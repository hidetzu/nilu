//! A table's hash part: every key that is not in the array part (manual
//! 13.5), with open addressing and linear probing over one array of slots.
//! A key is found by its word first, so a key that is the same object as the
//! one stored costs one compare; only two different strings compare their
//! hashes and then their bytes. Each slot also has a byte of its key's hash,
//! read before the key, so a probe passing other keys touches only bytes.
//! A key cleared to nil keeps its slot (a dead key, which `next` may still
//! continue from); a key taken out leaves a mark, so the probes past it still
//! reach their keys. Its owner frees `slots` and `tags`.
const std = @import("std");
const runtime = @import("runtime.zig");
const Value = runtime.Value;
const HashPart = @This();

pub const Slot = struct { key: Value, value: Value };

/// An empty slot's key: nil is never a key.
const empty: Value = .nil;
/// A slot whose key was taken out: NaN is never a key either.
const removed: Value = .{ .bits = 0x7ff8_0000_0000_0000 };

slots: []Slot = &.{},
/// Per slot: `free`, `gone` (a key taken out) or a key's tag (`tagOf`).
tags: []u8 = &.{},
/// Keys present, those holding nil included.
count: u32 = 0,
/// Slots that are not empty: keys and the marks of keys taken out. A probe
/// stops only at an empty slot, so growth is decided on this.
taken: u32 = 0,
/// 64 minus log2 of the capacity: a hash's top bits are its slot.
shift: u6 = 63,
/// Room for the smallest storage (`small_slots` slots and their tags) that
/// the part's owner keeps for it, used instead of an allocation; never freed
/// here. Null for a part with no such room.
spare: ?*align(@alignOf(Slot)) [small_bytes]u8 = null,

pub const small_slots = 4;
pub const small_bytes = small_slots * (@sizeOf(Slot) + 1);

pub fn deinit(part: *HashPart, allocator: std.mem.Allocator) void {
    part.freeStorage(allocator);
    part.* = .{};
}

/// The form a key is stored in: a float that is an integer a value holds
/// itself is that integer, as Lua's keys are (both zeros among them); any
/// other key is itself. A float that is an integer past 2^45 is boxed
/// before it gets here (`State.storedKey`); hashing and comparing go by value
/// either way.
pub fn normal(key: Value) Value {
    if (key.isNumber()) {
        if (runtime.floatToInteger(key.asNumber())) |whole| if (Value.inlineInteger(whole)) |integer| return integer;
    }
    return key;
}

const free: u8 = 0;
const gone: u8 = 1;

fn mix(hash: u64) u64 {
    // Multiplying spreads every bit of the word or the string's hash into
    // the top bits, which pick the slot.
    return hash *% 0x9e37_79b9_7f4a_7c15;
}

fn slotOf(part: *const HashPart, mixed: u64) usize {
    return @intCast(mixed >> part.shift);
}

/// Seven bits the slot did not use, with the top bit set.
fn tagOf(mixed: u64) u8 {
    return @as(u8, @truncate(mixed >> 24)) | 0x80;
}

fn hashOf(key: Value) u64 {
    if (key.is(.string)) return key.asString().hash;
    // A number that is an integer hashes as that integer, in whichever form
    // it is (inline, boxed, or a float), so that equal keys meet.
    if (key.isNumber()) {
        if (runtime.floatToInteger(key.asNumber())) |whole| return integerHash(whole);
        return key.bits;
    }
    if (key.isInlineInteger()) return integerHash(key.asInlineInteger());
    if (key.is(.integer)) return integerHash(key.asInteger());
    return key.bits;
}

fn integerHash(n: i64) u64 {
    return (Value.inlineInteger(0).?.bits & ~((@as(u64, 1) << 47) - 1)) ^ @as(u64, @bitCast(n));
}

fn same(stored: Value, key: Value) bool {
    if (stored.bits == key.bits) return true;
    if (stored.is(.string) and key.is(.string)) {
        const a = stored.asString();
        const b = key.asString();
        return a.hash == b.hash and std.mem.eql(u8, a.bytes, b.bytes);
    }
    // Numbers by value: a boxed integer, or a float that is an integer.
    return (stored.isNumber() or stored.is(.integer)) and (key.isNumber() or key.is(.integer)) and stored.equal(key);
}

/// The slot holding the key, or null. The key must not be nil or NaN.
pub fn find(part: *const HashPart, key: Value) ?usize {
    if (part.count == 0) return null;
    const wanted = normal(key);
    const mask = part.slots.len - 1;
    const mixed = mix(hashOf(wanted));
    const tag = tagOf(mixed);
    var index = part.slotOf(mixed);
    while (true) : (index = (index + 1) & mask) {
        const found = part.tags[index];
        if (found == free) return null;
        if (found == tag and same(part.slots[index].key, wanted)) return index;
    }
}

/// The slot holding a string key with these bytes and `hash`, or null.
pub fn findString(part: *const HashPart, bytes: []const u8, hash: u64) ?usize {
    if (part.count == 0) return null;
    const mask = part.slots.len - 1;
    const mixed = mix(hash);
    const tag = tagOf(mixed);
    var index = part.slotOf(mixed);
    while (true) : (index = (index + 1) & mask) {
        const found = part.tags[index];
        if (found == free) return null;
        if (found != tag) continue;
        const stored = part.slots[index].key;
        if (stored.is(.string) and stored.asString().hash == hash and std.mem.eql(u8, stored.asString().bytes, bytes)) return index;
    }
}

/// `findString` for a name known at compile time, a metamethod's: the
/// length, then a compare of that many bytes the compiler lays out, instead
/// of the general byte compare (26 instructions for `__index`).
pub fn findName(part: *const HashPart, comptime name: []const u8, hash: u64) ?usize {
    if (part.count == 0) return null;
    const mask = part.slots.len - 1;
    const mixed = mix(hash);
    const tag = tagOf(mixed);
    var index = part.slotOf(mixed);
    while (true) : (index = (index + 1) & mask) {
        const found = part.tags[index];
        if (found == free) return null;
        if (found != tag) continue;
        const stored = part.slots[index].key;
        if (!stored.is(.string)) continue;
        const bytes = stored.asString().bytes;
        if (bytes.len == name.len and std.mem.eql(u8, bytes[0..name.len], name)) return index;
    }
}

/// Where a probe for the key ends: the key's slot, or the slot a new key
/// would take (the first marked or empty one) with `found` false.
pub const Probe = struct { index: usize, found: bool, tag: u8, fresh: bool };

/// The probe for a key; only when there are slots.
pub fn probe(part: *const HashPart, key: Value) Probe {
    std.debug.assert(part.slots.len != 0);
    const wanted = normal(key);
    const mask = part.slots.len - 1;
    const mixed = mix(hashOf(wanted));
    const tag = tagOf(mixed);
    var index = part.slotOf(mixed);
    var vacant: ?usize = null;
    while (true) : (index = (index + 1) & mask) {
        const found = part.tags[index];
        if (found == free) return .{ .index = vacant orelse index, .found = false, .tag = tag, .fresh = vacant == null };
        if (found == gone) {
            if (vacant == null) vacant = index;
        } else if (found == tag and same(part.slots[index].key, wanted)) return .{ .index = index, .found = true, .tag = tag, .fresh = false };
    }
}

/// Puts a new key where `probe` said it goes; the probe must be current
/// and must have room under the load limit (`hasRoom`).
pub fn insertAt(part: *HashPart, at: Probe, key: Value, value: Value) void {
    std.debug.assert(!at.found);
    if (at.fresh) part.taken += 1;
    part.slots[at.index] = .{ .key = normal(key), .value = value };
    part.tags[at.index] = at.tag;
    part.count += 1;
}

/// Whether one more key fits without growing.
pub fn hasRoom(part: *const HashPart) bool {
    return (@as(usize, part.taken) + 1) * 4 <= part.slots.len * 3;
}

pub fn get(part: *const HashPart, key: Value) ?Value {
    return if (part.find(key)) |index| part.slots[index].value else null;
}

pub fn getPtr(part: *const HashPart, key: Value) ?*Value {
    return if (part.find(key)) |index| &part.slots[index].value else null;
}

/// Adds a key that is not present. Answers whether the slots moved, which
/// invalidates every slot index and pointer taken before.
pub fn insert(part: *HashPart, allocator: std.mem.Allocator, key: Value, value: Value) error{OutOfMemory}!bool {
    return (try part.insertSlot(allocator, key, value)).moved;
}

/// `insert`, answering also the slot the key went into.
pub fn insertSlot(part: *HashPart, allocator: std.mem.Allocator, key: Value, value: Value) error{OutOfMemory}!struct { moved: bool, index: usize } {
    var moved = false;
    if ((@as(usize, part.taken) + 1) * 4 > part.slots.len * 3) {
        try part.grow(allocator, @as(usize, part.count) + 1);
        moved = true;
    }
    return .{ .moved = moved, .index = part.place(normal(key), value) };
}

/// Room for `total` keys without moving. Answers whether the slots moved.
pub fn ensureTotalCapacity(part: *HashPart, allocator: std.mem.Allocator, total: usize) error{OutOfMemory}!bool {
    if (total * 4 <= part.slots.len * 3 and part.taken < part.slots.len) return false;
    try part.grow(allocator, total);
    return true;
}

/// Whether filling an empty part with `total` keys would regrow it: the
/// first key's growth makes four slots, which hold three.
pub fn regrowsFilling(total: usize) bool {
    return total > 3;
}

/// Room for `total` keys in the fewest slots that hold them under the load
/// limit, on a part with no slots yet: a size the program stated (a
/// constructor, `nilu_createtable`), so no room is kept for growth. A size
/// that would not regrow is left to the first key, which saves nothing and
/// only moves the allocation earlier.
pub fn reserve(part: *HashPart, allocator: std.mem.Allocator, total: usize) error{OutOfMemory}!void {
    std.debug.assert(part.slots.len == 0);
    if (!regrowsFilling(total)) return;
    // The last key fits while total * 4 <= slots * 3 (`hasRoom`).
    const least = std.math.divCeil(usize, std.math.mul(usize, total, 4) catch return error.OutOfMemory, 3) catch unreachable;
    try part.resize(allocator, least);
}

/// A part holding `keys`, each once and each with a nil value, in the
/// fewest slots that hold them: a constructor's keys, which every table it
/// makes copies (`copyOf`) instead of inserting them one by one.
pub fn template(allocator: std.mem.Allocator, keys: []const Value) error{OutOfMemory}!HashPart {
    var part: HashPart = .{};
    errdefer part.deinit(allocator);
    const least = std.math.divCeil(usize, std.math.mul(usize, keys.len, 4) catch return error.OutOfMemory, 3) catch unreachable;
    try part.resize(allocator, least);
    for (keys) |key| {
        if (part.find(key) == null) _ = part.place(normal(key), .nil);
    }
    return part;
}

/// `source`'s keys and values in the same slots, in storage of this part's
/// own: the owner's room when they fit it. The part has no slots yet.
pub fn copyOf(part: *HashPart, allocator: std.mem.Allocator, source: *const HashPart) error{OutOfMemory}!void {
    std.debug.assert(part.slots.len == 0);
    const length = source.slots.len;
    if (length == 0) return;
    const block: []align(@alignOf(Slot)) u8 = if (length == small_slots and part.spare != null)
        part.spare.?[0..]
    else
        try allocator.alignedAlloc(u8, .of(Slot), length * (@sizeOf(Slot) + 1));
    const slots: []Slot = @as([*]Slot, @ptrCast(block.ptr))[0..length];
    const tags = block[length * @sizeOf(Slot) ..][0..length];
    @memcpy(slots, source.slots);
    @memcpy(tags, source.tags);
    part.* = .{ .slots = slots, .tags = tags, .count = source.count, .taken = source.taken, .shift = source.shift, .spare = part.spare };
}

/// Into the first slot that is empty or marked, which it answers; the key
/// is known absent.
fn place(part: *HashPart, key: Value, value: Value) usize {
    const mask = part.slots.len - 1;
    const mixed = mix(hashOf(key));
    var index = part.slotOf(mixed);
    while (true) : (index = (index + 1) & mask) {
        const found = part.tags[index];
        if (found == free) {
            part.taken += 1;
            break;
        }
        if (found == gone) break;
    }
    part.slots[index] = .{ .key = key, .value = value };
    part.tags[index] = tagOf(mixed);
    part.count += 1;
    return index;
}

/// New slots for at least `total` keys, at most half full.
fn grow(part: *HashPart, allocator: std.mem.Allocator, total: usize) error{OutOfMemory}!void {
    try part.resize(allocator, std.math.mul(usize, total, 2) catch return error.OutOfMemory);
}

/// New slots, at least `least` of them and a power of two, keeping every key
/// (dead ones too) and dropping the marks.
fn resize(part: *HashPart, allocator: std.mem.Allocator, least: usize) error{OutOfMemory}!void {
    const wanted = std.math.ceilPowerOfTwo(usize, @max(4, least)) catch return error.OutOfMemory;
    if (wanted > std.math.maxInt(u32)) return error.OutOfMemory;
    // One block: the slots, then their tags; the owner's room when it fits
    // and is not the storage being left.
    const block: []align(@alignOf(Slot)) u8 = if (wanted == small_slots and part.spare != null and !part.inSpare())
        part.spare.?[0..]
    else
        try allocator.alignedAlloc(u8, .of(Slot), std.math.mul(usize, wanted, @sizeOf(Slot) + 1) catch return error.OutOfMemory);
    const slots: []Slot = @as([*]Slot, @ptrCast(block.ptr))[0..wanted];
    const tags = block[wanted * @sizeOf(Slot) ..];
    @memset(slots, .{ .key = empty, .value = .nil });
    @memset(tags, free);
    const old = part.*;
    part.* = .{ .slots = slots, .tags = tags, .shift = @intCast(@as(u7, 64) - std.math.log2_int(usize, wanted)), .spare = old.spare };
    for (old.slots, old.tags) |slot, tag| {
        if (tag >= 0x80) _ = part.place(slot.key, slot.value);
    }
    var released = old;
    released.freeStorage(allocator);
}

/// The block `grow` made: slots and tags together.
fn freeStorage(part: *HashPart, allocator: std.mem.Allocator) void {
    if (part.slots.len == 0 or part.inSpare()) return;
    const block: []align(@alignOf(Slot)) u8 = @as([*]align(@alignOf(Slot)) u8, @ptrCast(part.slots.ptr))[0 .. part.slots.len * (@sizeOf(Slot) + 1)];
    allocator.free(block);
}

fn inSpare(part: *const HashPart) bool {
    const spare = part.spare orelse return false;
    return part.slots.len != 0 and @intFromPtr(part.slots.ptr) == @intFromPtr(spare);
}

/// Takes the key at `index` out.
pub fn remove(part: *HashPart, index: usize) void {
    part.slots[index] = .{ .key = removed, .value = .nil };
    part.tags[index] = gone;
    part.count -= 1;
}

/// The first slot at or after `from` that holds a key, or null.
pub fn nextKey(part: *const HashPart, from: usize) ?usize {
    var index = from;
    while (index < part.tags.len) : (index += 1) {
        if (part.tags[index] >= 0x80) return index;
    }
    return null;
}

test "a name found by findName is that name, not another of its length whose tag and slot are the same" {
    var state = try runtime.State.init(std.testing.allocator);
    defer state.deinit();
    var part: HashPart = .{};
    defer part.deinit(std.testing.allocator);
    try part.resize(std.testing.allocator, small_slots);
    const wanted = mix(runtime.hashString("__index"));
    // A seven-byte name that probes as `__index` does: the same tag and the
    // same first slot.
    var name: [7]u8 = "__aaaaa".*;
    const found = search: for (0..26 * 26 * 26 * 26) |n| {
        var rest = n;
        for (name[2..6]) |*byte| {
            byte.* = 'a' + @as(u8, @intCast(rest % 26));
            rest /= 26;
        }
        const mixed = mix(runtime.hashString(&name));
        if (tagOf(mixed) == tagOf(wanted) and part.slotOf(mixed) == part.slotOf(wanted)) break :search true;
    } else false;
    try std.testing.expect(found);
    _ = try part.insert(std.testing.allocator, .from(.{ .string = try state.newString(&name) }), .from(.{ .number = 1 }));
    try std.testing.expect(part.findName("__index", runtime.hashString("__index")) == null);
}
