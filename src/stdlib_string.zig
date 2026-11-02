//! `string` (manual 10.2): positions start at 1 and a negative one counts
//! from the end; a number is never turned into a string. Patterns, `format`
//! and `pack` live in their own files.
const std = @import("std");
const api = @import("c_api.zig");
const stdlib = @import("stdlib.zig");
const pattern = @import("pattern.zig");
const string_format = @import("string_format.zig");
const string_pack = @import("string_pack.zig");

const Call = stdlib.Call;
const Error = stdlib.Error;
const entry = stdlib.entry;

pub fn open(call: Call) Error!void {
    try stdlib.openTable(call, "string", &.{
        .{ .name = "len", .function = entry("len", length) },
        .{ .name = "sub", .function = entry("sub", sub) },
        .{ .name = "upper", .function = entry("upper", upper) },
        .{ .name = "lower", .function = entry("lower", lower) },
        .{ .name = "reverse", .function = entry("reverse", reverse) },
        .{ .name = "rep", .function = entry("rep", rep) },
        .{ .name = "byte", .function = entry("byte", byte) },
        .{ .name = "char", .function = entry("char", char) },
        .{ .name = "format", .function = entry("format", string_format.format) },
        .{ .name = "find", .function = entry("find", pattern.find) },
        .{ .name = "match", .function = entry("match", pattern.match) },
        .{ .name = "gmatch", .function = entry("gmatch", pattern.gmatch) },
        .{ .name = "gsub", .function = entry("gsub", pattern.gsub) },
        .{ .name = "pack", .function = entry("pack", string_pack.pack) },
        .{ .name = "unpack", .function = entry("unpack", string_pack.unpack) },
        .{ .name = "packsize", .function = entry("packsize", string_pack.packsize) },
    });
    // Every string shares {__index = string}, so `s:upper()` is
    // `string.upper(s)`, as in Lua (the owner's answer).
    try call.check(api.nilu_newtable(call.state));
    try call.push("__index");
    try call.check(api.nilu_getglobal(call.state, "string"));
    try call.check(api.nilu_settable(call.state, -3));
    try call.push("");
    try call.pushValue(-2);
    try call.check(api.nilu_setmetatable(call.state, -2));
    call.pop(2);
}

/// Lua's posrelatI: a start position, clamped into 1..len+1.
pub fn startPosition(position: i64, len: usize) usize {
    const signed: i64 = @intCast(len);
    if (position > 0) return @intCast(position);
    if (position == 0) return 1;
    if (position < -signed) return 1;
    return @intCast(signed + position + 1);
}
/// Lua's getendpos: an end position, clamped into 0..len.
pub fn endPosition(position: i64, len: usize) usize {
    const signed: i64 = @intCast(len);
    if (position > signed) return len;
    if (position >= 0) return @intCast(position);
    if (position < -signed) return 0;
    return @intCast(signed + position + 1);
}

fn length(call: Call) Error!c_int {
    const text = try call.checkString(1);
    try call.pushInteger(@intCast(text.len));
    return 1;
}

fn sub(call: Call) Error!c_int {
    const text = try call.checkString(1);
    const start = startPosition(try call.optInteger(2, 1), text.len);
    const end = endPosition(try call.optInteger(3, -1), text.len);
    if (start > end) {
        try call.push("");
    } else {
        try call.push(text[start - 1 .. end]);
    }
    return 1;
}

fn mapBytes(call: Call, comptime transform: fn (u8) u8) Error!c_int {
    const text = try call.checkString(1);
    var buffer = try stdlib.Buffer.init(call, text.len);
    try buffer.reserve(text.len);
    for (text) |value| try buffer.appendByte(transform(value));
    try buffer.finish();
    return 1;
}
fn upper(call: Call) Error!c_int {
    return mapBytes(call, std.ascii.toUpper);
}
fn lower(call: Call) Error!c_int {
    return mapBytes(call, std.ascii.toLower);
}
fn reverse(call: Call) Error!c_int {
    const text = try call.checkString(1);
    var buffer = try stdlib.Buffer.init(call, text.len);
    var index = text.len;
    while (index > 0) {
        index -= 1;
        try buffer.appendByte(text[index]);
    }
    try buffer.finish();
    return 1;
}

fn rep(call: Call) Error!c_int {
    const text = try call.checkString(1);
    const count = try call.checkInteger(2);
    const separator = try call.optString(3, "");
    if (count <= 0) {
        try call.push("");
        return 1;
    }
    const times: usize = @intCast(count);
    // Lua refuses a result that cannot be sized before it is built.
    const total = std.math.add(usize, std.math.mul(usize, text.len, times) catch return call.raise("resulting string too large"), std.math.mul(usize, separator.len, times - 1) catch return call.raise("resulting string too large")) catch return call.raise("resulting string too large");
    if (total > std.math.maxInt(usize) / 2) return call.raise("resulting string too large");
    var buffer = try stdlib.Buffer.init(call, total);
    var remaining = times;
    while (remaining > 0) : (remaining -= 1) {
        try buffer.append(text);
        if (remaining > 1) try buffer.append(separator);
    }
    try buffer.finish();
    return 1;
}

fn byte(call: Call) Error!c_int {
    const text = try call.checkString(1);
    const first = try call.optInteger(2, 1);
    const start = startPosition(first, text.len);
    const end = endPosition(try call.optInteger(3, first), text.len);
    if (start > end) return 0;
    const count = end - start + 1;
    if (count >= std.math.maxInt(c_int)) return call.raise("string slice too long");
    for (text[start - 1 .. end]) |value| try call.pushInteger(@intCast(value));
    return @intCast(count);
}

fn char(call: Call) Error!c_int {
    const count = call.top();
    var buffer = try stdlib.Buffer.init(call, @intCast(count));
    var index: c_int = 1;
    while (index <= count) : (index += 1) {
        const value = try call.checkInteger(index);
        if (value < 0 or value > 255) return call.argumentError(index, "value out of range");
        try buffer.appendByte(@intCast(value));
    }
    try buffer.finish();
    return 1;
}
