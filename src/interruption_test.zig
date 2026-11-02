//! The hook's interruption reaches the host's call (the owner's answer): a
//! C function that ignores the interrupted status gets
//! no further call run and its return is replaced, and the host's next call
//! runs as usual.
const std = @import("std");
const api = @import("c_api.zig");
const runtime = @import("runtime.zig");
const a = std.testing.allocator;

var counter: usize = 0;
var inner_status: api.Status = .ok;
var later_status: api.Status = .ok;

fn stop(_: ?*runtime.State) callconv(.c) c_int {
    return 1;
}

fn counted(_: ?*runtime.State) callconv(.c) c_int {
    counter += 1;
    return 0;
}

fn ignoreStop(state: ?*runtime.State) callconv(.c) c_int {
    if (api.nilu_loadnamed(state, "while true do end", "=inner-stop", null) != .ok) return -1;
    inner_status = api.nilu_call(state, 0, 0);
    api.nilu_sethook(state, null, 0);
    if (api.nilu_pushcfunction(state, counted) != .ok) return -1;
    later_status = api.nilu_call(state, 0, 0);
    if (api.nilu_pushnumber(state, 7) != .ok) return -1;
    return 1;
}

test "interruption reaches the host however a C function in between answers it" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    counter = 0;
    api.nilu_sethook(state, stop, 1);
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushcfunction(state, ignoreStop));
    try std.testing.expectEqual(api.Status.interrupted, api.nilu_call(state, 0, 1));
    try std.testing.expectEqual(api.Status.interrupted, inner_status);
    try std.testing.expectEqual(api.Status.interrupted, later_status);
    try std.testing.expectEqual(@as(usize, 0), counter);
    try std.testing.expectEqual(@backingInt(api.Type.nil), api.nilu_type(state, -1));
    // Once the host's call has returned, the next one runs.
    try std.testing.expectEqual(api.Status.ok, api.nilu_settop(state, 0));
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushcfunction(state, counted));
    try std.testing.expectEqual(api.Status.ok, api.nilu_call(state, 0, 0));
    try std.testing.expectEqual(@as(usize, 1), counter);
}

var hook_depth: usize = 0;
var nested_status: api.Status = .ok;

/// Stops the instructions of an inner call it makes itself, then lets the
/// outer program go on: the recorded rule is that the callback's own answer
/// decides for the outer call.
fn stopInnerOnly(state: ?*runtime.State) callconv(.c) c_int {
    if (hook_depth > 0) return 1;
    hook_depth += 1;
    defer hook_depth -= 1;
    if (api.nilu_loadnamed(state, "while true do end", "=inner", null) != .ok) return 1;
    nested_status = api.nilu_call(state, 0, 0);
    api.nilu_sethook(state, null, 0);
    return 0;
}

test "interruption an inner call a hook callback stops leaves the outer program running" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_openlibs(state));
    api.nilu_sethook(state, stopInnerOnly, 1);
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state, "local s = tostring(5) return s .. '!'", "=outer", null));
    try std.testing.expectEqual(api.Status.ok, api.nilu_call(state, 0, 1));
    try std.testing.expectEqual(api.Status.interrupted, nested_status);
    try std.testing.expectEqualStrings("5!", std.mem.span(api.nilu_tolstring(state, -1, null).?));
}

var armed = false;

fn stopWhenArmed(_: ?*runtime.State) callconv(.c) c_int {
    return @intFromBool(armed);
}

/// Runs a loop the hook stops, ignores the interruption and returns a value
/// as if nothing had happened.
fn relayIgnoringStop(state: ?*runtime.State) callconv(.c) c_int {
    if (api.nilu_loadnamed(state, "while true do end", "=inner-stop", null) != .ok) return -1;
    armed = true;
    inner_status = api.nilu_call(state, 0, 0);
    armed = false;
    if (api.nilu_pushnumber(state, 7) != .ok) return -1;
    return 1;
}

test "interruption reaches the host through a script's call of a C function that wants one result" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    armed = false;
    api.nilu_sethook(state, stopWhenArmed, 1);
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushcfunction(state, relayIgnoringStop));
    try std.testing.expectEqual(api.Status.ok, api.nilu_setglobal(state, "relay"));
    // `local x = relay()` is a call that wants one result, into a local.
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state, "local x = relay() return x", "=outer", null));
    try std.testing.expectEqual(api.Status.interrupted, api.nilu_call(state, 0, 1));
    try std.testing.expectEqual(api.Status.interrupted, inner_status);
    try std.testing.expectEqual(@backingInt(api.Type.nil), api.nilu_type(state, -1));
}

var stops: usize = 0;

/// Stops at its third call. Called every 1000 instructions, it lets the few
/// instructions before a loop run, so the stop falls inside the loop.
fn stopThird(_: ?*runtime.State) callconv(.c) c_int {
    stops += 1;
    return @intFromBool(stops >= 3);
}

/// Runs `source` with the libraries open until the hook stops it inside its
/// endless loop: the host's protected call answers the interruption with nil,
/// and the host's next call runs.
fn interruptedRun(source: [*:0]const u8) !void {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_openlibs(state));
    stops = 0;
    api.nilu_sethook(state, stopThird, 1000);
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state, source, "=stopped", null));
    try std.testing.expectEqual(api.Status.interrupted, api.nilu_pcall(state, 0, 1, 0));
    try std.testing.expectEqual(@backingInt(api.Type.nil), api.nilu_type(state, -1));
    try std.testing.expectEqual(@as(usize, 3), stops);
    api.nilu_sethook(state, null, 0);
    try std.testing.expectEqual(api.Status.ok, api.nilu_settop(state, 0));
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state, "return 1 + 1", "=next", null));
    try std.testing.expectEqual(api.Status.ok, api.nilu_pcall(state, 0, 1, 0));
    try std.testing.expectEqual(@as(c_longlong, 2), api.nilu_tointegerx(state, -1, null));
}

// coroutine.resume and the function coroutine.wrap makes are C functions in
// between: the coroutine runs on its own thread, and its interruption still
// reaches the host's call, not as a failure the resume answers.
test "interruption inside a coroutine reaches the host's call" {
    try interruptedRun("local co = coroutine.create(function() while true do end end) local ok = coroutine.resume(co) return 'resumed'");
    try interruptedRun("coroutine.wrap(function() while true do end end)() return 'resumed'");
}

// A failure on its way to the host closes `<close>` variables first; when
// the hook stops a `__close` there, what reaches the host is the
// interruption, not the failure it was closing for.
test "interruption inside a __close that a failure runs reaches the host's call" {
    try interruptedRun("do local x <close> = setmetatable({}, {__close = function() while true do end end}) error('e') end");
}

// A host's own nilu_resume is the host's call: it answers the interruption,
// and the host's next call runs.
test "interruption a host's own resume answers leaves the next call running" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state, "while true do end", "=looping", null));
    try std.testing.expectEqual(api.Status.ok, api.nilu_newthread(state));
    stops = 0;
    api.nilu_sethook(state, stopThird, 1000);
    var count: c_int = 0;
    try std.testing.expectEqual(api.Status.interrupted, api.nilu_resume(state, 1, 0, &count));
    try std.testing.expectEqual(@as(usize, 3), stops);
    api.nilu_sethook(state, null, 0);
    try std.testing.expectEqual(api.Status.ok, api.nilu_settop(state, 0));
    // A C function's return is what an interruption left standing would
    // replace, so the next call is one.
    counter = 0;
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushcfunction(state, counted));
    try std.testing.expectEqual(api.Status.ok, api.nilu_call(state, 0, 0));
    try std.testing.expectEqual(@as(usize, 1), counter);
}
