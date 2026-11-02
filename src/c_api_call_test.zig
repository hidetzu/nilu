const std = @import("std");
const allocation_failures = @import("allocation_failures.zig");
const runtime = @import("runtime.zig");
const api = @import("c_api.zig");
const a = std.testing.allocator;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
extern fn test_public_relay(*runtime.State) callconv(.c) c_int;
extern fn test_public_handler(*runtime.State) callconv(.c) c_int;
extern fn test_public_catch(*runtime.State) callconv(.c) c_int;
extern fn test_public_reset_handlers() callconv(.c) void;
extern fn test_public_handler_count() callconv(.c) c_int;
fn load(state: *runtime.State, source: [*:0]const u8) !void {
    try equal(api.Status.ok, api.nilu_loadnamed(state, source, "=public-call", null));
}
fn pair(state: *runtime.State) callconv(.c) c_int {
    if (api.nilu_pushnumber(state, 8) != .ok) return -1;
    if (api.nilu_pushnumber(state, 9) != .ok) return -1;
    return 2;
}
fn bare(_: *runtime.State) callconv(.c) c_int {
    return -1;
}
fn stop(_: *runtime.State) callconv(.c) c_int {
    return 1;
}
test "c_api_call native and script fixed all and zero results preserve caller prefix" {
    for ([_]bool{ false, true }) |protected| for ([_]bool{ false, true }) |script| for ([_]c_int{ -1, 0, 1, 4 }) |wanted| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        try equal(api.Status.ok, api.nilu_pushnumber(&state, 42));
        if (script) try load(&state, "return 8,9") else try equal(api.Status.ok, api.nilu_pushcfunction(&state, pair));
        try equal(api.Status.ok, if (protected) api.nilu_pcall(&state, 0, wanted, 0) else api.nilu_call(&state, 0, wanted));
        const count: c_int = if (wanted == -1) 2 else wanted;
        try equal(count + 1, api.nilu_gettop(&state));
        try equal(@as(f64, 42), api.nilu_tonumberx(&state, 1, null));
        if (count > 0) try equal(@as(f64, 8), api.nilu_tonumberx(&state, 2, null));
        if (count > 1) try equal(@as(f64, 9), api.nilu_tonumberx(&state, 3, null));
        if (count > 2) try equal(@backingInt(api.Type.nil), api.nilu_type(&state, 4));
        try expect(state.execution == null and state.failure == null);
    };
}
test "c_api_call actual C relay copy fresh raise caught raise and bare failure retain distinct statuses" {
    for ([_]bool{ false, true }) |closure| {
        for (0..5) |mode| {
            var state = try runtime.State.init(a);
            defer state.deinit();
            try equal(api.Status.ok, api.nilu_pushnumber(&state, 42));
            if (closure) {
                try equal(api.Status.ok, api.nilu_pushnumber(&state, 7));
                try equal(api.Status.ok, api.nilu_pushcclosure(&state, test_public_relay, 1));
            } else try equal(api.Status.ok, api.nilu_pushcfunction(&state, test_public_relay));
            try load(&state, "return 1+nil");
            try equal(api.Status.ok, api.nilu_pushnumber(&state, @floatFromInt(mode)));
            const wanted = if (mode < 2) api.Status.type else .runtime;
            try equal(wanted, api.nilu_call(&state, 2, 0));
            try equal(@as(c_int, 2), api.nilu_gettop(&state));
            try equal(@as(f64, 42), api.nilu_tonumberx(&state, 1, null));
            if (mode == 4) try equal(@backingInt(api.Type.nil), api.nilu_type(&state, -1));
            if (mode < 2) {
                state.collect();
                var where: api.ErrorLocation = undefined;
                try std.testing.expectEqualStrings("public-call", std.mem.span(api.nilu_where(&state, 0, &where).?));
                try equal(@as(c_int, 1), where.line);
            }
            try expect(state.originAt(1) != null);
            try equal(@as(usize, 0), state.frames.items.len);
        }
    }
}
test "c_api_call actual C pre-unwind handlers support positive negative indices and caught isolation" {
    for ([_]c_int{ 2, -2 }) |index| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        try equal(api.Status.ok, api.nilu_pushnumber(&state, 42));
        try equal(api.Status.ok, api.nilu_pushcfunction(&state, test_public_handler));
        try load(&state, "return 1+nil");
        test_public_reset_handlers();
        try equal(api.Status.type, api.nilu_pcall(&state, 0, 4, index));
        try equal(@as(c_int, 1), test_public_handler_count());
        try equal(@as(c_int, 3), api.nilu_gettop(&state));
        try std.testing.expectEqualStrings("handled", state.get(-1).?.unpack().string.bytes);
        try expect(state.originAt(2) == null and state.failure == null);
        try equal(api.Status.ok, api.nilu_settop(&state, 2));
        try equal(api.Status.ok, api.nilu_pushcfunction(&state, test_public_catch));
        test_public_reset_handlers();
        try equal(api.Status.ok, api.nilu_pcall(&state, 0, 0, 2));
        try equal(@as(c_int, 0), test_public_handler_count());
    }
}
test "c_api_call failure is one value and protected capture clears relay origin" {
    for ([_]bool{ false, true }) |protected| for ([_]c_int{ -1, 0, 4 }) |wanted| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        try equal(api.Status.ok, api.nilu_pushcfunction(&state, bare));
        try equal(api.Status.runtime, if (protected) api.nilu_pcall(&state, 0, wanted, 0) else api.nilu_call(&state, 0, wanted));
        try equal(@as(c_int, 1), api.nilu_gettop(&state));
        try equal(@backingInt(api.Type.nil), api.nilu_type(&state, -1));
        try expect((state.originAt(0) == null) == protected);
    };
}
test "c_api_call setup Stack and Memory preserve inputs and never execute target" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try load(&state, "side_effect=1 return 8");
    const target = state.get(1).?;
    for ([_]bool{ false, true }) |protected| {
        try equal(api.Status.stack, if (protected) api.nilu_pcall(&state, 0, 1_000_001, 0) else api.nilu_call(&state, 0, 1_000_001));
        try equal(@as(c_int, 1), api.nilu_gettop(&state));
        try expect(state.get(1).?.equal(target));
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
        state.allocator = failing.allocator();
        const status = if (protected) api.nilu_pcall(&state, 0, 10000, 0) else api.nilu_call(&state, 0, 10000);
        state.allocator = a;
        try equal(api.Status.memory, status);
        try expect(state.get(1).?.equal(target));
        try expect(state.globals.getString("side_effect").is(.nil));
    }
}
test "c_api_call Interrupted bypasses capture and registered handler" {
    for ([_]bool{ false, true }) |protected| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        try equal(api.Status.ok, api.nilu_pushcfunction(&state, test_public_handler));
        try load(&state, "while true do end");
        test_public_reset_handlers();
        api.nilu_sethook(&state, stop, 1);
        try equal(api.Status.interrupted, if (protected) api.nilu_pcall(&state, 0, 0, 1) else api.nilu_call(&state, 0, 0));
        try equal(@as(c_int, 0), test_public_handler_count());
        try expect(state.get(-1).?.is(.nil) and state.failure.?.kind == .interrupted);
        try expect(state.originAt(1) != null);
    }
}
fn allocationCase(allocator: std.mem.Allocator) !void {
    var state = try runtime.State.init(allocator);
    defer state.deinit();
    if (api.nilu_pushnumber(&state, 42) == .memory) return error.OutOfMemory;
    const loaded = api.nilu_loadnamed(&state, "local t={} return 1+nil", "=allocation", null);
    if (loaded == .memory) return error.OutOfMemory;
    try equal(api.Status.ok, loaded);
    const result = api.nilu_pcall(&state, 0, 4, 0);
    try equal(@as(f64, 42), api.nilu_tonumberx(&state, 1, null));
    try expect(state.execution == null and state.frames.items.len == 0);
    if (result == .memory) return error.OutOfMemory;
    try equal(api.Status.type, result);
    try equal(@as(c_int, 2), api.nilu_gettop(&state));
    state.collect();
}
test "c_api_call every allocation failure cleans public load and protected execution" {
    try allocation_failures.checkAll(a, allocationCase, .{});
}

test "c_api_call public C handler runs at frame 201 and handler failure preserves original location" {
    for ([_]bool{ false, true }) |fails| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        try equal(api.Status.ok, api.nilu_pushcfunction(&state, if (fails) bare else test_public_handler));
        try load(&state, "local function f(n) if n==0 then return 1+nil end local x=f(n-1) return x end local x=f(198) return x");
        test_public_reset_handlers();
        try equal(if (fails) api.Status.runtime else .type, api.nilu_pcall(&state, 0, 0, 1));
        if (fails) try expect(state.get(-1).?.unpack().string == state.handling_failure) else try equal(@as(c_int, 1), test_public_handler_count());
        var where: api.ErrorLocation = undefined;
        try std.testing.expectEqualStrings("public-call", std.mem.span(api.nilu_where(&state, 0, &where).?));
        try equal(@as(c_int, 1), where.line);
        try equal(@as(usize, 200), state.callLimit());
        try expect(state.execution == null and state.frames.items.len == 0);
    }
}

fn memoryCall(state: *runtime.State) callconv(.c) c_int {
    if (api.nilu_pushcfunction(state, pair) != .ok) return -2;
    var failing = std.testing.FailingAllocator.init(state.allocator, .{ .fail_index = 0 });
    const allocator = state.allocator;
    state.allocator = failing.allocator();
    const status = api.nilu_call(state, 0, 10000);
    state.allocator = allocator;
    if (status != .memory) return -2;
    return -1;
}
test "c_api_call nested setup Memory notifies the native entry and skips its handler" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try equal(api.Status.ok, api.nilu_pushcfunction(&state, test_public_handler));
    try equal(api.Status.ok, api.nilu_pushcfunction(&state, memoryCall));
    test_public_reset_handlers();
    try equal(api.Status.memory, api.nilu_pcall(&state, 0, 0, 1));
    try expect(state.get(-1).?.unpack().string == state.memory_failure);
    try equal(@as(c_int, 0), test_public_handler_count());
    try expect(state.execution == null and state.failure == null);
}
