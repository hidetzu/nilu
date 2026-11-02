const std = @import("std");
const bytecode = @import("bytecode.zig");
const chunk_id = @import("chunk_id.zig");
const execution = @import("execution_context.zig");

/// Internal execution failure, distinct from a raw C operation's status.
/// Value and source coordinates survive frame/AST teardown; no string equality
/// is used to recover a status. Public raise/relay transport remains separate.
pub const FailureKind = enum { out_of_memory, stack_limit, call_depth, interrupted, type_error, runtime_error, pending_feature, invalid_bytecode, invalid_native_result };
pub const FailureRecord = struct {
    kind: FailureKind,
    value: Value = .nil,
    position: ?@import("bytecode.zig").Position = null,
    location: ?@import("execution_location.zig").Location = null,
    operation: ?std.meta.Tag(bytecode.Instruction.Operation) = null,
    origin: enum { vm, native, host } = .host,
    diagnostic: ?@import("runtime_diagnostic.zig").Diagnostic = null,
    handled: bool = false,
    needs_message: bool = false,
};

/// Immutable after publication; separate from Value identity and table storage.
pub const FailureOrigin = struct {
    header: Header = .{ .kind = .failure_origin },
    record: FailureRecord = .{ .kind = .runtime_error },
};

pub const Hook = *const fn (*State) callconv(.c) c_int;

pub const Native = *const fn (*State) callconv(.c) c_int;
pub const Function = union(enum) {
    native: Native,
    c_closure: *CClosure,
    closure: *Closure,

    fn equal(a: Function, b: Function) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .native => |f| f == b.native,
            .c_closure => |f| f == b.c_closure,
            .closure => |f| f == b.closure,
        };
    }
};

/// A value's type as a program sees it; `type()` and failure messages name it.
pub const Type = enum { nil, boolean, number, string, table, function, userdata, thread };

/// One 64-bit word (ADR 0007). A number is its binary64 bits; anything else
/// is a payload in the low 48 bits under a tag in the top 16, taken from NaN
/// space arithmetic never produces. `unpack` gives the tagged union for code
/// that reads a kind and its payload together; hot paths test the bits.
/// A stack cut to `length`, what is past it left as it is. ArrayList's
/// `shrinkRetainingCapacity` makes the dropped slots undefined, and the VM
/// regrows a frame over them without filling (ADR 0005), so no stack is cut
/// that way.
pub fn cutStack(stack: *std.ArrayList(Value), length: usize) void {
    std.debug.assert(length <= stack.items.len);
    stack.items.len = length;
}

/// With `-Dpoison-registers`, the slots a frame's registers regrew over
/// hold a number no script makes, so that compiled code reading a register
/// it has not written gives another answer and a test fails; otherwise
/// nothing.
pub fn poison(slots: []Value) void {
    if (!@import("layout").poison_registers) return;
    for (slots) |*slot| slot.* = .from(.{ .number = -7.25e301 });
}

/// Room in a stack for `total` slots. Every slot between a stack's length
/// and its capacity holds nil or a value the collector has not freed: the
/// VM regrows a frame's registers without filling them (ADR 0005), and the
/// collector clears what is past the length. Growth keeps that by filling
/// the whole new room, since a reallocation copies only up to the length.
/// Every growth of a stack's capacity goes through here.
/// `cells` are the stack's open cells, whose pointers follow its slots when
/// they move (`Cell.value`).
pub inline fn growStack(stack: *std.ArrayList(Value), cells: []const *Cell, allocator: std.mem.Allocator, total: usize) error{OutOfMemory}!void {
    // The room is almost always there: the test where it is called, the
    // growth out of line.
    if (total <= stack.capacity) return;
    return growStackRarely(stack, cells, allocator, total);
}

noinline fn growStackRarely(stack: *std.ArrayList(Value), cells: []const *Cell, allocator: std.mem.Allocator, total: usize) error{OutOfMemory}!void {
    const before = stack.items.ptr;
    try stack.ensureTotalCapacity(allocator, total);
    fillNil(stack.allocatedSlice()[stack.items.len..]);
    if (stack.items.ptr != before) for (cells) |cell| {
        cell.value = &stack.items[cell.storage.open];
    };
}

/// Every slot nil. Two slots a store: a register window is a few slots,
/// where a loop of single stores spends more on its count than on storing,
/// and a call to memset more again. Volatile, so the optimizer does not turn
/// the loop back into that call.
pub fn fillNil(slots: []Value) void {
    const TwoSlots = @Vector(2, u64);
    var index: usize = 0;
    while (index + 2 <= slots.len) : (index += 2) @as(*align(@alignOf(Value)) volatile TwoSlots, @ptrCast(&slots[index])).* = @splat(Value.nil.bits);
    if (index < slots.len) @as(*volatile Value, &slots[index]).* = .nil;
}

pub const Value = packed struct(u64) {
    bits: u64,

    /// The value as a tagged union, the shape the code reads and builds.
    pub const Unpacked = union(enum) {
        nil,
        boolean: bool,
        number: f64,
        /// Any 64-bit integer: kept in the value in [-2^45, 2^45), a
        /// `BoxedInteger` otherwise.
        integer: i64,
        string: *String,
        table: *Table,
        native: Native,
        c_closure: *CClosure,
        closure: *Closure,
        userdata: *Userdata,
        thread: *Thread,
    };
    pub const Tag = std.meta.Tag(Unpacked);

    const shift = 48;
    const payload: u64 = (1 << shift) - 1;
    /// nil, false and true are the payloads 0, 1 and 2; any other payload is a
    /// thread's address, which is never one of those (ADR 0013).
    const special: u64 = 0xFFF9;
    const tag_string: u64 = 0xFFFA;
    const tag_table: u64 = 0xFFFB;
    const tag_userdata: u64 = 0xFFFC;
    const tag_native: u64 = 0xFFFD;
    const tag_c_closure: u64 = 0xFFFE;
    const tag_closure: u64 = 0xFFFF;
    /// The NaN a number in the tag range becomes (ADR 0007).
    const canonical_nan: u64 = 0xFFF8_0000_0000_0000;

    /// An integer in [-2^45, 2^45) is kept in the value itself: the special
    /// tag with the low two bits set, which no other payload under it has
    /// (nil, false and true are 0, 1 and 2, and a thread or a boxed integer
    /// is aligned). Bit 47 would not do: a user address on aarch64 Linux
    /// reaches past 2^47. The integer n is `inline_zero + 4n`: offset, so
    /// that the bits order as the integers do, and two inline integers add
    /// and subtract as their bits do. Any other integer is a
    /// `BoxedInteger`, a pointer under the special tag as a thread is, told
    /// apart by its header. Each integer has one form, so the bits of two
    /// inline integers are equal exactly when the integers are.
    const inline_mark: u64 = 3;
    const inline_low: u64 = special << shift | inline_mark;
    const inline_zero: u64 = inline_low | 1 << 47;
    const inline_test: u64 = 0xFFFF << shift | inline_mark;
    pub const inline_min: i64 = -(1 << 45);
    pub const inline_max: i64 = (1 << 45) - 1;

    pub const nil: Value = .{ .bits = special << shift };
    pub const @"false": Value = .{ .bits = special << shift | 1 };
    pub const @"true": Value = .{ .bits = special << shift | 2 };

    fn tagged(tag: u64, target: anytype) Value {
        const address: u64 = @intFromPtr(target);
        std.debug.assert(address & ~payload == 0);
        return .{ .bits = tag << shift | address };
    }

    fn pointer(value: Value, comptime T: type) T {
        return @ptrFromInt(@as(usize, @intCast(value.bits & payload)));
    }

    /// A number from outside the core's arithmetic: a NaN in the tag range
    /// becomes the canonical negative NaN.
    pub fn fromNumber(number: f64) Value {
        const bits: u64 = @bitCast(number);
        return .{ .bits = if (bits >> shift >= special) canonical_nan else bits };
    }

    /// A number the core's arithmetic produced from numbers: such a result is
    /// never in the tag range (ADR 0007), so it needs no check.
    pub fn fromNumberUnchecked(number: f64) Value {
        const value: Value = .{ .bits = @bitCast(number) };
        std.debug.assert(value.isNumber());
        return value;
    }

    /// The integer kept in the value, or null when it needs a
    /// `BoxedInteger` (`State.integer`).
    pub inline fn inlineInteger(n: i64) ?Value {
        // In range when n + 2^45 is below 2^46: one compare, not two.
        if (@as(u64, @bitCast(n)) +% (1 << 45) >= 1 << 46) return null;
        return .{ .bits = inline_zero +% (@as(u64, @bitCast(n)) << 2) };
    }

    /// A count or an index of things in memory as an integer: it is below
    /// 2^45, as no block is near 2^45 bytes, so the value holds it itself.
    pub fn fromCount(n: usize) Value {
        return inlineInteger(@intCast(n)) orelse unreachable;
    }

    /// An index to look up, of any size: the integer when the value holds
    /// it, else the float of the same value, which finds the same key
    /// (`HashPart` compares numbers by value). A search for a border can
    /// probe past 2^45 without allocating.
    pub fn probeIndex(n: u64) Value {
        if (n <= @as(u64, @intCast(inline_max))) return inlineInteger(@intCast(n)).?;
        return .from(.{ .number = @floatFromInt(n) });
    }

    pub inline fn isInlineInteger(value: Value) bool {
        return value.bits & inline_test == inline_low;
    }

    /// Whether every value is an inline integer. Each is tested whole: an
    /// AND of the values would let a native function's tag, which
    /// contains the special one, and an odd address pass.
    pub inline fn allInlineIntegers(values: anytype) bool {
        var differ: u64 = 0;
        inline for (values) |value| differ |= value.bits ^ inline_low;
        return differ & inline_test == 0;
    }

    pub inline fn asInlineInteger(value: Value) i64 {
        std.debug.assert(value.isInlineInteger());
        return @as(i64, @bitCast(value.bits -% inline_zero)) >> 2;
    }

    /// The bits of `inline_zero + 4n` when they still lie in the inline
    /// range, which holds the integers whose bits are `inline_low` plus
    /// below 2^48.
    inline fn inlineBits(bits: u64) ?Value {
        if ((bits -% inline_low) >> shift != 0) return null;
        return .{ .bits = bits };
    }

    /// The sum of two inline integers when a value holds it: their bits
    /// added, less one `inline_zero`. Two operands below 2^45 in size
    /// leave the sum's bits in reach of the range test.
    pub inline fn inlineSum(a: Value, b: Value) ?Value {
        return inlineBits(a.bits +% b.bits -% inline_zero);
    }

    pub inline fn inlineDifference(a: Value, b: Value) ?Value {
        return inlineBits(a.bits -% b.bits +% inline_zero);
    }

    /// Two inline integers order as their bits do.
    pub inline fn inlineLess(a: Value, b: Value) bool {
        return a.bits < b.bits;
    }

    pub inline fn isPositiveInline(value: Value) bool {
        return value.bits > inline_zero;
    }

    /// A heap object under the special tag: a thread or a boxed integer.
    fn specialObject(value: Value) ?*Header {
        if (value.bits >> shift != special or value.bits & payload <= 2 or value.bits & inline_mark != 0) return null;
        return value.pointer(*Header);
    }

    /// The value of a boxed integer, made only by `State.integer`.
    fn fromBoxed(boxed: *BoxedInteger) Value {
        std.debug.assert(@intFromPtr(boxed) & inline_mark == 0);
        return tagged(special, boxed);
    }

    pub fn fromBoolean(b: bool) Value {
        return if (b) .true else .false;
    }

    pub fn from(unpacked: Unpacked) Value {
        return switch (unpacked) {
            .nil => .nil,
            .boolean => |b| fromBoolean(b),
            .number => |n| fromNumber(n),
            .string => |p| tagged(tag_string, p),
            .table => |p| tagged(tag_table, p),
            .userdata => |p| tagged(tag_userdata, p),
            .native => |p| tagged(tag_native, p),
            .c_closure => |p| tagged(tag_c_closure, p),
            .closure => |p| tagged(tag_closure, p),
            .thread => |p| tagged(special, p),
            // A value that needs boxing is made by `State.integer`.
            .integer => |n| inlineInteger(n) orelse @panic("Value.from: an integer past 2^45 needs State.integer"),
        };
    }

    pub fn isNumber(value: Value) bool {
        return value.bits >> shift < special;
    }

    /// The number in a slot, or null when the slot holds something else. The
    /// word is loaded once, as a float, and its tag is tested in a register:
    /// a slot just written as a float and read back as an integer costs the
    /// arithmetic chain about 5% on the machine measured. The load
    /// is volatile so that the compiler does not turn it back into an integer
    /// load for the test.
    /// Reads a slot through a float register, for the copies on a chain that
    /// arithmetic also writes; see `numberIn`.
    pub fn load(slot: *const Value) Value {
        return @bitCast(@as(*const volatile f64, @ptrCast(slot)).*);
    }

    /// Writes a slot through a float register; see `load`.
    pub fn store(slot: *Value, value: Value) void {
        @as(*volatile f64, @ptrCast(slot)).* = @bitCast(value);
    }

    pub fn numberIn(slot: *const Value) ?f64 {
        const number = @as(*const volatile f64, @ptrCast(slot)).*;
        return if (@as(u64, @bitCast(number)) >> shift < special) number else null;
    }

    /// Writes a number the core's arithmetic produced (see
    /// `fromNumberUnchecked`) straight from a float register.
    pub fn storeNumber(slot: *Value, number: f64) void {
        @as(*f64, @ptrCast(slot)).* = number;
        std.debug.assert(slot.isNumber());
    }

    /// A number's value as a float, of either subtype; null for anything
    /// else. For a reader that wants the value and not the subtype.
    pub fn numberValue(value: Value) ?f64 {
        if (value.isNumber()) return value.asNumber();
        if (value.is(.integer)) return @floatFromInt(value.asInteger());
        return null;
    }

    pub fn asNumber(value: Value) f64 {
        std.debug.assert(value.isNumber());
        return @bitCast(value.bits);
    }

    pub fn kind(value: Value) Tag {
        return switch (value.bits >> shift) {
            // An inline integer first: the usual value under the tag.
            special => if (value.bits & inline_mark == inline_mark) .integer else if (value.bits == nil.bits) .nil else if (value.bits & payload <= 2) .boolean else if (value.pointer(*Header).kind == .integer) .integer else .thread,
            tag_string => .string,
            tag_table => .table,
            tag_userdata => .userdata,
            tag_native => .native,
            tag_c_closure => .c_closure,
            tag_closure => .closure,
            else => .number,
        };
    }

    pub fn is(value: Value, comptime k: Tag) bool {
        return switch (k) {
            .number => value.isNumber(),
            .nil => value.bits == nil.bits,
            .boolean => value.bits == @"true".bits or value.bits == @"false".bits,
            .string => value.bits >> shift == tag_string,
            .table => value.bits >> shift == tag_table,
            .userdata => value.bits >> shift == tag_userdata,
            .native => value.bits >> shift == tag_native,
            .c_closure => value.bits >> shift == tag_c_closure,
            .closure => value.bits >> shift == tag_closure,
            .thread => if (value.specialObject()) |object| object.kind == .thread else false,
            .integer => value.isInlineInteger() or (if (value.specialObject()) |object| object.kind == .integer else false),
        };
    }

    /// The integer an integer value holds, inline or boxed.
    pub fn asInteger(value: Value) i64 {
        if (value.isInlineInteger()) return value.asInlineInteger();
        std.debug.assert(value.is(.integer));
        const boxed: *const BoxedInteger = @fieldParentPtr("header", value.pointer(*Header));
        return boxed.value;
    }

    pub fn unpack(value: Value) Unpacked {
        return switch (value.kind()) {
            .nil => .nil,
            .boolean => .{ .boolean = value.bits == @"true".bits },
            .number => .{ .number = @bitCast(value.bits) },
            .string => .{ .string = value.pointer(*String) },
            .table => .{ .table = value.pointer(*Table) },
            .userdata => .{ .userdata = value.pointer(*Userdata) },
            .native => .{ .native = value.pointer(Native) },
            .c_closure => .{ .c_closure = value.pointer(*CClosure) },
            .closure => .{ .closure = value.pointer(*Closure) },
            .thread => .{ .thread = value.pointer(*Thread) },
            .integer => .{ .integer = value.asInteger() },
        };
    }

    pub fn asString(value: Value) *String {
        std.debug.assert(value.is(.string));
        return value.pointer(*String);
    }

    pub fn asTable(value: Value) *Table {
        std.debug.assert(value.is(.table));
        return value.pointer(*Table);
    }

    pub fn asClosure(value: Value) *Closure {
        std.debug.assert(value.is(.closure));
        return value.pointer(*Closure);
    }

    pub fn fromFunction(function: Function) Value {
        return switch (function) {
            .native => |f| tagged(tag_native, f),
            .c_closure => |f| tagged(tag_c_closure, f),
            .closure => |f| tagged(tag_closure, f),
        };
    }

    /// Read from the tag alone, as `unpack` would answer it.
    pub inline fn asFunction(value: Value) ?Function {
        return switch (value.bits >> shift) {
            tag_native => .{ .native = value.pointer(Native) },
            tag_c_closure => .{ .c_closure = value.pointer(*CClosure) },
            tag_closure => .{ .closure = value.pointer(*Closure) },
            else => null,
        };
    }

    /// A C function, plain or with upvalues, read from the tag alone: what
    /// a call guessed to be one tests (`callNativeOne`).
    pub inline fn cFunction(value: Value) ?Function {
        return switch (value.bits >> shift) {
            tag_native => .{ .native = value.pointer(Native) },
            tag_c_closure => .{ .c_closure = value.pointer(*CClosure) },
            else => null,
        };
    }

    pub fn isFunction(value: Value) bool {
        const tag = value.bits >> shift;
        return tag >= tag_native and tag <= tag_closure;
    }

    pub fn @"type"(value: Value) Type {
        return switch (value.kind()) {
            .nil => .nil,
            .boolean => .boolean,
            .number, .integer => .number,
            .string => .string,
            .table => .table,
            .native, .c_closure, .closure => .function,
            .userdata => .userdata,
            .thread => .thread,
        };
    }

    pub fn truthy(value: Value) bool {
        return value.bits != nil.bits and value.bits != @"false".bits;
    }

    pub fn typeName(value: Value) []const u8 {
        return @tagName(value.type());
    }

    /// Raw equality never invokes a metamethod or converts a value.
    pub fn equal(a: Value, b: Value) bool {
        // Two inline integers are equal when their bits are.
        if (allInlineIntegers(.{ a, b })) return a.bits == b.bits;
        if (a.isNumber()) {
            if (b.isNumber()) return a.asNumber() == b.asNumber();
            return b.is(.integer) and floatIsInteger(a.asNumber(), b.asInteger());
        }
        if (a.bits == b.bits) return true;
        // Two boxed integers are two objects; an integer is its value.
        if (a.is(.integer)) {
            if (b.isNumber()) return floatIsInteger(b.asNumber(), a.asInteger());
            return b.is(.integer) and a.asInteger() == b.asInteger();
        }
        if (a.is(.string) and b.is(.string)) {
            const x = a.asString();
            const y = b.asString();
            return x.hash == y.hash and std.mem.eql(u8, x.bytes, y.bytes);
        }
        return false;
    }

    /// Whether a table can hold the value as a key: anything but nil and NaN,
    /// as in Lua (the owner's answer). A table, a function
    /// or a userdata is a key by identity.
    pub fn validKey(value: Value) bool {
        return if (value.isNumber()) !std.math.isNan(value.asNumber()) else !value.is(.nil);
    }
};

const Kind = enum { string, table, closure, c_closure, cell, userdata, failure_origin, thread, integer };

/// Whether the float is exactly the integer, as Lua compares the two
/// subtypes: integral, within 64 bits, and the same number.
pub fn floatIsInteger(number: f64, integer: i64) bool {
    return floatToInteger(number) == integer;
}

/// The integer a float is exactly, or null: not integral, or outside 64
/// bits (2^63 itself is outside).
pub fn floatToInteger(number: f64) ?i64 {
    if (!(number >= -0x1p63 and number < 0x1p63)) return null;
    const whole: i64 = @intFromFloat(number);
    return if (@as(f64, @floatFromInt(whole)) == number) whole else null;
}

/// A 64-bit integer outside [-2^45, 2^45), which a value cannot hold
/// itself (`Value.inline_min`, `Value.inline_max`). Immutable; compared by its value.
pub const BoxedInteger = struct {
    header: Header = .{ .kind = .integer },
    value: i64,
};
/// `marked` is sticky (ADR 0006): an object that survived a collection
/// keeps it, and is old. A collection of the young only (`collectStep`)
/// marks from the roots and from the old objects written since the last
/// collection (`touched`, chained through `gray_next` from
/// `State.remembered`), and passes over every other old object as marked.
const Header = struct {
    kind: Kind,
    next: ?*Header = null,
    gray_next: ?*Header = null,
    /// In one byte, so that `State.barrier` tests marked and not touched
    /// with one compare.
    flags: packed struct(u8) {
        marked: bool = false,
        touched: bool = false,
        /// A safe build's check of a young collection (`verifyYoung`) keeps
        /// the marks here while it marks everything again.
        kept_mark: bool = false,
        _: u5 = 0,
    } = .{},
};

/// Where a string's bytes start in its block (`State.newString`): just
/// after the `String`, or for a long string at the next cache line, where
/// copying it measured faster (`bench/concat.nilu` +8% at 48 bytes in).
fn stringOffset(length: usize) usize {
    return if (length < 128) @sizeOf(String) else std.mem.alignForward(usize, @sizeOf(String), 64);
}

/// State-owned immutable bytes, including a sentinel beyond the counted bytes.
pub const String = struct {
    header: Header = .{ .kind = .string },
    bytes: [:0]const u8,
    /// `hashString(bytes)`, computed once: a string is immutable, and a
    /// table lookup by string key otherwise hashed its bytes every time.
    hash: u64,

    /// The block `State.newString` made: this, then the bytes and the sentinel.
    fn block(string: *String) []align(@alignOf(String)) u8 {
        return @as([*]align(@alignOf(String)) u8, @ptrCast(string))[0 .. stringOffset(string.bytes.len) + string.bytes.len + 1];
    }

    pub fn order(a: *const String, b: *const String) std.math.Order {
        return std.mem.order(u8, a.bytes, b.bytes);
    }
};

pub fn hashString(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(1, bytes);
}

const HashPart = @import("HashPart.zig");

/// Values moving down the stack, a few at a time: a loop, where the call to
/// memmove that copyForwards makes cost more than the copy. The destination
/// starts at or below the source, so copying forward is safe; volatile so
/// the optimizer does not turn the loop back into that call.
pub fn moveDown(destination: []Value, source: []const Value) void {
    std.debug.assert(destination.len == source.len and @intFromPtr(destination.ptr) <= @intFromPtr(source.ptr));
    for (destination, source) |*to, from| @as(*volatile Value, to).* = from;
}
pub const Pair = struct { key: Value, value: Value };

/// All entries and their keys belong to the same state as the table. Its owner
/// frees both parts. The array part holds the values of the keys 1..n in
/// order, a hole being nil, so a sequence costs one value per element and no
/// hash; every other key is in the hash, where a dead key remains until an
/// insertion compacts it. `live` counts the values of both parts; `dead`
/// counts the hash's cleared keys.
/// What a `get` or `set` with a constant string key remembers about the
/// table it last found the key in: a pointer to the value's slot, valid while
/// the table is the one with `generation` and its hash part has not moved
/// since (`layout`). A string key is never removed from the hash part, only
/// made dead, so a valid slot is still this key's. For another table, the
/// slot's index and the key stored there: a table holding that same key
/// object in that slot holds the field there, so a table made fresh by the
/// same constructor is found without a search. The key is kept alive by the
/// prototype (the collector marks it), so its address is never another
/// string's.
pub const FieldCache = struct {
    generation: u64 = 0,
    layout: u32 = 0,
    index: u32 = std.math.maxInt(u32),
    slot: *Value = undefined,
    key: Value = .nil,
};

pub const Table = struct {
    header: Header = .{ .kind = .table },
    hash: HashPart = .{},
    /// Unique among the tables a state ever made (0 is none), so a cache
    /// never mistakes a later table at the same address for this one.
    generation: u64 = 0,
    /// Advanced whenever the hash part's storage moves or a key leaves it.
    layout: u32 = 0,
    /// Where `next` last stopped in the hash part: after `key`'s slot, while
    /// `layout` is the table's. A traversal resumes there instead of
    /// searching for its key from the start, which made it quadratic. The key
    /// is compared only under a matching layout, when it is still one of the
    /// hash part's keys and so still reachable.
    traversal: struct { key: Value = .nil, index: u32 = 0, layout: u32 = 0 } = .{},
    array: std.ArrayList(Value) = .empty,
    live: u32 = 0,
    dead: u32 = 0,
    metatable: ?*Table = null,
    /// The chain of weak tables a collection met (ADR 0005); null otherwise.
    weak_next: ?*Table = null,
    /// The hash part's storage while it is the smallest (`HashPart.spare`):
    /// a table of a few fields is one block, not two, in the 256-byte
    /// class the table takes anyway. Last, after the fields every access
    /// reads.
    small_hash: [HashPart.small_bytes]u8 align(@alignOf(HashPart.Slot)) = undefined,

    /// The array part's slot for the key: a whole number from 1 to the part's
    /// length. NaN and everything else answer null.
    /// Whether the key is the number `index`, of either subtype.
    fn isIndex(key: Value, index: usize) bool {
        if (key.isInlineInteger()) return key.asInlineInteger() == @as(i64, @intCast(index));
        return key.isNumber() and key.asNumber() == @as(f64, @floatFromInt(index));
    }

    pub fn arraySlot(table: *const Table, key: Value) ?usize {
        if (key.isInlineInteger()) {
            const n = key.asInlineInteger();
            if (n < 1 or n > table.array.items.len) return null;
            return @intCast(n - 1);
        }
        if (!key.is(.number)) return null;
        const n = key.unpack().number;
        if (!(n >= 1 and n <= @as(f64, @floatFromInt(table.array.items.len)))) return null;
        const index: usize = @intFromFloat(n);
        if (@as(f64, @floatFromInt(index)) != n) return null;
        return index - 1;
    }

    pub fn get(table: *const Table, key: Value) Value {
        if (table.arraySlot(key)) |slot| return table.array.items[slot];
        if (!key.validKey()) return .nil;
        return table.hash.get(key) orelse .nil;
    }

    /// The field a cache names when it was filled from this table as it is.
    pub inline fn cachedField(table: *const Table, cache: *const FieldCache) ?*Value {
        if (cache.generation == table.generation and cache.layout == table.layout) return cache.slot;
        return null;
    }

    /// The key's field: from the cache's slot when this table holds the
    /// cached key there, else by a search; the cache then names this table.
    /// Null when absent.
    pub fn refreshCache(table: *Table, cache: *FieldCache, key: Value) ?*Value {
        if (table.positionalField(cache)) |slot| return slot;
        return table.remember(cache, table.hash.find(key) orelse return null);
    }

    /// The field in the cache's slot when this table holds the cached key
    /// there, as a table made by the same constructor does, without a
    /// search; the cache then names this table. Null otherwise.
    /// The slot the cache names, when this table holds the cached key there
    /// too, without taking the table into the cache: a table made from the
    /// same constructor template, read or filled once.
    /// An old table takes a reference only after `State.barrier` remembered
    /// it (ADR 0006); a safe build stops a write that skipped it.
    inline fn assertWritable(table: *const Table, value: Value) void {
        if (value.isNumber() or value.isInlineInteger()) return;
        if (std.debug.runtime_safety and table.header.flags.marked and !table.header.flags.touched) std.debug.panic("an old table was written without State.barrier", .{});
    }

    pub fn positionalSlot(table: *Table, cache: *const FieldCache) ?*Value {
        if (cache.index < table.hash.slots.len and table.hash.slots[cache.index].key.bits == cache.key.bits) return &table.hash.slots[cache.index].value;
        return null;
    }

    pub fn positionalField(table: *Table, cache: *FieldCache) ?*Value {
        if (cache.index < table.hash.slots.len and table.hash.slots[cache.index].key.bits == cache.key.bits) return table.remember(cache, cache.index);
        return null;
    }

    fn remember(table: *Table, cache: *FieldCache, index: usize) *Value {
        const slot = &table.hash.slots[index];
        cache.* = .{ .generation = table.generation, .layout = table.layout, .index = @intCast(index), .slot = &slot.value, .key = slot.key };
        return &slot.value;
    }

    /// `set` for a key that is not a number, whose field the cache names
    /// afterwards: one probe finds the key or where it goes. A constant
    /// string key's `set` takes this when the cache missed.
    pub fn setRemembering(table: *Table, allocator: std.mem.Allocator, cache: *FieldCache, key: Value, value: Value) error{OutOfMemory}!void {
        table.assertWritable(key);
        table.assertWritable(value);
        std.debug.assert(key.validKey() and !key.isNumber());
        if (try table.setInHash(allocator, key, value)) |index| _ = table.remember(cache, index);
    }

    /// A write through a slot `hashSlot` gave, keeping the live and dead
    /// counts as `set` does for a key already in the hash part.
    /// The next key of the sequence, into room the array part already has,
    /// when the hash part holds nothing that could move over: `set`'s append
    /// without its search of the hash part. False when that is not the case.
    /// `appendNext` for a key known to be the next index: the array part
    /// takes it when it has room and the hash part nothing that would move.
    /// The caller runs `State.barrier` after a true answer; the store holds
    /// nothing a collection could free in between.
    pub inline fn appendHere(table: *Table, value: Value) bool {
        const filled = table.array.items.len;
        if (table.hash.count != 0 or value.is(.nil) or filled == table.array.capacity) return false;
        table.array.items.len = filled + 1;
        table.array.items[filled] = value;
        table.live += 1;
        return true;
    }

    pub fn appendNext(table: *Table, key: Value, value: Value) bool {
        table.assertWritable(value);
        if (table.hash.count != 0 or value.is(.nil)) return false;
        const filled = table.array.items.len;
        if (filled == table.array.capacity or !isIndex(key, filled + 1)) return false;
        table.array.items.len = filled + 1;
        table.array.items[filled] = value;
        table.live += 1;
        return true;
    }

    /// A write to the array part at a slot `arraySlot` gave, keeping the live count.
    pub fn storeInArray(table: *Table, slot: usize, value: Value) void {
        table.assertWritable(value);
        const old = table.array.items[slot];
        if (old.is(.nil) and !value.is(.nil)) table.live += 1;
        if (!old.is(.nil) and value.is(.nil)) table.live -= 1;
        table.array.items[slot] = value;
    }

    pub fn storeAt(table: *Table, slot: *Value, value: Value) void {
        table.assertWritable(value);
        if (slot.*.is(.nil) and !value.is(.nil)) {
            table.dead -= 1;
            table.live += 1;
        } else if (!slot.*.is(.nil) and value.is(.nil)) {
            table.live -= 1;
            table.dead += 1;
        }
        slot.store(value);
    }

    pub fn getString(table: *const Table, bytes: []const u8) Value {
        return table.getStringHashed(bytes, hashString(bytes));
    }

    /// `getString` with the bytes' `hashString` already made.
    pub fn getName(table: *const Table, comptime name: []const u8) Value {
        const index = table.hash.findName(name, comptime hashString(name)) orelse return .nil;
        return table.hash.slots[index].value;
    }

    pub fn getStringHashed(table: *const Table, bytes: []const u8, hash: u64) Value {
        const index = table.hash.findString(bytes, hash) orelse return .nil;
        return table.hash.slots[index].value;
    }

    pub fn set(table: *Table, allocator: std.mem.Allocator, key: Value, value: Value) error{ OutOfMemory, InvalidKey }!void {
        table.assertWritable(key);
        table.assertWritable(value);
        if (!key.validKey()) return error.InvalidKey;
        if (table.arraySlot(key)) |slot| {
            table.storeInArray(slot, value);
            return;
        }
        if (!value.is(.nil) and isIndex(key, table.array.items.len + 1)) {
            // The next key of the sequence extends the array part. Keys that
            // were written ahead of it move over from the hash while they
            // continue the sequence; a failure to grow leaves them where they are.
            try table.array.append(allocator, value);
            table.live += 1;
            while (true) {
                const following: Value = Value.fromCount(table.array.items.len + 1);
                const index = table.hash.find(following) orelse break;
                table.layout +%= 1;
                if (table.hash.slots[index].value.is(.nil)) {
                    table.hash.remove(index);
                    table.dead -= 1;
                    break;
                }
                table.array.ensureUnusedCapacity(allocator, 1) catch break;
                const moved = table.hash.slots[index].value;
                table.hash.remove(index);
                table.array.appendAssumeCapacity(moved);
            }
            return;
        }
        _ = try table.setInHash(allocator, key, value);
    }

    /// The hash part's share of `set`, for a key the array part does not
    /// take: answers the slot the key is in afterwards, or null when nothing
    /// was stored (nil for an absent key).
    fn setInHash(table: *Table, allocator: std.mem.Allocator, key: Value, value: Value) error{OutOfMemory}!?usize {
        // One probe finds the key or the slot a new one takes.
        const at: ?HashPart.Probe = if (table.hash.slots.len != 0) table.hash.probe(key) else null;
        if (at != null and at.?.found) {
            const slot = &table.hash.slots[at.?.index].value;
            if (slot.*.is(.nil) and !value.is(.nil)) {
                table.dead -= 1;
                table.live += 1;
            } else if (!slot.*.is(.nil) and value.is(.nil)) {
                table.live -= 1;
                table.dead += 1;
            }
            slot.* = value;
            return at.?.index;
        }
        if (value.is(.nil)) return null;
        const stored_key = HashPart.normal(key);
        if (table.dead > table.live) {
            // Build the replacement before swapping: a failed insert preserves
            // all live values and the traversal's retained keys.
            var replacement: HashPart = .{};
            errdefer replacement.deinit(allocator);
            _ = try replacement.ensureTotalCapacity(allocator, @as(usize, table.live) + 1);
            var index: usize = 0;
            while (table.hash.nextKey(index)) |found| : (index = found + 1) {
                const slot = table.hash.slots[found];
                if (!slot.value.is(.nil)) _ = try replacement.insert(allocator, slot.key, slot.value);
            }
            _ = try replacement.insert(allocator, stored_key, value);
            table.hash.deinit(allocator);
            table.hash = replacement;
            table.hash.spare = &table.small_hash;
            table.dead = 0;
            table.layout +%= 1;
            table.live += 1;
            return table.hash.find(stored_key);
        }
        if (at != null and table.hash.hasRoom()) {
            table.hash.insertAt(at.?, stored_key, value);
            table.live += 1;
            return at.?.index;
        }
        const inserted = try table.hash.insertSlot(allocator, stored_key, value);
        if (inserted.moved) table.layout +%= 1;
        table.live += 1;
        return inserted.index;
    }

    /// Iteration order is unspecified: the array part in index order, then the
    /// hash in its order. Clearing the current field keeps its key valid for
    /// this call. Inserting a new key may invalidate traversal.
    pub fn next(table: *Table, key: Value) error{InvalidNextKey}!?Pair {
        var found = key.is(.nil);
        var start: usize = 0;
        if (table.arraySlot(key)) |slot| {
            found = true;
            start = slot + 1;
        }
        if (found) {
            for (table.array.items[start..], start..) |value, slot| {
                if (!value.is(.nil)) return .{ .key = Value.fromCount(slot + 1), .value = value };
            }
        }
        var index: usize = 0;
        if (!found and !table.traversal.key.is(.nil) and table.traversal.layout == table.layout and table.traversal.key.equal(key)) {
            index = table.traversal.index;
            found = true;
        }
        while (table.hash.nextKey(index)) |at| : (index = at + 1) {
            const slot = table.hash.slots[at];
            if (found) {
                if (!slot.value.is(.nil)) {
                    table.traversal = .{ .key = slot.key, .index = @intCast(at + 1), .layout = table.layout };
                    return .{ .key = slot.key, .value = slot.value };
                }
            } else if (slot.key.equal(key)) found = true;
        }
        if (!found) return error.InvalidNextKey;
        return null;
    }

    pub fn length(table: *const Table) u64 {
        const max_index: u64 = 1 << 53;
        const items = table.array.items;
        if (items.len > 0 and items[items.len - 1].is(.nil)) {
            // A hole at the end: some border lies inside the array part.
            var present: usize = 0;
            var absent: usize = items.len;
            while (absent - present > 1) {
                const middle = present + (absent - present) / 2;
                if (items[middle - 1].is(.nil)) absent = middle else present = middle;
            }
            return present;
        }
        if (items.len == 0 and table.get(.from(.{ .number = 1 })).is(.nil)) return 0;
        // The array part is all present; the search for a border continues in
        // the hash by doubling from its end, as it did from 1 before.
        var present: u64 = @max(items.len, 1);
        var absent: u64 = present * 2;
        while (!table.get(Value.probeIndex(absent)).is(.nil)) {
            if (absent >= max_index) return max_index;
            present = absent;
            absent *= 2;
        }
        while (absent - present > 1) {
            const middle = present + (absent - present) / 2;
            if (table.get(Value.probeIndex(middle)).is(.nil)) absent = middle else present = middle;
        }
        return present;
    }
};

/// The name of a prototype made without a program; not allocated, so never freed.
pub const no_chunk_name: [:0]const u8 = "";

/// State-owned loaded function, with constants and optional compiled code.
/// Every backing slice remains owned until the state closes.
pub const Prototype = struct {
    next: ?*Prototype = null,
    constants: []Value,
    code: []bytecode.Instruction = &.{},
    /// Each instruction's `Info`, which its `info` points into.
    info: []bytecode.Info = &.{},
    call_names: []?[:0]u8 = &.{},
    registers: usize = 0,
    upvalue_count: usize = 0,
    vararg: bool = false,
    parameters: usize = 0,
    captures: []const bytecode.Capture = &.{},
    children: []const *Prototype = &.{},
    source: []const u8 = &.{},
    /// Whether this prototype frees `source`. The functions of one chunk share
    /// its first prototype's copy: a copy each made a chunk of n functions hold
    /// n copies of its source. Prototypes live until the state closes or a
    /// failed preparation discards them together, so the owner never goes
    /// before a borrower is done with it.
    owns_source: bool = true,
    /// Owned, NUL-terminated so a C caller can borrow it (nilu_getinfo);
    /// `no_chunk_name` until a program names it.
    chunk_name: [:0]const u8 = no_chunk_name,
    /// A whole chunk, made into a function by `newChunk`: its one upvalue,
    /// when it has one, is its `_ENV` (what `nilu_setenv` replaces).
    chunk: bool = false,
    /// The line of the `function` that made this prototype; 0 for a chunk.
    /// A traceback names an unnamed function by it, as Lua's linedefined.
    line_defined: usize = 0,
    /// The line of its `end`; 0 for a chunk (Lua's lastlinedefined).
    last_line_defined: usize = 0,
    display_id: [chunk_id.capacity]u8 = @splat(0),
    display_length: usize = 0,
    /// Set by the VM once the code has passed validation; a prototype does not
    /// change after it is linked, so every later call skips the walk over its code.
    validated: bool = false,
    /// One per `get`/`set` with a constant string key, made with validation;
    /// the instruction holds the index.
    field_caches: []FieldCache = &.{},
    /// One per constructor with constant string keys: the keys in the slots
    /// its tables hold them (`HashPart.template`); the `table` instruction
    /// holds the index.
    table_templates: []HashPart = &.{},

    pub fn displayName(prototype: *const Prototype) []const u8 {
        return prototype.display_id[0..prototype.display_length];
    }
};

pub const Closure = struct {
    header: Header = .{ .kind = .closure },
    prototype: *Prototype,
    /// Right after the closure, in its block (`State.reserveClosure`).
    upvalues: []*Cell,

    fn block(closure: *Closure) []align(@alignOf(Closure)) u8 {
        return @as([*]align(@alignOf(Closure)) u8, @ptrCast(closure))[0 .. @sizeOf(Closure) + closure.upvalues.len * @sizeOf(*Cell)];
    }
};
pub const CClosure = struct {
    header: Header = .{ .kind = .c_closure },
    function: Native,
    upvalues: []Value,
};
pub const Cell = struct {
    header: Header = .{ .kind = .cell },
    storage: union(enum) { open: usize, closed: Value },
    /// The thread whose stack an open cell's slot is in (ADR 0013).
    owner: *Thread,
    /// Where the value is: the open slot in its thread's stack, or
    /// `storage.closed`. A read or write goes straight there; `growStack`
    /// moves it with the slots, and closing points it at the cell.
    value: *Value = undefined,

    /// Makes the cell closed, holding `value`.
    pub fn close(cell: *Cell, value: Value) void {
        cell.storage = .{ .closed = value };
        cell.value = &cell.storage.closed;
    }
};

/// What the state holds for the running thread, and a thread holds while it
/// does not run (ADR 0013). Moved, never copied: one of them is empty.
pub const ThreadStack = struct {
    stack: std.ArrayList(Value) = .empty,
    origins: std.ArrayList(?*FailureOrigin) = .empty,
    origins_end: usize = 0,
    open_cells: std.ArrayList(*Cell) = .empty,
    frames: std.ArrayList(Frame) = .empty,
    failure: ?FailureRecord = null,
    execution: ?*execution.Context = null,
    hook_window: ?execution.Window = null,
    non_yieldable: usize = 0,
    continuations: std.ArrayList(Continuation) = .empty,
    closing: std.ArrayList(Closing) = .empty,
    /// What nilu_where(N, 0) answers, each thread's own (the owner's answer).
    /// A copy: the `call_locations` slots
    /// belong to call depths every thread shares.
    last_call_location: ?@import("execution_location.zig").Location = null,

    pub fn deinit(stack: *ThreadStack, allocator: std.mem.Allocator) void {
        stack.closing.deinit(allocator);
        stack.continuations.deinit(allocator);
        stack.stack.deinit(allocator);
        stack.origins.deinit(allocator);
        stack.open_cells.deinit(allocator);
        stack.frames.deinit(allocator);
    }
};

/// What a C function runs when the protected call it made with `nilu_pcallk`
/// finishes after its coroutine yielded and was resumed.
pub const KFunction = *const fn (*State, c_int, isize) callconv(.c) c_int;

/// A C function waiting, in a suspended coroutine, on a protected call that
/// yielded (`nilu_pcallk`, ADR 0013).
pub const Continuation = struct {
    /// The C function's frame.
    frame: usize,
    /// The called function's slot, where its results or failure go.
    base: usize,
    results: ?usize,
    handler: ?Function,
    k: KFunction,
    context: isize,
};

/// A to-be-closed variable's value and the stack slot it lives in, kept here
/// as well: a failure unwinds the stack before the value is closed.
pub const Closing = struct { slot: usize, value: Value };

/// A coroutine, or the main program (ADR 0013).
pub const Thread = struct {
    header: Header = .{ .kind = .thread },
    status: enum { suspended, running, normal, dead } = .suspended,
    /// The function a thread runs when first resumed; nil once it has started.
    function: Value = .nil,
    /// What a coroutine that died by a failure failed with, for `close`.
    failure_value: ?Value = null,
    /// While it runs or waits as `normal`, the thread that resumed it: the
    /// collector reaches the waiting chain from the running thread.
    resumer: ?*Thread = null,
    saved: ThreadStack = .{},
};
pub const userdata_alignment = @alignOf(std.c.max_align_t);
pub const Userdata = struct {
    header: Header = .{ .kind = .userdata },
    bytes: [:0]align(userdata_alignment) u8,
    metatable: ?*Table = null,
    /// Values the host keeps with it (nilu_newuserdatauv), nil to begin with.
    user_values: []Value = &.{},
};
pub const CallKind = @FieldType(bytecode.Name, "kind");
/// State-owned caller code, not parser-arena storage. Keep the written name
/// through __call even though that entry has no public namewhat classification.
/// The caller's prototype and call instruction, from which the name and its
/// text are read when asked: a frame holds three words, not the copies.
pub const CallSite = struct {
    prototype: *const Prototype,
    instruction: *const bytecode.Instruction,
    through_call: bool,

    pub fn name(site: CallSite) ?bytecode.Name {
        return site.instruction.info.names.primary;
    }

    pub fn text(site: CallSite) ?[:0]const u8 {
        return if (site.instruction.info.call_name_index) |index| site.prototype.call_names[index] else null;
    }

    pub fn classification(site: CallSite) ?CallKind {
        if (site.through_call) return null;
        return if (site.name()) |found| found.kind else null;
    }
};
/// `instruction` is the one a script frame is executing: a pointer into the
/// prototype's code, which the state owns until it closes, so the frame stores
/// one word per step instead of a copy of the position. Null for a native.
pub const Frame = struct {
    base: usize,
    function: Function,
    instruction: ?*const bytecode.Instruction = null,
    /// A native's `CallSite` (`callSite`), in fields of its own rather than
    /// as an optional: the optional's tag and padding took the room the
    /// mark below needs, and the frame grew past 64 bytes.
    site_prototype: ?*const Prototype = null,
    site_instruction: ?*const bytecode.Instruction = null,
    site_through_call: bool = false,
    /// The frame of a `pcall` a script called that runs its callee in the
    /// script's run of frames (ADR 0009): a boundary that stops a failure
    /// above it, and on a return, `true` before the callee's results.
    protected_call: bool = false,
    /// To 64 bytes, a cache line a frame: at 56, frames straddled lines and
    /// `bench/fib.nilu` ran 1.025 the cycles in four layouts. Not an
    /// alignment, which a host's allocator need not give.
    line_padding: u64 = undefined,

    comptime {
        std.debug.assert(@sizeOf(Frame) == 64);
    }

    pub fn callSite(frame: *const Frame) ?CallSite {
        return .{ .prototype = frame.site_prototype orelse return null, .instruction = frame.site_instruction.?, .through_call = frame.site_through_call };
    }

    /// A native's frame, with the call site its caller's call gave it.
    pub fn native(base: usize, function: Function, site: ?CallSite) Frame {
        return if (site) |known| .{ .base = base, .function = function, .site_prototype = known.prototype, .site_instruction = known.instruction, .site_through_call = known.through_call } else .{ .base = base, .function = function };
    }

    pub fn position(frame: *const Frame) ?@import("bytecode.zig").Position {
        return if (frame.instruction) |instruction| instruction.info.position else null;
    }
};

const metamethod_names = [_][]const u8{
    "__index", "__newindex", "__add",      "__sub",    "__mul",       "__div",  "__idiv",
    "__mod",   "__pow",      "__unm",      "__concat", "__len",       "__eq",   "__lt",
    "__le",    "__call",     "__tostring", "__pairs",  "__metatable", "__name", "__gc",
};

/// Counts the bytes a state holds through its allocator, for
/// `collectgarbage("count")`. A state made by nilu_new allocates through one;
/// it sits on the heap so the allocator it hands out keeps its address.
pub const MemoryCount = struct {
    backing: std.mem.Allocator,
    in_use: usize = 0,
    /// Small blocks freed, by their length and alignment, kept for the next
    /// allocation of exactly that length and alignment: most objects (tables,
    /// strings, closures, cells, small hash parts) are small, made and freed
    /// by the thousand, and the host's allocator behind two indirect calls
    /// costs more than a list's pop. A block is always the host's own of
    /// that length and alignment, so one the cache never made (a test's
    /// write through its own allocator) is kept and given back alike. Given
    /// back when the state closes (`flush`), or at once past `cache_limit`.
    cached: [max_length * alignments.len]?*Free = @splat(null),
    cached_bytes: usize = 0,

    const max_length = 256;
    const alignments = [_]std.mem.Alignment{ .@"1", .@"8", .@"16" };
    const cache_limit = 4 << 20;
    const Free = struct { next: ?*Free };

    pub fn allocator(self: *MemoryCount) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    /// A block's list, or null for one that is not cached. A block holds
    /// a list's node, so it is at least that large and aligned.
    fn listOf(len: usize, alignment: std.mem.Alignment) ?usize {
        if (len < @sizeOf(Free) or len > max_length) return null;
        inline for (alignments, 0..) |known, index| {
            if (alignment == known) {
                if (comptime known.toByteUnits() < @alignOf(Free)) {
                    // A string's bytes: aligned as the host gives them, which
                    // is not known to hold a node unless the length is a
                    // multiple of the node's alignment and the block is.
                    return null;
                }
                return (len - 1) * alignments.len + index;
            }
        }
        return null;
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *MemoryCount = @ptrCast(@alignCast(context));
        if (listOf(len, alignment)) |list| {
            if (self.cached[list]) |node| {
                self.cached[list] = node.next;
                self.cached_bytes -= len;
                self.in_use += len;
                return @ptrCast(node);
            }
        }
        const memory = self.backing.rawAlloc(len, alignment, ra) orelse return null;
        self.in_use += len;
        return memory;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *MemoryCount = @ptrCast(@alignCast(context));
        if (!self.backing.rawResize(memory, alignment, new_len, ra)) return false;
        self.in_use = (self.in_use -| memory.len) + new_len;
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *MemoryCount = @ptrCast(@alignCast(context));
        const moved = self.backing.rawRemap(memory, alignment, new_len, ra) orelse return null;
        self.in_use = (self.in_use -| memory.len) + new_len;
        return moved;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *MemoryCount = @ptrCast(@alignCast(context));
        // Saturating: memory a caller allocated around the count (a test
        // writing through its own allocator) is freed here without having
        // been counted.
        self.in_use -|= memory.len;
        if (listOf(memory.len, alignment)) |list| {
            if (self.cached_bytes + memory.len <= cache_limit) {
                const node: *Free = @ptrCast(@alignCast(memory.ptr));
                node.* = .{ .next = self.cached[list] };
                self.cached[list] = node;
                self.cached_bytes += memory.len;
                return;
            }
        }
        self.backing.rawFree(memory, alignment, ra);
    }

    /// Gives every cached block back to the host's allocator.
    pub fn flush(self: *MemoryCount) void {
        for (&self.cached, 0..) |*head, list| {
            const len = list / alignments.len + 1;
            const alignment = alignments[list % alignments.len];
            while (head.*) |node| {
                head.* = node.next;
                self.backing.rawFree(@as([*]u8, @ptrCast(node))[0..len], alignment, @returnAddress());
            }
        }
        self.cached_bytes = 0;
    }
};

/// Owns all allocated objects, prototypes and stack/frame storage. Use deinit
/// once. Object references passed to its methods must belong to this state.
/// This is an internal runtime foundation, not the public C API or a VM.
pub const State = struct {
    pub const max_calls = 200;
    pub const handler_calls = 220;
    pub const max_upvalues = 255;
    pub const max_stack = 1_000_000;
    allocator: std.mem.Allocator,
    objects: ?*Header = null,
    object_count: usize = 0,
    prototypes: ?*Prototype = null,
    stack: std.ArrayList(Value) = .empty,
    /// Every cell still open on the stack, ordered by slot index, so closing a
    /// stack range and sharing a capture touch only the cells above it rather
    /// than every object the state owns. A cell leaves when it is closed or
    /// swept; it holds no ownership and is not a root.
    open_cells: std.ArrayList(*Cell) = .empty,
    frames: std.ArrayList(Frame) = .empty,
    globals: *Table = undefined,
    /// The host's references (nilu_ref): a table only C reaches, keyed by
    /// the reference. A collector root.
    registry: *Table = undefined,
    free_references: std.ArrayList(c_int) = .empty,
    next_reference: c_int = 1,
    /// The host's reader for `require`, `dofile` and `loadfile` (ADR 0003),
    /// or nil when the host gave none. A collector root.
    reader: Value = .nil,
    /// The host's writer for `print` (ADR 0003), or nil. A collector root.
    writer: Value = .nil,
    /// The metatable every string shares (manual 7, string methods): the
    /// `string` library sets it to `{__index = string}`. A collector root.
    string_metatable: ?*Table = null,
    /// The byte count of a state nilu_new made; null for one made directly.
    memory: ?*MemoryCount = null,
    failure: ?FailureRecord = null,
    // Separate from propagating failures. Each active transport depth owns one
    // preallocated publication slot: an outer completion cannot overwrite a
    // name borrowed after its inner call completed. Queries allocate nothing.
    call_locations: std.ArrayList(@import("execution_location.zig").Location) = .empty,
    call_location_depth: usize = 0,
    last_call_location_index: usize = 0,
    has_last_call_location: bool = false,
    execution: ?*execution.Context = null,
    origins: std.ArrayList(?*FailureOrigin) = .empty,
    /// One past the highest slot that may hold an origin: every write of an
    /// origin goes through `setOrigin`, so clearing a range above it is free.
    origins_end: usize = 0,
    memory_failure: *String = undefined,
    handling_failure: *String = undefined,
    names: [metamethod_names.len]*String = undefined,
    /// A reserved failure origin no call published (`releaseFailureOrigin`).
    /// It is not an object the collector owns, and `deinit` frees it.
    spare_origin: ?*FailureOrigin = null,
    /// The library's `pcall` as a value, which a script's call runs in its
    /// own run of frames (ADR 0009): one compare of a callee's bits finds it.
    /// Set by `nilu_openlibs`; nil without it.
    protected_call: Value = .nil,
    /// The base a C API call sees (`base`): the top frame's, a hook's window
    /// while it is on top, or 0 with neither. Asked on every C API call, so
    /// kept by `pushFrame`, `popFrame`, `popFrameInChain`, `frameCountChanged`
    /// and the hook's entry and exit.
    frame_base: usize = 0,
    /// Write it through `setCollectionThreshold`, which keeps `step_threshold`.
    collection_threshold: usize = 64,
    /// Below it neither a collection nor a hook is due: `collection_threshold
    /// + 1` without a hook, 0 with one, and never reached while the collector
    /// is stopped. Written through `setStepThreshold`.
    step_threshold: usize = 65,
    /// `step_threshold - object_count`, kept with both, so that the frame
    /// loop's test before each step reads one field, not two (`stepDue`).
    step_budget: i64 = 65,
    /// `collectgarbage("stop")`: no collection starts by itself until
    /// "restart"; an asked-for one still runs.
    collector_stopped: bool = false,
    hook: ?Hook = null,
    hook_interval: c_uint = 0,
    hook_remaining: c_uint = 0,
    vm_entries: usize = 0,
    /// The host's hook stopped the program (the owner's answer): until the
    /// host's call returns, a call runs nothing
    /// and a C function's return becomes the interruption, whatever a C
    /// function in between did with the status. Cleared when the outermost
    /// entry leaves (Context.leave).
    interrupted: bool = false,
    /// The last generation given to a table; see `Table.generation`.
    table_generations: u64 = 0,
    /// The innermost running hook callback's empty window; null outside hooks.
    /// A callee entered from the callback stacks its frames above it.
    hook_window: ?execution.Window = null,
    hook_depth: usize = 0,
    /// How many failure handlers are running in this state's execution chain;
    /// while one is, the call limit is the handler margin (ADR 0009).
    handlers_running: usize = 0,
    /// `callLimit`'s answer, kept as one field: it is read on every call, and
    /// computed there it cost script calls 3% of their instructions.
    call_limit: usize = max_calls,
    // Coroutines (ADR 0013), last so that the fields the frame loop reads keep
    // their places. `stack`, `open_cells`, `frames`, `failure`, `execution`,
    // `origins`, `hook_window` and `non_yieldable` are the running thread's;
    // `switchTo` moves them.
    /// The main program's thread, and the one running.
    main_thread: *Thread = undefined,
    running: *Thread = undefined,
    /// The frames of the threads waiting on a resume: a resume nests on the
    /// host's stack, so they count toward the same call limit.
    frames_below: usize = 0,
    /// Entries under which a yield is refused: a native calling back into the
    /// VM, a message handler, a hook (Lua's nny).
    non_yieldable: usize = 0,
    /// Set from a yield until its resume takes it: while it is, the levels
    /// unwinding keep the coroutine's frames and stack.
    yielding: bool = false,
    /// How many values the yield gave, the last slots of its stack.
    yielded: usize = 0,
    /// The running thread's C functions waiting on a protected call that
    /// yielded, in frame order: innermost last.
    continuations: std.ArrayList(Continuation) = .empty,
    /// The running thread's to-be-closed variables, innermost last.
    closing: std.ArrayList(Closing) = .empty,
    /// The newest object old at the last collection: the objects before it
    /// in `objects` are the young ones. Null before the first collection.
    /// These four are declared last: among the fields the frame loop reads
    /// on every step, they moved those fields and `bench/forsum.nilu` ran
    /// 1.06 the cycles in four layouts with the same instructions.
    young_boundary: ?*Header = null,
    /// Old objects written since the last collection (`barrier`).
    remembered: ?*Header = null,
    /// The object count after the last full collection, and whether the
    /// next one must be full: when the old ones have doubled since.
    major_base: usize = 0,
    next_major: bool = true,

    /// Returns an owning state; deinit releases it even if no collection runs.
    pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!State {
        var state = State{ .allocator = allocator };
        errdefer state.deinit();
        // Call entry uses storage acquired with the state, not an allocation
        // after the caller has transferred its argument window.
        try state.frames.ensureTotalCapacity(allocator, handler_calls);
        // One extra slot covers a call refused at the existing depth limit.
        try state.call_locations.resize(allocator, handler_calls + 1);
        state.main_thread = try state.newThread(.nil);
        state.main_thread.status = .running;
        state.running = state.main_thread;
        state.globals = try state.newTable();
        state.registry = try state.newTable();
        state.memory_failure = try state.newString("not enough memory");
        state.handling_failure = try state.newString("error in error handling");
        for (metamethod_names, 0..) |name, i| state.names[i] = try state.newString(name);
        return state;
    }

    /// The entire same-state handler subtree shares one absolute ceiling.
    /// Protected captures cannot hide a running outer handler or renew its room.
    /// The limit is read on every call, so the count of running handlers is
    /// kept rather than found by walking the execution chain each time.
    pub fn callLimit(state: *const State) usize {
        return state.call_limit;
    }

    /// Run after `handlers_running` or `frames_below` changes.
    pub fn updateCallLimit(state: *State) void {
        state.call_limit = @as(usize, if (state.handlers_running > 0) handler_calls else max_calls) -| state.frames_below;
    }

    /// A thread that will run `function` when first resumed.
    pub fn newThread(state: *State, function: Value) error{OutOfMemory}!*Thread {
        const thread = try state.allocator.create(Thread);
        thread.* = .{ .function = function };
        state.own(&thread.header);
        return thread;
    }

    /// Makes `thread` the running one: what the state held for the running
    /// thread moves into that thread, and `thread`'s moves into the state.
    pub fn switchTo(state: *State, thread: *Thread) void {
        // The outgoing thread takes the state's stack into itself.
        state.barrier(&state.running.header);
        state.running.saved = .{
            .stack = state.stack,
            .origins = state.origins,
            .origins_end = state.origins_end,
            .open_cells = state.open_cells,
            .frames = state.frames,
            .failure = state.failure,
            .execution = state.execution,
            .hook_window = state.hook_window,
            .non_yieldable = state.non_yieldable,
            .continuations = state.continuations,
            .closing = state.closing,
            .last_call_location = if (state.has_last_call_location) state.call_locations.items[state.last_call_location_index] else null,
        };
        const incoming = thread.saved;
        thread.saved = .{};
        state.stack = incoming.stack;
        state.origins = incoming.origins;
        state.origins_end = incoming.origins_end;
        state.open_cells = incoming.open_cells;
        state.frames = incoming.frames;
        state.failure = incoming.failure;
        state.execution = incoming.execution;
        state.hook_window = incoming.hook_window;
        state.frameCountChanged();
        state.non_yieldable = incoming.non_yieldable;
        state.continuations = incoming.continuations;
        state.closing = incoming.closing;
        state.has_last_call_location = incoming.last_call_location != null;
        if (incoming.last_call_location) |location| {
            // A slot above every call in progress: nothing live reads it.
            const slot = @min(state.call_location_depth, state.call_locations.items.len - 1);
            state.call_locations.items[slot] = location;
            state.last_call_location_index = slot;
        }
        state.running = thread;
    }

    /// The stack holding an open cell's slot: the state's while its thread
    /// runs, the thread's own while it does not.
    fn stackOf(state: *const State, thread: *const Thread) []Value {
        return if (thread == state.running) state.stack.items else thread.saved.stack.items;
    }

    /// Observer registration; allocates nothing. Null or zero removes the hook.
    /// The change applies to the whole state at once, inside a callback too.
    pub fn setHook(state: *State, hook: ?Hook, count: c_uint) void {
        state.hook = if (count == 0) null else hook;
        state.hook_interval = if (state.hook == null) 0 else count;
        state.updateStepThreshold();
        state.hook_remaining = state.hook_interval;
    }

    /// Called before dispatch. The current instruction counts only after the
    /// observer permits it; a terminal return has no later dispatch to observe.
    /// Each callback owns an empty stack suffix, discarded on continue or stop.
    /// A callback may run this state's VM again: the countdown is shared, so
    /// the inner instructions consume it, and an inner callback nests its own
    /// window above this one and gives it back on return.
    pub fn hookStep(state: *State) bool {
        const hook = state.hook orelse return false;
        if (state.hook_remaining == 0) {
            state.hook_remaining = state.hook_interval;
            const window = execution.Window.above(state);
            const outer = state.hook_window;
            state.hook_window = window;
            state.frameCountChanged();
            state.hook_depth += 1;
            defer {
                if (state.stack.items.len != window.base) window.rollback(state);
                state.hook_window = outer;
                state.frameCountChanged();
                state.hook_depth -= 1;
            }
            // A hook is not a frame a resume can return to (ADR 0013).
            state.non_yieldable += 1;
            defer state.non_yieldable -= 1;
            // An inner call the callback makes may be interrupted; the
            // callback's own answer alone decides for the outer call.
            const outer_interrupted = state.interrupted;
            defer state.interrupted = outer_interrupted;
            if (hook(state) != 0) return true;
        }
        if (state.hook != null and state.hook_remaining > 0) state.hook_remaining -= 1;
        return false;
    }

    pub fn deinit(state: *State) void {
        while (state.prototypes) |prototype| {
            state.prototypes = prototype.next;
            state.destroyPrototype(prototype);
        }
        while (state.objects) |object| {
            state.objects = object.next;
            state.destroy(object);
        }
        state.stack.deinit(state.allocator);
        state.open_cells.deinit(state.allocator);
        state.origins.deinit(state.allocator);
        state.frames.deinit(state.allocator);
        state.continuations.deinit(state.allocator);
        state.closing.deinit(state.allocator);
        state.free_references.deinit(state.allocator);
        state.call_locations.deinit(state.allocator);
        if (state.spare_origin) |token| state.allocator.destroy(token);
        state.* = undefined;
    }

    fn destroyPrototype(state: *State, prototype: *Prototype) void {
        state.allocator.free(prototype.constants);
        state.allocator.free(prototype.code);
        state.allocator.free(prototype.info);
        for (prototype.call_names) |name| if (name) |bytes| state.allocator.free(bytes);
        state.allocator.free(prototype.call_names);
        state.allocator.free(prototype.field_caches);
        for (prototype.table_templates) |*part| part.deinit(state.allocator);
        state.allocator.free(prototype.table_templates);
        state.allocator.free(prototype.captures);
        state.allocator.free(prototype.children);
        if (prototype.owns_source) state.allocator.free(prototype.source);
        if (prototype.chunk_name.ptr != no_chunk_name.ptr) state.allocator.free(prototype.chunk_name);
        state.allocator.destroy(prototype);
    }

    /// Only for nonexecuting chunk preparation: no collection/callback may run,
    /// and no newly allocated value may be stored into a preexisting root.
    /// The checkpoint's list heads must still belong to this state. Successful
    /// preparation retains its allocations; discard only an unpublished failure.
    pub const PreparationCheckpoint = struct {
        objects: ?*Header,
        prototypes: ?*Prototype,
    };

    pub fn preparationCheckpoint(state: *const State) PreparationCheckpoint {
        return .{ .objects = state.objects, .prototypes = state.prototypes };
    }

    pub fn discardPreparation(state: *State, checkpoint: PreparationCheckpoint) void {
        while (state.prototypes != checkpoint.prototypes) {
            const prototype = state.prototypes.?;
            state.prototypes = prototype.next;
            state.destroyPrototype(prototype);
        }
        while (state.objects != checkpoint.objects) {
            const object = state.objects.?;
            state.objects = object.next;
            // The newest old object, or a remembered one, gone: the next
            // collection is a full one, which reads neither.
            if (object == state.young_boundary or object.flags.touched) state.next_major = true;
            state.forgetOpenCell(object);
            state.destroy(object);
            state.object_count -= 1;
            state.step_budget +|= 1;
        }
    }

    fn own(state: *State, object: *Header) void {
        object.next = state.objects;
        state.objects = object;
        state.object_count += 1;
        state.step_budget -|= 1;
    }

    /// Returns immutable bytes owned by the state, not an interned string.
    /// One block: the `String`, then its bytes and the sentinel, as Lua
    /// keeps them. Two blocks cost an allocation more and put the bytes a
    /// cache line or more away from the length and hash a comparison reads
    /// first. `destroy` frees the block (`String.block`).
    pub fn newString(state: *State, bytes: []const u8) error{OutOfMemory}!*String {
        const offset = stringOffset(bytes.len);
        const length = std.math.add(usize, offset, bytes.len) catch return error.OutOfMemory;
        const block = try state.allocator.alignedAlloc(u8, .of(String), std.math.add(usize, length, 1) catch return error.OutOfMemory);
        const string: *String = @ptrCast(block.ptr);
        const copy = block[offset..length];
        @memcpy(copy, bytes);
        block[length] = 0;
        string.* = .{ .bytes = block[offset..length :0], .hash = hashString(bytes) };
        state.own(&string.header);
        return string;
    }

    /// An integer as a value: kept in the value when it fits, a
    /// `BoxedInteger` the state owns otherwise.
    /// A key as a table stores it: a float that is an integer too large for
    /// a value to hold is that integer, boxed, so that `next` answers an
    /// integer as Lua's does. `HashPart.normal` makes the rest.
    pub fn storedKey(state: *State, candidate: Value) error{OutOfMemory}!Value {
        if (candidate.isNumber()) if (floatToInteger(candidate.asNumber())) |whole| if (Value.inlineInteger(whole) == null) return state.integer(whole);
        return candidate;
    }

    pub fn integer(state: *State, n: i64) error{OutOfMemory}!Value {
        if (Value.inlineInteger(n)) |value| return value;
        const boxed = try state.allocator.create(BoxedInteger);
        boxed.* = .{ .value = n };
        state.own(&boxed.header);
        return Value.fromBoxed(boxed);
    }

    pub fn newTable(state: *State) error{OutOfMemory}!*Table {
        const table = try state.allocator.create(Table);
        state.table_generations += 1;
        table.* = .{ .generation = state.table_generations };
        table.hash.spare = &table.small_hash;
        state.own(&table.header);
        return table;
    }

    /// A table whose hash part is a copy of a constructor's template: its
    /// keys present with nil values, which the constructor's stores fill.
    /// When that room cannot be had, the table is already the collector's.
    pub fn newTableFrom(state: *State, items: usize, template: *const HashPart) error{OutOfMemory}!*Table {
        const table = try state.newTable();
        try table.array.ensureTotalCapacityPrecise(state.allocator, items);
        try table.hash.copyOf(state.allocator, template);
        table.dead = template.count;
        return table;
    }

    /// A table with room for `items` in its array part and `fields` in its
    /// hash part. When that room cannot be had, the table is already the
    /// collector's, which frees it.
    pub fn newTableSized(state: *State, items: usize, fields: usize) error{OutOfMemory}!*Table {
        const table = try state.newTable();
        try table.array.ensureTotalCapacityPrecise(state.allocator, items);
        try table.hash.reserve(state.allocator, fields);
        return table;
    }

    pub fn newUserdata(state: *State, length: usize) error{OutOfMemory}!*Userdata {
        return state.newUserdataWith(length, 0);
    }

    /// A userdata of `length` bytes with `count` user values, all nil.
    pub fn newUserdataWith(state: *State, length: usize, count: usize) error{OutOfMemory}!*Userdata {
        const values = try state.allocator.alloc(Value, count);
        errdefer state.allocator.free(values);
        @memset(values, Value.nil);
        // A private sentinel keeps even zero-length blocks distinct. The
        // sentinel slice also retains the exact allocation size for free().
        const allocation_length = std.math.add(usize, length, 1) catch return error.OutOfMemory;
        const bytes = try state.allocator.alignedAlloc(u8, .fromByteUnits(userdata_alignment), allocation_length);
        errdefer state.allocator.free(bytes);
        @memset(bytes, 0);
        const userdata = try state.allocator.create(Userdata);
        userdata.* = .{ .bytes = bytes[0..length :0], .user_values = values };
        state.own(&userdata.header);
        return userdata;
    }

    /// Copies the constants. The container and its constants survive collections
    /// until the state closes, even when no closure refers to this prototype.
    pub fn newPrototype(state: *State, constants: []const Value) error{OutOfMemory}!*Prototype {
        const copy = try state.allocator.dupe(Value, constants);
        errdefer state.allocator.free(copy);
        const prototype = try state.allocator.create(Prototype);
        prototype.* = .{ .constants = copy, .next = state.prototypes };
        state.prototypes = prototype;
        return prototype;
    }

    /// Copies code and source metadata as well as constants. Publication occurs
    /// only after every allocation succeeds; deinit owns all returned storage.
    pub fn newProgram(state: *State, constants: []const Value, code: []const bytecode.Written, registers: usize, source: []const u8, chunk_name: []const u8) error{OutOfMemory}!*Prototype {
        // Preparing a prototype runs once per function loaded: out of the
        // running code's groups, so that its size does not move them.
        @branchHint(.cold);
        const source_copy = try state.allocator.dupe(u8, source);
        errdefer state.allocator.free(source_copy);
        return state.makeProgram(constants, code, registers, source_copy, true, chunk_name);
    }

    /// As `newProgram`, for another function of the same chunk: it borrows
    /// `shared`, the source a prototype made by `newProgram` owns.
    pub fn newProgramSharing(state: *State, constants: []const Value, code: []const bytecode.Written, registers: usize, shared: []const u8, chunk_name: []const u8) error{OutOfMemory}!*Prototype {
        // Preparing a prototype runs once per function loaded: out of the
        // running code's groups, so that its size does not move them.
        @branchHint(.cold);
        return state.makeProgram(constants, code, registers, shared, false, chunk_name);
    }

    fn makeProgram(state: *State, constants: []const Value, code: []const bytecode.Written, registers: usize, source_copy: []const u8, owns_source: bool, chunk_name: []const u8) error{OutOfMemory}!*Prototype {
        // Preparing a prototype runs once per function loaded: out of the
        // running code's groups, so that its size does not move them.
        @branchHint(.cold);
        // The instructions that run, and beside them what a failure or a
        // listing reads of each (`bytecode.Info`).
        const info = try state.allocator.alloc(bytecode.Info, code.len);
        errdefer state.allocator.free(info);
        const code_copy = try state.allocator.alloc(bytecode.Instruction, code.len);
        errdefer state.allocator.free(code_copy);
        for (code, info, code_copy) |written, *entry, *instruction| {
            entry.* = .{ .position = .of(written.position), .names = written.names };
            instruction.* = .{ .operation = written.operation, .info = entry };
        }
        const name_copy = try state.allocator.dupeSentinel(u8, chunk_name, 0);
        errdefer state.allocator.free(name_copy);
        var count: usize = 0;
        for (code_copy) |instruction| switch (instruction.operation) {
            .call, .tail_call, .generic_call => {
                if (instruction.info.names.primary != null) count += 1;
            },
            else => {},
        };
        const call_names = try state.allocator.alloc(?[:0]u8, count);
        @memset(call_names, null);
        errdefer {
            for (call_names) |name| if (name) |bytes| state.allocator.free(bytes);
            state.allocator.free(call_names);
        }
        var index: usize = 0;
        for (code_copy, info) |instruction, *entry| {
            switch (instruction.operation) {
                .call, .tail_call, .generic_call => {},
                else => continue,
            }
            const name = entry.names.primary orelse continue;
            entry.call_name_index = std.math.cast(u32, index) orelse return error.OutOfMemory;
            index += 1;
            const text = @import("name_text.zig").resolve(state.allocator, source_copy, name) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // Keep malformed internal bytecode for validate to refuse.
                error.InvalidSpan => continue,
            };
            defer text.deinit(state.allocator);
            call_names[index - 1] = try state.allocator.dupeSentinel(u8, text.bytes, 0);
        }
        const prototype = try state.newPrototype(constants);
        prototype.code = code_copy;
        prototype.info = info;
        prototype.call_names = call_names;
        prototype.registers = registers;
        prototype.source = source_copy;
        prototype.owns_source = owns_source;
        prototype.chunk_name = name_copy;
        prototype.display_length = chunk_id.format(&prototype.display_id, chunk_name).len;
        return prototype;
    }

    /// Copies nested-prototype links and capture descriptors. The state frees
    /// both slices with the prototype; child prototypes remain separately owned.
    pub fn linkPrototype(state: *State, prototype: *Prototype, captures: []const bytecode.Capture, children: []const *Prototype) error{OutOfMemory}!void {
        // Preparing a prototype runs once per function loaded: out of the
        // running code's groups, so that its size does not move them.
        @branchHint(.cold);
        const copied_captures = try state.allocator.dupe(bytecode.Capture, captures);
        errdefer state.allocator.free(copied_captures);
        const copied_children = try state.allocator.dupe(*Prototype, children);
        state.allocator.free(prototype.captures);
        state.allocator.free(prototype.children);
        prototype.captures = copied_captures;
        prototype.children = copied_children;
    }

    /// Creates a chunk with its own closed environment cell, initially holding
    /// this state's globals. Repeated runs share this cell; other chunks do not.
    /// The state owns the closure and any allocated cell; GC/deinit frees them.
    pub fn newChunk(state: *State, prototype: *Prototype) error{ OutOfMemory, InvalidPrototype }!*Closure {
        // Preparing a prototype runs once per function loaded: out of the
        // running code's groups, so that its size does not move them.
        @branchHint(.cold);
        if (prototype.upvalue_count > 1) return error.InvalidPrototype;
        prototype.chunk = true;
        if (prototype.upvalue_count == 0) return state.newClosure(prototype, &.{});
        const cell = try state.allocator.create(Cell);
        cell.* = .{ .storage = .{ .open = 0 }, .owner = state.running };
        state.barrier(&cell.header);
        cell.close(.from(.{ .table = state.globals }));
        state.own(&cell.header);
        return state.newClosure(prototype, &.{cell});
    }

    pub fn newClosure(state: *State, prototype: *Prototype, upvalues: []const *Cell) error{OutOfMemory}!*Closure {
        const closure = try state.reserveClosure(prototype, upvalues.len);
        @memcpy(closure.upvalues, upvalues);
        state.own(&closure.header);
        return closure;
    }

    /// A closure with room for `count` upvalues, in one block with them, as
    /// Lua keeps them: one allocation a closure rather than two. It is not
    /// the state's yet, and its upvalues are undefined: the caller fills them
    /// and calls `ownClosure`, or `dropClosure` when filling them failed.
    pub fn reserveClosure(state: *State, prototype: *Prototype, count: usize) error{OutOfMemory}!*Closure {
        const size = std.math.add(usize, @sizeOf(Closure), std.math.mul(usize, count, @sizeOf(*Cell)) catch return error.OutOfMemory) catch return error.OutOfMemory;
        const block = try state.allocator.alignedAlloc(u8, .of(Closure), size);
        const closure: *Closure = @ptrCast(block.ptr);
        const cells: [*]*Cell = @ptrCast(@alignCast(block.ptr + @sizeOf(Closure)));
        closure.* = .{ .prototype = prototype, .upvalues = cells[0..count] };
        return closure;
    }

    pub fn ownClosure(state: *State, closure: *Closure) void {
        state.own(&closure.header);
    }

    pub fn dropClosure(state: *State, closure: *Closure) void {
        state.allocator.free(closure.block());
    }

    pub fn newCClosure(state: *State, function: Native, upvalues: []const Value) error{ OutOfMemory, TooManyUpvalues }!Function {
        if (upvalues.len > max_upvalues) return error.TooManyUpvalues;
        if (upvalues.len == 0) return .{ .native = function };
        const copy = try state.allocator.dupe(Value, upvalues);
        errdefer state.allocator.free(copy);
        const closure = try state.allocator.create(CClosure);
        closure.* = .{ .function = function, .upvalues = copy };
        state.own(&closure.header);
        return .{ .c_closure = closure };
    }

    /// Shares an existing open cell for the absolute stack slot, or allocates a
    /// state-owned one. Indices remain valid when the stack buffer moves.
    pub fn capture(state: *State, index: usize) error{ OutOfMemory, InvalidIndex }!*Cell {
        if (index >= state.stack.items.len) return error.InvalidIndex;
        const position = openCellPosition(state.open_cells.items, index);
        if (position < state.open_cells.items.len and state.open_cells.items[position].storage.open == index) return state.open_cells.items[position];
        try state.open_cells.ensureUnusedCapacity(state.allocator, 1);
        const cell = try state.allocator.create(Cell);
        cell.* = .{ .storage = .{ .open = index }, .owner = state.running, .value = &state.stack.items[index] };
        state.own(&cell.header);
        state.open_cells.insertAssumeCapacity(position, cell);
        return cell;
    }

    /// The place in the ordered open list of the first cell whose slot is not
    /// below `index`: where a cell for that slot is, or would be inserted.
    fn openCellPosition(cells: []const *Cell, index: usize) usize {
        var low: usize = 0;
        var high = cells.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (cells[middle].storage.open < index) low = middle + 1 else high = middle;
        }
        return low;
    }

    /// A swept or discarded object that was an open cell leaves the open list;
    /// otherwise the list would point at freed memory the next time a range closes.
    fn forgetOpenCell(state: *State, object: *Header) void {
        if (object.kind != .cell) return;
        const cell: *Cell = @fieldParentPtr("header", object);
        if (cell.storage != .open) return;
        const list = if (cell.owner == state.running) &state.open_cells else &cell.owner.saved.open_cells;
        const position = openCellPosition(list.items, cell.storage.open);
        if (position < list.items.len and list.items[position] == cell) _ = list.orderedRemove(position);
    }

    /// A swept thread's open cells are swept with it (an open cell reaches its
    /// thread). Closed, those swept after it no longer look for its list.
    fn forgetThreadCells(object: *Header) void {
        if (object.kind != .thread) return;
        const thread: *Thread = @fieldParentPtr("header", object);
        for (thread.saved.open_cells.items) |cell| cell.close(.nil);
    }

    pub fn readCell(state: *const State, cell: *const Cell) Value {
        if (std.debug.runtime_safety) if (cell.storage == .open) std.debug.assert(cell.value == &state.stackOf(cell.owner)[cell.storage.open]);
        // A closed cell, as `_ENV` is, read where it is, without the pointer's
        // extra load; an open one through the pointer, without its thread.
        return switch (cell.storage) {
            .closed => |value| value,
            .open => cell.value.*,
        };
    }

    pub fn writeCell(state: *State, cell: *Cell, value: Value) void {
        if (std.debug.runtime_safety) if (cell.storage == .open) std.debug.assert(cell.value == &state.stackOf(cell.owner)[cell.storage.open]);
        state.barrier(&cell.header);
        cell.value.* = value;
    }

    /// A reused/dropped stack window never inherits C failure provenance.
    pub fn clearOriginsFrom(state: *State, first: usize) void {
        // Metadata capacity may be reserved for a large fixed result request;
        // only live slots can carry an origin. Shrink clears before dropping.
        if (first >= state.origins_end) return;
        const end = @min(state.stack.items.len, state.origins.items.len, state.origins_end);
        if (first < end) @memset(state.origins.items[first..end], null);
        state.origins_end = first;
    }

    /// The one way an origin is stored, so that `origins_end` stays true.
    pub fn setOrigin(state: *State, slot: usize, origin: ?*FailureOrigin) void {
        state.origins.items[slot] = origin;
        if (origin != null and slot >= state.origins_end) state.origins_end = slot + 1;
    }

    pub inline fn ensureOrigins(state: *State, length: usize) error{OutOfMemory}!void {
        if (length <= state.origins.items.len) return;
        return state.growOrigins(length);
    }

    noinline fn growOrigins(state: *State, length: usize) error{OutOfMemory}!void {
        const old = state.origins.items.len;
        try state.origins.resize(state.allocator, length);
        @memset(state.origins.items[old..], null);
    }

    pub fn originAt(state: *const State, absolute: usize) ?*FailureOrigin {
        return if (absolute < state.origins.items.len) state.origins.items[absolute] else null;
    }

    /// A failure origin for a call about to run, made before it runs so that
    /// publishing a failure allocates nothing. It is not the collector's until
    /// `publishFailureOrigin`; one never published goes back through
    /// `releaseFailureOrigin`, and the next call takes it again: most calls
    /// end without a failure, and one made and dropped per call (336 bytes)
    /// was most of what a `pcall` loop allocated.
    pub fn reserveFailureOrigin(state: *State) error{OutOfMemory}!*FailureOrigin {
        if (state.spare_origin) |token| {
            state.spare_origin = null;
            return token;
        }
        const origin = try state.allocator.create(FailureOrigin);
        origin.* = .{};
        return origin;
    }

    /// The reserved origin becomes an object the collector owns. It was
    /// never one before, so the collector never marked it.
    pub fn publishFailureOrigin(state: *State, token: *FailureOrigin) void {
        state.own(&token.header);
    }

    /// A reserved origin that was never published: kept for the next call,
    /// or freed when one is kept already.
    pub fn releaseFailureOrigin(state: *State, token: *FailureOrigin) void {
        if (state.spare_origin == null) {
            state.spare_origin = token;
            return;
        }
        state.allocator.destroy(token);
    }

    pub fn closeFrom(state: *State, first: usize) void {
        state.clearOriginsFrom(first);
        state.closeCellsFrom(first);
    }

    /// `closeFrom` without the origins, for a caller that knows none is at
    /// or above `first`: it calls nothing.
    pub inline fn closeCellsFrom(state: *State, first: usize) void {
        if (std.debug.runtime_safety) std.debug.assert(first >= state.origins_end);
        // The list is ordered by slot, so every cell at or above `first` sits at
        // its end; a range with no open cell costs one comparison.
        while (state.open_cells.items.len > 0) {
            const cell = state.open_cells.items[state.open_cells.items.len - 1];
            const index = cell.storage.open;
            if (index < first) break;
            // Read before replacing the union: its result location may acquire
            // the closed tag before the initializer runs.
            const value = state.stack.items[index];
            state.barrier(&cell.header);
            cell.close(value);
            state.open_cells.items.len -= 1;
        }
    }

    /// Copy metadata rather than returning a pointer into relocatable frames.
    pub fn nativeCallSite(state: *const State) ?CallSite {
        const frame = state.frames.getLastOrNull() orelse return null;
        if (frame.function == .closure) return null;
        return frame.callSite();
    }

    /// A callback sees its own window only while no callee frame sits above it.
    /// `frame_base` already says which, since every change of the frames or
    /// of the hook's window updates it: this is asked on every C API call.
    pub fn base(state: *const State) usize {
        if (std.debug.runtime_safety) std.debug.assert(state.frame_base == state.baseFromFrames());
        return state.frame_base;
    }

    fn baseFromFrames(state: *const State) usize {
        if (state.hook_window) |window| {
            if (state.frames.items.len == window.frames) return window.base;
        }
        return if (state.frames.getLastOrNull()) |frame| frame.base else 0;
    }

    pub fn top(state: *const State) usize {
        return state.stack.items.len - state.base();
    }

    pub fn absoluteIndex(state: *const State, index: i64) ?usize {
        const count = state.top();
        if (index > 0) {
            const positive: u64 = @intCast(index);
            if (positive > count) return null;
            return state.base() + @as(usize, @intCast(positive)) - 1;
        }
        // -(minInt) overflows; measuring -(index + 1) avoids it.
        if (index == 0) return null;
        const from_top: u64 = @intCast(-(index + 1));
        if (from_top >= count) return null;
        return state.stack.items.len - 1 - @as(usize, @intCast(from_top));
    }

    pub fn get(state: *const State, index: i64) ?Value {
        return state.stack.items[state.absoluteIndex(index) orelse return null];
    }

    pub fn push(state: *State, value: Value) error{ OutOfMemory, StackLimit }!void {
        // With room in the stack and its origins, as there almost always is.
        const length = state.stack.items.len;
        if (length < state.stack.capacity and length < state.origins.items.len and length < max_stack) {
            state.stack.items.len = length + 1;
            state.stack.items[length] = value;
            state.origins.items[length] = null;
            return;
        }
        return state.pushGrowing(value);
    }

    noinline fn pushGrowing(state: *State, value: Value) error{ OutOfMemory, StackLimit }!void {
        if (state.stack.items.len >= max_stack) return error.StackLimit;
        try state.ensureOrigins(state.stack.items.len + 1);
        try growStack(&state.stack, state.open_cells.items, state.allocator, state.stack.items.len + 1);
        state.stack.appendAssumeCapacity(value);
        state.origins.items[state.stack.items.len - 1] = null;
    }

    /// The VM's own way to move the top: an absolute stack length, with no
    /// base, hook window or signed index to resolve. `setTop` is the C API's
    /// and does all of that, several times in every call. A shorter stack
    /// closes the cells above its end; a longer one is filled with nil.
    pub inline fn setLength(state: *State, length: usize) error{ OutOfMemory, StackLimit }!void {
        const old = state.stack.items.len;
        if (length <= old) {
            state.closeFrom(length);
            cutStack(&state.stack, length);
            return;
        }
        // The common case, a few registers with room already there: a loop,
        // where a call to memset costs more than the stores; volatile so the
        // optimizer does not turn it back into that call.
        if (length <= state.stack.capacity and length <= max_stack and (state.origins.items.len == 0 or length <= state.origins.items.len)) {
            state.stack.items.len = length;
            fillNil(state.stack.items[old..]);
            return;
        }
        return state.growTo(length);
    }

    /// A frame's registers regrown to `length` slots without filling them:
    /// each holds nil or a value the collector has not freed (`growStack`),
    /// and compiled code writes a register before it reads it. A shorter
    /// length shrinks as `setLength` does.
    pub inline fn extendRegisters(state: *State, length: usize) error{ OutOfMemory, StackLimit }!void {
        const old = state.stack.items.len;
        if (length <= old) {
            state.closeFrom(length);
            cutStack(&state.stack, length);
            return;
        }
        if (length <= state.stack.capacity and length <= max_stack and (state.origins.items.len == 0 or length <= state.origins.items.len)) {
            state.stack.items.len = length;
            poison(state.stack.items[old..]);
            return;
        }
        return state.growTo(length);
    }

    noinline fn growTo(state: *State, length: usize) error{ OutOfMemory, StackLimit }!void {
        const old = state.stack.items.len;
        if (length > max_stack) return error.StackLimit;
        // The common case, room already there, tests inline before any call.
        if (state.origins.items.len > 0 and length > state.origins.items.len) try state.ensureOrigins(length);
        try growStack(&state.stack, state.open_cells.items, state.allocator, length);
        state.stack.items.len = length;
        @memset(state.stack.items[old..], .nil);
    }

    /// The top `count` values off the stack, which holds at least that many
    /// above the base: the API's own pops, with no index to resolve.
    pub fn pop(state: *State, count: usize) void {
        std.debug.assert(count <= state.top());
        const target = state.stack.items.len - count;
        state.closeFrom(target);
        cutStack(&state.stack, target);
    }

    /// Internal index errors are returned; the future C boundary supplies its
    /// documented host-precondition abort. A failed growth leaves slots intact.
    pub fn setTop(state: *State, index: i64) error{ OutOfMemory, StackLimit, InvalidIndex }!void {
        const count = state.top();
        var target: usize = undefined;
        if (index >= 0) {
            const requested: u64 = @intCast(index);
            if (requested > max_stack - state.base()) return error.StackLimit;
            target = state.base() + @as(usize, @intCast(requested));
        } else {
            const remove: u64 = @intCast(-(index + 1));
            if (remove > count) return error.InvalidIndex;
            target = state.stack.items.len - @as(usize, @intCast(remove));
        }
        if (target < state.stack.items.len) {
            state.closeFrom(target);
            cutStack(&state.stack, target);
        } else {
            const old = state.stack.items.len;
            if (state.origins.items.len > 0) try state.ensureOrigins(target);
            try growStack(&state.stack, state.open_cells.items, state.allocator, target);
            state.stack.items.len = target;
            @memset(state.stack.items[old..], .nil);
        }
    }

    /// Raw frame storage. The VM checks depth before entry; state construction
    /// reserves room for every ordinary call frame. A frame's base cannot expose an enclosing frame's slots.
    pub fn pushFrame(state: *State, frame: Frame) error{ OutOfMemory, InvalidIndex }!void {
        if (frame.base < state.base() or frame.base > state.stack.items.len) return error.InvalidIndex;
        if (state.frames.items.len < state.frames.capacity) {
            state.frames.appendAssumeCapacity(frame);
        } else try state.frames.append(state.allocator, frame);
        state.frame_base = frame.base;
    }

    pub fn popFrame(state: *State) ?Frame {
        const popped = state.frames.pop();
        state.frameCountChanged();
        return popped;
    }

    /// A frame returning to its caller in the same run of frames: the
    /// caller's base is the base, since a run starts above any hook's window
    /// and so never ends on one. Every script return takes this.
    pub fn popFrameInChain(state: *State) void {
        _ = state.frames.pop();
        state.frame_base = state.frames.items[state.frames.items.len - 1].base;
        if (std.debug.runtime_safety) std.debug.assert(state.frame_base == state.baseFromFrames());
    }

    /// After anything that changes which frame is on top: `frame_base`
    /// follows it.
    pub fn frameCountChanged(state: *State) void {
        state.frame_base = state.baseFromFrames();
    }

    /// Raw metatable attachment. Library protection and handler invocation are
    /// separate; userdata finalizers are refused at this lower boundary too.
    pub fn setMetatable(state: *State, value: Value, metatable: ?*Table) error{ InvalidType, Finalizer }!void {
        switch (value.unpack()) {
            .table => |table| {
                state.barrier(&table.header);
                table.metatable = metatable;
            },
            // One metatable for every string, as Lua has.
            .string => state.string_metatable = metatable,
            .userdata => |userdata| {
                if (metatable) |table| if (!table.getString("__gc").is(.nil)) return error.Finalizer;
                state.barrier(&userdata.header);
                userdata.metatable = metatable;
            },
            else => return error.InvalidType,
        }
    }

    /// Before a reference is stored into an object: an old one is
    /// remembered, so that a young collection marks what it now holds.
    pub inline fn barrier(state: *State, object: *Header) void {
        if (@as(u8, @bitCast(object.flags)) & 0b11 == 0b01) {
            object.flags.touched = true;
            object.gray_next = state.remembered;
            state.remembered = object;
        }
    }

    pub fn setCollectionThreshold(state: *State, threshold: usize) void {
        state.collection_threshold = threshold;
        state.updateStepThreshold();
    }

    pub fn updateStepThreshold(state: *State) void {
        state.setStepThreshold(if (state.hook != null) 0 else if (state.collector_stopped) std.math.maxInt(usize) else state.collection_threshold +| 1);
    }

    pub fn setStepThreshold(state: *State, threshold: usize) void {
        state.step_threshold = threshold;
        const room = @as(i128, threshold) - @as(i128, state.object_count);
        state.step_budget = std.math.cast(i64, room) orelse std.math.maxInt(i64);
    }

    pub fn setCollectorStopped(state: *State, stopped: bool) void {
        state.collector_stopped = stopped;
        state.updateStepThreshold();
    }

    /// True when a collection or a hook may be due before the next step.
    pub fn stepDue(state: *const State) bool {
        std.debug.assert((state.step_budget <= 0) == (state.object_count >= state.step_threshold));
        return state.step_budget <= 0;
    }

    pub fn shouldCollect(state: *const State) bool {
        return !state.collector_stopped and state.object_count > state.collection_threshold;
    }

    fn markObject(gray: *?*Header, object: *Header) void {
        if (object.flags.marked) return;
        object.flags.marked = true;
        object.gray_next = gray.*;
        gray.* = object;
    }

    fn markFunction(gray: *?*Header, function: Function) void {
        switch (function) {
            .native => {},
            .closure => |closure| markObject(gray, &closure.header),
            .c_closure => |closure| markObject(gray, &closure.header),
        }
    }

    fn markValue(gray: *?*Header, value: Value) void {
        // A number of either kind is the usual value in a table and refers
        // to nothing, but a boxed integer: out before it is unpacked.
        if (value.isNumber() or value.isInlineInteger()) return;
        switch (value.unpack()) {
            .nil, .boolean, .number => {},
            .string => |string| markObject(gray, &string.header),
            .table => |table| markObject(gray, &table.header),
            .native => {},
            .c_closure => |closure| markObject(gray, &closure.header),
            .closure => |closure| markObject(gray, &closure.header),
            .userdata => |userdata| markObject(gray, &userdata.header),
            .thread => |thread| markObject(gray, &thread.header),
            .integer => if (value.specialObject()) |boxed| markObject(gray, boxed),
        }
    }

    fn markExecution(gray: *?*Header, chain: ?*execution.Context) void {
        var context = chain;
        while (context) |active| : (context = active.previous) {
            for (active.roots) |value| markValue(gray, value);
            if (active.suspended.get()) |record| markFailure(gray, record);
            // A reserved origin is not an object until it is published, and
            // its record is read only then (`reserveFailureOrigin`).
            if (active.raised.get()) |record| markFailure(gray, record);
            if (active.protection) |protection| {
                if (protection.handler) |handler| markFunction(gray, handler);
            }
        }
    }

    fn markFailure(gray: *?*Header, record: FailureRecord) void {
        markValue(gray, record.value);
        if (record.diagnostic) |diagnostic| {
            if (diagnostic.type_name) |name| markObject(gray, &name.header);
            if (diagnostic.other_name) |name| markObject(gray, &name.header);
        }
    }

    /// Allocation-free internal collection. The VM must call this only between
    /// instructions; constructors, raw table operations and stack edits never do.
    /// Tests force it directly; there is no host-facing collection API.
    /// A full collection: every object is marked again, the old included.
    pub fn collect(state: *State) void {
        state.collectWith(true);
    }

    /// The collection the frame loop starts: the young objects only, unless
    /// the old ones have doubled since the last full collection (ADR 0006).
    pub fn collectStep(state: *State) void {
        state.collectWith(state.next_major or state.young_boundary == null);
    }

    fn collectWith(state: *State, major: bool) void {
        var gray: ?*Header = null;
        if (major) {
            // Every mark goes, and with it every remembered object.
            var each = state.objects;
            while (each) |object| : (each = object.next) {
                object.flags.marked = false;
                object.flags.touched = false;
                object.gray_next = null;
            }
            state.remembered = null;
        } else {
            // The old objects written since the last collection are marked
            // already: they go straight to gray, so that what they now hold
            // is marked too.
            var each = state.remembered;
            state.remembered = null;
            while (each) |object| {
                each = object.gray_next;
                object.flags.touched = false;
                object.gray_next = gray;
                gray = object;
            }
        }
        state.markRoots(&gray);
        var weak: ?*Table = null;
        state.propagate(&gray, &weak);
        state.settleEphemerons(&gray, &weak);
        clearWeak(weak);
        if (!major and std.debug.runtime_safety) state.verifyYoung();
        // A young collection frees among the objects made since the last
        // one; whatever survives, of either kind, keeps its mark and is old.
        const stop: ?*Header = if (major) null else state.young_boundary;
        var link = &state.objects;
        while (link.*) |object| {
            if (object == stop) break;
            if (object.flags.marked) {
                link = &object.next;
            } else {
                link.* = object.next;
                state.forgetOpenCell(object);
                forgetThreadCells(object);
                state.destroy(object);
                state.object_count -= 1;
            }
        }
        state.young_boundary = state.objects;
        if (major) state.major_base = state.object_count;
        state.next_major = state.object_count > state.major_base *| 2;
        // The budget follows from the threshold set here, so the frees above
        // leave it alone.
        state.setCollectionThreshold(@max(64, state.object_count *| 2));
    }

    /// A safe build's check of a young collection, before it frees: every
    /// object marked again from the roots alone, the old included, must
    /// leave each young object it is about to free unmarked. One that is
    /// marked is held by an old object written without `barrier`.
    fn verifyYoung(state: *State) void {
        var each = state.objects;
        while (each) |object| : (each = object.next) {
            object.flags.kept_mark = object.flags.marked;
            object.flags.marked = false;
        }
        var gray: ?*Header = null;
        state.markRoots(&gray);
        var weak: ?*Table = null;
        state.propagate(&gray, &weak);
        state.settleEphemerons(&gray, &weak);
        while (weak) |table| {
            weak = table.weak_next;
            table.weak_next = null;
        }
        each = state.objects;
        while (each) |object| : (each = object.next) {
            if (object == state.young_boundary) break;
            if (!object.flags.kept_mark and object.flags.marked) std.debug.panic("young collection would free a reachable {s}: an old object was written without State.barrier", .{@tagName(object.kind)});
        }
        each = state.objects;
        while (each) |object| : (each = object.next) object.flags.marked = object.flags.kept_mark;
    }

    fn markRoots(state: *State, gray: *?*Header) void {
        // Past the length is not a root, and is cleared: what this sweep frees
        // is never found there when the VM regrows a frame (`growStack`).
        fillNil(state.stack.allocatedSlice()[state.stack.items.len..]);
        for (state.stack.items) |value| markValue(gray, value);
        for (state.origins.items[0..@min(state.stack.items.len, state.origins.items.len)]) |origin| {
            if (origin) |token| markObject(gray, &token.header);
        }
        for (state.frames.items) |frame| markFunction(gray, frame.function);
        markObject(gray, &state.globals.header);
        markObject(gray, &state.registry.header);
        markValue(gray, state.reader);
        markValue(gray, state.writer);
        if (state.string_metatable) |table| markObject(gray, &table.header);
        if (state.failure) |record| markFailure(gray, record);
        markExecution(gray, state.execution);
        for (state.continuations.items) |waiting| if (waiting.handler) |handler| markFunction(gray, handler);
        for (state.closing.items) |entry| markValue(gray, entry.value);
        markObject(gray, &state.main_thread.header);
        markObject(gray, &state.running.header);
        markObject(gray, &state.memory_failure.header);
        markObject(gray, &state.handling_failure.header);
        for (state.names) |name| markObject(gray, &name.header);
        var prototypes = state.prototypes;
        while (prototypes) |prototype| : (prototypes = prototype.next) {
            for (prototype.constants) |value| markValue(gray, value);
            for (prototype.field_caches) |cache| markValue(gray, cache.key);
        }
    }

    /// Marks what the gray objects reach. A weak table met on the way is
    /// chained onto `weak` (ADR 0005).
    fn propagate(state: *State, gray: *?*Header, weak: *?*Table) void {
        while (gray.*) |object| {
            gray.* = object.gray_next;
            object.gray_next = null;
            switch (object.kind) {
                .string, .integer => {},
                .failure_origin => {
                    const origin: *FailureOrigin = @fieldParentPtr("header", object);
                    markFailure(gray, origin.record);
                },
                .table => {
                    const table: *Table = @fieldParentPtr("header", object);
                    if (table.metatable) |metatable| markObject(gray, &metatable.header);
                    const mode = weakMode(table);
                    if (mode.keys or mode.values) {
                        table.weak_next = weak.*;
                        weak.* = table;
                    }
                    if (!mode.values) for (table.array.items) |value| markValue(gray, value) else for (table.array.items) |value| {
                        if (value.is(.integer)) markValue(gray, value);
                    };
                    var index: usize = 0;
                    while (table.hash.nextKey(index)) |at| : (index = at + 1) {
                        const key = table.hash.slots[at].key;
                        const value = table.hash.slots[at].value;
                        // A dead string key still anchors next(t, key), even if
                        // a different equal string is passed after collection.
                        // A weak table's strings are kept too: they are values.
                        if (!mode.keys or key.is(.string) or key.is(.integer)) markValue(gray, key);
                        if (value.is(.string) or value.is(.integer)) markValue(gray, value);
                        // A weak key keeps its value only while the key lives.
                        if (!mode.values and (!mode.keys or alive(key))) markValue(gray, value);
                    }
                },
                .closure => {
                    const closure: *Closure = @fieldParentPtr("header", object);
                    for (closure.upvalues) |cell| markObject(gray, &cell.header);
                },
                .c_closure => {
                    const closure: *CClosure = @fieldParentPtr("header", object);
                    for (closure.upvalues) |value| markValue(gray, value);
                },
                .cell => {
                    const cell: *Cell = @fieldParentPtr("header", object);
                    markValue(gray, state.readCell(cell));
                    if (cell.storage == .open) markObject(gray, &cell.owner.header);
                },
                .thread => {
                    // The running thread's stack is the state's, marked above;
                    // its `saved` is empty.
                    const thread: *Thread = @fieldParentPtr("header", object);
                    markValue(gray, thread.function);
                    if (thread.failure_value) |value| markValue(gray, value);
                    if (thread.resumer) |resumer| markObject(gray, &resumer.header);
                    const saved = &thread.saved;
                    fillNil(saved.stack.allocatedSlice()[saved.stack.items.len..]);
                    for (saved.stack.items) |value| markValue(gray, value);
                    for (saved.origins.items[0..@min(saved.stack.items.len, saved.origins.items.len)]) |origin| {
                        if (origin) |token| markObject(gray, &token.header);
                    }
                    for (saved.frames.items) |frame| markFunction(gray, frame.function);
                    if (saved.failure) |record| markFailure(gray, record);
                    markExecution(gray, saved.execution);
                    for (saved.continuations.items) |waiting| if (waiting.handler) |handler| markFunction(gray, handler);
                    for (saved.closing.items) |entry| markValue(gray, entry.value);
                },
                .userdata => {
                    const userdata: *Userdata = @fieldParentPtr("header", object);
                    if (userdata.metatable) |metatable| markObject(gray, &metatable.header);
                    for (userdata.user_values) |value| markValue(gray, value);
                },
            }
        }
    }

    const WeakMode = struct { keys: bool = false, values: bool = false };

    /// What the metatable's `__mode`, read raw as a string, makes weak.
    fn weakMode(table: *const Table) WeakMode {
        const metatable = table.metatable orelse return .{};
        const mode = metatable.getString("__mode");
        if (!mode.is(.string)) return .{};
        const text = mode.asString().bytes;
        return .{ .keys = std.mem.indexOfScalar(u8, text, 'k') != null, .values = std.mem.indexOfScalar(u8, text, 'v') != null };
    }

    /// Whether a value survives this collection: an object only when marked.
    fn alive(value: Value) bool {
        return switch (value.unpack()) {
            // An integer is a value, which a weak table never drops; its box
            // is marked with the table (`propagate`).
            .nil, .boolean, .number, .native, .integer => true,
            .string => |string| string.header.flags.marked,
            .table => |table| table.header.flags.marked,
            .userdata => |userdata| userdata.header.flags.marked,
            .c_closure => |closure| closure.header.flags.marked,
            .closure => |closure| closure.header.flags.marked,
            .thread => |thread| thread.header.flags.marked,
        };
    }

    /// Weak-key tables are ephemerons: a value reached only through its own
    /// key does not keep the key. Marks values whose keys turned out alive,
    /// until nothing changes.
    fn settleEphemerons(state: *State, gray: *?*Header, weak: *?*Table) void {
        while (true) {
            var changed = false;
            var next = weak.*;
            while (next) |table| : (next = table.weak_next) {
                const mode = weakMode(table);
                if (!mode.keys or mode.values) continue;
                var index: usize = 0;
                while (table.hash.nextKey(index)) |at| : (index = at + 1) {
                    const slot = table.hash.slots[at];
                    if (alive(slot.key) and !alive(slot.value)) {
                        markValue(gray, slot.value);
                        changed = true;
                    }
                }
            }
            if (!changed) return;
            state.propagate(gray, weak);
        }
    }

    /// Removes from each weak table what no longer lives: a value becomes nil
    /// (its key stays, as after assigning nil), an entry whose key goes is
    /// removed, and the table's layout moves so no cache keeps the slot.
    fn clearWeak(weak: ?*Table) void {
        var next = weak;
        while (next) |table| {
            next = table.weak_next;
            table.weak_next = null;
            const mode = weakMode(table);
            if (mode.values) for (table.array.items) |*slot| {
                if (!alive(slot.*)) {
                    slot.* = .nil;
                    table.live -= 1;
                }
            };
            var removed = false;
            var index: usize = 0;
            while (table.hash.nextKey(index)) |at| : (index = at + 1) {
                const slot = &table.hash.slots[at];
                const empty = slot.value.is(.nil);
                if (mode.keys and !alive(slot.key)) {
                    if (empty) table.dead -= 1 else table.live -= 1;
                    table.hash.remove(at);
                    removed = true;
                } else if (mode.values and !empty and !alive(slot.value)) {
                    slot.value = .nil;
                    table.live -= 1;
                    table.dead += 1;
                }
            }
            if (removed) table.layout +%= 1;
        }
    }

    fn destroy(state: *State, object: *Header) void {
        switch (object.kind) {
            .integer => {
                const boxed: *BoxedInteger = @fieldParentPtr("header", object);
                state.allocator.destroy(boxed);
            },
            .failure_origin => {
                const origin: *FailureOrigin = @fieldParentPtr("header", object);
                state.allocator.destroy(origin);
            },
            .string => {
                const string: *String = @fieldParentPtr("header", object);
                state.allocator.free(string.block());
            },
            .table => {
                const table: *Table = @fieldParentPtr("header", object);
                table.hash.deinit(state.allocator);
                table.array.deinit(state.allocator);
                state.allocator.destroy(table);
            },
            .closure => {
                const closure: *Closure = @fieldParentPtr("header", object);
                state.allocator.free(closure.block());
            },
            .c_closure => {
                const closure: *CClosure = @fieldParentPtr("header", object);
                state.allocator.free(closure.upvalues);
                state.allocator.destroy(closure);
            },
            .cell => {
                const cell: *Cell = @fieldParentPtr("header", object);
                state.allocator.destroy(cell);
            },
            .userdata => {
                const userdata: *Userdata = @fieldParentPtr("header", object);
                state.allocator.free(userdata.user_values);
                state.allocator.free(userdata.bytes);
                state.allocator.destroy(userdata);
            },
            .thread => {
                const thread: *Thread = @fieldParentPtr("header", object);
                thread.saved.deinit(state.allocator);
                state.allocator.destroy(thread);
            },
        }
    }
};

test {
    _ = @import("runtime_test.zig");
}

comptime {
    std.debug.assert(@sizeOf(Value) == 8);
}
