const std = @import("std");
const allocation_failures = @import("allocation_failures.zig");
const repeated = @import("repeated_text.zig").repeated;
const Ast = @import("Ast.zig");
const Token = @import("Token.zig");
const Lexer = @import("Lexer.zig");

pub const Diagnostic = struct {
    kind: enum { break_outside_loop, varargs_outside_vararg_function, unsupported_attribute, global_close_attribute, multiple_to_be_closed },
    span: Token.Span,
    position: Token.Position,
};
pub const Error = error{ OutOfMemory, Syntax };

const Context = struct { loop: bool = false, varargs: bool = true };
const Frame = struct { node: *const Ast.Node, context: Context };
const Work = struct {
    allocator: std.mem.Allocator,
    frames: std.ArrayList(Frame) = .empty,

    fn push(self: *Work, node: *const Ast.Node, context: Context) Error!void {
        try self.frames.append(self.allocator, .{ .node = node, .context = context });
    }

    fn list(self: *Work, nodes: []const *const Ast.Node, context: Context) Error!void {
        var remaining = nodes.len;
        while (remaining > 0) {
            remaining -= 1;
            try self.push(nodes[remaining], context);
        }
    }
};

pub fn checkControl(allocator: std.mem.Allocator, ast: *const Ast, diagnostic: *?Diagnostic) Error!void {
    diagnostic.* = null;
    var work = Work{ .allocator = allocator };
    defer work.frames.deinit(allocator);
    try work.push(ast.root, .{});
    while (work.frames.pop()) |frame| {
        const node = frame.node;
        const context = frame.context;
        const loop = Context{ .loop = true, .varargs = context.varargs };
        switch (node.data) {
            .nil, .boolean, .number, .integer, .string, .name, .empty, .goto_statement, .label => {},
            .break_statement => if (!context.loop) {
                diagnostic.* = .{ .kind = .break_outside_loop, .span = node.span, .position = node.position };
                return error.Syntax;
            },
            .varargs => if (!context.varargs) {
                diagnostic.* = .{ .kind = .varargs_outside_vararg_function, .span = node.span, .position = node.position };
                return error.Syntax;
            },
            .group => |inner| try work.push(inner, context),
            .unary => |unary| try work.push(unary.operand, context),
            .binary => |binary| {
                try work.push(binary.right, context);
                try work.push(binary.left, context);
            },
            .index => |index| {
                try work.push(index.key, context);
                try work.push(index.receiver, context);
            },
            .field => |field| try work.push(field.receiver, context),
            .call => |call| {
                try work.list(call.arguments, context);
                try work.push(call.receiver, context);
            },
            .table => |fields| {
                var remaining = fields.len;
                while (remaining > 0) {
                    remaining -= 1;
                    const field = fields[remaining];
                    try work.push(field.value, context);
                    if (field.key == .expression) try work.push(field.key.expression, context);
                }
            },
            .function => |function| try work.push(function.body, .{ .varargs = function.varargs != null }),
            .block, .return_statement => |nodes| try work.list(nodes, context),
            .do_block => |body| try work.push(body, context),
            .declaration => |declaration| {
                if (declaration.default_attribute) |attribute| try checkAttribute(ast.source, attribute, declaration.global, diagnostic);
                var closing: usize = 0;
                for (declaration.names) |binding| {
                    if (binding.attribute) |attribute| try checkAttribute(ast.source, attribute, declaration.global, diagnostic);
                    // One to-be-closed variable per list, counted by each
                    // name's own attribute or the list's, as Lua counts.
                    const effective = binding.attribute orelse declaration.default_attribute orelse continue;
                    if (!std.mem.eql(u8, ast.source[effective.start..effective.end], "close")) continue;
                    closing += 1;
                    if (closing > 1) {
                        diagnostic.* = .{ .kind = .multiple_to_be_closed, .span = effective, .position = Lexer.positionAt(ast.source, effective.start) };
                        return error.Syntax;
                    }
                }
                try work.list(declaration.values, context);
            },
            .definition => |definition| {
                try work.push(definition.value, context);
                try work.push(definition.target, context);
            },
            .assignment => |assignment| {
                try work.list(assignment.values, context);
                try work.list(assignment.targets, context);
            },
            .conditional => |conditional| {
                if (conditional.otherwise) |otherwise| try work.push(otherwise, context);
                var remaining = conditional.arms.len;
                while (remaining > 0) {
                    remaining -= 1;
                    try work.push(conditional.arms[remaining].body, context);
                    try work.push(conditional.arms[remaining].condition, context);
                }
            },
            .while_loop => |statement| {
                try work.push(statement.body, loop);
                try work.push(statement.condition, context);
            },
            .repeat_loop => |statement| {
                try work.push(statement.condition, context);
                try work.push(statement.body, loop);
            },
            .numeric_for => |statement| {
                try work.push(statement.body, loop);
                if (statement.step) |step| try work.push(step, context);
                try work.push(statement.limit, context);
                try work.push(statement.initial, context);
            },
            .generic_for => |statement| {
                try work.push(statement.body, loop);
                try work.list(statement.values, context);
            },
        }
    }
}

fn checkAttribute(source: []const u8, span: Token.Span, global: bool, diagnostic: *?Diagnostic) Error!void {
    const name = source[span.start..span.end];
    if (std.mem.eql(u8, name, "const")) return;
    if (!global and std.mem.eql(u8, name, "close")) return;
    const position = Lexer.positionAt(source, span.start);
    diagnostic.* = .{
        .kind = if (global and std.mem.eql(u8, name, "close")) .global_close_attribute else .unsupported_attribute,
        .span = span,
        .position = position,
    };
    return error.Syntax;
}

fn check(source: []const u8, expected: ?@FieldType(Diagnostic, "kind")) !void {
    var parse_diagnostic: ?@import("parser.zig").Diagnostic = null;
    var ast = try @import("parser.zig").parseChunk(std.testing.allocator, source, &parse_diagnostic);
    defer ast.deinit();
    var diagnostic: ?Diagnostic = null;
    if (expected) |kind| {
        try std.testing.expectError(error.Syntax, checkControl(std.testing.allocator, &ast, &diagnostic));
        try std.testing.expectEqual(kind, diagnostic.?.kind);
    } else {
        try checkControl(std.testing.allocator, &ast, &diagnostic);
        try std.testing.expect(diagnostic == null);
    }
}

test "break requires a loop in the current function" {
    for ([_][]const u8{ "break", "do break end", "if true then break end", "while true do local f = function() break end end", "for i = 1, 2 do function t:m() break end end" }) |source| try check(source, .break_outside_loop);
    for ([_][]const u8{ "while true do break end", "repeat break until true", "for i = 1, 2 do break end", "for k in next, t do if k then do break end end end", "local f = function() while true do break end end", "while true do local f = function() end break end" }) |source| try check(source, null);
}

test "varargs belong only to the chunk or the immediately enclosing vararg function" {
    for ([_][]const u8{ "return ...", "local f = function(...) return {...} end", "function t:m(a, ...) f(...) end", "local f = function() return function(...) return ... end end" }) |source| try check(source, null);
    for ([_][]const u8{ "local f = function() return ... end", "local f = function(...) return function() return ... end end", "function t:m() return ... end", "local function f(a) f(...) end" }) |source| try check(source, .varargs_outside_vararg_function);
}

test "only const attributes are accepted in default binding and wildcard positions" {
    for ([_][]const u8{ "local <const> x, y <const>", "global <const> *", "global x <const> = 1" }) |source| try check(source, null);
    for ([_][]const u8{ "local x, y <unknown>", "global <unknown> *", "global x <unknown>" }) |source| try check(source, .unsupported_attribute);
    for ([_][]const u8{ "local a <close>, b <close> = nil, nil", "local <close> a, b = nil" }) |source| try check(source, .multiple_to_be_closed);
    for ([_][]const u8{ "local x <close>", "local <close> x", "local <close> x, y <const>", "local <const> x <close>" }) |source| try check(source, null);
    for ([_][]const u8{ "global <close> *", "global x <close>", "global <close> x" }) |source| try check(source, .global_close_attribute);
}

test "all expression and statement child positions are visited" {
    for ([_][]const u8{
        "local function f() local x = (...) end",
        "local function f() return -... end",
        "local function f() return 1 + ... end",
        "local function f() return ... + 1 end",
        "local function f() return t[...] end",
        "local function f() return (...).x end",
        "local function f() return (...)[1] end",
        "local function f() return (...)(1) end",
        "local function f() return g(...) end",
        "local function f() return {[...] = 1} end",
        "local function f() return {x = ...} end",
        "local function f() return {...} end",
        "local function f() t[...] = 1 end",
        "local function f() t.x = ... end",
        "local function f() if ... then end end",
        "local function f() if a then elseif ... then end end",
        "local function f() if a then else return ... end end",
        "local function f() while ... do end end",
        "local function f() while a do return ... end end",
        "local function f() repeat return ... until a end",
        "local function f() repeat until ... end",
        "local function f() for i = ..., 1 do end end",
        "local function f() for i = 1, ... do end end",
        "local function f() for i = 1, 2, ... do end end",
        "local function f() for i = 1, 2 do return ... end end",
        "local function f() for k in ... do end end",
        "local function f() for k in next, t do return ... end end",
        "local function f() do return ... end end",
    }) |source| try check(source, .varargs_outside_vararg_function);
}

test "diagnostics retain byte positions and the offending source span" {
    const source = "-- comment\r\nlocal x <\n bogus>";
    var parse_diagnostic: ?@import("parser.zig").Diagnostic = null;
    var ast = try @import("parser.zig").parseChunk(std.testing.allocator, source, &parse_diagnostic);
    defer ast.deinit();
    var diagnostic: ?Diagnostic = null;
    try std.testing.expectError(error.Syntax, checkControl(std.testing.allocator, &ast, &diagnostic));
    const failure = diagnostic.?;
    try std.testing.expectEqualStrings("bogus", source[failure.span.start..failure.span.end]);
    try std.testing.expectEqual(@as(usize, 3), failure.position.line);
    try std.testing.expectEqual(@as(usize, 2), failure.position.column);
    try std.testing.expectEqual(failure.span.start, failure.position.offset);
}

test "iterative validation handles deep left associative trees without imposing a syntax limit" {
    var ast = try @import("synthetic_ast.zig").addition(std.testing.allocator, 10000, true);
    defer ast.deinit();
    var diagnostic: ?Diagnostic = null;
    try checkControl(std.testing.allocator, &ast, &diagnostic);
    try std.testing.expect(diagnostic == null);
    try check("if false then " ++ repeated("elseif false then ", 1000) ++ "end", null);
}

fn allocationCase(allocator: std.mem.Allocator, ast: *const Ast, failure: bool) !void {
    var diagnostic: ?Diagnostic = .{ .kind = .break_outside_loop, .span = .{ .start = 0, .end = 0 }, .position = .{ .offset = 0, .line = 1, .column = 1 } };
    checkControl(allocator, ast, &diagnostic) catch |err| {
        if (err == error.OutOfMemory) {
            try std.testing.expect(diagnostic == null);
            return err;
        }
        if (failure and err == error.Syntax) return;
        return err;
    };
    if (failure) return error.TestUnexpectedResult;
    try std.testing.expect(diagnostic == null);
}

test "work storage is reclaimed on success failure and every allocation failure" {
    var parse_diagnostic: ?@import("parser.zig").Diagnostic = null;
    for ([_]bool{ false, true }) |failure| {
        const source = if (failure) "local function f() return {1, 2, 3, 4, 5, 6, 7, ...} end" else "local function f(...) return {1, 2, 3, 4, 5, 6, 7, ...} end";
        var ast = try @import("parser.zig").parseChunk(std.testing.allocator, source, &parse_diagnostic);
        defer ast.deinit();
        try allocation_failures.checkAll(std.testing.allocator, allocationCase, .{ &ast, failure });
    }
}

test "control validation does not claim to resolve const globals or labels" {
    try check("local x <const> = 1 x = 2 goto missing global x x = undeclared", null);
}

test "contexts are restored after loops functions and failed checks" {
    try check("while true do break end break", .break_outside_loop);
    try check("local f = function(...) return ... end local g = function() return ... end", .varargs_outside_vararg_function);
    try check("local f = function() end return ...", null);
    try check("local f = function(...) while true do do return ... end end end", null);
    var parse_diagnostic: ?@import("parser.zig").Diagnostic = null;
    var ast = try @import("parser.zig").parseChunk(std.testing.allocator, "\nlocal f = function() return ... end", &parse_diagnostic);
    defer ast.deinit();
    var diagnostic: ?Diagnostic = null;
    try std.testing.expectError(error.Syntax, checkControl(std.testing.allocator, &ast, &diagnostic));
    try std.testing.expectEqualStrings("...", ast.source[diagnostic.?.span.start..diagnostic.?.span.end]);
    try std.testing.expectEqual(@as(usize, 2), diagnostic.?.position.line);
    var valid = try @import("parser.zig").parseChunk(std.testing.allocator, "return ...", &parse_diagnostic);
    defer valid.deinit();
    try checkControl(std.testing.allocator, &valid, &diagnostic);
    try std.testing.expect(diagnostic == null);
}
