const std = @import("std");
const runtime = @import("runtime.zig");
const api = @import("c_api.zig");
const loader = @import("loader.zig");
const vm = @import("vm.zig");
const transport = @import("failure_transport.zig");
const a = std.testing.allocator;
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
extern fn test_namewhat(*runtime.State) callconv(.c) c_int;

fn install(state: *runtime.State, name: []const u8, value: runtime.Value) !void {
    state.barrier(&state.globals.header);
    try state.globals.set(a, .from(.{ .string = try state.newString(name) }), value);
}
fn run(state: *runtime.State, source: []const u8) !void {
    var loaded: ?loader.Diagnostic = null;
    const chunk = try loader.prepare(state, source, "=namewhat", &loaded);
    var diagnostic: ?vm.Diagnostic = null;
    _ = try vm.run(state, chunk, &diagnostic);
}
fn attach(state: *runtime.State, receiver: runtime.Value, key: []const u8, method: runtime.Value) !void {
    const meta = try state.newTable();
    state.barrier(&meta.header);
    try meta.set(a, .from(.{ .string = try state.newString(key) }), method);
    try state.setMetatable(receiver, meta);
}

test "c_api_namewhat actual C callback matches carried method field local global and callable expectations" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    const function = runtime.Value.fromFunction(.{ .native = test_namewhat });
    try install(&state, "how", function);
    const callable = runtime.Value.from(.{ .table = try state.newTable() });
    try attach(&state, callable, "__call", function);
    try install(&state, "c", callable);
    try run(&state, "local t={how=how} local h=how local o={c=c} return t:how()..' '..t.how()..' '..h()..' '..how()..' '..o:c()");
    try std.testing.expectEqualStrings("method field local global NULL", state.get(1).?.unpack().string.bytes);
    try expect(api.nilu_namewhat(&state) == null);
}

test "c_api_namewhat native tail entries retain direct kind and suppress it through call chains" {
    for ([_]struct { source: []const u8, wanted: []const u8 }{
        .{ .source = "return how()", .wanted = "global" },
        .{ .source = "local h=how return h()", .wanted = "local" },
        .{ .source = "return c()", .wanted = "NULL" },
        .{ .source = "local o={c=c} return o:c()", .wanted = "NULL" },
        .{ .source = "local h=how local function f() return h() end return f()", .wanted = "upvalue" },
        .{ .source = "for k in how do return k end", .wanted = "for iterator" },
    }) |case| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        const function = runtime.Value.fromFunction(.{ .native = test_namewhat });
        try install(&state, "how", function);
        const outer = runtime.Value.from(.{ .table = try state.newTable() });
        const inner = runtime.Value.from(.{ .userdata = try state.newUserdata(0) });
        try attach(&state, inner, "__call", function);
        try attach(&state, outer, "__call", inner);
        try install(&state, "c", outer);
        try run(&state, case.source);
        try std.testing.expectEqualStrings(case.wanted, state.get(1).?.unpack().string.bytes);
    }
}

fn wrapper(state: *runtime.State) callconv(.c) c_int {
    const before = api.nilu_namewhat(state) orelse return -1;
    if (!std.mem.eql(u8, std.mem.span(before), "global")) return -1;
    if (api.nilu_pushcfunction(state, test_namewhat) != .ok) return -1;
    var diagnostic: ?vm.Diagnostic = null;
    const result = transport.call(state, 0, true, &diagnostic) catch return -1;
    if (result != .success or result.success != 1) return -1;
    if (!std.mem.eql(u8, state.get(-1).?.unpack().string.bytes, "NULL")) return -1;
    const after = api.nilu_namewhat(state) orelse return -1;
    if (before != after) return -1;
    state.collect();
    return test_namewhat(state);
}
test "c_api_namewhat host reentry clears classification only for the nested native and restores caller" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try install(&state, "wrapper", .fromFunction(.{ .native = wrapper }));
    try run(&state, "return wrapper()");
    try std.testing.expectEqualStrings("global", state.get(1).?.unpack().string.bytes);
    try state.setTop(0);
    try state.push(.fromFunction(.{ .native = test_namewhat }));
    var diagnostic: ?vm.Diagnostic = null;
    _ = try transport.call(&state, 0, true, &diagnostic);
    try std.testing.expectEqualStrings("NULL", state.get(1).?.unpack().string.bytes);
    try expect(api.nilu_namewhat(&state) == null);
}

test "c_api_namewhat C closures keep classification while operator handlers have none" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try equal(api.Status.ok, api.nilu_pushnumber(&state, 13));
    try equal(api.Status.ok, api.nilu_pushcclosure(&state, test_namewhat, 1));
    const function = state.get(-1).?;
    try install(&state, "how", function);
    try state.setTop(0);
    const value = runtime.Value.from(.{ .table = try state.newTable() });
    try attach(&state, value, "__add", function);
    try install(&state, "t", value);
    try run(&state, "return how(),t+1");
    try std.testing.expectEqualStrings("global", state.get(1).?.unpack().string.bytes);
    try std.testing.expectEqualStrings("NULL", state.get(2).?.unpack().string.bytes);
}

fn inspectWithoutAllocation(state: *runtime.State) callconv(.c) c_int {
    const saved = state.allocator;
    defer state.allocator = saved;
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    state.allocator = failing.allocator();
    const top = state.top();
    const first = api.nilu_namewhat(state) orelse return -1;
    const second = api.nilu_namewhat(state) orelse return -1;
    if (first != second or state.top() != top or failing.alloc_index != 0) return -1;
    if (!std.mem.eql(u8, std.mem.span(first), "global")) return -1;
    return 0;
}
test "c_api_namewhat inspection allocates nothing and changes no visible slots" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try install(&state, "inspect", .fromFunction(.{ .native = inspectWithoutAllocation }));
    try run(&state, "inspect(7) return 9");
    try equal(@as(f64, 9), state.get(1).?.numberValue().?);
}
