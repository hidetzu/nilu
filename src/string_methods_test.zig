//! Every string shares one metatable, `{__index = string}` once the library
//! is open, so `s:upper()` is `string.upper(s)`.
const std = @import("std");
const api = @import("c_api.zig");
const runtime = @import("runtime.zig");
const a = std.testing.allocator;

fn answer(state: *runtime.State, source: [:0]const u8) ![]const u8 {
    _ = api.nilu_settop(state, 0);
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state, source, "=t", null));
    try std.testing.expectEqual(api.Status.ok, api.nilu_call(state, 0, 1));
    return std.mem.span(api.nilu_tolstring(state, -1, null).?);
}

test "string_methods a string calls the string table's functions with a colon" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_openlibs(state));
    try std.testing.expectEqualStrings("HELLO|xxx|a;b|3 items|true|nil|nil", try answer(state,
        \\local s = "Hello"
        \\local swapped = ("a,b"):gsub(",", ";")
        \\return s:upper() .. "|" .. ("x"):rep(3) .. "|" .. swapped .. "|" .. ("%d items"):format(3)
        \\  .. "|" .. tostring(getmetatable("").__index == string)
        \\  .. "|" .. tostring(("abc")[1]) .. "|" .. tostring(("abc")[true])
    ));
}

test "string_methods a missing method and a library left closed are failures that name them" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    // Before the library is open a string has no metatable at all.
    _ = api.nilu_settop(state, 0);
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state, "local s = 'x' return s:upper()", "=t", null));
    try std.testing.expectEqual(api.Status.type, api.nilu_call(state, 0, 1));
    try std.testing.expectEqualStrings("t:1: attempt to index a string value (local 's')", std.mem.span(api.nilu_tolstring(state, -1, null).?));
    try std.testing.expectEqual(api.Status.ok, api.nilu_openlibs(state));
    try std.testing.expectEqualStrings("t:1: attempt to call a nil value (method 'nosuch')", try answer(state, "return select(2, pcall(function() return ('x'):nosuch() end))"));
}

test "string_methods the C API reads and replaces the metatable strings share" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_openlibs(state));
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushstring(state, "any"));
    try std.testing.expectEqual(api.Status.ok, api.nilu_getmetatable(state, -1));
    try std.testing.expectEqual(@as(c_int, @backingInt(api.Type.table)), api.nilu_type(state, -1));
    try std.testing.expectEqual(api.Status.ok, api.nilu_getmetafield(state, 1, "__index"));
    try std.testing.expectEqual(@as(c_int, @backingInt(api.Type.table)), api.nilu_type(state, -1));
    // A host's metatable for one string is the metatable of every string.
    _ = api.nilu_settop(state, 0);
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state, "return function(s, k) return 'host' end", "=h", null));
    try std.testing.expectEqual(api.Status.ok, api.nilu_call(state, 0, 1));
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushstring(state, "x"));
    try std.testing.expectEqual(api.Status.ok, api.nilu_newtable(state));
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushstring(state, "__index"));
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushvalue(state, 1));
    try std.testing.expectEqual(api.Status.ok, api.nilu_settable(state, -3));
    try std.testing.expectEqual(api.Status.ok, api.nilu_setmetatable(state, 2));
    // Only the state holds the metatable and its function now.
    _ = api.nilu_settop(state, 0);
    state.collect();
    try std.testing.expectEqualStrings("host host", try answer(state, "return ('y').anything .. ' ' .. ('z').field"));
}
