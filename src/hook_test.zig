const std = @import("std");
const allocation_failures = @import("allocation_failures.zig");
const runtime = @import("runtime.zig");
const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const vm = @import("vm.zig");
const bytecode = @import("bytecode.zig");
const a = std.testing.allocator;
const State = runtime.State;
const Value = runtime.Value;
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
const api = @import("c_api.zig");
const loader = @import("loader.zig");

const Context = struct { calls: usize = 0, stop_after: usize = std.math.maxInt(usize), stop_result: c_int = 1, reentry: ?*runtime.Closure = null, reentered: ?runtime.Value = null };
var context: Context = .{};
fn observer(_: *State) callconv(.c) c_int {
    context.calls += 1;
    return if (context.calls >= context.stop_after) context.stop_result else 0;
}
fn compile(state: *State, source: []const u8) !*runtime.Closure {
    var parsed: ?parser.Diagnostic = null;
    var ast = try parser.parseChunk(a, source, &parsed);
    defer ast.deinit();
    var diagnostic: ?compiler.Diagnostic = null;
    return state.newChunk(try compiler.compile(a, state, &ast, "<hook>", &diagnostic));
}
fn run(state: *State, source: []const u8, diagnostic: *?vm.Diagnostic) !usize {
    return vm.run(state, try compile(state, source), diagnostic);
}

test "hook carried watcher cases count before the next instruction and recover after stopping" {
    var state = try State.init(a);
    defer state.deinit();
    const closure = try compile(&state, "return 10+20");
    context = .{};
    state.setHook(observer, 1);
    var diagnostic: ?vm.Diagnostic = null;
    try equal(@as(usize, 1), try vm.run(&state, closure, &diagnostic));
    // Independent carried C smoke cases specify four executed instructions.
    try equal(@as(usize, 3), context.calls);
    try expect(state.get(1).?.equal(.from(.{ .number = 30 })));
    try state.setTop(0);
    try state.push(.from(.{ .number = 42 }));
    context = .{ .stop_after = 1, .stop_result = -9 };
    state.setHook(observer, 2);
    try std.testing.expectError(error.Interrupted, vm.run(&state, closure, &diagnostic));
    try equal(@as(usize, 1), context.calls);
    try equal(.interrupted, diagnostic.?.kind);
    try equal(.binary, diagnostic.?.operation);
    try expect(state.failure.?.value.is(.nil));
    try equal(@as(usize, 1), state.top());
    try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
    try equal(@as(usize, 0), state.frames.items.len);
    try equal(@as(usize, 0), state.vm_entries);
    state.setHook(null, 0);
    try equal(@as(usize, 1), try vm.run(&state, closure, &diagnostic));
    try expect(state.get(2).?.equal(.from(.{ .number = 30 })));
}

test "hook outermost calls reset partial counts and final returns have no trailing hook" {
    var state = try State.init(a);
    defer state.deinit();
    const closure = try compile(&state, "return 10+20");
    context = .{};
    state.setHook(observer, 3);
    var diagnostic: ?vm.Diagnostic = null;
    // Five runs cross every carried remainder for a four-step/three-count pair.
    for (0..5) |_| {
        const before = context.calls;
        try equal(@as(usize, 1), try vm.run(&state, closure, &diagnostic));
        try equal(before + 1, context.calls);
        try state.setTop(0);
    }
    context = .{};
    state.setHook(observer, 4);
    _ = try vm.run(&state, closure, &diagnostic);
    try equal(@as(usize, 0), context.calls);
}

fn program(state: *State, constants: []const Value, operations: []const bytecode.Instruction.Operation, registers: usize) !*runtime.Closure {
    const code = try a.alloc(bytecode.Written, operations.len);
    defer a.free(code);
    for (operations, code, 0..) |operation, *instruction, i| instruction.* = .{ .position = .{ .offset = 0, .line = @intCast(i + 1), .column = 1 }, .operation = operation };
    return state.newChunk(try state.newProgram(constants, code, registers, "", "<hook-code>"));
}

test "hook nested and tail calls share one instruction countdown" {
    var state = try State.init(a);
    defer state.deinit();
    const child = try program(&state, &.{.from(.{ .number = 7 })}, &.{
        .{ .constant = .{ .destination = 0, .index = 0 } },
        .{ .returns = .{ .first = 0, .count = 1 } },
    }, 1);
    const parent = try program(&state, &.{.fromFunction(.{ .closure = child })}, &.{
        .{ .constant = .{ .destination = 0, .index = 0 } },
        .{ .call = .{ .base = 0, .arguments = 0, .results = 1 } },
        .{ .returns = .{ .first = 0, .count = 1 } },
    }, 1);
    context = .{};
    state.setHook(observer, 2);
    var diagnostic: ?vm.Diagnostic = null;
    try equal(@as(usize, 1), try vm.run(&state, parent, &diagnostic));
    try equal(@as(usize, 2), context.calls); // five instructions, boundaries 2 and 4
    try state.setTop(0);
    const tail = try program(&state, &.{.fromFunction(.{ .closure = child })}, &.{
        .{ .constant = .{ .destination = 0, .index = 0 } },
        .{ .tail_call = .{ .base = 0, .arguments = 0 } },
    }, 1);
    context = .{};
    try equal(@as(usize, 1), try vm.run(&state, tail, &diagnostic));
    try equal(@as(usize, 1), context.calls); // four instructions, no hook after return
}

test "hook zero and null disable observation without allocating" {
    var state = try State.init(a);
    defer state.deinit();
    const closure = try compile(&state, "return 10+20");
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    const original = state.allocator;
    state.allocator = failing.allocator();
    state.setHook(observer, 1);
    state.setHook(observer, 0);
    state.setHook(null, std.math.maxInt(c_uint));
    try equal(@as(usize, 0), failing.alloc_index);
    state.allocator = original;
    context = .{};
    var diagnostic: ?vm.Diagnostic = null;
    _ = try vm.run(&state, closure, &diagnostic);
    try equal(@as(usize, 0), context.calls);
    state.setHook(observer, 0);
    _ = try vm.run(&state, closure, &diagnostic);
    try equal(@as(usize, 0), context.calls);
}

test "hook stops actual endless loops iterators and tail recursion" {
    for ([_][]const u8{
        "while true do end",
        "repeat until false",
        "for i=1,1/0 do end",
        "for k in function() return false end do end",
        "local function f() return f() end return f()",
    }) |source| {
        var state = try State.init(a);
        defer state.deinit();
        context = .{ .stop_after = 3 };
        state.setHook(observer, 100);
        var diagnostic: ?vm.Diagnostic = null;
        try std.testing.expectError(error.Interrupted, run(&state, source, &diagnostic));
        try equal(@as(usize, 3), context.calls);
        try expect(state.failure.?.value.is(.nil));
        try equal(@as(usize, 0), state.top());
        try equal(@as(usize, 0), state.frames.items.len);
        try equal(@as(usize, 0), state.vm_entries);
        state.setHook(null, 0);
        _ = try run(&state, "return 7", &diagnostic);
        try expect(state.get(1).?.equal(.from(.{ .number = 7 })));
    }
}

test "hook interruption closes escaped captured cells before abandoning frames" {
    var state = try State.init(a);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    context = .{ .stop_after = 1 };
    state.setHook(observer, 100);
    state.setCollectionThreshold(0);
    var diagnostic: ?vm.Diagnostic = null;
    try std.testing.expectError(error.Interrupted, run(&state, "local function f() local x={v=9} saved=function() return x.v end while true do end end return f()", &diagnostic));
    try equal(@as(usize, 1), state.top());
    try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
    state.setHook(null, 0);
    state.collect();
    _ = try run(&state, "return saved()", &diagnostic);
    try expect(state.get(2).?.equal(.from(.{ .number = 9 })));
}

// The first callback runs the child once in its own window; later callbacks
// (the child's own instructions are observed too) only count.
fn reenter(state: *State) callconv(.c) c_int {
    context.calls += 1;
    if (context.calls != 1) return 0;
    var diagnostic: ?vm.Diagnostic = null;
    _ = vm.run(state, context.reentry.?, &diagnostic) catch return 1;
    context.reentered = state.get(-1);
    return 0;
}

test "hook callback runs the same state's VM again and the outer result is unchanged" {
    var state = try State.init(a);
    defer state.deinit();
    const child = try compile(&state, "return 7");
    try state.push(.fromFunction(.{ .closure = child })); // a host root for the callback
    context = .{ .reentry = child };
    state.setHook(reenter, 1);
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(&state, "return 10+20", &diagnostic);
    try expect(context.reentered.?.equal(.from(.{ .number = 7 })));
    try expect(context.calls > 1);
    try expect(state.get(-1).?.equal(.from(.{ .number = 30 })));
    try equal(@as(usize, 2), state.top());
    try expect(state.hook_depth == 0 and state.hook_window == null);
    try equal(@as(usize, 0), state.vm_entries);
}

fn allocationCase(allocator: std.mem.Allocator, ast: *const @import("Ast.zig")) !void {
    var state = try State.init(allocator);
    defer state.deinit();
    var compilation: ?compiler.Diagnostic = null;
    const closure = try state.newChunk(try compiler.compile(allocator, &state, ast, "<hook-allocation>", &compilation));
    try state.push(.from(.{ .number = 42 }));
    context = .{ .stop_after = 1 };
    state.setHook(observer, 30);
    var diagnostic: ?vm.Diagnostic = null;
    _ = vm.run(&state, closure, &diagnostic) catch |err| {
        try equal(@as(usize, 1), state.top());
        try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
        try equal(@as(usize, 0), state.frames.items.len);
        try equal(@as(usize, 0), state.vm_entries);
        try expect(state.hook_depth == 0);
        if (err == error.Interrupted) {
            try expect(state.failure.?.value.is(.nil));
            return;
        }
        if (err == error.OutOfMemory) try expect(state.failure.?.value.unpack().string == state.memory_failure);
        return err;
    };
    return error.TestUnexpectedResult;
}

test "hook allocation failures and interruption both restore execution state" {
    var parsed: ?parser.Diagnostic = null;
    var ast = try parser.parseChunk(a, "local function f() while true do local x={} end end return f()", &parsed);
    defer ast.deinit();
    try allocation_failures.checkAll(a, allocationCase, .{&ast});
}

var answer: c_int = 0;
var callback_ok: bool = false;
var callbacks: usize = 0;

fn noop(_: *runtime.State) callconv(.c) c_int {
    return 0;
}
fn roots(state: *runtime.State) callconv(.c) c_int {
    callbacks += 1;
    if (api.nilu_gettop(state) != 0) return 1;
    if (callbacks != 1) return answer;
    if (api.nilu_pushstring(state, "temporary") != .ok or api.nilu_newtable(state) != .ok or api.nilu_newuserdata(state, 16, null) != .ok) return 1;
    if (api.nilu_pushvalue(state, 1) != .ok or api.nilu_pushcclosure(state, noop, 1) != .ok or api.nilu_loadstring(state, "return 8", null) != .ok) return 1;
    const token = state.reserveFailureOrigin() catch return 1;
    state.publishFailureOrigin(token);
    token.record = .{ .kind = .runtime_error, .value = state.get(1).? };
    state.setOrigin(state.base(), token);
    state.collect();
    if (api.nilu_type(state, 1) != 4 or api.nilu_type(state, 2) != 5 or api.nilu_type(state, 3) != 6 or api.nilu_type(state, 4) != 2 or api.nilu_type(state, 5) != 2) return 1;
    const closure = state.get(4).?.unpack().c_closure;
    if (!std.mem.eql(u8, closure.upvalues[0].unpack().string.bytes, "temporary")) return 1;
    callback_ok = true;
    return answer;
}
fn prepare(state: *runtime.State) !*runtime.Closure {
    var diagnostic: ?loader.Diagnostic = null;
    const chunk = try loader.prepare(state, "return 1+2", "=window", &diagnostic);
    state.barrier(&state.globals.header);
    try state.globals.set(a, .from(.{ .string = try state.newString("held_chunk") }), .fromFunction(.{ .closure = chunk }));
    return chunk;
}

test "hook_window temporary strings tables userdata closures and origins are roots only while needed" {
    for ([_]c_int{ 0, -1 }) |stop| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        const chunk = try prepare(&state);
        try state.push(.from(.{ .number = 42 }));
        try state.ensureOrigins(1);
        const caller_origin = try state.reserveFailureOrigin();
        state.publishFailureOrigin(caller_origin);
        caller_origin.record = .{ .kind = .type_error, .value = .from(.{ .number = 42 }) };
        state.setOrigin(0, caller_origin);
        state.collect();
        const baseline = state.object_count;
        answer = stop;
        callbacks = 0;
        callback_ok = false;
        api.nilu_sethook(&state, roots, 1);
        var diagnostic: ?vm.Diagnostic = null;
        if (stop == 0) {
            _ = try vm.run(&state, chunk, &diagnostic);
            try equal(@as(usize, 2), state.top());
            try equal(@as(f64, 3), state.get(-1).?.numberValue().?);
        } else {
            try std.testing.expectError(error.Interrupted, vm.run(&state, chunk, &diagnostic));
            try equal(@as(usize, 1), state.top());
        }
        try expect(callback_ok);
        try expect(state.originAt(0) == caller_origin);
        try expect(state.hook_window == null and state.hook_depth == 0);
        for (state.origins.items[1..]) |origin| try expect(origin == null);
        state.collect();
        try equal(baseline, state.object_count);
        try equal(@as(f64, 42), state.get(1).?.numberValue().?);
    }
}

fn pushNumber(state: *runtime.State) callconv(.c) c_int {
    callback_ok = api.nilu_gettop(state) == 0 and api.nilu_pushnumber(state, 99) == .ok;
    return answer;
}
test "hook_window entry and cleanup allocate nothing and preserve caller even when allocator refuses" {
    for ([_]c_int{ 0, -1 }) |stop| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        try state.push(.from(.{ .number = 42 }));
        try runtime.growStack(&state.stack, state.open_cells.items, state.allocator, 16);
        try state.ensureOrigins(16);
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
        const saved = state.allocator;
        defer state.allocator = saved;
        state.allocator = failing.allocator();
        answer = stop;
        callback_ok = false;
        api.nilu_sethook(&state, pushNumber, 1);
        try expect(!state.hookStep());
        try equal(stop != 0, state.hookStep());
        try expect(callback_ok);
        try equal(@as(usize, 0), failing.alloc_index);
        try equal(@as(usize, 1), state.top());
        try equal(@as(f64, 42), state.get(1).?.numberValue().?);
        try expect(state.hook_window == null and state.hook_depth == 0);
    }
}

fn captured(state: *runtime.State) callconv(.c) c_int {
    callbacks += 1;
    if (api.nilu_gettop(state) != 0) return 1;
    if (callbacks != 1) return answer;
    if (api.nilu_pushstring(state, "captured temporary") != .ok) return 1;
    const cell = state.capture(state.base()) catch return 1;
    const prototype = state.newPrototype(&.{}) catch return 1;
    prototype.upvalue_count = 1;
    const closure = state.newClosure(prototype, &.{cell}) catch return 1;
    const key = state.newString("escaped") catch return 1;
    state.barrier(&state.globals.header);
    state.globals.set(state.allocator, .from(.{ .string = key }), .fromFunction(.{ .closure = closure })) catch return 1;
    state.collect();
    callback_ok = cell.storage == .open;
    return answer;
}
test "hook_window cleanup closes escaped temporary cells without closing caller cells" {
    for ([_]c_int{ 0, 1 }) |stop| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        const chunk = try prepare(&state);
        try state.push(.from(.{ .number = 42 }));
        const caller_cell = try state.capture(0);
        const prototype = try state.newPrototype(&.{});
        prototype.upvalue_count = 1;
        const caller = try state.newClosure(prototype, &.{caller_cell});
        state.barrier(&state.globals.header);
        try state.globals.set(a, .from(.{ .string = try state.newString("caller") }), .fromFunction(.{ .closure = caller }));
        answer = stop;
        callbacks = 0;
        callback_ok = false;
        api.nilu_sethook(&state, captured, 1);
        var diagnostic: ?vm.Diagnostic = null;
        if (stop == 0) _ = try vm.run(&state, chunk, &diagnostic) else try std.testing.expectError(error.Interrupted, vm.run(&state, chunk, &diagnostic));
        try expect(callback_ok);
        try expect(caller_cell.storage == .open);
        try equal(@as(f64, 42), state.readCell(caller_cell).numberValue().?);
        state.collect();
        const escaped = state.globals.getString("escaped").unpack().closure.upvalues[0];
        try expect(escaped.storage == .closed);
        try std.testing.expectEqualStrings("captured temporary", escaped.storage.closed.unpack().string.bytes);
        try expect(state.hook_window == null and state.hook_depth == 0);
    }
}
