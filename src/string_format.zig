//! `string.format` (manual 10.2): `%d %i %u %o %x %X %c %f %e %E %g %G %a %A
//! %q %s %%`, a width and a precision of up to two digits, and Lua 5.5's
//! refusals word for word. The float conversions give C's results
//!: `%f`, `%e` and `%g` round the exact binary value, a tie
//! to even, and `%a` writes its bits. The owner's answers of 0113 §2 fix the
//! special values and the integer conversions: `nan`/`inf` as tostring spells
//! them (`NAN`/`INF` for the uppercase conversions), `-0` keeps its sign, and
//! a negative `%u`/`%o`/`%x` is refused.
const std = @import("std");
const stdlib = @import("stdlib.zig");
const api = @import("c_api.zig");

const Call = stdlib.Call;
const Error = stdlib.Error;
const Buffer = stdlib.Buffer;

const Spec = struct {
    left: bool = false,
    plus: bool = false,
    space: bool = false,
    alternate: bool = false,
    zero: bool = false,
    width: usize = 0,
    precision: ?usize = null,
    conversion: u8,
};

pub fn format(call: Call) Error!c_int {
    const text = try call.checkString(1);
    const top = call.top();
    var argument: c_int = 1;
    var buffer = try Buffer.init(call, text.len + 16);
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        index += 1;
        if (byte != '%') {
            try buffer.appendByte(byte);
            continue;
        }
        if (index < text.len and text[index] == '%') {
            try buffer.appendByte('%');
            index += 1;
            continue;
        }
        const spec_start = index - 1;
        var spec = Spec{ .conversion = 0 };
        var end = index;
        while (end < text.len and std.mem.indexOfScalar(u8, "-+ #0123456789.", text[end]) != null) end += 1;
        const letter: u8 = if (end < text.len) text[end] else 0;
        const written = text[spec_start..@min(end + 1, text.len)];
        if (letter == 0 or !std.ascii.isAlphabetic(letter)) return invalidConversion(call, written);
        spec.conversion = letter;
        // Lua refuses any flag, width or precision on %q before reading them.
        if (letter == 'q' and end != spec_start + 1) return call.raise("specifier '%q' cannot have modifiers");
        const flags: []const u8 = switch (letter) {
            'd', 'i' => "-+0 ",
            'u' => "-0",
            'o', 'x', 'X' => "-#0",
            'c' => "-",
            'f', 'e', 'E', 'g', 'G', 'a', 'A' => "-+ #0",
            's', 'p' => "-",
            'q' => "",
            else => return invalidConversion(call, written),
        };
        const precision_allowed = switch (letter) {
            'c', 'u', 'p' => false,
            else => true,
        };
        var cursor = index;
        while (cursor < end and std.mem.indexOfScalar(u8, flags, text[cursor]) != null) : (cursor += 1) {
            switch (text[cursor]) {
                '-' => spec.left = true,
                '+' => spec.plus = true,
                ' ' => spec.space = true,
                '#' => spec.alternate = true,
                '0' => spec.zero = true,
                else => {},
            }
        }
        if (cursor < end and text[cursor] != '0') {
            var digits: usize = 0;
            while (cursor < end and std.ascii.isDigit(text[cursor]) and digits < 2) : (cursor += 1) {
                spec.width = spec.width * 10 + (text[cursor] - '0');
                digits += 1;
            }
            if (cursor < end and text[cursor] == '.' and precision_allowed) {
                cursor += 1;
                var precision: usize = 0;
                digits = 0;
                while (cursor < end and std.ascii.isDigit(text[cursor]) and digits < 2) : (cursor += 1) {
                    precision = precision * 10 + (text[cursor] - '0');
                    digits += 1;
                }
                spec.precision = precision;
            }
        }
        if (cursor != end) return invalidSpecification(call, written);
        index = end + 1;
        argument += 1;
        if (argument > top) return call.argumentError(argument, "no value");
        var body: [512]u8 = undefined;
        switch (letter) {
            'd', 'i' => {
                const value = try call.checkInteger(argument);
                try layoutInteger(&buffer, spec, value < 0, @abs(value), 10, false, &body);
            },
            'u', 'o', 'x', 'X' => {
                // The integer's 64 bits read as unsigned, as Lua's.
                const value = try call.checkInteger(argument);
                const base: u8 = switch (letter) {
                    'u' => 10,
                    'o' => 8,
                    else => 16,
                };
                try layoutInteger(&buffer, spec, false, @as(u64, @bitCast(value)), base, letter == 'X', &body);
            },
            'c' => {
                // The low eight bits, the byte C's %c writes for Lua's int.
                const value = try call.checkInteger(argument);
                const one = [_]u8{@truncate(@as(u64, @bitCast(value)))};
                try pad(&buffer, spec, &one, "");
            },
            'f', 'e', 'E', 'g', 'G', 'a', 'A' => {
                const value = try call.checkNumber(argument);
                try layoutFloat(&buffer, spec, value, &body);
            },
            'q' => try quoted(call, &buffer, argument),
            // An object's address as C's %p writes it; a value that is not an
            // object has none, and Lua writes `(null)` for it.
            'p' => {
                const shown = if (api.nilu_topointer(call.state, argument)) |address|
                    std.fmt.bufPrint(&body, "0x{x}", .{@intFromPtr(address)}) catch unreachable
                else
                    "(null)";
                try pad(&buffer, spec, shown, "");
            },
            's' => {
                try stdlib.pushToString(call, argument);
                const string = call.bytesAt(-1);
                if (spec.precision == null and string.len >= 100) {
                    // Lua copies a long string as it is, ignoring the width.
                    try buffer.append(string);
                } else {
                    const shown = if (spec.precision) |limit| string[0..@min(limit, string.len)] else string;
                    try pad(&buffer, spec, shown, "");
                }
                call.pop(1);
            },
            else => return invalidConversion(call, written),
        }
    }
    try buffer.finish();
    return 1;
}

fn invalidConversion(call: Call, written: []const u8) Error {
    var sentence: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&sentence, "invalid conversion '{s}' to 'format'", .{written}) catch "invalid conversion to 'format'";
    return call.raise(text);
}
fn invalidSpecification(call: Call, written: []const u8) Error {
    var sentence: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&sentence, "invalid conversion specification: '{s}'", .{written}) catch "invalid conversion specification";
    return call.raise(text);
}

/// Writes `prefix` (a sign or `0x`) and `body` into the width: left-justified
/// with spaces, or right-justified with spaces, or with zeros after the prefix.
fn pad(buffer: *Buffer, spec: Spec, body: []const u8, prefix: []const u8) Error!void {
    const used = prefix.len + body.len;
    const fill = if (spec.width > used) spec.width - used else 0;
    if (spec.left) {
        try buffer.append(prefix);
        try buffer.append(body);
        try appendRepeated(buffer, ' ', fill);
        return;
    }
    if (spec.zero) {
        try buffer.append(prefix);
        try appendRepeated(buffer, '0', fill);
        try buffer.append(body);
        return;
    }
    try appendRepeated(buffer, ' ', fill);
    try buffer.append(prefix);
    try buffer.append(body);
}
fn appendRepeated(buffer: *Buffer, byte: u8, count: usize) Error!void {
    var remaining = count;
    while (remaining > 0) : (remaining -= 1) try buffer.appendByte(byte);
}

fn layoutInteger(buffer: *Buffer, spec: Spec, negative: bool, magnitude: u64, base: u8, uppercase: bool, body: *[512]u8) Error!void {
    var digits: [64]u8 = undefined;
    var count: usize = 0;
    var remaining = magnitude;
    if (remaining == 0) {
        digits[0] = '0';
        count = 1;
    }
    while (remaining > 0) : (count += 1) {
        const digit: u8 = @intCast(remaining % base);
        const letter: u8 = if (uppercase) 'A' else 'a';
        digits[count] = if (digit < 10) '0' + digit else letter + digit - 10;
        remaining /= base;
    }
    var length: usize = 0;
    // A precision is a minimum number of digits; with precision 0 a zero prints nothing.
    const minimum: usize = spec.precision orelse 1;
    if (spec.precision != null and magnitude == 0 and minimum == 0) count = 0;
    while (length + count < minimum and length < body.len) : (length += 1) body[length] = '0';
    var position = count;
    while (position > 0 and length < body.len) {
        position -= 1;
        body[length] = digits[position];
        length += 1;
    }
    var prefix_buffer: [3]u8 = undefined;
    var prefix: []const u8 = "";
    if (negative) {
        prefix = "-";
    } else if (spec.plus and base == 10) {
        prefix = "+";
    } else if (spec.space and base == 10) {
        prefix = " ";
    }
    if (spec.alternate and magnitude != 0) {
        prefix = switch (base) {
            8 => "0",
            16 => if (uppercase) "0X" else "0x",
            else => prefix,
        };
    }
    if (spec.alternate and base == 8 and magnitude != 0) {
        // C's `#` for octal makes the first digit a zero rather than adding one.
        prefix_buffer[0] = '0';
        prefix = prefix_buffer[0..1];
    }
    // A precision disables zero padding, as in C.
    var layout = spec;
    if (spec.precision != null) layout.zero = false;
    try pad(buffer, layout, body[0..length], prefix);
}

/// Decimal digits and the decimal exponent of the first one:
/// value = d1.d2d3... * 10^exponent.
const Decimal = struct { digits: [520]u8 = undefined, count: usize = 0, exponent: i32 = 0 };

/// The exponent of the first digit of the shortest spelling: an estimate of
/// floor(log10(magnitude)) that `exponentDigits` corrects by one when needed.
fn shortestExponent(magnitude: f64) ?i32 {
    var raw_buffer: [64]u8 = undefined;
    const raw = std.fmt.bufPrint(&raw_buffer, "{e}", .{magnitude}) catch return null;
    const separator = std.mem.indexOfScalar(u8, raw, 'e') orelse return null;
    return std.fmt.parseInt(i32, raw[separator + 1 ..], 10) catch null;
}

/// The decimal digits of magnitude * 10^power rounded to a whole number, a
/// tie to even, as C's printf rounds: the double is exactly
/// mantissa * 2^exponent, so the product is a ratio of integers. The big
/// integers live in a buffer on the stack, never in a global allocator.
fn scaledDigits(out: []u8, magnitude: f64, power: i32) ?[]const u8 {
    const Big = std.math.big.int.Managed;
    var memory: [32 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    const gpa = fixed.allocator();
    const bits: u64 = @bitCast(magnitude);
    const biased: i32 = @intCast((bits >> 52) & 0x7ff);
    var mantissa: u64 = bits & ((@as(u64, 1) << 52) - 1);
    var exponent: i32 = -1074;
    if (biased != 0) {
        mantissa |= @as(u64, 1) << 52;
        exponent = biased - 1075;
    }
    var numerator = Big.init(gpa) catch return null;
    var denominator = Big.init(gpa) catch return null;
    var scale = Big.init(gpa) catch return null;
    var ten = Big.init(gpa) catch return null;
    var quotient = Big.init(gpa) catch return null;
    var remainder = Big.init(gpa) catch return null;
    numerator.set(mantissa) catch return null;
    denominator.set(1) catch return null;
    if (exponent >= 0) numerator.shiftLeft(&numerator, @intCast(exponent)) catch return null else denominator.shiftLeft(&denominator, @intCast(-exponent)) catch return null;
    ten.set(10) catch return null;
    scale.pow(&ten, @intCast(@abs(power))) catch return null;
    if (power >= 0) numerator.mul(&numerator, &scale) catch return null else denominator.mul(&denominator, &scale) catch return null;
    quotient.divFloor(&remainder, &numerator, &denominator) catch return null;
    remainder.shiftLeft(&remainder, 1) catch return null;
    const order = remainder.order(denominator);
    const odd = quotient.toConst().limbs[0] & 1 == 1;
    if (order == .gt or (order == .eq and odd)) quotient.addScalar(&quotient, 1) catch return null;
    const text = quotient.toString(gpa, 10, .lower) catch return null;
    if (text.len > out.len) return null;
    @memcpy(out[0..text.len], text);
    return out[0..text.len];
}

/// `precision + 1` significant digits of a finite magnitude, rounded as C
/// rounds, and the exponent of the first.
fn exponentDigits(magnitude: f64, precision: usize) ?Decimal {
    var decimal = Decimal{};
    if (magnitude == 0) {
        @memset(decimal.digits[0 .. precision + 1], '0');
        decimal.count = precision + 1;
        return decimal;
    }
    var exponent = shortestExponent(magnitude) orelse return null;
    var attempt: usize = 0;
    while (attempt < 3) : (attempt += 1) {
        const power: i32 = @as(i32, @intCast(precision)) - exponent;
        const digits = scaledDigits(&decimal.digits, magnitude, power) orelse return null;
        if (digits.len == precision + 2) {
            exponent += 1;
            continue;
        }
        if (digits.len < precision + 1) {
            exponent -= 1;
            continue;
        }
        decimal.count = digits.len;
        decimal.exponent = exponent;
        return decimal;
    }
    return null;
}

/// `precision` digits after the point of a finite magnitude, rounded as C
/// rounds: the digits and the exponent of the first.
fn fixedDigits(magnitude: f64, precision: usize) ?Decimal {
    var decimal = Decimal{};
    const digits = scaledDigits(&decimal.digits, magnitude, @intCast(precision)) orelse return null;
    decimal.count = digits.len;
    decimal.exponent = @as(i32, @intCast(digits.len)) - 1 - @as(i32, @intCast(precision));
    return decimal;
}

fn layoutFloat(buffer: *Buffer, spec: Spec, value: f64, body: *[512]u8) Error!void {
    const negative = std.math.signbit(value);
    const sign: []const u8 = if (negative) "-" else if (spec.plus) "+" else if (spec.space) " " else "";
    const uppercase = spec.conversion == 'E' or spec.conversion == 'G' or spec.conversion == 'A';
    if (std.math.isNan(value) or std.math.isInf(value)) {
        const word: []const u8 = if (std.math.isNan(value)) (if (uppercase) "NAN" else "nan") else (if (uppercase) "INF" else "inf");
        // A special value is never zero padded, as in C.
        var layout = spec;
        layout.zero = false;
        return pad(buffer, layout, word, if (std.math.isNan(value)) "" else sign);
    }
    const magnitude = @abs(value);
    var length: usize = 0;
    switch (spec.conversion) {
        'f' => {
            const decimal = fixedDigits(magnitude, spec.precision orelse 6) orelse return error.Stack;
            length = writeFixed(body, decimal.digits[0..decimal.count], decimal.exponent, 0, spec.precision orelse 6, spec.alternate);
        },
        'e', 'E' => {
            const precision = spec.precision orelse 6;
            const decimal = exponentDigits(magnitude, precision) orelse return error.Stack;
            length = writeExponent(body, decimal, precision, spec.alternate, uppercase);
        },
        'g', 'G' => {
            // C's %g: P significant digits; the exponent X that %e would show
            // picks %f (precision P-1-X) when -4 <= X < P, else %e (P-1).
            const requested = spec.precision orelse 6;
            const significant: usize = if (requested == 0) 1 else requested;
            const probe = exponentDigits(magnitude, significant - 1) orelse return error.Stack;
            const x = probe.exponent;
            if (x >= -4 and x < @as(i32, @intCast(significant))) {
                const after: usize = @intCast(@as(i32, @intCast(significant)) - 1 - x);
                const decimal = fixedDigits(magnitude, after) orelse return error.Stack;
                length = writeFixed(body, decimal.digits[0..decimal.count], decimal.exponent, 0, after, spec.alternate);
                if (!spec.alternate) length = trimFraction(body[0..length]);
            } else {
                length = writeExponent(body, probe, significant - 1, spec.alternate, uppercase);
                if (!spec.alternate) {
                    const mark = std.mem.indexOfScalar(u8, body[0..length], if (uppercase) 'E' else 'e').?;
                    var tail: [8]u8 = undefined;
                    @memcpy(tail[0 .. length - mark], body[mark..length]);
                    const kept = trimFraction(body[0..mark]);
                    @memcpy(body[kept..][0 .. length - mark], tail[0 .. length - mark]);
                    length = kept + (length - mark);
                }
            }
        },
        'a', 'A' => length = writeHexadecimal(body, magnitude, spec.precision, spec.alternate, uppercase),
        else => unreachable,
    }
    try pad(buffer, spec, body[0..length], sign);
}

/// Drops the zeros at the end of a fraction, and the point when nothing is
/// left after it, as %g does without `#`.
fn trimFraction(text: []u8) usize {
    if (std.mem.indexOfScalar(u8, text, '.') == null) return text.len;
    var length = text.len;
    while (length > 0 and text[length - 1] == '0') length -= 1;
    if (length > 0 and text[length - 1] == '.') length -= 1;
    return length;
}

/// C's %a for a double: 0x1.hhhp+e (0x0.hhhp-1022 below the normal range),
/// the fraction rounded to `precision` hex digits, a tie to even, or written
/// without its trailing zeros when no precision is given.
fn writeHexadecimal(body: *[512]u8, magnitude: f64, precision: ?usize, alternate: bool, uppercase: bool) usize {
    const bits: u64 = @bitCast(magnitude);
    const biased: u64 = (bits >> 52) & 0x7ff;
    var fraction: u64 = bits & ((@as(u64, 1) << 52) - 1);
    var lead: u64 = if (biased == 0) 0 else 1;
    const exponent: i64 = if (magnitude == 0) 0 else if (biased == 0) -1022 else @as(i64, @intCast(biased)) - 1023;
    var digits: usize = 13;
    if (precision) |wanted| if (wanted < 13) {
        const drop: u6 = @intCast(4 * (13 - wanted));
        const kept = fraction >> drop;
        const rest = fraction & ((@as(u64, 1) << drop) - 1);
        const half = @as(u64, 1) << (drop - 1);
        var rounded = kept;
        // The last digit kept decides a tie; with no fraction digits it is
        // the leading one (1.5 -> 0x2p+0, as glibc).
        const last_odd = if (wanted == 0) lead & 1 == 1 else kept & 1 == 1;
        if (rest > half or (rest == half and last_odd)) rounded += 1;
        const limit = @as(u64, 1) << @intCast(4 * wanted);
        if (rounded == limit) {
            rounded = 0;
            lead += 1;
        }
        fraction = rounded;
        digits = wanted;
    } else {
        digits = wanted;
    };
    var hex: [128]u8 = undefined;
    const letters = if (uppercase) "0123456789ABCDEF" else "0123456789abcdef";
    var count: usize = 0;
    while (count < digits) : (count += 1) {
        const shift: i64 = if (digits <= 13) 4 * (@as(i64, @intCast(digits)) - 1 - @as(i64, @intCast(count))) else -1;
        hex[count] = if (count < 13 and shift >= 0) letters[@intCast((fraction >> @intCast(shift)) & 0xf)] else if (count < 13) letters[@intCast((fraction >> @intCast(4 * (12 - count))) & 0xf)] else '0';
    }
    if (precision == null) {
        while (count > 0 and hex[count - 1] == '0') count -= 1;
    }
    var length: usize = 0;
    const prefix = if (uppercase) "0X" else "0x";
    @memcpy(body[0..2], prefix);
    length = 2;
    body[length] = letters[@intCast(lead)];
    length += 1;
    if (count > 0 or alternate) {
        body[length] = '.';
        length += 1;
    }
    @memcpy(body[length..][0..count], hex[0..count]);
    length += count;
    const tail = std.fmt.bufPrint(body[length..], "{c}{c}{d}", .{ @as(u8, if (uppercase) 'P' else 'p'), @as(u8, if (exponent < 0) '-' else '+'), @abs(exponent) }) catch return length;
    return length + tail.len;
}

/// %q: a string Lua can read back, or a number, nil or a boolean as a
/// literal. An integer is written in decimal, a float
/// in hexadecimal, infinity as 1e9999 and NaN as (0/0), as Lua writes them.
fn quoted(call: Call, buffer: *Buffer, argument: c_int) Error!void {
    switch (call.typeAt(argument)) {
        .string => {
            const text = call.bytesAt(argument);
            try buffer.appendByte('"');
            for (text, 0..) |byte, i| {
                const next_is_digit = i + 1 < text.len and std.ascii.isDigit(text[i + 1]);
                switch (byte) {
                    '"', '\\' => {
                        try buffer.appendByte('\\');
                        try buffer.appendByte(byte);
                    },
                    '\n' => {
                        try buffer.appendByte('\\');
                        try buffer.appendByte('\n');
                    },
                    0...9, 11...31, 127 => {
                        var escape: [8]u8 = undefined;
                        const written = if (next_is_digit) std.fmt.bufPrint(&escape, "\\{d:0>3}", .{byte}) catch unreachable else std.fmt.bufPrint(&escape, "\\{d}", .{byte}) catch unreachable;
                        try buffer.append(written);
                    },
                    else => try buffer.appendByte(byte),
                }
            }
            try buffer.appendByte('"');
        },
        .number => {
            const value = call.numberAt(argument);
            var text: [64]u8 = undefined;
            // An integer in decimal, the smallest in hexadecimal (its decimal
            // would read back as a float); a float in hexadecimal, so that it
            // reads back as itself and as a float, as Lua's %q.
            const integer = api.nilu_tointegerx(call.state, argument, null);
            const written = if (call.isIntegerAt(argument))
                (if (integer == std.math.minInt(i64)) "0x8000000000000000" else std.fmt.bufPrint(&text, "{d}", .{integer}) catch unreachable)
            else if (std.math.isNan(value))
                "(0/0)"
            else if (std.math.isInf(value))
                (if (value > 0) "1e9999" else "-1e9999")
            else blk: {
                var body: [512]u8 = undefined;
                const length = writeHexadecimal(&body, @abs(value), null, false, false);
                const sign: []const u8 = if (std.math.signbit(value)) "-" else "";
                break :blk std.fmt.bufPrint(&text, "{s}{s}", .{ sign, body[0..length] }) catch unreachable;
            };
            try buffer.append(written);
        },
        .nil, .boolean => {
            try stdlib.pushToString(call, argument);
            try buffer.append(call.bytesAt(-1));
            call.pop(1);
        },
        else => return call.argumentError(argument, "value has no literal form"),
    }
}

/// Lays out digits d1 d2 ... (first digit worth 10^exponent) with `precision`
/// digits after the point, zero-filled on both sides.
fn writeFixed(body: *[512]u8, digits: []const u8, exponent: i32, _: usize, precision: usize, alternate: bool) usize {
    var length: usize = 0;
    const integer_digits: i64 = @as(i64, exponent) + 1;
    if (integer_digits <= 0) {
        body[length] = '0';
        length += 1;
    } else {
        var index: i64 = 0;
        while (index < integer_digits and length < body.len) : (index += 1) {
            body[length] = if (index < digits.len) digits[@intCast(index)] else '0';
            length += 1;
        }
    }
    if (precision > 0 or alternate) {
        if (length < body.len) {
            body[length] = '.';
            length += 1;
        }
    }
    var fraction: usize = 0;
    while (fraction < precision and length < body.len) : (fraction += 1) {
        const position: i64 = integer_digits + @as(i64, @intCast(fraction));
        body[length] = if (position >= 0 and position < digits.len) digits[@intCast(position)] else '0';
        length += 1;
    }
    return length;
}

fn writeExponent(body: *[512]u8, decimal: Decimal, precision: usize, alternate: bool, uppercase: bool) usize {
    var length: usize = 0;
    body[length] = decimal.digits[0];
    length += 1;
    if (precision > 0 or alternate) {
        body[length] = '.';
        length += 1;
    }
    var fraction: usize = 0;
    while (fraction < precision and length < body.len) : (fraction += 1) {
        body[length] = if (fraction + 1 < decimal.count) decimal.digits[fraction + 1] else '0';
        length += 1;
    }
    const tail = std.fmt.bufPrint(body[length..], "{c}{c}{d:0>2}", .{ @as(u8, if (uppercase) 'E' else 'e'), @as(u8, if (decimal.exponent < 0) '-' else '+'), @abs(decimal.exponent) }) catch return length;
    return length + tail.len;
}
