const std = @import("std");
const allocation_failures = @import("allocation_failures.zig");
const runtime = @import("runtime.zig");
const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const vm = @import("vm.zig");
const a = std.testing.allocator;
const State = runtime.State;
const Value = runtime.Value;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
fn field(state: *State, table: *runtime.Table, name: []const u8, value: Value) !void {
    state.barrier(&table.header);
    try table.set(state.allocator, .from(.{ .string = try state.newString(name) }), value);
}
fn compile(state: *State, allocator: std.mem.Allocator, source: []const u8) !*runtime.Closure {
    var parsed: ?parser.Diagnostic = null;
    var ast = try parser.parseChunk(allocator, source, &parsed);
    defer ast.deinit();
    var diagnostic: ?compiler.Diagnostic = null;
    return state.newChunk(try compiler.compile(allocator, state, &ast, "<operator-handler>", &diagnostic));
}
fn run(state: *State, source: []const u8, diagnostic: *?vm.Diagnostic) !usize {
    return vm.run(state, try compile(state, a, source), diagnostic);
}
fn script(state: *State, source: []const u8) !Value {
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(state, source, &diagnostic);
    const method = state.get(-1).?;
    try state.setTop(-2);
    return method;
}
fn attach(state: *State, receiver: Value, name: []const u8, method: Value) !*runtime.Table {
    const meta = try state.newTable();
    try field(state, meta, name, method);
    try state.setMetatable(receiver, meta);
    return meta;
}
fn install(state: *State, name: []const u8, value: Value) !void {
    try field(state, state.globals, name, value);
}

test "length_handler precedes border passes operand twice and preserves arbitrary first result" {
    const results = [_][]const u8{ "", "nil,99", "false,99", "0,99", "'length',99", "{},99", "function() return 7 end", "1152921504606846976" };
    const kinds = [_]@import("runtime.zig").Type{ .nil, .nil, .boolean, .number, .string, .table, .function, .number };
    for (results, kinds, 0..) |result, kind, index| {
        var state = try State.init(a);
        defer state.deinit();
        const table = try state.newTable();
        state.barrier(&table.header);
        try table.set(a, .from(.{ .number = 1 }), .from(.{ .number = 8 }));
        const value = Value.from(.{ .table = table });
        try install(&state, "t", value);
        const source = try std.fmt.allocPrint(a, "global * return function(x,y,...) first=x second=y local args={{...}} extra=#args return {s} end", .{result});
        defer a.free(source);
        _ = try attach(&state, value, "__len", try script(&state, source));
        try state.push(.from(.{ .number = 42 }));
        var diagnostic: ?vm.Diagnostic = null;
        _ = try run(&state, "return #t", &diagnostic);
        try equal(@as(usize, 2), state.top());
        const actual = state.get(2).?;
        try equal(kind, actual.type());
        switch (index) {
            2 => try expect(actual.equal(.from(.{ .boolean = false }))),
            3 => try expect(actual.equal(.from(.{ .number = 0 }))),
            4 => try std.testing.expectEqualStrings("length", actual.unpack().string.bytes),
            7 => try expect(actual.equal(.from(.{ .number = 1152921504606846976 }))),
            else => {},
        }
        try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
        try expect(state.globals.getString("first").equal(value));
        try expect(state.globals.getString("second").equal(value));
        try expect(state.globals.getString("extra").equal(.from(.{ .number = 0 })));
        try equal(@as(usize, 1), table.length());
        try equal(@as(usize, 0), state.frames.items.len);
    }
}

test "length_handler absent uses raw border and an inherited handler is found" {
    var state = try State.init(a);
    defer state.deinit();
    const value = Value.from(.{ .table = try state.newTable() });
    try value.unpack().table.set(a, .from(.{ .number = 1 }), .from(.{ .number = 8 }));
    try install(&state, "t", value);
    const meta = try attach(&state, value, "__len", .nil);
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(&state, "return #t,#'é',#''", &diagnostic);
    for ([_]f64{ 1, 2, 0 }, state.stack.items) |expected, actual| try expect(actual.equal(.from(.{ .number = expected })));
    // __len one table-valued __index link away is the handler (ADR 0012).
    const provider = try state.newTable();
    try field(&state, provider, "__len", try script(&state, "return function() return 99 end"));
    _ = try attach(&state, .from(.{ .table = meta }), "__index", .from(.{ .table = provider }));
    try state.setTop(0);
    _ = try run(&state, "return #t", &diagnostic);
    try expect(state.get(-1).?.equal(.from(.{ .number = 99 })));
    // An uncallable handler fails as a call and names the metamethod.
    const Uncallable = struct { method: Value, message: []const u8 };
    for ([_]Uncallable{
        .{ .method = .from(.{ .boolean = false }), .message = "[string \"<operator-handler>\"]:1: attempt to call a boolean value (metamethod 'len')" },
        .{ .method = .from(.{ .number = 0 }), .message = "[string \"<operator-handler>\"]:1: attempt to call a number value (metamethod 'len')" },
        .{ .method = .from(.{ .table = provider }), .message = "[string \"<operator-handler>\"]:1: attempt to call a table value (metamethod 'len')" },
    }) |case| {
        try state.setTop(0);
        try field(&state, meta, "__len", case.method);
        try std.testing.expectError(error.Type, run(&state, "return #t", &diagnostic));
        try std.testing.expectEqualStrings(case.message, state.failure.?.value.unpack().string.bytes);
        try equal(@as(usize, 0), state.top());
    }
    // A callable table handler is called with itself first, then the operand twice.
    const callable = Value.from(.{ .table = try state.newTable() });
    try install(&state, "callable", callable);
    _ = try attach(&state, callable, "__call", try script(&state, "global * return function(self, x, y) seen = {self, x, y} return 5 end"));
    try field(&state, meta, "__len", callable);
    try state.setTop(0);
    _ = try run(&state, "return #t", &diagnostic);
    try expect(state.get(-1).?.equal(.from(.{ .number = 5 })));
    const seen = state.globals.getString("seen").unpack().table;
    try expect(seen.get(.from(.{ .number = 1 })).equal(callable) and seen.get(.from(.{ .number = 2 })).equal(value) and seen.get(.from(.{ .number = 3 })).equal(value));
}

fn nativeLength(state: *State) callconv(.c) c_int {
    if (state.top() != 2 or !state.get(1).?.equal(state.get(2).?)) return -1;
    state.collect();
    state.push(.from(.{ .number = 42 })) catch return -1;
    state.push(.from(.{ .number = 99 })) catch return -1;
    return 2;
}
test "length_handler native and C closure dispatch supports userdata and GC" {
    for (0..3) |mode| {
        var state = try State.init(a);
        defer state.deinit();
        const value = Value.from(.{ .userdata = try state.newUserdata(8) });
        try install(&state, "t", value);
        const method: Value = if (mode == 0) try script(&state, "return function(x,y) if x==y then return 42 end return 0 end") else .fromFunction(if (mode == 1) .{ .native = nativeLength } else try state.newCClosure(nativeLength, &.{value}));
        _ = try attach(&state, value, "__len", method);
        state.setCollectionThreshold(0);
        var diagnostic: ?vm.Diagnostic = null;
        _ = try run(&state, "return #t", &diagnostic);
        try expect(state.get(-1).?.equal(.from(.{ .number = 42 })));
    }
}

test "length_handler invalid primitive and bare userdata refuse without coercion" {
    var state = try State.init(a);
    defer state.deinit();
    try install(&state, "t", .from(.{ .userdata = try state.newUserdata(0) }));
    for ([_][]const u8{ "return #nil", "return #true", "return #1", "return #t", "return #function() end" }) |source| {
        var diagnostic: ?vm.Diagnostic = null;
        try std.testing.expectError(error.Type, run(&state, source, &diagnostic));
        try equal(@as(usize, 0), state.top());
        try equal(@as(usize, 0), state.frames.items.len);
    }
}

test "length_handler failures and recursion restore caller and close escaped captures" {
    var state = try State.init(a);
    defer state.deinit();
    const value = Value.from(.{ .table = try state.newTable() });
    try install(&state, "t", value);
    const meta = try attach(&state, value, "__len", try script(&state, "global * return function() local n=7 saved=function() return n end return 1+nil end"));
    try state.push(.from(.{ .number = 42 }));
    var diagnostic: ?vm.Diagnostic = null;
    try std.testing.expectError(error.Type, run(&state, "return #t", &diagnostic));
    try equal(@as(usize, 1), state.top());
    state.collect();
    _ = try run(&state, "return saved()", &diagnostic);
    try expect(state.get(-1).?.equal(.from(.{ .number = 7 })));
    try state.setTop(1);
    try field(&state, meta, "__len", try script(&state, "return function(x) return #x end"));
    try std.testing.expectError(error.CallDepth, run(&state, "return #t", &diagnostic));
    try equal(@as(usize, 1), state.top());
    try equal(@as(usize, 0), state.frames.items.len);
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var state = try State.init(allocator);
    defer state.deinit();
    const value = Value.from(.{ .table = try state.newTable() });
    try install(&state, "t", value);
    var diagnostic: ?vm.Diagnostic = null;
    _ = try vm.run(&state, try compile(&state, allocator, "return function() return {n=7} end"), &diagnostic);
    _ = try attach(&state, value, "__len", state.get(-1).?);
    try state.setTop(0);
    const closure = try compile(&state, allocator, "return (#t).n");
    try state.push(.from(.{ .number = 42 }));
    _ = vm.run(&state, closure, &diagnostic) catch |err| {
        try equal(@as(usize, 1), state.top());
        try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
        try equal(@as(usize, 0), state.frames.items.len);
        return err;
    };
    try expect(state.get(-1).?.equal(.from(.{ .number = 7 })));
}
test "length_handler allocation failures release setup and unwind frames" {
    try allocation_failures.checkAll(a, allocationCase, .{});
}

test "length_handler returned closures retain captures after collection" {
    var state = try State.init(a);
    defer state.deinit();
    const value = Value.from(.{ .table = try state.newTable() });
    try install(&state, "t", value);
    _ = try attach(&state, value, "__len", try script(&state, "return function() local x={n=7} return function() return x.n end end"));
    state.setCollectionThreshold(0);
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(&state, "local f=#t return f()", &diagnostic);
    try expect(state.get(-1).?.equal(.from(.{ .number = 7 })));
}
