const std = @import("std");
const allocation_failures = @import("allocation_failures.zig");
const runtime = @import("runtime.zig");
const api = @import("c_api.zig");
const transport = @import("failure_transport.zig");
const loader = @import("loader.zig");
const vm = @import("vm.zig");
const a = std.testing.allocator;
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
extern fn test_failure_relay(*runtime.State) callconv(.c) c_int;
extern fn test_failure_copy(*runtime.State) callconv(.c) c_int;
extern fn test_failure_new_same(*runtime.State) callconv(.c) c_int;
extern fn test_failure_bare(*runtime.State) callconv(.c) c_int;
var operation: runtime.Native = test_failure_relay;
var protected: bool = false;
fn wrapper(state: *runtime.State) callconv(.c) c_int {
    if (api.nilu_pushvalue(state, 1) != .ok) return -1;
    var diagnostic: ?vm.Diagnostic = null;
    const result = transport.call(state, 0, protected, &diagnostic) catch return -1;
    if (result != .failure) return -1;
    state.collect();
    return operation(state);
}
fn prepare(state: *runtime.State, source: []const u8) !*runtime.Closure {
    var diagnostic: ?loader.Diagnostic = null;
    return loader.prepare(state, source, "=origin", &diagnostic);
}

test "failure_transport C relay and stack copies retain Type and the inner source instruction" {
    for ([_]runtime.Native{ test_failure_relay, test_failure_copy }) |callback| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        operation = callback;
        protected = false;
        state.barrier(&state.globals.header);
        try state.globals.set(a, .from(.{ .string = try state.newString("wrapper") }), .fromFunction(.{ .native = wrapper }));
        const closure = try prepare(&state, "local function inner()\n return 1+nil\nend\nreturn wrapper(inner)");
        try state.push(.from(.{ .number = 42 }));
        state.setCollectionThreshold(0);
        var diagnostic: ?vm.Diagnostic = null;
        try std.testing.expectError(error.Type, vm.run(&state, closure, &diagnostic));
        try equal(runtime.FailureKind.type_error, state.failure.?.kind);
        try equal(@as(usize, 2), diagnostic.?.position.line);
        try equal(.binary, diagnostic.?.operation);
        try equal(diagnostic.?.position, state.failure.?.position.?);
        try equal(@as(usize, 1), state.top());
        try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
        try expect(state.execution == null);
        try equal(@as(usize, 0), state.frames.items.len);
    }
}

test "failure_transport new same-valued raise bare failure and protected capture are Runtime" {
    for ([_]struct { callback: runtime.Native, caught: bool }{
        .{ .callback = test_failure_new_same, .caught = false },
        .{ .callback = test_failure_bare, .caught = false },
        .{ .callback = test_failure_relay, .caught = true },
    }) |case| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        operation = case.callback;
        protected = case.caught;
        state.barrier(&state.globals.header);
        try state.globals.set(a, .from(.{ .string = try state.newString("wrapper") }), .fromFunction(.{ .native = wrapper }));
        var diagnostic: ?vm.Diagnostic = null;
        try std.testing.expectError(error.Runtime, vm.run(&state, try prepare(&state, "return wrapper(function() return 1+nil end)"), &diagnostic));
        try equal(runtime.FailureKind.runtime_error, state.failure.?.kind);
        if (case.callback == test_failure_bare) try expect(state.failure.?.value.is(.nil)) else try std.testing.expectEqualStrings("origin:1: attempt to perform arithmetic on a nil value", state.failure.?.value.unpack().string.bytes);
    }
}

fn seed(state: *runtime.State, value: runtime.Value) !void {
    try state.push(value);
    const token = try state.reserveFailureOrigin();
    state.publishFailureOrigin(token);
    token.record = .{ .kind = .type_error, .value = value, .origin = .vm };
    state.setOrigin(state.stack.items.len - 1, token);
}

test "failure_transport equal message bytes do not identify a failure origin" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    const string = try state.newString("same words");
    try seed(&state, .from(.{ .string = string }));
    _ = test_failure_relay(&state);
    try equal(runtime.FailureKind.type_error, state.failure.?.kind);
    _ = test_failure_new_same(&state);
    try equal(runtime.FailureKind.runtime_error, state.failure.?.kind);
    try std.testing.expectEqualStrings("same words", state.failure.?.value.unpack().string.bytes);
    try expect(state.failure.?.value.unpack().string != string);
    state.failure = null;
    try equal(api.Status.ok, api.nilu_pushvalue(&state, 1));
    _ = test_failure_relay(&state);
    try equal(runtime.FailureKind.type_error, state.failure.?.kind);
}

test "failure_transport table and C upvalue storage remove provenance while nonconverting reads retain it" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    const text = try state.newString("original");
    try seed(&state, .from(.{ .string = text }));
    var length: usize = 0;
    _ = api.nilu_tolstring(&state, 1, &length);
    try expect(state.originAt(0) != null);
    const table = try state.newTable();
    try state.push(.from(.{ .table = table }));
    state.barrier(&table.header);
    try table.set(a, .from(.{ .number = 1 }), state.get(1).?);
    try state.push(table.get(.from(.{ .number = 1 })));
    try expect(state.originAt(state.stack.items.len - 1) == null);
    _ = test_failure_relay(&state);
    try equal(runtime.FailureKind.runtime_error, state.failure.?.kind);
    try equal(api.Status.ok, api.nilu_pushvalue(&state, 1));
    try equal(api.Status.ok, api.nilu_pushcclosure(&state, test_failure_bare, 1));
    try expect(state.originAt(state.stack.items.len - 1) == null);
}

test "failure_transport number conversion slot reuse and successful calls cannot leak old origins" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try seed(&state, .from(.{ .number = 17 }));
    _ = api.nilu_tolstring(&state, 1, null);
    try expect(state.originAt(0) == null);
    _ = test_failure_relay(&state);
    try equal(runtime.FailureKind.runtime_error, state.failure.?.kind);
    try equal(api.Status.ok, api.nilu_settop(&state, 0));
    try equal(api.Status.ok, api.nilu_pushnumber(&state, 8));
    try expect(state.originAt(0) == null);
    try state.push(.fromFunction(.{ .closure = try prepare(&state, "return 9") }));
    var diagnostic: ?vm.Diagnostic = null;
    try equal(@as(usize, 1), (try transport.call(&state, 0, false, &diagnostic)).success);
    try expect(state.originAt(1) == null);
    try expect(state.failure == null);
    try expect(state.get(1).?.equal(.from(.{ .number = 8 })));
    try expect(state.get(2).?.equal(.from(.{ .number = 9 })));
}

fn stop(_: *runtime.State) callconv(.c) c_int {
    return 1;
}
test "failure_transport interruption bypasses protected capture and retains nil and Interrupted" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    try state.push(.fromFunction(.{ .closure = try prepare(&state, "while true do end") }));
    state.setHook(stop, 1);
    var diagnostic: ?vm.Diagnostic = null;
    try equal(runtime.FailureKind.interrupted, (try transport.call(&state, 0, true, &diagnostic)).failure);
    try expect(state.get(-1).?.is(.nil));
    try expect(state.originAt(1) != null);
    try equal(runtime.FailureKind.interrupted, state.failure.?.kind);
    _ = api.nilu_error(&state);
    try equal(runtime.FailureKind.interrupted, state.failure.?.kind);
    try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var state = try runtime.State.init(allocator);
    defer state.deinit();
    const closure = try prepare(&state, "return 1+nil");
    try state.push(.from(.{ .number = 42 }));
    try state.push(.fromFunction(.{ .closure = closure }));
    var diagnostic: ?vm.Diagnostic = null;
    const result = transport.call(&state, 0, false, &diagnostic) catch |err| {
        try equal(@as(usize, 2), state.top());
        try expect(state.get(2).?.unpack().closure == closure);
        try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
        try expect(state.execution == null);
        return err;
    };
    try equal(@as(usize, 2), state.top());
    try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
    try expect(state.originAt(1) != null);
    state.collect();
    if (result.failure == .out_of_memory) {
        try expect(state.get(2).?.unpack().string == state.memory_failure);
        _ = api.nilu_error(&state);
        try equal(runtime.FailureKind.out_of_memory, state.failure.?.kind);
        return error.OutOfMemory;
    }
    try equal(runtime.FailureKind.type_error, result.failure);
    try expect(state.execution == null);
    try equal(@as(usize, 0), state.frames.items.len);
}
test "failure_transport all allocation failures preserve setup inputs or publish a rooted memory failure" {
    try allocation_failures.checkAll(a, allocationCase, .{});
}

test "failure_transport copied tokens remain immutable and are collected after their last slot is dropped" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    const baseline = state.object_count;
    try seed(&state, .from(.{ .string = try state.newString("one") }));
    try equal(api.Status.ok, api.nilu_pushvalue(&state, 1));
    const first = state.originAt(0).?;
    try seed(&state, .from(.{ .string = try state.newString("two") }));
    try expect(state.originAt(2).? != first);
    state.collect();
    try equal(baseline + 4, state.object_count);
    try std.testing.expectEqualStrings("one", first.record.value.unpack().string.bytes);
    try equal(api.Status.ok, api.nilu_settop(&state, 1));
    state.collect();
    try equal(baseline + 2, state.object_count);
    try equal(api.Status.ok, api.nilu_settop(&state, 0));
    state.collect();
    try equal(baseline, state.object_count);
}

fn callable(state: *runtime.State, terminal: runtime.Value) !runtime.Value {
    const value = runtime.Value.from(.{ .table = try state.newTable() });
    const meta = try state.newTable();
    state.barrier(&meta.header);
    try meta.set(a, .from(.{ .string = try state.newString("__call") }), terminal);
    try state.setMetatable(value, meta);
    return value;
}
fn arguments(state: *runtime.State) callconv(.c) c_int {
    state.collect();
    return @intCast(state.top());
}
test "failure_transport callable chains preserve receiver order and fixed result adjustment" {
    for ([_]?usize{ null, 0, 1, 5 }) |requested| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        const inner = try callable(&state, .fromFunction(.{ .native = arguments }));
        const outer = try callable(&state, inner);
        try state.push(.from(.{ .number = 42 }));
        try state.push(outer);
        try state.push(.from(.{ .number = 7 }));
        var diagnostic: ?vm.Diagnostic = null;
        const wanted = requested orelse 3;
        try equal(wanted, (try transport.callAdjusted(&state, 1, requested, true, null, &diagnostic)).success);
        try equal(wanted + 1, state.top());
        try equal(@as(f64, 42), state.get(1).?.numberValue().?);
        const values = [_]runtime.Value{ inner, outer, .from(.{ .number = 7 }), .nil, .nil };
        for (values[0..wanted], 0..) |value, i| try expect(state.get(@intCast(i + 2)).?.equal(value));
        try expect(state.execution == null and state.frames.items.len == 0);
    }
}

test "failure_transport invalid callable values publish Type and protected capture strips origin" {
    for ([_]bool{ false, true }) |caught| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        try state.push(.from(.{ .number = 42 }));
        try state.push(try callable(&state, .from(.{ .boolean = false })));
        var diagnostic: ?vm.Diagnostic = null;
        try equal(runtime.FailureKind.type_error, (try transport.call(&state, 0, caught, &diagnostic)).failure);
        try equal(@as(usize, 2), state.top());
        try std.testing.expectEqualStrings("attempt to call a boolean value", state.get(2).?.unpack().string.bytes);
        try equal(!caught, state.originAt(1) != null);
        if (!caught) try expect(state.failure.?.position == null);
        state.collect();
        try equal(@as(f64, 42), state.get(1).?.numberValue().?);
    }
}

test "failure_transport callable script errors retain their original source and handler sees the failure" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try state.push(try callable(&state, .fromFunction(.{ .closure = try prepare(&state, "return 1+nil") })));
    var diagnostic: ?vm.Diagnostic = null;
    const handler = runtime.Value.fromFunction(.{ .native = arguments });
    try equal(runtime.FailureKind.type_error, (try transport.callWithHandler(&state, 0, true, handler, &diagnostic)).failure);
    try std.testing.expectEqualStrings("origin:1: attempt to perform arithmetic on a nil value", state.get(1).?.unpack().string.bytes);
    try equal(@as(usize, 1), diagnostic.?.position.line);
    try expect(state.originAt(0) == null);
}

fn callableAllocationCase(allocator: std.mem.Allocator) !void {
    var state = try runtime.State.init(allocator);
    defer state.deinit();
    const value = runtime.Value.from(.{ .table = try state.newTable() });
    const meta = try state.newTable();
    state.barrier(&meta.header);
    try meta.set(allocator, .from(.{ .string = try state.newString("__call") }), .fromFunction(.{ .closure = try prepare(&state, "return 8") }));
    try state.setMetatable(value, meta);
    try state.push(.from(.{ .number = 42 }));
    try state.push(value);
    var diagnostic: ?vm.Diagnostic = null;
    const result = transport.call(&state, 0, true, &diagnostic) catch |err| {
        try equal(@as(usize, 2), state.top());
        try expect(state.get(2).?.equal(value));
        return err;
    };
    try equal(@as(f64, 42), state.get(1).?.numberValue().?);
    try expect(state.execution == null and state.frames.items.len == 0);
    state.collect();
    if (result == .failure) {
        try equal(runtime.FailureKind.out_of_memory, result.failure);
        try expect(state.get(2).?.unpack().string == state.memory_failure);
        return error.OutOfMemory;
    }
    try equal(@as(f64, 8), state.get(2).?.numberValue().?);
}
test "failure_transport callable setup and relay allocation failures preserve caller and release roots" {
    try allocation_failures.checkAll(a, callableAllocationCase, .{});
}

fn relayLast(state: *runtime.State) callconv(.c) c_int {
    return api.nilu_error(state);
}
test "failure_transport callable receiver insertion preserves the explicit argument failure origin" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try state.push(try callable(&state, .fromFunction(.{ .native = relayLast })));
    try seed(&state, .from(.{ .string = try state.newString("original") }));
    var diagnostic: ?vm.Diagnostic = null;
    try equal(runtime.FailureKind.type_error, (try transport.call(&state, 1, false, &diagnostic)).failure);
    try std.testing.expectEqualStrings("original", state.get(1).?.unpack().string.bytes);
}

test "failure_transport cyclic callable refusal uses the shared budget and publishes one Runtime value" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    const value = try callable(&state, .nil);
    try value.unpack().table.metatable.?.set(a, .from(.{ .string = try state.newString("__call") }), value);
    try state.push(.from(.{ .number = 42 }));
    try state.push(value);
    var diagnostic: ?vm.Diagnostic = null;
    try equal(runtime.FailureKind.runtime_error, (try transport.call(&state, 0, true, &diagnostic)).failure);
    try equal(@as(usize, 2), state.top());
    try std.testing.expectEqualStrings("'__call' chain too long", state.get(2).?.unpack().string.bytes);
    try expect(state.originAt(1) == null);
    try expect(state.execution == null and state.frames.items.len == 0);
}

test "failure_transport callable userdata and script terminals share results and preflight capacity refusal" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    const value = runtime.Value.from(.{ .userdata = try state.newUserdata(0) });
    const meta = try state.newTable();
    state.barrier(&meta.header);
    try meta.set(a, .from(.{ .string = try state.newString("__call") }), .fromFunction(.{ .closure = try prepare(&state, "local self,x=... return self,x,nil") }));
    try state.setMetatable(value, meta);
    try state.push(.from(.{ .number = 42 }));
    try state.push(value);
    try state.push(.from(.{ .number = 7 }));
    var diagnostic: ?vm.Diagnostic = null;
    try std.testing.expectError(error.StackLimit, transport.callAdjusted(&state, 1, runtime.State.max_stack, true, null, &diagnostic));
    try equal(@as(usize, 3), state.top());
    try expect(state.get(2).?.equal(value));
    try equal(@as(usize, 3), (try transport.call(&state, 1, true, &diagnostic)).success);
    try expect(state.get(2).?.equal(value));
    try equal(@as(f64, 7), state.get(3).?.numberValue().?);
    try expect(state.get(4).?.is(.nil));
}

test "failure_transport a call that publishes no failure allocates nothing once the state has warmed up" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try equal(api.Status.ok, api.nilu_openlibs(state));
    // `run` is a function with fixed parameters, which makes no table for
    // its arguments, and `f` is a global, so that `run` makes no closure.
    try equal(api.Status.ok, api.nilu_loadstring(state, "f = function(x) return x end run = function() for i = 1, 50 do pcall(f, i) pcall(error, i) end end", null));
    try equal(api.Status.ok, api.nilu_call(state, 0, 0));
    // The first run grows the state's own lists and prepares `run`.
    _ = api.nilu_getglobal(state, "run");
    try equal(api.Status.ok, api.nilu_call(state, 0, 0));
    _ = api.nilu_getglobal(state, "run");
    // Every allocation now fails: a call that reserved a new failure origin
    // each time would end in a memory failure. A failure caught by pcall
    // publishes nothing either.
    const saved = state.allocator;
    defer state.allocator = saved;
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    state.allocator = failing.allocator();
    try equal(api.Status.ok, api.nilu_call(state, 0, 0));
    try equal(@as(usize, 0), failing.allocations);
}

test "failure_transport a script's pcall runs its callee among the script's frames and answers as lua5.5 does" {
    // The answers are lua5.5's, the chunk named "t" there as here. Each
    // line is one case: results, failures with and without a position, a
    // failure value's identity, nesting, a tail call in the callee, a pcall
    // inside xpcall whose handler must not run, to-be-closed variables,
    // stack overflow, a coroutine yielding inside pcall and failing after a
    // resume, a C function's failure, and a non-callable.
    const state = try api.create(a);
    defer api.nilu_close(state);
    try equal(api.Status.ok, api.nilu_openlibs(state));
    try equal(api.Status.ok, api.nilu_loadnamed(state,
        \\local out = {}
        \\local function put(...) local t = table.pack(...) for i = 1, t.n do t[i] = tostring(t[i]) end out[#out + 1] = table.concat(t, ",") end
        \\local function ok(...) return ... end
        \\local function bad(v) error(v) end
        \\local function bad0(v) error(v, 0) end
        \\put(pcall(ok, 1, 2, 3))
        \\put(pcall(ok))
        \\put(select("#", pcall(ok)))
        \\put(pcall(bad0, "plain"))
        \\put(pcall(bad, "with position"))
        \\local e = {}
        \\local s, v = pcall(bad, e) put(s, v == e)
        \\put(pcall(function() local x = nil; return x.y end))
        \\put(pcall(function() return 1 + {} end))
        \\local x = pcall(bad0, "target") put(x)
        \\local a, b = pcall(ok, 7) put(a, b)
        \\-- nested
        \\put(pcall(function() local r1, r2 = pcall(bad0, "inner") return "outer", r1, r2 end))
        \\-- tail call inside the callee
        \\put(pcall(function() return ok(4, 5) end))
        \\-- pcall inside xpcall: the handler must not see the inner failure
        \\put(xpcall(function() local r1, r2 = pcall(bad0, "caught") return r1, r2 end, function(m) return "handled " .. tostring(m) end))
        \\put(xpcall(function() pcall(bad0, "caught") error("after", 0) end, function(m) return "handled " .. tostring(m) end))
        \\-- to-be-closed variables close on failure
        \\local log = {}
        \\put(pcall(function()
        \\  local c <close> = setmetatable({}, {__close = function(_, err) log[#log + 1] = "closed " .. tostring(err) end})
        \\  error("tbc", 0)
        \\end))
        \\put(table.concat(log, ";"))
        \\-- stack overflow inside pcall
        \\local function r() return 1 + r() end
        \\local so, sm = pcall(r) put(so, (tostring(sm):gsub("^.-:%d+: ", "")))
        \\-- coroutine yielding inside pcall
        \\local co = coroutine.create(function(n)
        \\  local okc, got = pcall(function(m) local y = coroutine.yield(m + 1) return y * 2 end, n)
        \\  local okd, msg = pcall(function() coroutine.yield("again") error("after resume", 0) end)
        \\  return okc, got, okd, msg
        \\end)
        \\put(coroutine.resume(co, 10))
        \\put(coroutine.resume(co, 21))
        \\put(coroutine.resume(co))
        \\-- error in a pcall whose callee calls a C function that fails
        \\put(pcall(function() return string.rep() end))
        \\-- repeated catches in a loop
        \\local count = 0
        \\for i = 1, 100 do if not pcall(bad0, i) then count = count + 1 end end
        \\put(count)
        \\-- pcall of pcall
        \\put(pcall(pcall, bad0, "deep"))
        \\-- non-function
        \\put(pcall(nil))
        \\put(pcall(42))
        \\-- varargs callee
        \\put(pcall(function(...) return select("#", ...), ... end, nil, nil))
        \\-- error with a table value and its identity across nested pcalls
        \\local t = {}
        \\put(select(2, pcall(function() local _, v2 = pcall(error, t) error(v2) end)) == t)
        \\return table.concat(out, "\n")
    , "=t", null));
    try equal(api.Status.ok, api.nilu_pcall(state, 0, 1, 0));
    try std.testing.expectEqualStrings(
        \\true,1,2,3
        \\true
        \\1
        \\false,plain
        \\false,t:4: with position
        \\false,true
        \\false,t:13: attempt to index a nil value (local 'x')
        \\false,t:14: attempt to perform arithmetic on a table value
        \\false
        \\true,7
        \\true,outer,false,inner
        \\true,4,5
        \\true,false,caught
        \\false,handled after
        \\false,tbc
        \\closed tbc
        \\false,stack overflow
        \\true,11
        \\true,again
        \\true,true,42,false,after resume
        \\false,t:44: bad argument #1 to 'rep' (string expected, got no value)
        \\100
        \\true,false,deep
        \\false,attempt to call a nil value
        \\false,attempt to call a number value
        \\true,2,nil,nil
        \\true
    , std.mem.span(api.nilu_tolstring(state, -1, null).?));
}

fn inChainProbe(state: *runtime.State) callconv(.c) c_int {
    // Frames: the chunk, the `pcall` frame, the callee, this function.
    const frames = state.frames.items;
    const marked = frames.len >= 3 and frames[frames.len - 3].protected_call;
    _ = api.nilu_pushboolean(state, @intFromBool(marked));
    return 1;
}

test "failure_transport a script's pcall of a script function stands for it with a marked frame, not a host call" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try equal(api.Status.ok, api.nilu_openlibs(state));
    try equal(api.Status.ok, api.nilu_pushcfunction(state, inChainProbe));
    try equal(api.Status.ok, api.nilu_setglobal(state, "probe"));
    try equal(api.Status.ok, api.nilu_loadstring(state, "return select(2, pcall(function() return probe() end))", null));
    try equal(api.Status.ok, api.nilu_pcall(state, 0, 1, 0));
    try expect(api.nilu_toboolean(state, -1) != 0);
}

test "failure_transport a call site that met a C function and then meets a script function or pcall takes each one's way" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try equal(api.Status.ok, api.nilu_openlibs(state));
    try equal(api.Status.ok, api.nilu_pushcfunction(state, inChainProbe));
    try equal(api.Status.ok, api.nilu_setglobal(state, "probe"));
    // One call instruction, `local x = f(...)`, run three times: a C
    // function, then a script function, then the library's `pcall`, which
    // must still stand for its callee with a marked frame.
    try equal(api.Status.ok, api.nilu_loadstring(state,
        \\local out = {}
        \\local callees = {tostring, function(v) return "script " .. v end, pcall}
        \\local marked
        \\local arguments = {7, 8, function() marked = probe() end}
        \\for i = 1, 3 do
        \\  local f = callees[i]
        \\  local x = f(arguments[i])
        \\  out[i] = tostring(x)
        \\end
        \\local first = tostring(marked)
        \\-- `pcall` straight after a C function, with no other kind between.
        \\marked = nil
        \\local direct = {tostring, pcall}
        \\local given = {9, function() marked = probe() end}
        \\for i = 1, 2 do
        \\  local f = direct[i]
        \\  local x = f(given[i])
        \\  out[#out + 1] = tostring(x)
        \\end
        \\return table.concat(out, ",") .. "," .. first .. "," .. tostring(marked)
    , null));
    try equal(api.Status.ok, api.nilu_pcall(state, 0, 1, 0));
    try std.testing.expectEqualStrings("7,script 8,true,9,true,true,true", std.mem.span(api.nilu_tolstring(state, -1, null).?));
}

test "failure_transport a script's tail call of a C function answers as lua5.5 does" {
    // The answers are lua5.5's, the chunk named "t" there as here: zero,
    // one and several results, into a call that wants one or two, a C
    // function's failure, inside `pcall`, into a call that counts them, a
    // yield in tail position resumed, and a raw access.
    const state = try api.create(a);
    defer api.nilu_close(state);
    try equal(api.Status.ok, api.nilu_openlibs(state));
    try equal(api.Status.ok, api.nilu_loadnamed(state,
        \\local out = {}
        \\local function put(...) local t = table.pack(...) for i = 1, t.n do t[i] = tostring(t[i]) end out[#out + 1] = table.concat(t, ",") end
        \\local function one(x) return tostring(x) end
        \\local function many() return string.byte("abc", 1, 3) end
        \\local function none() return select(2) end
        \\local function bad() return string.rep() end
        \\local function sel(...) return select("#", ...) end
        \\put(one(5)) put(many()) put(none()) put(select("#", none()))
        \\local a = one(6) put(a)
        \\local x, y = many() put(x, y)
        \\local first = many() put(first)
        \\put(pcall(bad))
        \\put(pcall(function() return tostring(7) end))
        \\put(pcall(function() return string.byte("xy", 1, 2) end))
        \\put(sel(many()))
        \\local co = coroutine.wrap(function(v) local function f(w) return coroutine.yield(w + 1) end local r = f(v) return r * 2 end)
        \\put(co(1)) put(co(20))
        \\local co2 = coroutine.wrap(function() local function g() return coroutine.yield("a", "b") end return g() end)
        \\put(co2()) put(co2("c", "d"))
        \\local t = setmetatable({}, {__index = function(_, k) return tostring(k) end})
        \\local function viaIndex() return rawget(t, "k") end
        \\put(viaIndex())
        \\return table.concat(out, "\n")
    , "=t", null));
    try equal(api.Status.ok, api.nilu_pcall(state, 0, 1, 0));
    try std.testing.expectEqualStrings(
        \\5
        \\97,98,99
        \\
        \\0
        \\6
        \\97,98
        \\97
        \\false,t:6: bad argument #1 to 'rep' (string expected, got no value)
        \\true,7
        \\true,120,121
        \\3
        \\2
        \\40
        \\a,b
        \\c,d
        \\nil
    , std.mem.span(api.nilu_tolstring(state, -1, null).?));
}
