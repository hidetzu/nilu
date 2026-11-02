const std = @import("std");
const allocation_failures = @import("allocation_failures.zig");
const repeated = @import("repeated_text.zig").repeated;
const Ast = @import("Ast.zig");
const Token = @import("Token.zig");

pub const Error = error{ OutOfMemory, Syntax };
pub const Diagnostic = struct {
    kind: enum { const_assignment, undeclared_global, global_environment },
    name: Token.Span,
    position: Token.Position,
};

/// Source declaration offsets are stable within an AST; the implicit chunk
/// environment has a reserved identity. Analysis and lowering share these IDs.
pub const BindingId = usize;
pub const root_environment: BindingId = std.math.maxInt(usize);
pub const Reference = struct { binding: ?BindingId, environment: ?BindingId };
pub const Analysis = std.AutoHashMapUnmanaged(usize, Reference);

const Binding = struct {
    id: BindingId,
    parent: ?*const Binding,
    name: ?[]const u8,
    global: bool,
    read_only: bool,
};
const Environment = ?*const Binding;
const Visit = struct { node: *const Ast.Node, environment: Environment, write: bool = false };
const Sequence = struct { nodes: []const *const Ast.Node, environment: Environment, index: usize = 0, tail: ?*const Ast.Node = null };
const Task = union(enum) { visit: Visit, sequence: Sequence };
const Resolution = struct { global: bool, read_only: bool, declared: bool = true, id: ?BindingId = null };

const Checker = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    diagnostic: *?Diagnostic,
    tasks: std.ArrayList(Task) = .empty,
    analysis: ?*Analysis = null,
    analysis_allocator: std.mem.Allocator,
    /// Whether anything assigns a variable named `_ENV`.
    environment_written: bool = false,

    fn bind(self: *Checker, environment: Environment, name: ?[]const u8, global: bool, read_only: bool, id: BindingId) Error!Environment {
        const binding = try self.allocator.create(Binding);
        binding.* = .{ .parent = environment, .name = name, .global = global, .read_only = read_only, .id = id };
        return binding;
    }

    fn text(self: *const Checker, span: Token.Span) []const u8 {
        return self.source[span.start..span.end];
    }

    fn attribute(self: *const Checker, span: ?Token.Span) bool {
        // A to-be-closed variable is read-only as a constant is (Lua 5.5).
        return if (span) |name| std.mem.eql(u8, self.text(name), "const") or std.mem.eql(u8, self.text(name), "close") else false;
    }

    fn push(self: *Checker, node: *const Ast.Node, environment: Environment, write: bool) Error!void {
        try self.tasks.append(self.allocator, .{ .visit = .{ .node = node, .environment = environment, .write = write } });
    }

    fn list(self: *Checker, nodes: []const *const Ast.Node, environment: Environment, write: bool) Error!void {
        var remaining = nodes.len;
        while (remaining > 0) {
            remaining -= 1;
            try self.push(nodes[remaining], environment, write);
        }
    }

    fn sequence(self: *Checker, frame: Sequence) Error!void {
        if (frame.index == frame.nodes.len) {
            if (frame.tail) |tail| try self.push(tail, frame.environment, false);
            return;
        }
        const node = frame.nodes[frame.index];
        var next = frame;
        next.index += 1;
        var current = frame.environment;
        switch (node.data) {
            .declaration => |declaration| {
                if (declaration.wildcard) {
                    next.environment = try self.bind(current, null, true, self.attribute(declaration.default_attribute), node.span.start);
                } else {
                    for (declaration.names) |binding| {
                        next.environment = try self.bind(next.environment, self.text(binding.name), declaration.global, self.attribute(binding.attribute orelse declaration.default_attribute), binding.name.start);
                    }
                }
            },
            .definition => |definition| if (definition.scope != .ordinary) {
                next.environment = try self.bind(current, self.text(definition.target.span), definition.scope == .global, false, definition.target.span.start);
                current = next.environment;
            },
            else => {},
        }
        try self.tasks.append(self.allocator, .{ .sequence = next });
        try self.push(node, current, false);
    }

    fn checkName(self: *Checker, node: *const Ast.Node, environment: Environment, write: bool) Error!void {
        const found = resolve(environment, self.text(node.span));
        if (write and std.mem.eql(u8, self.text(node.span), "_ENV")) self.environment_written = true;
        const kind: ?@FieldType(Diagnostic, "kind") = if (!found.declared) .undeclared_global else if (write and found.read_only) .const_assignment else if (found.global and resolve(environment, "_ENV").global) .global_environment else null;
        if (self.analysis) |analysis| try analysis.put(self.analysis_allocator, node.position.offset, .{ .binding = found.id, .environment = resolve(environment, "_ENV").id });
        if (kind) |failure| {
            self.diagnostic.* = .{ .kind = failure, .name = node.span, .position = node.position };
            return error.Syntax;
        }
    }

    fn visit(self: *Checker, task: Visit) Error!void {
        const node = task.node;
        const environment = task.environment;
        switch (node.data) {
            .nil, .boolean, .number, .integer, .string, .varargs, .empty, .break_statement, .goto_statement, .label => {},
            .name => try self.checkName(node, environment, task.write),
            .group => |inner| try self.push(inner, environment, false),
            .unary => |unary| try self.push(unary.operand, environment, false),
            .binary => |binary| {
                try self.push(binary.right, environment, false);
                try self.push(binary.left, environment, false);
            },
            .index => |index| {
                try self.push(index.key, environment, false);
                try self.push(index.receiver, environment, false);
            },
            .field => |field| try self.push(field.receiver, environment, false),
            .call => |call| {
                try self.list(call.arguments, environment, false);
                try self.push(call.receiver, environment, false);
            },
            .table => |fields| {
                var remaining = fields.len;
                while (remaining > 0) {
                    remaining -= 1;
                    try self.push(fields[remaining].value, environment, false);
                    if (fields[remaining].key == .expression) try self.push(fields[remaining].key.expression, environment, false);
                }
            },
            .function => |function| {
                var inner = environment;
                if (function.implicit_self) inner = try self.bind(inner, "self", false, false, node.span.start);
                for (function.parameters) |parameter| inner = try self.bind(inner, self.text(parameter), false, false, parameter.start);
                // A named vararg table is read-only, as in Lua 5.5: `...` reads
                // its fields, so the name always means this call's table.
                if (function.varargs_name) |name| inner = try self.bind(inner, self.text(name), false, true, name.start);
                try self.push(function.body, inner, false);
            },
            .block => |nodes| try self.tasks.append(self.allocator, .{ .sequence = .{ .nodes = nodes, .environment = environment } }),
            .return_statement => |nodes| try self.list(nodes, environment, false),
            .do_block => |body| try self.push(body, environment, false),
            .declaration => |declaration| {
                if (declaration.global) {
                    if (self.analysis) |analysis| for (declaration.names) |binding| {
                        try analysis.put(self.analysis_allocator, binding.name.start, .{ .binding = null, .environment = resolve(environment, "_ENV").id });
                    };
                }
                if (declaration.global and declaration.values.len > 0 and resolve(environment, "_ENV").global) {
                    const span = declaration.names[0].name;
                    self.diagnostic.* = .{ .kind = .global_environment, .name = span, .position = @import("Lexer.zig").positionAt(self.source, span.start) };
                    return error.Syntax;
                }
                try self.list(declaration.values, environment, false);
            },
            .definition => |definition| {
                try self.push(definition.value, environment, false);
                try self.push(definition.target, environment, definition.scope == .ordinary);
            },
            .assignment => |assignment| {
                try self.list(assignment.values, environment, false);
                try self.list(assignment.targets, environment, true);
            },
            .conditional => |conditional| {
                if (conditional.otherwise) |otherwise| try self.push(otherwise, environment, false);
                var remaining = conditional.arms.len;
                while (remaining > 0) {
                    remaining -= 1;
                    try self.push(conditional.arms[remaining].body, environment, false);
                    try self.push(conditional.arms[remaining].condition, environment, false);
                }
            },
            .while_loop => |statement| {
                try self.push(statement.body, environment, false);
                try self.push(statement.condition, environment, false);
            },
            .repeat_loop => |statement| try self.tasks.append(self.allocator, .{ .sequence = .{ .nodes = statement.body.data.block, .environment = environment, .tail = statement.condition } }),
            .numeric_for => |statement| {
                const inner = try self.bind(environment, self.text(statement.name), false, true, statement.name.start);
                try self.push(statement.body, inner, false);
                if (statement.step) |step| try self.push(step, environment, false);
                try self.push(statement.limit, environment, false);
                try self.push(statement.initial, environment, false);
            },
            .generic_for => |statement| {
                var inner = environment;
                for (statement.names, 0..) |binding, index| inner = try self.bind(inner, self.text(binding), false, index == 0, binding.start);
                try self.push(statement.body, inner, false);
                try self.list(statement.values, environment, false);
            },
        }
    }
};

fn resolve(environment: Environment, name: []const u8) Resolution {
    var current = environment;
    var wildcard: ?bool = null;
    var declared = false;
    while (current) |binding| : (current = binding.parent) {
        if (binding.name) |bound| {
            if (std.mem.eql(u8, bound, name)) return .{ .global = binding.global, .read_only = binding.read_only, .id = if (binding.global) null else binding.id };
            declared = declared or binding.global;
        } else if (wildcard == null) wildcard = binding.read_only;
    }
    return .{ .global = true, .read_only = wildcard orelse false, .declared = wildcard != null or !declared };
}

pub fn checkNames(allocator: std.mem.Allocator, ast: *const Ast, diagnostic: *?Diagnostic) Error!void {
    return analyze(allocator, ast, diagnostic, null, null);
}

/// Optionally publish reference identities into caller-owned storage. With an
/// output map, the caller owns its allocations; it contains only value IDs.
/// `environment_written`, when given, says whether anything in the chunk
/// assigns a variable named `_ENV`: when nothing does, every `_ENV` keeps the
/// value it started with, so reading it later reads the same table.
pub fn analyze(allocator: std.mem.Allocator, ast: *const Ast, diagnostic: *?Diagnostic, analysis: ?*Analysis, environment_written: ?*bool) Error!void {
    diagnostic.* = null;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var checker = Checker{ .allocator = arena.allocator(), .source = ast.source, .diagnostic = diagnostic, .analysis = analysis, .analysis_allocator = allocator };
    const initial = try checker.bind(null, "_ENV", false, false, root_environment);
    try checker.push(ast.root, initial, false);
    while (checker.tasks.pop()) |task| switch (task) {
        .visit => |visit| try checker.visit(visit),
        .sequence => |sequence| try checker.sequence(sequence),
    };
    if (environment_written) |written| written.* = checker.environment_written;
}

fn check(source: []const u8, expected: ?@FieldType(Diagnostic, "kind")) !void {
    var parse_diagnostic: ?@import("parser.zig").Diagnostic = null;
    var ast = try @import("parser.zig").parseChunk(std.testing.allocator, source, &parse_diagnostic);
    defer ast.deinit();
    var control_diagnostic: ?@import("validation.zig").Diagnostic = null;
    try @import("validation.zig").checkControl(std.testing.allocator, &ast, &control_diagnostic);
    var diagnostic: ?Diagnostic = null;
    if (expected) |kind| {
        try std.testing.expectError(error.Syntax, checkNames(std.testing.allocator, &ast, &diagnostic));
        try std.testing.expectEqual(kind, diagnostic.?.kind);
    } else {
        try checkNames(std.testing.allocator, &ast, &diagnostic);
        try std.testing.expect(diagnostic == null);
    }
}

test "const assignments are refused directly through closures and function definitions" {
    for ([_][]const u8{
        "local x <const> = 1 x = 2",
        "local <const> a, b = 1, 2 b = 3",
        "local x <const> = 1 local function f() x = 2 end",
        "local x <const> function x() end",
        "global x <const> = 1 x = 2",
        "global <const> * x = 1",
        "global x <const> function x() end",
        "for i = 1, 3 do i = 9 end",
        "for i = 1, 3 do local f = function() i = 9 end end",
    }) |source| try check(source, .const_assignment);
}

test "new locals parameters and methods shadow rather than mutate outer const bindings" {
    for ([_][]const u8{
        "local x <const> = {} x.a = 1 x[2] = 3 function x:m() end",
        "local x <const> = 1 do local x = 2 x = 3 end",
        "local x <const> local x = 1 x = 2",
        "local x <const> local function x() x = 1 end",
        "local x <const> local f = function(x) x = 2 end",
        "local self <const> function t:m() self = 1 end",
        "local x <const> global x x = 2",
        "local x <const> global function x() x = 1 end",
        "local i <const> for k, i in next, t do i = 3 end",
    }) |source| try check(source, null);
}

test "closures see declaration-time bindings and normal local initializers see the outer scope" {
    try check("local x <const> local f = function() x = 1 end local x = 2", .const_assignment);
    try check("local x <const> local x = function() x = 1 end", .const_assignment);
    try check("local x = 1 local f = function() x = 2 end local x <const>", null);
    try check("local x <const> local f = function() local x = 1 x = 2 end", null);
    try check("local x <const> do local x = 1 end x = 2", .const_assignment);
}

test "global declarations are lexical sequential inherited and relaxed by wildcard" {
    for ([_][]const u8{
        "y = 1 global x",
        "do global x end y = 1",
        "global x global y y = 1",
        "global * global x y = 1",
        "local function f() global x end y = 1",
        "global x local x = 2 x = 3",
        "global <const> * global x x = 1",
        "global x global <const> * x = 1",
    }) |source| try check(source, null);
    for ([_][]const u8{
        "global x y = 1",
        "global x do y = 1 end",
        "global x local function f() y = 1 end",
        "global x local x = 2 y = 1",
        "global x do global * y = 1 end z = 1",
        "global y global x = x",
    }) |source| try check(source, .undeclared_global);
}

test "global initializers use the previous binding and global functions bind before their body" {
    try check("local x <const> global x = function() x = 1 end", .const_assignment);
    try check("global x global function f() return f(), x end", null);
    try check("global x local f = function() return f() end", .undeclared_global);
    try check("global x local function f() return f() end", null);
    try check("local x <const> global x = x x = 2", null);
}

test "repeat conditions share body locals while branches and loops do not leak declarations" {
    try check("global x repeat local done = true until done", null);
    try check("local x <const> repeat local x = 1 until (function() x = 2 end)()", null);
    try check("local x <const> while true do local x = 1 end x = 2", .const_assignment);
    try check("global x if true then local y = 1 elseif y then end", .undeclared_global);
    try check("global x for i = i, 3 do end", .undeclared_global);
    try check("global x for k in k do end", .undeclared_global);
}

test "global environment access is refused when ENV resolves to a global" {
    try check("global _ENV global x = 1", .global_environment);
    try check("global _ENV, x x = 1", .global_environment);
    try check("global _ENV, x local f = function() return x end", .global_environment);
    try check("global _ENV do local _ENV = {} global x x = 1 end", null);
    try check("local _ENV <const> = {} x = 1", null);
}

test "all expression names are resolved but field labels and constructor name keys are not reads" {
    for ([_][]const u8{
        "global f f({x = 1})",
        "global t t.x = 1 function t:m() self.x = 1 end",
        "global x return {x = x}",
    }) |source| try check(source, null);
    for ([_][]const u8{
        "global t t[x] = 1",            "global t return t[x]",            "global f f(x)",
        "global f return x()",          "global t return {x}",             "global t return {[x] = 1}",
        "global t return -x",           "global t return 1 + x",           "global t return (x).y",
        "global t while x do end",      "global t if x then end",          "global t repeat until x",
        "global t for i = 1, x do end", "global t for i = 1, 2, x do end", "global t for k in x do end",
        "global t function x() end",
    }) |source| try check(source, .undeclared_global);
}

fn allocationCase(allocator: std.mem.Allocator, ast: *const Ast, failure: bool) !void {
    var diagnostic: ?Diagnostic = null;
    checkNames(allocator, ast, &diagnostic) catch |err| {
        if (failure and err == error.Syntax) return;
        return err;
    };
    if (failure) return error.TestUnexpectedResult;
    try std.testing.expect(diagnostic == null);
}

test "scope storage is freed on success syntax failure and every allocation failure" {
    const source = "global print local x <const> = 1 local function f(a) repeat local t = {x = x} for i = 1, 3 do local g = function() return i end end until a end ";
    for ([_]bool{ false, true }) |failure| {
        var parse_diagnostic: ?@import("parser.zig").Diagnostic = null;
        var ast = try @import("parser.zig").parseChunk(std.testing.allocator, if (failure) source ++ "x = 2" else source, &parse_diagnostic);
        defer ast.deinit();
        try allocation_failures.checkAll(std.testing.allocator, allocationCase, .{ &ast, failure });
    }
}

fn expectConstPosition(source: []const u8, name: []const u8, line: usize, column: usize) !void {
    var parse_diagnostic: ?@import("parser.zig").Diagnostic = null;
    var ast = try @import("parser.zig").parseChunk(std.testing.allocator, source, &parse_diagnostic);
    defer ast.deinit();
    var diagnostic: ?Diagnostic = null;
    try std.testing.expectError(error.Syntax, checkNames(std.testing.allocator, &ast, &diagnostic));
    const failure = diagnostic.?;
    try std.testing.expectEqual(.const_assignment, failure.kind);
    try std.testing.expectEqualStrings(name, source[failure.name.start..failure.name.end]);
    try std.testing.expectEqual(failure.name.start, failure.position.offset);
    try std.testing.expectEqual(line, failure.position.line);
    try std.testing.expectEqual(column, failure.position.column);
}

// The owner's answer: a const assignment points at the start of the
// written name, whatever form the write takes, so the reader lands on the name
// to change. Columns count bytes.
test "const assignment errors point at the start of the written name" {
    try expectConstPosition("local limit <const> = 10\nlimit = 20", "limit", 2, 1);
    try expectConstPosition("local a, limit2 <const> = 1, 2\na,\n  limit2 = 3, 4", "limit2", 3, 3);
    try expectConstPosition("local limit <const> = 1\nfunction limit() end", "limit", 2, 10);
    try expectConstPosition("local x <const> = 1\nlocal function f()\n  return function() x = 2 end\nend", "x", 3, 21);
    try expectConstPosition("global g <const> = 1\n  g = 2", "g", 2, 3);
    try expectConstPosition("for i = 1, 3 do\n    i = 9\nend", "i", 2, 5);
    try expectConstPosition("local s <const> = 'é' s = 1", "s", 1, 24);
    // Also the owner's: with two const targets, the first in source order.
    try expectConstPosition("local a <const>, b <const> = 1, 2\nb,\na = 3, 4", "b", 2, 1);
}

test "long expression trees and flat declarations do not recurse on the host stack" {
    var ast = try @import("synthetic_ast.zig").addition(std.testing.allocator, 10000, true);
    defer ast.deinit();
    var diagnostic: ?Diagnostic = null;
    try checkNames(std.testing.allocator, &ast, &diagnostic);
    try std.testing.expect(diagnostic == null);
    try check(repeated("local x = 1 ", 2000) ++ "x = 2", null);
}

test "named declarations beat wildcard defaults without hiding locals" {
    try check("local x <const> global * x = 1", .const_assignment);
    try check("global x <const> global * x = 1", .const_assignment);
    try check("global <const> * local function f() y = 1 end", .const_assignment);
    try check("local x <const> global * global x x = 1", null);
    try check("global <const> * global x local f = function() x = 1 end", null);
    try check("global * do global <const> * x = 1 end", .const_assignment);
}

test "generic for first control is read-only while later names remain mutable" {
    try check("for k, v in next, t do k = 1 end", .const_assignment);
    try check("for k in next, t do local f = function() k = 1 end end", .const_assignment);
    try check("for k, v in next, t do v = 1 end", null);
    try check("for k in next, t do local k = 1 k = 2 end", null);
}
