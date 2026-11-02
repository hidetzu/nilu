//! Characterization, not acceptance of unresolved hook capabilities.
//! Keep observed assertions distinct from owner-confirmed expectations. H01-H07 are confirmed by the owner; the other
//! capabilities remain observations, not accepted hook permissions.
const std = @import("std");
const runtime = @import("runtime.zig");
const api = @import("c_api.zig");
const vm = @import("vm.zig");
const transport = @import("failure_transport.zig");
const bytecode = @import("bytecode.zig");
const a = std.testing.allocator;
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
const Action = enum { inspect, push_pop, leave_value, overwrite, disable, disable_zero, recount, replace, load_ok, load_syntax, reenter_script, reenter_native, reenter_protected, api_memory, load_memory, raise_value, collect, cross_state, upvalues, raw_table, convert_register, ignore_raise };
const Sample = struct { line: usize, top: usize, frames: usize, actor: u8, first_type: c_int, first: runtime.Value, second: runtime.Value };
const Observation = struct {
    action: Action = .inspect,
    answer: c_int = 0,
    new_interval: c_uint = 3,
    other: ?*runtime.State = null,
    origin: ?*runtime.State = null,
    other_calls: usize = 0,
    both_in_hook: bool = false,
    other_result: ?usize = null,
    secondary_status: ?api.Status = null,
    queried_number: f64 = 0,
    converted: bool = false,
    converted_length: usize = 99,
    raise_return: c_int = 0,
    samples: [16]Sample = undefined,
    count: usize = 0,
    callback_in_hook: bool = false,
    status: ?api.Status = null,
    caught: ?vm.Error = null,
    target: ?runtime.Function = null,
    target_called: bool = false,
    reentry_value: runtime.Value = .nil,
    handler_called: bool = false,
    frames_unchanged: bool = false,
    top_unchanged: bool = false,
    entries_unchanged: bool = false,
    memory_notified: bool = false,
    loaded_not_executed: bool = false,
    where: api.ErrorLocation = .{ .line = 99, .column = 99 },
};
var observed: Observation = .{};

fn target(_: *runtime.State) callconv(.c) c_int {
    observed.target_called = true;
    return 0;
}
fn handler(_: *runtime.State) callconv(.c) c_int {
    observed.handler_called = true;
    return 0;
}
fn observer(state: *runtime.State) callconv(.c) c_int {
    return observe(state, 1);
}
fn replacement(state: *runtime.State) callconv(.c) c_int {
    return observe(state, 2);
}
fn observe(state: *runtime.State, actor: u8) c_int {
    if (observed.count >= observed.samples.len) return 1;
    observed.samples[observed.count] = .{
        .line = state.frames.items[state.frames.items.len - 1].position().?.line,
        .top = state.top(),
        .frames = state.frames.items.len,
        .actor = actor,
        .first_type = api.nilu_type(state, 1),
        .first = state.get(1) orelse .nil,
        .second = state.get(2) orelse .nil,
    };
    observed.count += 1;
    observed.callback_in_hook = state.hook_depth > 0;
    if (observed.count == 1) switch (observed.action) {
        .inspect => {},
        .push_pop => {
            observed.status = api.nilu_pushnumber(state, 99);
            if (observed.status == .ok) observed.status = api.nilu_settop(state, -2);
        },
        .leave_value => observed.status = api.nilu_pushnumber(state, 99),
        .overwrite => {
            observed.status = api.nilu_pushnumber(state, 100);
            if (observed.status == .ok) {
                api.nilu_copy(state, -1, 1);
                observed.status = api.nilu_settop(state, -2);
            }
        },
        .disable => api.nilu_sethook(state, null, 1),
        .disable_zero => api.nilu_sethook(state, observer, 0),
        .recount => api.nilu_sethook(state, observer, observed.new_interval),
        .replace => api.nilu_sethook(state, replacement, 2),
        .load_ok, .load_syntax => {
            observed.status = api.nilu_loadnamed(state, if (observed.action == .load_ok) "global hook_marker=99 return 8" else "local = 1", "=in-hook", &observed.where);
            observed.loaded_not_executed = state.globals.getString("hook_marker").is(.nil);
        },
        .reenter_script, .reenter_native, .reenter_protected => {
            const top = state.top();
            const frames = state.frames.items.len;
            const entries = state.vm_entries;
            var diagnostic: ?vm.Diagnostic = null;
            if (observed.action == .reenter_protected) {
                observed.status = api.nilu_pushcfunction(state, target);
                if (observed.status == .ok) {
                    _ = transport.callWithHandler(state, 0, true, .fromFunction(.{ .native = handler }), &diagnostic) catch |err| {
                        observed.caught = err;
                    };
                }
            } else {
                _ = vm.runFunctionWithArguments(state, if (observed.action == .reenter_script) observed.target.? else .{ .native = target }, 0, &diagnostic) catch |err| {
                    observed.caught = err;
                };
            }
            observed.reentry_value = state.get(-1) orelse runtime.Value.nil;
            observed.top_unchanged = state.top() == top;
            observed.frames_unchanged = state.frames.items.len == frames;
            observed.entries_unchanged = state.vm_entries == entries;
        },
        .api_memory, .load_memory => {
            const saved = state.allocator;
            defer state.allocator = saved;
            var failing = std.testing.FailingAllocator.init(saved, .{ .fail_index = 0 });
            state.allocator = failing.allocator();
            observed.status = if (observed.action == .api_memory) api.nilu_pushstring(state, "hook allocation") else api.nilu_loadstring(state, "return 1", &observed.where);
            observed.memory_notified = state.execution.?.api_memory_failure;
        },
        .raise_value => {
            observed.status = api.nilu_pushstring(state, "hook raised");
            if (observed.status == .ok) return api.nilu_error(state);
        },
        .upvalues => {
            const before = state.top();
            observed.status = api.nilu_getupvalue(state, 1);
            observed.secondary_status = api.nilu_setupvalue(state, 1);
            observed.top_unchanged = state.top() == before;
        },
        .raw_table => {
            observed.status = api.nilu_newtable(state);
            if (observed.status != .ok) return 1;
            if (api.nilu_pushstring(state, "key") != .ok or api.nilu_pushnumber(state, 99) != .ok) return 1;
            observed.status = api.nilu_rawset(state, -3);
            if (observed.status != .ok or api.nilu_pushstring(state, "key") != .ok) return 1;
            observed.secondary_status = api.nilu_rawget(state, -2);
            observed.queried_number = api.nilu_tonumberx(state, -1, null);
            _ = api.nilu_settop(state, -2);
            state.collect();
        },
        .convert_register => observed.converted = api.nilu_tolstring(state, 1, &observed.converted_length) != null,
        .ignore_raise => {
            observed.status = api.nilu_pushstring(state, "ignored hook raise");
            if (observed.status != .ok) return 1;
            observed.raise_return = api.nilu_error(state);
            state.collect();
        },
        .collect => state.collect(),
        .cross_state => {
            observed.origin = state;
            var diagnostic: ?vm.Diagnostic = null;
            observed.other_result = vm.runFunctionWithArguments(observed.other.?, observed.target.?, 0, &diagnostic) catch |err| failed: {
                observed.caught = err;
                break :failed null;
            };
        },
    };
    return observed.answer;
}

// Exactly six dispatches. At the first hook (interval=1), line 1 has initialized
// r0=1, r1 is nil, and line 2 has not executed. The final result is 1+2+4=7.
fn program(state: *runtime.State) !*runtime.Closure {
    const operations = [_]bytecode.Instruction.Operation{
        .{ .constant = .{ .destination = 0, .index = 0 } },
        .{ .constant = .{ .destination = 1, .index = 1 } },
        .{ .binary = .{ .operator = .add, .destination = 0, .left = 0, .right = 1 } },
        .{ .constant = .{ .destination = 1, .index = 2 } },
        .{ .binary = .{ .operator = .add, .destination = 0, .left = 0, .right = 1 } },
        .{ .returns = .{ .first = 0, .count = 1 } },
    };
    var code: [operations.len]bytecode.Written = undefined;
    for (operations, &code, 0..) |op, *instruction, i| instruction.* = .{ .operation = op, .position = .{ .offset = 0, .line = @intCast(i + 1), .column = 1 } };
    return state.newChunk(try state.newProgram(&.{ .from(.{ .number = 1 }), .from(.{ .number = 2 }), .from(.{ .number = 4 }) }, &code, 2, "", "=hook-observation"));
}
fn expectRestored(state: *runtime.State, top: usize) !void {
    try equal(top, state.top());
    try equal(@as(f64, 42), state.get(1).?.numberValue().?);
    try equal(@as(usize, 0), state.frames.items.len);
    try equal(@as(usize, 0), state.vm_entries);
    try expect(state.hook_depth == 0);
    try expect(state.execution == null);
}
fn setup(state: *runtime.State, action: Action) !*runtime.Closure {
    const chunk = try program(state);
    try state.push(.from(.{ .number = 42 }));
    observed = .{ .action = action };
    api.nilu_sethook(state, observer, 1);
    return chunk;
}
fn lines(wanted: []const usize) !void {
    try equal(wanted.len, observed.count);
    for (wanted, observed.samples[0..observed.count]) |line, sample| try equal(line, sample.line);
    std.debug.print("hook observation: {s}; line/top/observer=", .{@tagName(observed.action)});
    for (observed.samples[0..observed.count]) |sample| std.debug.print(" {d}/{d}/{d}", .{ sample.line, sample.top, sample.actor });
    std.debug.print("\n", .{});
}

test "hook_behavior confirmed frame visibility begins empty and hides VM registers and caller" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    const chunk = try setup(&state, .inspect);
    var diagnostic: ?vm.Diagnostic = null;
    _ = try vm.run(&state, chunk, &diagnostic);
    try lines(&.{ 2, 3, 4, 5, 6 });
    try equal(@as(usize, 0), observed.samples[0].top);
    try expect(observed.samples[0].first.is(.nil));
    try equal(@as(c_int, -1), observed.samples[0].first_type);
    try expect(observed.samples[0].second.is(.nil));
    try expect(observed.callback_in_hook);
    try expectRestored(&state, 2);
    try equal(@as(f64, 7), state.get(-1).?.numberValue().?);
}

test "hook_behavior confirmed push pop and unpopped values are isolated to one callback" {
    for ([_]Action{ .push_pop, .leave_value }) |action| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        const chunk = try setup(&state, action);
        var diagnostic: ?vm.Diagnostic = null;
        _ = try vm.run(&state, chunk, &diagnostic);
        try equal(api.Status.ok, observed.status.?);
        try equal(@as(usize, 0), observed.samples[1].top);
        try expectRestored(&state, 2);
        try equal(@as(f64, 7), state.get(-1).?.numberValue().?);
    }
}

test "hook_behavior confirmed temporary overwrite cannot change suspended computation" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    const chunk = try setup(&state, .overwrite);
    var diagnostic: ?vm.Diagnostic = null;
    _ = try vm.run(&state, chunk, &diagnostic);
    try expectRestored(&state, 2);
    try equal(@as(f64, 7), state.get(-1).?.numberValue().?);
    try equal(api.Status.ok, observed.status.?);
}

test "hook_behavior observed removal inside callback takes effect immediately and persists" {
    for ([_]Action{ .disable, .disable_zero }) |action| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        const chunk = try setup(&state, action);
        var diagnostic: ?vm.Diagnostic = null;
        _ = try vm.run(&state, chunk, &diagnostic);
        try lines(&.{2});
        try expect(state.hook == null);
        try equal(@as(c_uint, 0), state.hook_remaining);
        _ = try vm.run(&state, chunk, &diagnostic);
        try lines(&.{2});
    }
}

test "hook_behavior observed interval change and callback replacement use new countdown in current dispatch" {
    for ([_]Action{ .recount, .replace }) |action| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        const chunk = try setup(&state, action);
        var diagnostic: ?vm.Diagnostic = null;
        _ = try vm.run(&state, chunk, &diagnostic);
        try lines(if (action == .recount) &.{ 2, 5 } else &.{ 2, 4, 6 });
        try equal(@as(u8, 1), observed.samples[0].actor);
        for (observed.samples[1..observed.count]) |sample| try equal(@as(u8, if (action == .replace) 2 else 1), sample.actor);
        try expectRestored(&state, 2);
        try equal(@as(f64, 7), state.get(-1).?.numberValue().?);
    }
}

test "hook_behavior observed registration changes persist even when callback interrupts" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    const chunk = try setup(&state, .replace);
    observed.answer = -1;
    var diagnostic: ?vm.Diagnostic = null;
    try std.testing.expectError(error.Interrupted, vm.run(&state, chunk, &diagnostic));
    try lines(&.{2});
    try expectRestored(&state, 1);
    try expect(state.hook == replacement);
    try equal(@as(c_uint, 2), state.hook_remaining);
    observed = .{};
    _ = try vm.run(&state, chunk, &diagnostic);
    try lines(&.{ 3, 5 });
    for (observed.samples[0..observed.count]) |sample| try equal(@as(u8, 2), sample.actor);
    try expect(state.failure == null);
}

test "hook_behavior observed public loading inside hook succeeds without executing or recursively observing" {
    for ([_]Action{ .load_ok, .load_syntax }) |action| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        const chunk = try setup(&state, action);
        var diagnostic: ?vm.Diagnostic = null;
        _ = try vm.run(&state, chunk, &diagnostic);
        try equal(if (action == .load_ok) api.Status.ok else .syntax, observed.status.?);
        try equal(if (action == .load_ok) api.ErrorLocation{} else api.ErrorLocation{ .line = 1, .column = 7 }, observed.where);
        try expect(observed.loaded_not_executed);
        try lines(&.{ 2, 3, 4, 5, 6 });
        try equal(@as(usize, 0), observed.samples[1].top);
        try expectRestored(&state, 2);
        try equal(@as(f64, 7), state.get(-1).?.numberValue().?);
    }
}

fn reentryTarget(state: *runtime.State) !runtime.Function {
    var diagnostic: ?@import("loader.zig").Diagnostic = null;
    const chunk = try @import("loader.zig").prepare(state, "global target_ran=99 return 8", "=hook-target", &diagnostic);
    const function = runtime.Function{ .closure = chunk };
    state.barrier(&state.globals.header);
    try state.globals.set(a, .from(.{ .string = try state.newString("held_target") }), .fromFunction(function));
    return function;
}
// HC01/HC02/HC04: the same state's VM runs again
// from the callback. The target's instructions are observed too, so the script
// target adds its own callback samples before the outer lines 3..6.
test "hook_behavior confirmed script native and protected reentry run the target inside the callback" {
    for ([_]Action{ .reenter_script, .reenter_native, .reenter_protected }) |action| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        const chunk = try setup(&state, action);
        observed.target = try reentryTarget(&state);
        var diagnostic: ?vm.Diagnostic = null;
        _ = try vm.run(&state, chunk, &diagnostic);
        try expect(observed.caught == null);
        try expect(!observed.handler_called);
        if (action == .reenter_script) {
            try expect(observed.reentry_value.equal(.from(.{ .number = 8 })));
            try equal(@as(f64, 99), state.globals.getString("target_ran").numberValue().?);
            try expect(!observed.top_unchanged);
            try expect(observed.count > 5);
        } else {
            try expect(observed.target_called);
            try expect(state.globals.getString("target_ran").is(.nil));
            try lines(&.{ 2, 3, 4, 5, 6 });
        }
        try expect(observed.frames_unchanged and observed.entries_unchanged);
        try expectRestored(&state, 2);
        try equal(@as(f64, 7), state.get(-1).?.numberValue().?);
        try expect(state.failure == null);
    }
}

test "hook_behavior observed API Memory can be ignored or followed by interruption" {
    for ([_]Action{ .api_memory, .load_memory }) |action| {
        for ([_]c_int{ 0, -1 }) |answer| {
            var state = try runtime.State.init(a);
            defer state.deinit();
            const chunk = try setup(&state, action);
            observed.answer = answer;
            var diagnostic: ?vm.Diagnostic = null;
            if (answer == 0) {
                _ = try vm.run(&state, chunk, &diagnostic);
                try expectRestored(&state, 2);
                try equal(@as(f64, 7), state.get(-1).?.numberValue().?);
                try expect(state.failure == null);
            } else {
                try std.testing.expectError(error.Interrupted, vm.run(&state, chunk, &diagnostic));
                try expectRestored(&state, 1);
                try expect(state.failure.?.value.is(.nil));
            }
            try equal(api.Status.memory, observed.status.?);
            try expect(!observed.memory_notified);
            if (action == .load_memory) try equal(api.ErrorLocation{}, observed.where);
        }
    }
}

test "hook_behavior observed nilu_error return from hook interrupts rather than raising Runtime" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    const chunk = try setup(&state, .raise_value);
    var diagnostic: ?vm.Diagnostic = null;
    try std.testing.expectError(error.Interrupted, vm.run(&state, chunk, &diagnostic));
    try equal(api.Status.ok, observed.status.?);
    try expectRestored(&state, 1);
    try equal(runtime.FailureKind.interrupted, state.failure.?.kind);
    try expect(state.failure.?.value.is(.nil));
}

test "hook_behavior observed collection inside callback retains active registers and caller roots" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    const chunk = try setup(&state, .collect);
    const held = try state.newString("caller-root");
    try state.push(.from(.{ .string = held }));
    var diagnostic: ?vm.Diagnostic = null;
    _ = try vm.run(&state, chunk, &diagnostic);
    try equal(@as(usize, 3), state.top());
    try std.testing.expectEqualStrings("caller-root", state.get(2).?.unpack().string.bytes);
    try equal(@as(f64, 7), state.get(-1).?.numberValue().?);
    try expect(state.execution == null and state.hook_depth == 0);
}

fn otherObserver(state: *runtime.State) callconv(.c) c_int {
    observed.other_calls += 1;
    observed.both_in_hook = state.hook_depth > 0 and observed.origin.?.hook_depth > 0;
    return 0;
}
test "hook_behavior observed reentry into a different state runs with independent hook counting" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    var other = try runtime.State.init(a);
    defer other.deinit();
    const chunk = try setup(&state, .cross_state);
    const other_chunk = try program(&other);
    other.barrier(&other.globals.header);
    try other.globals.set(a, .from(.{ .string = try other.newString("held") }), .fromFunction(.{ .closure = other_chunk }));
    observed.other = &other;
    observed.target = .{ .closure = other_chunk };
    api.nilu_sethook(&other, otherObserver, 1);
    var diagnostic: ?vm.Diagnostic = null;
    _ = try vm.run(&state, chunk, &diagnostic);
    try expect(observed.caught == null);
    try equal(@as(usize, 1), observed.other_result.?);
    try equal(@as(usize, 5), observed.other_calls);
    try expect(observed.both_in_hook);
    try lines(&.{ 2, 3, 4, 5, 6 });
    try equal(@as(f64, 7), other.get(-1).?.numberValue().?);
    try expect(other.hook_depth == 0 and other.execution == null and other.vm_entries == 0);
    try expectRestored(&state, 2);
}

test "hook_behavior confirmed nonzero signs and extremes interrupt protected or propagating entries without handlers" {
    for ([_]c_int{ 1, -1, std.math.minInt(c_int), std.math.maxInt(c_int) }) |answer| {
        for ([_]bool{ false, true }) |protected| {
            var state = try runtime.State.init(a);
            defer state.deinit();
            const chunk = try setup(&state, .inspect);
            observed.answer = answer;
            try state.push(.fromFunction(.{ .closure = chunk }));
            var diagnostic: ?vm.Diagnostic = null;
            const result = try transport.callWithHandler(&state, 0, protected, if (protected) .fromFunction(.{ .native = handler }) else null, &diagnostic);
            try equal(runtime.FailureKind.interrupted, result.failure);
            try expect(!observed.handler_called);
            try equal(@as(usize, 2), state.top());
            try expect(state.get(-1).?.is(.nil));
            try expect(state.originAt(1) != null);
            try equal(@as(usize, 2), diagnostic.?.position.line);
            try equal(@as(usize, 0), state.frames.items.len);
            try expect(state.hook_depth == 0 and state.execution == null and state.vm_entries == 0);
            api.nilu_sethook(&state, null, 0);
            try state.setTop(1);
            _ = try vm.run(&state, chunk, &diagnostic);
            try equal(@as(f64, 7), state.get(-1).?.numberValue().?);
            try expect(state.failure == null);
        }
    }
}

test "hook_behavior observed unchanged and maximum replacement intervals have explicit dispatch timing" {
    for ([_]c_uint{ 1, std.math.maxInt(c_uint) }) |interval| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        const chunk = try setup(&state, .recount);
        observed.new_interval = interval;
        var diagnostic: ?vm.Diagnostic = null;
        _ = try vm.run(&state, chunk, &diagnostic);
        try lines(if (interval == 1) &.{ 2, 3, 4, 5, 6 } else &.{2});
        try equal(interval, state.hook_interval);
        try equal(@as(f64, 7), state.get(-1).?.numberValue().?);
    }
}

// HC16: a successful reentry followed by a nonzero answer still interrupts the
// outer run; the answer is given on every callback, so the inner script target
// is itself interrupted before it completes.
test "hook_behavior confirmed stopping after reentry interrupts the outer run with nil" {
    for ([_]Action{ .reenter_script, .reenter_native, .reenter_protected }) |action| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        const chunk = try setup(&state, action);
        observed.target = try reentryTarget(&state);
        observed.answer = 1;
        var diagnostic: ?vm.Diagnostic = null;
        try std.testing.expectError(error.Interrupted, vm.run(&state, chunk, &diagnostic));
        try equal(runtime.FailureKind.interrupted, state.failure.?.kind);
        try expect(state.failure.?.value.is(.nil));
        if (action == .reenter_script) {
            try equal(error.Interrupted, observed.caught.?);
            try expect(state.globals.getString("target_ran").is(.nil));
        } else {
            try expect(observed.caught == null and observed.target_called);
        }
        try expect(!observed.handler_called);
        try expectRestored(&state, 1);
    }
}

extern fn test_hook_observe_reset() callconv(.c) void;
extern fn test_hook_observe_stack(*runtime.State) callconv(.c) c_int;
extern fn test_hook_observed_top() callconv(.c) c_int;
extern fn test_hook_observed_type() callconv(.c) c_int;
extern fn test_hook_observed_number() callconv(.c) f64;
extern fn test_hook_observed_count() callconv(.c) c_uint;

test "hook_behavior confirmed actual C callback starts with an empty temporary window" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    const chunk = try setup(&state, .inspect);
    test_hook_observe_reset();
    api.nilu_sethook(&state, test_hook_observe_stack, 1);
    var diagnostic: ?vm.Diagnostic = null;
    _ = try vm.run(&state, chunk, &diagnostic);
    try equal(@as(c_int, 0), test_hook_observed_top());
    try equal(@as(c_int, -1), test_hook_observed_type());
    try equal(@as(f64, 0), test_hook_observed_number());
    try equal(@as(c_uint, 5), test_hook_observed_count());
    try expectRestored(&state, 2);
    try equal(@as(f64, 7), state.get(-1).?.numberValue().?);
}

test "hook_behavior observed upvalue queries see no running C closure in a script hook" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    const chunk = try setup(&state, .upvalues);
    var diagnostic: ?vm.Diagnostic = null;
    _ = try vm.run(&state, chunk, &diagnostic);
    try equal(api.Status.type, observed.status.?);
    try equal(api.Status.type, observed.secondary_status.?);
    try expect(observed.top_unchanged);
    try equal(@as(f64, 7), state.get(-1).?.numberValue().?);
}

test "hook_behavior observed raw table allocation writes reads and collection do not execute VM" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    const chunk = try setup(&state, .raw_table);
    var diagnostic: ?vm.Diagnostic = null;
    _ = try vm.run(&state, chunk, &diagnostic);
    try equal(api.Status.ok, observed.status.?);
    try equal(api.Status.ok, observed.secondary_status.?);
    try equal(@as(f64, 99), observed.queried_number);
    try lines(&.{ 2, 3, 4, 5, 6 });
    try equal(@as(usize, 0), observed.samples[1].top);
    try expectRestored(&state, 2);
    try equal(@as(f64, 7), state.get(-1).?.numberValue().?);
}

test "hook_behavior confirmed absent register conversion returns NULL without changing computation" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    const chunk = try setup(&state, .convert_register);
    var diagnostic: ?vm.Diagnostic = null;
    _ = try vm.run(&state, chunk, &diagnostic);
    try expect(!observed.converted);
    try equal(@as(usize, 0), observed.converted_length);
    try lines(&.{ 2, 3, 4, 5, 6 });
    try expectRestored(&state, 2);
    try equal(@as(f64, 7), state.get(-1).?.numberValue().?);
}

test "hook_behavior observed ignoring nilu_error return permits successful completion" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    const chunk = try setup(&state, .ignore_raise);
    var diagnostic: ?vm.Diagnostic = null;
    _ = try vm.run(&state, chunk, &diagnostic);
    try equal(api.Status.ok, observed.status.?);
    try equal(@as(c_int, -1), observed.raise_return);
    try expectRestored(&state, 2);
    try equal(@as(f64, 7), state.get(-1).?.numberValue().?);
    try expect(state.failure == null);
}

test "hook_behavior observed full physical stack push or load refusal may continue or interrupt" {
    for ([_]Action{ .leave_value, .load_ok }) |action| {
        for ([_]c_int{ 0, 1 }) |answer| {
            var state = try runtime.State.init(a);
            defer state.deinit();
            const chunk = try setup(&state, action);
            try state.setTop(runtime.State.max_stack - 2);
            observed.answer = answer;
            var diagnostic: ?vm.Diagnostic = null;
            if (answer == 0) {
                _ = try vm.run(&state, chunk, &diagnostic);
                try equal(runtime.State.max_stack - 1, state.top());
                try equal(@as(f64, 7), state.get(-1).?.numberValue().?);
            } else {
                try std.testing.expectError(error.Interrupted, vm.run(&state, chunk, &diagnostic));
                try equal(runtime.State.max_stack - 2, state.top());
                try expect(state.failure.?.value.is(.nil));
            }
            try equal(api.Status.stack, observed.status.?);
            if (action == .load_ok) try equal(api.ErrorLocation{}, observed.where);
            try equal(@as(usize, 0), observed.samples[0].top);
            try equal(@as(f64, 42), state.get(1).?.numberValue().?);
            try expect(state.hook_depth == 0 and state.execution == null and state.vm_entries == 0);
        }
    }
}

fn frameProgram(state: *runtime.State, child: *runtime.Closure, tail: bool) !*runtime.Closure {
    const normal_ops = [_]bytecode.Instruction.Operation{
        .{ .constant = .{ .destination = 0, .index = 0 } },
        .{ .constant = .{ .destination = 1, .index = 1 } },
        .{ .call = .{ .base = 1, .arguments = 0, .results = 1 } },
        .{ .returns = .{ .first = 0, .count = 2 } },
    };
    const tail_ops = [_]bytecode.Instruction.Operation{
        .{ .constant = .{ .destination = 0, .index = 1 } },
        .{ .tail_call = .{ .base = 0, .arguments = 0 } },
    };
    const operations = if (tail) &tail_ops else &normal_ops;
    var code: [normal_ops.len]bytecode.Written = undefined;
    for (operations, code[0..operations.len], 0..) |op, *instruction, i| instruction.* = .{ .operation = op, .position = .{ .offset = 0, .line = @intCast(100 + i), .column = 1 } };
    return state.newChunk(try state.newProgram(&.{ .from(.{ .number = 99 }), .fromFunction(.{ .closure = child }) }, code[0..operations.len], 2, "", "=hook-parent"));
}

test "hook_behavior observed nested script callbacks see only the active script window" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    const child = try setup(&state, .inspect);
    const parent = try frameProgram(&state, child, false);
    var diagnostic: ?vm.Diagnostic = null;
    _ = try vm.run(&state, parent, &diagnostic);
    try lines(&.{ 101, 102, 1, 2, 3, 4, 5, 6, 103 });
    for (observed.samples[0..observed.count]) |sample| {
        try equal(@as(usize, 0), sample.top);
        try equal(@as(usize, if (sample.line < 100) 2 else 1), sample.frames);
        try expect(sample.first.is(.nil) and sample.second.is(.nil));
    }
    try expectRestored(&state, 3);
    try equal(@as(f64, 99), state.get(2).?.numberValue().?);
    try equal(@as(f64, 7), state.get(3).?.numberValue().?);
}

test "hook_behavior observed tail script callbacks reuse the frame without exposing old caller slots" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    const child = try setup(&state, .inspect);
    const parent = try frameProgram(&state, child, true);
    var diagnostic: ?vm.Diagnostic = null;
    _ = try vm.run(&state, parent, &diagnostic);
    try lines(&.{ 101, 1, 2, 3, 4, 5, 6 });
    for (observed.samples[0..observed.count]) |sample| try equal(@as(usize, 1), sample.frames);
    try expect(observed.samples[2].first.is(.nil));
    try expectRestored(&state, 2);
    try equal(@as(f64, 7), state.get(-1).?.numberValue().?);
}

fn scriptFromNative(state: *runtime.State) callconv(.c) c_int {
    var diagnostic: ?vm.Diagnostic = null;
    const count = vm.runFunctionWithArguments(state, observed.target.?, 0, &diagnostic) catch return -1;
    return @intCast(count);
}
test "hook_behavior observed script entered by C closure hides native arguments and upvalues" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    const child = try setup(&state, .upvalues);
    observed.target = .{ .closure = child };
    const outer = try state.newCClosure(scriptFromNative, &.{.from(.{ .string = try state.newString("private") })});
    try state.push(.from(.{ .number = 99 }));
    var diagnostic: ?vm.Diagnostic = null;
    _ = try vm.runFunctionWithArguments(&state, outer, 1, &diagnostic);
    try lines(&.{ 2, 3, 4, 5, 6 });
    try equal(@as(usize, 2), observed.samples[0].frames);
    try equal(@as(usize, 0), observed.samples[0].top);
    try expect(observed.samples[0].first.is(.nil));
    try equal(api.Status.type, observed.status.?);
    try equal(api.Status.type, observed.secondary_status.?);
    try expect(observed.top_unchanged);
    try std.testing.expectEqualStrings("private", outer.c_closure.upvalues[0].unpack().string.bytes);
    try expectRestored(&state, 2);
    try equal(@as(f64, 7), state.get(-1).?.numberValue().?);
}
