//! The bitwise operators (the owner's answer): Lua 5.5's
//! answers on whole numbers, and Lua's sentence for an operand that is not a
//! whole number or a result past 2^53. The expected texts were taken from
//! lua5.5 running the same source, except where a result past 2^53 is refused.
const std = @import("std");
const api = @import("c_api.zig");
const runtime = @import("runtime.zig");
const a = std.testing.allocator;

fn answer(state: *runtime.State, source: [:0]const u8) ![]const u8 {
    _ = api.nilu_settop(state, 0);
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state, source, "=t", null));
    _ = api.nilu_pcall(state, 0, 1, 0);
    return std.mem.span(api.nilu_tolstring(state, -1, null).?);
}

fn opened() !*runtime.State {
    const state = try api.create(a);
    errdefer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_openlibs(state));
    return state;
}

test "bitwise operators give Lua's answers on whole numbers" {
    const state = try opened();
    defer api.nilu_close(state);
    const cases = .{
        .{ "return table.concat({5 & 3, 5 | 3, 5 ~ 3, ~5, 1 << 4, 256 >> 4}, ' ')", "1 7 6 -6 16 16" },
        .{ "return table.concat({1 << 64, 1 << -1, 2 >> -1, 3.0 & 1, 1 << 52, -(1 << 52)}, ' ')", "0 0 4 1 4503599627370496 -4503599627370496" },
        .{ "return table.concat({-1 & 0xFF, ~0, ~-1, 0xFF ~ 0x0F, ~~5, 1 >> 64, 8 >> -2}, ' ')", "255 -1 0 240 5 0 32" },
        // Precedence: | < ~ < & < shifts < .. < + - < unary < ^.
        .{ "return table.concat({1 | 2 ~ 3 & 4 << 1, 2 ^ 2 & 7, #'abc' << 1, 1 + 2 << 1, ~5 ~ 1}, ' ')", "3 4 6 6 -5" },
        .{ "return tostring(1 ~= 2) .. tostring(1 ~ 2)", "true3" },
    };
    inline for (cases) |case| try std.testing.expectEqualStrings(case[1], try answer(state, case[0]));
}

test "bitwise operators refuse what is not an integer, and answer in 64 bits" {
    const state = try opened();
    defer api.nilu_close(state);
    const cases = .{
        .{ "local x = 1.5 return x & 1", "t:1: number (local 'x') has no integer representation" },
        .{ "local y = 0.5 return 1 & y", "t:1: number (local 'y') has no integer representation" },
        .{ "return 1.5 | 1", "t:1: number has no integer representation" },
        .{ "local x = 2^63 return x & 1", "t:1: number (local 'x') has no integer representation" },
        .{ "local z = 0.5 return ~z", "t:1: number (local 'z') has no integer representation" },
        // In 64 bits, as Lua's answers.
        .{ "return 1 << 60", "1152921504606846976" },
        .{ "return -1 >> 1", "9223372036854775807" },
        .{ "return 8 >> -60", "-9223372036854775808" },
        .{ "local n = 2^53 return ~n", "-9007199254740993" },
    };
    inline for (cases) |case| try std.testing.expectEqualStrings(case[1], try answer(state, case[0]));
}

test "bitwise operators on other values are refused with Lua's words, after the metamethods" {
    const state = try opened();
    defer api.nilu_close(state);
    const cases = .{
        .{ "local t = {} return t & 1", "t:1: attempt to perform bitwise operation on a table value (local 't')" },
        .{ "return nil ~ 1", "t:1: attempt to perform bitwise operation on a nil value" },
        .{ "local s = 'a' return s << 1", "t:1: attempt to perform bitwise operation on a string value (local 's')" },
        .{ "return ~{}", "t:1: attempt to perform bitwise operation on a table value" },
        .{ "local t = {} return 1 >> t.y", "t:1: attempt to perform bitwise operation on a nil value (field 'y')" },
        .{ "return 3 & '1'", "t:1: attempt to perform bitwise operation on a string value (constant '1')" },
        .{
            \\local m = setmetatable({}, {__band = function() return 'band' end, __bor = function() return 'bor' end,
            \\  __bxor = function() return 'bxor' end, __shl = function() return 'shl' end,
            \\  __shr = function() return 'shr' end, __bnot = function() return 'bnot' end})
            \\return table.concat({m & 1, 1.5 | m, m ~ 2, 1 << m, m >> 1, ~m}, ' ')
            ,
            "band bor bxor shl shr bnot",
        },
    };
    inline for (cases) |case| try std.testing.expectEqualStrings(case[1], try answer(state, case[0]));
}
