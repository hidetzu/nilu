const std = @import("std");
const allocation_failures = @import("allocation_failures.zig");
const runtime = @import("runtime.zig");
const api = @import("c_api.zig");
const transport = @import("failure_transport.zig");
const loader = @import("loader.zig");
const vm = @import("vm.zig");
const a = std.testing.allocator;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
extern fn test_handler_message(*runtime.State) callconv(.c) c_int;
fn prepare(state: *runtime.State, source: []const u8) !*runtime.Closure {
    var diagnostic: ?loader.Diagnostic = null;
    return loader.prepare(state, source, "=handler", &diagnostic);
}
fn pushTarget(state: *runtime.State, source: []const u8) !void {
    try state.push(.fromFunction(.{ .closure = try prepare(state, source) }));
}
var calls: usize = 0;
var chain_seen: bool = false;
fn chain(state: *runtime.State) callconv(.c) c_int {
    calls += 1;
    if (state.top() != 1 or state.frames.items.len != 4) return -1;
    const frames = state.frames.items;
    const saved = state.globals.getString("saved").unpack().closure;
    chain_seen = frames[2].position().?.line == 4 and frames[1].position().?.line == 8 and frames[0].position().?.line == 11 and saved.upvalues[0].storage == .open;
    state.collect();
    if (!state.readCell(saved.upvalues[0]).equal(.from(.{ .number = 7 }))) return -1;
    if (api.nilu_pushstring(state, "handled") != .ok) return -1;
    return 1;
}

test "failure_handling runs before all failed frames unwind and before captured locals close" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    try pushTarget(&state, "local function c()\n local x=7\n saved=function() return x end\n local bad=1+nil\n return bad\nend\nlocal function b()\n local x=c()\n return x\nend\nlocal x=b()\nreturn x");
    calls = 0;
    chain_seen = false;
    state.setCollectionThreshold(0);
    var diagnostic: ?vm.Diagnostic = null;
    const result = try transport.callWithHandler(&state, 0, true, .fromFunction(.{ .native = chain }), &diagnostic);
    try equal(runtime.FailureKind.type_error, result.failure);
    try equal(@as(usize, 1), calls);
    try expect(chain_seen);
    try equal(@as(usize, 2), state.top());
    try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
    try std.testing.expectEqualStrings("handled", state.get(2).?.unpack().string.bytes);
    try expect(state.originAt(1) == null);
    try expect(state.failure == null);
    try expect(state.execution == null);
    try equal(@as(usize, 0), state.frames.items.len);
    const saved = state.globals.getString("saved").unpack().closure;
    try expect(saved.upvalues[0].storage == .closed);
    state.collect();
    try equal(@as(usize, 1), try vm.run(&state, saved, &diagnostic));
    try expect(state.get(3).?.equal(.from(.{ .number = 7 })));
}

fn none(_: *runtime.State) callconv(.c) c_int {
    calls += 1;
    return 0;
}
fn fail(state: *runtime.State) callconv(.c) c_int {
    calls += 1;
    _ = api.nilu_pushstring(state, "handler failed");
    return api.nilu_error(state);
}
fn bare(_: *runtime.State) callconv(.c) c_int {
    return -1;
}

test "failure_handling C handler first result replaces failure and no result is nil" {
    for ([_]runtime.Native{ test_handler_message, none }) |handler| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        try state.push(.fromFunction(.{ .native = bare }));
        var diagnostic: ?vm.Diagnostic = null;
        try equal(runtime.FailureKind.runtime_error, (try transport.callWithHandler(&state, 0, true, .fromFunction(.{ .native = handler }), &diagnostic)).failure);
        if (handler == none) try expect(state.get(1).?.is(.nil)) else try std.testing.expectEqualStrings("handled", state.get(1).?.unpack().string.bytes);
    }
    var state = try runtime.State.init(a);
    defer state.deinit();
    const handler_chunk = try prepare(&state, "return function(value) return 8,9 end");
    var diagnostic: ?vm.Diagnostic = null;
    _ = try vm.run(&state, handler_chunk, &diagnostic);
    const handler = state.get(-1).?;
    try pushTarget(&state, "return 1+nil");
    try equal(runtime.FailureKind.type_error, (try transport.callWithHandler(&state, 0, true, handler, &diagnostic)).failure);
    try expect(state.get(-1).?.equal(.from(.{ .number = 8 })));
}

var nested_protected: bool = false;
fn nestedFail(state: *runtime.State) callconv(.c) c_int {
    calls += 1;
    const callback = state.globals.getString("bad");
    state.push(callback) catch return -1;
    var diagnostic: ?vm.Diagnostic = null;
    _ = transport.call(state, 0, nested_protected, &diagnostic) catch return -1;
    return api.nilu_error(state);
}
test "failure_handling failed handlers run once even after an inner call catches and resets failure state" {
    for ([_]runtime.Native{ fail, nestedFail }) |handler| {
        for ([_]bool{ false, true }) |protected| {
            var state = try runtime.State.init(a);
            defer state.deinit();
            nested_protected = protected;
            calls = 0;
            state.barrier(&state.globals.header);
            try state.globals.set(a, .from(.{ .string = try state.newString("bad") }), .fromFunction(.{ .native = bare }));
            try pushTarget(&state, "return 1+nil");
            var diagnostic: ?vm.Diagnostic = null;
            try equal(runtime.FailureKind.runtime_error, (try transport.callWithHandler(&state, 0, true, .fromFunction(.{ .native = handler }), &diagnostic)).failure);
            try equal(@as(usize, 1), calls);
            try expect(state.get(-1).?.unpack().string == state.handling_failure);
            try expect(state.failure == null);
            try expect(state.execution == null);
        }
    }
}

fn stop(_: *runtime.State) callconv(.c) c_int {
    return 1;
}
test "failure_handling interruptions skip the registered handler" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    calls = 0;
    try pushTarget(&state, "while true do end");
    state.setHook(stop, 1);
    var diagnostic: ?vm.Diagnostic = null;
    try equal(runtime.FailureKind.interrupted, (try transport.callWithHandler(&state, 0, true, .fromFunction(.{ .native = none }), &diagnostic)).failure);
    try equal(@as(usize, 0), calls);
    try expect(state.get(-1).?.is(.nil));
}

var ran: bool = false;
fn successful(_: *runtime.State) callconv(.c) c_int {
    ran = true;
    return 0;
}
test "failure_handling checks handler before target execution and leaves successful calls alone" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try state.push(.fromFunction(.{ .native = successful }));
    ran = false;
    var diagnostic: ?vm.Diagnostic = null;
    try std.testing.expectError(error.Type, transport.callWithHandler(&state, 0, true, .from(.{ .number = 7 }), &diagnostic));
    try expect(!ran);
    try equal(@as(usize, 1), state.top());
    calls = 0;
    try equal(@as(usize, 0), (try transport.callWithHandler(&state, 0, true, .fromFunction(.{ .native = none }), &diagnostic)).success);
    try expect(ran);
    try equal(@as(usize, 0), calls);
}

fn catchInner(state: *runtime.State) callconv(.c) c_int {
    const bad = state.globals.getString("bad");
    state.push(bad) catch return -1;
    var diagnostic: ?vm.Diagnostic = null;
    const result = transport.call(state, 0, true, &diagnostic) catch return -1;
    if (result != .failure) return -1;
    return 0;
}
test "failure_handling a protected inner failure is invisible to the outer handler" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    calls = 0;
    state.barrier(&state.globals.header);
    try state.globals.set(a, .from(.{ .string = try state.newString("bad") }), .fromFunction(.{ .native = bare }));
    try state.push(.fromFunction(.{ .native = catchInner }));
    var diagnostic: ?vm.Diagnostic = null;
    try equal(@as(usize, 0), (try transport.callWithHandler(&state, 0, true, .fromFunction(.{ .native = none }), &diagnostic)).success);
    try equal(@as(usize, 0), calls);
    try expect(state.failure == null);
}

fn upvalueHandler(state: *runtime.State) callconv(.c) c_int {
    calls += 1;
    state.collect();
    if (api.nilu_getupvalue(state, 1) != .ok) return -1;
    return 1;
}
test "failure_handling handler closure is a root throughout target execution and transformation" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    const handler = try state.newCClosure(upvalueHandler, &.{.from(.{ .string = try state.newString("held") })});
    try pushTarget(&state, "local n=0 while n<100 do local garbage={} n=n+1 end return 1+nil");
    state.setCollectionThreshold(0);
    calls = 0;
    var diagnostic: ?vm.Diagnostic = null;
    try equal(runtime.FailureKind.type_error, (try transport.callWithHandler(&state, 0, true, .fromFunction(handler), &diagnostic)).failure);
    try equal(@as(usize, 1), calls);
    state.collect();
    try std.testing.expectEqualStrings("held", state.get(-1).?.unpack().string.bytes);
}

fn identity(state: *runtime.State) callconv(.c) c_int {
    calls += 1;
    return @intCast(state.top());
}
test "failure_handling core OOM skips the handler and carries the prepared memory value" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try pushTarget(&state, "return 1");
    try runtime.growStack(&state.stack, state.open_cells.items, state.allocator, 256);
    try state.ensureOrigins(256);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 1 });
    const allocator = state.allocator;
    defer state.allocator = allocator;
    state.allocator = failing.allocator();
    calls = 0;
    var diagnostic: ?vm.Diagnostic = null;
    try equal(runtime.FailureKind.out_of_memory, (try transport.callWithHandler(&state, 0, true, .fromFunction(.{ .native = identity }), &diagnostic)).failure);
    try equal(@as(usize, 0), calls);
    try expect(state.get(-1).?.unpack().string == state.memory_failure);
    try expect(state.failure == null);
}

fn pushResult(state: *runtime.State) callconv(.c) c_int {
    if (api.nilu_pushnumber(state, 17) != .ok) return -1;
    return 1;
}
fn allocationCase(allocator: std.mem.Allocator) !void {
    var state = try runtime.State.init(allocator);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    try pushTarget(&state, "local x={} saved=function() return x end return 1+nil");
    state.setCollectionThreshold(0);
    var diagnostic: ?vm.Diagnostic = null;
    const result = transport.callWithHandler(&state, 0, true, .fromFunction(.{ .native = pushResult }), &diagnostic) catch |err| {
        try equal(@as(usize, 2), state.top());
        try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
        try expect(state.get(2).?.isFunction());
        try expect(state.execution == null);
        return err;
    };
    try equal(@as(usize, 2), state.top());
    try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
    try expect(state.originAt(1) == null);
    try expect(state.failure == null);
    try expect(state.execution == null);
    try equal(@as(usize, 0), state.frames.items.len);
    state.collect();
    if (result.failure == .out_of_memory) {
        try expect(state.get(2).?.unpack().string == state.memory_failure);
        return error.OutOfMemory;
    }
    if (result.failure == .runtime_error) {
        try expect(state.get(2).?.unpack().string == state.handling_failure);
        return error.OutOfMemory;
    }
    try equal(runtime.FailureKind.type_error, result.failure);
    try expect(state.get(2).?.equal(.from(.{ .number = 17 })));
}
test "failure_handling all allocation failures restore caller state and free partial handler setup" {
    try allocation_failures.checkAll(a, allocationCase, .{});
}

fn relayInner(state: *runtime.State) callconv(.c) c_int {
    state.push(state.globals.getString("bad")) catch return -1;
    var diagnostic: ?vm.Diagnostic = null;
    _ = transport.call(state, 0, false, &diagnostic) catch return -1;
    return api.nilu_error(state);
}
fn countedResult(state: *runtime.State) callconv(.c) c_int {
    calls += 1;
    return pushResult(state);
}
test "failure_handling an unprotected native relay does not transform the same failure twice" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    state.barrier(&state.globals.header);
    try state.globals.set(a, .from(.{ .string = try state.newString("bad") }), .fromFunction(.{ .closure = try prepare(&state, "return 1+nil") }));
    try state.push(.fromFunction(.{ .native = relayInner }));
    calls = 0;
    var diagnostic: ?vm.Diagnostic = null;
    try equal(runtime.FailureKind.type_error, (try transport.callWithHandler(&state, 0, true, .fromFunction(.{ .native = countedResult }), &diagnostic)).failure);
    try equal(@as(usize, 1), calls);
    try expect(state.get(-1).?.equal(.from(.{ .number = 17 })));
}

test "failure_handling interruption inside the handler remains Interrupted instead of error handling Runtime" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    var diagnostic: ?vm.Diagnostic = null;
    _ = try vm.run(&state, try prepare(&state, "return function() while true do end end"), &diagnostic);
    const handler = state.get(-1).?;
    try state.push(.fromFunction(.{ .native = bare }));
    state.setHook(stop, 1);
    try equal(runtime.FailureKind.interrupted, (try transport.callWithHandler(&state, 0, true, handler, &diagnostic)).failure);
    try expect(state.get(-1).?.is(.nil));
    try equal(runtime.FailureKind.interrupted, state.failure.?.kind);
    try expect(state.execution == null);
    try equal(@as(usize, 0), state.frames.items.len);
}

fn apiMemory(state: *runtime.State) callconv(.c) c_int {
    const saved = state.allocator;
    defer state.allocator = saved;
    var failing = std.testing.FailingAllocator.init(saved, .{ .fail_index = 0 });
    state.allocator = failing.allocator();
    if (api.nilu_pushstring(state, "allocation must fail") != .memory) return 0;
    return -1;
}
fn apiMemoryThenRaise(state: *runtime.State) callconv(.c) c_int {
    _ = apiMemory(state);
    return api.nilu_error(state);
}
fn apiMemoryThenSuccess(state: *runtime.State) callconv(.c) c_int {
    _ = apiMemory(state);
    return 0;
}
fn apiMemoryThenNested(state: *runtime.State) callconv(.c) c_int {
    _ = apiMemory(state);
    var diagnostic: ?vm.Diagnostic = null;
    _ = vm.runFunctionWithArguments(state, .{ .native = apiMemoryThenSuccess }, 0, &diagnostic) catch return -1;
    return -1;
}
fn bareFailure(_: *runtime.State) callconv(.c) c_int {
    return -1;
}
test "failure_handling API Memory bare failure skips handler but explicit raise runs it" {
    for ([_]runtime.Native{ apiMemory, apiMemoryThenNested, apiMemoryThenRaise }) |callback| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        try state.push(.fromFunction(.{ .native = callback }));
        try state.push(.from(.{ .string = try state.newString("own failure") }));
        calls = 0;
        var diagnostic: ?vm.Diagnostic = null;
        const result = try transport.callWithHandler(&state, 1, true, .fromFunction(.{ .native = identity }), &diagnostic);
        const explicit = callback == apiMemoryThenRaise;
        try equal(if (explicit) runtime.FailureKind.runtime_error else .out_of_memory, result.failure);
        try equal(@as(usize, if (explicit) 1 else 0), calls);
        try std.testing.expectEqualStrings(if (explicit) "own failure" else "not enough memory", state.get(-1).?.unpack().string.bytes);
    }
}
test "failure_handling API Memory status does not escape a completed callback" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    var diagnostic: ?vm.Diagnostic = null;
    _ = try vm.runFunctionWithArguments(&state, .{ .native = apiMemoryThenSuccess }, 0, &diagnostic);
    try state.push(.fromFunction(.{ .native = bareFailure }));
    const result = try transport.call(&state, 0, true, &diagnostic);
    try equal(runtime.FailureKind.runtime_error, result.failure);
    try expect(state.get(-1).?.is(.nil));
}

extern fn test_native_invalid_negative(*runtime.State) callconv(.c) c_int;
extern fn test_native_overcount(*runtime.State) callconv(.c) c_int;

test "failure_handling invalid native results bypass protected capture and handlers" {
    for ([_]runtime.Native{ test_native_invalid_negative, test_native_overcount }) |callback| {
        for ([_]?usize{ null, 0, 2 }) |requested| {
            var state = try runtime.State.init(a);
            defer state.deinit();
            try state.push(.from(.{ .number = 42 }));
            try state.push(.fromFunction(.{ .native = callback }));
            calls = 0;
            var diagnostic: ?vm.Diagnostic = null;
            try std.testing.expectError(error.InvalidNativeResult, transport.callAdjusted(&state, 0, requested, true, .fromFunction(.{ .native = identity }), &diagnostic));
            try equal(@as(usize, 0), calls);
            try equal(@as(usize, 1), state.top());
            try equal(@as(f64, 42), state.get(1).?.numberValue().?);
            try equal(@as(usize, 0), state.frames.items.len);
            try expect(state.execution == null);
            try expect(state.originAt(0) == null);
        }
    }
}

test "failure_handling invalid handler result is host misuse rather than error in error handling" {
    for ([_]runtime.Native{ test_native_invalid_negative, test_native_overcount }) |callback| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        try state.push(.from(.{ .number = 42 }));
        try pushTarget(&state, "return 1+nil");
        var diagnostic: ?vm.Diagnostic = null;
        try std.testing.expectError(error.InvalidNativeResult, transport.callWithHandler(&state, 0, true, .fromFunction(.{ .native = callback }), &diagnostic));
        try equal(runtime.FailureKind.invalid_native_result, state.failure.?.kind);
        try equal(@as(usize, 1), state.top());
        try equal(@as(f64, 42), state.get(1).?.numberValue().?);
        try equal(@as(usize, 0), state.frames.items.len);
        try expect(state.execution == null);
    }
}
