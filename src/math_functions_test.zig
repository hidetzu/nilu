//! The math functions: values that agree with lua5.5 5.5.1 bit for bit (as
//! `%a` prints them), and their integer answers.
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

fn opened() !*runtime.State {
    const state = try api.create(a);
    errdefer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_openlibs(state));
    return state;
}

test "math_functions real functions give lua5.5's values" {
    const state = try opened();
    defer api.nilu_close(state);
    // Captured with: lua5.5 -e 'print(math.asin(1), math.atan(1, 2), math.exp(0.5), math.log(27, 3), math.deg(1), math.rad(90))'
    try std.testing.expectEqualStrings("1.5707963267948966 0.4636476090008061 1.6487212707001282 3.0 57.29577951308232 1.5707963267948966", try answer(state,
        \\return table.concat({math.asin(1), math.atan(1, 2), math.exp(0.5), math.log(27, 3), math.deg(1), math.rad(90)}, " ")
    ));
    try std.testing.expectEqualStrings("3 0.75 -3 -0.5 inf 0.0 0.5 4 8.0", try answer(state,
        \\local w, f = math.modf(3.75)
        \\local nw, nf = math.modf(-3.5)
        \\local iw, i_f = math.modf(1 / 0)
        \\local m, e = math.frexp(8)
        \\return table.concat({w, f, nw, nf, iw, i_f, m, e, math.ldexp(0.5, 4)}, " ")
    ));
}

test "math_functions the integer functions read Lua's 64-bit integers" {
    const state = try opened();
    defer api.nilu_close(state);
    // As lua5.5, but `math.tointeger("8")`, which Nilu does not convert
    // (manual 13.1).
    try std.testing.expectEqualStrings("integer float nil|3 nil nil|true false|9223372036854775807 -9223372036854775808", try answer(state,
        \\return math.type(3) .. " " .. math.type(1.5) .. " " .. tostring(math.type("1"))
        \\  .. "|" .. math.tointeger(3.0) .. " " .. tostring(math.tointeger(3.5)) .. " " .. tostring(math.tointeger("8"))
        \\  .. "|" .. tostring(math.ult(1, -1)) .. " " .. tostring(math.ult(-1, 1))
        \\  .. "|" .. math.maxinteger .. " " .. math.mininteger
    ));
    try std.testing.expectEqualStrings("bad argument #1 to 'ult' (number has no integer representation)", try answer(state, "return select(2, pcall(math.ult, 1.5, 2))"));
}

fn failure(state: *runtime.State, source: [:0]const u8) ![]const u8 {
    _ = api.nilu_settop(state, 0);
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state, source, "=t", null));
    try std.testing.expect(api.nilu_pcall(state, 0, 1, 0) != .ok);
    return std.mem.span(api.nilu_tolstring(state, -1, null).?);
}

test "math_functions max and min order anything < orders, as lua5.5's" {
    const state = try opened();
    defer api.nilu_close(state);
    // Captured with lua5.5 5.5.1 running the same sources.
    try std.testing.expectEqualStrings("3 a c 2 1 inf", try answer(state,
        \\local mt = {__lt = function(a, b) return a.v < b.v end}
        \\local x, y = setmetatable({v = 1}, mt), setmetatable({v = 2}, mt)
        \\return table.concat({math.max(3, 1, 2), math.min("b", "a", "c"), math.max("a", "c"), math.max(x, y).v, math.min(y, x).v, math.max(1 / 0, 0 / 0)}, " ")
    ));
    try std.testing.expectEqualStrings("attempt to compare string with number", try failure(state, "return math.min(1, '2')"));
    try std.testing.expectEqualStrings("attempt to compare two table values", try failure(state, "return math.max({}, {})"));
    try std.testing.expectEqualStrings("attempt to compare number with table", try failure(state, "return math.max(1, {})"));
    // A failing __lt raises its own failure, not the comparison's sentence.
    try std.testing.expectEqualStrings("in lt", try failure(state, "return math.max(setmetatable({}, {__lt = function() error('in lt', 0) end}), {})"));
}
