//! `string.pack`, `string.unpack` and `string.packsize` (manual 10.2): Lua
//! 5.5's format, options, sizes and refusals, borrowed as they are. The
//! default byte order is little-endian and the default is no alignment. An
//! integer option carries its value in an i128 so that the 16-byte options
//! work; an 8-byte value past 2^53 comes back as the nearest number, since
//! a Nilu number holds no more (the owner's answer of 0113 §2).
const std = @import("std");
const stdlib = @import("stdlib.zig");

const Call = stdlib.Call;
const Error = stdlib.Error;
const Buffer = stdlib.Buffer;

const max_integer_size = 16;
const native_align = 8;

const Option = union(enum) {
    signed: usize,
    unsigned: usize,
    float: usize,
    fixed_string: usize,
    counted_string: usize,
    zero_string: void,
    padding: void,
    align_next: void,
    nothing: void,
};

const Header = struct {
    little: bool = true,
    max_align: usize = 1,
};

const Reader = struct {
    call: Call,
    format: []const u8,
    index: usize = 0,
    header: Header = .{},

    fn digit(self: *Reader) bool {
        return self.index < self.format.len and std.ascii.isDigit(self.format[self.index]);
    }
    fn number(self: *Reader, default: usize) usize {
        if (!self.digit()) return default;
        var value: usize = 0;
        while (self.digit()) : (self.index += 1) {
            value = value *| 10 +| (self.format[self.index] - '0');
            // Lua reads at most as many digits as fit; anything larger is refused below.
            if (value > 1_000_000) value = 1_000_000;
        }
        return value;
    }
    fn integerSize(self: *Reader, default: usize) Error!usize {
        const size = self.number(default);
        if (size < 1 or size > max_integer_size) {
            var buffer: [64]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "integral size ({d}) out of limits [1,{d}]", .{ size, max_integer_size }) catch "integral size out of limits";
            return self.call.raise(text);
        }
        return size;
    }

    /// Reads one option and answers it with its size and alignment requirement.
    fn option(self: *Reader) Error!struct { option: Option, size: usize, alignment: usize } {
        const letter = self.format[self.index];
        self.index += 1;
        const result: Option = switch (letter) {
            'b' => .{ .signed = 1 },
            'B' => .{ .unsigned = 1 },
            'h' => .{ .signed = 2 },
            'H' => .{ .unsigned = 2 },
            'l', 'j' => .{ .signed = 8 },
            'L', 'J', 'T' => .{ .unsigned = 8 },
            'i' => .{ .signed = try self.integerSize(4) },
            'I' => .{ .unsigned = try self.integerSize(4) },
            'f' => .{ .float = 4 },
            'd', 'n' => .{ .float = 8 },
            's' => .{ .counted_string = try self.integerSize(8) },
            'c' => blk: {
                if (!self.digit()) return self.call.argumentError(1, "missing size for format option 'c'");
                break :blk .{ .fixed_string = self.number(0) };
            },
            'z' => .zero_string,
            'x' => .padding,
            'X' => .align_next,
            ' ' => .nothing,
            '<' => blk: {
                self.header.little = true;
                break :blk .nothing;
            },
            '>' => blk: {
                self.header.little = false;
                break :blk .nothing;
            },
            '=' => blk: {
                self.header.little = true;
                break :blk .nothing;
            },
            '!' => blk: {
                self.header.max_align = try self.integerSize(native_align);
                break :blk .nothing;
            },
            else => {
                var buffer: [40]u8 = undefined;
                const text = std.fmt.bufPrint(&buffer, "invalid format option '{c}'", .{letter}) catch "invalid format option";
                return self.call.argumentError(1, text);
            },
        };
        const size: usize = switch (result) {
            .signed, .unsigned, .float => |n| n,
            .fixed_string => |n| n,
            .counted_string => |n| n,
            .padding => 1,
            else => 0,
        };
        return .{ .option = result, .size = size, .alignment = size };
    }

    /// Lua's getdetails: the option, its size and the padding that precedes it.
    fn details(self: *Reader, total: usize) Error!struct { option: Option, size: usize, padding: usize } {
        var read = try self.option();
        var alignment = read.alignment;
        if (read.option == .align_next) {
            if (self.index >= self.format.len) return self.call.argumentError(1, "invalid next option for option 'X'");
            const following = try self.option();
            alignment = following.alignment;
            if (following.option == .fixed_string or alignment == 0) return self.call.argumentError(1, "invalid next option for option 'X'");
            read.size = 0;
        }
        var padding: usize = 0;
        if (alignment <= 1 or read.option == .fixed_string) {
            // No alignment for a single byte, a string or an unaligned format.
        } else {
            if (alignment > self.header.max_align) alignment = self.header.max_align;
            if (alignment & (alignment - 1) != 0) return self.call.argumentError(1, "format asks for alignment not power of 2");
            padding = (alignment - (total & (alignment - 1))) & (alignment - 1);
        }
        return .{ .option = read.option, .size = read.size, .padding = padding };
    }
};

/// An integer argument, as Lua's luaL_checkinteger reads one: an integer,
/// or a float that is one within 64 bits; sign-extended for a wider option.
fn packedInteger(call: Call, argument: c_int) Error!i128 {
    return try call.checkInteger(argument);
}

fn packInteger(buffer: *Buffer, value: i128, size: usize, little: bool) Error!void {
    var bytes: [max_integer_size]u8 = undefined;
    var remaining = value;
    var index: usize = 0;
    while (index < size) : (index += 1) {
        bytes[index] = @truncate(@as(u128, @bitCast(remaining)));
        remaining >>= 8;
    }
    if (little) {
        try buffer.append(bytes[0..size]);
    } else {
        var reverse = size;
        while (reverse > 0) {
            reverse -= 1;
            try buffer.appendByte(bytes[reverse]);
        }
    }
}

pub fn pack(call: Call) Error!c_int {
    const format = try call.checkString(1);
    var reader = Reader{ .call = call, .format = format };
    var buffer = try Buffer.init(call, 32);
    var argument: c_int = 1;
    var total: usize = 0;
    while (reader.index < format.len) {
        const detail = try reader.details(total);
        total += detail.padding;
        var pad = detail.padding;
        while (pad > 0) : (pad -= 1) try buffer.appendByte(0);
        switch (detail.option) {
            .signed, .unsigned => |size| {
                argument += 1;
                const value = try packedInteger(call, argument);
                if (size < 8) {
                    const limit: i128 = @as(i128, 1) << @intCast(size * 8 - 1);
                    if (detail.option == .signed) {
                        if (value < -limit or value >= limit) return call.argumentError(argument, "integer overflow");
                    } else {
                        if (value < 0 or value >= limit * 2) return call.argumentError(argument, "unsigned overflow");
                    }
                } else if (detail.option == .unsigned and value < 0) return call.argumentError(argument, "unsigned overflow");
                try packInteger(&buffer, value, size, reader.header.little);
            },
            .float => |size| {
                argument += 1;
                const value = try call.checkNumber(argument);
                if (size == 4) {
                    const bits: u32 = @bitCast(@as(f32, @floatCast(value)));
                    try packInteger(&buffer, bits, 4, reader.header.little);
                } else {
                    const bits: u64 = @bitCast(value);
                    try packInteger(&buffer, bits, 8, reader.header.little);
                }
            },
            .fixed_string => |size| {
                argument += 1;
                const text = try call.checkString(argument);
                if (text.len > size) return call.argumentError(argument, "string longer than given size");
                try buffer.append(text);
                var fill = size - text.len;
                while (fill > 0) : (fill -= 1) try buffer.appendByte(0);
            },
            .counted_string => |size| {
                argument += 1;
                const text = try call.checkString(argument);
                if (size < 8 and text.len >= (@as(usize, 1) << @intCast(size * 8))) return call.argumentError(argument, "string length does not fit in given size");
                try packInteger(&buffer, @intCast(text.len), size, reader.header.little);
                try buffer.append(text);
                total += text.len;
            },
            .zero_string => {
                argument += 1;
                const text = try call.checkString(argument);
                if (std.mem.indexOfScalar(u8, text, 0) != null) return call.argumentError(argument, "string contains zeros");
                try buffer.append(text);
                try buffer.appendByte(0);
                total += text.len + 1;
            },
            .padding => try buffer.appendByte(0),
            .align_next, .nothing => {},
        }
        total += detail.size;
    }
    try buffer.finish();
    return 1;
}

pub fn packsize(call: Call) Error!c_int {
    const format = try call.checkString(1);
    var reader = Reader{ .call = call, .format = format };
    var total: usize = 0;
    while (reader.index < format.len) {
        const detail = try reader.details(total);
        if (detail.option == .counted_string or detail.option == .zero_string) return call.argumentError(1, "variable-length format");
        total = std.math.add(usize, total, detail.padding + detail.size) catch return call.argumentError(1, "format result too large");
        if (total > std.math.maxInt(c_int)) return call.argumentError(1, "format result too large");
    }
    try call.pushInteger(@intCast(total));
    return 1;
}

fn unpackInteger(data: []const u8, size: usize, little: bool, signed: bool, call: Call) Error!i64 {
    var value: u128 = 0;
    var index: usize = 0;
    const limit = @min(size, max_integer_size);
    while (index < limit) : (index += 1) {
        const byte: u128 = if (little) data[index] else data[size - 1 - index];
        value |= byte << @intCast(index * 8);
    }
    if (signed and size < max_integer_size and value >> @intCast(size * 8 - 1) & 1 == 1) {
        // Sign-extend.
        const mask = ~((@as(u128, 1) << @intCast(size * 8)) - 1);
        value |= mask;
    }
    if (signed) {
        const result: i128 = @bitCast(value);
        if (result > std.math.maxInt(i64) or result < std.math.minInt(i64)) {
            var buffer: [64]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "{d}-byte integer does not fit into Lua Integer", .{size}) catch "integer does not fit into Lua Integer";
            return call.raise(text);
        }
        return @intCast(result);
    }
    if (value > std.math.maxInt(u64)) {
        var buffer: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{d}-byte integer does not fit into Lua Integer", .{size}) catch "integer does not fit into Lua Integer";
        return call.raise(text);
    }
    // An unsigned 8-byte value past the largest integer wraps, as Lua's.
    return @bitCast(@as(u64, @intCast(value)));
}

pub fn unpack(call: Call) Error!c_int {
    const format = try call.checkString(1);
    const data = try call.checkString(2);
    const start = @import("stdlib_string.zig").startPosition(try call.optInteger(3, 1), data.len) - 1;
    if (start > data.len) return call.argumentError(3, "initial position out of string");
    var reader = Reader{ .call = call, .format = format };
    var position = start;
    var count: c_int = 0;
    while (reader.index < format.len) {
        const detail = try reader.details(position);
        if (detail.padding + detail.size > data.len - position) return call.argumentError(2, "data string too short");
        position += detail.padding;
        switch (detail.option) {
            .signed => |size| {
                try call.pushInteger(try unpackInteger(data[position..], size, reader.header.little, true, call));
                count += 1;
            },
            .unsigned => |size| {
                try call.pushInteger(try unpackInteger(data[position..], size, reader.header.little, false, call));
                count += 1;
            },
            .float => |size| {
                var bits: u64 = 0;
                var index: usize = 0;
                while (index < size) : (index += 1) {
                    const byte: u64 = if (reader.header.little) data[position + index] else data[position + size - 1 - index];
                    bits |= byte << @intCast(index * 8);
                }
                const value: f64 = if (size == 4) @floatCast(@as(f32, @bitCast(@as(u32, @truncate(bits))))) else @bitCast(bits);
                try call.pushNumber(value);
                count += 1;
            },
            .fixed_string => |size| {
                try call.push(data[position .. position + size]);
                count += 1;
            },
            .counted_string => |size| {
                const length_value = try unpackInteger(data[position..], size, reader.header.little, false, call);
                const length: usize = if (length_value < 0 or length_value > @as(i64, @intCast(data.len))) data.len + 1 else @intCast(length_value);
                if (length > data.len - position - size) return call.argumentError(2, "data string too short");
                try call.push(data[position + size .. position + size + length]);
                count += 1;
                position += length;
            },
            .zero_string => {
                const end = std.mem.indexOfScalarPos(u8, data, position, 0) orelse return call.argumentError(2, "unfinished string for format 'z'");
                try call.push(data[position..end]);
                count += 1;
                position = end + 1;
            },
            .padding, .align_next, .nothing => {},
        }
        position += detail.size;
    }
    try call.pushInteger(@intCast(position + 1));
    return count + 1;
}
