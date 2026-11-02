const std = @import("std");
const allocation_failures = @import("allocation_failures.zig");
const runtime = @import("runtime.zig");
const api = @import("c_api.zig");
const a = std.testing.allocator;
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
fn function(state: *runtime.State, source: [*:0]const u8) !runtime.Value {
    try equal(api.Status.ok, api.nilu_loadnamed(state, source, "=operator", null));
    try equal(api.Status.ok, api.nilu_call(state, 0, 1));
    const value = state.get(-1).?;
    try equal(api.Status.ok, api.nilu_settop(state, -2));
    return value;
}
fn object(state: *runtime.State, name: []const u8, method: runtime.Value) !runtime.Value {
    const table = try state.newTable();
    const meta = try state.newTable();
    state.barrier(&meta.header);
    try meta.set(state.allocator, .from(.{ .string = try state.newString(name) }), method);
    const value: runtime.Value = .from(.{ .table = table });
    try state.setMetatable(value, meta);
    return value;
}
test "c_api_operator primitive length comparison no coercion and input preservation" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try equal(api.Status.ok, api.nilu_pushlstring(&state, "a\x00b", 3));
    try equal(api.Status.ok, api.nilu_len(&state, 1));
    try equal(@as(f64, 3), api.nilu_tonumberx(&state, -1, null));
    try equal(api.Status.ok, api.nilu_pushnumber(&state, 8));
    const before = state.top();
    try equal(api.Status.type, api.nilu_len(&state, -1));
    try equal(before, state.top());
    try equal(api.Status.type, api.nilu_compare(&state, 1, 3, 1));
    try equal(before, state.top());
    for ([_]c_int{ 0, 1, 2 }) |operation| {
        try equal(api.Status.ok, api.nilu_compare(&state, 2, 3, operation));
        try equal(@as(c_int, if (operation == 0) 0 else 1), api.nilu_toboolean(&state, -1));
        try equal(api.Status.ok, api.nilu_settop(&state, -2));
    }
    try equal(api.Status.ok, api.nilu_pushnumber(&state, std.math.nan(f64)));
    try equal(api.Status.ok, api.nilu_compare(&state, -1, -1, 0));
    try equal(@as(c_int, 0), api.nilu_toboolean(&state, -1));
}
var observed_frames: usize = 0;
fn collectResult(state: *runtime.State) callconv(.c) c_int {
    observed_frames = state.frames.items.len;
    state.collect();
    if (api.nilu_gettop(state) != 2) return -1;
    if (api.nilu_pushstring(state, "arbitrary") != .ok) return -1;
    return 1;
}
test "c_api_operator native C closure handlers add only their own frame and arbitrary length result" {
    for ([_]bool{ false, true }) |closure| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        const method: runtime.Value = .fromFunction(if (closure) try state.newCClosure(collectResult, &.{.from(.{ .number = 7 })}) else .{ .native = collectResult });
        try state.push(try object(&state, "__len", method));
        observed_frames = 0;
        try equal(api.Status.ok, api.nilu_len(&state, 1));
        try equal(@as(usize, 1), observed_frames);
        try std.testing.expectEqualStrings("arbitrary", state.get(-1).?.unpack().string.bytes);
        try equal(api.Status.ok, api.nilu_rawlen(&state, 1));
        try equal(@as(f64, 0), api.nilu_tonumberx(&state, -1, null));
        try expect(state.execution == null and state.frames.items.len == 0);
    }
}
test "c_api_operator inherited script comparison truth and no inclusive fallback" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    const method = try function(&state, "return function(a,b) return 'truthy',false end");
    const left = try object(&state, "__lt", method);
    const base = left.unpack().table.metatable.?;
    const derived = try state.newTable();
    const links = try state.newTable();
    state.barrier(&links.header);
    try links.set(a, .from(.{ .string = try state.newString("__index") }), .from(.{ .table = base }));
    derived.metatable = links;
    left.unpack().table.metatable = derived;
    try state.push(left);
    try equal(api.Status.ok, api.nilu_newtable(&state));
    try equal(api.Status.ok, api.nilu_compare(&state, 1, 2, 1));
    try equal(@as(c_int, 1), api.nilu_toboolean(&state, -1));
    try equal(api.Status.ok, api.nilu_settop(&state, 2));
    try equal(api.Status.type, api.nilu_compare(&state, 1, 2, 2));
    try equal(@as(c_int, 2), api.nilu_gettop(&state));
    state.barrier(&base.header);
    try base.set(a, .from(.{ .string = try state.newString("__eq") }), method);
    try equal(api.Status.ok, api.nilu_compare(&state, 1, 2, 0));
    try equal(@as(c_int, 1), api.nilu_toboolean(&state, -1));
}
fn stop(_: *runtime.State) callconv(.c) c_int {
    return 1;
}
test "c_api_operator failed or interrupted metamethod publishes one failure value and restores its window" {
    for ([_]bool{ false, true }) |interrupted| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        const method = try function(&state, if (interrupted) "return function() while true do end end" else "return function() return 1+nil end");
        try state.push(try object(&state, "__len", method));
        const input = state.get(1).?;
        if (interrupted) api.nilu_sethook(&state, stop, 1);
        try equal(if (interrupted) api.Status.interrupted else .type, api.nilu_len(&state, 1));
        try equal(@as(c_int, 2), api.nilu_gettop(&state));
        try expect(state.get(1).?.equal(input));
        try expect(state.originAt(1) != null);
        if (interrupted) try expect(state.get(-1).?.is(.nil)) else try expect(state.get(-1).?.is(.string));
        try expect(state.execution == null and state.frames.items.len == 0);
        try equal(if (interrupted) runtime.FailureKind.interrupted else .type_error, state.failure.?.kind);
    }
}
var executions: usize = 0;
fn count(state: *runtime.State) callconv(.c) c_int {
    executions += 1;
    return collectResult(state);
}
test "c_api_operator result reservation refuses before executing any handler" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try state.push(try object(&state, "__len", .fromFunction(.{ .native = count })));
    executions = 0;
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    const capacity = @min(state.stack.capacity, state.origins.capacity);
    try state.setTop(@intCast(capacity));
    state.allocator = failing.allocator();
    const status = api.nilu_len(&state, 1);
    state.allocator = a;
    try equal(api.Status.memory, status);
    try equal(@as(usize, 0), executions);
    try equal(capacity, state.top());
    try equal(api.Status.ok, api.nilu_settop(&state, 1_000_000));
    try equal(api.Status.stack, api.nilu_len(&state, 1));
    try equal(@as(usize, 0), executions);
}
fn allocationCase(allocator: std.mem.Allocator) !void {
    var state = try runtime.State.init(allocator);
    defer state.deinit();
    var diagnostic: ?@import("loader.zig").Diagnostic = null;
    const method = try @import("loader.zig").prepare(&state, "local n=0 return n", "=query", &diagnostic);
    const value = try object(&state, "__len", .fromFunction(.{ .closure = method }));
    try state.push(value);
    state.setCollectionThreshold(0);
    const status = api.nilu_len(&state, 1);
    try expect(state.execution == null and state.frames.items.len == 0);
    try expect(state.get(1).?.equal(value));
    if (status == .memory) return error.OutOfMemory;
    try equal(api.Status.ok, status);
    try equal(@as(c_int, 2), api.nilu_gettop(&state));
}
test "c_api_operator every allocation failure releases preparation and restores query roots" {
    try allocation_failures.checkAll(a, allocationCase, .{});
}

extern fn test_operator_queries(*runtime.State) callconv(.c) c_int;
extern fn test_operator_failure(*runtime.State) callconv(.c) c_int;
extern fn test_public_handler(*runtime.State) callconv(.c) c_int;
extern fn test_public_handler_count() callconv(.c) c_int;
extern fn test_public_reset_handlers() callconv(.c) void;
test "c_api_operator actual C client uses len compare and query metamethod failures inherit protection" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    const value = try object(&state, "__len", .fromFunction(.{ .native = collectResult }));
    try value.unpack().table.metatable.?.set(a, .from(.{ .string = try state.newString("__eq") }), .fromFunction(.{ .native = collectResult }));
    try value.unpack().table.metatable.?.set(a, .from(.{ .string = try state.newString("__lt") }), .fromFunction(.{ .native = collectResult }));
    try equal(api.Status.ok, api.nilu_pushcfunction(&state, test_operator_queries));
    try state.push(value);
    try equal(api.Status.ok, api.nilu_newtable(&state));
    try equal(api.Status.ok, api.nilu_call(&state, 2, 0));
    try equal(@as(usize, 2), observed_frames);
    const method = try function(&state, "return function() return 1+nil end");
    try equal(api.Status.ok, api.nilu_pushcfunction(&state, test_public_handler));
    try equal(api.Status.ok, api.nilu_pushcfunction(&state, test_operator_failure));
    try state.push(try object(&state, "__len", method));
    test_public_reset_handlers();
    // The C client can handle the returned status. The metamethod's raise
    // has still run the enclosing handler before unwinding, like nilu_call.
    try equal(api.Status.ok, api.nilu_pcall(&state, 1, 0, 1));
    try equal(@as(c_int, 1), test_public_handler_count());
    try expect(state.execution == null and state.failure == null);
}

fn originalFailure(state: *runtime.State) callconv(.c) c_int {
    if (api.nilu_pushstring(state, "original failure") != .ok) return -1;
    return api.nilu_error(state);
}
test "c_api_operator queries preserve suspended failure roots and input provenance" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try equal(api.Status.ok, api.nilu_pushcfunction(&state, originalFailure));
    try equal(api.Status.runtime, api.nilu_call(&state, 0, 0));
    const origin = state.originAt(0).?;
    const original = state.failure.?;
    try equal(api.Status.ok, api.nilu_len(&state, 1));
    try expect(state.originAt(0) == origin and state.originAt(1) == null);
    try expect(std.meta.eql(original, state.failure.?));
    try equal(api.Status.ok, api.nilu_settop(&state, 1));
    const h = try function(&state, "return function() local t={} return 'answer' end");
    // The factory completed a new call; restore the carried record to exercise
    // its suspension across a collecting metamethod without manufacturing origin.
    state.failure = original;
    try state.push(try object(&state, "__len", h));
    state.setCollectionThreshold(0);
    try equal(api.Status.ok, api.nilu_len(&state, 2));
    try expect(std.meta.eql(original, state.failure.?));
    try std.testing.expectEqualStrings("original failure", state.get(1).?.unpack().string.bytes);
    try equal(api.Status.ok, api.nilu_pushnil(&state));
    const before = state.top();
    try equal(api.Status.type, api.nilu_len(&state, -1));
    try equal(before, state.top());
    try expect(std.meta.eql(original, state.failure.?));
    try expect(state.originAt(0) == origin);
}
