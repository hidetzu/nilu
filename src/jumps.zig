const std = @import("std");
const allocation_failures = @import("allocation_failures.zig");
const repeated = @import("repeated_text.zig").repeated;
const Ast = @import("Ast.zig");
const Token = @import("Token.zig");

pub const Error = error{ OutOfMemory, Syntax };
pub const Diagnostic = struct {
    kind: enum { missing_label, duplicate_label, enters_local_scope },
    name: Token.Span,
    position: Token.Position,
    related: ?Token.Span = null,
    previous_position: ?Token.Position = null,
};

pub const Resolution = struct { jump: *const Ast.Node, label: *const Ast.Node };

const Local = struct { parent: ?*const Local, name: Token.Span, depth: usize };
const Jump = struct { node: *const Ast.Node, name: Token.Span, locals: ?*const Local };
const Block = struct {
    parent: ?*Block,
    base: ?*const Local,
    labels: std.ArrayList(Jump) = .empty,
    jumps: std.ArrayList(Jump) = .empty,
};
const Context = struct { block: *Block, locals: ?*const Local };
const Visit = struct { node: *const Ast.Node, context: Context };
const Sequence = struct { nodes: []const *const Ast.Node, index: usize = 0, context: Context, terminal_start: usize };
const Task = union(enum) { visit: Visit, sequence: Sequence, finish: *Block };

const Checker = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    diagnostic: *?Diagnostic,
    tasks: std.ArrayList(Task) = .empty,
    resolutions: ?*std.ArrayList(Resolution) = null,
    output_allocator: std.mem.Allocator,

    fn same(self: *const Checker, a: Token.Span, b: Token.Span) bool {
        return std.mem.eql(u8, self.source[a.start..a.end], self.source[b.start..b.end]);
    }

    fn push(self: *Checker, node: *const Ast.Node, context: Context) Error!void {
        try self.tasks.append(self.allocator, .{ .visit = .{ .node = node, .context = context } });
    }

    fn list(self: *Checker, nodes: []const *const Ast.Node, context: Context) Error!void {
        var remaining = nodes.len;
        while (remaining > 0) {
            remaining -= 1;
            try self.push(nodes[remaining], context);
        }
    }

    fn bind(self: *Checker, locals: ?*const Local, name: Token.Span) Error!*const Local {
        const local = try self.allocator.create(Local);
        local.* = .{ .parent = locals, .name = name, .depth = depth(locals) + 1 };
        return local;
    }

    fn block(self: *Checker, node: *const Ast.Node, parent: ?*Block, locals: ?*const Local, repeat: bool) Error!void {
        const inner = try self.allocator.create(Block);
        inner.* = .{ .parent = parent, .base = locals };
        const nodes = node.data.block;
        var terminal_start = nodes.len;
        if (!repeat) while (terminal_start > 0) {
            switch (nodes[terminal_start - 1].data) {
                .label, .empty => terminal_start -= 1,
                else => break,
            }
        };
        try self.tasks.append(self.allocator, .{ .finish = inner });
        try self.tasks.append(self.allocator, .{ .sequence = .{ .nodes = nodes, .context = .{ .block = inner, .locals = locals }, .terminal_start = terminal_start } });
    }

    fn sequence(self: *Checker, frame: Sequence) Error!void {
        if (frame.index == frame.nodes.len) return;
        const node = frame.nodes[frame.index];
        var next = frame;
        next.index += 1;
        switch (node.data) {
            .declaration => |declaration| {
                for (declaration.names) |binding| next.context.locals = try self.bind(next.context.locals, binding.name);
                if (declaration.wildcard) next.context.locals = try self.bind(next.context.locals, .{ .start = node.span.end - 1, .end = node.span.end });
            },
            .definition => |definition| if (definition.scope != .ordinary) {
                next.context.locals = try self.bind(next.context.locals, definition.target.span);
            },
            else => {},
        }
        try self.tasks.append(self.allocator, .{ .sequence = next });
        var context = frame.context;
        if (node.data == .label and frame.index >= frame.terminal_start) context.locals = context.block.base;
        try self.push(node, context);
    }

    fn label(self: *Checker, node: *const Ast.Node, name: Token.Span, context: Context) Error!void {
        var current: ?*Block = context.block;
        while (current) |scope| : (current = scope.parent) {
            for (scope.labels.items) |previous| if (self.same(name, previous.name)) {
                self.diagnostic.* = .{ .kind = .duplicate_label, .name = name, .position = node.position, .related = previous.name, .previous_position = previous.node.position };
                return error.Syntax;
            };
        }
        try context.block.labels.append(self.allocator, .{ .node = node, .name = name, .locals = context.locals });
    }

    fn finish(self: *Checker, scope: *Block) Error!void {
        for (scope.jumps.items) |jump| {
            var target: ?Jump = null;
            for (scope.labels.items) |candidate| if (self.same(candidate.name, jump.name)) {
                target = candidate;
                break;
            };
            if (target) |label_target| {
                if (depth(label_target.locals) > depth(jump.locals)) {
                    var entered = label_target.locals.?;
                    while (depth(entered.parent) > depth(jump.locals)) entered = entered.parent.?;
                    self.diagnostic.* = .{ .kind = .enters_local_scope, .name = jump.name, .position = jump.node.position, .related = entered.name };
                    return error.Syntax;
                }
                if (self.resolutions) |output| try output.append(self.output_allocator, .{ .jump = jump.node, .label = label_target.node });
            } else if (scope.parent) |parent| {
                var outward = jump;
                outward.locals = scope.base;
                try parent.jumps.append(self.allocator, outward);
            } else {
                self.diagnostic.* = .{ .kind = .missing_label, .name = jump.name, .position = jump.node.position };
                return error.Syntax;
            }
        }
    }

    fn visit(self: *Checker, frame: Visit) Error!void {
        const node = frame.node;
        const context = frame.context;
        switch (node.data) {
            .nil, .boolean, .number, .integer, .string, .name, .empty => {},
            .break_statement, .varargs => {},
            .goto_statement => |name| try context.block.jumps.append(self.allocator, .{ .node = node, .name = name, .locals = context.locals }),
            .label => |name| try self.label(node, name, context),
            .group => |inner| try self.push(inner, context),
            .unary => |unary| try self.push(unary.operand, context),
            .binary => |binary| {
                try self.push(binary.right, context);
                try self.push(binary.left, context);
            },
            .index => |index| {
                try self.push(index.key, context);
                try self.push(index.receiver, context);
            },
            .field => |field| try self.push(field.receiver, context),
            .call => |call| {
                try self.list(call.arguments, context);
                try self.push(call.receiver, context);
            },
            .table => |fields| {
                var remaining = fields.len;
                while (remaining > 0) {
                    remaining -= 1;
                    const field = fields[remaining];
                    try self.push(field.value, context);
                    if (field.key == .expression) try self.push(field.key.expression, context);
                }
            },
            .function => |function| try self.block(function.body, null, null, false),
            .block => try self.block(node, context.block, context.locals, false),
            .return_statement => |nodes| try self.list(nodes, context),
            .do_block => |body| try self.push(body, context),
            .declaration => |declaration| {
                try self.list(declaration.values, context);
            },
            .definition => |definition| {
                try self.push(definition.value, context);
                try self.push(definition.target, context);
            },
            .assignment => |assignment| {
                try self.list(assignment.values, context);
                try self.list(assignment.targets, context);
            },
            .conditional => |conditional| {
                if (conditional.otherwise) |otherwise| try self.push(otherwise, context);
                var remaining = conditional.arms.len;
                while (remaining > 0) {
                    remaining -= 1;
                    try self.push(conditional.arms[remaining].body, context);
                    try self.push(conditional.arms[remaining].condition, context);
                }
            },
            .while_loop => |statement| {
                try self.push(statement.body, context);
                try self.push(statement.condition, context);
            },
            .repeat_loop => |statement| {
                try self.push(statement.condition, context);
                try self.block(statement.body, context.block, context.locals, true);
            },
            .numeric_for => |statement| {
                try self.push(statement.body, context);
                if (statement.step) |step| try self.push(step, context);
                try self.push(statement.limit, context);
                try self.push(statement.initial, context);
            },
            .generic_for => |statement| {
                try self.push(statement.body, context);
                try self.list(statement.values, context);
            },
        }
    }
};

fn depth(locals: ?*const Local) usize {
    return if (locals) |local| local.depth else 0;
}

/// Checks labels and goto scope entry. Borrows an unchanged parsed AST for the
/// call; all work storage is freed on success, syntax refusal or allocation failure.
/// This does not emit jumps, close captured cells or establish full validity.
pub fn checkJumps(allocator: std.mem.Allocator, ast: *const Ast, diagnostic: *?Diagnostic) Error!void {
    return resolve(allocator, ast, diagnostic, null);
}

/// Optionally appends resolved AST node pairs to caller-owned storage.
/// The caller frees the list, including when validation fails part way through.
pub fn resolve(allocator: std.mem.Allocator, ast: *const Ast, diagnostic: *?Diagnostic, resolutions: ?*std.ArrayList(Resolution)) Error!void {
    diagnostic.* = null;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var checker = Checker{ .allocator = arena.allocator(), .source = ast.source, .diagnostic = diagnostic, .resolutions = resolutions, .output_allocator = allocator };
    var outer = Block{ .parent = null, .base = null };
    try checker.tasks.append(checker.allocator, .{ .finish = &outer });
    try checker.push(ast.root, .{ .block = &outer, .locals = null });
    while (checker.tasks.pop()) |task| switch (task) {
        .visit => |frame| try checker.visit(frame),
        .sequence => |frame| try checker.sequence(frame),
        .finish => |scope| try checker.finish(scope),
    };
}

fn check(source: []const u8, expected: ?@FieldType(Diagnostic, "kind")) !void {
    var parse_diagnostic: ?@import("parser.zig").Diagnostic = null;
    var ast = try @import("parser.zig").parseChunk(std.testing.allocator, source, &parse_diagnostic);
    defer ast.deinit();
    var diagnostic: ?Diagnostic = null;
    if (expected) |kind| {
        try std.testing.expectError(error.Syntax, checkJumps(std.testing.allocator, &ast, &diagnostic));
        try std.testing.expectEqual(kind, diagnostic.?.kind);
    } else {
        try checkJumps(std.testing.allocator, &ast, &diagnostic);
        try std.testing.expect(diagnostic == null);
    }
}

test "jumps resolve forward backward and outward but not into child or sibling blocks" {
    for ([_][]const u8{
        "goto done ::done::",                            "::again:: f() goto again",                                            "do goto out end ::out::",
        "::out:: while true do goto out end",            "if a then goto out elseif b then goto out else goto out end ::out::", "for i = 1, 3 do goto done end ::done::",
        "for k, v in next, t do goto done end ::done::",
    }) |source| try check(source, null);
    for ([_][]const u8{
        "goto missing",                  "goto child do ::child:: end",               "do goto sibling end do ::sibling:: end",
        "do ::hidden:: end goto hidden", "if a then ::hidden:: else goto hidden end",
    }) |source| try check(source, .missing_label);
}

test "jumps cannot enter local scopes including captured and shadowed bindings" {
    for ([_][]const u8{
        "goto f local x = 1 ::f:: print(x)",
        "goto f local x <const> = 1 ::f:: print(x)",
        "goto f local function f() end ::f:: f()",
        "local x = 1 goto f local x = 2 ::f:: print(x)",
        "do goto f end local x = 1 ::f:: print(x)",
        "do local y = 1 goto f end local x = 1 ::f:: print(x)",
        "do do goto f end end local x = 1 ::f:: print(x)",
        "local function f() goto done local x = 1 ::done:: return x end",
        "for i = 1, 3 do goto f local x = 1 ::f:: print(x) end",
    }) |source| try check(source, .enters_local_scope);
    for ([_][]const u8{
        "local x = 1 goto f ::f:: print(x)",
        "::f:: local x = 1 goto f",
        "local x = 1 do local y = 2 goto f end ::f:: print(x)",
        "do local x = 1 end goto f do local y = 2 end ::f:: print(1)",
    }) |source| try check(source, null);
}

test "jumps to terminal labels ignore block locals except before until" {
    for ([_][]const u8{
        "goto f local x = 1 ::f::",                                                                                    "do goto f local x = 1 ::f:: end",
        "do goto f local x = 1 ::f:: ; ::g:: ;; end",                                                                  "for i = 1, 3 do if i == 2 then goto continue end local x = i ::continue:: end",
        "if a then goto f local x = 1 ::f:: elseif b then goto g local y = 2 ::g:: else goto h local z = 3 ::h:: end", "repeat do goto f local x = 1 ::f:: end until true",
    }) |source| try check(source, null);
    for ([_][]const u8{
        "repeat goto f local x = 1 ::f:: until x",
        "repeat goto f local x = 1 ::f:: ; ::g:: ; until true",
        "goto f local x = 1 ::f:: do end",
        "goto f local x = 1 ::f:: return",
    }) |source| try check(source, .enters_local_scope);
}

test "jumps keep function labels separate in every expression position" {
    for ([_][]const u8{
        "::f:: local function x() goto f end",               "goto f local function x() ::f:: end",
        "local f = function() goto missing end",             "return function() goto missing end",
        "f(function() goto missing end)",                    "local t = {[function() goto missing end] = 1}",
        "local t = {x = function() goto missing end}",       "(function() goto missing end)()",
        "t[function() goto missing end] = 1",                "t.x = function() goto missing end",
        "if (function() goto missing end)() then end",       "while (function() goto missing end)() do end",
        "repeat until (function() goto missing end)()",      "for i = (function() goto missing end)(), 2 do end",
        "for i = 1, (function() goto missing end)() do end", "for i = 1, 2, (function() goto missing end)() do end",
        "for k in (function() goto missing end)() do end",
    }) |source| try check(source, .missing_label);
    try check("::f:: local function x() goto f ::f:: end", null);
    try check("goto f local function x() goto f ::f:: end ::f::", null);
}

test "jumps reject duplicate visible labels but allow siblings and separate functions" {
    for ([_][]const u8{
        "::a:: ::a::",                         "::a:: do ::a:: end",            "::a:: if true then ::a:: end",
        "::a:: while true do ::a:: end",       "::a:: repeat ::a:: until true", "::a:: for i = 1, 3 do ::a:: end",
        "::a:: for k in next, t do ::a:: end",
    }) |source| try check(source, .duplicate_label);
    for ([_][]const u8{
        "do ::a:: end do ::a:: end",          "if true then ::a:: else ::a:: end",
        "::a:: local function f() ::a:: end", "local function f() ::a:: end ::a::",
    }) |source| try check(source, null);
}

test "jumps diagnostics identify goto position first entered local and previous label" {
    const source = "-- first\r\ndo\n  goto target\nend\nlocal x, y = 1, 2\n::target:: print(x)";
    var parse_diagnostic: ?@import("parser.zig").Diagnostic = null;
    var ast = try @import("parser.zig").parseChunk(std.testing.allocator, source, &parse_diagnostic);
    defer ast.deinit();
    var diagnostic: ?Diagnostic = null;
    try std.testing.expectError(error.Syntax, checkJumps(std.testing.allocator, &ast, &diagnostic));
    try std.testing.expectEqualStrings("target", source[diagnostic.?.name.start..diagnostic.?.name.end]);
    try std.testing.expectEqualStrings("x", source[diagnostic.?.related.?.start..diagnostic.?.related.?.end]);
    try std.testing.expectEqual(@as(usize, 3), diagnostic.?.position.line);
    try std.testing.expectEqual(@as(usize, 3), diagnostic.?.position.column);
    try std.testing.expectEqualStrings("goto", source[diagnostic.?.position.offset..][0..4]);
    var duplicate = try @import("parser.zig").parseChunk(std.testing.allocator, "::a::\ndo\n ::a:: end", &parse_diagnostic);
    defer duplicate.deinit();
    try std.testing.expectError(error.Syntax, checkJumps(std.testing.allocator, &duplicate, &diagnostic));
    try std.testing.expectEqual(@as(usize, 3), diagnostic.?.position.line);
    try std.testing.expectEqual(@as(usize, 2), diagnostic.?.position.column);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.?.previous_position.?.line);
    var missing = try @import("parser.zig").parseChunk(std.testing.allocator, "\n goto unknown", &parse_diagnostic);
    defer missing.deinit();
    try std.testing.expectError(error.Syntax, checkJumps(std.testing.allocator, &missing, &diagnostic));
    try std.testing.expectEqual(@as(usize, 2), diagnostic.?.position.line);
    try std.testing.expectEqual(@as(usize, 2), diagnostic.?.position.column);
    var valid = try @import("parser.zig").parseChunk(std.testing.allocator, "goto f ::f::", &parse_diagnostic);
    defer valid.deinit();
    try checkJumps(std.testing.allocator, &valid, &diagnostic);
    try std.testing.expect(diagnostic == null);
}

fn allocationCase(allocator: std.mem.Allocator, ast: *const Ast, failure: bool) !void {
    var diagnostic: ?Diagnostic = null;
    checkJumps(allocator, ast, &diagnostic) catch |err| {
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

test "jumps storage is freed on success refusal and every allocation failure" {
    const prefix = "local x = 1 do local y = 2 do goto out end end local function f() goto own ::own:: end ";
    for ([_][]const u8{ "::out::", "::out:: ::out::", "local z = 1 ::out:: print(z)", "" }) |tail| {
        var parse_diagnostic: ?@import("parser.zig").Diagnostic = null;
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, tail });
        defer std.testing.allocator.free(source);
        var ast = try @import("parser.zig").parseChunk(std.testing.allocator, source, &parse_diagnostic);
        defer ast.deinit();
        try allocation_failures.checkAll(std.testing.allocator, allocationCase, .{ &ast, !std.mem.eql(u8, tail, "::out::") });
    }
}

test "jumps traversal handles long expression trees and flat blocks iteratively" {
    var ast = try @import("synthetic_ast.zig").addition(std.testing.allocator, 10000, true);
    defer ast.deinit();
    var diagnostic: ?Diagnostic = null;
    try checkJumps(std.testing.allocator, &ast, &diagnostic);
    try std.testing.expect(diagnostic == null);
    try check(repeated("local x = 1 ", 2000) ++ "goto f ::f::", null);
    try check("if false then " ++ repeated("elseif false then ", 1000) ++ "end", null);
}

test "jumps also accept expression parser trees without assuming a block root" {
    for ([_][]const u8{ "1 + 2", "function() goto own ::own:: end", "{function() goto own ::own:: end}" }) |source| {
        var parse_diagnostic: ?@import("parser.zig").Diagnostic = null;
        var ast = try @import("parser.zig").parseExpression(std.testing.allocator, source, &parse_diagnostic);
        defer ast.deinit();
        var diagnostic: ?Diagnostic = null;
        try checkJumps(std.testing.allocator, &ast, &diagnostic);
        try std.testing.expect(diagnostic == null);
    }
    var parse_diagnostic: ?@import("parser.zig").Diagnostic = null;
    var ast = try @import("parser.zig").parseExpression(std.testing.allocator, "function() goto missing end", &parse_diagnostic);
    defer ast.deinit();
    var diagnostic: ?Diagnostic = null;
    try std.testing.expectError(error.Syntax, checkJumps(std.testing.allocator, &ast, &diagnostic));
    try std.testing.expectEqual(.missing_label, diagnostic.?.kind);
}

test "jumps cannot enter named wildcard or function global declaration scopes" {
    try check("global * do goto l global x ::l:: x = 8 end", .enters_local_scope);
    try check("goto l global * ::l:: x = 1", .enters_local_scope);
    try check("goto f global x = 1 ::f:: print(x)", .enters_local_scope);
    try check("goto l global function f() end ::l:: f()", .enters_local_scope);
    try check("goto l global x ::l::", null);
    try check("do goto l global * ::l:: end", null);
    try check("global x goto l ::l:: x = 1", null);
}
