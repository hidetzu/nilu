const std = @import("std");
const allocation_failures = @import("allocation_failures.zig");
const runtime = @import("runtime.zig");
const loader = @import("loader.zig");
const vm = @import("vm.zig");
const a = std.testing.allocator;
const equal = std.testing.expectEqual;
const expect = std.testing.expect;

test "loader prepares without executing and owns source names constants after input mutation" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    var source = "global marker=99 return 'held'".*;
    var name = "=loader".*;
    var diagnostic: ?loader.Diagnostic = null;
    const chunk = try loader.prepare(&state, &source, &name, &diagnostic);
    try expect(diagnostic == null);
    try equal(@as(usize, 1), state.top());
    try expect(state.globals.getString("marker").is(.nil));
    @memset(&source, '?');
    @memset(&name, '?');
    try std.testing.expectEqualStrings("global marker=99 return 'held'", chunk.prototype.source);
    try std.testing.expectEqualStrings("=loader", chunk.prototype.chunk_name);
    try state.push(.fromFunction(.{ .closure = chunk }));
    state.collect();
    var execution: ?vm.Diagnostic = null;
    try equal(@as(usize, 1), try vm.run(&state, chunk, &execution));
    try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
    try std.testing.expectEqualStrings("held", state.get(-1).?.unpack().string.bytes);
    try expect(state.globals.getString("marker").equal(.from(.{ .number = 99 })));
}

test "loader parse and compiler diagnostics survive arena teardown and success clears stale output" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    var diagnostic: ?loader.Diagnostic = null;
    // Positions independently retained in the carried C syntax-error case.
    for ([_]struct { source: []const u8, line: usize, column: usize }{
        .{ .source = "return 10 +", .line = 1, .column = 12 },
        .{ .source = "return 10 +\n  * 2", .line = 2, .column = 3 },
        .{ .source = "1 + 2", .line = 1, .column = 1 },
    }) |case| {
        try std.testing.expectError(error.Syntax, loader.prepare(&state, case.source, "=bad", &diagnostic));
        const position = switch (diagnostic.?.parse) {
            .expected_expression, .invalid_statement => |token| token.position,
            else => return error.TestUnexpectedResult,
        };
        try equal(case.line, position.line);
        try equal(case.column, position.column);
        try equal(@as(usize, 1), state.top());
    }
    try std.testing.expectError(error.Syntax, loader.prepare(&state, "global known return missing", "=bad", &diagnostic));
    try expect(diagnostic.? == .compile);
    try expect(diagnostic.?.compile == .names);
    try expect(diagnostic.?.compile.names.kind == .undeclared_global);
    try equal(@as(usize, 21), diagnostic.?.compile.names.position.column);
    _ = try loader.prepare(&state, "return 7", "=ok", &diagnostic);
    try expect(diagnostic == null);
    try equal(@as(usize, 1), state.top());
    try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
}

test "loader indexed stores prepare without executing and syntax depth has a formal refusal" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    var diagnostic: ?loader.Diagnostic = null;
    _ = try loader.prepare(&state, "local t={} t.x=1", "=indexed", &diagnostic);
    try expect(diagnostic == null);
    var nested: [410]u8 = undefined;
    @memset(nested[0..201], '(');
    nested[201] = '1';
    @memset(nested[202..403], ')');
    const source = try std.fmt.allocPrint(a, "return {s}", .{nested[0..403]});
    defer a.free(source);
    try std.testing.expectError(error.Syntax, loader.prepare(&state, source, "=deep", &diagnostic));
    try expect(diagnostic.?.parse == .syntax_limit);
    try equal(@as(usize, 0), state.top());
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var state = try runtime.State.init(allocator);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    var diagnostic: ?loader.Diagnostic = null;
    const objects = state.objects;
    const prototypes = state.prototypes;
    const count = state.object_count;
    const chunk = loader.prepare(&state, "local x='held' return function() return x end", "=allocation", &diagnostic) catch |err| {
        try expect(state.objects == objects);
        try expect(state.prototypes == prototypes);
        try equal(count, state.object_count);
        try equal(@as(usize, 1), state.top());
        try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
        return err;
    };
    try equal(@as(usize, 1), state.top());
    try expect(diagnostic == null);
    try expect(chunk.prototype.children.len == 1);
    try expect(chunk.upvalues.len == 1);
}

test "loader every allocation failure preserves caller stack and frees owned temporary storage" {
    try allocation_failures.checkAll(a, allocationCase, .{});
}

test "loader separate prepared chunks own distinct environments and preserve caller frames" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    try state.pushFrame(.{ .base = 1, .function = .{ .native = noop } });
    var diagnostic: ?loader.Diagnostic = null;
    const first = try loader.prepare(&state, "return 1", "=first", &diagnostic);
    const second = try loader.prepare(&state, "return 2", "=second", &diagnostic);
    try expect(first != second);
    try expect(first.upvalues[0] != second.upvalues[0]);
    try expect(state.readCell(first.upvalues[0]).unpack().table == state.globals);
    try expect(state.readCell(second.upvalues[0]).unpack().table == state.globals);
    try equal(@as(usize, 0), state.top());
    try equal(@as(usize, 1), state.frames.items.len);
    _ = state.popFrame();
    try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
}
fn noop(_: *runtime.State) callconv(.c) c_int {
    return 0;
}

test "loader failed preparation releases unpublished constants while preserving previous chunks" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    const kept = try state.newString("caller");
    try state.push(.from(.{ .string = kept }));
    var diagnostic: ?loader.Diagnostic = null;
    const chunk = try loader.prepare(&state, "return 'kept'", "=kept", &diagnostic);
    try state.push(.fromFunction(.{ .closure = chunk }));
    const objects = state.objects;
    const prototypes = state.prototypes;
    const count = state.object_count;
    // Both compile paths create a first constant before a later refusal.
    for (0..20) |_| {
        try std.testing.expectError(error.Syntax, loader.prepare(&state, "return 'unpublished', '\\q'", "=bad", &diagnostic));
        try expect(state.objects == objects);
        try expect(state.prototypes == prototypes);
        try equal(count, state.object_count);
        try expect(diagnostic.?.compile == .string);
        const message = try @import("load_diagnostic.zig").render(a, "return 'unpublished', '\\q'", "=bad", diagnostic.?);
        defer a.free(message);
        try expect(std.mem.indexOf(u8, message, "invalid escape sequence") != null);
        try std.testing.expectError(error.Syntax, loader.prepare(&state, "return 'unpublished', function(t) return '\\q' end", "=child-bad", &diagnostic));
        try expect(state.objects == objects);
        try expect(state.prototypes == prototypes);
        try equal(count, state.object_count);
    }
    try equal(@as(usize, 2), state.top());
    state.collect();
    try expect(state.get(1).?.unpack().string == kept);
    try std.testing.expectEqualStrings("caller", kept.bytes);
    var execution: ?vm.Diagnostic = null;
    try equal(@as(usize, 1), try vm.run(&state, chunk, &execution));
    try std.testing.expectEqualStrings("kept", state.get(-1).?.unpack().string.bytes);
}

test "loader grammar families compile without executing runtime dependent paths" {
    const sources = [_][]const u8{
        "return nil,true,1,'s',(2),not false,-1,#'abc',1+2,1 .. 2",
        "local t={1,a=2,[3]=4} t.a,t[3]=t[3],t.a return t.a,t[1]",
        "local function f(a,...) return a,... end return f(1,2)",
        "local t={} function t:m(x) return self,x end function t.f() end return t:m(1)",
        "global x=1 global function f() return x end return f()",
        "global * return unknown",
        "do local x=1 end if true then elseif false then else end",
        "while true do break end repeat local x=1 until x==1",
        "for i=1,3,1 do local x=i end for k,v in missing_iterator,nil,0 do end",
        "::again:: ; do goto again end",
        "local x<const> = 1 return function() return x end",
        "local _ENV={} field=1 return field",
    };
    for (sources) |source| {
        errdefer std.debug.print("load-only grammar case: {s}\n", .{source});
        var state = try runtime.State.init(a);
        defer state.deinit();
        try state.push(.from(.{ .number = 42 }));
        var diagnostic: ?loader.Diagnostic = null;
        const chunk = try loader.prepare(&state, source, "=grammar", &diagnostic);
        try expect(diagnostic == null);
        try equal(@as(usize, 1), state.top());
        try equal(@as(usize, 0), state.frames.items.len);
        try expect(state.globals.getString("x").is(.nil));
        try vm.validate(chunk.prototype);
    }
}

test "loader compiler rejects misplaced internal nodes as InvalidAst" {
    const Ast = @import("Ast.zig");
    const compiler = @import("compiler.zig");
    const position = @import("Token.zig").Position{ .offset = 0, .line = 1, .column = 1 };
    const expression = Ast.Node{ .span = .{ .start = 0, .end = 0 }, .position = position, .data = .{ .number = 1 } };
    const nodes = [_]*const Ast.Node{&expression};
    for ([_]Ast.Node.Data{ .empty, .{ .block = &nodes } }) |data| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        const root = Ast.Node{ .span = .{ .start = 0, .end = 0 }, .position = position, .data = data };
        var ast = Ast{ .arena = std.heap.ArenaAllocator.init(a), .source = "", .root = &root };
        defer ast.deinit();
        var diagnostic: ?compiler.Diagnostic = null;
        try std.testing.expectError(error.InvalidAst, compiler.compile(a, &state, &ast, "=invalid", &diagnostic));
        try expect(diagnostic == null);
        try equal(@as(usize, 0), state.top());
    }
}

// Each function of a chunk once copied the whole source, so n functions held
// n copies: memory and time grew with the square of the chunk.
test "loader the functions of a chunk share one copy of its source" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    var diagnostic: ?loader.Diagnostic = null;
    const chunk = try loader.prepare(&state, "local function f() return function() return 1 end end return f", "=shared", &diagnostic);
    const root = chunk.prototype;
    try expect(root.owns_source);
    try equal(@as(usize, 1), root.children.len);
    const f = root.children[0];
    try equal(@as(usize, 1), f.children.len);
    for ([_]*const runtime.Prototype{ f, f.children[0] }) |child| {
        try expect(!child.owns_source);
        try equal(root.source.ptr, child.source.ptr);
    }
}
