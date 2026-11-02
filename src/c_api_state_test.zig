//! nilu_newstate (the owner's answer): a state
//! lives in the host's memory, gives every block back when closed, and meets
//! the host's refusal as an ordinary memory failure.
const std = @import("std");
const api = @import("c_api.zig");
const runtime = @import("runtime.zig");
const stdlib = @import("stdlib.zig");
const c = @import("nilu-header");
const a = std.testing.allocator;

const Ledger = struct { blocks: isize = 0, bytes: isize = 0, budget: usize = std.math.maxInt(usize) };

fn hostAlloc(ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque {
    const ledger: *Ledger = @ptrCast(@alignCast(ud.?));
    if (nsize == 0) {
        if (ptr != null) {
            ledger.blocks -= 1;
            ledger.bytes -= @intCast(osize);
            std.c.free(ptr);
        }
        return null;
    }
    const grown = if (ptr == null) nsize else nsize -| osize;
    if (grown > ledger.budget) return null;
    const moved = std.c.realloc(ptr, nsize) orelse return null;
    ledger.budget -= grown;
    if (ptr == null) ledger.blocks += 1;
    ledger.bytes += @as(isize, @intCast(nsize)) - @as(isize, @intCast(if (ptr == null) 0 else osize));
    return moved;
}

test "host_allocator a state runs in the host's memory and gives every block back" {
    var ledger = Ledger{};
    const state = api.nilu_newstate(hostAlloc, &ledger) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(api.Status.ok, api.nilu_openlibs(state));
    try std.testing.expect(ledger.blocks > 0);
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state, "local t = {} for i = 1, 1000 do t[i] = {i} end collectgarbage() return #t", "=t", null));
    try std.testing.expectEqual(api.Status.ok, api.nilu_pcall(state, 0, 1, 0));
    try std.testing.expectEqual(@as(f64, 1000), api.nilu_tonumberx(state, -1, null));
    api.nilu_close(state);
    try std.testing.expectEqual(@as(isize, 0), ledger.blocks);
    try std.testing.expectEqual(@as(isize, 0), ledger.bytes);
}

test "host_allocator the host's refusal is a memory failure, or no state at all" {
    var none = Ledger{ .budget = 0 };
    try std.testing.expect(api.nilu_newstate(hostAlloc, &none) == null);
    try std.testing.expectEqual(@as(isize, 0), none.blocks);
    var ledger = Ledger{};
    const state = api.nilu_newstate(hostAlloc, &ledger) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(api.Status.ok, api.nilu_openlibs(state));
    ledger.budget = 64 * 1024;
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state, "local t = {} for i = 1, 1e6 do t[i] = {i} end", "=t", null));
    try std.testing.expectEqual(api.Status.memory, api.nilu_pcall(state, 0, 0, 0));
    ledger.budget = std.math.maxInt(usize);
    api.nilu_close(state);
    try std.testing.expectEqual(@as(isize, 0), ledger.blocks);
}

const Probe = struct {
    start: *std.atomic.Value(bool),
    offset: f64,
    failure: ?anyerror = null,

    fn run(probe: *Probe) void {
        while (!probe.start.load(.acquire)) std.atomic.spinLoopHint();
        probe.execute() catch |err| {
            probe.failure = err;
        };
    }

    fn execute(probe: *Probe) !void {
        // The internal constructor permits leak checking; subsequent operations
        // use the same public boundary as a C host. The testing allocator is
        // thread-safe in this multithreaded build.
        const state = try api.create(std.testing.allocator);
        defer api.nilu_close(state);
        try std.testing.expectEqual(api.Status.ok, api.nilu_openlibs(state));
        try std.testing.expectEqual(api.Status.ok, api.nilu_pushnumber(state, probe.offset));
        try std.testing.expectEqual(api.Status.ok, api.nilu_setglobal(state, "offset"));
        try std.testing.expectEqual(api.Status.ok, api.nilu_loadstring(state, "local t = {} for i = 1, 10000 do t[i] = i + offset end " ++
            "local sum = 0 for i = 1, #t do sum = sum + t[i] end return sum", null));
        try std.testing.expectEqual(api.Status.ok, api.nilu_call(state, 0, 1));
        var is_number: c_int = 0;
        const result = api.nilu_tonumberx(state, -1, &is_number);
        try std.testing.expectEqual(@as(c_int, 1), is_number);
        try std.testing.expectEqual(@as(f64, 50005000) + 10000 * probe.offset, result);
    }
};

test "state_threads separate states compute independent tables concurrently" {
    var start = std.atomic.Value(bool).init(false);
    var first = Probe{ .start = &start, .offset = 0 };
    var second = Probe{ .start = &start, .offset = 7 };
    const first_thread = try std.Thread.spawn(.{}, Probe.run, .{&first});
    const second_thread = std.Thread.spawn(.{}, Probe.run, .{&second}) catch |err| {
        start.store(true, .release);
        first_thread.join();
        return err;
    };
    start.store(true, .release);
    first_thread.join();
    second_thread.join();
    if (first.failure) |err| return err;
    if (second.failure) |err| return err;
}

// nilu_openselectedlibs (the owner's answer):
// only the libraries asked for, and the bits are the header's.
test "selected_libraries the bits are the header's" {
    try std.testing.expectEqual(@as(c_int, c.NILU_LIB_BASE), stdlib.Library.base);
    try std.testing.expectEqual(@as(c_int, c.NILU_LIB_PACKAGE), stdlib.Library.package);
    try std.testing.expectEqual(@as(c_int, c.NILU_LIB_COROUTINE), stdlib.Library.coroutine);
    try std.testing.expectEqual(@as(c_int, c.NILU_LIB_DEBUG), stdlib.Library.debug);
    try std.testing.expectEqual(@as(c_int, c.NILU_LIB_MATH), stdlib.Library.math);
    try std.testing.expectEqual(@as(c_int, c.NILU_LIB_STRING), stdlib.Library.string);
    try std.testing.expectEqual(@as(c_int, c.NILU_LIB_TABLE), stdlib.Library.table);
    try std.testing.expectEqual(@as(c_int, c.NILU_LIB_UTF8), stdlib.Library.utf8);
}

test "selected_libraries only the libraries asked for are opened" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_openselectedlibs(state, c.NILU_LIB_BASE | c.NILU_LIB_STRING));
    _ = api.nilu_settop(state, 0);
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state, "return type(string) .. type(math) .. type(table) .. type(coroutine) .. type(require) .. type(debug) .. ('a'):upper()", "=t", null));
    try std.testing.expectEqual(api.Status.ok, api.nilu_pcall(state, 0, 1, 0));
    try std.testing.expectEqualStrings("tablenilnilnilnilnilA", std.mem.span(api.nilu_tolstring(state, -1, null).?));
}
