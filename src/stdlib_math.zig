//! `math` (manual 10.4): the functions a number without an integer type can
//! answer, and Lua 5.5's xoshiro256** with Lua's seeding, so a seed gives
//! Lua's sequence. The generator's state is a userdata that `random` and
//! `randomseed` hold as an upvalue; a fresh library starts as after
//! `randomseed(0)`, since the core has no clock. `fmod(x, 0)` is nan and
//! `randomseed()` reseeds from the generator's next value, 53 bits of it
//! (the owner's answers of 2026-10-30).
const std = @import("std");
const api = @import("c_api.zig");
const stdlib = @import("stdlib.zig");

const Call = stdlib.Call;
const Error = stdlib.Error;
const entry = stdlib.entry;

pub fn open(call: Call) Error!void {
    try call.check(api.nilu_newtable(call.state));
    try stdlib.setNumberField(call, "pi", std.math.pi);
    try stdlib.setNumberField(call, "huge", std.math.inf(f64));
    // One number type: the largest whole numbers that are all exact
    //.
    try call.push("maxinteger");
    try call.pushInteger(std.math.maxInt(i64));
    try call.check(api.nilu_settable(call.state, -3));
    try call.push("mininteger");
    try call.pushInteger(std.math.minInt(i64));
    try call.check(api.nilu_settable(call.state, -3));
    for ([_]stdlib.Registration{
        .{ .name = "abs", .function = entry("abs", abs) },
        .{ .name = "floor", .function = entry("floor", floor) },
        .{ .name = "ceil", .function = entry("ceil", ceil) },
        .{ .name = "sqrt", .function = entry("sqrt", sqrt) },
        .{ .name = "max", .function = entry("max", max) },
        .{ .name = "min", .function = entry("min", min) },
        .{ .name = "fmod", .function = entry("fmod", fmod) },
        .{ .name = "sin", .function = entry("sin", sin) },
        .{ .name = "cos", .function = entry("cos", cos) },
        .{ .name = "tan", .function = entry("tan", tan) },
        .{ .name = "asin", .function = entry("asin", asin) },
        .{ .name = "acos", .function = entry("acos", acos) },
        .{ .name = "atan", .function = entry("atan", atan) },
        .{ .name = "exp", .function = entry("exp", exp) },
        .{ .name = "log", .function = entry("log", log) },
        .{ .name = "deg", .function = entry("deg", deg) },
        .{ .name = "rad", .function = entry("rad", rad) },
        .{ .name = "modf", .function = entry("modf", modf) },
        .{ .name = "frexp", .function = entry("frexp", frexp) },
        .{ .name = "ldexp", .function = entry("ldexp", ldexp) },
        .{ .name = "type", .function = entry("type", mathType) },
        .{ .name = "tointeger", .function = entry("tointeger", toInteger) },
        .{ .name = "ult", .function = entry("ult", ult) },
    }) |function| try stdlib.setField(call, function.name, function.function);
    // The generator's state, shared by the two closures as their upvalue.
    var block: ?*anyopaque = null;
    try call.check(api.nilu_newuserdata(call.state, @sizeOf(Generator), &block));
    const fresh: *Generator = @ptrCast(@alignCast(block.?));
    fresh.seed(0, 0);
    try call.push("random");
    try call.pushValue(-2);
    try call.check(api.nilu_pushcclosure(call.state, entry("random", random), 1));
    try call.check(api.nilu_settable(call.state, -4));
    try call.push("randomseed");
    try call.pushValue(-2);
    try call.check(api.nilu_pushcclosure(call.state, entry("randomseed", randomSeed), 1));
    try call.check(api.nilu_settable(call.state, -4));
    call.pop(1);
    try call.check(api.nilu_setglobal(call.state, "math"));
}

fn unary(call: Call, comptime operation: fn (f64) f64) Error!c_int {
    const value = try call.checkNumber(1);
    try call.pushNumber(operation(value));
    return 1;
}
fn absOf(value: f64) f64 {
    return @abs(value);
}
fn floorOf(value: f64) f64 {
    return @floor(value);
}
fn ceilOf(value: f64) f64 {
    return @ceil(value);
}
fn sqrtOf(value: f64) f64 {
    return @sqrt(value);
}
// Integers stay integers, as in Lua: abs wraps for the
// smallest one, and floor and ceil give an integer where it fits.
fn abs(call: Call) Error!c_int {
    if (call.isIntegerAt(1)) {
        const n = api.nilu_tointegerx(call.state, 1, null);
        try call.pushInteger(if (n < 0) 0 -% n else n);
        return 1;
    }
    return unary(call, absOf);
}
fn floor(call: Call) Error!c_int {
    return rounded(call, floorOf);
}
fn ceil(call: Call) Error!c_int {
    return rounded(call, ceilOf);
}
fn rounded(call: Call, comptime operation: fn (f64) f64) Error!c_int {
    if (call.isIntegerAt(1)) {
        try call.pushValue(1);
        return 1;
    }
    try call.pushFloatAsInteger(operation(try call.checkNumber(1)));
    return 1;
}
fn sqrt(call: Call) Error!c_int {
    return unary(call, sqrtOf);
}

/// Lua's loop: the candidate is replaced only when the comparison says so,
/// which is what decides the answer with a nan among the arguments.
/// luaG_ordererror's sentence, the types named as a failure names them.
fn orderError(call: Call, left: c_int, right: c_int) Error {
    var first: [128]u8 = undefined;
    var second: [128]u8 = undefined;
    const a = call.typeNameAt(left, &first);
    const b = call.typeNameAt(right, &second);
    var sentence: [320]u8 = undefined;
    const text = if (std.mem.eql(u8, a, b))
        std.fmt.bufPrint(&sentence, "attempt to compare two {s} values", .{a}) catch "attempt to compare"
    else
        std.fmt.bufPrint(&sentence, "attempt to compare {s} with {s}", .{ a, b }) catch "attempt to compare";
    try call.push(text);
    return error.Raised;
}

/// math.max and math.min compare with `<`, as Lua 5.5's do (the owner's
/// answer): anything `<` orders, `__lt` included, and
/// `<`'s own failure for what it does not. A NaN never replaces the first.
fn extreme(call: Call, comptime keep_larger: bool) Error!c_int {
    const count = call.top();
    if (count < 1) return call.argumentError(1, "value expected");
    var best: c_int = 1;
    var index: c_int = 2;
    while (index <= count) : (index += 1) {
        const left = if (keep_larger) best else index;
        const right = if (keep_larger) index else best;
        const before = call.top();
        const status = api.nilu_compare(call.state, left, right, 1);
        if (status != .ok) {
            // A failing __lt left its value on top, for nilu_error to raise.
            if (call.top() > before) return error.Raised;
            if (status != .type) {
                try call.check(status);
                unreachable;
            }
            // `<` refused the pair and pushed nothing: its sentence, which
            // Lua gives with no position since the comparison is the C
            // function's.
            return orderError(call, left, right);
        }
        const less = call.truthy(-1);
        call.pop(1);
        if (less) best = index;
    }
    try call.pushValue(best);
    return 1;
}
fn max(call: Call) Error!c_int {
    return extreme(call, true);
}
fn min(call: Call) Error!c_int {
    return extreme(call, false);
}

fn fmod(call: Call) Error!c_int {
    // Two integers: C's remainder, toward zero, and a zero divisor refused,
    // as Lua's math.fmod.
    if (call.isIntegerAt(1) and call.isIntegerAt(2)) {
        const m = api.nilu_tointegerx(call.state, 1, null);
        const d = api.nilu_tointegerx(call.state, 2, null);
        if (d == 0) return call.argumentError(2, "zero");
        try call.pushInteger(if (d == -1) 0 else @rem(m, d));
        return 1;
    }
    const a = try call.checkNumber(1);
    const b = try call.checkNumber(2);
    try call.pushNumber(if (b == 0 or std.math.isInf(a) or std.math.isNan(a) or std.math.isNan(b)) std.math.nan(f64) else if (std.math.isInf(b)) a else @rem(a, b));
    return 1;
}

/// xoshiro256** as Lua 5.5 runs it, with Lua's seeding and discards.
pub const Generator = extern struct {
    state: [4]u64,

    fn rotl(x: u64, n: u6) u64 {
        return (x << n) | (x >> @intCast(64 - @as(u7, n)));
    }
    pub fn next(self: *Generator) u64 {
        const s = &self.state;
        const result = rotl(s[1] *% 5, 7) *% 9;
        const t = s[1] << 17;
        s[2] ^= s[0];
        s[3] ^= s[1];
        s[1] ^= s[2];
        s[0] ^= s[3];
        s[2] ^= t;
        s[3] = rotl(s[3], 45);
        return result;
    }
    pub fn seed(self: *Generator, n1: u64, n2: u64) void {
        self.state = .{ n1, 0xff, n2, 0 };
        var discard: usize = 0;
        while (discard < 16) : (discard += 1) _ = self.next();
    }
    /// A fraction in [0, 1) from the top 53 bits.
    pub fn float(self: *Generator) f64 {
        return @as(f64, @floatFromInt(self.next() >> 11)) * 0x1.0p-53;
    }
    /// Lua's project: an unbiased value in [0, n] from a 64-bit draw.
    pub fn project(self: *Generator, first: u64, n: u64) u64 {
        if (n & (n +% 1) == 0) return first & n;
        var lim = n;
        lim |= lim >> 1;
        lim |= lim >> 2;
        lim |= lim >> 4;
        lim |= lim >> 8;
        lim |= lim >> 16;
        lim |= lim >> 32;
        var ran = first;
        while (true) {
            ran &= lim;
            if (ran <= n) return ran;
            ran = self.next();
        }
    }
};

fn generator(call: Call) Error!*Generator {
    try call.check(api.nilu_getupvalue(call.state, 1));
    defer call.pop(1);
    const block = api.nilu_touserdata(call.state, -1) orelse return error.Stack;
    return @ptrCast(@alignCast(block));
}

fn random(call: Call) Error!c_int {
    const state = try generator(call);
    const draw = state.next();
    var low: i64 = 1;
    var up: i64 = 0;
    switch (call.top()) {
        0 => {
            try call.pushNumber(@as(f64, @floatFromInt(draw >> 11)) * 0x1.0p-53);
            return 1;
        },
        1 => {
            up = try call.checkInteger(1);
            if (up == 0) {
                // Every bit, as Lua's.
                try call.pushInteger(@bitCast(draw));
                return 1;
            }
        },
        2 => {
            low = try call.checkInteger(1);
            up = try call.checkInteger(2);
        },
        else => return call.raise("wrong number of arguments"),
    }
    if (low > up) return call.argumentError(1, "interval is empty");
    const span: u64 = @bitCast(up -% low);
    const offset = state.project(draw, span);
    const result: i64 = low +% @as(i64, @bitCast(offset));
    try call.pushInteger(@intCast(result));
    return 1;
}

fn randomSeed(call: Call) Error!c_int {
    const state = try generator(call);
    var n1: i64 = 0;
    var n2: i64 = 0;
    if (call.typeAt(1) == .none) {
        n1 = @intCast(state.next() >> 11);
    } else {
        n1 = try call.checkInteger(1);
        n2 = try call.optInteger(2, 0);
    }
    state.seed(@bitCast(n1), @bitCast(n2));
    try call.pushInteger(@intCast(n1));
    try call.pushInteger(@intCast(n2));
    return 2;
}

test "generator matches Lua 5.5.1's sequence for seed 42" {
    var state: Generator = undefined;
    state.seed(42, 0);
    try std.testing.expectEqual(@as(f64, 0.9308121780395682), state.float());
    state.seed(42, 0);
    const expected = [_]u64{ 49, 75, 85 };
    for (expected) |value| try std.testing.expectEqual(value, state.project(state.next(), 99));
}

// Real functions: as Lua's, on the one number type.

fn sinOf(value: f64) f64 {
    return @sin(value);
}
fn cosOf(value: f64) f64 {
    return @cos(value);
}
fn tanOf(value: f64) f64 {
    return @tan(value);
}
fn asinOf(value: f64) f64 {
    return std.math.asin(value);
}
fn acosOf(value: f64) f64 {
    return std.math.acos(value);
}
fn expOf(value: f64) f64 {
    return @exp(value);
}
fn degOf(value: f64) f64 {
    return value * (180.0 / std.math.pi);
}
fn radOf(value: f64) f64 {
    return value * (std.math.pi / 180.0);
}
fn sin(call: Call) Error!c_int {
    return unary(call, sinOf);
}
fn cos(call: Call) Error!c_int {
    return unary(call, cosOf);
}
fn tan(call: Call) Error!c_int {
    return unary(call, tanOf);
}
fn asin(call: Call) Error!c_int {
    return unary(call, asinOf);
}
fn acos(call: Call) Error!c_int {
    return unary(call, acosOf);
}
fn exp(call: Call) Error!c_int {
    return unary(call, expOf);
}
fn deg(call: Call) Error!c_int {
    return unary(call, degOf);
}
fn rad(call: Call) Error!c_int {
    return unary(call, radOf);
}

/// atan(y [, x]): the angle of (x, y), x defaulting to 1, as Lua's.
fn atan(call: Call) Error!c_int {
    const y = try call.checkNumber(1);
    const x = try call.optNumber(2, 1);
    try call.pushNumber(std.math.atan2(y, x));
    return 1;
}

/// log(x [, base]): natural, or in the base, with Lua's exact cases for 2
/// and 10.
fn log(call: Call) Error!c_int {
    const x = try call.checkNumber(1);
    const answer = if (call.typeAt(2) == .none or call.typeAt(2) == .nil) @log(x) else blk: {
        const base = try call.checkNumber(2);
        break :blk if (base == 2) @log2(x) else if (base == 10) @log10(x) else @log(x) / @log(base);
    };
    try call.pushNumber(answer);
    return 1;
}

/// modf(x): the whole part toward zero and the rest; infinity has no rest.
fn modf(call: Call) Error!c_int {
    if (call.isIntegerAt(1)) {
        try call.pushValue(1);
        try call.pushNumber(0);
        return 2;
    }
    const x = try call.checkNumber(1);
    const whole = if (x < 0) @ceil(x) else @floor(x);
    try call.pushFloatAsInteger(whole);
    try call.pushNumber(if (std.math.isInf(x)) 0 else x - whole);
    return 2;
}

/// frexp(x): m and e with x = m * 2^e and 0.5 <= |m| < 1 (m is 0 for 0).
fn frexp(call: Call) Error!c_int {
    const parts = std.math.frexp(try call.checkNumber(1));
    try call.pushNumber(parts.significand);
    try call.pushInteger(@intCast(parts.exponent));
    return 2;
}

/// ldexp(m, e): m * 2^e; e must be a whole number.
fn ldexp(call: Call) Error!c_int {
    const m = try call.checkNumber(1);
    const e = try call.checkInteger(2);
    const clamped: i32 = @intCast(std.math.clamp(e, -4096, 4096));
    try call.pushNumber(std.math.ldexp(m, clamped));
    return 1;
}

/// type(x): the subtype of a number, "integer" or "float"; nil for
/// anything else.
fn mathType(call: Call) Error!c_int {
    try call.checkAny(1);
    if (call.typeAt(1) != .number) {
        try call.pushNil();
        return 1;
    }
    try call.push(if (call.isIntegerAt(1)) "integer" else "float");
    return 1;
}

/// tointeger(x): an integer as it is, a float that is one within 64 bits
/// as that integer, else nil. A string is not converted (manual 13.1).
fn toInteger(call: Call) Error!c_int {
    try call.checkAny(1);
    var isnum: c_int = 0;
    const n = api.nilu_tointegerx(call.state, 1, &isnum);
    if (call.typeAt(1) == .number and isnum != 0) {
        try call.pushInteger(n);
    } else try call.pushNil();
    return 1;
}

/// ult(m, n): m < n with both read as unsigned, as Lua compares its
/// integers; here the whole numbers up to 2^53 in two's complement.
fn ult(call: Call) Error!c_int {
    const m: u64 = @bitCast(try call.checkInteger(1));
    const n: u64 = @bitCast(try call.checkInteger(2));
    try call.pushBoolean(m < n);
    return 1;
}
