const std = @import("std");
const runtime = @import("runtime.zig");
const locations = @import("execution_location.zig");
const api = @import("c_api.zig");
const transport = @import("failure_transport.zig");
const loader = @import("loader.zig");
const vm = @import("vm.zig");
const a = std.testing.allocator;
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
fn prepare(state: *runtime.State, source: []const u8, name: []const u8) !*runtime.Closure {
    var diagnostic: ?loader.Diagnostic = null;
    return loader.prepare(state, source, name, &diagnostic);
}
fn install(state: *runtime.State, name: []const u8, value: runtime.Value) !void {
    state.barrier(&state.globals.header);
    try state.globals.set(a, .from(.{ .string = try state.newString(name) }), value);
}

test "execution_location original chunk and line survive unwind GC success and state destruction" {
    var saved: locations.Location = undefined;
    {
        var state = try runtime.State.init(a);
        defer state.deinit();
        const chunk = try prepare(&state, "local function inner()\n local v=1+nil return v\nend\nlocal v=inner() return v", "=original");
        var diagnostic: ?vm.Diagnostic = null;
        try std.testing.expectError(error.Type, vm.run(&state, chunk, &diagnostic));
        try equal(@as(usize, 0), state.frames.items.len);
        saved = locations.activeFailure(&state).?;
        try std.testing.expectEqualStrings("original", saved.name());
        try equal(@as(usize, 2), saved.line);
        state.collect();
        try expect(std.meta.eql(saved, locations.activeFailure(&state).?));
        _ = try vm.run(&state, try prepare(&state, "return 9", "=success"), &diagnostic);
        try expect(locations.activeFailure(&state) == null);
    }
    try std.testing.expectEqualStrings("original", saved.name());
    try equal(@as(usize, 2), saved.line);
}

fn relay(state: *runtime.State) callconv(.c) c_int {
    state.push(state.globals.getString("bad")) catch return -1;
    var diagnostic: ?vm.Diagnostic = null;
    const result = transport.call(state, 0, false, &diagnostic) catch return -1;
    if (result != .failure) return -1;
    state.collect();
    return api.nilu_error(state);
}
test "execution_location native relay keeps the inner chunk instead of the outer caller chunk" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try install(&state, "bad", .fromFunction(.{ .closure = try prepare(&state, "\nreturn 1+nil", "=inner") }));
    try install(&state, "relay", .fromFunction(.{ .native = relay }));
    var diagnostic: ?vm.Diagnostic = null;
    try std.testing.expectError(error.Type, vm.run(&state, try prepare(&state, "return relay()", "=outer"), &diagnostic));
    const found = locations.activeFailure(&state).?;
    try std.testing.expectEqualStrings("inner", found.name());
    try equal(@as(usize, 2), found.line);
    try expect(state.originAt(0) == null);
}

var seen: [4]?locations.Location = @splat(null);
fn inspectHandler(state: *runtime.State) callconv(.c) c_int {
    state.collect();
    for (&seen, 1..) |*entry, level| entry.* = locations.caller(state, level);
    return 0;
}
test "execution_location handler sees all live script frames before unwind" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    const source = "local function c()\n local v=1+nil return v\nend\nlocal function b() local v=c() return v end\nlocal v=b()\nreturn v";
    const chunk = try prepare(&state, source, "=chain");
    try state.push(.fromFunction(.{ .closure = chunk }));
    seen = @splat(null);
    var diagnostic: ?vm.Diagnostic = null;
    try equal(runtime.FailureKind.type_error, (try transport.callWithHandler(&state, 0, true, .fromFunction(.{ .native = inspectHandler }), &diagnostic)).failure);
    for ([_]usize{ 2, 4, 5 }, seen[0..3]) |line, entry| {
        try std.testing.expectEqualStrings("chain", entry.?.name());
        try equal(line, entry.?.line);
    }
    try expect(seen[3] == null);
    try equal(@as(usize, 0), state.frames.items.len);
    try expect(locations.caller(&state, 1) == null);
    try expect(locations.activeFailure(&state) == null);
}

fn innerNative(state: *runtime.State) callconv(.c) c_int {
    const saved = state.allocator;
    defer state.allocator = saved;
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    state.allocator = failing.allocator();
    const top = state.top();
    for (&seen, 1..) |*entry, level| entry.* = locations.caller(state, level);
    if (state.top() != top or failing.alloc_index != 0) return -1;
    if (locations.caller(state, std.math.maxInt(usize)) != null or locations.caller(state, 0) != null) return -1;
    return 0;
}
fn outerNative(state: *runtime.State) callconv(.c) c_int {
    state.push(.fromFunction(.{ .native = innerNative })) catch return -1;
    var diagnostic: ?vm.Diagnostic = null;
    _ = transport.call(state, 0, true, &diagnostic) catch return -1;
    return 0;
}
test "execution_location native callers are C line zero and queries allocate nothing" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try install(&state, "outer", .fromFunction(.{ .native = outerNative }));
    seen = @splat(null);
    var diagnostic: ?vm.Diagnostic = null;
    _ = try vm.run(&state, try prepare(&state, "outer() return 7", "=script"), &diagnostic);
    try std.testing.expectEqualStrings("[C]", seen[0].?.name());
    try equal(@as(usize, 0), seen[0].?.line);
    try std.testing.expectEqualStrings("script", seen[1].?.name());
    try equal(@as(usize, 1), seen[1].?.line);
    try expect(seen[2] == null and seen[3] == null);
    try equal(@as(f64, 7), state.get(1).?.numberValue().?);
}

test "execution_location host refusal has no fabricated location and formatting OOM retains the original snapshot" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try state.push(.nil);
    var diagnostic: ?vm.Diagnostic = null;
    _ = try transport.call(&state, 0, false, &diagnostic);
    try expect(locations.activeFailure(&state) == null);
    try state.setTop(0);
    const chunk = try prepare(&state, "return 1+nil", "=oom");
    try runtime.growStack(&state.stack, state.open_cells.items, state.allocator, 1024);
    try state.ensureOrigins(1024);
    const saved_allocator = state.allocator;
    defer state.allocator = saved_allocator;
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    state.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, vm.run(&state, chunk, &diagnostic));
    const found = locations.activeFailure(&state).?;
    try std.testing.expectEqualStrings("oom", found.name());
    try equal(@as(usize, 1), found.line);
}

var native_handler_ran: bool = false;
var native_handler_location: ?locations.Location = null;
var native_handler_line: ?usize = null;
fn inspectNativeFailure(state: *runtime.State) callconv(.c) c_int {
    native_handler_ran = true;
    const original = state.execution.?.suspended.get() orelse return -1;
    native_handler_location = original.location;
    native_handler_line = if (original.position) |position| position.line else null;
    state.collect();
    return 1;
}
fn raiseNative(state: *runtime.State) callconv(.c) c_int {
    if (api.nilu_pushstring(state, "new failure") != .ok) return -1;
    return api.nilu_error(state);
}
fn bareNative(_: *runtime.State) callconv(.c) c_int {
    return -1;
}
fn resetNativeObservation() void {
    native_handler_ran = false;
    native_handler_location = null;
    native_handler_line = null;
}
test "execution_location fresh native raises and bare failure are positioned before handler dispatch" {
    for ([_]runtime.Native{ raiseNative, bareNative }) |callback| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        try install(&state, "bad", .fromFunction(.{ .native = callback }));
        const chunk = try prepare(&state, "local function f()\n local v=bad() return v\nend\nlocal v=f() return v", "=native-caller");
        try state.push(.fromFunction(.{ .closure = chunk }));
        resetNativeObservation();
        var diagnostic: ?vm.Diagnostic = null;
        try equal(runtime.FailureKind.runtime_error, (try transport.callWithHandler(&state, 0, true, .fromFunction(.{ .native = inspectNativeFailure }), &diagnostic)).failure);
        try expect(native_handler_ran);
        try expect(native_handler_location != null);
        try std.testing.expectEqualStrings("native-caller", native_handler_location.?.name());
        try equal(@as(usize, 2), native_handler_location.?.line);
        try equal(@as(?usize, 2), native_handler_line);
        if (callback == bareNative) try expect(state.get(-1).?.is(.nil)) else try std.testing.expectEqualStrings("new failure", state.get(-1).?.unpack().string.bytes);
        try expect(state.execution == null and state.frames.items.len == 0);
    }
}

test "execution_location a native host failure without a script has no fabricated location even in its handler" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    var previous: ?vm.Diagnostic = null;
    try std.testing.expectError(error.Type, vm.run(&state, try prepare(&state, "return 1+nil", "=stale"), &previous));
    try expect(locations.activeFailure(&state) != null);
    try state.push(.fromFunction(.{ .native = raiseNative }));
    resetNativeObservation();
    var diagnostic: ?vm.Diagnostic = null;
    try equal(runtime.FailureKind.runtime_error, (try transport.callWithHandler(&state, 0, true, .fromFunction(.{ .native = inspectNativeFailure }), &diagnostic)).failure);
    try expect(native_handler_ran);
    try expect(native_handler_location == null and native_handler_line == null);
}

fn catchAndRaiseNew(state: *runtime.State) callconv(.c) c_int {
    state.push(state.globals.getString("inner")) catch return -1;
    var diagnostic: ?vm.Diagnostic = null;
    const result = transport.call(state, 0, true, &diagnostic) catch return -1;
    if (result != .failure) return -1;
    return api.nilu_error(state);
}
test "execution_location protected capture followed by a new native raise uses its own caller before handling" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try install(&state, "inner", .fromFunction(.{ .closure = try prepare(&state, "\nreturn 1+nil", "=original-inner") }));
    try install(&state, "again", .fromFunction(.{ .native = catchAndRaiseNew }));
    try state.push(.fromFunction(.{ .closure = try prepare(&state, "\n\nlocal v=again() return v", "=new-outer") }));
    resetNativeObservation();
    var diagnostic: ?vm.Diagnostic = null;
    try equal(runtime.FailureKind.runtime_error, (try transport.callWithHandler(&state, 0, true, .fromFunction(.{ .native = inspectNativeFailure }), &diagnostic)).failure);
    try expect(native_handler_ran and native_handler_location != null);
    try std.testing.expectEqualStrings("new-outer", native_handler_location.?.name());
    try equal(@as(usize, 3), native_handler_location.?.line);
    // The words can still name the caught inner failure; provenance and the
    // new raise position are separate from message text.
    try std.testing.expectEqualStrings("original-inner:2: attempt to perform arithmetic on a nil value", state.get(-1).?.unpack().string.bytes);
}

var refusing_native: std.testing.FailingAllocator = undefined;
fn failApiMemory(state: *runtime.State) callconv(.c) c_int {
    state.allocator = refusing_native.allocator();
    if (api.nilu_pushstring(state, "must allocate") != .memory) return 0;
    return -1;
}
test "execution_location native API Memory gets its caller snapshot without allocation or handler execution" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try install(&state, "oom", .fromFunction(.{ .native = failApiMemory }));
    const chunk = try prepare(&state, "\nlocal v=oom() return v", "=native-oom");
    try state.push(.fromFunction(.{ .closure = chunk }));
    refusing_native = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    defer state.allocator = a;
    const execution = @import("execution_context.zig");
    var protection = execution.Protection{ .handler = .{ .native = inspectNativeFailure } };
    var boundary = execution.Context{ .window = execution.Window.above(&state), .protection = &protection };
    boundary.enter(&state);
    defer boundary.leave(&state, false);
    resetNativeObservation();
    var diagnostic: ?vm.Diagnostic = null;
    try equal(runtime.FailureKind.out_of_memory, (try transport.call(&state, 0, false, &diagnostic)).failure);
    state.allocator = a;
    try expect(!native_handler_ran);
    const found = locations.activeFailure(&state).?;
    try std.testing.expectEqualStrings("native-oom", found.name());
    try equal(@as(usize, 2), found.line);
    try expect(state.get(-1).?.unpack().string == state.memory_failure);
    try equal(@as(usize, 0), state.frames.items.len);
}
