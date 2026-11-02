//! `utf8` (manual 10.5): counting a byte string as UTF-8 characters. Reading
//! is strict by default (Unicode only, no surrogates) and `lax` admits what
//! Lua's decoder admits up to 0x7FFFFFFF; `utf8.char` writes that far. The
//! encoder is the core's (utf8.encode). `offset` answers two values, the
//! first and the last byte of the character, as Lua 5.5 does.
const std = @import("std");
const api = @import("c_api.zig");
const stdlib = @import("stdlib.zig");
const utf8 = @import("utf8.zig");

const Call = stdlib.Call;
const Error = stdlib.Error;
const entry = stdlib.entry;

const max_unicode: u32 = 0x10FFFF;
const max_utf: u32 = 0x7FFFFFFF;
pub const charpattern = "[\x00-\x7F\xC2-\xFD][\x80-\xBF]*";
const invalid = "invalid UTF-8 code";

pub fn open(call: Call) Error!void {
    try call.check(api.nilu_newtable(call.state));
    for ([_]stdlib.Registration{
        .{ .name = "char", .function = entry("char", char) },
        .{ .name = "codepoint", .function = entry("codepoint", codepoint) },
        .{ .name = "len", .function = entry("len", len) },
        .{ .name = "offset", .function = entry("offset", offset) },
        .{ .name = "codes", .function = entry("codes", codes) },
    }) |function| try stdlib.setField(call, function.name, function.function);
    try call.push("charpattern");
    try call.push(charpattern);
    try call.check(api.nilu_settable(call.state, -3));
    try call.check(api.nilu_setglobal(call.state, "utf8"));
}

fn isContinuation(byte: u8) bool {
    return byte & 0xC0 == 0x80;
}

/// Lua's utf8_decode: the code point at `start` and the index after it, or
/// null for a sequence that is malformed, overlong, or (strictly) outside
/// Unicode or a surrogate.
fn decode(text: []const u8, start: usize, strict: bool) ?struct { code: u32, next: usize } {
    const limits = [_]u32{ ~@as(u32, 0), 0x80, 0x800, 0x10000, 0x200000, 0x4000000 };
    const first = text[start];
    var result: u32 = 0;
    var count: usize = 0;
    if (first < 0x80) {
        result = first;
    } else {
        var c: u32 = first;
        while (c & 0x40 != 0) : (c <<= 1) {
            count += 1;
            if (start + count >= text.len) return null;
            const continuation = text[start + count];
            if (!isContinuation(continuation)) return null;
            result = (result << 6) | (continuation & 0x3F);
        }
        result |= (c & 0x7F) << @intCast(count * 5);
        if (count > 5 or result > max_utf or result < limits[count]) return null;
    }
    if (strict and (result > max_unicode or (result >= 0xD800 and result <= 0xDFFF))) return null;
    return .{ .code = result, .next = start + count + 1 };
}

fn char(call: Call) Error!c_int {
    const count = call.top();
    var buffer = try stdlib.Buffer.init(call, @intCast(count * 4));
    var index: c_int = 1;
    while (index <= count) : (index += 1) {
        const value = try call.checkInteger(index);
        if (value < 0 or value > max_utf) return call.argumentError(index, "value out of range");
        var bytes: [6]u8 = undefined;
        const encoded = utf8.encode(&bytes, @intCast(value)) catch return call.argumentError(index, "value out of range");
        try buffer.append(encoded);
    }
    try buffer.finish();
    return 1;
}

/// Lua's u_posrelat: a position relative to the end for a negative number.
fn relative(position: i64, length: usize) i64 {
    if (position >= 0) return position;
    if (-position > @as(i64, @intCast(length))) return 0;
    return @as(i64, @intCast(length)) + position + 1;
}

fn len(call: Call) Error!c_int {
    const text = try call.checkString(1);
    var start = relative(try call.optInteger(2, 1), text.len);
    var end = relative(try call.optInteger(3, -1), text.len);
    const lax = call.truthy(4);
    if (!(1 <= start and start - 1 <= @as(i64, @intCast(text.len)))) return call.argumentError(2, "initial position out of bounds");
    start -= 1;
    end -= 1;
    if (end >= @as(i64, @intCast(text.len))) return call.argumentError(3, "final position out of bounds");
    var count: i64 = 0;
    var position: usize = @intCast(start);
    while (@as(i64, @intCast(position)) <= end) {
        const decoded = decode(text, position, !lax) orelse {
            try call.pushNil();
            try call.pushInteger(@intCast(position + 1));
            return 2;
        };
        position = decoded.next;
        count += 1;
    }
    try call.pushInteger(@intCast(count));
    return 1;
}

fn codepoint(call: Call) Error!c_int {
    const text = try call.checkString(1);
    const first_argument = try call.optInteger(2, 1);
    const start = relative(first_argument, text.len);
    const end = relative(try call.optInteger(3, first_argument), text.len);
    const lax = call.truthy(4);
    if (start < 1) return call.argumentError(2, "out of bounds");
    if (end > @as(i64, @intCast(text.len))) return call.argumentError(3, "out of bounds");
    if (start > end) return 0;
    if (end - start >= std.math.maxInt(c_int)) return call.raise("string slice too long");
    var count: c_int = 0;
    var position: usize = @intCast(start - 1);
    while (@as(i64, @intCast(position)) < end) {
        const decoded = decode(text, position, !lax) orelse return call.raise(invalid);
        try call.pushInteger(@intCast(decoded.code));
        position = decoded.next;
        count += 1;
    }
    return count;
}

fn offset(call: Call) Error!c_int {
    const text = try call.checkString(1);
    var n = try call.checkInteger(2);
    const default: i64 = if (n >= 0) 1 else @as(i64, @intCast(text.len)) + 1;
    var position = relative(try call.optInteger(3, default), text.len);
    if (!(1 <= position and position - 1 <= @as(i64, @intCast(text.len)))) return call.argumentError(3, "position out of bounds");
    position -= 1;
    const length: i64 = @intCast(text.len);
    const at = struct {
        fn continuation(s: []const u8, i: i64) bool {
            return i >= 0 and i < s.len and isContinuation(s[@intCast(i)]);
        }
    };
    if (n == 0) {
        while (position > 0 and at.continuation(text, position)) position -= 1;
    } else {
        if (at.continuation(text, position)) return call.raise("initial position is a continuation byte");
        if (n < 0) {
            while (n < 0 and position > 0) {
                position -= 1;
                while (position > 0 and at.continuation(text, position)) position -= 1;
                n += 1;
            }
        } else {
            n -= 1;
            while (n > 0 and position < length) {
                position += 1;
                while (at.continuation(text, position)) position += 1;
                n -= 1;
            }
        }
    }
    if (n != 0) {
        try call.pushNil();
        return 1;
    }
    var last = position;
    while (at.continuation(text, last + 1)) last += 1;
    try call.pushInteger(@intCast(position + 1));
    try call.pushInteger(@intCast(last + 1));
    return 2;
}

fn codesStep(call: Call, strict: bool) Error!c_int {
    const text = try call.checkString(1);
    var position: usize = @intCast(@max(try call.checkInteger(2), 0));
    if (position < text.len) {
        while (position < text.len and isContinuation(text[position])) position += 1;
    }
    if (position >= text.len) return 0;
    const decoded = decode(text, position, strict) orelse return call.raise(invalid);
    if (decoded.next < text.len and isContinuation(text[decoded.next])) return call.raise(invalid);
    try call.pushInteger(@intCast(position + 1));
    try call.pushInteger(@intCast(decoded.code));
    return 2;
}
fn codesStrict(call: Call) Error!c_int {
    return codesStep(call, true);
}
fn codesLax(call: Call) Error!c_int {
    return codesStep(call, false);
}

fn codes(call: Call) Error!c_int {
    const text = try call.checkString(1);
    const lax = call.truthy(2);
    if (text.len > 0 and isContinuation(text[0])) return call.argumentError(1, invalid);
    try call.pushFunction(if (lax) entry("codes", codesLax) else entry("codes", codesStrict));
    try call.pushValue(1);
    try call.pushInteger(0);
    return 3;
}

comptime {
    std.debug.assert(charpattern.len == 14);
}
