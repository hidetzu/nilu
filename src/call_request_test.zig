const std = @import("std");
const runtime = @import("runtime.zig");
const request = @import("c_api.zig").CallRequest;
const transport = @import("failure_transport.zig");
const api = @import("c_api.zig");
const vm = @import("vm.zig");
const a = std.testing.allocator;
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
var calls: usize = 0;
fn echo(state: *runtime.State) callconv(.c) c_int {
    calls += 1;
    return @intCast(state.top());
}
fn fail(state: *runtime.State) callconv(.c) c_int {
    if (api.nilu_pushstring(state, "original") != .ok) return -1;
    return api.nilu_error(state);
}
fn handled(state: *runtime.State) callconv(.c) c_int {
    if (api.nilu_pushstring(state, "handled") != .ok) return -1;
    return 1;
}

test "call_request signed counts are checked without overflow execution or mutation" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    try state.push(.fromFunction(.{ .native = echo }));
    try state.push(.nil);
    calls = 0;
    for ([_]c_int{ std.math.minInt(c_int), -1, 3, std.math.maxInt(c_int) }) |count|
        try std.testing.expectError(error.InvalidArgumentCount, request.prepare(&state, count, 0, 0));
    for ([_]c_int{ std.math.minInt(c_int), -2 }) |count|
        try std.testing.expectError(error.InvalidResultCount, request.prepare(&state, 1, count, 0));
    for ([_]c_int{ -1, 0, 1, std.math.maxInt(c_int) }) |count| {
        const prepared = try request.prepare(&state, 1, count, 0);
        try equal(@as(usize, 1), prepared.arguments);
        try equal(if (count == -1) @as(?usize, null) else @as(?usize, @intCast(count)), prepared.results);
        try expect(prepared.handler == null);
    }
    try equal(@as(usize, 0), calls);
    try equal(@as(usize, 3), state.top());
    try equal(@as(f64, 42), state.get(1).?.numberValue().?);
}

test "call_request missing callee and arguments are misuse but a nonfunction callee is a language condition" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try std.testing.expectError(error.InvalidArgumentCount, request.prepare(&state, 0, 0, 0));
    try state.push(.nil);
    try std.testing.expectError(error.InvalidArgumentCount, request.prepare(&state, 1, 0, 0));
    const prepared = try request.prepare(&state, 0, 0, 0);
    var diagnostic: ?vm.Diagnostic = null;
    try equal(runtime.FailureKind.type_error, (try transport.callAdjusted(&state, prepared.arguments, prepared.results, true, prepared.handler, &diagnostic)).failure);
    try equal(@as(usize, 1), state.top());
    try std.testing.expectEqualStrings("attempt to call a nil value", state.get(1).?.unpack().string.bytes);
}

test "call_request handler indices resolve before execution and must be functions below the callee" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try state.push(.fromFunction(.{ .native = handled }));
    try state.push(.fromFunction(.{ .native = echo }));
    try state.push(.from(.{ .number = 7 }));
    for ([_]c_int{ 1, -3 }) |index| {
        const prepared = try request.prepare(&state, 1, -1, index);
        try expect(prepared.handler.?.equal(state.get(1).?));
    }
    for ([_]c_int{ 2, 3, -1, -2, 4, -4, std.math.minInt(c_int), std.math.maxInt(c_int) }) |index|
        try std.testing.expectError(error.InvalidHandlerIndex, request.prepare(&state, 1, 0, index));
    state.stack.items[0] = .from(.{ .boolean = false });
    try std.testing.expectError(error.InvalidHandlerType, request.prepare(&state, 1, 0, 1));
}

test "call_request indices cannot expose suspended caller slots and preparation allocates nothing" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try state.push(.fromFunction(.{ .native = handled }));
    try state.push(.fromFunction(.{ .native = echo }));
    try state.push(.from(.{ .number = 7 }));
    try state.pushFrame(.{ .base = 1, .function = .{ .native = echo } });
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    const saved = state.allocator;
    defer state.allocator = saved;
    state.allocator = failing.allocator();
    try std.testing.expectError(error.InvalidHandlerIndex, request.prepare(&state, 1, 0, -3));
    try std.testing.expectError(error.InvalidHandlerIndex, request.prepare(&state, 1, 0, 1));
    _ = try request.prepare(&state, 1, -1, 0);
    try equal(@as(usize, 0), failing.alloc_index);
    _ = state.popFrame();
}

test "call_request prepared negative handler index survives callee result replacement" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    try state.push(.fromFunction(.{ .native = handled }));
    try state.push(.fromFunction(.{ .native = fail }));
    const prepared = try request.prepare(&state, 0, 0, -2);
    var diagnostic: ?vm.Diagnostic = null;
    try equal(runtime.FailureKind.runtime_error, (try transport.callAdjusted(&state, prepared.arguments, prepared.results, true, prepared.handler, &diagnostic)).failure);
    try equal(@as(usize, 3), state.top());
    try equal(@as(f64, 42), state.get(1).?.numberValue().?);
    try expect(state.get(2).?.unpack().native == handled);
    try std.testing.expectEqualStrings("handled", state.get(3).?.unpack().string.bytes);
}
