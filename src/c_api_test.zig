const std = @import("std");
const allocation_failures = @import("allocation_failures.zig");
const api = @import("c_api.zig");
const runtime = @import("runtime.zig");
const a = std.testing.allocator;
const equal = std.testing.expectEqual;
const expect = std.testing.expect;

fn creationCase(allocator: std.mem.Allocator) !void {
    const state = try api.create(allocator);
    defer api.nilu_close(state);
    try equal(@as(c_int, 0), api.nilu_gettop(state));
}
test "c_api state creation reclaims every partial allocation" {
    try allocation_failures.checkAll(a, creationCase, .{});
    api.nilu_close(null);
}

test "c_api integers cross as Lua's do, every 64-bit one, told apart from floats" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    const integers = [_]i64{ 0, 1, -1, runtime.Value.inline_max, runtime.Value.inline_min, runtime.Value.inline_max + 1, runtime.Value.inline_min - 1, std.math.maxInt(i64), std.math.minInt(i64) };
    for (integers) |n| {
        try equal(api.Status.ok, api.nilu_pushinteger(state, n));
        var isnum: c_int = -1;
        try equal(n, api.nilu_tointegerx(state, -1, &isnum));
        try equal(@as(c_int, 1), isnum);
        try equal(@as(c_int, 1), api.nilu_isinteger(state, -1));
        try equal(@as(f64, @floatFromInt(n)), api.nilu_tonumberx(state, -1, &isnum));
        try equal(@as(c_int, 1), isnum);
    }
    var length: usize = 0;
    try equal(api.Status.ok, api.nilu_pushinteger(state, std.math.minInt(i64)));
    try std.testing.expectEqualStrings("-9223372036854775808", api.nilu_tolstring(state, -1, &length).?[0..length]);
    // A float with an integer value reads as that integer but is no integer;
    // any other float, a string and an absent slot read as none.
    try equal(api.Status.ok, api.nilu_pushnumber(state, 3.0));
    var isnum: c_int = -1;
    try equal(@as(i64, 3), api.nilu_tointegerx(state, -1, &isnum));
    try equal(@as(c_int, 1), isnum);
    try equal(@as(c_int, 0), api.nilu_isinteger(state, -1));
    for ([_]f64{ 3.5, 0x1p63, -0x1p64, std.math.inf(f64), std.math.nan(f64) }) |x| {
        try equal(api.Status.ok, api.nilu_pushnumber(state, x));
        isnum = -1;
        try equal(@as(i64, 0), api.nilu_tointegerx(state, -1, &isnum));
        try equal(@as(c_int, 0), isnum);
    }
    try equal(api.Status.ok, api.nilu_pushstring(state, "8"));
    isnum = -1;
    try equal(@as(i64, 0), api.nilu_tointegerx(state, -1, &isnum));
    try equal(@as(c_int, 0), isnum);
    try equal(@as(c_int, 0), api.nilu_isinteger(state, -1));
    isnum = -1;
    try equal(@as(i64, 0), api.nilu_tointegerx(state, 1000, &isnum));
    try equal(@as(c_int, 0), isnum);
    try equal(@as(c_int, 0), api.nilu_isinteger(state, 1000));
    // The 3.0 is seven slots down: five floats and the string above it.
    try equal(@as(i64, 3), api.nilu_tointegerx(state, -7, null));
}

fn boxedIntegerCase(allocator: std.mem.Allocator) !void {
    const state = try api.create(allocator);
    defer api.nilu_close(state);
    switch (api.nilu_pushinteger(state, 1)) {
        .ok => {},
        .memory => return error.OutOfMemory,
        else => return error.TestUnexpectedResult,
    }
    // An integer past the inline range is an object: a failed allocation
    // pushes nothing and leaves the slot below as it was.
    switch (api.nilu_pushinteger(state, 1 << 60)) {
        .ok => try equal(@as(i64, 1 << 60), api.nilu_tointegerx(state, -1, null)),
        .memory => {
            try equal(@as(c_int, 1), api.nilu_gettop(state));
            try equal(@as(i64, 1), api.nilu_tointegerx(state, 1, null));
            return error.OutOfMemory;
        },
        else => return error.TestUnexpectedResult,
    }
}
test "c_api pushing a boxed integer survives every allocation failure" {
    try allocation_failures.checkAll(a, boxedIntegerCase, .{});
}

test "c_api numeric reads preserve bits and clear optional flags for absent or nil slots" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    for ([_]u64{ 0, 0x8000000000000000, 0x7ff0000000000000, 0xfff0000000000000, 0x7ff8000000000042 }) |bits| {
        try equal(api.Status.ok, api.nilu_pushnumber(state, @bitCast(bits)));
        var isnum: c_int = -1;
        try equal(bits, @as(u64, @bitCast(api.nilu_tonumberx(state, -1, &isnum))));
        try equal(@as(c_int, 1), isnum);
    }
    try equal(api.Status.ok, api.nilu_pushnil(state));
    for ([_]c_int{ 0, 6, 7, -1, std.math.minInt(c_int), std.math.maxInt(c_int) }) |index| {
        var isnum: c_int = 99;
        try equal(@as(f64, 0), api.nilu_tonumberx(state, index, &isnum));
        try equal(@as(c_int, 0), isnum);
        try equal(@as(f64, 0), api.nilu_tonumberx(state, index, null));
    }
}

test "c_api frame relative stack operations cannot expose caller and close captured popped slots" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try state.push(.from(.{ .number = 42 }));
    try state.pushFrame(.{ .base = 1, .function = .{ .native = dummy } });
    try equal(@as(c_int, 0), api.nilu_gettop(state));
    var isnum: c_int = 1;
    _ = api.nilu_tonumberx(state, -1, &isnum);
    try equal(@as(c_int, 0), isnum);
    try equal(api.Status.ok, api.nilu_pushnumber(state, 7));
    const cell = try state.capture(1);
    try equal(api.Status.ok, api.nilu_settop(state, 3));
    try expect(state.get(2).?.is(.nil) and state.get(3).?.is(.nil));
    try equal(api.Status.ok, api.nilu_settop(state, 0));
    try expect(cell.storage == .closed);
    try expect(state.readCell(cell).equal(.from(.{ .number = 7 })));
    _ = state.popFrame();
    try equal(@as(c_int, 1), api.nilu_gettop(state));
    try equal(@as(f64, 42), api.nilu_tonumberx(state, 1, null));
}
fn dummy(_: *runtime.State) callconv(.c) c_int {
    return 0;
}

test "c_api allocation and depth failures return distinct status without changing stack" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    const original = state.allocator;
    state.allocator = failing.allocator();
    defer state.allocator = original;
    try equal(api.Status.memory, api.nilu_pushnumber(state, 7));
    try equal(api.Status.memory, api.nilu_pushnil(state));
    try equal(api.Status.memory, api.nilu_settop(state, 2));
    try equal(@as(c_int, 0), api.nilu_gettop(state));
    try equal(api.Status.stack, api.nilu_settop(state, std.math.maxInt(c_int)));
    try equal(@as(c_int, 0), api.nilu_gettop(state));
    state.allocator = original;
    try equal(api.Status.ok, api.nilu_settop(state, runtime.State.max_stack));
    try equal(api.Status.stack, api.nilu_pushnil(state));
    try equal(api.Status.stack, api.nilu_pushnumber(state, 9));
    try equal(@as(c_int, runtime.State.max_stack), api.nilu_gettop(state));
    try equal(api.Status.ok, api.nilu_settop(state, 0));
}

test "c_api_strings copy counted bytes terminate and distinguish null nil from empty" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    var input = [_]u8{ 'a', 0, 'b' };
    try equal(api.Status.ok, api.nilu_pushlstring(state, &input, input.len));
    input[0] = 'z';
    var length: usize = 99;
    const pointer = api.nilu_tolstring(state, 1, &length).?;
    try equal(@as(usize, 3), length);
    try std.testing.expectEqualSlices(u8, "a\x00b", pointer[0..length]);
    try equal(@as(u8, 0), pointer[length]);
    try equal(api.Status.ok, api.nilu_pushlstring(state, null, 0));
    try expect(api.nilu_tolstring(state, -1, &length) != null);
    try equal(@as(usize, 0), length);
    try equal(api.Status.ok, api.nilu_pushstring(state, null));
    length = 99;
    try expect(api.nilu_tolstring(state, -1, &length) == null);
    try equal(@as(usize, 0), length);
    try expect(state.get(-1).?.is(.nil));
}

test "c_api_strings numeric conversion mutates only its slot with recorded spelling" {
    const cases = [_]struct { number: f64, text: []const u8 }{
        .{ .number = 10, .text = "10.0" },                 .{ .number = -0.0, .text = "-0.0" },
        .{ .number = 1e20, .text = "1e+20" },              .{ .number = std.math.inf(f64), .text = "inf" },
        .{ .number = -std.math.inf(f64), .text = "-inf" }, .{ .number = std.math.nan(f64), .text = "nan" },
    };
    for (cases) |case| {
        const state = try api.create(a);
        defer api.nilu_close(state);
        try equal(api.Status.ok, api.nilu_pushnumber(state, 42));
        try equal(api.Status.ok, api.nilu_pushnumber(state, case.number));
        var length: usize = 99;
        const text = api.nilu_tolstring(state, -1, &length).?;
        try std.testing.expectEqualSlices(u8, case.text, text[0..length]);
        try equal(@as(c_int, 2), api.nilu_gettop(state));
        try equal(@as(f64, 42), api.nilu_tonumberx(state, 1, null));
        var flag: c_int = 1;
        _ = api.nilu_tonumberx(state, -1, &flag);
        try equal(@as(c_int, 0), flag);
        try expect(text == api.nilu_tolstring(state, -1, null).?);
    }
}

test "c_api_strings nonconvertible values and absent slots clear length without mutation" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    const values = [_]runtime.Value{ .nil, .from(.{ .boolean = true }), .from(.{ .table = try state.newTable() }), .from(.{ .userdata = try state.newUserdata(0) }), .fromFunction(.{ .native = dummy }) };
    for (values) |value| {
        try state.push(value);
        var length: usize = 99;
        try expect(api.nilu_tolstring(state, -1, &length) == null);
        try equal(@as(usize, 0), length);
        try expect(state.get(-1).?.equal(value));
    }
    for ([_]c_int{ 0, 99, std.math.minInt(c_int), std.math.maxInt(c_int) }) |index| {
        var length: usize = 99;
        try expect(api.nilu_tolstring(state, index, &length) == null);
        try equal(@as(usize, 0), length);
    }
}

test "c_api_strings borrowed bytes stay rooted through growth collection and caller windows" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try equal(api.Status.ok, api.nilu_pushstring(state, "caller"));
    const caller = api.nilu_tolstring(state, 1, null).?;
    try state.pushFrame(.{ .base = 1, .function = .{ .native = dummy } });
    var length: usize = 99;
    try expect(api.nilu_tolstring(state, -1, &length) == null);
    try equal(@as(usize, 0), length);
    try equal(api.Status.ok, api.nilu_pushstring(state, "kept"));
    const pointer = api.nilu_tolstring(state, 1, null).?;
    try equal(api.Status.ok, api.nilu_settop(state, 10000));
    state.collect();
    try std.testing.expectEqualStrings("kept", std.mem.span(pointer));
    try std.testing.expectEqualStrings("caller", std.mem.span(caller));
    try equal(api.Status.ok, api.nilu_settop(state, 0));
    _ = state.popFrame();
    state.collect();
    try std.testing.expectEqualStrings("caller", std.mem.span(caller));
}

fn stringAllocationCase(allocator: std.mem.Allocator) !void {
    const state = try api.create(allocator);
    defer api.nilu_close(state);
    try state.push(.from(.{ .number = 42 }));
    const status = api.nilu_pushstring(state, "new bytes");
    if (status == .memory) {
        try equal(@as(c_int, 1), api.nilu_gettop(state));
        try equal(@as(f64, 42), api.nilu_tonumberx(state, 1, null));
        return error.OutOfMemory;
    }
    try equal(api.Status.ok, status);
    try equal(api.Status.ok, api.nilu_pushnumber(state, 10));
    var length: usize = 99;
    const text = api.nilu_tolstring(state, -1, &length) orelse {
        try equal(@as(usize, 0), length);
        try equal(@as(c_int, 3), api.nilu_gettop(state));
        try equal(@as(f64, 10), api.nilu_tonumberx(state, -1, null));
        return error.OutOfMemory;
    };
    try std.testing.expectEqualSlices(u8, "10.0", text[0..length]);
}
test "c_api_strings every allocation failure leaves prior stack and number intact" {
    try allocation_failures.checkAll(a, stringAllocationCase, .{});
}

test "c_api_strings oversized lengths and full stack refuse before reading input" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    const byte = [_]u8{0};
    try equal(api.Status.memory, api.nilu_pushlstring(state, &byte, std.math.maxInt(usize)));
    try equal(@as(c_int, 0), api.nilu_gettop(state));
    try equal(api.Status.ok, api.nilu_settop(state, runtime.State.max_stack));
    const objects = state.object_count;
    try equal(api.Status.stack, api.nilu_pushlstring(state, &byte, 1));
    try equal(api.Status.stack, api.nilu_pushstring(state, "full"));
    try equal(objects, state.object_count);
}

test "c_api_values boolean inputs normalize and reads use runtime truth without coercion" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    for ([_]c_int{ 0, 1, -1, std.math.minInt(c_int), std.math.maxInt(c_int) }) |input| {
        try equal(api.Status.ok, api.nilu_pushboolean(state, input));
        try equal(@as(c_int, if (input == 0) 0 else 1), api.nilu_toboolean(state, -1));
        try expect(state.get(-1).?.is(.boolean));
    }
    for ([_]runtime.Value{ .nil, .from(.{ .boolean = false }), .from(.{ .number = 0 }), .from(.{ .number = std.math.nan(f64) }), .from(.{ .string = try state.newString("") }), .from(.{ .table = try state.newTable() }), .from(.{ .userdata = try state.newUserdata(0) }), .fromFunction(.{ .native = dummy }) }, 0..) |value, i| {
        try state.push(value);
        try equal(@as(c_int, if (i < 2) 0 else 1), api.nilu_toboolean(state, -1));
    }
    for ([_]c_int{ 0, 99, std.math.minInt(c_int), std.math.maxInt(c_int) }) |index| try equal(@as(c_int, 0), api.nilu_toboolean(state, index));
}

test "c_api_values pushvalue preserves object identity and roots a duplicate after original removal" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    const table = try state.newTable();
    try state.push(.from(.{ .table = table }));
    try equal(api.Status.ok, api.nilu_pushvalue(state, -1));
    try expect(state.get(1).?.unpack().table == state.get(2).?.unpack().table);
    api.nilu_copy(state, 2, 1);
    try equal(api.Status.ok, api.nilu_settop(state, 1));
    state.collect();
    try expect(state.get(1).?.unpack().table == table);
    try equal(api.Status.ok, api.nilu_pushstring(state, "owned"));
    const pointer = api.nilu_tolstring(state, -1, null).?;
    try equal(api.Status.ok, api.nilu_pushvalue(state, 2));
    api.nilu_copy(state, -1, 1);
    try equal(api.Status.ok, api.nilu_settop(state, 1));
    state.collect();
    try expect(pointer == api.nilu_tolstring(state, 1, null).?);
}

test "c_api_values rotations match independent index mapping for all directions and boundaries" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    for (1..9) |length| {
        const bound: i32 = @intCast(length);
        var count = -bound;
        while (count <= bound) : (count += 1) {
            for ([_]bool{ false, true }) |negative_index| {
                try equal(api.Status.ok, api.nilu_settop(state, 0));
                try equal(api.Status.ok, api.nilu_pushnumber(state, 42));
                try equal(api.Status.ok, api.nilu_pushnumber(state, 99));
                for (0..length) |i| try equal(api.Status.ok, api.nilu_pushnumber(state, @floatFromInt(i)));
                api.nilu_rotate(state, if (negative_index) -bound else 3, count);
                try equal(@as(c_int, @intCast(length + 2)), api.nilu_gettop(state));
                try equal(@as(f64, 42), api.nilu_tonumberx(state, 1, null));
                try equal(@as(f64, 99), api.nilu_tonumberx(state, 2, null));
                for (0..length) |i| {
                    const expected = @mod(@as(i64, @intCast(i)) - count, @as(i64, @intCast(length)));
                    try equal(@as(f64, @floatFromInt(expected)), api.nilu_tonumberx(state, @intCast(i + 3), null));
                }
            }
        }
    }
}

test "c_api_values copying rotating and reads are allocation free and isolated to caller window" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try state.push(.from(.{ .number = 42 }));
    try state.pushFrame(.{ .base = 1, .function = .{ .native = dummy } });
    try equal(api.Status.ok, api.nilu_pushnumber(state, 1));
    try equal(api.Status.ok, api.nilu_pushnumber(state, 2));
    try equal(api.Status.ok, api.nilu_pushnumber(state, 3));
    const cell = try state.capture(1);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    const original = state.allocator;
    state.allocator = failing.allocator();
    defer state.allocator = original;
    api.nilu_copy(state, -1, 1);
    try equal(@as(f64, 3), api.nilu_tonumberx(state, 1, null));
    try expect(state.readCell(cell).equal(.from(.{ .number = 3 })));
    api.nilu_copy(state, 2, 2);
    api.nilu_rotate(state, 1, 1);
    try equal(@as(c_int, 1), api.nilu_toboolean(state, -1));
    try equal(@as(c_int, 3), api.nilu_gettop(state));
    try equal(@as(f64, 42), state.stack.items[0].numberValue().?);
    try expect(cell.storage == .open);
    state.allocator = original;
    try equal(api.Status.ok, api.nilu_settop(state, 0));
    _ = state.popFrame();
    try equal(@as(f64, 42), api.nilu_tonumberx(state, 1, null));
}

fn duplicateAllocationCase(allocator: std.mem.Allocator) !void {
    const state = try api.create(allocator);
    defer api.nilu_close(state);
    if (api.nilu_pushstring(state, "source") == .memory) return error.OutOfMemory;
    const pointer = api.nilu_tolstring(state, 1, null).?;
    while (state.stack.items.len < state.stack.capacity) try state.push(.nil);
    const depth = state.top();
    const status = api.nilu_pushvalue(state, 1);
    if (status == .memory) {
        try equal(depth, state.top());
        try expect(pointer == api.nilu_tolstring(state, 1, null).?);
        return error.OutOfMemory;
    }
    try equal(api.Status.ok, status);
    try equal(depth + 1, state.top());
    try expect(pointer == api.nilu_tolstring(state, -1, null).?);
}
test "c_api_values duplicate allocation failures preserve source and visible stack" {
    try allocation_failures.checkAll(a, duplicateAllocationCase, .{});
}

test "c_api_values boolean and duplicate pushes retain depth refusal" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try equal(api.Status.ok, api.nilu_settop(state, runtime.State.max_stack));
    try equal(api.Status.stack, api.nilu_pushboolean(state, 1));
    try equal(api.Status.stack, api.nilu_pushvalue(state, 1));
    try equal(@as(c_int, runtime.State.max_stack), api.nilu_gettop(state));
}

test "c_api_objects userdata is zeroed aligned and retained through copies and GC" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    for ([_]usize{ 0, 1, 3, 7, 16, 100 }) |size| {
        var block: ?*anyopaque = null;
        try equal(api.Status.ok, api.nilu_newuserdata(state, size, &block));
        try expect(block != null);
        try equal(@as(usize, 0), @intFromPtr(block.?) % runtime.userdata_alignment);
        const bytes: [*]u8 = @ptrCast(block.?);
        for (bytes[0..size]) |byte| try equal(@as(u8, 0), byte);
        if (size > 0) bytes[size - 1] = 123;
        try expect(block == api.nilu_touserdata(state, -1));
        try equal(api.Status.ok, api.nilu_pushvalue(state, -1));
        state.collect();
        try expect(block == api.nilu_touserdata(state, -1));
        if (size > 0) try equal(@as(u8, 123), bytes[size - 1]);
    }
    try equal(api.Status.ok, api.nilu_newuserdata(state, 4, null));
    try expect(api.nilu_touserdata(state, -1) != null);
}

test "c_api_objects raw lengths bypass handlers for tables strings and userdata" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try equal(api.Status.ok, api.nilu_newtable(state));
    const table = state.get(1).?.unpack().table;
    for (1..4) |i| try table.set(state.allocator, .from(.{ .number = @floatFromInt(i) }), .from(.{ .number = 99 }));
    state.barrier(&table.header);
    try table.set(state.allocator, .from(.{ .number = 100 }), .from(.{ .number = 8 }));
    const meta = try state.newTable();
    state.barrier(&meta.header);
    try meta.set(state.allocator, .from(.{ .string = try state.newString("__len") }), .fromFunction(.{ .native = dummy }));
    table.metatable = meta;
    try equal(api.Status.ok, api.nilu_rawlen(state, 1));
    try equal(@as(f64, 3), api.nilu_tonumberx(state, -1, null));
    try equal(api.Status.ok, api.nilu_pushlstring(state, "a\x00b", 3));
    try equal(api.Status.ok, api.nilu_rawlen(state, -1));
    try equal(@as(f64, 3), api.nilu_tonumberx(state, -1, null));
    try equal(api.Status.ok, api.nilu_newuserdata(state, 7, null));
    state.get(-1).?.unpack().userdata.metatable = meta;
    try equal(api.Status.ok, api.nilu_rawlen(state, -1));
    try equal(@as(f64, 7), api.nilu_tonumberx(state, -1, null));
    try equal(@as(usize, 0), state.frames.items.len);
    try equal(api.Status.ok, api.nilu_newtable(state));
    try equal(api.Status.ok, api.nilu_rawlen(state, -1));
    try equal(@as(f64, 0), api.nilu_tonumberx(state, -1, null));
}

test "c_api_objects nonuserdata reads and zero raw lengths preserve original slots" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    for ([_]runtime.Value{ .nil, .from(.{ .boolean = true }), .from(.{ .number = 7 }), .fromFunction(.{ .native = dummy }) }) |value| {
        try state.push(value);
        const depth = state.top();
        try expect(api.nilu_touserdata(state, -1) == null);
        try equal(api.Status.ok, api.nilu_rawlen(state, -1));
        try equal(depth + 1, state.top());
        try equal(@as(f64, 0), api.nilu_tonumberx(state, -1, null));
        try expect(state.get(-2).?.equal(value));
        try equal(api.Status.ok, api.nilu_settop(state, -2));
    }
    for ([_]c_int{ 0, 99, std.math.minInt(c_int), std.math.maxInt(c_int) }) |index| try expect(api.nilu_touserdata(state, index) == null);
}

test "c_api_objects frame windows and raw length growth retain object roots" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try equal(api.Status.ok, api.nilu_newuserdata(state, 8, null));
    const pointer = api.nilu_touserdata(state, 1);
    try state.pushFrame(.{ .base = 1, .function = .{ .native = dummy } });
    try expect(api.nilu_touserdata(state, -1) == null);
    try equal(api.Status.ok, api.nilu_newtable(state));
    const table = state.get(1).?.unpack().table;
    state.barrier(&table.header);
    try table.set(state.allocator, .from(.{ .number = 1 }), .from(.{ .number = 7 }));
    while (state.stack.items.len < state.stack.capacity) try state.push(.nil);
    try equal(api.Status.ok, api.nilu_rawlen(state, 1));
    state.collect();
    try equal(@as(f64, 1), api.nilu_tonumberx(state, -1, null));
    try equal(api.Status.ok, api.nilu_settop(state, 0));
    _ = state.popFrame();
    try expect(pointer == api.nilu_touserdata(state, 1));
}

fn objectAllocationCase(allocator: std.mem.Allocator) !void {
    const state = try api.create(allocator);
    defer api.nilu_close(state);
    try state.push(.from(.{ .number = 42 }));
    while (state.stack.items.len < state.stack.capacity) try state.push(.nil);
    const before = state.top();
    var marker: u8 = 0;
    var block: ?*anyopaque = &marker;
    const status = api.nilu_newuserdata(state, 7, &block);
    if (status == .memory) {
        try expect(block == null);
        try equal(before, state.top());
        try equal(@as(f64, 42), api.nilu_tonumberx(state, 1, null));
        return error.OutOfMemory;
    }
    try equal(api.Status.ok, status);
    try expect(block != null);
    const table_status = api.nilu_newtable(state);
    if (table_status == .memory) {
        try equal(before + 1, state.top());
        return error.OutOfMemory;
    }
    try equal(api.Status.ok, table_status);
    while (state.stack.items.len < state.stack.capacity) try state.push(.nil);
    const depth = state.top();
    const length_status = api.nilu_rawlen(state, @intCast(before + 1));
    if (length_status == .memory) {
        try equal(depth, state.top());
        try expect(block == api.nilu_touserdata(state, @intCast(before + 1)));
        return error.OutOfMemory;
    }
    try equal(api.Status.ok, length_status);
    try equal(@as(f64, 7), api.nilu_tonumberx(state, -1, null));
}
test "c_api_objects every allocation failure preserves values and clears userdata output" {
    try allocation_failures.checkAll(a, objectAllocationCase, .{});
}

test "c_api_objects size overflow and stack limits refuse without allocating objects" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    const count = state.object_count;
    var marker: u8 = 0;
    var block: ?*anyopaque = &marker;
    try equal(api.Status.memory, api.nilu_newuserdata(state, std.math.maxInt(usize), &block));
    try expect(block == null);
    try equal(@as(usize, 0), state.top());
    try equal(count, state.object_count);
    try equal(api.Status.ok, api.nilu_pushstring(state, "full"));
    try equal(api.Status.ok, api.nilu_settop(state, runtime.State.max_stack));
    const objects = state.object_count;
    block = &marker;
    try equal(api.Status.stack, api.nilu_newuserdata(state, 8, &block));
    try expect(block == null);
    try equal(api.Status.stack, api.nilu_newtable(state));
    try equal(api.Status.stack, api.nilu_rawlen(state, 1));
    try equal(objects, state.object_count);
    try equal(@as(c_int, runtime.State.max_stack), api.nilu_gettop(state));
}

test "c_api_queries rawlen follows recorded zero rule for every other kind and absent slot" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    const values = [_]runtime.Value{ .nil, .from(.{ .boolean = false }), .from(.{ .number = 7 }), .fromFunction(.{ .native = dummy }) };
    for (values) |value| {
        try state.push(value);
        const depth = state.top();
        try equal(api.Status.ok, api.nilu_rawlen(state, -1));
        try equal(depth + 1, state.top());
        try expect(state.get(-2).?.equal(value));
        try equal(@as(f64, 0), api.nilu_tonumberx(state, -1, null));
        try equal(api.Status.ok, api.nilu_settop(state, 0));
    }
    for ([_]c_int{ 0, 99, std.math.minInt(c_int), std.math.maxInt(c_int) }) |index| {
        try equal(api.Status.ok, api.nilu_rawlen(state, index));
        try equal(@as(f64, 0), api.nilu_tonumberx(state, -1, null));
        try equal(api.Status.ok, api.nilu_settop(state, 0));
    }
}

test "c_api_queries raw equality keeps value rules identities and no handler dispatch" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try equal(api.Status.ok, api.nilu_pushnil(state)); // 1
    try equal(api.Status.ok, api.nilu_pushnil(state)); // 2
    try equal(@as(c_int, 1), api.nilu_rawequal(state, 1, 2));
    try equal(api.Status.ok, api.nilu_pushboolean(state, 0)); // 3
    try equal(@as(c_int, 0), api.nilu_rawequal(state, 1, 3));
    try equal(api.Status.ok, api.nilu_pushnumber(state, 0)); // 4
    try equal(api.Status.ok, api.nilu_pushnumber(state, -0.0)); // 5
    try equal(@as(c_int, 1), api.nilu_rawequal(state, 4, 5));
    try equal(api.Status.ok, api.nilu_pushnumber(state, std.math.nan(f64))); // 6
    try equal(@as(c_int, 0), api.nilu_rawequal(state, 6, 6));
    try equal(api.Status.ok, api.nilu_pushstring(state, "same")); // 7
    try equal(api.Status.ok, api.nilu_pushstring(state, "same")); // 8
    try expect(state.get(7).?.unpack().string != state.get(8).?.unpack().string);
    try equal(@as(c_int, 1), api.nilu_rawequal(state, 7, 8));
    try equal(api.Status.ok, api.nilu_pushstring(state, "0")); // 9
    try equal(@as(c_int, 0), api.nilu_rawequal(state, 4, 9));
    try equal(api.Status.ok, api.nilu_newtable(state)); // 10
    try equal(api.Status.ok, api.nilu_newtable(state)); // 11
    const meta = try state.newTable();
    state.barrier(&meta.header);
    try meta.set(state.allocator, .from(.{ .string = try state.newString("__eq") }), .from(.{ .boolean = true }));
    state.get(10).?.unpack().table.metatable = meta;
    state.get(11).?.unpack().table.metatable = meta;
    try equal(@as(c_int, 0), api.nilu_rawequal(state, 10, 11));
    try equal(api.Status.ok, api.nilu_pushvalue(state, 10)); // 12
    try equal(@as(c_int, 1), api.nilu_rawequal(state, 10, 12));
    try equal(api.Status.ok, api.nilu_newuserdata(state, 1, null)); // 13
    try equal(api.Status.ok, api.nilu_newuserdata(state, 1, null)); // 14
    try equal(@as(c_int, 0), api.nilu_rawequal(state, 13, 14));
    try equal(api.Status.ok, api.nilu_pushvalue(state, 13)); // 15
    try equal(@as(c_int, 1), api.nilu_rawequal(state, 13, 15));
    try state.push(.fromFunction(.{ .native = dummy })); // 16
    try state.push(.fromFunction(.{ .native = dummy })); // 17
    try equal(@as(c_int, 1), api.nilu_rawequal(state, 16, 17));
    try state.push(.fromFunction(try state.newCClosure(dummy, &.{.from(.{ .number = 1 })}))); // 18
    try state.push(.fromFunction(try state.newCClosure(dummy, &.{.from(.{ .number = 1 })}))); // 19
    try equal(@as(c_int, 0), api.nilu_rawequal(state, 18, 19));
    try equal(@as(c_int, 1), api.nilu_rawequal(state, 18, 18));
}

test "c_api_queries absent equality slots remain false without allocation or caller exposure" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try state.push(.nil);
    try state.pushFrame(.{ .base = 1, .function = .{ .native = dummy } });
    try state.push(.nil);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    const original = state.allocator;
    state.allocator = failing.allocator();
    defer state.allocator = original;
    for ([_]c_int{ 0, -2, 2, std.math.minInt(c_int), std.math.maxInt(c_int) }) |index| {
        try equal(@as(c_int, 0), api.nilu_rawequal(state, index, index));
        try equal(@as(c_int, 0), api.nilu_rawequal(state, 1, index));
        try equal(@as(c_int, 0), api.nilu_rawequal(state, index, 1));
    }
    try equal(@as(c_int, 1), api.nilu_rawequal(state, 1, -1));
    try equal(@as(c_int, 1), api.nilu_gettop(state));
    _ = state.popFrame();
}

test "c_api_queries stringtonumber agrees with unchanged Lua parsing fixture" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try equal(api.Status.ok, api.nilu_pushnumber(state, 42));
    var lines = std.mem.tokenizeScalar(u8, @embedFile("lua55-numeral-parsing"), '\n');
    var buffer: [128]u8 = undefined;
    var checked: usize = 0;
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        const space = std.mem.indexOfScalar(u8, line, ' ').?;
        const encoded = line[0..space];
        const bytes = if (std.mem.eql(u8, encoded, "-")) "" else try std.fmt.hexToBytes(&buffer, encoded);
        const expected = line[space + 1 ..];
        const status = api.nilu_stringtonumber(state, bytes.ptr, bytes.len);
        if (std.mem.eql(u8, expected, "nil")) {
            try equal(api.Status.syntax, status);
            try equal(@as(c_int, 1), api.nilu_gettop(state));
        } else {
            try equal(api.Status.ok, status);
            try equal(@as(c_int, 2), api.nilu_gettop(state));
            try equal(try std.fmt.parseInt(u64, expected, 16), @as(u64, @bitCast(api.nilu_tonumberx(state, -1, null))));
            try equal(api.Status.ok, api.nilu_settop(state, 1));
        }
        try equal(@as(f64, 42), api.nilu_tonumberx(state, 1, null));
        checked += 1;
    }
    try expect(checked > 0);
    std.debug.print("C stringtonumber fixture: {d} unchanged Lua conversions/refusals checked\n", .{checked});
}

test "c_api_queries bounded numeral input ignores following bytes and rejects embedded zeros" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    const bytes = [_]u8{ '1', '2', 'x', 0 };
    try equal(api.Status.ok, api.nilu_stringtonumber(state, &bytes, 2));
    try equal(@as(f64, 12), api.nilu_tonumberx(state, -1, null));
    for ([_][]const u8{ "", "12x", "1\x002", "nan", "inf", "0x" }) |input| {
        try equal(api.Status.syntax, api.nilu_stringtonumber(state, input.ptr, input.len));
        try equal(@as(c_int, 1), api.nilu_gettop(state));
    }
}

test "c_api_queries numeral push and zero raw length failures preserve visible stack" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    const original = state.allocator;
    state.allocator = failing.allocator();
    defer state.allocator = original;
    try equal(api.Status.memory, api.nilu_stringtonumber(state, "7", 1));
    try equal(api.Status.memory, api.nilu_rawlen(state, 0));
    try equal(api.Status.syntax, api.nilu_stringtonumber(state, "x", 1));
    try equal(@as(c_int, 0), api.nilu_gettop(state));
    state.allocator = original;
    try equal(api.Status.ok, api.nilu_settop(state, runtime.State.max_stack));
    try equal(api.Status.stack, api.nilu_stringtonumber(state, "7", 1));
    try equal(api.Status.stack, api.nilu_rawlen(state, -1));
    try equal(@as(c_int, runtime.State.max_stack), api.nilu_gettop(state));
}

test "c_api_identity distinct objects and zero userdata preserve aliases through GC" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try equal(api.Status.ok, api.nilu_newtable(state));
    try equal(api.Status.ok, api.nilu_pushvalue(state, 1));
    try equal(api.Status.ok, api.nilu_newtable(state));
    try expect(api.nilu_topointer(state, 1) != null);
    try expect(api.nilu_topointer(state, 1) == api.nilu_topointer(state, 2));
    try expect(api.nilu_topointer(state, 1) != api.nilu_topointer(state, 3));
    for (0..2) |_| try equal(api.Status.ok, api.nilu_pushstring(state, "same"));
    try equal(@as(c_int, 1), api.nilu_rawequal(state, 4, 5));
    try expect(api.nilu_topointer(state, 4) != api.nilu_topointer(state, 5));
    for (0..2) |_| try equal(api.Status.ok, api.nilu_newuserdata(state, 0, null));
    const pointer = api.nilu_topointer(state, 6);
    try expect(pointer != null and pointer == api.nilu_touserdata(state, 6));
    try expect(pointer != api.nilu_topointer(state, 7));
    try equal(api.Status.ok, api.nilu_rawlen(state, 6));
    try equal(@as(f64, 0), api.nilu_tonumberx(state, -1, null));
    try equal(api.Status.ok, api.nilu_settop(state, 10000));
    state.collect();
    try expect(pointer == api.nilu_topointer(state, 6));
    try expect(pointer != api.nilu_topointer(state, 7));
}

test "c_api_identity scalar absent and hidden caller slots have no identity or metatable" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try equal(api.Status.ok, api.nilu_newtable(state));
    state.get(1).?.unpack().table.metatable = try state.newTable();
    try state.pushFrame(.{ .base = 1, .function = .{ .native = dummy } });
    for ([_]c_int{ 0, 1, -1, std.math.minInt(c_int), std.math.maxInt(c_int) }) |index| {
        try expect(api.nilu_topointer(state, index) == null);
        try equal(api.Status.ok, api.nilu_getmetatable(state, index));
        try expect(state.get(-1).?.is(.nil));
        try equal(api.Status.ok, api.nilu_settop(state, 0));
    }
    for ([_]runtime.Value{ .nil, .from(.{ .boolean = true }), .from(.{ .number = 42 }) }) |value| {
        try state.push(value);
        try expect(api.nilu_topointer(state, -1) == null);
        try equal(api.Status.ok, api.nilu_getmetatable(state, -1));
        try expect(state.get(-1).?.is(.nil));
        try equal(api.Status.ok, api.nilu_settop(state, 0));
    }
    _ = state.popFrame();
    try expect(api.nilu_topointer(state, 1) != null);
}

test "c_api_identity function identities distinguish closure instances" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try state.push(.fromFunction(.{ .native = dummy }));
    try state.push(.fromFunction(.{ .native = dummy }));
    try expect(api.nilu_topointer(state, 1) != null);
    try expect(api.nilu_topointer(state, 1) == api.nilu_topointer(state, 2));
    for (0..2) |_| try state.push(.fromFunction(try state.newCClosure(dummy, &.{.from(.{ .number = 1 })})));
    try expect(api.nilu_topointer(state, 3) != null);
    try expect(api.nilu_topointer(state, 3) != api.nilu_topointer(state, 4));
    const position = @import("Token.zig").Position{ .offset = 0, .line = 1, .column = 1 };
    const code = [_]@import("bytecode.zig").Written{.{ .position = position, .operation = .{ .returns = .{ .first = 0, .count = 0 } } }};
    const prototype = try state.newProgram(&.{}, &code, 0, "", "<identity>");
    for (0..2) |_| try state.push(.fromFunction(.{ .closure = try state.newChunk(prototype) }));
    try expect(api.nilu_topointer(state, 5) != null);
    try expect(api.nilu_topointer(state, 5) != api.nilu_topointer(state, 6));
}

test "c_api_identity actual metatable bypasses protection and stays rooted after receiver removal" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    const meta = try state.newTable();
    state.barrier(&meta.header);
    try meta.set(state.allocator, .from(.{ .string = try state.newString("__metatable") }), .from(.{ .string = try state.newString("hidden") }));
    try equal(api.Status.ok, api.nilu_newtable(state));
    state.get(1).?.unpack().table.metatable = meta;
    try equal(api.Status.ok, api.nilu_newuserdata(state, 8, null));
    state.get(2).?.unpack().userdata.metatable = meta;
    for ([_]c_int{ 1, 2 }) |index| {
        try equal(api.Status.ok, api.nilu_getmetatable(state, index));
        try expect(state.get(-1).?.is(.table));
        try expect(state.get(-1).?.unpack().table == meta);
    }
    api.nilu_copy(state, -1, 1);
    try equal(api.Status.ok, api.nilu_settop(state, 1));
    state.collect();
    try std.testing.expectEqualStrings("hidden", state.get(1).?.unpack().table.getString("__metatable").unpack().string.bytes);
}

test "c_api_identity pointer reads allocate nothing and metatable growth failure preserves source" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try equal(api.Status.ok, api.nilu_newtable(state));
    const meta = try state.newTable();
    state.get(1).?.unpack().table.metatable = meta;
    const pointer = api.nilu_topointer(state, 1);
    while (state.stack.items.len < state.stack.capacity) try state.push(.nil);
    const depth = state.top();
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    const original = state.allocator;
    state.allocator = failing.allocator();
    defer state.allocator = original;
    try expect(pointer == api.nilu_topointer(state, 1));
    try equal(api.Status.memory, api.nilu_getmetatable(state, 1));
    try equal(depth, state.top());
    try expect(state.get(1).?.unpack().table.metatable == meta);
    state.allocator = original;
    try equal(api.Status.ok, api.nilu_settop(state, runtime.State.max_stack));
    try equal(api.Status.stack, api.nilu_getmetatable(state, 1));
}

fn zeroIdentityAllocationCase(allocator: std.mem.Allocator) !void {
    const state = try api.create(allocator);
    defer api.nilu_close(state);
    for (0..2) |i| {
        const status = api.nilu_newuserdata(state, 0, null);
        if (status == .memory) {
            try equal(i, state.top());
            return error.OutOfMemory;
        }
        try equal(api.Status.ok, status);
    }
    try expect(api.nilu_topointer(state, 1) != api.nilu_topointer(state, 2));
    try std.testing.expectError(error.OutOfMemory, state.newUserdata(std.math.maxInt(usize)));
}
test "c_api_identity zero userdata ownership survives every allocation failure" {
    try allocation_failures.checkAll(a, zeroIdentityAllocationCase, .{});
}

extern fn test_counter_callback(state: *runtime.State) c_int;

test "c_api_closures real C callbacks keep independent mutable state through internal VM calls" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try equal(api.Status.ok, api.nilu_pushnumber(state, 42));
    try equal(api.Status.ok, api.nilu_pushnumber(state, 0));
    try equal(api.Status.ok, api.nilu_pushcclosure(state, test_counter_callback, 1));
    try equal(api.Status.ok, api.nilu_pushnumber(state, 10));
    try equal(api.Status.ok, api.nilu_pushcclosure(state, test_counter_callback, 1));
    try equal(@as(c_int, 0), api.nilu_rawequal(state, 2, 3));
    state.collect();
    for ([_]struct { index: i64, expected: f64 }{ .{ .index = 2, .expected = 1 }, .{ .index = 2, .expected = 2 }, .{ .index = 3, .expected = 11 } }) |case| {
        var diagnostic: ?@import("vm.zig").Diagnostic = null;
        try equal(@as(usize, 1), try @import("vm.zig").runFunctionWithArguments(state, state.get(case.index).?.asFunction().?, 0, &diagnostic));
        try equal(case.expected, api.nilu_tonumberx(state, -1, null));
        try equal(@as(f64, 42), api.nilu_tonumberx(state, 1, null));
        try equal(api.Status.ok, api.nilu_settop(state, 3));
    }
}

test "c_api_closures capture top values in order close consumed cells and use light zero case" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try equal(api.Status.ok, api.nilu_pushnumber(state, 42));
    try equal(api.Status.ok, api.nilu_pushstring(state, "first"));
    try equal(api.Status.ok, api.nilu_pushnumber(state, 7));
    const cell = try state.capture(1);
    try equal(api.Status.ok, api.nilu_pushcclosure(state, dummy, 2));
    try equal(@as(c_int, 2), api.nilu_gettop(state));
    try expect(cell.storage == .closed);
    try std.testing.expectEqualStrings("first", state.readCell(cell).unpack().string.bytes);
    const closure = state.get(2).?.unpack().c_closure;
    try std.testing.expectEqualStrings("first", closure.upvalues[0].unpack().string.bytes);
    try expect(closure.upvalues[1].equal(.from(.{ .number = 7 })));
    try equal(api.Status.ok, api.nilu_pushcfunction(state, dummy));
    try equal(api.Status.ok, api.nilu_pushcclosure(state, dummy, 0));
    try equal(@as(c_int, 1), api.nilu_rawequal(state, -1, -2));
}

test "c_api_closures absent running closure and invalid upvalues retain stack and value" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try equal(api.Status.ok, api.nilu_pushnumber(state, 42));
    for ([_]c_int{ 0, 1, -1, std.math.minInt(c_int), std.math.maxInt(c_int) }) |index| {
        try equal(api.Status.type, api.nilu_getupvalue(state, index));
        try equal(api.Status.type, api.nilu_setupvalue(state, index));
        try equal(@as(c_int, 1), api.nilu_gettop(state));
    }
    try state.pushFrame(.{ .base = 1, .function = .{ .native = dummy } });
    try equal(api.Status.type, api.nilu_getupvalue(state, 1));
    try equal(api.Status.type, api.nilu_setupvalue(state, 1));
    _ = state.popFrame();
    const function = try state.newCClosure(dummy, &.{.from(.{ .number = 7 })});
    try state.pushFrame(.{ .base = 1, .function = function });
    try equal(api.Status.ok, api.nilu_pushnumber(state, 9));
    for ([_]c_int{ 0, 2, -1, std.math.minInt(c_int), std.math.maxInt(c_int) }) |index| {
        try equal(api.Status.type, api.nilu_getupvalue(state, index));
        try equal(api.Status.type, api.nilu_setupvalue(state, index));
        try equal(@as(c_int, 1), api.nilu_gettop(state));
    }
    try equal(api.Status.ok, api.nilu_setupvalue(state, 1));
    try equal(@as(c_int, 0), api.nilu_gettop(state));
    try expect(function.c_closure.upvalues[0].equal(.from(.{ .number = 9 })));
    _ = state.popFrame();
    try equal(@as(f64, 42), api.nilu_tonumberx(state, 1, null));
}

test "c_api_closures active closure and changed object upvalues stay rooted during collection" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    const function = try state.newCClosure(dummy, &.{.from(.{ .string = try state.newString("held") })});
    try state.pushFrame(.{ .base = 0, .function = function });
    state.collect();
    try equal(api.Status.ok, api.nilu_getupvalue(state, 1));
    try std.testing.expectEqualStrings("held", std.mem.span(api.nilu_tolstring(state, 1, null).?));
    try equal(api.Status.ok, api.nilu_settop(state, 0));
    try equal(api.Status.ok, api.nilu_newtable(state));
    const pointer = api.nilu_topointer(state, -1);
    try equal(api.Status.ok, api.nilu_setupvalue(state, 1));
    state.collect();
    try equal(api.Status.ok, api.nilu_getupvalue(state, 1));
    try expect(pointer == api.nilu_topointer(state, -1));
    _ = state.popFrame();
}

fn closureAllocationCase(allocator: std.mem.Allocator) !void {
    const state = try api.create(allocator);
    defer api.nilu_close(state);
    try state.push(.from(.{ .number = 42 }));
    const text = try state.newString("captured");
    try state.push(.from(.{ .string = text }));
    const status = api.nilu_pushcclosure(state, dummy, 1);
    if (status == .memory) {
        try equal(@as(usize, 2), state.top());
        try expect(state.get(2).?.unpack().string == text);
        return error.OutOfMemory;
    }
    try equal(api.Status.ok, status);
    try equal(@as(usize, 2), state.top());
    try expect(state.get(2).?.unpack().c_closure.upvalues[0].unpack().string == text);
}
test "c_api_closures every allocation failure preserves capture operands" {
    try allocation_failures.checkAll(a, closureAllocationCase, .{});
}

test "c_api_closures get allocation failure and full stack capture boundaries remain distinct" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    const function = try state.newCClosure(dummy, &.{.from(.{ .number = 7 })});
    try state.pushFrame(.{ .base = 0, .function = function });
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    const original = state.allocator;
    state.allocator = failing.allocator();
    defer state.allocator = original;
    try equal(api.Status.memory, api.nilu_getupvalue(state, 1));
    try equal(@as(c_int, 0), api.nilu_gettop(state));
    state.allocator = original;
    try equal(api.Status.ok, api.nilu_settop(state, runtime.State.max_stack));
    try equal(api.Status.stack, api.nilu_getupvalue(state, 1));
    try equal(api.Status.stack, api.nilu_pushcfunction(state, dummy));
    try equal(api.Status.stack, api.nilu_pushcclosure(state, dummy, 0));
    try equal(api.Status.ok, api.nilu_pushcclosure(state, dummy, 1));
    try equal(@as(c_int, runtime.State.max_stack), api.nilu_gettop(state));
    try equal(api.Status.ok, api.nilu_settop(state, 0));
    _ = state.popFrame();
    try equal(api.Status.ok, api.nilu_settop(state, runtime.State.max_upvalues));
    try equal(api.Status.ok, api.nilu_pushcclosure(state, dummy, runtime.State.max_upvalues));
    try equal(@as(usize, runtime.State.max_upvalues), state.get(-1).?.unpack().c_closure.upvalues.len);
}

extern fn test_hook_reset(c_int) callconv(.c) void;
extern fn test_hook_calls() callconv(.c) c_uint;
extern fn test_instruction_hook(*runtime.State) callconv(.c) c_int;

fn hookChunk(state: *runtime.State, source: []const u8) !*runtime.Closure {
    const parser = @import("parser.zig");
    const compiler = @import("compiler.zig");
    var parsed: ?parser.Diagnostic = null;
    var ast = try parser.parseChunk(a, source, &parsed);
    defer ast.deinit();
    var diagnostic: ?compiler.Diagnostic = null;
    return state.newChunk(try compiler.compile(a, state, &ast, "<c-hook>", &diagnostic));
}

test "c_api_hooks registration allocates nothing preserves stack and isolates states" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    const other = try api.create(a);
    defer api.nilu_close(other);
    try state.push(.from(.{ .number = 42 }));
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    const original = state.allocator;
    state.allocator = failing.allocator();
    defer state.allocator = original;
    test_hook_reset(0);
    api.nilu_sethook(state, test_instruction_hook, 2);
    try expect(other.hook == null);
    try expect(!state.hookStep());
    try expect(!state.hookStep());
    try equal(@as(c_uint, 0), test_hook_calls());
    try expect(!state.hookStep());
    try equal(@as(c_uint, 1), test_hook_calls());
    api.nilu_sethook(state, test_instruction_hook, std.math.maxInt(c_uint));
    try equal(std.math.maxInt(c_uint), state.hook_remaining);
    try expect(!state.hookStep());
    api.nilu_sethook(state, test_instruction_hook, 0);
    try expect(state.hook == null);
    api.nilu_sethook(state, test_instruction_hook, 1);
    api.nilu_sethook(state, null, 19);
    try expect(state.hook == null);
    try equal(@as(c_uint, 0), state.hook_remaining);
    try equal(@as(usize, 1), state.top());
    try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
    try equal(@as(usize, 0), failing.alloc_index);
}

test "c_api_hooks actual C observer interrupts VM for either nonzero sign then can be removed" {
    const vm = @import("vm.zig");
    for ([_]c_int{ 1, -1 }) |answer| {
        const state = try api.create(a);
        defer api.nilu_close(state);
        const loop = try hookChunk(state, "while true do end");
        try state.push(.from(.{ .number = 42 }));
        test_hook_reset(answer);
        api.nilu_sethook(state, test_instruction_hook, 10);
        var diagnostic: ?vm.Diagnostic = null;
        try std.testing.expectError(error.Interrupted, vm.run(state, loop, &diagnostic));
        try equal(@as(c_uint, 3), test_hook_calls());
        try equal(@as(usize, 1), state.top());
        try equal(@as(usize, 0), state.frames.items.len);
        try expect(state.hook_depth == 0);
        api.nilu_sethook(state, null, 0);
        const finite = try hookChunk(state, "return 7");
        try equal(@as(usize, 1), try vm.run(state, finite, &diagnostic));
        try equal(@as(c_uint, 3), test_hook_calls());
        try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
        try expect(state.get(2).?.equal(.from(.{ .number = 7 })));
    }
}

fn typeWindow(state: *runtime.State) callconv(.c) c_int {
    if (api.nilu_type(state, 1) != 1 or api.nilu_type(state, 0) != -1 or api.nilu_type(state, -2) != -1) return -1;
    return 0;
}
test "c_api types use stable tags and hide caller slots without conversion" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    const closure = try state.newChunk(try state.newProgram(&.{}, &.{}, 0, "", ""));
    const values = [_]runtime.Value{ .nil, .from(.{ .number = 1 }), .fromFunction(.{ .native = typeWindow }), .from(.{ .boolean = true }), .from(.{ .string = try state.newString("1") }), .from(.{ .table = try state.newTable() }), .from(.{ .userdata = try state.newUserdata(0) }), .fromFunction(try state.newCClosure(typeWindow, &.{.nil})), .fromFunction(.{ .closure = closure }), try state.integer(3), try state.integer(1 << 60) };
    for (values, [_]c_int{ 0, 1, 2, 3, 4, 5, 6, 2, 2, 1, 1 }) |value, tag| {
        try state.push(value);
        try equal(tag, api.nilu_type(&state, -1));
        try expect(state.get(-1).?.equal(value));
    }
    for ([_]c_int{ 0, 12, -12, std.math.minInt(c_int), std.math.maxInt(c_int) }) |index| try equal(@as(c_int, -1), api.nilu_type(&state, index));
    var diagnostic: ?@import("vm.zig").Diagnostic = null;
    try state.push(.from(.{ .number = 7 }));
    _ = try @import("vm.zig").runFunctionWithArguments(&state, .{ .native = typeWindow }, 1, &diagnostic);
    try equal(values.len, state.top());
}

test "c_api raw operations preserve failures bypass handlers and clear read provenance" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    const table = try state.newTable();
    const meta = try state.newTable();
    table.metatable = meta;
    for ([_][]const u8{ "__index", "__newindex" }) |name| try meta.set(state.allocator, .from(.{ .string = try state.newString(name) }), .fromFunction(.{ .native = typeWindow }));
    try state.push(.from(.{ .table = table }));
    try state.push(.from(.{ .string = try state.newString("key") }));
    try state.push(.from(.{ .number = 17 }));
    const stored_origin = try state.reserveFailureOrigin();
    state.publishFailureOrigin(stored_origin);
    stored_origin.record = .{ .kind = .type_error };
    state.setOrigin(2, stored_origin);
    try equal(api.Status.ok, api.nilu_rawset(&state, -3));
    try equal(@as(usize, 1), state.top());
    try state.push(.from(.{ .string = try state.newString("key") }));
    const token = try state.reserveFailureOrigin();
    state.publishFailureOrigin(token);
    token.record = .{ .kind = .type_error };
    state.setOrigin(1, token);
    try equal(api.Status.ok, api.nilu_rawget(&state, 1));
    try expect(state.get(-1).?.equal(.from(.{ .number = 17 })));
    try expect(state.originAt(1) == null);
    for ([_]runtime.Value{ .nil, .from(.{ .number = std.math.nan(f64) }) }) |key| {
        try state.setTop(1);
        try state.push(key);
        try state.push(.from(.{ .number = 99 }));
        try equal(api.Status.type, api.nilu_rawset(&state, 1));
        try equal(@as(usize, 3), state.top());
        try expect(state.get(-2).?.equal(key) or (key.is(.number) and std.math.isNan(state.get(-2).?.numberValue().?)));
        try equal(@as(f64, 17), table.getString("key").numberValue().?);
        try state.setTop(2);
        try equal(api.Status.ok, api.nilu_rawget(&state, 1));
        try expect(state.get(-1).?.is(.nil));
    }
    try state.setTop(0);
    try state.push(.from(.{ .number = 1 }));
    try state.push(.from(.{ .number = 2 }));
    try equal(api.Status.type, api.nilu_rawget(&state, 1));
    try equal(@as(f64, 2), state.get(-1).?.numberValue().?);
    try state.push(.from(.{ .number = 3 }));
    try equal(api.Status.type, api.nilu_rawset(&state, 1));
    try equal(@as(usize, 3), state.top());
}

fn rawAllocationCase(allocator: std.mem.Allocator) !void {
    var state = try runtime.State.init(allocator);
    defer state.deinit();
    const table = try state.newTable();
    try state.push(.from(.{ .table = table }));
    // Force both ordinary growth and tombstone replacement paths.
    for (0..40) |i| {
        try state.push(.from(.{ .number = @floatFromInt(i) }));
        try state.push(.from(.{ .number = @floatFromInt(i + 1) }));
        const before = table.live;
        const status = api.nilu_rawset(&state, 1);
        if (status == .memory) {
            try equal(@as(usize, 3), state.top());
            try equal(before, table.live);
            try expect(table.get(state.get(-2).?).is(.nil));
            try equal(@as(f64, @floatFromInt(i + 1)), state.get(-1).?.numberValue().?);
            return error.OutOfMemory;
        }
        try equal(api.Status.ok, status);
        if (i == 20) for (0..20) |j| try table.set(allocator, .from(.{ .number = @floatFromInt(j) }), .nil);
    }
    state.collect();
    try equal(@as(f64, 40), table.get(.from(.{ .number = 39 })).numberValue().?);
}
test "c_api rawset every allocation failure preserves operands and table" {
    try allocation_failures.checkAll(a, rawAllocationCase, .{});
}
