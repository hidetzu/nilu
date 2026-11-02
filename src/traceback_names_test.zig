//! What a traceback says a function is (the owner's answer):
//! nilu_callername answers the name the function at a level was called by,
//! nilu_linedefined the line of its `function`, both counted as nilu_where counts.
const std = @import("std");
const api = @import("c_api.zig");
const runtime = @import("runtime.zig");
const a = std.testing.allocator;

var seen: [512]u8 = undefined;
var seen_length: usize = 0;

/// Writes "namewhat name line" for every level, then "|".
fn describe(state: *runtime.State) void {
    var level: c_int = 1;
    while (api.nilu_where(state, level, null) != null) : (level += 1) {
        var namewhat: [*:0]const u8 = "";
        const name = api.nilu_callername(state, level, &namewhat);
        const written = std.fmt.bufPrint(seen[seen_length..], "{s} {s} {d};", .{ std.mem.span(namewhat), if (name) |n| std.mem.span(n) else "-", api.nilu_linedefined(state, level) }) catch return;
        seen_length += written.len;
    }
    if (seen_length < seen.len) {
        seen[seen_length] = '|';
        seen_length += 1;
    }
}

fn trace(state: *runtime.State) callconv(.c) c_int {
    describe(state);
    return 0;
}

fn handler(state: *runtime.State) callconv(.c) c_int {
    describe(state);
    return 1;
}

fn opened() !*runtime.State {
    const state = try api.create(a);
    errdefer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_openlibs(state));
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushcfunction(state, trace));
    try std.testing.expectEqual(api.Status.ok, api.nilu_setglobal(state, "trace"));
    seen_length = 0;
    return state;
}

test "traceback_names a script function is named by its call, else by the line it was defined on" {
    const state = try opened();
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state,
        \\local function inner() trace() end
        \\local t = {run = function() inner() end}
        \\t.run()
        \\local o = {go = function(self) trace() end}
        \\o:go()
        \\;(function() trace() end)()
    , "=t", null));
    try std.testing.expectEqual(api.Status.ok, api.nilu_call(state, 0, 0));
    try std.testing.expectEqualStrings(
        "upvalue inner 1;field run 2; - 0;|" ++
            "method go 4; - 0;|" ++
            " - 6; - 0;|",
        seen[0..seen_length],
    );
}

test "traceback_names a handler sees the failing native by the name it was called by" {
    const state = try opened();
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushcfunction(state, handler));
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state, "local function f() error('x') end f()", "=t", null));
    try std.testing.expectEqual(api.Status.runtime, api.nilu_pcall(state, 0, 0, 1));
    try std.testing.expectEqualStrings("global error -1;local f 1; - 0;|", seen[0..seen_length]);
}

test "traceback_names a level with no function answers no name and -1" {
    const state = try opened();
    defer api.nilu_close(state);
    var namewhat: [*:0]const u8 = "unset";
    try std.testing.expect(api.nilu_callername(state, 1, &namewhat) == null);
    try std.testing.expectEqualStrings("", std.mem.span(namewhat));
    try std.testing.expect(api.nilu_callername(state, -1, null) == null);
    try std.testing.expectEqual(@as(c_int, -1), api.nilu_linedefined(state, 0));
    try std.testing.expectEqual(@as(c_int, -1), api.nilu_linedefined(state, 3));
}
