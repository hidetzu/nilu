//! string.format's float conversions against answers captured from Lua 5.5
//! (tools/capture-format.lua): C's rounding of the exact binary value, %g,
//! %a and the flags, byte for byte.
const std = @import("std");
const api = @import("c_api.zig");
const a = std.testing.allocator;

test "string_format float conversions agree with captured Lua answers" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_openlibs(state));
    var lines = std.mem.tokenizeScalar(u8, @embedFile("lua55-format"), '\n');
    var rows: usize = 0;
    var format_text: [32]u8 = undefined;
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const bits = try std.fmt.parseInt(u64, fields.next().?, 16);
        const format = fields.next().?;
        const expected = fields.next().?;
        _ = api.nilu_settop(state, 0);
        try std.testing.expectEqual(api.Status.ok, api.nilu_getglobal(state, "string"));
        try std.testing.expectEqual(api.Status.ok, api.nilu_pushstring(state, "format"));
        try std.testing.expectEqual(api.Status.ok, api.nilu_gettable(state, -2));
        @memcpy(format_text[0..format.len], format);
        format_text[format.len] = 0;
        try std.testing.expectEqual(api.Status.ok, api.nilu_pushstring(state, @ptrCast(&format_text)));
        try std.testing.expectEqual(api.Status.ok, api.nilu_pushnumber(state, @bitCast(bits)));
        try std.testing.expectEqual(api.Status.ok, api.nilu_call(state, 2, 1));
        const written = std.mem.span(api.nilu_tolstring(state, -1, null).?);
        std.testing.expectEqualStrings(expected, written) catch |err| {
            std.debug.print("value bits {x}, format {s}\n", .{ bits, format });
            return err;
        };
        rows += 1;
    }
    try std.testing.expect(rows != 0);
    std.debug.print("format fixture: {d} Lua answers agree\n", .{rows});
}

fn answer(state: *@import("runtime.zig").State, source: [:0]const u8) ![]const u8 {
    _ = api.nilu_settop(state, 0);
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state, source, "=t", null));
    try std.testing.expectEqual(api.Status.ok, api.nilu_call(state, 0, 1));
    return std.mem.span(api.nilu_tolstring(state, -1, null).?);
}

test "string_format %q writes values that read back" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_openlibs(state));
    // The string as lua5.5 quotes it: a newline as backslash-newline, a
    // control byte in decimal (three digits before a digit), others as they are.
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\\n\\13\\0z\\0001\\1x\\127\xc8\"", try answer(state, "return string.format('%q', 'a\"b\\\\c\\n\\r\\0z\\0001\\1x\\127\\200')"));
    // lua5.5's answers: a float is always written in hexadecimal.
    try std.testing.expectEqualStrings("3|-0x0p+0|0x1.8p+0|1e9999|-1e9999|(0/0)|0x1p+60|nil|true", try answer(state,
        \\return string.format("%q|%q|%q|%q|%q|%q|%q|%q|%q", 3, -0.0, 1.5, 1/0, -1/0, 0/0, 2^60, nil, true)
    ));
    try std.testing.expectEqualStrings("true true", try answer(state,
        \\local text = string.format("return %q, %q", "line\n\"two\"\0end", 1/3)
        \\local s, n = load(text)()
        \\return tostring(s == "line\n\"two\"\0end") .. " " .. tostring(n == 1/3)
    ));
    try std.testing.expectEqualStrings("bad argument #2 to 'format' (value has no literal form)|specifier '%q' cannot have modifiers", try answer(state,
        \\return select(2, pcall(string.format, "%q", {})) .. "|" .. select(2, pcall(string.format, "%5q", "x"))
    ));
}

// lua5.5's answers (the owner's answer): %u, %o and %x
// read the integer's 64 bits as unsigned, and %c writes its low byte.
test "string_format %u and %c take every integer as lua5.5 does" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_openlibs(state));
    try std.testing.expectEqualStrings("18446744073709551615 9223372036854775808     3 4    | 00007 ffffffffffffffff 1777777777777777777777", try answer(state,
        \\return string.format("%u %u %5u %-5u| %05u %x %o", -1, math.mininteger, 3, 4, 7, -1, -1)
    ));
    try std.testing.expectEqualStrings(",|255|A|B|    A|B  |", try answer(state,
        \\return string.format("%c", 300) .. "|" .. string.format("%c", -1):byte() .. "|" .. string.format("%c", 256 + 65)
        \\  .. "|" .. string.format("%c", 2^40 + 66) .. "|" .. string.format("%5c|%-3c|", 65, 66)
    ));
}
