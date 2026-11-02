//! The three kinds of function are separate tags of a value; a program still
//! sees one type, `function`, in `type()`, in failure messages and in raw
//! equality.
const std = @import("std");
const api = @import("c_api.zig");
const runtime = @import("runtime.zig");
const a = std.testing.allocator;

test "value_layout a script function, a native and a C closure are each a function" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_openlibs(state));
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadstring(state,
        \\local out = {}
        \\local it = string.gmatch("a", "a")
        \\for _, f in ipairs({function() end, type, it}) do
        \\  local ok, m = pcall(function() return #f end)
        \\  out[#out + 1] = type(f) .. ":" .. m .. ":" .. tostring(f == f)
        \\end
        \\return table.concat(out, "|"), function() end, type, it
    , null));
    try std.testing.expectEqual(api.Status.ok, api.nilu_call(state, 0, 4));
    const line = "[string \"local out = {}...\"]:4: attempt to get length of a function value (upvalue 'f')";
    try std.testing.expectEqualStrings("function:" ++ line ++ ":true|function:" ++ line ++ ":true|function:" ++ line ++ ":true", std.mem.span(api.nilu_tolstring(state, -4, null).?));
    // The script really produced one value of each kind.
    try std.testing.expect(state.get(-3).?.is(.closure));
    try std.testing.expect(state.get(-2).?.is(.native));
    try std.testing.expect(state.get(-1).?.is(.c_closure));
    for ([_]c_int{ -3, -2, -1 }) |index| try std.testing.expectEqual(@as(c_int, @backingInt(api.Type.function)), api.nilu_type(state, index));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(runtime.Value));
}

test "value_layout an instruction stays within 256 bytes" {
    // The frame loop indexes instructions on every step; 264 bytes cost two
    // more machine instructions per step than 256.
    try std.testing.expect(@sizeOf(@import("bytecode.zig").Instruction) <= 256);
}

test "value_layout NaN bits are kept except for a negative NaN in the tag range" {
    // ADR 0007: every positive NaN and every negative
    // NaN whose bits 48-50 are zero keeps its bits; a negative NaN with any of
    // them set (top 16 bits 0xFFF9-0xFFFF) becomes the negative quiet NaN
    // 0xFFF8000000000000, and is still a number, unequal to itself.
    const state = try api.create(a);
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_openlibs(state));
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadstring(state,
        \\local function hex(s) local out = "" for i = 1, #s do out = out .. string.format("%02x", string.byte(s, i)) end return out end
        \\local out = {}
        \\out[#out + 1] = hex(string.pack("<d", 0/0)) .. "," .. hex(string.pack("<d", -(0/0)))
        \\local payload = string.unpack("<d", "\1\0\0\0\0\0\248\127")
        \\local negative = string.unpack("<d", "\1\0\0\0\0\0\248\255")
        \\local tagged = string.unpack("<d", "\1\0\0\0\0\0\249\255")
        \\local top = string.unpack("<d", "\255\255\255\255\255\255\255\255")
        \\out[#out + 1] = hex(string.pack("<d", payload)) .. "," .. hex(string.pack("<d", negative)) .. "," .. hex(string.pack("<d", tagged)) .. "," .. hex(string.pack("<d", top))
        \\local t = {payload, tagged}
        \\out[#out + 1] = hex(string.pack("<d", t[1])) .. "," .. hex(string.pack("<d", t[2])) .. "," .. type(t[2]) .. "," .. tostring(t[2] == t[2])
        \\return table.concat(out, "|")
    , null));
    try std.testing.expectEqual(api.Status.ok, api.nilu_call(state, 0, 1));
    try std.testing.expectEqualStrings("000000000000f8ff,000000000000f87f|010000000000f87f,010000000000f8ff,000000000000f8ff,000000000000f8ff|010000000000f87f,000000000000f8ff,number,false", std.mem.span(api.nilu_tolstring(state, -1, null).?));
}

test "value_layout negating a positive NaN in the tag range gives the canonical NaN" {
    // Negation flips the sign bit and quiets nothing, so a positive NaN whose
    // bits 48-50 are set would land in the tag range; it is checked like any
    // number made outside arithmetic (ADR 0007). Arithmetic keeps the payload.
    const state = try api.create(a);
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_openlibs(state));
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadstring(state,
        \\local function hex(s) local out = "" for i = 1, #s do out = out .. string.format("%02x", string.byte(s, i)) end return out end
        \\local p = string.unpack("<d", "\1\0\0\0\0\0\249\127")
        \\local n = -p
        \\return hex(string.pack("<d", n)) .. "," .. type(n) .. "," .. tostring(n == n) .. "," .. hex(string.pack("<d", p + 1))
    , null));
    try std.testing.expectEqual(api.Status.ok, api.nilu_call(state, 0, 1));
    try std.testing.expectEqualStrings("000000000000f8ff,number,false,010000000000f97f", std.mem.span(api.nilu_tolstring(state, -1, null).?));
}
