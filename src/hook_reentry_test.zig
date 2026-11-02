//! A hook callback may run the same state's VM again, and
//! the inner instructions are observed too. Case IDs HC01-HC36 name the cases.
//! Every test is confirmed: either the C option itself requires the result, or
//! the owner chose the current answer on 2026-10-30 (counting shared by the
//! state, the callback's return decides after an inner interruption, the
//! ordinary call limit alone bounds reentry, registration changes apply to the
//! whole state at once).
const std = @import("std");
const allocation_failures = @import("allocation_failures.zig");
const runtime = @import("runtime.zig");
const api = @import("c_api.zig");
const vm = @import("vm.zig");
const transport = @import("failure_transport.zig");
const bytecode = @import("bytecode.zig");
const loader = @import("loader.zig");
const a = std.testing.allocator;
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
const State = runtime.State;
const Value = runtime.Value;

const Event = struct { kind: enum { enter, leave }, depth: usize, line: usize, top: usize, frames: usize, actor: u8 };
var events: [128]Event = undefined;
var event_count: usize = 0;

fn currentLine(state: *const State) usize {
    const frame = state.frames.getLastOrNull() orelse return 0;
    const position = frame.position() orelse return 0;
    return position.line;
}
fn record(state: *State, kind: @FieldType(Event, "kind"), actor: u8) void {
    if (event_count == events.len) return;
    events[event_count] = .{ .kind = kind, .depth = state.hook_depth, .line = currentLine(state), .top = state.top(), .frames = state.frames.items.len, .actor = actor };
    event_count += 1;
}
fn entries(depth: usize) usize {
    var count: usize = 0;
    for (events[0..event_count]) |event| {
        if (event.kind == .enter and event.depth == depth) count += 1;
    }
    return count;
}
/// The callback lines in order, every depth together, as `depth*1000 + line`.
fn expectTrace(wanted: []const usize) !void {
    var seen: usize = 0;
    for (events[0..event_count]) |event| {
        if (event.kind != .enter) continue;
        if (seen == wanted.len) return error.TestUnexpectedResult;
        try equal(wanted[seen], event.depth * 1000 + event.line);
        seen += 1;
    }
    try equal(wanted.len, seen);
}
fn printTrace(label: []const u8) void {
    std.debug.print("hook reentry {s}: depth/line/top/frames/actor =", .{label});
    for (events[0..event_count]) |event| {
        if (event.kind == .enter) std.debug.print(" {d}/{d}/{d}/{d}/{d}", .{ event.depth, event.line, event.top, event.frames, event.actor });
    }
    std.debug.print("\n", .{});
}

const Case = enum { hc01, hc02, hc03, hc04, hc05, hc06, hc07, hc08, hc09, hc10, hc11, hc12, hc13, hc14, hc15, hc16, hc20, hc21, hc22, hc23, hc24, hc25, hc26, hc27, hc28, hc29, hc30, hc31, hc33, hc34, hc36 };
const Public = enum { call, pcall_positive_handler, pcall_negative_handler, pcall_all, pcall_type, pcall_interrupt };
const Plan = struct {
    case: Case = .hc01,
    inner: ?*runtime.Closure = null,
    second: ?*runtime.Closure = null,
    handler_script: ?*runtime.Closure = null,
    callable: Value = .nil,
    answer_inner: c_int = 0,
    answer_outer: c_int = 0,
    protected: bool = false,
    requested: ?usize = null,
    max_depth: usize = 1,
    public: Public = .call,
    other: ?*State = null,
    origin: ?*State = null,
    failing: ?*std.testing.FailingAllocator = null,
    calls: [256]usize = @splat(0),
    // Observations the callbacks leave behind.
    value: Value = .nil,
    second_value: Value = .nil,
    result: ?transport.Result = null,
    caught: ?vm.Error = null,
    status: ?api.Status = null,
    failure_kind: ?runtime.FailureKind = null,
    message: [96]u8 = undefined,
    message_len: usize = 0,
    ok: bool = false,
    ok2: bool = false,
    handler_calls: usize = 0,
    handler_frames: usize = 0,
    handler_limit: usize = 0,
    native_calls: usize = 0,
    other_calls: usize = 0,
    executions: usize = 0,
    refused: bool = false,
    refusal_depth: usize = 0,
    refusal_frames: usize = 0,
    remaining_before: c_uint = 0,
    remaining_after: c_uint = 0,
    relocated: bool = false,
    objects_during: usize = 0,
    cell: ?*runtime.Cell = null,
    cell_open_after: bool = false,
    top_after: usize = 0,
    window: [6]Value = @splat(Value.nil),
    window_len: usize = 0,
};
var plan: Plan = .{};

fn keepMessage(value: Value) void {
    plan.message_len = 0;
    if (!value.is(.string)) return;
    const bytes = value.unpack().string.bytes;
    plan.message_len = @min(bytes.len, plan.message.len);
    @memcpy(plan.message[0..plan.message_len], bytes[0..plan.message_len]);
}
fn message() []const u8 {
    return plan.message[0..plan.message_len];
}
fn isString(value: ?Value, text: []const u8) bool {
    const present = value orelse return false;
    return present.is(.string) and std.mem.eql(u8, present.unpack().string.bytes, text);
}
fn isNumber(value: ?Value, number: f64) bool {
    const present = value orelse return false;
    return present.equal(.from(.{ .number = number }));
}

// Natives a callback may run. Each records only what its case asserts.
fn echo(state: *State) callconv(.c) c_int {
    plan.native_calls += 1;
    if (state.top() != 1 or !isNumber(state.get(1), 8)) return 0;
    return 1;
}
fn noop(_: *State) callconv(.c) c_int {
    plan.native_calls += 1;
    return 0;
}
fn handler(_: *State) callconv(.c) c_int {
    plan.handler_calls += 1;
    return 0;
}
fn wrapper(state: *State) callconv(.c) c_int {
    plan.native_calls += 1;
    plan.ok = state.top() == 1 and isNumber(state.get(1), 5);
    var diagnostic: ?vm.Diagnostic = null;
    _ = vm.run(state, plan.inner.?, &diagnostic) catch return 0;
    return 1;
}
fn cClosure(state: *State) callconv(.c) c_int {
    plan.native_calls += 1;
    var ok = api.nilu_getupvalue(state, 1) == .ok and isNumber(state.get(-1), 13);
    _ = api.nilu_settop(state, -2);
    ok = ok and state.top() == 1 and isNumber(state.get(1), 8);
    var diagnostic: ?vm.Diagnostic = null;
    _ = vm.run(state, plan.inner.?, &diagnostic) catch return 0;
    ok = ok and api.nilu_getupvalue(state, 1) == .ok and isNumber(state.get(-1), 13);
    _ = api.nilu_settop(state, -2);
    plan.ok = ok;
    return 1;
}
fn preUnwindHandler(state: *State) callconv(.c) c_int {
    plan.handler_calls += 1;
    plan.handler_frames = state.frames.items.len;
    if (api.nilu_pushstring(state, "handled") != .ok) return 0;
    return 1;
}
fn relayWrapper(state: *State) callconv(.c) c_int {
    plan.native_calls += 1;
    state.push(.fromFunction(.{ .closure = plan.inner.? })) catch return 0;
    plan.status = api.nilu_call(state, 0, 0);
    if (plan.status.? == .ok) return 0;
    return api.nilu_error(state);
}
fn marginHandler(state: *State) callconv(.c) c_int {
    plan.handler_calls += 1;
    plan.handler_limit = state.callLimit();
    var diagnostic: ?vm.Diagnostic = null;
    _ = vm.run(state, plan.second.?, &diagnostic) catch return 0;
    plan.second_value = state.get(-1) orelse runtime.Value.nil;
    if (api.nilu_pushstring(state, "handled") != .ok) return 0;
    return 1;
}
fn counter(_: *State) callconv(.c) c_int {
    plan.other_calls += 1;
    return 0;
}
// State B's hook for HC34: its first callback runs state A's script I while A
// is itself inside a callback.
fn crossObserver(state: *State) callconv(.c) c_int {
    plan.other_calls += 1;
    if (plan.other_calls != 1) return 0;
    var diagnostic: ?vm.Diagnostic = null;
    plan.ok = state.hook_depth == 1 and plan.origin.?.hook_depth == 1;
    _ = vm.run(plan.origin.?, plan.inner.?, &diagnostic) catch |err| {
        plan.caught = err;
        return 1;
    };
    plan.second_value = plan.origin.?.get(-1) orelse runtime.Value.nil;
    return 0;
}

fn runInner(state: *State, closure: *runtime.Closure) void {
    var diagnostic: ?vm.Diagnostic = null;
    _ = vm.run(state, closure, &diagnostic) catch |err| {
        plan.caught = err;
        if (state.failure) |record_| {
            plan.failure_kind = record_.kind;
            keepMessage(record_.value);
        }
        return;
    };
    plan.value = state.get(-1) orelse runtime.Value.nil;
}
fn protectedInner(state: *State, closure: *runtime.Closure, with_handler: ?runtime.Function) void {
    state.push(.fromFunction(.{ .closure = closure })) catch {
        plan.status = .stack;
        return;
    };
    var diagnostic: ?vm.Diagnostic = null;
    plan.result = transport.callWithHandler(state, 0, true, if (with_handler) |function| .fromFunction(function) else null, &diagnostic) catch |err| {
        plan.caught = err;
        return;
    };
    plan.value = state.get(-1) orelse runtime.Value.nil;
    // A protected entry clears the record; the caught value is the top slot.
    if (plan.result.? == .failure) {
        plan.failure_kind = plan.result.?.failure;
        keepMessage(plan.value);
    }
}

fn observer(state: *State) callconv(.c) c_int {
    return observe(state, 1);
}
fn replacement(state: *State) callconv(.c) c_int {
    return observe(state, 2);
}
fn observe(state: *State, actor: u8) c_int {
    record(state, .enter, actor);
    const depth = state.hook_depth;
    const slot = @min(depth, plan.calls.len - 1);
    plan.calls[slot] += 1;
    const answer = act(state, depth, plan.calls[slot] == 1);
    record(state, .leave, actor);
    return answer;
}
fn answerFor(depth: usize) c_int {
    return if (depth >= 2) plan.answer_inner else plan.answer_outer;
}
fn act(state: *State, depth: usize, first: bool) c_int {
    const outer_first = depth == 1 and first;
    const inner_first = depth == 2 and first;
    switch (plan.case) {
        .hc01, .hc15, .hc16 => if (outer_first) runInner(state, plan.inner.?),
        .hc28 => if (outer_first) {
            runInner(state, plan.inner.?);
        } else if (inner_first) {
            state.setHook(replacement, 3);
        },
        .hc31 => {
            if (outer_first) runInner(state, plan.inner.?);
            // Only a caught memory failure makes the outer answer nonzero.
            return if (plan.caught != null) plan.answer_outer else 0;
        },
        .hc02 => if (outer_first) {
            plan.remaining_before = state.hook_remaining;
            state.push(.from(.{ .number = 8 })) catch return 1;
            var diagnostic: ?vm.Diagnostic = null;
            _ = vm.runFunctionWithArguments(state, .{ .native = echo }, 1, &diagnostic) catch |err| {
                plan.caught = err;
                return 1;
            };
            plan.value = state.get(-1) orelse runtime.Value.nil;
            plan.remaining_after = state.hook_remaining;
        },
        .hc03 => if (outer_first) {
            state.push(.from(.{ .number = 5 })) catch return 1;
            var diagnostic: ?vm.Diagnostic = null;
            _ = vm.runFunctionWithArguments(state, .{ .native = wrapper }, 1, &diagnostic) catch |err| {
                plan.caught = err;
                return 1;
            };
            plan.value = state.get(-1) orelse runtime.Value.nil;
        },
        .hc04 => if (outer_first) protectedInner(state, plan.inner.?, .{ .native = handler }),
        .hc05 => if (outer_first) {
            state.push(plan.callable) catch return 1;
            state.push(.from(.{ .number = 8 })) catch return 1;
            var diagnostic: ?vm.Diagnostic = null;
            _ = vm.runCallableWithArguments(state, 1, &diagnostic) catch |err| {
                plan.caught = err;
                return 1;
            };
            plan.value = state.get(-1) orelse runtime.Value.nil;
        },
        .hc06 => if (outer_first) {
            if (api.nilu_pushnumber(state, 13) != .ok or api.nilu_pushcclosure(state, cClosure, 1) != .ok or api.nilu_pushnumber(state, 8) != .ok) return 1;
            plan.status = api.nilu_call(state, 1, 1);
            plan.value = state.get(-1) orelse runtime.Value.nil;
        },
        .hc07 => if (outer_first) {
            if (api.nilu_pushstring(state, "outer") != .ok) return 1;
            runInner(state, plan.inner.?);
            plan.ok = isString(state.get(1), "outer");
            plan.top_after = state.top();
        } else if (inner_first) {
            if (api.nilu_pushstring(state, "inner") != .ok) return 1;
        },
        .hc08 => switch (depth) {
            1 => if (first) {
                if (api.nilu_pushstring(state, "A") != .ok) return 1;
                runInner(state, plan.inner.?);
                plan.ok = isString(state.get(1), "A") and state.top() == 2 and isNumber(state.get(2), 9);
            },
            2 => if (first) {
                if (api.nilu_pushstring(state, "B") != .ok) return 1;
                var diagnostic: ?vm.Diagnostic = null;
                _ = vm.run(state, plan.second.?, &diagnostic) catch return 1;
                plan.ok2 = isString(state.get(1), "B") and state.top() == 2 and isNumber(state.get(2), 11);
            },
            else => if (first) {
                if (api.nilu_pushstring(state, "C") != .ok) return 1;
            },
        },
        .hc09 => if (outer_first) {
            if (api.nilu_pushstring(state, "outer") != .ok) return 1;
            const token = state.reserveFailureOrigin() catch return 1;
            state.publishFailureOrigin(token);
            token.record = .{ .kind = .runtime_error, .value = state.get(1).? };
            state.setOrigin(state.base(), token);
            const before = state.stack.items.ptr;
            runInner(state, plan.inner.?);
            plan.relocated = state.stack.items.ptr != before;
            plan.ok = isString(state.get(1), "outer") and state.originAt(state.base()) == token and isNumber(state.get(2), 120);
        },
        .hc10 => if (outer_first) {
            if (api.nilu_pushstring(state, "outer-cell") != .ok) return 1;
            plan.cell = state.capture(state.base()) catch return 1;
            runInner(state, plan.inner.?);
            plan.cell_open_after = plan.cell.?.storage == .open;
        } else if (inner_first) {
            if (api.nilu_pushstring(state, "captured") != .ok) return 1;
            const cell = state.capture(state.base()) catch return 1;
            const prototype = state.newPrototype(&.{}) catch return 1;
            prototype.upvalue_count = 1;
            const closure = state.newClosure(prototype, &.{cell}) catch return 1;
            const key = state.newString("escaped") catch return 1;
            state.barrier(&state.globals.header);
            state.globals.set(state.allocator, .from(.{ .string = key }), .fromFunction(.{ .closure = closure })) catch return 1;
        },
        .hc11 => if (outer_first) {
            state.push(.from(.{ .number = 5 })) catch return 1;
            state.push(.fromFunction(.{ .closure = plan.inner.? })) catch return 1;
            var diagnostic: ?vm.Diagnostic = null;
            plan.result = transport.callAdjusted(state, 0, plan.requested, false, null, &diagnostic) catch |err| {
                plan.caught = err;
                return 1;
            };
            plan.window_len = @min(state.top(), plan.window.len);
            for (0..plan.window_len) |i| plan.window[i] = state.get(@intCast(i + 1)).?;
        },
        .hc12 => if (outer_first) {
            protectedInner(state, plan.inner.?, null);
            plan.ok = state.originAt(state.stack.items.len - 1) == null;
        },
        .hc13 => if (outer_first) protectedInner(state, plan.inner.?, .{ .native = preUnwindHandler }),
        .hc14 => if (outer_first) {
            var diagnostic: ?vm.Diagnostic = null;
            _ = vm.runFunctionWithArguments(state, .{ .native = relayWrapper }, 0, &diagnostic) catch |err| {
                plan.caught = err;
                if (state.failure) |record_| {
                    plan.failure_kind = record_.kind;
                    keepMessage(record_.value);
                    plan.ok = record_.position != null and record_.position.?.line == 1 and record_.location != null;
                }
            };
        },
        .hc20 => if (outer_first) {
            plan.remaining_before = state.hook_remaining;
            for (0..100) |_| {
                var diagnostic: ?vm.Diagnostic = null;
                _ = vm.runFunctionWithArguments(state, .{ .native = noop }, 0, &diagnostic) catch return 1;
            }
            plan.remaining_after = state.hook_remaining;
        },
        .hc21 => if (outer_first) runInner(state, plan.inner.?),
        .hc22 => switch (depth) {
            1 => if (first) runInner(state, plan.inner.?),
            2 => if (first) {
                var diagnostic: ?vm.Diagnostic = null;
                _ = vm.run(state, plan.second.?, &diagnostic) catch return 1;
                plan.second_value = state.get(-1) orelse runtime.Value.nil;
            },
            else => {},
        },
        // HC23 reenters at every callback until the first refusal; HC24 only
        // at the first callback of each depth, so a limit below the refusal
        // depth terminates by itself. Only the ordinary call limit bounds this.
        .hc23, .hc24 => if (!plan.refused and depth <= plan.max_depth and (plan.case == .hc23 or first)) {
            var diagnostic: ?vm.Diagnostic = null;
            _ = vm.run(state, plan.inner.?, &diagnostic) catch |err| {
                plan.refused = true;
                plan.caught = err;
                plan.refusal_depth = depth;
                plan.refusal_frames = state.frames.items.len;
                if (state.failure) |record_| {
                    plan.failure_kind = record_.kind;
                    keepMessage(record_.value);
                }
                return 0;
            };
            plan.executions += 1;
        },
        .hc25 => if (outer_first) {
            protectedInner(state, plan.inner.?, if (plan.handler_script) |script| .{ .closure = script } else .{ .native = marginHandler });
            state.collect();
            plan.ok = isString(state.get(-1), message());
        },
        .hc26 => if (outer_first) {
            state.setHook(null, 0);
            runInner(state, plan.inner.?);
        },
        .hc27 => if (outer_first) {
            runInner(state, plan.inner.?);
        } else if (inner_first) {
            state.setHook(null, 0);
        },
        .hc29 => if (outer_first) {
            runInner(state, plan.inner.?);
        } else if (inner_first) {
            state.setHook(replacement, 2);
            return 1;
        },
        .hc30 => if (outer_first) {
            if (api.nilu_pushstring(state, "kept") != .ok or api.nilu_newtable(state) != .ok or api.nilu_newuserdata(state, 8, null) != .ok or api.nilu_pushcfunction(state, noop) != .ok) return 1;
            runInner(state, plan.inner.?);
            plan.objects_during = state.object_count;
            plan.ok = isString(state.get(1), "kept") and api.nilu_type(state, 2) == 5 and api.nilu_type(state, 3) == 6 and api.nilu_type(state, 4) == 2 and isNumber(state.get(5), 9);
        } else if (inner_first) {
            if (api.nilu_newtable(state) != .ok) return 1;
            state.collect();
        },
        .hc33 => if (outer_first) {
            protectedInner(state, plan.inner.?, null);
            plan.top_after = state.top();
        },
        .hc34 => if (outer_first) {
            var diagnostic: ?vm.Diagnostic = null;
            _ = vm.run(plan.other.?, plan.second.?, &diagnostic) catch |err| {
                plan.caught = err;
                return 1;
            };
            plan.value = plan.other.?.get(-1) orelse runtime.Value.nil;
        },
        .hc36 => if (outer_first) {
            if (api.nilu_pushstring(state, "outer") != .ok) return 1;
            switch (plan.public) {
                .call => {
                    state.push(.fromFunction(.{ .closure = plan.inner.? })) catch return 1;
                    plan.status = api.nilu_call(state, 0, 1);
                },
                .pcall_positive_handler, .pcall_negative_handler => {
                    if (api.nilu_pushcfunction(state, handler) != .ok) return 1;
                    state.push(.fromFunction(.{ .closure = plan.inner.? })) catch return 1;
                    plan.status = api.nilu_pcall(state, 0, 1, if (plan.public == .pcall_positive_handler) 2 else -2);
                },
                .pcall_all => {
                    state.push(.fromFunction(.{ .closure = plan.inner.? })) catch return 1;
                    plan.status = api.nilu_pcall(state, 0, -1, 0);
                },
                .pcall_type, .pcall_interrupt => {
                    state.push(.fromFunction(.{ .closure = plan.inner.? })) catch return 1;
                    plan.status = api.nilu_pcall(state, 0, 1, 0);
                },
            }
            plan.value = state.get(-1) orelse runtime.Value.nil;
            keepMessage(plan.value);
            plan.top_after = state.top();
            plan.ok = isString(state.get(1), "outer");
            plan.window_len = @min(state.top(), plan.window.len);
            for (0..plan.window_len) |i| plan.window[i] = state.get(@intCast(i + 1)).?;
        },
    }
    return answerFor(depth);
}

// Six dispatches with known lines: r0=1, r1=2, r0+=r1, r1=last, r0+=r1, return.
fn synthetic(state: *State, last: f64, first_line: usize, name: []const u8) !*runtime.Closure {
    const operations = [_]bytecode.Instruction.Operation{
        .{ .constant = .{ .destination = 0, .index = 0 } },
        .{ .constant = .{ .destination = 1, .index = 1 } },
        .{ .binary = .{ .operator = .add, .destination = 0, .left = 0, .right = 1 } },
        .{ .constant = .{ .destination = 1, .index = 2 } },
        .{ .binary = .{ .operator = .add, .destination = 0, .left = 0, .right = 1 } },
        .{ .returns = .{ .first = 0, .count = 1 } },
    };
    var code: [operations.len]bytecode.Written = undefined;
    for (operations, &code, 0..) |op, *instruction, i| instruction.* = .{ .operation = op, .position = .{ .offset = 0, .line = @intCast(first_line + i), .column = 1 } };
    return state.newChunk(try state.newProgram(&.{ .from(.{ .number = 1 }), .from(.{ .number = 2 }), .from(.{ .number = last }) }, &code, 2, "", name));
}
fn hold(state: *State, name: []const u8, value: Value) !void {
    state.barrier(&state.globals.header);
    try state.globals.set(state.allocator, .from(.{ .string = try state.newString(name) }), value);
}
fn compileNamed(state: *State, source: []const u8, name: []const u8) !*runtime.Closure {
    var diagnostic: ?loader.Diagnostic = null;
    const chunk = try loader.prepare(state, source, name, &diagnostic);
    try hold(state, name, .fromFunction(.{ .closure = chunk }));
    return chunk;
}
/// Inner script I: result 9, lines 101..106. J: result 11, lines 201..206.
fn innerI(state: *State) !*runtime.Closure {
    const chunk = try synthetic(state, 6, 101, "=I");
    try hold(state, "held_I", .fromFunction(.{ .closure = chunk }));
    return chunk;
}
fn innerJ(state: *State) !*runtime.Closure {
    const chunk = try synthetic(state, 8, 201, "=J");
    try hold(state, "held_J", .fromFunction(.{ .closure = chunk }));
    return chunk;
}
/// Outer script O: result 7, lines 1..6, with the host's 42 below it.
fn begin(state: *State, case: Case) !*runtime.Closure {
    const outer = try synthetic(state, 4, 1, "=O");
    try state.push(.from(.{ .number = 42 }));
    plan = .{ .case = case };
    event_count = 0;
    state.setHook(observer, 1);
    return outer;
}
fn restored(state: *State, top: usize) !void {
    try equal(top, state.top());
    try equal(@as(f64, 42), state.get(1).?.numberValue().?);
    try equal(@as(usize, 0), state.frames.items.len);
    try equal(@as(usize, 0), state.vm_entries);
    try expect(state.hook_depth == 0 and state.hook_window == null);
    try expect(state.execution == null);
}
fn completes(state: *State, outer: *runtime.Closure) !void {
    var diagnostic: ?vm.Diagnostic = null;
    _ = try vm.run(state, outer, &diagnostic);
    try restored(state, 2);
    try equal(@as(f64, 7), state.get(2).?.numberValue().?);
    try expect(state.failure == null);
}

test "hook_reentry HC01 confirmed same-state script reentry runs the target and observes its instructions" {
    var state = try State.init(a);
    defer state.deinit();
    const outer = try begin(&state, .hc01);
    plan.inner = try innerI(&state);
    try completes(&state, outer);
    try expect(plan.caught == null);
    try expect(isNumber(plan.value, 9));
    try expect(entries(2) >= 1);
    try expect(entries(1) == 5);
    printTrace("HC01");
}

test "hook_reentry HC02 confirmed native reentry sees its argument window and adds no instruction callbacks" {
    var state = try State.init(a);
    defer state.deinit();
    const outer = try begin(&state, .hc02);
    try completes(&state, outer);
    try expect(plan.caught == null);
    try equal(@as(usize, 1), plan.native_calls);
    try expect(isNumber(plan.value, 8));
    try equal(plan.remaining_before, plan.remaining_after);
    try expectTrace(&.{ 1002, 1003, 1004, 1005, 1006 });
}

test "hook_reentry HC03 confirmed script entered through a native wrapper is observed with an empty window" {
    var state = try State.init(a);
    defer state.deinit();
    const outer = try begin(&state, .hc03);
    plan.inner = try innerI(&state);
    try completes(&state, outer);
    try expect(plan.caught == null and plan.ok);
    try expect(isNumber(plan.value, 9));
    try expect(entries(2) >= 1);
    var order: usize = 0;
    for (events[0..event_count]) |event| {
        if (event.depth == 2) {
            try equal(@as(usize, 0), event.top);
            try expect(event.frames >= 3);
            // The inner callbacks all happen between the outer's first entry and its leave.
            try equal(@as(usize, 1), order);
        } else if (event.kind == .enter and order == 0) order = 1 else if (event.kind == .leave and order == 1) order = 2;
    }
    try equal(@as(usize, 2), order);
}

test "hook_reentry HC04 confirmed protected reentry succeeds without running the handler" {
    var state = try State.init(a);
    defer state.deinit();
    const outer = try begin(&state, .hc04);
    plan.inner = try innerI(&state);
    try completes(&state, outer);
    try equal(transport.Result{ .success = 1 }, plan.result.?);
    try expect(isNumber(plan.value, 9));
    try equal(@as(usize, 0), plan.handler_calls);
    try expect(entries(2) >= 1);
}

test "hook_reentry HC05 confirmed a callable table with an inherited __call is called with itself first" {
    var state = try State.init(a);
    defer state.deinit();
    const outer = try begin(&state, .hc05);
    state.setHook(null, 0);
    const function = try compileNamed(&state, "return function(self, x) global seen_self = self return x + 1 end", "=call");
    const target = Value.from(.{ .table = try state.newTable() });
    try hold(&state, "held_t", target);
    const meta = try state.newTable();
    try hold(&state, "held_mt", .from(.{ .table = meta }));
    const base = try state.newTable();
    try hold(&state, "held_base", .from(.{ .table = base }));
    const link = try state.newTable();
    try hold(&state, "held_link", .from(.{ .table = link }));
    var diagnostic: ?vm.Diagnostic = null;
    _ = try vm.run(&state, function, &diagnostic);
    state.barrier(&base.header);
    try base.set(a, .from(.{ .string = try state.newString("__call") }), state.get(-1).?);
    try state.setTop(1);
    state.barrier(&link.header);
    try link.set(a, .from(.{ .string = try state.newString("__index") }), .from(.{ .table = base }));
    try state.setMetatable(.from(.{ .table = meta }), link);
    try state.setMetatable(target, meta);
    plan.callable = target;
    state.setHook(observer, 1);
    event_count = 0;
    plan.calls = @splat(0);
    try completes(&state, outer);
    try expect(plan.caught == null);
    try expect(isNumber(plan.value, 9));
    try expect(state.globals.getString("seen_self").equal(target));
    try expect(entries(2) >= 1);
}

test "hook_reentry HC06 confirmed a C closure keeps its arguments and upvalue around an inner script" {
    var state = try State.init(a);
    defer state.deinit();
    const outer = try begin(&state, .hc06);
    plan.inner = try innerI(&state);
    try completes(&state, outer);
    try equal(api.Status.ok, plan.status.?);
    try expect(plan.ok);
    try expect(isNumber(plan.value, 9));
    try expect(entries(2) >= 1);
    for (events[0..event_count]) |event| if (event.depth == 2) try equal(@as(usize, 0), event.top);
}

test "hook_reentry HC07 confirmed inner callbacks start empty and the outer temporary survives them" {
    var state = try State.init(a);
    defer state.deinit();
    const outer = try begin(&state, .hc07);
    plan.inner = try innerI(&state);
    try completes(&state, outer);
    try expect(plan.caught == null and plan.ok);
    try equal(@as(usize, 2), plan.top_after);
    try expect(entries(2) >= 2);
    for (events[0..event_count]) |event| if (event.depth == 2 and event.kind == .enter) try equal(@as(usize, 0), event.top);
}

test "hook_reentry HC08 confirmed three nested windows each keep only their own temporaries" {
    var state = try State.init(a);
    defer state.deinit();
    const outer = try begin(&state, .hc08);
    plan.inner = try innerI(&state);
    plan.second = try innerJ(&state);
    try completes(&state, outer);
    try expect(plan.ok and plan.ok2);
    try expect(entries(3) >= 1);
    for (events[0..event_count]) |event| if (event.kind == .enter) try equal(@as(usize, 0), event.top);
}

test "hook_reentry HC09 confirmed an inner run that relocates the stack keeps the outer value and origin" {
    var state = try State.init(a);
    defer state.deinit();
    const outer = try begin(&state, .hc09);
    plan.inner = try compileNamed(&state, "local function f(n) local p, q, r, s, t, u, v, w = n, n, n, n, n, n, n, n if n == 0 then return 0 end return 1 + f(n - 1) end return f(120)", "=deep");
    state.setCollectionThreshold(0);
    try completes(&state, outer);
    try expect(plan.caught == null);
    try expect(plan.relocated);
    try expect(plan.ok);
}

test "hook_reentry HC10 confirmed an escaped inner capture closes with its value while the outer cell stays open" {
    var state = try State.init(a);
    defer state.deinit();
    const outer = try begin(&state, .hc10);
    plan.inner = try innerI(&state);
    try completes(&state, outer);
    try expect(plan.cell_open_after);
    state.collect();
    const escaped = state.globals.getString("escaped");
    try expect(escaped.isFunction());
    const cell = escaped.unpack().closure.upvalues[0];
    try expect(cell.storage == .closed);
    try expect(isString(cell.storage.closed, "captured"));
}

test "hook_reentry HC11 confirmed fixed and open result counts adjust the inner window above the outer prefix" {
    const Expected = struct { requested: ?usize, window: []const Value };
    for ([_]Expected{
        .{ .requested = 0, .window = &.{.from(.{ .number = 5 })} },
        .{ .requested = 1, .window = &.{ .from(.{ .number = 5 }), .from(.{ .number = 1 }) } },
        .{ .requested = 4, .window = &.{ .from(.{ .number = 5 }), .from(.{ .number = 1 }), .nil, .from(.{ .number = 3 }), .nil } },
        .{ .requested = null, .window = &.{ .from(.{ .number = 5 }), .from(.{ .number = 1 }), .nil, .from(.{ .number = 3 }) } },
    }) |expected| {
        var state = try State.init(a);
        defer state.deinit();
        const outer = try begin(&state, .hc11);
        plan.inner = try compileNamed(&state, "return 1, nil, 3", "=three");
        plan.requested = expected.requested;
        try completes(&state, outer);
        try expect(plan.caught == null);
        try equal(expected.window.len, plan.window_len);
        for (expected.window, plan.window[0..plan.window_len]) |wanted, actual| try expect(wanted.equal(actual));
    }
}

test "hook_reentry HC12 confirmed a Type failure caught inside the callback leaves the outer run successful" {
    var state = try State.init(a);
    defer state.deinit();
    const outer = try begin(&state, .hc12);
    plan.inner = try compileNamed(&state, "return 1 + nil", "=I");
    try completes(&state, outer);
    try equal(transport.Result{ .failure = .type_error }, plan.result.?);
    try equal(runtime.FailureKind.type_error, plan.failure_kind.?);
    try std.testing.expectEqualStrings("I:1: attempt to perform arithmetic on a nil value", message());
    try expect(plan.ok);
}

test "hook_reentry HC13 confirmed a pre-unwind handler runs at the inner failure point and its value is handled" {
    var state = try State.init(a);
    defer state.deinit();
    const outer = try begin(&state, .hc13);
    plan.inner = try compileNamed(&state, "local function g() return 1 + nil end local v = g() return v", "=I");
    try completes(&state, outer);
    try equal(transport.Result{ .failure = .type_error }, plan.result.?);
    try equal(@as(usize, 1), plan.handler_calls);
    // O, I, g and the handler's own native frame are all still present.
    try expect(plan.handler_frames >= 4);
    try expect(isString(plan.value, "handled"));
    try expect(entries(2) >= 1);
}

test "hook_reentry HC14 confirmed a native relay inside the callback keeps the inner Type and position" {
    for ([_]c_int{ 0, 1 }) |answer| {
        var state = try State.init(a);
        defer state.deinit();
        const outer = try begin(&state, .hc14);
        plan.inner = try compileNamed(&state, "return 1 + nil", "=I");
        plan.answer_outer = answer;
        var diagnostic: ?vm.Diagnostic = null;
        if (answer == 0) {
            try completes(&state, outer);
        } else {
            try std.testing.expectError(error.Interrupted, vm.run(&state, outer, &diagnostic));
            try restored(&state, 1);
            try expect(state.failure.?.value.is(.nil));
        }
        try equal(api.Status.type, plan.status.?);
        try equal(error.Type, plan.caught.?);
        try equal(runtime.FailureKind.type_error, plan.failure_kind.?);
        try std.testing.expectEqualStrings("I:1: attempt to perform arithmetic on a nil value", message());
        try expect(plan.ok);
    }
}

test "hook_reentry HC15 confirmed an inner interruption is the callback's to see and the outer continues on zero" {
    for ([_]c_int{ 1, -1, std.math.minInt(c_int), std.math.maxInt(c_int) }) |answer| {
        for ([_]bool{ false, true }) |protected| {
            var state = try State.init(a);
            defer state.deinit();
            const outer = try begin(&state, .hc15);
            plan.inner = try innerI(&state);
            plan.answer_inner = answer;
            if (protected) plan.case = .hc04;
            try completes(&state, outer);
            if (protected) {
                try equal(transport.Result{ .failure = .interrupted }, plan.result.?);
                try expect(plan.value.is(.nil));
            } else {
                try equal(error.Interrupted, plan.caught.?);
                try equal(runtime.FailureKind.interrupted, plan.failure_kind.?);
            }
            try equal(@as(usize, 0), plan.handler_calls);
            try equal(@as(usize, 1), entries(2));
            try equal(@as(usize, 5), entries(1));
        }
    }
}

test "hook_reentry HC16 confirmed a nonzero answer after a successful reentry interrupts the outer run with nil" {
    for ([_]c_int{ 1, -1 }) |answer| {
        var state = try State.init(a);
        defer state.deinit();
        const outer = try begin(&state, .hc16);
        plan.inner = try innerI(&state);
        plan.answer_outer = answer;
        var diagnostic: ?vm.Diagnostic = null;
        try std.testing.expectError(error.Interrupted, vm.run(&state, outer, &diagnostic));
        try expect(isNumber(plan.value, 9));
        try equal(runtime.FailureKind.interrupted, state.failure.?.kind);
        try expect(state.failure.?.value.is(.nil));
        try equal(@as(usize, 0), plan.handler_calls);
        try restored(&state, 1);
        try equal(@as(usize, 1), entries(1));
        try expect(entries(2) == 5);
    }
}

test "hook_reentry HC17 confirmed another state and the same state stay usable after an inner interruption" {
    var state = try State.init(a);
    defer state.deinit();
    var other = try State.init(a);
    defer other.deinit();
    const outer = try begin(&state, .hc15);
    plan.inner = try innerI(&state);
    plan.answer_inner = 1;
    try completes(&state, outer);
    try equal(error.Interrupted, plan.caught.?);
    const other_chunk = try synthetic(&other, 4, 1, "=B");
    try other.push(.from(.{ .number = 42 }));
    other.setHook(counter, 1);
    var diagnostic: ?vm.Diagnostic = null;
    _ = try vm.run(&other, other_chunk, &diagnostic);
    try equal(@as(usize, 5), plan.other_calls);
    try equal(@as(f64, 7), other.get(-1).?.numberValue().?);
    state.setHook(null, 0);
    try state.setTop(1);
    _ = try vm.run(&state, outer, &diagnostic);
    try restored(&state, 2);
    try equal(@as(f64, 7), state.get(-1).?.numberValue().?);
}

test "hook_reentry HC18 confirmed one shared countdown: inner instructions consume the outer schedule" {
    var state = try State.init(a);
    defer state.deinit();
    const outer = try begin(&state, .hc01);
    plan.inner = try innerI(&state);
    state.setHook(observer, 2);
    try completes(&state, outer);
    try expect(isNumber(plan.value, 9));
    printTrace("HC18 count=2");
    // Without reentry the outer callbacks are at lines 3 and 5. The inner run
    // leaves the shared countdown at zero when it returns, so line 3 is not
    // counted and the next callback follows immediately at line 4 (owner: A).
    try expectTrace(&.{ 1003, 2103, 2105, 1004, 1006 });
}

test "hook_reentry HC19 confirmed with count=1 the first inner callback is before the inner second instruction" {
    var state = try State.init(a);
    defer state.deinit();
    const outer = try begin(&state, .hc01);
    plan.inner = try innerI(&state);
    try completes(&state, outer);
    printTrace("HC19 count=1");
    try expectTrace(&.{ 1002, 2102, 2103, 2104, 2105, 2106, 1003, 1004, 1005, 1006 });
}

test "hook_reentry HC20 confirmed native-only reentry leaves the countdown and callback count unchanged" {
    var state = try State.init(a);
    defer state.deinit();
    const outer = try begin(&state, .hc20);
    try completes(&state, outer);
    try equal(@as(usize, 100), plan.native_calls);
    try equal(plan.remaining_before, plan.remaining_after);
    try expectTrace(&.{ 1002, 1003, 1004, 1005, 1006 });
}

test "hook_reentry HC21 confirmed tail calls, ordinary calls and callable iterators are observed alike" {
    const Variant = struct { source: []const u8, callable: bool };
    for ([_]Variant{
        .{ .source = "local function f(n) if n == 0 then return 9 end return f(n - 1) end return f(3)", .callable = false },
        .{ .source = "local function f() return 9 end local v = f() return v", .callable = false },
        .{ .source = "local total = 0 for i in it, nil, 0 do total = total + i end return total + 6", .callable = true },
    }) |variant| {
        var state = try State.init(a);
        defer state.deinit();
        const outer = try begin(&state, .hc21);
        state.setHook(null, 0);
        if (variant.callable) {
            const step = try compileNamed(&state, "return function(self, s, c) if c < 2 then return c + 1 end end", "=step");
            var diagnostic: ?vm.Diagnostic = null;
            _ = try vm.run(&state, step, &diagnostic);
            const iterator = try state.newTable();
            try hold(&state, "it", .from(.{ .table = iterator }));
            const meta = try state.newTable();
            try hold(&state, "held_mt", .from(.{ .table = meta }));
            state.barrier(&meta.header);
            try meta.set(a, .from(.{ .string = try state.newString("__call") }), state.get(-1).?);
            try state.setTop(1);
            try state.setMetatable(.from(.{ .table = iterator }), meta);
        }
        plan.inner = try compileNamed(&state, variant.source, "=I");
        state.setHook(observer, 1);
        event_count = 0;
        plan.calls = @splat(0);
        try completes(&state, outer);
        try expect(plan.caught == null);
        try expect(isNumber(plan.value, 9));
        try expect(entries(2) >= 3);
        try equal(@as(usize, 5), entries(1));
    }
}

test "hook_reentry HC22 confirmed three finite levels run and return in reverse order" {
    var state = try State.init(a);
    defer state.deinit();
    const outer = try begin(&state, .hc22);
    plan.inner = try innerI(&state);
    plan.second = try innerJ(&state);
    try completes(&state, outer);
    try expect(isNumber(plan.value, 9));
    try expect(isNumber(plan.second_value, 11));
    try expect(entries(3) >= 1);
    var deepest: usize = 0;
    var last_leave: usize = 0;
    for (events[0..event_count]) |event| {
        if (event.kind == .enter) {
            deepest = @max(deepest, event.depth);
        } else {
            // Leaves come back from the deepest level outward.
            if (last_leave != 0 and event.depth > last_leave) try expect(event.depth == last_leave + 1 or entries(event.depth) > 1);
            last_leave = event.depth;
        }
    }
    try equal(@as(usize, 3), deepest);
}

test "hook_reentry HC23 confirmed unconditional reentry is bounded by the ordinary call limit" {
    var state = try State.init(a);
    defer state.deinit();
    const outer = try begin(&state, .hc23);
    plan.inner = try innerI(&state);
    plan.max_depth = std.math.maxInt(usize);
    try completes(&state, outer);
    try expect(plan.refused);
    try equal(error.CallDepth, plan.caught.?);
    // The internal entry leaves the sentence to the public boundary; the kind is enough here.
    // The ordinary call limit is the only bound (owner: A).
    try equal(runtime.FailureKind.call_depth, plan.failure_kind.?);
    std.debug.print("hook reentry HC23: refused at hook depth {d} with {d} frames after {d} inner runs\n", .{ plan.refusal_depth, plan.refusal_frames, plan.executions });
    try equal(State.max_calls, plan.refusal_frames);
    try equal(State.max_calls, plan.refusal_depth);
    try equal(State.max_calls - 1, plan.executions);
}

test "hook_reentry HC24 confirmed reentry stops one level below the call limit and the refused level has no effect" {
    for ([_]usize{ State.max_calls - 1, State.max_calls, State.max_calls + 1 }) |limit| {
        var state = try State.init(a);
        defer state.deinit();
        const outer = try begin(&state, .hc24);
        plan.inner = try innerI(&state);
        plan.max_depth = limit;
        try completes(&state, outer);
        if (limit < State.max_calls) {
            try expect(!plan.refused);
            try equal(limit, plan.executions);
        } else {
            try expect(plan.refused);
            try equal(State.max_calls, plan.refusal_depth);
            try equal(State.max_calls - 1, plan.executions);
        }
    }
}

test "hook_reentry HC25 confirmed a handler run from the callback has the handler margin and its own failure stops once" {
    for ([_]bool{ false, true }) |handler_fails| {
        var state = try State.init(a);
        defer state.deinit();
        const outer = try begin(&state, .hc25);
        plan.inner = try compileNamed(&state, "return 1 + nil", "=I");
        if (handler_fails) {
            plan.handler_script = try compileNamed(&state, "return 1 + nil", "=H");
        } else {
            plan.second = try innerJ(&state);
        }
        state.setCollectionThreshold(0);
        try completes(&state, outer);
        if (handler_fails) {
            try equal(transport.Result{ .failure = .runtime_error }, plan.result.?);
            try std.testing.expectEqualStrings("error in error handling", message());
        } else {
            try equal(transport.Result{ .failure = .type_error }, plan.result.?);
            try equal(@as(usize, 1), plan.handler_calls);
            try equal(State.handler_calls, plan.handler_limit);
            try expect(isNumber(plan.second_value, 11));
            try std.testing.expectEqualStrings("handled", message());
        }
        try expect(plan.ok);
        try expect(entries(2) >= 1);
    }
}

test "hook_reentry HC26 confirmed removal before reentry is immediate for the inner run and the rest of the outer" {
    var state = try State.init(a);
    defer state.deinit();
    const outer = try begin(&state, .hc26);
    plan.inner = try innerI(&state);
    try completes(&state, outer);
    try expect(isNumber(plan.value, 9));
    try expectTrace(&.{1002});
    try expect(state.hook == null);
}

test "hook_reentry HC27 confirmed removal inside the inner callback persists after the return" {
    var state = try State.init(a);
    defer state.deinit();
    const outer = try begin(&state, .hc27);
    plan.inner = try innerI(&state);
    try completes(&state, outer);
    try expect(isNumber(plan.value, 9));
    try expectTrace(&.{ 1002, 2102 });
    try expect(state.hook == null);
}

test "hook_reentry HC28 confirmed replacement inside the inner callback applies to both runs from the next countdown" {
    var state = try State.init(a);
    defer state.deinit();
    const outer = try begin(&state, .hc28);
    plan.inner = try innerI(&state);
    try completes(&state, outer);
    try expect(isNumber(plan.value, 9));
    printTrace("HC28 replacement count=3");
    try expectTrace(&.{ 1002, 2102, 2105, 1003, 1006 });
    var actors: [8]u8 = undefined;
    var count: usize = 0;
    for (events[0..event_count]) |event| if (event.kind == .enter) {
        actors[count] = event.actor;
        count += 1;
    };
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 2, 2, 2 }, actors[0..count]);
    try equal(@as(c_uint, 3), state.hook_interval);
}

test "hook_reentry HC29 confirmed a replacement made by an interrupting inner callback persists" {
    var state = try State.init(a);
    defer state.deinit();
    const outer = try begin(&state, .hc29);
    plan.inner = try innerI(&state);
    try completes(&state, outer);
    try equal(error.Interrupted, plan.caught.?);
    try expect(state.hook.? == &replacement);
    try equal(@as(c_uint, 2), state.hook_interval);
    printTrace("HC29 replacement count=2 then stop");
    // The inner callback set the countdown to 2 and stopped; the outer's own
    // dispatch at line 3 then counts, and the replacement fires at 4 and 6.
    try expectTrace(&.{ 1002, 2102, 1004, 1006 });
    event_count = 0;
    try state.setTop(1);
    var diagnostic: ?vm.Diagnostic = null;
    _ = try vm.run(&state, outer, &diagnostic);
    try expectTrace(&.{ 1003, 1005 });
}

test "hook_reentry HC30 confirmed outer temporaries stay roots through inner collection and are released afterwards" {
    var state = try State.init(a);
    defer state.deinit();
    const outer = try begin(&state, .hc30);
    plan.inner = try compileNamed(&state, "local t = {} for i = 1, 40 do t[i] = { i } end return 9", "=alloc");
    state.setCollectionThreshold(0);
    try completes(&state, outer);
    try expect(plan.caught == null and plan.ok);
    state.collect();
    try expect(state.object_count < plan.objects_during);
}

fn allocationCase(allocator: std.mem.Allocator, answer: c_int) !void {
    var state = try State.init(allocator);
    defer state.deinit();
    const outer = try begin(&state, .hc31);
    plan.inner = try compileNamed(&state, "local t = { 1, 2 } local s = 'a' .. 'b' return 9", "=alloc");
    plan.answer_outer = answer;
    var diagnostic: ?vm.Diagnostic = null;
    // The callback swallows the inner memory failure (answer 0) or stops on it
    // (answer 1); either way the checker is told that the induced failure was seen.
    _ = vm.run(&state, outer, &diagnostic) catch |err| {
        try restored(&state, 1);
        if (err == error.OutOfMemory) {
            try expect(state.failure.?.value.unpack().string == state.memory_failure);
        } else {
            try equal(error.Interrupted, err);
            try expect(state.failure.?.value.is(.nil));
            try equal(error.OutOfMemory, plan.caught.?);
        }
        return error.OutOfMemory;
    };
    try restored(&state, 2);
    try equal(@as(f64, 7), state.get(2).?.numberValue().?);
    try expect(state.failure == null);
    if (plan.caught) |caught| {
        try equal(error.OutOfMemory, caught);
        return error.OutOfMemory;
    }
}

test "hook_reentry HC31 HC32 confirmed allocation failures in reentry preparation or the inner run restore the outer state" {
    for ([_]c_int{ 0, 1 }) |answer| try allocation_failures.checkAll(a, allocationCase, .{answer});
}

test "hook_reentry HC33 confirmed a full physical stack refuses the reentry before it runs" {
    for ([_]usize{ 2, 3 }) |spare| {
        var state = try State.init(a);
        defer state.deinit();
        const outer = try begin(&state, .hc33);
        plan.inner = try innerI(&state);
        try state.setTop(@intCast(State.max_stack - spare));
        var diagnostic: ?vm.Diagnostic = null;
        _ = try vm.run(&state, outer, &diagnostic);
        try equal(State.max_stack - spare + 1, state.top());
        try equal(@as(f64, 7), state.get(-1).?.numberValue().?);
        try equal(@as(f64, 42), state.get(1).?.numberValue().?);
        if (spare == 2) {
            try equal(api.Status.stack, plan.status.?);
            try expect(plan.result == null);
        } else {
            try equal(transport.Result{ .failure = .stack_limit }, plan.result.?);
            try equal(@as(usize, 1), plan.top_after);
        }
        try expect(state.hook_depth == 0 and state.hook_window == null and state.execution == null);
    }
}

test "hook_reentry HC34 confirmed a cross-state cycle returns into the original state's callback" {
    var state = try State.init(a);
    defer state.deinit();
    var other = try State.init(a);
    defer other.deinit();
    const outer = try begin(&state, .hc34);
    plan.inner = try innerI(&state);
    plan.second = try synthetic(&other, 4, 1, "=B");
    other.barrier(&other.globals.header);
    try other.globals.set(a, .from(.{ .string = try other.newString("held") }), .fromFunction(.{ .closure = plan.second.? }));
    plan.other = &other;
    plan.origin = &state;
    other.setHook(crossObserver, 1);
    try completes(&state, outer);
    try expect(plan.caught == null and plan.ok);
    try expect(isNumber(plan.value, 7));
    try expect(isNumber(plan.second_value, 9));
    try equal(@as(usize, 5), plan.other_calls);
    try expect(entries(2) >= 1);
    try expect(other.hook_depth == 0 and other.execution == null and other.vm_entries == 0);
    var diagnostic: ?vm.Diagnostic = null;
    _ = try vm.run(&other, plan.second.?, &diagnostic);
    try equal(@as(f64, 7), other.get(-1).?.numberValue().?);
}

test "hook_reentry HC35 confirmed one state is reused across success, caught failure, interruption and memory failure" {
    var state = try State.init(a);
    defer state.deinit();
    const outer = try begin(&state, .hc01);
    const inner = try innerI(&state);
    const bad = try compileNamed(&state, "return 1 + nil", "=I");
    var diagnostic: ?vm.Diagnostic = null;
    // Success.
    plan.inner = inner;
    try completes(&state, outer);
    try expect(isNumber(plan.value, 9));
    // A Type failure caught inside the callback.
    try state.setTop(1);
    plan = .{ .case = .hc12, .inner = bad };
    event_count = 0;
    try completes(&state, outer);
    try equal(transport.Result{ .failure = .type_error }, plan.result.?);
    // Interruption after a successful reentry.
    try state.setTop(1);
    plan = .{ .case = .hc16, .inner = inner, .answer_outer = 1 };
    event_count = 0;
    try std.testing.expectError(error.Interrupted, vm.run(&state, outer, &diagnostic));
    try restored(&state, 1);
    // Memory failure while the inner script runs; the callback continues.
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 1 });
    plan = .{ .case = .hc31, .inner = try compileNamed(&state, "local t = { 1, 2 } return 9", "=alloc") };
    event_count = 0;
    const saved = state.allocator;
    state.allocator = failing.allocator();
    _ = vm.run(&state, outer, &diagnostic) catch {};
    state.allocator = saved;
    try expect(state.hook_depth == 0 and state.hook_window == null and state.execution == null and state.vm_entries == 0);
    // Observation removed: the same chunk runs clean.
    state.setHook(null, 0);
    try state.setTop(1);
    _ = try vm.run(&state, outer, &diagnostic);
    try restored(&state, 2);
    try equal(@as(f64, 7), state.get(2).?.numberValue().?);
    try expect(state.failure == null);
}

test "hook_reentry HC36 confirmed public call and pcall from the callback agree with the internal entries" {
    for ([_]Public{ .call, .pcall_positive_handler, .pcall_negative_handler, .pcall_all, .pcall_type, .pcall_interrupt }) |public| {
        var state = try State.init(a);
        defer state.deinit();
        const outer = try begin(&state, .hc36);
        plan.public = public;
        plan.inner = switch (public) {
            .pcall_all => try compileNamed(&state, "return 1, nil, 3", "=three"),
            .pcall_type => try compileNamed(&state, "return 1 + nil", "=I"),
            else => try innerI(&state),
        };
        if (public == .pcall_interrupt) plan.answer_inner = 1;
        try completes(&state, outer);
        try expect(plan.ok);
        try equal(@as(usize, 0), plan.handler_calls);
        switch (public) {
            .call, .pcall_positive_handler, .pcall_negative_handler => {
                try equal(api.Status.ok, plan.status.?);
                try expect(isNumber(plan.value, 9));
                try equal(@as(usize, if (public == .call) 2 else 3), plan.top_after);
            },
            .pcall_all => {
                try equal(api.Status.ok, plan.status.?);
                try equal(@as(usize, 4), plan.top_after);
                try expect(plan.window[1].equal(.from(.{ .number = 1 })) and plan.window[2].is(.nil) and plan.window[3].equal(.from(.{ .number = 3 })));
            },
            .pcall_type => {
                try equal(api.Status.type, plan.status.?);
                try std.testing.expectEqualStrings("I:1: attempt to perform arithmetic on a nil value", message());
                try equal(@as(usize, 2), plan.top_after);
            },
            .pcall_interrupt => {
                try equal(api.Status.interrupted, plan.status.?);
                try expect(plan.value.is(.nil));
                try equal(@as(usize, 2), plan.top_after);
                try equal(@as(usize, 1), entries(2));
            },
        }
    }
}
