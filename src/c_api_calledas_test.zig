const std = @import("std");
const allocation_failures = @import("allocation_failures.zig");
const runtime = @import("runtime.zig");
const api = @import("c_api.zig");
const a = std.testing.allocator;
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
extern fn test_calledas(*runtime.State) callconv(.c) c_int;
extern fn test_calledas_pointer() callconv(.c) ?[*:0]const u8;
extern fn test_calledas_length() callconv(.c) usize;
extern fn test_calledas_kind() callconv(.c) ?[*:0]const u8;
fn install(state: *runtime.State, name: [*:0]const u8, callback: runtime.Native) !void {
    try equal(api.Status.ok, api.nilu_pushcfunction(state, callback));
    try equal(api.Status.ok, api.nilu_setglobal(state, name));
}
fn run(state: *runtime.State, source: []const u8) !void {
    const temporary = try a.dupeSentinel(u8, source, 0);
    const status = api.nilu_loadnamed(state, temporary.ptr, "=calledas", null);
    a.free(temporary);
    try equal(api.Status.ok, status);
    try equal(api.Status.ok, api.nilu_call(state, 0, -1));
}
test "c_api_calledas actual C and C closure preserve written escaped NUL empty and iterator names" {
    for ([_]bool{ false, true }) |closure| for ([_]struct { source: []const u8, wanted: []const u8 }{
        .{ .source = "return probe()", .wanted = "probe" },
        .{ .source = "local p=probe local v=p() return v", .wanted = "p" },
        .{ .source = "local t={x=probe} return t.x()", .wanted = "x" },
        .{ .source = "local t={m=probe} return t:m()", .wanted = "m" },
        .{ .source = "local p=probe local function f() return p() end return f()", .wanted = "p" },
        .{ .source = "local t={x=probe} return t['\\120']()", .wanted = "x" },
        .{ .source = "local t={['a\\000b']=probe} return t['a\\000b']()", .wanted = "a\x00b" },
        .{ .source = "local t={['']=probe} return t['']()", .wanted = "" },
        .{ .source = "local t={['\\u{1f600}']=probe} return t['\\u{1f600}']()", .wanted = "\xf0\x9f\x98\x80" },
        .{ .source = "local t={['a\\nb']=probe} return t[ [=[\na\r\nb]=] ]()", .wanted = "a\nb" },
        .{ .source = "for k in probe do return k end", .wanted = "for iterator" },
        .{ .source = "local function f() return probe end return f()()", .wanted = "<NULL>" },
    }) |case| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        if (closure) {
            try equal(api.Status.ok, api.nilu_pushnumber(&state, 7));
            try equal(api.Status.ok, api.nilu_pushcclosure(&state, test_calledas, 1));
            try equal(api.Status.ok, api.nilu_setglobal(&state, "probe"));
        } else try install(&state, "probe", test_calledas);
        try run(&state, case.source);
        try std.testing.expectEqualSlices(u8, case.wanted, state.get(-1).?.unpack().string.bytes);
        const borrowed = test_calledas_pointer();
        const length = test_calledas_length();
        state.collect();
        var no_name: usize = 99;
        try expect(api.nilu_calledas(&state, &no_name) == null);
        try equal(@as(usize, 0), no_name);
        if (borrowed) |pointer| try std.testing.expectEqualSlices(u8, case.wanted, pointer[0..length]);
    };
}
test "c_api_calledas callable chain keeps original name while namewhat remains absent" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try equal(api.Status.ok, api.nilu_newtable(&state));
    try equal(api.Status.ok, api.nilu_newtable(&state));
    try equal(api.Status.ok, api.nilu_pushstring(&state, "__call"));
    try equal(api.Status.ok, api.nilu_pushcfunction(&state, test_calledas));
    try equal(api.Status.ok, api.nilu_rawset(&state, 2));
    try equal(api.Status.ok, api.nilu_setmetatable(&state, 1));
    try equal(api.Status.ok, api.nilu_setglobal(&state, "t"));
    try run(&state, "return t()");
    try std.testing.expectEqualStrings("t", state.get(-1).?.unpack().string.bytes);
    try expect(test_calledas_kind() == null);
}
var restored: bool = false;
fn reenter(state: *runtime.State) callconv(.c) c_int {
    var length: usize = 0;
    const before = api.nilu_calledas(state, &length) orelse return -2;
    if (api.nilu_pushcfunction(state, test_calledas) != .ok) return -1;
    if (api.nilu_pcall(state, 0, 0, 0) != .ok) return -1;
    var after_length: usize = 99;
    const after = api.nilu_calledas(state, &after_length) orelse return -2;
    restored = before == after and length == after_length and test_calledas_pointer() == null;
    return 0;
}
fn readonly(state: *runtime.State) callconv(.c) c_int {
    const top = state.top();
    var failing = std.testing.FailingAllocator.init(state.allocator, .{ .fail_index = 0 });
    const allocator = state.allocator;
    state.allocator = failing.allocator();
    var length: usize = 99;
    const name = api.nilu_calledas(state, &length);
    const again = api.nilu_calledas(state, null);
    state.allocator = allocator;
    if (name == null or again != name or length != 1 or name.?[0] != 'p' or state.top() != top or failing.alloc_index != 0) return -2;
    state.collect();
    return 0;
}
test "c_api_calledas readonly lookup and nested host entry restore caller metadata" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try install(&state, "probe", readonly);
    try run(&state, "local p=probe p()");
    try install(&state, "wrapper", reenter);
    restored = false;
    try run(&state, "wrapper()");
    try expect(restored);
    try equal(api.Status.ok, api.nilu_pushcfunction(&state, test_calledas));
    try equal(api.Status.ok, api.nilu_call(&state, 0, 1));
    try std.testing.expectEqualStrings("<NULL>", state.get(-1).?.unpack().string.bytes);
}
fn allocationCase(allocator: std.mem.Allocator) !void {
    var state = try runtime.State.init(allocator);
    defer state.deinit();
    const status = api.nilu_loadnamed(&state, "local p=function() end p() local t={['a\\000b']=p} t['a\\000b']()", "=allocation", null);
    if (status == .memory) return error.OutOfMemory;
    try equal(api.Status.ok, status);
    const result = api.nilu_call(&state, 0, 0);
    if (result == .memory) return error.OutOfMemory;
    try equal(api.Status.ok, result);
}
test "c_api_calledas each allocation failure releases partial cached name and failed preparation" {
    try allocation_failures.checkAll(a, allocationCase, .{});
}

test "c_api_calledas borrowed names survive another state GC and repeated absent queries" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try install(&state, "probe", test_calledas);
    try run(&state, "return probe()");
    const saved = test_calledas_pointer().?;
    const length = test_calledas_length();
    {
        var other = try runtime.State.init(a);
        defer other.deinit();
        try install(&other, "probe", test_calledas);
        try run(&other, "local other=probe return other()");
        try expect(test_calledas_pointer().? != saved);
        other.collect();
        try std.testing.expectEqualSlices(u8, "probe", saved[0..length]);
    }
    state.collect();
    for (0..3) |_| {
        var missing: usize = 99;
        try expect(api.nilu_calledas(&state, &missing) == null);
        try equal(@as(usize, 0), missing);
        try std.testing.expectEqualSlices(u8, "probe", saved[0..length]);
    }
}
test "c_api_calledas cache indices are rebuilt and malformed prepared names are refused safely" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    const bytecode = @import("bytecode.zig");
    const vm = @import("vm.zig");
    const position = @import("Token.zig").Position{ .offset = 0, .line = 1, .column = 1 };
    var code = [_]bytecode.Written{
        .{ .position = position, .operation = .{ .call = .{ .base = 0, .arguments = 0, .results = 0 } }, .names = .{ .primary = .{ .kind = .global, .text = .{ .span = .{ .start = 0, .end = 1 } } } } },
        .{ .position = position, .operation = .{ .returns = .{ .first = 0, .count = 0 } } },
    };
    const prototype = try state.newProgram(&.{}, &code, 1, "f", "=cache");
    try equal(@as(?u32, 0), prototype.info[0].call_name_index);
    try equal(@as(usize, 1), prototype.call_names.len);
    try std.testing.expectEqualStrings("f", prototype.call_names[0].?);
    try vm.validate(prototype);
    prototype.info[0].call_name_index = 1;
    try std.testing.expectError(error.InvalidBytecode, vm.validate(prototype));
    prototype.info[0].call_name_index = 0;
    const saved = prototype.call_names[0];
    prototype.call_names[0] = null;
    defer prototype.call_names[0] = saved;
    try std.testing.expectError(error.InvalidBytecode, vm.validate(prototype));
    code[0].names.primary = .{ .kind = .field, .text = .{ .literal = .{ .contents = .{ .start = 0, .end = 2 }, .long_level = null } } };
    const malformed = try state.newProgram(&.{}, &code, 1, "\\q", "=invalid");
    try std.testing.expectError(error.InvalidBytecode, vm.validate(malformed));
}
