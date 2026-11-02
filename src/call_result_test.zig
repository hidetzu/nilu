const std = @import("std");
const allocation_failures = @import("allocation_failures.zig");
const runtime = @import("runtime.zig");
const transport = @import("failure_transport.zig");
const api = @import("c_api.zig");
const loader = @import("loader.zig");
const vm = @import("vm.zig");
const a = std.testing.allocator;
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
fn prepare(state: *runtime.State, source: []const u8) !*runtime.Closure {
    var diagnostic: ?loader.Diagnostic = null;
    return loader.prepare(state, source, "=result", &diagnostic);
}
fn two(state: *runtime.State) callconv(.c) c_int {
    if (api.nilu_pushnumber(state, 1) != .ok or api.nilu_pushnumber(state, 2) != .ok) return -1;
    return 2;
}
var calls: usize = 0;
fn observed(_: *runtime.State) callconv(.c) c_int {
    calls += 1;
    return 0;
}

test "call_result native and script results drop pad and preserve every result including nil" {
    for ([_]bool{ false, true }) |script| {
        for ([_]?usize{ 0, 1, 2, 4, null }) |requested| {
            var state = try runtime.State.init(a);
            defer state.deinit();
            try state.push(.from(.{ .number = 42 }));
            const function: runtime.Function = if (script) .{ .closure = try prepare(&state, "return 1,2") } else .{ .native = two };
            try state.push(.fromFunction(function));
            var diagnostic: ?vm.Diagnostic = null;
            const wanted = requested orelse 2;
            try equal(wanted, (try transport.callAdjusted(&state, 0, requested, true, null, &diagnostic)).success);
            try equal(wanted + 1, state.top());
            try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
            for (0..wanted) |i| {
                const value = state.get(@intCast(i + 2)).?;
                if (i < 2) try expect(value.equal(.from(.{ .number = @floatFromInt(i + 1) }))) else try expect(value.is(.nil));
                try expect(state.originAt(i + 1) == null);
            }
            try expect(state.failure == null);
            try expect(state.execution == null);
        }
    }
    var state = try runtime.State.init(a);
    defer state.deinit();
    try state.push(.fromFunction(.{ .closure = try prepare(&state, "return 1,nil,3,nil") }));
    var diagnostic: ?vm.Diagnostic = null;
    try equal(@as(usize, 4), (try transport.callAdjusted(&state, 0, null, false, null, &diagnostic)).success);
    try expect(state.get(2).?.is(.nil));
    try expect(state.get(4).?.is(.nil));
}

test "call_result excessive fixed request is rejected before function or handler side effects" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    try state.push(.fromFunction(.{ .native = observed }));
    try state.push(.from(.{ .number = 7 }));
    calls = 0;
    var diagnostic: ?vm.Diagnostic = null;
    for ([_]bool{ false, true }) |protected| {
        try std.testing.expectError(error.StackLimit, transport.callAdjusted(&state, 1, runtime.State.max_stack, protected, if (protected) .fromFunction(.{ .native = observed }) else null, &diagnostic));
        try equal(@as(usize, 0), calls);
        try equal(@as(usize, 3), state.top());
        try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
        try expect(state.get(2).?.unpack().native == observed);
        try expect(state.get(3).?.equal(.from(.{ .number = 7 })));
        try expect(state.execution == null);
        try expect(diagnostic == null);
    }
    try std.testing.expectError(error.StackLimit, transport.callAdjusted(&state, 1, std.math.maxInt(usize), false, null, &diagnostic));
}

test "call_result exact stack boundary fits after consuming the function slot" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try state.push(.fromFunction(.{ .native = two }));
    var diagnostic: ?vm.Diagnostic = null;
    try equal(runtime.State.max_stack, (try transport.callAdjusted(&state, 0, runtime.State.max_stack, false, null, &diagnostic)).success);
    try equal(runtime.State.max_stack, state.top());
    try expect(state.get(1).?.equal(.from(.{ .number = 1 })));
    try expect(state.get(2).?.equal(.from(.{ .number = 2 })));
    try expect(state.get(-1).?.is(.nil));
}

fn fail(state: *runtime.State) callconv(.c) c_int {
    if (api.nilu_pushstring(state, "boom") != .ok) return -1;
    return api.nilu_error(state);
}
test "call_result failures leave one carried value regardless of requested success count" {
    for ([_]?usize{ 0, 1, 4, null }) |requested| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        try state.push(.from(.{ .number = 42 }));
        try state.push(.fromFunction(.{ .native = fail }));
        var diagnostic: ?vm.Diagnostic = null;
        try equal(runtime.FailureKind.runtime_error, (try transport.callAdjusted(&state, 0, requested, true, null, &diagnostic)).failure);
        try equal(@as(usize, 2), state.top());
        try std.testing.expectEqualStrings("boom", state.get(-1).?.unpack().string.bytes);
        try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
    }
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var state = try runtime.State.init(allocator);
    defer state.deinit();
    const closure = try prepare(&state, "return {v=7},9");
    try state.push(.from(.{ .number = 42 }));
    try state.push(.fromFunction(.{ .closure = closure }));
    state.setCollectionThreshold(0);
    var diagnostic: ?vm.Diagnostic = null;
    const result = transport.callAdjusted(&state, 0, 100, true, null, &diagnostic) catch |err| {
        try equal(@as(usize, 2), state.top());
        try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
        try expect(state.get(2).?.unpack().closure == closure);
        try expect(state.execution == null);
        return err;
    };
    if (result == .failure) {
        try equal(runtime.FailureKind.out_of_memory, result.failure);
        try equal(@as(usize, 2), state.top());
        try expect(state.get(2).?.unpack().string == state.memory_failure);
        return error.OutOfMemory;
    }
    try equal(@as(usize, 100), result.success);
    try equal(@as(usize, 101), state.top());
    state.collect();
    try expect(state.get(2).?.unpack().table.getString("v").equal(.from(.{ .number = 7 })));
    try expect(state.get(3).?.equal(.from(.{ .number = 9 })));
    try expect(state.get(101).?.is(.nil));
    try expect(state.execution == null);
}
test "call_result all allocation failures preserve pre-call inputs or publish one memory failure" {
    try allocation_failures.checkAll(a, allocationCase, .{});
}
