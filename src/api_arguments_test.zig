//! The C API's argument checks give the sentences Lua 5.5's luaL_check* give
//! for the same C functions (measured with a C probe against Lua 5.5.1),
//! except where Nilu does not convert a number to a string (ADR 0008) and
//! names a function nobody named '?' where Lua searches the globals.
const std = @import("std");
const api = @import("c_api.zig");
const runtime = @import("runtime.zig");
const a = std.testing.allocator;

fn rep(state: *runtime.State) callconv(.c) c_int {
    var text: [*:0]const u8 = undefined;
    var length: usize = 0;
    var count: c_longlong = 0;
    var separator: [*:0]const u8 = undefined;
    if (api.nilu_checklstring(state, 1, &text, &length) != 0) return api.fail;
    if (api.nilu_checkinteger(state, 2, &count) != 0) return api.fail;
    if (api.nilu_optlstring(state, 3, "", &separator, null) != 0) return api.fail;
    _ = api.nilu_pushstring(state, "ok");
    return 1;
}

fn any(state: *runtime.State) callconv(.c) c_int {
    var number: f64 = 0;
    if (api.nilu_checkany(state, 1) != 0) return api.fail;
    if (api.nilu_checktype(state, 2, @backingInt(api.Type.table)) != 0) return api.fail;
    if (api.nilu_optnumber(state, 3, 1.5, &number) != 0) return api.fail;
    _ = api.nilu_pushnumber(state, number);
    return 1;
}

fn arg(state: *runtime.State) callconv(.c) c_int {
    return api.nilu_argerror(state, 2, "custom detail");
}

fn answer(state: *runtime.State, source: [:0]const u8) ![]const u8 {
    _ = api.nilu_settop(state, 0);
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state, source, "=t", null));
    _ = api.nilu_pcall(state, 0, 1, 0);
    return std.mem.span(api.nilu_tolstring(state, -1, null) orelse "nil");
}

test "api_arguments refusals match Lua's luaL checks" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_openlibs(state));
    inline for (.{ .{ "rep", rep }, .{ "any", any }, .{ "arg", arg } }) |entry| {
        try std.testing.expectEqual(api.Status.ok, api.nilu_pushcfunction(state, entry[1]));
        try std.testing.expectEqual(api.Status.ok, api.nilu_setglobal(state, entry[0]));
    }
    const cases = .{
        .{ "return rep('a', 2)", "ok" },
        .{ "return rep('a', 2.5)", "t:1: bad argument #2 to 'rep' (number has no integer representation)" },
        .{ "return rep('a')", "t:1: bad argument #2 to 'rep' (number expected, got no value)" },
        .{ "return rep('a', 2, {})", "t:1: bad argument #3 to 'rep' (string expected, got table)" },
        .{ "return any()", "t:1: bad argument #1 to 'any' (value expected)" },
        .{ "return any(1, 2)", "t:1: bad argument #2 to 'any' (table expected, got number)" },
        .{ "return any(1, {})", "1.5" },
        .{ "return any(1, {}, 'x')", "t:1: bad argument #3 to 'any' (number expected, got string)" },
        .{ "return arg()", "t:1: bad argument #2 to 'arg' (custom detail)" },
        .{ "local t = {m = rep} return t:m(2)", "t:1: calling 'm' on bad self (string expected, got table)" },
        // Lua converts 1 to "1"; Nilu does not (ADR 0008).
        .{ "return rep(1, 2)", "t:1: bad argument #1 to 'rep' (string expected, got number)" },
        // Lua finds 'rep' among the globals; with no caller's name, Nilu says '?'.
        .{ "return select(2, pcall(rep, 'a'))", "bad argument #2 to '?' (number expected, got no value)" },
    };
    inline for (cases) |case| try std.testing.expectEqualStrings(case[1], try answer(state, case[0]));
}
