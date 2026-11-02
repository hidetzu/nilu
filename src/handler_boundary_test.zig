const std = @import("std");
const allocation_failures = @import("allocation_failures.zig");
const runtime = @import("runtime.zig");
const loader = @import("loader.zig");
const vm = @import("vm.zig");
const transport = @import("failure_transport.zig");
const a = std.testing.allocator;
const equal = std.testing.expectEqual;
const expect = std.testing.expect;

fn script(state: *runtime.State, source: []const u8) !runtime.Value {
    var diagnostic: ?loader.Diagnostic = null;
    return .fromFunction(.{ .closure = try loader.prepare(state, source, "=boundary", &diagnostic) });
}
var calls: usize = 0;
var depth: usize = 0;
fn handler(state: *runtime.State) callconv(.c) c_int {
    calls += 1;
    depth = state.frames.items.len;
    state.collect();
    return 0;
}
fn fail(_: *runtime.State) callconv(.c) c_int {
    calls += 1;
    return -1;
}
fn clean(state: *runtime.State) !void {
    try equal(@as(usize, 0), state.frames.items.len);
    try equal(@as(usize, 0), state.call_location_depth);
    try expect(state.execution == null and state.failure == null);
    try equal(@as(usize, 2), state.top());
    try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
    try expect(state.originAt(1) == null);
}

// Owner-approved B+D policy: ordinary 200, shared handler 220.
test "handler_boundary approved depth margin for script native and C closure handlers" {
    for ([_]usize{ 198, 199, 200 }) |target_depth| {
        for (0..3) |kind| {
            var state = try runtime.State.init(a);
            defer state.deinit();
            const h = switch (kind) {
                0 => runtime.Value.fromFunction(.{ .native = handler }),
                1 => runtime.Value.fromFunction(try state.newCClosure(handler, &.{.from(.{ .number = 7 })})),
                else => try script(&state, "seen=1 return 8"),
            };
            // Root chunk + f(n)..f(0) = n+2 live script frames. The call is
            // deliberately not a tail call so that the boundary is reached.
            const source = try std.fmt.allocPrint(a, "local function f(n) if n==0 then return 1+nil end local x=f(n-1) return x end local x=f({d}) return x", .{target_depth - 2});
            defer a.free(source);
            try state.push(.from(.{ .number = 42 }));
            try state.push(try script(&state, source));
            calls = 0;
            depth = 0;
            var diagnostic: ?vm.Diagnostic = null;
            const result = try transport.callWithHandler(&state, 0, true, h, &diagnostic);
            try equal(runtime.FailureKind.type_error, result.failure);
            if (kind == 2) {
                try expect(state.globals.getString("seen").equal(.from(.{ .number = 1 })));
                try expect(state.get(-1).?.equal(.from(.{ .number = 8 })));
            } else {
                try equal(@as(usize, 1), calls);
                try equal(target_depth + 1, depth);
                try expect(state.get(-1).?.is(.nil));
            }
            try clean(&state);
            // A later failure must still run a handler: no leaked running guard.
            try state.setTop(1);
            try state.push(try script(&state, "return 1+nil"));
            calls = 0;
            try equal(runtime.FailureKind.type_error, (try transport.callWithHandler(&state, 0, true, .fromFunction(.{ .native = handler }), &diagnostic)).failure);
            try equal(@as(usize, 1), calls);
            try clean(&state);
        }
    }
}

test "handler_boundary call-depth refusal retains its kind unless the handler fails" {
    for (0..3) |mode| {
        const with_handler = mode != 0;
        var state = try runtime.State.init(a);
        defer state.deinit();
        try state.push(.from(.{ .number = 42 }));
        try state.push(try script(&state, "local function f() local x=f() return x end local x=f() return x"));
        calls = 0;
        var diagnostic: ?vm.Diagnostic = null;
        const result = try transport.callWithHandler(&state, 0, true, if (with_handler) .fromFunction(.{ .native = if (mode == 2) fail else handler }) else null, &diagnostic);
        try equal(if (mode == 2) runtime.FailureKind.runtime_error else .call_depth, result.failure);
        try equal(@as(usize, if (with_handler) 1 else 0), calls);
        if (mode == 1) try expect(state.get(-1).?.is(.nil));
        if (mode == 2) try expect(state.get(-1).?.unpack().string == state.handling_failure);
        try clean(&state);
    }
}

test "handler_boundary handler failure changes Type and Runtime originals to Runtime" {
    for ([_]bool{ false, true }) |type_original| {
        for ([_]bool{ false, true }) |script_failure| {
            var state = try runtime.State.init(a);
            defer state.deinit();
            const h = if (script_failure) try script(&state, "return 1+nil") else runtime.Value.fromFunction(.{ .native = fail });
            try state.push(.from(.{ .number = 42 }));
            try state.push(if (type_original) try script(&state, "return 1+nil") else .fromFunction(.{ .native = fail }));
            calls = 0;
            var diagnostic: ?vm.Diagnostic = null;
            try equal(runtime.FailureKind.runtime_error, (try transport.callWithHandler(&state, 0, true, h, &diagnostic)).failure);
            try expect(state.get(-1).?.unpack().string == state.handling_failure);
            try clean(&state);
        }
    }
}

const api = @import("c_api.zig");
fn deepSource(state: *runtime.State) !runtime.Value {
    return script(state, "local function f(n) if n==0 then return 1+nil end local x=f(n-1) return x end local x=f(198) return x");
}
fn install(state: *runtime.State, name: []const u8, value: runtime.Value) !void {
    state.barrier(&state.globals.header);
    try state.globals.set(a, .from(.{ .string = try state.newString(name) }), value);
}

test "handler_boundary shared 220 allows final script native and native-tail frames but refuses 221" {
    for ([_]bool{ false, true }) |tail_native| {
        for ([_]usize{ 17, 18 }) |n| {
            var state = try runtime.State.init(a);
            defer state.deinit();
            try install(&state, "probe", .fromFunction(.{ .native = handler }));
            const source = try std.fmt.allocPrint(a, "local function f(n) if n==0 then {s} end local x=f(n-1) return x end local x=f({d}) return x", .{ if (tail_native) "return probe()" else "local x=probe() return x", n });
            defer a.free(source);
            var load_diagnostic: ?loader.Diagnostic = null;
            const h: runtime.Value = .fromFunction(.{ .closure = try loader.prepare(&state, source, "=handler-room", &load_diagnostic) });
            try state.push(.from(.{ .number = 42 }));
            try state.push(try deepSource(&state));
            calls = 0;
            depth = 0;
            var diagnostic: ?vm.Diagnostic = null;
            const result = try transport.callWithHandler(&state, 0, true, h, &diagnostic);
            if (n == 17) {
                try equal(runtime.FailureKind.type_error, result.failure);
                try equal(@as(usize, 220), depth);
                try equal(@as(usize, 1), calls);
            } else {
                try equal(runtime.FailureKind.runtime_error, result.failure);
                try equal(@as(usize, 0), calls);
                try expect(state.get(-1).?.unpack().string == state.handling_failure);
            }
            var location: api.ErrorLocation = undefined;
            const original_name = api.nilu_where(&state, 0, &location).?;
            try std.testing.expectEqualStrings("boundary", std.mem.span(original_name));
            try equal(@as(c_int, 1), location.line);
            state.collect();
            try std.testing.expectEqualStrings("boundary", std.mem.span(original_name));
            try equal(@as(usize, 200), state.callLimit());
            try clean(&state);
        }
    }
}

test "handler_boundary script tail replacements reuse room and preserve closed captures" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try install(&state, "probe", .fromFunction(.{ .native = handler }));
    const h = try script(&state, "local function f(n) if n==0 then local x=7 saved=function() return x end return probe() end return f(n-1) end return f(1000)");
    try state.push(.from(.{ .number = 42 }));
    try state.push(try deepSource(&state));
    calls = 0;
    depth = 0;
    var diagnostic: ?vm.Diagnostic = null;
    try equal(runtime.FailureKind.type_error, (try transport.callWithHandler(&state, 0, true, h, &diagnostic)).failure);
    try equal(@as(usize, 202), depth);
    try equal(@as(usize, 1), calls);
    try clean(&state);
    state.collect();
    const saved = state.globals.getString("saved").unpack().closure;
    try expect(saved.upvalues[0].storage == .closed);
    _ = try vm.run(&state, saved, &diagnostic);
    try expect(state.get(-1).?.equal(.from(.{ .number = 7 })));
}

var room_max: usize = 0;
var refused: usize = 0;
var room_ok: bool = false;
fn forbidden(_: *runtime.State) callconv(.c) c_int {
    refused += 1;
    return 0;
}
fn room(state: *runtime.State) callconv(.c) c_int {
    room_max = @max(room_max, state.frames.items.len);
    if (state.callLimit() != 220) return -1;
    if (state.frames.items.len < 220) {
        const self = state.frames.getLast().function;
        state.push(.fromFunction(self)) catch return -1;
        var diagnostic: ?vm.Diagnostic = null;
        const result = transport.call(state, 0, true, &diagnostic) catch return -1;
        if (result != .success) return -1;
        return 0;
    }
    if (state.call_location_depth != 220) return -1;
    const top = state.top();
    // A fresh protected boundary and its handler cannot renew the shared room.
    // Repeat after capture to prove that the attempted renewal is not one-shot.
    for (0..2) |_| {
        for ([_]bool{ false, true }) |with_handler| {
            state.push(.fromFunction(.{ .native = forbidden })) catch return -1;
            var diagnostic: ?vm.Diagnostic = null;
            const result = transport.callWithHandler(state, 0, true, if (with_handler) .fromFunction(.{ .native = forbidden }) else null, &diagnostic) catch return -1;
            if (result != .failure or result.failure != (if (with_handler) runtime.FailureKind.runtime_error else .call_depth)) return -1;
            if (with_handler and state.get(-1).?.unpack().string != state.handling_failure) return -1;
            state.setTop(@intCast(top)) catch return -1;
            if (state.frames.items.len != 220 or state.callLimit() != 220) return -1;
        }
    }
    var location: api.ErrorLocation = undefined;
    const name = api.nilu_where(state, 1, &location) orelse return -1;
    if (!std.mem.eql(u8, std.mem.span(name), "[C]")) return -1;
    state.collect();
    room_ok = true;
    return 0;
}
fn deepNative(state: *runtime.State) callconv(.c) c_int {
    state.push(.fromFunction(.{ .native = deepNative })) catch return -1;
    var diagnostic: ?vm.Diagnostic = null;
    const result = transport.call(state, 0, false, &diagnostic) catch return -1;
    if (result == .failure) return api.nilu_error(state);
    return 0;
}
test "handler_boundary native transport reentry and inner handlers share room and snapshot capacity" {
    for ([_]bool{ false, true }) |closure| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        const h: runtime.Value = .fromFunction(if (closure) try state.newCClosure(room, &.{.from(.{ .number = 7 })}) else .{ .native = room });
        try state.push(.from(.{ .number = 42 }));
        try state.push(.fromFunction(.{ .native = deepNative }));
        room_max = 0;
        room_ok = false;
        refused = 0;
        var diagnostic: ?vm.Diagnostic = null;
        try equal(runtime.FailureKind.call_depth, (try transport.callWithHandler(&state, 0, true, h, &diagnostic)).failure);
        try expect(room_ok);
        try equal(@as(usize, 220), room_max);
        try equal(@as(usize, 0), refused);
        try clean(&state);
        try equal(@as(usize, 200), state.callLimit());
        try state.setTop(1);
        try state.push(.fromFunction(.{ .native = deepNative }));
        try equal(runtime.FailureKind.call_depth, (try transport.call(&state, 0, true, &diagnostic)).failure);
        try clean(&state);
    }
}

fn stop(_: *runtime.State) callconv(.c) c_int {
    return 1;
}
var interrupt_room: bool = false;
fn failRoom(state: *runtime.State) callconv(.c) c_int {
    depth = state.frames.items.len;
    if (interrupt_room) {
        state.setHook(stop, 1);
        return 0;
    }
    var failing = std.testing.FailingAllocator.init(state.allocator, .{ .fail_index = 0 });
    const allocator = state.allocator;
    state.allocator = failing.allocator();
    const status = api.nilu_pushstring(state, "allocation during handler room");
    state.allocator = allocator;
    if (status != .memory) return -2;
    return -1;
}
test "handler_boundary OOM and interruption at the final frame restore the ordinary ceiling" {
    for ([_]bool{ false, true }) |interrupted| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        try install(&state, "force", .fromFunction(.{ .native = failRoom }));
        const h = try script(&state, "local function f(n) if n==0 then local x=force() return x end local x=f(n-1) return x end local x=f(17) return x");
        try state.push(.from(.{ .number = 42 }));
        try state.push(try deepSource(&state));
        interrupt_room = interrupted;
        depth = 0;
        var diagnostic: ?vm.Diagnostic = null;
        try equal(if (interrupted) runtime.FailureKind.interrupted else .runtime_error, (try transport.callWithHandler(&state, 0, true, h, &diagnostic)).failure);
        try equal(@as(usize, 220), depth);
        if (interrupted) {
            try expect(state.get(-1).?.is(.nil));
            try equal(runtime.FailureKind.interrupted, state.failure.?.kind);
            state.setHook(null, 0);
            // Interruption stays active until a subsequent successful entry.
            try state.setTop(1);
            try state.push(try script(&state, "return 1"));
            _ = try transport.call(&state, 0, true, &diagnostic);
        } else try expect(state.get(-1).?.unpack().string == state.handling_failure);
        try equal(@as(usize, 200), state.callLimit());
        try clean(&state);
    }
}

test "handler_boundary Stack originals and handler Stack failure preserve the selected status and location" {
    for ([_]bool{ false, true }) |failed_handler| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        const position = @import("Token.zig").Position{ .offset = 0, .line = 7, .column = 1 };
        const code = [_]@import("bytecode.zig").Written{.{ .position = position, .operation = .{ .returns = .{ .first = 0, .count = 0 } } }};
        const too_large: runtime.Value = .fromFunction(.{ .closure = try state.newChunk(try state.newProgram(&.{}, &code, runtime.State.max_stack, "", "=stack-original")) });
        const h: runtime.Value = if (failed_handler) too_large else .fromFunction(.{ .native = handler });
        try state.push(.from(.{ .number = 42 }));
        try state.push(too_large);
        var diagnostic: ?vm.Diagnostic = null;
        try equal(if (failed_handler) runtime.FailureKind.runtime_error else .stack_limit, (try transport.callWithHandler(&state, 0, true, h, &diagnostic)).failure);
        if (failed_handler) try expect(state.get(-1).?.unpack().string == state.handling_failure);
        var location: api.ErrorLocation = undefined;
        try std.testing.expectEqualStrings("stack-original", std.mem.span(api.nilu_where(&state, 0, &location).?));
        try equal(@as(c_int, 7), location.line);
        try clean(&state);
    }
}

var other_ok: bool = false;
fn otherState(state: *runtime.State) callconv(.c) c_int {
    if (state.callLimit() != 220) return -1;
    var other = runtime.State.init(a) catch return -1;
    defer other.deinit();
    other.push(.fromFunction(.{ .native = deepNative })) catch return -1;
    var diagnostic: ?vm.Diagnostic = null;
    const result = transport.call(&other, 0, true, &diagnostic) catch return -1;
    other_ok = result == .failure and result.failure == .call_depth and other.callLimit() == 200 and state.callLimit() == 220;
    return 0;
}
test "handler_boundary room is state-local and initialization reserves all handler frames and snapshots" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try expect(state.frames.capacity >= 220);
    try equal(@as(usize, 221), state.call_locations.items.len);
    try state.push(.from(.{ .number = 42 }));
    try state.push(try deepSource(&state));
    other_ok = false;
    var diagnostic: ?vm.Diagnostic = null;
    try equal(runtime.FailureKind.type_error, (try transport.callWithHandler(&state, 0, true, .fromFunction(.{ .native = otherState }), &diagnostic)).failure);
    try expect(other_ok);
    try clean(&state);
}

fn allocationRoomCase(allocator: std.mem.Allocator) !void {
    var state = try runtime.State.init(allocator);
    defer state.deinit();
    const h = try script(&state, "local function f(n) if n==0 then return 'handled' end local x=f(n-1) return x end local x=f(18) return x");
    try state.push(.from(.{ .number = 42 }));
    try state.push(try deepSource(&state));
    state.setCollectionThreshold(0);
    var diagnostic: ?vm.Diagnostic = null;
    const result = transport.callWithHandler(&state, 0, true, h, &diagnostic) catch |err| {
        try clean(&state);
        try equal(@as(usize, 200), state.callLimit());
        return err;
    };
    try clean(&state);
    try equal(@as(usize, 200), state.callLimit());
    switch (result.failure) {
        .out_of_memory => return error.OutOfMemory,
        .runtime_error => {
            try expect(state.get(-1).?.unpack().string == state.handling_failure);
            return error.OutOfMemory;
        },
        .type_error => try std.testing.expectEqualStrings("handled", state.get(-1).?.unpack().string.bytes),
        else => return error.UnexpectedFailure,
    }
}
test "handler_boundary every allocation failure through the final handler frame cleans up" {
    try allocation_failures.checkAll(a, allocationRoomCase, .{});
}
