const std = @import("std");
const allocation_failures = @import("allocation_failures.zig");
const api = @import("c_api.zig");
const runtime = @import("runtime.zig");
const vm = @import("vm.zig");
const transport = @import("failure_transport.zig");
const a = std.testing.allocator;
const equal = std.testing.expectEqual;
const expect = std.testing.expect;

var hook_calls: usize = 0;
fn observer(_: *runtime.State) callconv(.c) c_int {
    hook_calls += 1;
    return 1;
}

test "c_api_load owns source and name after return and loads without execution or hooks" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    var source = "global marker=99 return 'held'".* ++ [_:0]u8{};
    var name = "=owned".* ++ [_:0]u8{};
    var where = api.ErrorLocation{ .line = 99, .column = 99 };
    api.nilu_sethook(&state, observer, 1);
    hook_calls = 0;
    try equal(api.Status.ok, api.nilu_loadnamed(&state, &source, &name, &where));
    try equal(@as(usize, 0), hook_calls);
    try expect(state.globals.getString("marker").is(.nil));
    try equal(api.ErrorLocation{}, where);
    try equal(@as(usize, 2), state.top());
    try expect(state.originAt(1) == null);
    const chunk = state.get(-1).?.unpack().closure;
    @memset(source[0..source.len], '?');
    @memset(name[0..name.len], '?');
    state.collect();
    try std.testing.expectEqualStrings("=owned", chunk.prototype.chunk_name);
    try std.testing.expectEqualStrings("owned", chunk.prototype.displayName());
    api.nilu_sethook(&state, null, 0);
    var diagnostic: ?vm.Diagnostic = null;
    _ = try transport.call(&state, 0, true, &diagnostic);
    try equal(@as(f64, 42), state.get(1).?.numberValue().?);
    try std.testing.expectEqualStrings("held", state.get(-1).?.unpack().string.bytes);
    try equal(@as(f64, 99), state.globals.getString("marker").numberValue().?);
}

test "c_api_load syntax messages coordinates optional output and nul terminated text" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    var where = api.ErrorLocation{ .line = 99, .column = 99 };
    try equal(api.Status.syntax, api.nilu_loadnamed(&state, "local = 1", "=probe", &where));
    try equal(api.ErrorLocation{ .line = 1, .column = 7 }, where);
    try std.testing.expectEqualStrings("probe:1:7: <name> expected near '='", state.get(-1).?.unpack().string.bytes);
    try expect(state.originAt(1) == null);
    state.collect();
    try equal(api.Status.syntax, api.nilu_loadnamed(&state, "local = 1", "=probe", null));
    try expect(state.get(-1).?.equal(state.get(-2).?));
    try equal(api.Status.ok, api.nilu_loadstring(&state, "return 1\x00this is ignored", &where));
    try equal(api.ErrorLocation{}, where);
    const chunk = state.get(-1).?.unpack().closure;
    try std.testing.expectEqualStrings("return 1", chunk.prototype.source);
    try std.testing.expectEqualStrings("return 1", chunk.prototype.chunk_name);
    try std.testing.expectEqualStrings("[string \"return 1\"]", chunk.prototype.displayName());
    try equal(@as(f64, 42), state.get(1).?.numberValue().?);
}

fn allocationCase(allocator: std.mem.Allocator, source: [*:0]const u8, named: bool) !void {
    var state = try runtime.State.init(allocator);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    const token = try state.reserveFailureOrigin();
    state.publishFailureOrigin(token);
    token.record = .{ .kind = .type_error };
    state.setOrigin(0, token);
    var where = api.ErrorLocation{ .line = 99, .column = 99 };
    const status = if (named) api.nilu_loadnamed(&state, source, "=allocation", &where) else api.nilu_loadstring(&state, source, &where);
    try equal(@as(f64, 42), state.get(1).?.numberValue().?);
    try expect(state.originAt(0) == token);
    try equal(@as(usize, 0), state.frames.items.len);
    if (status == .memory) {
        try equal(@as(usize, 1), state.top());
        try equal(api.ErrorLocation{}, where);
        return error.OutOfMemory;
    }
    try expect(status == .ok or status == .syntax);
    try equal(@as(usize, 2), state.top());
    try expect(state.originAt(1) == null);
    state.collect();
    if (status == .ok) {
        try equal(api.ErrorLocation{}, where);
        try equal(@as(c_int, 2), api.nilu_type(&state, -1));
    } else {
        try expect(where.line > 0 and where.column > 0);
        try equal(@as(c_int, 4), api.nilu_type(&state, -1));
    }
}
test "c_api_load every allocation failure preserves caller slots origins and clears output" {
    for ([_][*:0]const u8{ "local t={v=7} return function() return t.v end", "local = 1", "return '\\q'", "goto absent", "local function f() return ... end" }) |source|
        for ([_]bool{ false, true }) |named|
            try allocation_failures.checkAll(a, allocationCase, .{ source, named });
}

test "c_api_load full stack refuses before parsing and leaves no diagnostic or coordinates" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try state.setTop(runtime.State.max_stack);
    state.stack.items[state.stack.items.len - 1] = .from(.{ .number = 42 });
    var where = api.ErrorLocation{ .line = 99, .column = 99 };
    for ([_][*:0]const u8{ "return 1", "local = 1" }) |source| {
        try equal(api.Status.stack, api.nilu_loadstring(&state, source, &where));
        try equal(api.ErrorLocation{}, where);
        try equal(runtime.State.max_stack, state.top());
        try equal(@as(f64, 42), state.get(-1).?.numberValue().?);
    }
}

fn memoryLoad(state: *runtime.State) callconv(.c) c_int {
    const saved = state.allocator;
    defer state.allocator = saved;
    var failing = std.testing.FailingAllocator.init(saved, .{ .fail_index = 0 });
    state.allocator = failing.allocator();
    var where = api.ErrorLocation{ .line = 99, .column = 99 };
    if (api.nilu_loadstring(state, "return 1", &where) != .memory or where.line != 0 or where.column != 0) return 0;
    return -1;
}
test "c_api_load Memory notification preserves native bare failure status" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try state.push(.fromFunction(.{ .native = memoryLoad }));
    var diagnostic: ?vm.Diagnostic = null;
    const result = try transport.call(&state, 0, true, &diagnostic);
    try equal(runtime.FailureKind.out_of_memory, result.failure);
    try expect(state.get(-1).?.unpack().string == state.memory_failure);
}

test "c_api_load bounded malformed byte corpus returns source refusals without internal outcomes" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    var source: [32:0]u8 = undefined;
    var seed: u32 = 0x51ab92e7;
    for (0..1024) |_| {
        for (&source) |*byte| {
            seed = seed *% 1664525 +% 1013904223;
            byte.* = @intCast(1 + seed % 127);
        }
        source[source.len] = 0;
        var where: api.ErrorLocation = .{};
        const status = api.nilu_loadnamed(&state, &source, "=bytes", &where);
        try expect(status == .ok or status == .syntax);
        try equal(@as(usize, 1), state.top());
        try equal(api.Status.ok, api.nilu_settop(&state, 0));
        state.collect();
    }
}

fn raiseSyntaxValue(state: *runtime.State) callconv(.c) c_int {
    if (api.nilu_loadnamed(state, "local = 1", "=inner", null) != .syntax) return 0;
    return api.nilu_error(state);
}
test "c_api_load explicitly raising a syntax message is a fresh Runtime failure" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try state.push(.fromFunction(.{ .native = raiseSyntaxValue }));
    var diagnostic: ?vm.Diagnostic = null;
    const result = try transport.call(&state, 0, true, &diagnostic);
    try equal(runtime.FailureKind.runtime_error, result.failure);
    try std.testing.expectEqualStrings("inner:1:7: <name> expected near '='", state.get(-1).?.unpack().string.bytes);
}
