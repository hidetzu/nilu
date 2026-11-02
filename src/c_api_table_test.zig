const std = @import("std");
const allocation_failures = @import("allocation_failures.zig");
const runtime = @import("runtime.zig");
const api = @import("c_api.zig");
const a = std.testing.allocator;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;

extern fn test_table_roundtrip(*runtime.State) callconv(.c) c_int;
extern fn test_api_operation_relay(*runtime.State) callconv(.c) c_int;
fn script(state: *runtime.State, source: []const u8) !runtime.Value {
    var diagnostic: ?@import("loader.zig").Diagnostic = null;
    return .fromFunction(.{ .closure = try @import("loader.zig").prepare(state, source, "=access-failure", &diagnostic) });
}
fn meta(state: *runtime.State, method: runtime.Value) !*runtime.Table {
    const result = try state.newTable();
    state.barrier(&result.header);
    for ([_][]const u8{ "__index", "__newindex", "__len", "__eq" }) |name|
        try result.set(state.allocator, .from(.{ .string = try state.newString(name) }), method);
    return result;
}
fn key(state: *runtime.State, text: [*:0]const u8) !void {
    try equal(api.Status.ok, api.nilu_pushstring(state, text));
}
test "c_api_table positive negative and alias indices preserve caller and replace only operands" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try equal(api.Status.ok, api.nilu_pushnumber(&state, 42));
    try equal(api.Status.ok, api.nilu_newtable(&state));
    try key(&state, "x");
    try equal(api.Status.ok, api.nilu_pushnumber(&state, 8));
    try equal(api.Status.ok, api.nilu_settable(&state, -3));
    try equal(@as(c_int, 2), api.nilu_gettop(&state));
    try key(&state, "x");
    try equal(api.Status.ok, api.nilu_gettable(&state, 2));
    try equal(@as(f64, 8), api.nilu_tonumberx(&state, -1, null));
    try equal(api.Status.ok, api.nilu_settop(&state, 2));
    try key(&state, "missing");
    try equal(api.Status.ok, api.nilu_gettable(&state, -2));
    try expect(state.get(-1).?.is(.nil));
    try equal(@as(f64, 42), api.nilu_tonumberx(&state, 1, null));
    try equal(api.Status.ok, api.nilu_settop(&state, 0));
    try equal(api.Status.ok, api.nilu_newtable(&state));
    // The target is also the top key: table keys read nil without handlers.
    try equal(api.Status.ok, api.nilu_gettable(&state, 1));
    try expect(state.get(1).?.is(.nil));
}
test "c_api_table direct refusals preserve all inputs and do not add diagnostics" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try equal(api.Status.ok, api.nilu_newtable(&state));
    try equal(api.Status.ok, api.nilu_pushnil(&state));
    try equal(api.Status.ok, api.nilu_pushnumber(&state, 8));
    try equal(api.Status.type, api.nilu_settable(&state, 1));
    try equal(@as(c_int, 3), api.nilu_gettop(&state));
    try expect(state.get(2).?.is(.nil) and state.get(3).?.equal(.from(.{ .number = 8 })));
    try equal(api.Status.ok, api.nilu_settop(&state, 1));
    try equal(api.Status.ok, api.nilu_pushnil(&state));
    try equal(api.Status.ok, api.nilu_gettable(&state, 1));
    try expect(state.get(-1).?.is(.nil));
    try equal(api.Status.ok, api.nilu_settop(&state, 0));
    try equal(api.Status.ok, api.nilu_pushnumber(&state, 7));
    try key(&state, "x");
    try equal(api.Status.type, api.nilu_gettable(&state, 1));
    try equal(@as(c_int, 2), api.nilu_gettop(&state));
    try std.testing.expectEqualStrings("x", state.get(-1).?.unpack().string.bytes);
}
test "c_api_table actual C roundtrip also registers a native global callable from script" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try equal(api.Status.ok, api.nilu_pushcfunction(&state, test_table_roundtrip));
    try equal(api.Status.ok, api.nilu_setglobal(&state, "roundtrip_fn"));
    try equal(api.Status.ok, api.nilu_getglobal(&state, "roundtrip_fn"));
    try equal(api.Status.ok, api.nilu_newtable(&state));
    try equal(api.Status.ok, api.nilu_call(&state, 1, 1));
    try equal(@as(f64, 8), api.nilu_tonumberx(&state, -1, null));
    try equal(api.Status.ok, api.nilu_settop(&state, 0));
    try equal(api.Status.ok, api.nilu_loadnamed(&state, "global roundtrip_fn return roundtrip_fn({})", "=global-client", null));
    try equal(api.Status.ok, api.nilu_call(&state, 0, 1));
    try equal(@as(f64, 8), api.nilu_tonumberx(&state, -1, null));
}
test "c_api_table actual C and C closure relay failure values from all six metamethod-aware operations" {
    for ([_]bool{ false, true }) |closure| for (0..6) |mode| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        const method = try script(&state, "return 1+nil");
        const methods = try meta(&state, method);
        const target = try state.newTable();
        target.metatable = methods;
        state.globals.metatable = methods;
        try equal(api.Status.ok, api.nilu_pushnumber(&state, 42));
        if (closure) {
            try equal(api.Status.ok, api.nilu_pushnumber(&state, 7));
            try equal(api.Status.ok, api.nilu_pushcclosure(&state, test_api_operation_relay, 1));
        } else try equal(api.Status.ok, api.nilu_pushcfunction(&state, test_api_operation_relay));
        try state.push(.from(.{ .table = target }));
        try equal(api.Status.ok, api.nilu_pushnumber(&state, @floatFromInt(mode)));
        try equal(api.Status.type, api.nilu_call(&state, 2, 0));
        try equal(@as(c_int, 2), api.nilu_gettop(&state));
        try equal(@as(f64, 42), api.nilu_tonumberx(&state, 1, null));
        try expect(state.get(-1).?.is(.string) and state.originAt(1) != null);
        var where: api.ErrorLocation = undefined;
        try std.testing.expectEqualStrings("access-failure", std.mem.span(api.nilu_where(&state, 0, &where).?));
        try equal(@as(c_int, 1), where.line);
    };
}
var frames: usize = 0;
fn reader(state: *runtime.State) callconv(.c) c_int {
    frames = state.frames.items.len;
    state.collect();
    if (state.top() != 2) return -2;
    if (api.nilu_pushvalue(state, 2) != .ok) return -1;
    return 1;
}
fn writer(state: *runtime.State) callconv(.c) c_int {
    frames = state.frames.items.len;
    state.collect();
    if (state.top() != 3) return -2;
    // Store in a backing table captured as a C upvalue, bypassing __newindex.
    if (api.nilu_getupvalue(state, 1) != .ok or api.nilu_pushvalue(state, 2) != .ok or api.nilu_pushvalue(state, 3) != .ok) return -1;
    if (api.nilu_rawset(state, -3) != .ok) return -1;
    return 0;
}
test "c_api_table inherited get and global get set run collecting handlers without extra frames" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    const backing = try state.newTable();
    const methods = try state.newTable();
    state.barrier(&methods.header);
    try methods.set(a, .from(.{ .string = try state.newString("__index") }), .fromFunction(.{ .native = reader }));
    const setter = try state.newCClosure(writer, &.{.from(.{ .table = backing })});
    state.barrier(&methods.header);
    try methods.set(a, .from(.{ .string = try state.newString("__newindex") }), .fromFunction(setter));
    const inherited = try state.newTable();
    const links = try state.newTable();
    state.barrier(&links.header);
    try links.set(a, .from(.{ .string = try state.newString("__index") }), .from(.{ .table = methods }));
    inherited.metatable = links;
    state.globals.metatable = inherited;
    try equal(api.Status.ok, api.nilu_getglobal(&state, "absent-name"));
    try std.testing.expectEqualStrings("absent-name", state.get(-1).?.unpack().string.bytes);
    try expect(state.originAt(0) == null);
    try equal(@as(usize, 1), frames);
    try equal(api.Status.ok, api.nilu_settop(&state, 0));
    try key(&state, "stored");
    try equal(api.Status.ok, api.nilu_setglobal(&state, "name"));
    try equal(@as(c_int, 0), api.nilu_gettop(&state));
    try std.testing.expectEqualStrings("stored", backing.getString("name").unpack().string.bytes);
    try equal(@as(usize, 1), frames);
}
fn stop(_: *runtime.State) callconv(.c) c_int {
    return 1;
}
test "c_api_table failed setters leave failure at the consumed key slot and interruption keeps nil origin" {
    for ([_]bool{ false, true }) |interrupted| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        const method = try script(&state, if (interrupted) "while true do end" else "return 1+nil");
        const target = try state.newTable();
        target.metatable = try meta(&state, method);
        try state.push(.from(.{ .number = 42 }));
        try state.push(.from(.{ .table = target }));
        try key(&state, "key");
        try state.push(.from(.{ .number = 7 }));
        if (interrupted) api.nilu_sethook(&state, stop, 1);
        try equal(if (interrupted) api.Status.interrupted else .type, api.nilu_settable(&state, 2));
        try equal(@as(c_int, 3), api.nilu_gettop(&state));
        try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
        try expect(state.originAt(2) != null);
        if (interrupted) try expect(state.get(3).?.is(.nil)) else try expect(state.get(3).?.is(.string));
        try expect(target.getString("key").is(.nil));
        try expect(state.execution == null and state.frames.items.len == 0);
    }
}
fn allocationCase(allocator: std.mem.Allocator) !void {
    var state = try runtime.State.init(allocator);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    const status = api.nilu_pushnumber(&state, 8);
    if (status == .memory) return error.OutOfMemory;
    try equal(api.Status.ok, status);
    const stored = api.nilu_setglobal(&state, "value");
    try expect(state.execution == null and state.frames.items.len == 0);
    if (stored == .memory) {
        try equal(@as(usize, 2), state.top());
        try expect(state.globals.getString("value").is(.nil));
        return error.OutOfMemory;
    }
    try equal(api.Status.ok, stored);
    try equal(@as(usize, 1), state.top());
    const fetched = api.nilu_getglobal(&state, "value");
    if (fetched == .memory) return error.OutOfMemory;
    try equal(api.Status.ok, fetched);
    try expect(state.get(1).?.equal(.from(.{ .number = 42 })) and state.get(2).?.equal(.from(.{ .number = 8 })));
}
test "c_api_table every allocation failure in globals preserves operands and partial state" {
    try allocation_failures.checkAll(a, allocationCase, .{});
}

fn raisedNumber(state: *runtime.State) callconv(.c) c_int {
    if (api.nilu_pushnumber(state, 8) != .ok) return -1;
    return api.nilu_error(state);
}
test "c_api_table full stack replacement needs no extra value slot and storage strips provenance" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try equal(api.Status.ok, api.nilu_newtable(&state));
    try key(&state, "k");
    try equal(api.Status.ok, api.nilu_pushcfunction(&state, raisedNumber));
    try equal(api.Status.runtime, api.nilu_call(&state, 0, 0));
    try expect(state.originAt(2) != null);
    try equal(api.Status.ok, api.nilu_settable(&state, 1));
    try equal(api.Status.ok, api.nilu_settop(&state, 999999));
    try key(&state, "k");
    try equal(api.Status.ok, api.nilu_gettable(&state, 1));
    try equal(@as(c_int, 1000000), api.nilu_gettop(&state));
    try equal(@as(f64, 8), api.nilu_tonumberx(&state, -1, null));
    try expect(state.originAt(999999) == null);
    try equal(api.Status.stack, api.nilu_getglobal(&state, "absent"));
    try equal(@as(c_int, 1000000), api.nilu_gettop(&state));
}
fn metamethodAllocationCase(allocator: std.mem.Allocator) !void {
    var state = try runtime.State.init(allocator);
    defer state.deinit();
    const method = try script(&state, "local t={} return 1+nil");
    state.globals.metatable = try meta(&state, method);
    try state.push(.from(.{ .number = 42 }));
    state.setCollectionThreshold(0);
    const status = api.nilu_getglobal(&state, "absent");
    try expect(state.execution == null and state.frames.items.len == 0);
    try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
    if (status == .memory) {
        if (state.top() == 2) {
            try expect(state.get(-1).?.unpack().string == state.memory_failure);
            try expect(state.originAt(1) != null);
        } else try equal(@as(usize, 1), state.top());
        return error.OutOfMemory;
    }
    try equal(api.Status.type, status);
    try equal(@as(usize, 2), state.top());
    try expect(state.get(-1).?.is(.string) and state.originAt(1) != null);
    state.collect();
}
test "c_api_table every allocation failure distinguishes setup refusal from executed metamethod failure" {
    try allocation_failures.checkAll(a, metamethodAllocationCase, .{});
}

// nilu_getmetafield: the C API's view of the metamethod walk of manual 7.4,
// and the library's use of it for __tostring, __name and __pairs (ADR 0012).
fn load(state: *runtime.State, source: [*:0]const u8) !void {
    try equal(api.Status.ok, api.nilu_loadstring(state, source, null));
    try equal(api.Status.ok, api.nilu_call(state, 0, 1));
}

test "c_api_metafield finds a name raw, one link away, and answers nil when absent" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try equal(api.Status.ok, api.nilu_openlibs(state));
    // t's metatable is empty but inherits __tostring and __name from base.
    try load(state, "local base = {} base.__tostring = function() return 'B' end base.__name = 'Base' local mt = setmetatable({}, {__index = base}) return setmetatable({}, mt)");
    try equal(api.Status.ok, api.nilu_getmetafield(state, 1, "__tostring"));
    try equal(@as(c_int, 2), api.nilu_type(state, -1));
    try equal(api.Status.ok, api.nilu_getmetafield(state, 1, "__name"));
    try std.testing.expectEqualStrings("Base", std.mem.span(api.nilu_tolstring(state, -1, null).?));
    try equal(api.Status.ok, api.nilu_getmetafield(state, 1, "__call"));
    try equal(@as(c_int, 0), api.nilu_type(state, -1));
    try equal(api.Status.ok, api.nilu_pushnumber(state, 1));
    try equal(api.Status.ok, api.nilu_getmetafield(state, -1, "__tostring"));
    try equal(@as(c_int, 0), api.nilu_type(state, -1));
    try equal(@as(c_int, 6), api.nilu_gettop(state));
}

test "c_api_metafield answers runtime without pushing when the chain is too long" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try equal(api.Status.ok, api.nilu_openlibs(state));
    try load(state, "local mt = {} setmetatable(mt, {__index = mt}) return setmetatable({}, mt)");
    try equal(api.Status.runtime, api.nilu_getmetafield(state, 1, "__tostring"));
    try equal(@as(c_int, 1), api.nilu_gettop(state));
}

test "c_api_metafield the library spells and traverses through inherited names" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try equal(api.Status.ok, api.nilu_openlibs(state));
    try load(state, "local base = {} base.__tostring = function() return 'B' end base.__pairs = function(t) return next, {inherited = true}, nil end local mt = setmetatable({}, {__index = base}) local t = setmetatable({}, mt) local k = next(t) for key in pairs(t) do k = key end return tostring(t) .. ':' .. tostring(k)");
    try std.testing.expectEqualStrings("B:inherited", std.mem.span(api.nilu_tolstring(state, -1, null).?));
    // __name one link away names the operand in the library's refusal.
    try equal(api.Status.ok, api.nilu_settop(state, 0));
    try load(state, "local base = {} base.__name = 'Point' local mt = setmetatable({}, {__index = base}) local t = setmetatable({}, mt) return select(2, pcall(string.rep, t, 1))");
    try std.testing.expectEqualStrings("bad argument #1 to 'rep' (string expected, got Point)", std.mem.span(api.nilu_tolstring(state, -1, null).?));
    // __metatable stays a raw attribute of the metatable itself.
    try equal(api.Status.ok, api.nilu_settop(state, 0));
    try load(state, "local base = {} base.__metatable = 'locked' local mt = setmetatable({}, {__index = base}) local t = setmetatable({}, mt) return getmetatable(t) == mt");
    try equal(@as(c_int, 1), api.nilu_toboolean(state, -1));
}

fn bare(_: *runtime.State) callconv(.c) c_int {
    return -1;
}
fn put(state: *runtime.State, name: [*:0]const u8, value: f64) !void {
    try equal(api.Status.ok, api.nilu_pushstring(state, name));
    try equal(api.Status.ok, api.nilu_pushnumber(state, value));
    try equal(api.Status.ok, api.nilu_rawset(state, 1));
}
test "c_api_remaining next traverses clears more allows deletion and NULL output" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try equal(api.Status.ok, api.nilu_newtable(&state));
    try put(&state, "a", 1);
    try put(&state, "b", 2);
    try equal(api.Status.ok, api.nilu_pushnil(&state));
    var seen: usize = 0;
    var sum: f64 = 0;
    var more: c_int = 99;
    while (true) {
        try equal(api.Status.ok, api.nilu_next(&state, 1, &more));
        if (more == 0) break;
        seen += 1;
        sum += api.nilu_tonumberx(&state, -1, null);
        try equal(api.Status.ok, api.nilu_settop(&state, -2));
        // Delete exactly the current key while retaining its traversal token.
        try equal(api.Status.ok, api.nilu_pushvalue(&state, -1));
        try equal(api.Status.ok, api.nilu_pushnil(&state));
        try equal(api.Status.ok, api.nilu_rawset(&state, 1));
        state.collect();
    }
    try equal(@as(usize, 2), seen);
    try equal(@as(f64, 3), sum);
    try equal(@as(c_int, 1), api.nilu_gettop(&state));
    try equal(api.Status.ok, api.nilu_pushnil(&state));
    try equal(api.Status.ok, api.nilu_next(&state, -2, null));
    try equal(@as(c_int, 1), api.nilu_gettop(&state));
}
test "c_api_remaining next refuses before mutation and checks end invalid key before capacity" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try equal(api.Status.ok, api.nilu_newtable(&state));
    try put(&state, "a", 7);
    try equal(api.Status.ok, api.nilu_settop(&state, 999999));
    try equal(api.Status.ok, api.nilu_pushstring(&state, "absent"));
    var more: c_int = 99;
    try equal(api.Status.runtime, api.nilu_next(&state, 1, &more));
    try equal(@as(c_int, 0), more);
    try std.testing.expectEqualStrings("absent", state.get(-1).?.unpack().string.bytes);
    try equal(api.Status.ok, api.nilu_settop(&state, -2));
    try equal(api.Status.ok, api.nilu_pushnil(&state));
    more = 99;
    try equal(api.Status.stack, api.nilu_next(&state, 1, &more));
    try equal(@as(c_int, 0), more);
    try expect(state.get(-1).?.is(.nil));
    try equal(api.Status.ok, api.nilu_settop(&state, -2));
    try equal(api.Status.ok, api.nilu_pushstring(&state, "a"));
    more = 99;
    try equal(api.Status.ok, api.nilu_next(&state, 1, &more));
    try equal(@as(c_int, 0), more);
    try equal(@as(c_int, 999999), api.nilu_gettop(&state));
    // A non-table remains Type with key preserved even at full capacity.
    try equal(api.Status.ok, api.nilu_pushnumber(&state, 8));
    more = 99;
    try equal(api.Status.type, api.nilu_next(&state, -1, &more));
    try equal(@as(c_int, 0), more);
    try equal(@as(f64, 8), api.nilu_tonumberx(&state, -1, null));
}
test "c_api_remaining next pair allocation refusal preserves key table more and provenance" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try equal(api.Status.ok, api.nilu_newtable(&state));
    try put(&state, "a", 1);
    try equal(api.Status.ok, api.nilu_pushcfunction(&state, bare));
    try equal(api.Status.runtime, api.nilu_call(&state, 0, 0));
    const origin = state.originAt(1).?;
    const capacity = @min(state.stack.capacity, state.origins.capacity);
    try equal(api.Status.ok, api.nilu_settop(&state, @intCast(capacity)));
    api.nilu_copy(&state, 2, -1);
    var refusing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    state.allocator = refusing.allocator();
    var more: c_int = 99;
    const result = api.nilu_next(&state, 1, &more);
    state.allocator = a;
    try equal(api.Status.memory, result);
    try equal(@as(c_int, 0), more);
    try equal(capacity, state.top());
    try expect(state.get(-1).?.is(.nil));
    try expect(state.get(1).?.unpack().table.getString("a").equal(.from(.{ .number = 1 })));
    try expect(state.originAt(capacity - 1) == origin);
    try equal(api.Status.ok, api.nilu_next(&state, 1, &more));
    try equal(@as(c_int, 1), more);
    try expect(state.originAt(capacity - 1) == null and state.originAt(capacity) == null);
}
test "c_api_remaining metatable wrong operands preserve inputs under a refusing allocator and C bypasses protection" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try equal(api.Status.ok, api.nilu_newtable(&state));
    try equal(api.Status.ok, api.nilu_pushnumber(&state, 9));
    var refusing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    state.allocator = refusing.allocator();
    const bad = api.nilu_setmetatable(&state, 1);
    state.allocator = a;
    try equal(api.Status.type, bad);
    try equal(@as(c_int, 2), api.nilu_gettop(&state));
    try equal(@as(f64, 9), api.nilu_tonumberx(&state, -1, null));
    try equal(api.Status.ok, api.nilu_settop(&state, 1));
    try equal(api.Status.ok, api.nilu_newtable(&state));
    try equal(api.Status.ok, api.nilu_pushstring(&state, "__metatable"));
    try equal(api.Status.ok, api.nilu_pushboolean(&state, 0));
    try equal(api.Status.ok, api.nilu_rawset(&state, 2));
    try equal(api.Status.ok, api.nilu_setmetatable(&state, -2));
    try equal(api.Status.ok, api.nilu_pushnil(&state));
    try equal(api.Status.ok, api.nilu_setmetatable(&state, 1));
    try expect(state.get(1).?.unpack().table.metatable == null);
    try equal(api.Status.ok, api.nilu_pushnil(&state));
    try equal(api.Status.type, api.nilu_setmetatable(&state, -1));
    try equal(@as(c_int, 2), api.nilu_gettop(&state));
    try equal(api.Status.ok, api.nilu_settop(&state, 1));
    // Target and top may alias; the self-metatable cycle is collectable.
    try equal(api.Status.ok, api.nilu_setmetatable(&state, 1));
    try equal(@as(c_int, 0), api.nilu_gettop(&state));
    state.collect();
}
test "c_api_remaining userdata finalizers remain raw and refusal is atomic" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try equal(api.Status.ok, api.nilu_newuserdata(&state, 0, null));
    try equal(api.Status.ok, api.nilu_newtable(&state));
    try equal(api.Status.ok, api.nilu_pushstring(&state, "__gc"));
    try equal(api.Status.ok, api.nilu_pushboolean(&state, 0));
    try equal(api.Status.ok, api.nilu_rawset(&state, 2));
    try equal(api.Status.type, api.nilu_setmetatable(&state, 1));
    try equal(@as(c_int, 2), api.nilu_gettop(&state));
    try expect(state.get(1).?.unpack().userdata.metatable == null);
    try equal(api.Status.ok, api.nilu_pushstring(&state, "__gc"));
    try equal(api.Status.ok, api.nilu_pushnil(&state));
    try equal(api.Status.ok, api.nilu_rawset(&state, 2));
    try equal(api.Status.ok, api.nilu_setmetatable(&state, 1));
    try expect(state.get(1).?.unpack().userdata.metatable != null);
    try equal(api.Status.ok, api.nilu_pushnil(&state));
    try equal(api.Status.ok, api.nilu_setmetatable(&state, 1));
    try expect(state.get(1).?.unpack().userdata.metatable == null);
}
