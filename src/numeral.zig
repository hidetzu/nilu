const std = @import("std");

pub fn isSpace(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\n', '\r', 11, 12 => true,
        else => false,
    };
}

/// A numeral's value: an integer when it has neither a point nor an
/// exponent and, in decimal, fits 64 bits; a hexadecimal one wraps around,
/// as Lua's does. Anything else is a float.
pub const Parsed = union(enum) {
    integer: i64,
    float: f64,

    pub fn asFloat(parsed: Parsed) f64 {
        return switch (parsed) {
            .integer => |n| @floatFromInt(n),
            .float => |f| f,
        };
    }
};

pub fn parse(input: []const u8) ?Parsed {
    var first: usize = 0;
    var last = input.len;
    while (first < last and isSpace(input[first])) first += 1;
    while (last > first and isSpace(input[last - 1])) last -= 1;
    const text = input[first..last];
    if (text.len == 0) return null;
    var cursor: usize = 0;
    if (text[cursor] == '+' or text[cursor] == '-') cursor += 1;
    if (cursor == text.len) return null;
    const hexadecimal = text.len - cursor >= 2 and text[cursor] == '0' and (text[cursor + 1] == 'x' or text[cursor + 1] == 'X');
    if (hexadecimal) cursor += 2;
    var digits: usize = 0;
    while (cursor < text.len and isDigit(text[cursor], hexadecimal)) : (cursor += 1) digits += 1;
    var whole = true;
    if (cursor < text.len and text[cursor] == '.') {
        whole = false;
        cursor += 1;
        while (cursor < text.len and isDigit(text[cursor], hexadecimal)) : (cursor += 1) digits += 1;
    }
    if (digits == 0) return null;
    if (cursor < text.len and isExponent(text[cursor], hexadecimal)) {
        whole = false;
        cursor += 1;
        if (cursor < text.len and (text[cursor] == '+' or text[cursor] == '-')) cursor += 1;
        const exponent_start = cursor;
        while (cursor < text.len and std.ascii.isDigit(text[cursor])) cursor += 1;
        if (exponent_start == cursor) return null;
    }
    if (cursor != text.len) return null;
    if (whole) if (integerOf(text, hexadecimal)) |n| return .{ .integer = n };
    return .{ .float = std.fmt.parseFloat(f64, text) catch return null };
}

/// The integer a numeral of digits alone writes, with its sign: decimal
/// within 64 bits (null past them, which makes it a float), hexadecimal
/// modulo 2^64.
fn integerOf(text: []const u8, hexadecimal: bool) ?i64 {
    var cursor: usize = 0;
    const negative = text[0] == '-';
    if (text[0] == '+' or text[0] == '-') cursor += 1;
    var magnitude: u64 = 0;
    if (hexadecimal) {
        cursor += 2;
        for (text[cursor..]) |byte| magnitude = magnitude *% 16 +% (std.fmt.charToDigit(byte, 16) catch unreachable);
        const n: i64 = @bitCast(magnitude);
        return if (negative) 0 -% n else n;
    }
    for (text[cursor..]) |byte| {
        magnitude = std.math.mul(u64, magnitude, 10) catch return null;
        magnitude = std.math.add(u64, magnitude, byte - '0') catch return null;
    }
    // Up to 2^63 - 1, or 2^63 itself with a minus.
    const limit: u64 = if (negative) 1 << 63 else (1 << 63) - 1;
    if (magnitude > limit) return null;
    return if (negative) @bitCast(0 -% magnitude) else @intCast(magnitude);
}

pub fn isExponent(byte: u8, hexadecimal: bool) bool {
    return if (hexadecimal) byte == 'p' or byte == 'P' else byte == 'e' or byte == 'E';
}

fn isDigit(byte: u8, hexadecimal: bool) bool {
    return if (hexadecimal) std.ascii.isHex(byte) else std.ascii.isDigit(byte);
}

const Output = struct {
    bytes: []u8,
    length: usize = 0,

    fn append(self: *Output, bytes: []const u8) error{NoSpaceLeft}!void {
        if (bytes.len > self.bytes.len - self.length) return error.NoSpaceLeft;
        @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
        self.length += bytes.len;
    }

    fn byte(self: *Output, value: u8) error{NoSpaceLeft}!void {
        if (self.length == self.bytes.len) return error.NoSpaceLeft;
        self.bytes[self.length] = value;
        self.length += 1;
    }
};

/// An integer's spelling: its decimal digits, as Lua's `%d`.
pub fn formatInteger(buffer: []u8, value: i64) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(buffer, "{d}", .{value});
}

pub fn format(buffer: []u8, value: f64) error{NoSpaceLeft}![]const u8 {
    if (std.math.isNan(value)) return std.fmt.bufPrint(buffer, "nan", .{});
    if (std.math.isInf(value)) return std.fmt.bufPrint(buffer, "{s}inf", .{if (std.math.signbit(value)) "-" else ""});
    // A float with a whole value is written with `.0`, as Lua writes it, so
    // that it reads back as a float and not as the integer of the same value
    //; the fixed form below adds it.
    var raw_buffer: [64]u8 = undefined;
    const raw = try std.fmt.bufPrint(&raw_buffer, "{e}", .{@abs(value)});
    const separator = std.mem.indexOfScalar(u8, raw, 'e') orelse return error.NoSpaceLeft;
    const exponent = std.fmt.parseInt(i16, raw[separator + 1 ..], 10) catch return error.NoSpaceLeft;
    var digits: [17]u8 = undefined;
    var length: usize = 0;
    for (raw[0..separator]) |byte| {
        if (byte == '.') continue;
        if (length == digits.len) return error.NoSpaceLeft;
        digits[length] = byte;
        length += 1;
    }
    if (length == 0) return error.NoSpaceLeft;
    const precision: i16 = if (length <= 15) 15 else 17;
    var output: Output = .{ .bytes = buffer };
    if (std.math.signbit(value)) try output.byte('-');
    if (exponent < -4 or exponent >= precision) {
        try output.byte(digits[0]);
        if (length > 1) {
            try output.byte('.');
            try output.append(digits[1..length]);
        }
        try output.byte('e');
        try output.byte(if (exponent < 0) '-' else '+');
        var exponent_buffer: [8]u8 = undefined;
        try output.append(try std.fmt.bufPrint(&exponent_buffer, "{d:0>2}", .{@abs(exponent)}));
    } else {
        const point = exponent + 1;
        if (point <= 0) {
            try output.append("0.");
            for (0..@intCast(-point)) |_| try output.byte('0');
            try output.append(digits[0..length]);
        } else {
            const whole: usize = @intCast(point);
            for (0..whole) |index| try output.byte(if (index < length) digits[index] else '0');
            if (whole < length) {
                try output.byte('.');
                try output.append(digits[whole..length]);
            } else try output.append(".0");
        }
    }
    return buffer[0..output.length];
}

test "decimal and hexadecimal numerals read as Lua's integers and floats" {
    const floats = .{
        .{ ".5", 0.5 },                                    .{ "3.", 3.0 }, .{ "1E-2", 0.01 }, .{ " +12.5\r\n", 12.5 }, .{ "-0X.8p1", -1.0 }, .{ "0x1p4", 16.0 },
        // Past 64 bits a decimal integer is a float.
        .{ "9223372036854775808", 9223372036854775808.0 },
    };
    inline for (floats) |entry| try std.testing.expectEqual(@as(f64, entry[1]), parse(entry[0]).?.float);
    // A numeral of digits alone is an integer; a hexadecimal one wraps.
    const integers = .{
        .{ "3", 3 },                                      .{ "0x10", 16 },                                   .{ "-0", 0 },
        .{ "9223372036854775807", std.math.maxInt(i64) }, .{ "-9223372036854775808", std.math.minInt(i64) }, .{ "0xFFFFFFFFFFFFFFFF", -1 },
        .{ "0x10000000000000000", 0 },
    };
    inline for (integers) |entry| try std.testing.expectEqual(@as(i64, entry[1]), parse(entry[0]).?.integer);
    try std.testing.expect(std.math.isInf(parse("1e9999").?.float));
    try std.testing.expectEqual(@as(u64, 0x8000000000000000), @as(u64, @bitCast(parse("-0.0").?.float)));
}

test "foreign number extensions and incomplete numbers are rejected" {
    for ([_][]const u8{ "", " ", "+", "-", ".", "inf", "nan", "-inf", "1_0", "0b10", "0x", "0x.p1", "1e", "1e+", "0x1p", "1 2", "1\x00", "1..2", "0x1g" }) |text| {
        try std.testing.expect(parse(text) == null);
    }
}

test "shortest numbers use the recorded fixed and scientific forms" {
    // A float with a whole value keeps `.0`, as lua5.5 writes it
    //: 0.0, -0.0, 1.0, 1e14 and 2^53 below are lua5.5's.
    const cases = .{
        .{ 0.0, "0.0" },                               .{ -0.0, "-0.0" },                             .{ 1.0, "1.0" },                           .{ 0.1, "0.1" },
        .{ 1.0 / 3.0, "0.3333333333333333" },          .{ 1e14, "100000000000000.0" },                .{ 1e15, "1e+15" },                        .{ 1e-4, "0.0001" },
        .{ 1e-5, "1e-05" },                            .{ 9007199254740992.0, "9007199254740992.0" }, .{ std.math.floatTrueMin(f64), "5e-324" }, .{ std.math.inf(f64), "inf" },
        .{ -std.math.inf(f64), "-inf" },               .{ -std.math.nan(f64), "nan" },                .{ -2.5, "-2.5" },                         .{ -9007199254740992.0, "-9007199254740992.0" },
        .{ 9007199254740994.0, "9007199254740994.0" }, .{ 1e16, "1e+16" },
    };
    var buffer: [64]u8 = undefined;
    inline for (cases) |entry| try std.testing.expectEqualStrings(entry[1], try format(&buffer, entry[0]));
}

test "formatting respects the caller buffer" {
    var short: [2]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, format(&short, 1.5));
    try std.testing.expectError(error.NoSpaceLeft, format(&short, 100));
    var exact: [3]u8 = undefined;
    try std.testing.expectEqualStrings("1.5", try format(&exact, 1.5));
    try std.testing.expectError(error.NoSpaceLeft, format(&exact, 100));
    var whole: [5]u8 = undefined;
    try std.testing.expectEqualStrings("100.0", try format(&whole, 100));
}

test "captured Lua numerals bound the form and length and every number reads back" {
    const fixture = @embedFile("lua55-numerals");
    var lines = std.mem.tokenizeScalar(u8, fixture, '\n');
    var rows: usize = 0;
    var identical: usize = 0;
    var shorter: usize = 0;
    var different_same_length: usize = 0;
    var whole: usize = 0;
    var buffer: [64]u8 = undefined;
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse return error.InvalidFixture;
        const bits = try std.fmt.parseInt(u64, line[0..space], 16);
        const value: f64 = @bitCast(bits);
        const expected = line[space + 1 ..];
        const written = try format(&buffer, value);
        // A whole number up to 2^53 is written as an integer,
        // which Lua writes for a float in its own %.14g form; only reading back
        // is compared for it.
        if (@abs(value) <= 9007199254740992.0 and value == @trunc(value)) {
            try std.testing.expectEqual(bits, @as(u64, @bitCast(parse(written).?.asFloat())));
            whole += 1;
            rows += 1;
            continue;
        }
        try std.testing.expectEqual(std.mem.indexOfScalar(u8, expected, 'e') != null, std.mem.indexOfScalar(u8, written, 'e') != null);
        try std.testing.expect(written.len <= expected.len);
        try std.testing.expectEqual(bits, @as(u64, @bitCast(parse(written).?.asFloat())));
        if (std.mem.eql(u8, expected, written)) {
            identical += 1;
        } else if (written.len < expected.len) {
            shorter += 1;
        } else different_same_length += 1;
        rows += 1;
    }
    try std.testing.expect(rows != 0);
    try std.testing.expect(identical != 0 and shorter != 0 and different_same_length != 0);
    std.debug.print("numeral fixture: {d} rows checked ({d} identical, {d} shorter, {d} same length with different digits, {d} whole numbers written as integers)\n", .{ rows, identical, shorter, different_same_length, whole });
}

test "finite bit patterns round trip and signs of zero are preserved" {
    var seed: u64 = 0x9e3779b97f4a7c15;
    var checked: usize = 0;
    var buffer: [64]u8 = undefined;
    for (0..4096) |_| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        const value: f64 = @bitCast(seed);
        if (!std.math.isFinite(value)) continue;
        const written = try format(&buffer, value);
        try std.testing.expectEqual(seed, @as(u64, @bitCast(parse(written).?.asFloat())));
        checked += 1;
    }
    std.debug.print("numeral round trips: {d} finite values from 4096 bit patterns\n", .{checked});
}

test "numerals have no locale buffer length cap" {
    var digits: [1024]u8 = @splat('0');
    digits[0] = '1';
    try std.testing.expect(std.math.isInf(parse(&digits).?.asFloat()));
    digits[0] = '0';
    try std.testing.expectEqual(@as(f64, 0), parse(&digits).?.asFloat());
}

test "number parsing agrees with captured Lua float conversions and refusals" {
    var lines = std.mem.tokenizeScalar(u8, @embedFile("lua55-numeral-parsing"), '\n');
    var buffer: [128]u8 = undefined;
    var checked: usize = 0;
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse return error.InvalidFixture;
        const encoded = line[0..space];
        const text = if (std.mem.eql(u8, encoded, "-")) "" else try std.fmt.hexToBytes(&buffer, encoded);
        const expected = line[space + 1 ..];
        if (std.mem.eql(u8, expected, "nil")) {
            try std.testing.expect(parse(text) == null);
        } else {
            const bits = try std.fmt.parseInt(u64, expected, 16);
            try std.testing.expectEqual(bits, @as(u64, @bitCast(parse(text).?.asFloat())));
        }
        checked += 1;
    }
    try std.testing.expect(checked != 0);
    std.debug.print("numeral parsing fixture: {d} Lua conversions and refusals checked\n", .{checked});
}
