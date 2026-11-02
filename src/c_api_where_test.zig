const std = @import("std");
const runtime = @import("runtime.zig");
const api = @import("c_api.zig");
const transport = @import("failure_transport.zig");
const loader = @import("loader.zig");
const vm = @import("vm.zig");
const Location = @import("execution_location.zig").Location;
const a = std.testing.allocator;
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
extern fn test_where_chain(*runtime.State) callconv(.c) c_int;
extern fn test_where_name(c_int) callconv(.c) ?[*:0]const u8;
extern fn test_where_line(c_int) callconv(.c) c_int;
fn prepare(state: *runtime.State, source: []const u8, name: []const u8) !*runtime.Closure {
    var diagnostic: ?loader.Diagnostic = null;
    return loader.prepare(state, source, name, &diagnostic);
}
fn install(state: *runtime.State, name: []const u8, value: runtime.Value) !void {
    state.barrier(&state.globals.header);
    try state.globals.set(a, .from(.{ .string = try state.newString(name) }), value);
}
fn call(state: *runtime.State, protected: bool) !transport.Result {
    var diagnostic: ?vm.Diagnostic = null;
    return transport.call(state, 0, protected, &diagnostic);
}
fn bad(state: *runtime.State, name: [*:0]const u8) !void {
    try equal(api.Status.ok, api.nilu_loadnamed(state, "local t={}\nlocal x=t.missing\nreturn x.y", name, null));
}

test "c_api_where protected and unprotected failures retain names after GC and repeated queries" {
    for ([_]bool{ false, true }) |protected| for ([_]struct { input: [*:0]const u8, wanted: []const u8 }{
        .{ .input = "=literal", .wanted = "literal" },
        .{ .input = "@config.nilu", .wanted = "config.nilu" },
        .{ .input = "=", .wanted = "" },
    }) |case| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        var where = api.ErrorLocation{ .line = 99, .column = 99 };
        try expect(api.nilu_where(&state, 0, &where) == null);
        try equal(api.ErrorLocation{}, where);
        try bad(&state, case.input);
        try equal(runtime.FailureKind.type_error, (try call(&state, protected)).failure);
        const pointer = api.nilu_where(&state, 0, &where).?;
        try std.testing.expectEqualStrings(case.wanted, std.mem.span(pointer));
        try equal(@as(c_int, 3), where.line);
        try equal(@as(c_int, 0), where.column);
        if (protected) try expect(state.failure == null and state.originAt(0) == null);
        state.collect();
        for ([_]c_int{ std.math.minInt(c_int), -1, 1, std.math.maxInt(c_int) }) |level| {
            where = .{ .line = 99, .column = 99 };
            try expect(api.nilu_where(&state, level, &where) == null);
            try equal(api.ErrorLocation{}, where);
            try std.testing.expectEqualStrings(case.wanted, std.mem.span(pointer));
        }
        try std.testing.expectEqualStrings(case.wanted, std.mem.span(api.nilu_where(&state, 0, null).?));
        try std.testing.expectEqualStrings(case.wanted, std.mem.span(pointer));
        // Raw operations and loading do not begin a call or invalidate its name.
        try equal(api.Status.ok, api.nilu_pushnil(&state));
        try equal(api.Status.type, api.nilu_rawget(&state, 1));
        try equal(api.Status.syntax, api.nilu_loadstring(&state, "local = 1", null));
        try std.testing.expectEqualStrings(case.wanted, std.mem.span(api.nilu_where(&state, 0, &where).?));
        try equal(@as(c_int, 3), where.line);
        try std.testing.expectEqualStrings(case.wanted, std.mem.span(pointer));
    };
}

test "c_api_where success and preflight Stack or Memory refusal clear publication without overwriting a borrowed name" {
    for ([_]bool{ false, true }) |memory| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        try bad(&state, "=previous");
        _ = try call(&state, true);
        const pointer = api.nilu_where(&state, 0, null).?;
        try equal(api.Status.ok, api.nilu_settop(&state, 0));
        try equal(api.Status.ok, api.nilu_loadnamed(&state, "return 9", "=success", null));
        try std.testing.expectEqualStrings("previous", std.mem.span(pointer));
        var diagnostic: ?vm.Diagnostic = null;
        if (memory) {
            // The reservation is what asks for memory first; a kept one
            // would let the call start without asking.
            if (state.spare_origin) |token| state.allocator.destroy(token);
            state.spare_origin = null;
            const saved = state.allocator;
            defer state.allocator = saved;
            var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
            state.allocator = failing.allocator();
            try std.testing.expectError(error.OutOfMemory, transport.call(&state, 0, true, &diagnostic));
        } else try std.testing.expectError(error.StackLimit, transport.callAdjusted(&state, 0, runtime.State.max_stack + 1, true, null, &diagnostic));
        var where = api.ErrorLocation{ .line = 99, .column = 99 };
        try expect(api.nilu_where(&state, 0, &where) == null);
        try equal(api.ErrorLocation{}, where);
        // No target ran, so the earlier borrowed bytes remain usable.
        try std.testing.expectEqualStrings("previous", std.mem.span(pointer));
        try equal(@as(usize, 1), (try call(&state, true)).success);
        try expect(api.nilu_where(&state, 0, null) == null);
        try equal(api.Status.ok, api.nilu_settop(&state, 0));
        try equal(api.Status.ok, api.nilu_pushnil(&state));
        try equal(runtime.FailureKind.type_error, (try call(&state, true)).failure);
        try expect(api.nilu_where(&state, 0, &where) == null);
        try equal(api.ErrorLocation{}, where);
    }
}

test "c_api_where actual C handler retains three distinct chunk pointers across queries before unwind" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try install(&state, "c", .fromFunction(.{ .closure = try prepare(&state, "\nreturn 1+nil", "=inner") }));
    try install(&state, "b", .fromFunction(.{ .closure = try prepare(&state, "\n\nlocal v=c() return v", "=middle") }));
    const root = try prepare(&state, "local v=b() return v", "=outer");
    try state.push(.fromFunction(.{ .closure = root }));
    var diagnostic: ?vm.Diagnostic = null;
    try equal(runtime.FailureKind.type_error, (try transport.callWithHandler(&state, 0, true, .fromFunction(.{ .native = test_where_chain }), &diagnostic)).failure);
    for ([_][]const u8{ "inner", "middle", "outer" }, [_]c_int{ 2, 3, 1 }, 0..) |name, line, index| {
        try std.testing.expectEqualStrings(name, std.mem.span(test_where_name(@intCast(index)).?));
        try equal(line, test_where_line(@intCast(index)));
    }
    try std.testing.expectEqualStrings("handled", state.get(1).?.unpack().string.bytes);
    try expect(state.failure == null);
    var where: api.ErrorLocation = .{};
    const pointer = api.nilu_where(&state, 0, &where).?;
    try std.testing.expectEqualStrings("inner", std.mem.span(pointer));
    try equal(@as(c_int, 2), where.line);
    try expect(api.nilu_where(&state, 1, &where) == null);
    try std.testing.expectEqualStrings("inner", std.mem.span(pointer));
}

fn noop(_: *runtime.State) callconv(.c) c_int {
    return 0;
}
test "c_api_where C int limits retain names and read-only queries work under a refusing allocator" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    const chunk = try prepare(&state, "return 9", "=boundary");
    try state.push(.from(.{ .number = 42 }));
    const token = try state.reserveFailureOrigin();
    state.publishFailureOrigin(token);
    token.record = .{ .kind = .type_error };
    state.setOrigin(0, token);
    // The frame points at an instruction; this one's line is set per case.
    // A copy of the first instruction with an `Info` of its own, whose line
    // each case sets.
    var at_info = chunk.prototype.code[0].info.*;
    var at = chunk.prototype.code[0];
    at.info = &at_info;
    try state.pushFrame(.{ .base = 0, .function = .{ .closure = chunk }, .instruction = &at });
    try state.pushFrame(.{ .base = 0, .function = .{ .native = noop } });
    const saved = state.allocator;
    defer state.allocator = saved;
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    state.allocator = failing.allocator();
    for ([_]struct { line: usize, wanted: c_int }{
        .{ .line = @intCast(std.math.maxInt(c_int)), .wanted = std.math.maxInt(c_int) },
        .{ .line = @as(usize, @intCast(std.math.maxInt(c_int))) + 1, .wanted = 0 },
        .{ .line = std.math.maxInt(usize), .wanted = 0 },
    }) |case| {
        // A bytecode position holds 32 bits; the largest it can be is past C's int too.
        at_info.position.line = std.math.cast(u32, case.line) orelse std.math.maxInt(u32);
        state.call_locations.items[0] = Location.init("saved", case.line);
        state.last_call_location_index = 0;
        state.has_last_call_location = true;
        var where = api.ErrorLocation{ .line = 99, .column = 99 };
        const live = api.nilu_where(&state, 1, &where).?;
        try std.testing.expectEqualStrings("boundary", std.mem.span(live));
        try equal(api.ErrorLocation{ .line = case.wanted }, where);
        const last = api.nilu_where(&state, 0, &where).?;
        try std.testing.expectEqualStrings("saved", std.mem.span(last));
        try equal(api.ErrorLocation{ .line = case.wanted }, where);
        try std.testing.expectEqualStrings("boundary", std.mem.span(live));
    }
    try equal(@as(usize, 0), failing.alloc_index);
    try equal(@as(usize, 1), state.top());
    try equal(@as(f64, 42), state.get(1).?.numberValue().?);
    try expect(state.originAt(0) == token);
}

var native_probe_ok: bool = false;
fn probe(state: *runtime.State) callconv(.c) c_int {
    var where = api.ErrorLocation{ .line = 99, .column = 99 };
    const native = api.nilu_where(state, 1, &where) orelse return -1;
    if (!std.mem.eql(u8, std.mem.span(native), "[C]") or where.line != 0 or where.column != 0) return -1;
    const script = api.nilu_where(state, 2, &where) orelse return -1;
    if (!std.mem.eql(u8, std.mem.span(script), "root") or where.line != 1 or where.column != 0) return -1;
    native_probe_ok = std.mem.eql(u8, std.mem.span(native), "[C]");
    return 0;
}
fn nativeOuter(state: *runtime.State) callconv(.c) c_int {
    state.push(.fromFunction(.{ .native = probe })) catch return -1;
    _ = call(state, true) catch return -1;
    return 0;
}
test "c_api_where live native callers are C line zero and script callers retain their position" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try install(&state, "outer", .fromFunction(.{ .native = nativeOuter }));
    try state.push(.fromFunction(.{ .closure = try prepare(&state, "outer() return 7", "=root") }));
    native_probe_ok = false;
    _ = try call(&state, true);
    try expect(native_probe_ok);
    try expect(api.nilu_where(&state, 0, null) == null);
}

test "c_api_where another state's call and collection do not invalidate the first state's name" {
    var first = try runtime.State.init(a);
    defer first.deinit();
    var second = try runtime.State.init(a);
    defer second.deinit();
    try bad(&first, "=first");
    _ = try call(&first, true);
    const pointer = api.nilu_where(&first, 0, null).?;
    try bad(&second, "=second");
    _ = try call(&second, true);
    first.collect();
    second.collect();
    try std.testing.expectEqualStrings("first", std.mem.span(pointer));
    try std.testing.expectEqualStrings("second", std.mem.span(api.nilu_where(&second, 0, null).?));
}

var inner_pointer: ?[*:0]const u8 = null;
fn catchInner(state: *runtime.State) callconv(.c) c_int {
    state.push(state.globals.getString("bad")) catch return -1;
    const result = call(state, true) catch return -1;
    if (result != .failure) return -1;
    inner_pointer = api.nilu_where(state, 0, null);
    return 0;
}
test "c_api_where outer success clears nested failed-call publication without changing already borrowed bytes" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try install(&state, "bad", .fromFunction(.{ .closure = try prepare(&state, "return 1+nil", "=inner") }));
    try install(&state, "catcher", .fromFunction(.{ .native = catchInner }));
    try state.push(.fromFunction(.{ .closure = try prepare(&state, "catcher() return 7", "=outer") }));
    inner_pointer = null;
    _ = try call(&state, true);
    try expect(api.nilu_where(&state, 0, null) == null);
    try std.testing.expectEqualStrings("inner", std.mem.span(inner_pointer.?));
}

fn catchThenRaise(state: *runtime.State) callconv(.c) c_int {
    state.push(state.globals.getString("bad")) catch return -1;
    const result = call(state, true) catch return -1;
    if (result != .failure) return -1;
    inner_pointer = api.nilu_where(state, 0, null);
    if (api.nilu_pushstring(state, "new outer failure") != .ok) return -1;
    return api.nilu_error(state);
}
test "c_api_where outer failure publication does not overwrite an inner name borrowed after the last call began" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try install(&state, "bad", .fromFunction(.{ .closure = try prepare(&state, "return 1+nil", "=inner") }));
    try install(&state, "fresh", .fromFunction(.{ .native = catchThenRaise }));
    try state.push(.fromFunction(.{ .closure = try prepare(&state, "return fresh()", "=outer") }));
    inner_pointer = null;
    try equal(runtime.FailureKind.runtime_error, (try call(&state, true)).failure);
    try std.testing.expectEqualStrings("outer", std.mem.span(api.nilu_where(&state, 0, null).?));
    try std.testing.expectEqualStrings("inner", std.mem.span(inner_pointer.?));
}

fn recurse(state: *runtime.State) callconv(.c) c_int {
    state.push(.fromFunction(.{ .native = recurse })) catch return -1;
    const result = call(state, false) catch return -1;
    if (result == .failure) return api.nilu_error(state);
    return 0;
}
test "c_api_where publication slots cover the existing native call limit and restore depth after refusal" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try state.push(.fromFunction(.{ .native = recurse }));
    try equal(runtime.FailureKind.call_depth, (try call(&state, false)).failure);
    try equal(@as(usize, 0), state.call_location_depth);
    try equal(@as(usize, 0), state.frames.items.len);
    try expect(api.nilu_where(&state, 0, null) == null);
}
