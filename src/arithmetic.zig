//! Arithmetic and comparison across the two subtypes of number, as Lua 5.5
//! defines them: two integers give an integer that wraps
//! around in 64 bits, except `/` and `^`, which give a float; a float on
//! either side makes the operation a float one. An integer and a float
//! compare by their exact values. Floats alone keep the frame loop's own path
//! (`vm.numbers`); this is the path for everything with an integer in it.
const std = @import("std");
const runtime = @import("runtime.zig");
const bytecode = @import("bytecode.zig");
const Value = runtime.Value;

/// A number of either subtype.
pub const Number = union(enum) {
    integer: i64,
    float: f64,

    pub fn of(value: Value) ?Number {
        if (value.isNumber()) return .{ .float = value.asNumber() };
        if (value.is(.integer)) return .{ .integer = value.asInteger() };
        return null;
    }

    pub fn asFloat(number: Number) f64 {
        return switch (number) {
            .integer => |n| @floatFromInt(n),
            .float => |f| f,
        };
    }

    /// The integer a number is exactly, as Lua's bitwise operators and
    /// integer arguments read one: an integer, or a float with an integral
    /// value inside 64 bits.
    pub fn asInteger(number: Number) ?i64 {
        return switch (number) {
            .integer => |n| n,
            .float => |f| runtime.floatToInteger(f),
        };
    }
};

pub fn isNumber(value: Value) bool {
    return value.isNumber() or value.is(.integer);
}

/// What an operator on two numbers gives: a value, or Lua's refusal of an
/// integer division or modulo by zero, or of a bitwise operand that is not
/// an integer.
pub const Outcome = union(enum) {
    value: Value,
    divide_by_zero,
    modulo_by_zero,
    /// The first operand, counted from 0, that has no integer value.
    no_integer: u1,
};

/// An operator on two numbers, at least one an integer; or null for one
/// that does not take numbers (`..`). Allocates only for an integer result
/// outside what a value holds itself.
pub fn binary(state: *runtime.State, operator: bytecode.Binary, a: Number, b: Number) error{OutOfMemory}!?Outcome {
    switch (operator) {
        .bitwise_and, .bitwise_or, .bitwise_xor, .shift_left, .shift_right => {
            const x = a.asInteger() orelse return .{ .no_integer = 0 };
            const y = b.asInteger() orelse return .{ .no_integer = 1 };
            return .{ .value = try state.integer(bitwise(operator, x, y)) };
        },
        .equal, .not_equal, .less, .less_equal, .greater, .greater_equal => {
            const result = switch (operator) {
                .equal => equal(a, b),
                .not_equal => !equal(a, b),
                .less => less(a, b),
                .less_equal => lessEqual(a, b),
                .greater => less(b, a),
                .greater_equal => lessEqual(b, a),
                else => unreachable,
            };
            return .{ .value = .fromBoolean(result) };
        },
        .concatenate => return null,
        .divide => return .{ .value = .from(.{ .number = a.asFloat() / b.asFloat() }) },
        .power => return .{ .value = .from(.{ .number = std.math.pow(f64, a.asFloat(), b.asFloat()) }) },
        else => {},
    }
    if (a == .integer and b == .integer) {
        const x = a.integer;
        const y = b.integer;
        const result: i64 = switch (operator) {
            .add => x +% y,
            .subtract => x -% y,
            .multiply => x *% y,
            .floor_divide => if (y == 0) return .divide_by_zero else floorDivide(x, y),
            .modulo => if (y == 0) return .modulo_by_zero else modulo(x, y),
            else => unreachable,
        };
        return .{ .value = try state.integer(result) };
    }
    const x = a.asFloat();
    const y = b.asFloat();
    return .{ .value = .from(.{ .number = switch (operator) {
        .add => x + y,
        .subtract => x - y,
        .multiply => x * y,
        .floor_divide => @floor(x / y),
        .modulo => floatModulo(x, y),
        else => unreachable,
    } }) };
}

/// Lua's luaV_idiv: the quotient rounded toward negative infinity; by -1
/// it is the negation, which wraps for the smallest integer.
pub fn floorDivide(x: i64, y: i64) i64 {
    if (y == -1) return 0 -% x;
    const quotient = @divTrunc(x, y);
    return if ((x ^ y) < 0 and @rem(x, y) != 0) quotient - 1 else quotient;
}

/// Lua's luaV_mod: the remainder with the divisor's sign.
pub fn modulo(x: i64, y: i64) i64 {
    if (y == -1) return 0;
    const remainder = @rem(x, y);
    return if (remainder != 0 and (remainder ^ y) < 0) remainder + y else remainder;
}

/// Lua's float modulo: fmod corrected to the divisor's sign.
pub fn floatModulo(a: f64, b: f64) f64 {
    if (std.math.isNan(a) or std.math.isNan(b) or std.math.isInf(a) or b == 0) return std.math.nan(f64);
    var remainder = if (std.math.isInf(b)) a else @rem(a, b);
    if (if (remainder > 0) b < 0 else remainder < 0 and b > 0) remainder += b;
    return remainder;
}

pub fn bitwise(operator: bytecode.Binary, x: i64, y: i64) i64 {
    return switch (operator) {
        .bitwise_and => x & y,
        .bitwise_or => x | y,
        .bitwise_xor => x ^ y,
        .shift_left => shiftLeft(x, y),
        .shift_right => shiftLeft(x, if (y == std.math.minInt(i64)) std.math.maxInt(i64) else -y),
        else => unreachable,
    };
}

/// Lua's luaV_shiftl: a logical shift, to the right for a negative count,
/// and 0 once every bit has moved out.
pub fn shiftLeft(x: i64, count: i64) i64 {
    const bits: u64 = @bitCast(x);
    if (count <= -64 or count >= 64) return 0;
    if (count < 0) return @bitCast(bits >> @intCast(-count));
    return @bitCast(bits << @intCast(count));
}

pub fn equal(a: Number, b: Number) bool {
    return switch (a) {
        .integer => |x| switch (b) {
            .integer => |y| x == y,
            .float => |y| runtime.floatIsInteger(y, x),
        },
        .float => |x| switch (b) {
            .integer => |y| runtime.floatIsInteger(x, y),
            .float => |y| x == y,
        },
    };
}

pub fn less(a: Number, b: Number) bool {
    return switch (a) {
        .integer => |x| switch (b) {
            .integer => |y| x < y,
            .float => |y| integerLessFloat(x, y),
        },
        .float => |x| switch (b) {
            .integer => |y| floatLessInteger(x, y),
            .float => |y| x < y,
        },
    };
}

pub fn lessEqual(a: Number, b: Number) bool {
    return switch (a) {
        .integer => |x| switch (b) {
            .integer => |y| x <= y,
            .float => |y| integerLessEqualFloat(x, y),
        },
        .float => |x| switch (b) {
            .integer => |y| floatLessEqualInteger(x, y),
            .float => |y| x <= y,
        },
    };
}

/// Whether an integer is exactly a float too: within 2^53 every one is.
fn fitsFloat(n: i64) bool {
    const limit: i64 = 1 << 53;
    return n >= -limit and n <= limit;
}

/// Lua's LTintfloat: i < f exactly, a NaN never.
fn integerLessFloat(i: i64, f: f64) bool {
    if (fitsFloat(i)) return @as(f64, @floatFromInt(i)) < f;
    // i < f exactly when i < ceil(f), for an f inside 64 bits.
    if (std.math.isNan(f)) return false;
    if (f >= 0x1p63) return true;
    if (f < -0x1p63) return false;
    return i < @as(i64, @intFromFloat(@ceil(f)));
}

/// Lua's LEintfloat: i <= f exactly.
fn integerLessEqualFloat(i: i64, f: f64) bool {
    if (fitsFloat(i)) return @as(f64, @floatFromInt(i)) <= f;
    if (std.math.isNan(f)) return false;
    if (f >= 0x1p63) return true;
    if (f < -0x1p63) return false;
    return i <= @as(i64, @intFromFloat(@floor(f)));
}

/// Lua's LTfloatint: f < i exactly.
fn floatLessInteger(f: f64, i: i64) bool {
    if (fitsFloat(i)) return f < @as(f64, @floatFromInt(i));
    if (std.math.isNan(f)) return false;
    if (f >= 0x1p63) return false;
    if (f < -0x1p63) return true;
    return @as(i64, @intFromFloat(@floor(f))) < i;
}

/// Lua's LEfloatint: f <= i exactly.
fn floatLessEqualInteger(f: f64, i: i64) bool {
    if (fitsFloat(i)) return f <= @as(f64, @floatFromInt(i));
    if (std.math.isNan(f)) return false;
    if (f >= 0x1p63) return false;
    if (f < -0x1p63) return true;
    return @as(i64, @intFromFloat(@ceil(f))) <= i;
}
