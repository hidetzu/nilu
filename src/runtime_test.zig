const std = @import("std");
const allocation_failures = @import("allocation_failures.zig");
const runtime = @import("runtime.zig");
const State = runtime.State;
const Value = runtime.Value;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const testing_allocator = std.testing.allocator;

fn native(_: *State) callconv(.c) c_int {
    return 0;
}

fn owned(state: *const State, address: usize) bool {
    var current = state.objects;
    while (current) |object| : (current = object.next) {
        if (@intFromPtr(object) == address) return true;
    }
    return false;
}

fn number(n: f64) Value {
    return .from(.{ .number = n });
}

fn text(state: *State, bytes: []const u8) !Value {
    return .from(.{ .string = try state.newString(bytes) });
}

test "runtime truth and equality preserve types bytes NaNs and object identities" {
    var state = try State.init(testing_allocator);
    defer state.deinit();
    const empty = try text(&state, "");
    const a = try text(&state, "a\x00\xff");
    const b = try text(&state, "a\x00\xff");
    try expect(a.unpack().string != b.unpack().string);
    try expect(a.equal(b));
    try expect(!Value.truthy(.nil));
    try expect(!Value.truthy(.from(.{ .boolean = false })));
    for ([_]Value{ .from(.{ .boolean = true }), number(0), number(-0.0), number(std.math.nan(f64)), empty, .fromFunction(.{ .native = native }) }) |value| try expect(value.truthy());
    try expect(number(0).equal(number(-0.0)));
    try expect(!number(std.math.nan(f64)).equal(number(std.math.nan(f64))));
    try expect(!number(1).equal(try text(&state, "1")));
    try expect(!Value.equal(.nil, .from(.{ .boolean = false })));
    const table = Value.from(.{ .table = try state.newTable() });
    try expect(table.equal(table));
    try expect(!table.equal(.from(.{ .table = try state.newTable() })));
    const userdata = Value.from(.{ .userdata = try state.newUserdata(1) });
    try expect(userdata.equal(userdata));
    try expect(!userdata.equal(.from(.{ .userdata = try state.newUserdata(1) })));
    const prototype = try state.newPrototype(&.{});
    const closure = Value.fromFunction(.{ .closure = try state.newClosure(prototype, &.{}) });
    try expect(closure.equal(closure));
    try expect(!closure.equal(.fromFunction(.{ .closure = try state.newClosure(prototype, &.{}) })));
    const c = try state.newCClosure(native, &.{number(1)});
    try expect(Value.equal(.fromFunction(c), .fromFunction(c)));
    try expect(!Value.equal(.fromFunction(c), .fromFunction(try state.newCClosure(native, &.{number(1)}))));
    const bare = Value.fromFunction(.{ .native = native });
    try expect(bare.equal(bare));
    try expect(!bare.equal(.fromFunction(c)));
    const values = [_]Value{ .nil, .from(.{ .boolean = true }), number(1), a, table, closure, userdata };
    for (values, [_][]const u8{ "nil", "boolean", "number", "string", "table", "function", "userdata" }) |value, name| try std.testing.expectEqualStrings(name, value.typeName());
}

test "runtime strings own arbitrary counted bytes and a trailing sentinel" {
    var state = try State.init(testing_allocator);
    defer state.deinit();
    var bytes = [_]u8{ 'a', 0, 255, 'z' };
    const string = try state.newString(&bytes);
    @memset(&bytes, 'x');
    try std.testing.expectEqualSlices(u8, &.{ 'a', 0, 255, 'z' }, string.bytes);
    try equal(@as(u8, 0), string.bytes[string.bytes.len]);
    const empty = try state.newString("");
    try equal(@as(usize, 0), empty.bytes.len);
    try equal(@as(u8, 0), empty.bytes[0]);
    try equal(std.math.Order.eq, string.order(try state.newString("a\x00\xffz")));
    try equal(std.math.Order.lt, empty.order(string));
    try equal(std.math.Order.gt, (try state.newString("\xff")).order(try state.newString("\x7f")));
    try equal(std.math.Order.lt, (try state.newString("a\x00")).order(try state.newString("a\x00b")));
}

test "runtime tables restrict writes but invalid reads answer nil" {
    var state = try State.init(testing_allocator);
    defer state.deinit();
    const table = try state.newTable();
    // Only nil and NaN cannot be keys (the owner's answer).
    const invalid = [_]Value{ .nil, number(std.math.nan(f64)) };
    for (invalid) |key| {
        try expect(table.get(key).is(.nil));
        try std.testing.expectError(error.InvalidKey, table.set(testing_allocator, key, number(1)));
        try std.testing.expectError(error.InvalidKey, table.set(testing_allocator, key, .nil));
    }
    const keys = [_]Value{ number(1), number(1.5), number(-3), number(std.math.inf(f64)), number(-std.math.inf(f64)), try text(&state, "1"), try text(&state, "\x00\xff"), .from(.{ .boolean = false }), .from(.{ .boolean = true }), .from(.{ .table = try state.newTable() }), .fromFunction(.{ .native = native }), .from(.{ .userdata = try state.newUserdata(0) }) };
    for (keys, 0..) |key, i| try table.set(testing_allocator, key, number(@floatFromInt(i + 1)));
    for (keys, 0..) |key, i| try expect(table.get(key).equal(number(@floatFromInt(i + 1))));
    try equal(@as(u32, keys.len), table.live);
    try expect(table.get(number(2)).is(.nil));
}

test "runtime table keys compare strings by content and canonicalize signed zero" {
    var state = try State.init(testing_allocator);
    defer state.deinit();
    const table = try state.newTable();
    const first = try text(&state, "a\x00b");
    const second = try text(&state, "a\x00b");
    state.barrier(&table.header);
    try table.set(testing_allocator, first, number(1));
    try expect(table.get(second).equal(number(1)));
    state.barrier(&table.header);
    try table.set(testing_allocator, second, number(2));
    try equal(@as(u32, 1), table.live);
    try expect(table.getString("a\x00b").equal(number(2)));
    const zeros = try state.newTable();
    state.barrier(&zeros.header);
    try zeros.set(testing_allocator, number(-0.0), number(1));
    try expect(zeros.get(number(0)).equal(number(1)));
    state.barrier(&zeros.header);
    try zeros.set(testing_allocator, number(0), number(2));
    try equal(@as(u32, 1), zeros.live);
    const pair = (try zeros.next(.nil)).?;
    try equal(@as(u64, 0), @as(u64, @bitCast(pair.key.numberValue().?)));
}

test "runtime table deletion preserves traversal and compacts only on insertion" {
    var state = try State.init(testing_allocator);
    defer state.deinit();
    const table = try state.newTable();
    for (0..20) |i| try table.set(testing_allocator, try text(&state, &[_]u8{'a' + @as(u8, @intCast(i))}), number(@floatFromInt(i)));
    var key: Value = .nil;
    var seen: usize = 0;
    while (try table.next(key)) |pair| {
        key = pair.key;
        state.barrier(&table.header);
        try table.set(testing_allocator, key, .nil);
        try expect(table.get(key).is(.nil));
        seen += 1;
    }
    try equal(@as(usize, 20), seen);
    try equal(@as(u32, 0), table.live);
    try equal(@as(u32, 20), table.dead);
    try equal(@as(u64, 0), table.length());
    try expect(try table.next(.nil) == null);
    try std.testing.expectError(error.InvalidNextKey, table.next(number(99)));
    try std.testing.expectError(error.InvalidNextKey, table.next(.from(.{ .boolean = true })));
    state.barrier(&table.header);
    try table.set(testing_allocator, try text(&state, "a"), number(1));
    try equal(@as(u32, 19), table.dead);
    state.barrier(&table.header);
    try table.set(testing_allocator, try text(&state, "a"), .nil);
    state.barrier(&table.header);
    try table.set(testing_allocator, try text(&state, "zz"), .nil);
    try equal(@as(u32, 20), table.dead);
    state.barrier(&table.header);
    try table.set(testing_allocator, try text(&state, "zz"), number(1));
    try equal(@as(u32, 0), table.dead);
    try equal(@as(u32, 1), table.hash.count);
}

test "runtime failed table insertion preserves live fields and dead traversal keys" {
    var state = try State.init(testing_allocator);
    defer state.deinit();
    const table = try state.newTable();
    for (1..5) |i| try table.set(testing_allocator, try text(&state, &[_]u8{'a' + @as(u8, @intCast(i))}), number(@floatFromInt(i)));
    for (1..4) |i| try table.set(testing_allocator, try text(&state, &[_]u8{'a' + @as(u8, @intCast(i))}), .nil);
    var failing = std.testing.FailingAllocator.init(testing_allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, table.set(failing.allocator(), number(99), number(9)));
    try equal(@as(u32, 1), table.live);
    try equal(@as(u32, 3), table.dead);
    try equal(@as(u32, 4), table.hash.count);
    try expect(table.get(try text(&state, "e")).equal(number(4)));
    _ = try table.next(try text(&state, "b"));
    try expect(table.get(number(99)).is(.nil));
    state.barrier(&table.header);
    try table.set(testing_allocator, number(99), number(9));
    try equal(@as(u32, 2), table.live);
    try equal(@as(u32, 0), table.dead);
}

test "runtime table lengths satisfy borders for sequences holes and the largest index" {
    var state = try State.init(testing_allocator);
    defer state.deinit();
    const table = try state.newTable();
    try equal(@as(u64, 0), table.length());
    state.barrier(&table.header);
    try table.set(testing_allocator, number(1.5), number(1));
    state.barrier(&table.header);
    try table.set(testing_allocator, number(-1), number(1));
    state.barrier(&table.header);
    try table.set(testing_allocator, number(std.math.inf(f64)), number(1));
    try equal(@as(u64, 0), table.length());
    for (1..130) |i| {
        state.barrier(&table.header);
        try table.set(testing_allocator, number(@floatFromInt(i)), number(1));
        try equal(@as(u64, @intCast(i)), table.length());
    }
    for ([_]u64{ 1, 2, 5, 64, 128, 129 }) |i| {
        state.barrier(&table.header);
        try table.set(testing_allocator, number(@floatFromInt(i)), .nil);
        const border = table.length();
        try expect(border == 0 or !table.get(number(@floatFromInt(border))).is(.nil));
        try expect(table.get(number(@floatFromInt(border + 1))).is(.nil));
    }
    const powers = try state.newTable();
    var i: u64 = 1;
    while (true) {
        state.barrier(&powers.header);
        try powers.set(testing_allocator, number(@floatFromInt(i)), number(1));
        if (i == 1 << 53) break;
        i *= 2;
    }
    try equal(@as(u64, 1 << 53), powers.length());
}

test "runtime stack indices bounds padding and shrinking follow the recorded convention" {
    var state = try State.init(testing_allocator);
    defer state.deinit();
    try equal(@as(usize, 0), state.top());
    for ([_]i64{ 0, 1, -1, std.math.minInt(i64), std.math.maxInt(i64) }) |index| try expect(state.get(index) == null);
    try state.push(number(10));
    try state.push(number(20));
    try expect(state.get(1).?.equal(number(10)));
    try expect(state.get(-1).?.equal(number(20)));
    try expect(state.get(-2).?.equal(number(10)));
    for ([_]i64{ 0, 3, -3, std.math.minInt(i64), std.math.maxInt(i64) }) |index| try expect(state.get(index) == null);
    try state.setTop(5);
    for (3..6) |index| try expect(state.get(@intCast(index)).?.is(.nil));
    const capacity = state.stack.capacity;
    try state.setTop(-2);
    try equal(@as(usize, 4), state.top());
    try state.setTop(-1);
    try equal(@as(usize, 4), state.top());
    try state.setTop(0);
    try equal(capacity, state.stack.capacity);
    try std.testing.expectError(error.InvalidIndex, state.setTop(-2));
    try std.testing.expectError(error.InvalidIndex, state.setTop(std.math.minInt(i64)));
    try std.testing.expectError(error.StackLimit, state.setTop(std.math.maxInt(i64)));
    try equal(@as(usize, 0), state.top());
}

test "runtime frame windows hide enclosing slots and enforce global stack room" {
    var state = try State.init(testing_allocator);
    defer state.deinit();
    try state.push(number(10));
    try state.push(number(20));
    try state.pushFrame(.{ .base = 1, .function = .{ .native = native } });
    try equal(@as(usize, 1), state.top());
    try expect(state.get(1).?.equal(number(20)));
    try expect(state.get(-2) == null);
    try std.testing.expectError(error.InvalidIndex, state.pushFrame(.{ .base = 0, .function = .{ .native = native } }));
    try std.testing.expectError(error.InvalidIndex, state.pushFrame(.{ .base = 3, .function = .{ .native = native } }));
    try state.setTop(0);
    try equal(@as(usize, 1), state.stack.items.len);
    try std.testing.expectError(error.StackLimit, state.setTop(State.max_stack));
    try expect(state.popFrame() != null);
    try expect(state.get(1).?.equal(number(10)));
    try expect(state.popFrame() == null);
    try state.setTop(State.max_stack);
    try equal(@as(usize, State.max_stack), state.top());
    try std.testing.expectError(error.StackLimit, state.push(.nil));
    try equal(@as(usize, State.max_stack), state.top());
}

test "runtime failed stack growth leaves contents and depth unchanged" {
    var state = try State.init(testing_allocator);
    defer state.deinit();
    try state.push(number(42));
    var failing = std.testing.FailingAllocator.init(testing_allocator, .{ .fail_index = 0 });
    state.allocator = failing.allocator();
    defer state.allocator = testing_allocator;
    try std.testing.expectError(error.OutOfMemory, state.setTop(10000));
    try equal(@as(usize, 1), state.top());
    try expect(state.get(1).?.equal(number(42)));
}

test "runtime cells share absolute slots survive growth and close before reuse" {
    var state = try State.init(testing_allocator);
    defer state.deinit();
    try state.push(number(10));
    try state.push(number(20));
    const first = try state.capture(0);
    const second = try state.capture(1);
    try expect(first == try state.capture(0));
    try std.testing.expectError(error.InvalidIndex, state.capture(2));
    try std.testing.expectError(error.InvalidIndex, state.capture(std.math.maxInt(usize)));
    try state.setTop(10000);
    state.writeCell(first, number(11));
    try expect(state.get(1).?.equal(number(11)));
    state.closeFrom(1);
    try expect(first.storage == .open);
    try expect(second.storage == .closed);
    try state.setTop(1);
    try state.push(number(99));
    try expect(state.readCell(second).equal(number(20)));
    state.writeCell(second, number(21));
    try expect(state.get(2).?.equal(number(99)));
    try state.setTop(0);
    try expect(first.storage == .closed);
    try expect(state.readCell(first).equal(number(11)));
    try state.push(number(50));
    try expect(first != try state.capture(0));
}

test "runtime userdata is zeroed aligned and refuses finalizers without changing its metatable" {
    var state = try State.init(testing_allocator);
    defer state.deinit();
    const userdata = try state.newUserdata(37);
    try equal(@as(usize, 0), @intFromPtr(userdata.bytes.ptr) % runtime.userdata_alignment);
    for (userdata.bytes) |byte| try equal(@as(u8, 0), byte);
    try equal(@as(usize, 0), (try state.newUserdata(0)).bytes.len);
    try std.testing.expectError(error.OutOfMemory, state.newUserdata(std.math.maxInt(usize)));
    const ordinary = try state.newTable();
    try state.setMetatable(.from(.{ .userdata = userdata }), ordinary);
    const finalizer = try state.newTable();
    state.barrier(&finalizer.header);
    try finalizer.set(testing_allocator, try text(&state, "__gc"), .from(.{ .boolean = false }));
    try std.testing.expectError(error.Finalizer, state.setMetatable(.from(.{ .userdata = userdata }), finalizer));
    try expect(userdata.metatable.? == ordinary);
    const table = try state.newTable();
    try state.setMetatable(.from(.{ .table = table }), finalizer);
    try expect(table.metatable.? == finalizer);
    try state.setMetatable(.from(.{ .userdata = userdata }), null);
    try expect(userdata.metatable == null);
    try std.testing.expectError(error.InvalidType, state.setMetatable(number(1), ordinary));
}

test "runtime native closures copy upvalues enforce 255 and allocate nothing without upvalues" {
    var state = try State.init(testing_allocator);
    defer state.deinit();
    const before = state.object_count;
    const bare = try state.newCClosure(native, &.{});
    try expect(bare == .native);
    try equal(before, state.object_count);
    var captures: [255]Value = @splat(number(1));
    const closure = try state.newCClosure(native, &captures);
    captures[0] = number(99);
    try expect(closure.c_closure.upvalues[0].equal(number(1)));
    const oversized: [256]Value = @splat(.nil);
    try std.testing.expectError(error.TooManyUpvalues, state.newCClosure(native, &oversized));
    try equal(before + 1, state.object_count);
}

test "runtime collection retains reserved roots and collects dropped stack items not capacity" {
    var state = try State.init(testing_allocator);
    defer state.deinit();
    const baseline = state.object_count;
    const kept = try text(&state, "stack only");
    const discarded = try text(&state, "capacity only");
    try state.push(kept);
    try state.push(discarded);
    try state.setTop(-2);
    state.collect();
    try equal(baseline + 1, state.object_count);
    try expect(owned(&state, @intFromPtr(&kept.unpack().string.header)));
    try expect(!owned(&state, @intFromPtr(&discarded.unpack().string.header)));
    try std.testing.expectEqualStrings("stack only", state.get(1).?.unpack().string.bytes);
    try std.testing.expectEqualStrings("not enough memory", state.memory_failure.bytes);
    try equal(@as(u32, 0), state.globals.live);
    for (state.names) |name| {
        try expect(owned(&state, @intFromPtr(&name.header)));
        try expect(std.mem.startsWith(u8, name.bytes, "__"));
    }
    try state.setTop(0);
    state.collect();
    try equal(baseline, state.object_count);
}

test "runtime globals failure values and loaded prototype constants independently keep graphs alive" {
    var state = try State.init(testing_allocator);
    defer state.deinit();
    const baseline = state.object_count;
    const key = try text(&state, "key");
    const value = try text(&state, "global value");
    const child = try state.newTable();
    state.barrier(&child.header);
    try child.set(testing_allocator, key, value);
    state.barrier(&state.globals.header);
    try state.globals.set(testing_allocator, number(1), .from(.{ .table = child }));
    state.collect();
    try equal(baseline + 3, state.object_count);
    try expect(child.getString("key").equal(value));
    state.barrier(&state.globals.header);
    try state.globals.set(testing_allocator, number(1), .nil);
    state.failure = .{ .kind = .runtime_error, .value = .from(.{ .table = child }) };
    state.collect();
    try equal(baseline + 3, state.object_count);
    state.failure = null;
    var constants = [_]Value{.from(.{ .table = child })};
    const prototype = try state.newPrototype(&constants);
    constants[0] = .nil;
    state.collect();
    try equal(baseline + 3, state.object_count);
    try expect(prototype.constants[0].unpack().table == child);
    // No loaded closure is needed to keep prototype constants alive.
    _ = try state.newPrototype(&.{});
    state.collect();
    try expect(child.getString("key").equal(value));
}

test "runtime table and userdata metatables retain their graphs" {
    var state = try State.init(testing_allocator);
    defer state.deinit();
    const baseline = state.object_count;
    const table = try state.newTable();
    const meta = try state.newTable();
    const value = try text(&state, "handler graph");
    state.barrier(&meta.header);
    try meta.set(testing_allocator, number(1), value);
    try state.setMetatable(.from(.{ .table = table }), meta);
    try state.push(.from(.{ .table = table }));
    state.collect();
    try equal(baseline + 3, state.object_count);
    const userdata = try state.newUserdata(8);
    try state.setMetatable(.from(.{ .userdata = userdata }), meta);
    try state.setTop(0);
    try state.push(.from(.{ .userdata = userdata }));
    state.collect();
    try equal(baseline + 3, state.object_count);
    try expect(!owned(&state, @intFromPtr(&table.header)));
    try expect(userdata.metatable.?.get(number(1)).equal(value));
    try state.setTop(0);
    state.collect();
    try equal(baseline, state.object_count);
}

test "runtime a running closure off the stack retains closed cells and their values" {
    var state = try State.init(testing_allocator);
    defer state.deinit();
    const baseline = state.object_count;
    const captured = try text(&state, "captured");
    try state.push(captured);
    const cell = try state.capture(0);
    const prototype = try state.newPrototype(&.{});
    const closure = try state.newClosure(prototype, &.{cell});
    try state.setTop(0);
    try state.pushFrame(.{ .base = 0, .function = .{ .closure = closure } });
    state.collect();
    try equal(baseline + 3, state.object_count);
    try expect(owned(&state, @intFromPtr(&cell.header)));
    try expect(owned(&state, @intFromPtr(&closure.header)));
    try std.testing.expectEqualStrings("captured", state.readCell(cell).unpack().string.bytes);
    _ = state.popFrame();
    state.collect();
    try equal(baseline, state.object_count);
}

test "runtime running native closures and hidden caller slots are roots" {
    var state = try State.init(testing_allocator);
    defer state.deinit();
    const baseline = state.object_count;
    const hidden = try text(&state, "caller slot");
    const captured = try text(&state, "native upvalue");
    try state.push(hidden);
    const function = try state.newCClosure(native, &.{captured});
    try state.pushFrame(.{ .base = 1, .function = function });
    try equal(@as(usize, 0), state.top());
    state.collect();
    try equal(baseline + 3, state.object_count);
    try expect(owned(&state, @intFromPtr(&hidden.unpack().string.header)));
    try expect(function.c_closure.upvalues[0].equal(captured));
    _ = state.popFrame();
    try state.setTop(0);
    state.collect();
    try equal(baseline, state.object_count);
}

test "runtime open cells are traced and are not permanent roots by themselves" {
    var state = try State.init(testing_allocator);
    defer state.deinit();
    const baseline = state.object_count;
    try state.push(try text(&state, "open"));
    const cell = try state.capture(0);
    const prototype = try state.newPrototype(&.{});
    const closure = try state.newClosure(prototype, &.{cell});
    try state.push(.fromFunction(.{ .closure = closure }));
    state.collect();
    try equal(baseline + 3, state.object_count);
    try expect(state.readCell(cell).equal(state.get(1).?));
    try state.setTop(1);
    state.collect();
    try equal(baseline + 1, state.object_count);
    try expect(!owned(&state, @intFromPtr(&cell.header)));
    const fresh = try state.capture(0);
    try expect(fresh.storage == .open);
    // The new capture is a live object, not the swept cell found again through
    // a stale entry; and closing the range must reach only cells that exist.
    try expect(owned(&state, @intFromPtr(&fresh.header)));
    try state.setTop(0);
    try expect(fresh.storage == .closed);
    try expect(state.readCell(fresh).equal(state.readCell(fresh)));
}

test "runtime captures out of slot order close by slot not by age" {
    var state = try State.init(testing_allocator);
    defer state.deinit();
    try state.push(number(1));
    try state.push(number(2));
    try state.push(number(3));
    const high = try state.capture(2);
    const low = try state.capture(0);
    const middle = try state.capture(1);
    try expect(high == try state.capture(2));
    try expect(low == try state.capture(0));
    try expect(middle == try state.capture(1));
    state.closeFrom(1);
    try expect(low.storage == .open);
    try expect(middle.storage == .closed);
    try expect(high.storage == .closed);
    try expect(state.readCell(middle).equal(number(2)));
    try expect(state.readCell(high).equal(number(3)));
    // A new capture of a closed slot is a new cell; the closed one keeps its value.
    const again = try state.capture(1);
    try expect(again != middle);
    try state.setTop(0);
    try expect(low.storage == .closed);
    try expect(again.storage == .closed);
}

test "runtime dead string keys survive collection until a later insert compacts them" {
    var state = try State.init(testing_allocator);
    defer state.deinit();
    const baseline = state.object_count;
    const table = try state.newTable();
    const original = try text(&state, "original");
    state.barrier(&table.header);
    try table.set(testing_allocator, original, number(1));
    state.barrier(&table.header);
    try table.set(testing_allocator, original, .nil);
    try state.push(.from(.{ .table = table }));
    state.collect();
    try equal(baseline + 2, state.object_count);
    try expect(owned(&state, @intFromPtr(&original.unpack().string.header)));
    const same = try text(&state, "original");
    try expect(try table.next(same) == null);
    // An insertion into the hash compacts it; the new key is the one object added.
    state.barrier(&table.header);
    try table.set(testing_allocator, try text(&state, "fresh"), number(1));
    state.collect();
    try equal(baseline + 2, state.object_count);
    try equal(@as(u32, 0), table.dead);
}

test "runtime table sequence keys live in the array part and the hash keeps the rest" {
    var state = try State.init(testing_allocator);
    defer state.deinit();
    const table = try state.newTable();
    for (1..101) |i| try table.set(testing_allocator, number(@floatFromInt(i)), number(@floatFromInt(i * 10)));
    try equal(@as(usize, 100), table.array.items.len);
    try equal(@as(u32, 0), table.hash.count);
    try equal(@as(u32, 100), table.live);
    try equal(@as(u64, 100), table.length());
    try expect(table.get(number(37)).equal(number(370)));
    try expect(table.get(number(37.5)).is(.nil));
    try expect(table.get(number(101)).is(.nil));
    try expect(table.get(number(0)).is(.nil));
    // Keys written ahead of the sequence wait in the hash and move over when it reaches them.
    state.barrier(&table.header);
    try table.set(testing_allocator, number(103), number(1030));
    state.barrier(&table.header);
    try table.set(testing_allocator, number(102), number(1020));
    try equal(@as(u32, 2), table.hash.count);
    state.barrier(&table.header);
    try table.set(testing_allocator, number(101), number(1010));
    try equal(@as(usize, 103), table.array.items.len);
    try equal(@as(u32, 0), table.hash.count);
    try expect(table.get(number(103)).equal(number(1030)));
    try equal(@as(u64, 103), table.length());
    // Traversal walks the array part in order, then the hash; clearing the current key keeps it valid.
    state.barrier(&table.header);
    try table.set(testing_allocator, try text(&state, "name"), number(1));
    var key: Value = .nil;
    var seen: usize = 0;
    var last_index: f64 = 0;
    while (try table.next(key)) |pair| {
        key = pair.key;
        if (key.numberValue() != null) {
            try expect(key.numberValue().? > last_index);
            last_index = key.numberValue().?;
        } else try equal(@as(usize, 103), seen);
        state.barrier(&table.header);
        try table.set(testing_allocator, key, .nil);
        seen += 1;
    }
    try equal(@as(usize, 104), seen);
    try equal(@as(u32, 0), table.live);
    try equal(@as(u64, 0), table.length());
    try std.testing.expectError(error.InvalidNextKey, table.next(number(104)));
    try std.testing.expectError(error.InvalidNextKey, table.next(number(50.5)));
    // Holes: the border is inside the array part, and a trailing hole is not the length.
    for (1..11) |i| try table.set(testing_allocator, number(@floatFromInt(i)), number(1));
    state.barrier(&table.header);
    try table.set(testing_allocator, number(10), .nil);
    try equal(@as(u64, 9), table.length());
    state.barrier(&table.header);
    try table.set(testing_allocator, number(5), .nil);
    const border = table.length();
    try expect(border == 4 or border == 9);
    // Growth failure leaves the table unchanged: the first element needs the first allocation.
    const fresh = try state.newTable();
    var failing = std.testing.FailingAllocator.init(testing_allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, fresh.set(failing.allocator(), number(1), number(1)));
    try equal(@as(usize, 0), fresh.array.items.len);
    try equal(@as(u32, 0), fresh.live);
    try expect(fresh.get(number(1)).is(.nil));
    try equal(@as(u64, 0), fresh.length());
}

test "runtime cyclic tables closures and userdata are swept without recursive marking" {
    var state = try State.init(testing_allocator);
    defer state.deinit();
    const baseline = state.object_count;
    const a = try state.newTable();
    const b = try state.newTable();
    state.barrier(&a.header);
    try a.set(testing_allocator, number(1), .from(.{ .table = b }));
    state.barrier(&b.header);
    try b.set(testing_allocator, number(1), .from(.{ .table = a }));
    const userdata = try state.newUserdata(1);
    try state.setMetatable(.from(.{ .userdata = userdata }), a);
    state.barrier(&a.header);
    try a.set(testing_allocator, number(2), .from(.{ .userdata = userdata }));
    try state.push(.from(.{ .table = a }));
    const cell = try state.capture(0);
    const prototype = try state.newPrototype(&.{});
    const closure = try state.newClosure(prototype, &.{cell});
    state.barrier(&a.header);
    try a.set(testing_allocator, number(3), .fromFunction(.{ .closure = closure }));
    const c = try state.newCClosure(native, &.{.from(.{ .table = a })});
    state.barrier(&b.header);
    try b.set(testing_allocator, number(2), .fromFunction(c));
    state.collect();
    try equal(baseline + 6, state.object_count);
    try state.setTop(0);
    state.collect();
    try equal(baseline, state.object_count);
    var head = try state.newTable();
    try state.push(.from(.{ .table = head }));
    for (0..10000) |_| {
        const child = try state.newTable();
        state.barrier(&head.header);
        try head.set(testing_allocator, number(1), .from(.{ .table = child }));
        head = child;
    }
    state.collect();
    try equal(baseline + 10001, state.object_count);
    try state.setTop(0);
    state.collect();
    try equal(baseline, state.object_count);
}

test "runtime allocation never collects and forced collection allocates nothing" {
    var state = try State.init(testing_allocator);
    defer state.deinit();
    const baseline = state.object_count;
    for (0..100) |_| _ = try state.newString("unrooted until a VM safe point");
    try equal(baseline + 100, state.object_count);
    try expect(state.shouldCollect());
    var failing = std.testing.FailingAllocator.init(testing_allocator, .{ .fail_index = 0 });
    state.allocator = failing.allocator();
    state.collect();
    state.allocator = testing_allocator;
    try equal(baseline, state.object_count);
    try expect(!failing.has_induced_failure);
    try equal(@as(usize, 0), failing.alloc_index);
    try expect(!state.shouldCollect());
    const survivors = try state.newTable();
    try state.push(.from(.{ .table = survivors }));
    for (0..100) |i| {
        state.barrier(&survivors.header);
        try survivors.set(testing_allocator, number(@floatFromInt(i)), try text(&state, "survivor"));
    }
    state.collect();
    try equal(state.object_count * 2, state.collection_threshold);
    state.collect();
    try equal(baseline + 101, state.object_count);
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var state = try State.init(allocator);
    defer state.deinit();
    const value = try text(&state, "all owned paths");
    const table = try state.newTable();
    for (0..5) |i| try table.set(allocator, number(@floatFromInt(i)), value);
    for (0..4) |i| try table.set(allocator, number(@floatFromInt(i)), .nil);
    state.barrier(&table.header);
    try table.set(allocator, number(99), value);
    try state.push(.from(.{ .table = table }));
    const cell = try state.capture(0);
    const prototype = try state.newPrototype(&.{value});
    const closure = try state.newClosure(prototype, &.{cell});
    const c = try state.newCClosure(native, &.{.fromFunction(.{ .closure = closure })});
    try state.pushFrame(.{ .base = 0, .function = c });
    const userdata = try state.newUserdata(17);
    try state.setMetatable(.from(.{ .userdata = userdata }), table);
    state.failure = .{ .kind = .runtime_error, .value = .from(.{ .userdata = userdata }) };
    try state.setTop(1000);
    state.collect();
}

test "runtime every allocation failure reclaims partial state and object construction" {
    try allocation_failures.checkAll(testing_allocator, allocationCase, .{});
}

test "runtime fillNil makes every slot of the range nil and touches nothing past it" {
    var slots: [12]Value = undefined;
    for (0..10) |length| {
        for (1..3) |start| {
            @memset(&slots, .from(.{ .number = 7 }));
            runtime.fillNil(slots[start .. start + length]);
            for (slots, 0..) |slot, index| {
                const inside = index >= start and index < start + length;
                try std.testing.expect(if (inside) slot.is(.nil) else slot.equal(.from(.{ .number = 7 })));
            }
        }
    }
}

test "runtime a stack's room past its length is nil after growth and after a collection" {
    var state = try State.init(testing_allocator);
    defer state.deinit();
    // Growth: the new room is nil, however the allocator left it.
    try runtime.growStack(&state.stack, state.open_cells.items, testing_allocator, 40);
    for (state.stack.allocatedSlice()[state.stack.items.len..]) |slot| try std.testing.expect(slot.is(.nil));
    // A table left past the length by a frame that returned is not a root,
    // and the collection that frees it clears its slot, so a frame that
    // regrows over it without filling (ADR 0005) does not find the table.
    try state.extendRegisters(10);
    for (state.stack.items) |*slot| slot.* = .nil;
    state.stack.items[7] = .from(.{ .table = try state.newTable() });
    try state.extendRegisters(3);
    state.collect();
    try state.extendRegisters(10);
    // Nil, or `-Dpoison-registers`'s number; never the freed table.
    try std.testing.expect(!state.stack.items[7].is(.table));
    // A suspended coroutine's stack likewise.
    const thread = try state.newThread(.nil);
    try state.push(.from(.{ .thread = thread }));
    const saved = &thread.saved.stack;
    try runtime.growStack(saved, thread.saved.open_cells.items, testing_allocator, 10);
    saved.items.len = 10;
    for (saved.items) |*slot| slot.* = .nil;
    saved.items[7] = .from(.{ .table = try state.newTable() });
    runtime.cutStack(saved, 3);
    state.collect();
    try std.testing.expect(!saved.allocatedSlice()[7].is(.table));
}

test "runtime the memory count reuses a freed small block and gives every block back" {
    var count = runtime.MemoryCount{ .backing = testing_allocator };
    const counted = count.allocator();
    const first = try counted.alloc(u64, 4);
    counted.free(first);
    // The same length and alignment takes the block back from the cache.
    const second = try counted.alloc(u64, 4);
    try expect(first.ptr == second.ptr);
    // Bytes aligned as bytes are not cached; another length is a new block.
    const bytes = try counted.alloc(u8, 10);
    const other = try counted.alloc(u64, 5);
    try expect(other.ptr != second.ptr);
    try equal(@as(usize, 32 + 10 + 40), count.in_use);
    counted.free(bytes);
    counted.free(other);
    counted.free(second);
    try equal(@as(usize, 0), count.in_use);
    // A block allocated around the count, freed through it, goes back to the
    // host as it was made.
    const foreign = try testing_allocator.alloc(u64, 6);
    counted.free(foreign);
    count.flush();
    try equal(@as(usize, 0), count.cached_bytes);
}

test "runtime an integer is kept in the value up to 2^45 and boxed past it, one form for each" {
    var state = try State.init(testing_allocator);
    defer state.deinit();
    const edges = [_]i64{ 0, 1, -1, Value.inline_max, Value.inline_min, Value.inline_max + 1, Value.inline_min - 1, std.math.maxInt(i64), std.math.minInt(i64) };
    for (edges) |n| {
        const value = try state.integer(n);
        try expect(value.is(.integer));
        try expect(!value.is(.thread) and !value.isNumber());
        try equal(n, value.asInteger());
        try equal(n, value.unpack().integer);
        try equal(n >= Value.inline_min and n <= Value.inline_max, value.isInlineInteger());
        // Another value of the same integer is equal, boxed or not.
        try expect(value.equal(try state.integer(n)));
        try expect(!value.equal(try state.integer(n +% 1)));
    }
}

test "runtime inline integers add, subtract and order through their bits, and nothing else passes for one" {
    const edges = [_]i64{ 0, 1, -1, 2, -2, Value.inline_max, Value.inline_min, Value.inline_max - 1, Value.inline_min + 1, 1 << 40, -(1 << 40) };
    for (edges) |x| for (edges) |y| {
        const a = Value.inlineInteger(x).?;
        const b = Value.inlineInteger(y).?;
        try expect(Value.allInlineIntegers(.{ a, b }));
        const sum = Value.inlineSum(a, b);
        try equal(Value.inlineInteger(x + y) == null, sum == null);
        if (sum) |value| try equal(x + y, value.asInlineInteger());
        const difference = Value.inlineDifference(a, b);
        try equal(Value.inlineInteger(x - y) == null, difference == null);
        if (difference) |value| try equal(x - y, value.asInlineInteger());
        try equal(x < y, Value.inlineLess(a, b));
        try equal(x > 0, a.isPositiveInline());
    };
    // nil, the booleans, an odd native address under a tag that contains
    // the special one, and a float are no inline integer, alone or beside one.
    const one = Value.inlineInteger(1).?;
    const odd_native: Value = .{ .bits = 0xFFFD << 48 | 0x1003 };
    const others = [_]Value{ .nil, .false, .true, odd_native, number(3), number(std.math.nan(f64)) };
    for (others) |other| {
        try expect(!other.isInlineInteger());
        try expect(!Value.allInlineIntegers(.{ one, other }));
        try expect(!Value.allInlineIntegers(.{ other, one }));
    }
}

test "runtime integers and floats compare by value as lua5.5's raw equality does" {
    var state = try State.init(testing_allocator);
    defer state.deinit();
    try expect((try state.integer(3)).equal(number(3)));
    try expect(number(3).equal(try state.integer(3)));
    try expect(!(try state.integer(3)).equal(number(3.5)));
    try expect((try state.integer(1 << 60)).equal(number(0x1p60)));
    // 2^63 is no 64-bit integer, and the largest one is not a float.
    try expect(!(try state.integer(std.math.maxInt(i64))).equal(number(0x1p63)));
    try expect(!(try state.integer(0)).equal(number(std.math.nan(f64))));
    try expect((try state.integer(0)).equal(number(-0.0)));
}

test "runtime a table finds an integer key through any form of the same number" {
    var state = try State.init(testing_allocator);
    defer state.deinit();
    const table = try state.newTable();
    const big: i64 = 1 << 60;
    state.barrier(&table.header);
    try table.set(testing_allocator, try state.integer(big), number(1));
    state.barrier(&table.header);
    try table.set(testing_allocator, try state.integer(-7), number(2));
    try expect(table.get(try state.integer(big)).equal(number(1)));
    try expect(table.get(number(0x1p60)).equal(number(1)));
    try expect(table.get(number(-7)).equal(number(2)));
    try expect(table.get(number(-7.5)).is(.nil));
    try equal(@as(u32, 2), table.live);
}

test "runtime a boxed integer lives while it is reachable, a weak table's included" {
    var state = try State.init(testing_allocator);
    defer state.deinit();
    const weak = try state.newTable();
    const meta = try state.newTable();
    state.barrier(&meta.header);
    try meta.set(testing_allocator, try text(&state, "__mode"), try text(&state, "kv"));
    weak.metatable = meta;
    try state.push(.from(.{ .table = weak }));
    state.barrier(&weak.header);
    try weak.set(testing_allocator, try state.integer(1 << 50), try state.integer(-(1 << 50)));
    // Unreachable once collected, and freed with the rest at deinit.
    _ = try state.integer(1 << 55);
    state.collect();
    try expect(weak.get(try state.integer(1 << 50)).equal(try state.integer(-(1 << 50))));
}
