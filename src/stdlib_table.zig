//! `table` (manual 10.3): every element is read and written through the C
//! API's table access, so `__index`/`__newindex`/`__len` take part as in Lua.
//! `concat` joins strings only; `sort` is Lua's algorithm with the middle
//! element as the pivot every time (13.1).
const std = @import("std");
const api = @import("c_api.zig");
const stdlib = @import("stdlib.zig");

const Call = stdlib.Call;
const Error = stdlib.Error;
const entry = stdlib.entry;

pub fn open(call: Call) Error!void {
    try stdlib.openTable(call, "table", &.{
        .{ .name = "pack", .function = entry("pack", pack) },
        .{ .name = "create", .function = entry("create", create) },
        .{ .name = "unpack", .function = entry("unpack", unpack) },
        .{ .name = "insert", .function = entry("insert", insert) },
        .{ .name = "remove", .function = entry("remove", remove) },
        .{ .name = "concat", .function = entry("concat", concat) },
        .{ .name = "move", .function = entry("move", move) },
        .{ .name = "sort", .function = entry("sort", sort) },
    });
}

/// `#t` through the operator, so a `__len` answers; the answer must be an
/// integer the library can count with.
fn lengthOf(call: Call, index: c_int) Error!i64 {
    try call.check(api.nilu_len(call.state, index));
    var is_integer: c_int = 0;
    const length = api.nilu_tointegerx(call.state, -1, &is_integer);
    // Popped before a refusal, which pushes its message on top.
    call.pop(1);
    if (is_integer == 0) return call.raise("object length is not an integer");
    return length;
}

fn getAt(call: Call, table: c_int, key: i64) Error!void {
    try call.pushInteger(@intCast(key));
    try call.check(api.nilu_gettable(call.state, table));
}
/// Stores the top value at t[key] and pops it.
fn setAt(call: Call, table: c_int, key: i64) Error!void {
    try call.pushInteger(@intCast(key));
    call.insert(-2);
    try call.check(api.nilu_settable(call.state, table));
}

fn pack(call: Call) Error!c_int {
    const count = call.top();
    try call.check(api.nilu_newtable(call.state));
    call.insert(1);
    var index: c_int = count;
    while (index >= 1) : (index -= 1) try setAt(call, 1, index);
    try call.push("n");
    try call.pushInteger(@intCast(count));
    try call.check(api.nilu_settable(call.state, 1));
    return 1;
}

fn unpack(call: Call) Error!c_int {
    try call.checkTable(1);
    const first = try call.optInteger(2, 1);
    const last = if (call.typeAt(3) == .none or call.typeAt(3) == .nil) try lengthOf(call, 1) else try call.checkInteger(3);
    if (first > last) return 0;
    const count = last - first + 1;
    if (count >= std.math.maxInt(c_int) or count > @as(i64, @intCast(@import("runtime.zig").State.max_stack)) - @as(i64, call.top())) return call.raise("too many results to unpack");
    var key = first;
    while (key <= last) : (key += 1) {
        getAt(call, 1, key) catch |err| return if (err == error.Stack) call.raise("too many results to unpack") else err;
    }
    return @intCast(count);
}

fn insert(call: Call) Error!c_int {
    try call.checkTable(1);
    const size = try lengthOf(call, 1);
    var position = size + 1;
    switch (call.top()) {
        2 => {},
        3 => {
            position = try call.checkInteger(2);
            if (position < 1 or position > size + 1) return call.argumentError(2, "position out of bounds");
            var key = size + 1;
            while (key > position) : (key -= 1) {
                try getAt(call, 1, key - 1);
                try setAt(call, 1, key);
            }
        },
        else => return call.raise("wrong number of arguments to 'insert'"),
    }
    try setAt(call, 1, position);
    return 0;
}

fn remove(call: Call) Error!c_int {
    try call.checkTable(1);
    const size = try lengthOf(call, 1);
    var position = try call.optInteger(2, size);
    if (call.typeAt(2) != .none and call.typeAt(2) != .nil) {
        if (position < 1 or position > size + 1) return call.argumentError(2, "position out of bounds");
    }
    try getAt(call, 1, position);
    while (position < size) : (position += 1) {
        try getAt(call, 1, position + 1);
        try setAt(call, 1, position);
    }
    try call.pushNil();
    try setAt(call, 1, position);
    return 1;
}

fn concat(call: Call) Error!c_int {
    try call.checkTable(1);
    const separator = try call.optString(2, "");
    const first = try call.optInteger(3, 1);
    const last = if (call.typeAt(4) == .none or call.typeAt(4) == .nil) try lengthOf(call, 1) else try call.checkInteger(4);
    var buffer = try stdlib.Buffer.init(call, 64);
    var key = first;
    while (key <= last) : (key += 1) {
        try getAt(call, 1, key);
        // A number joins as `tostring` spells it, as `..` does.
        if (call.typeAt(-1) != .string and call.typeAt(-1) != .number) {
            var sentence: [128]u8 = undefined;
            const text = std.fmt.bufPrint(&sentence, "invalid value ({s}) at index {d} in table for 'concat'", .{ stdlib.typeName(call.typeAt(-1)), key }) catch "invalid value in table for 'concat'";
            return call.raise(text);
        }
        try buffer.append(call.bytesAt(-1));
        call.pop(1);
        if (key < last) try buffer.append(separator);
    }
    try buffer.finish();
    return 1;
}

fn move(call: Call) Error!c_int {
    try call.checkTable(1);
    const from = try call.checkInteger(2);
    const to = try call.checkInteger(3);
    const target = try call.checkInteger(4);
    const destination: c_int = if (call.typeAt(5) == .none or call.typeAt(5) == .nil) 1 else 5;
    if (destination == 5) try call.checkTable(5);
    if (to >= from) {
        if (!(from > 0 or to < std.math.maxInt(i64) + from)) return call.argumentError(3, "too many elements to move");
        const count = to - from + 1;
        if (target > std.math.maxInt(i64) - count + 1) return call.argumentError(4, "destination wrap around");
        const same = destination == 1 or api.nilu_rawequal(call.state, 1, 5) != 0;
        if (target > to or target <= from or !same) {
            var index: i64 = 0;
            while (index < count) : (index += 1) {
                try getAt(call, 1, from + index);
                try setAt(call, destination, target + index);
            }
        } else {
            var index: i64 = count - 1;
            while (index >= 0) : (index -= 1) {
                try getAt(call, 1, from + index);
                try setAt(call, destination, target + index);
            }
        }
    }
    try call.pushValue(destination);
    return 1;
}

// Sorting: Lua's auxsort with the pivot always at the middle of the interval.

const Sorter = struct {
    call: Call,
    has_comparator: bool,

    /// Is the value at `a` before the value at `b`? Both are stack indices.
    fn before(self: Sorter, a: c_int, b: c_int) Error!bool {
        const call = self.call;
        if (!self.has_comparator) {
            try call.check(api.nilu_compare(call.state, a, b, 1));
            defer call.pop(1);
            return call.truthy(-1);
        }
        try call.pushValue(2);
        try call.pushValue(a - 1);
        try call.pushValue(b - 2);
        try call.check(api.nilu_call(call.state, 2, 1));
        defer call.pop(1);
        return call.truthy(-1);
    }

    /// Stores the top two values at t[i] and t[j]: the top at j, the next at i.
    fn store2(self: Sorter, i: i64, j: i64) Error!void {
        try setAt(self.call, 1, i);
        try setAt(self.call, 1, j);
    }

    fn partition(self: Sorter, lo: i64, up: i64) Error!i64 {
        const call = self.call;
        var i = lo;
        var j = up - 1;
        while (true) {
            while (true) {
                i += 1;
                try getAt(call, 1, i);
                if (!try self.before(-1, -2)) break;
                if (i == up - 1) return call.raise("invalid order function for sorting");
                call.pop(1);
            }
            while (true) {
                j -= 1;
                try getAt(call, 1, j);
                if (!try self.before(-3, -1)) break;
                if (j < i) return call.raise("invalid order function for sorting");
                call.pop(1);
            }
            if (j < i) {
                call.pop(1);
                try self.store2(up - 1, i);
                return i;
            }
            try self.store2(i, j);
        }
    }

    fn sortRange(self: Sorter, low: i64, high: i64) Error!void {
        var lo = low;
        var up = high;
        while (lo < up) {
            const call = self.call;
            try getAt(call, 1, lo);
            try getAt(call, 1, up);
            if (try self.before(-1, -2)) try self.store2(lo, up) else call.pop(2);
            if (up - lo == 1) break;
            var p = @divFloor(lo + up, 2);
            try getAt(call, 1, p);
            try getAt(call, 1, lo);
            if (try self.before(-2, -1)) {
                try self.store2(p, lo);
            } else {
                call.pop(1);
                try getAt(call, 1, up);
                if (try self.before(-1, -2)) try self.store2(p, up) else call.pop(2);
            }
            if (up - lo == 2) break;
            try getAt(call, 1, p);
            try call.pushValue(-1);
            try getAt(call, 1, up - 1);
            try self.store2(p, up - 1);
            p = try self.partition(lo, up);
            if (p - lo < up - p) {
                try self.sortRange(lo, p - 1);
                lo = p + 1;
            } else {
                try self.sortRange(p + 1, up);
                up = p - 1;
            }
        }
    }
};

fn sort(call: Call) Error!c_int {
    try call.checkTable(1);
    const size = try lengthOf(call, 1);
    if (size > 1) {
        if (size >= std.math.maxInt(c_int)) return call.argumentError(1, "array too big");
        const has_comparator = call.typeAt(2) != .none and call.typeAt(2) != .nil;
        if (has_comparator) try call.checkFunction(2);
        try call.setTop(2);
        const sorter = Sorter{ .call = call, .has_comparator = has_comparator };
        try sorter.sortRange(1, size);
    }
    return 0;
}

/// table.create(nseq [, nrec]): an empty table with room reserved, as Lua 5.5's.
fn create(call: Call) Error!c_int {
    const sequence = try call.checkInteger(1);
    if (sequence < 0 or sequence > std.math.maxInt(c_int)) return call.argumentError(1, "out of range");
    const others = try call.optInteger(2, 0);
    if (others < 0 or others > std.math.maxInt(c_int)) return call.argumentError(2, "out of range");
    try call.check(api.nilu_createtable(call.state, @intCast(sequence), @intCast(others)));
    return 1;
}
