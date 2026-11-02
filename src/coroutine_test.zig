//! Coroutines (ADR 0013): what a collection may and may not free while
//! threads are suspended, and the C API's statuses and refusals.
const std = @import("std");
const api = @import("c_api.zig");
const runtime = @import("runtime.zig");
const a = std.testing.allocator;

fn opened() !*runtime.State {
    const state = try api.create(a);
    errdefer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_openlibs(state));
    return state;
}

fn run(state: *runtime.State, source: [:0]const u8) ![]const u8 {
    _ = api.nilu_settop(state, 0);
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state, source, "=t", null));
    _ = api.nilu_pcall(state, 0, 1, 0);
    return std.mem.span(api.nilu_tolstring(state, -1, null) orelse "(not a string)");
}

test "coroutine a collection between resumes keeps a suspended coroutine's stack and shared upvalues" {
    const state = try opened();
    defer api.nilu_close(state);
    _ = try run(state,
        \\co = coroutine.create(function()
        \\  local x = {name = "kept"}
        \\  get = function() return x.name end
        \\  set = function(v) x = {name = v} end
        \\  coroutine.yield()
        \\  return x.name .. "!"
        \\end)
        \\coroutine.resume(co)
        \\return ""
    );
    _ = api.nilu_settop(state, 0);
    state.collect();
    try std.testing.expectEqualStrings("kept", try run(state, "return get()"));
    _ = try run(state, "set('changed') return ''");
    state.collect();
    try std.testing.expectEqualStrings("changed!", try run(state, "return select(2, coroutine.resume(co))"));
    try std.testing.expectEqualStrings("changed", try run(state, "return get()"));
}

test "coroutine an escaped closure keeps a dropped suspended coroutine's stack" {
    const state = try opened();
    defer api.nilu_close(state);
    _ = try run(state,
        \\local co = coroutine.create(function()
        \\  local x = "on the coroutine's stack"
        \\  read = function() return x end
        \\  coroutine.yield()
        \\end)
        \\coroutine.resume(co)
        \\return ""
    );
    _ = api.nilu_settop(state, 0);
    state.collect();
    state.collect();
    try std.testing.expectEqualStrings("on the coroutine's stack", try run(state, "return read()"));
}

test "coroutine unreachable suspended coroutines are freed with their open upvalues" {
    const state = try opened();
    defer api.nilu_close(state);
    _ = try run(state,
        \\for i = 1, 100 do
        \\  local co = coroutine.create(function()
        \\    local a, b = {i}, {i}
        \\    local f = function() return a[1] + b[1] end
        \\    coroutine.yield(f)
        \\  end)
        \\  coroutine.resume(co)
        \\end
        \\return ""
    );
    _ = api.nilu_settop(state, 0);
    const before = state.object_count;
    state.collect();
    try std.testing.expect(state.object_count < before);
    // The state still runs, and new coroutines still capture.
    try std.testing.expectEqualStrings("7", try run(state,
        \\local co = coroutine.wrap(function() local n = 3 local f = function() return n end coroutine.yield() return f() + 4 end)
        \\co()
        \\collectgarbage()
        \\return tostring(co())
    ));
}

test "coroutine a resume nested past the call limit fails as a stack overflow" {
    const state = try opened();
    defer api.nilu_close(state);
    try std.testing.expectEqualStrings("true", try run(state,
        \\local function down(n)
        \\  local co = coroutine.create(function() return down(n + 1) end)
        \\  local ok, message = coroutine.resume(co)
        \\  if not ok then error(message, 0) end
        \\  return message
        \\end
        \\local ok, message = pcall(down, 1)
        \\return tostring(not ok and message:find("stack overflow") ~= nil)
    ));
}

fn yieldNow(state: *runtime.State) callconv(.c) c_int {
    return api.nilu_yield(state, api.nilu_gettop(state));
}

fn callYielding(state: *runtime.State) callconv(.c) c_int {
    // A yield under nilu_call is refused; the refusal is this call's failure.
    _ = api.nilu_getglobal(state, "yield_now");
    if (api.nilu_call(state, 0, 0) != .ok) return api.nilu_error(state);
    return 0;
}

test "coroutine the C API resumes, yields and reports statuses" {
    const state = try opened();
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushcfunction(state, yieldNow));
    try std.testing.expectEqual(api.Status.ok, api.nilu_setglobal(state, "yield_now"));
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushcfunction(state, callYielding));
    try std.testing.expectEqual(api.Status.ok, api.nilu_setglobal(state, "call_yielding"));
    _ = api.nilu_settop(state, 0);

    // A value that is not a function makes no thread.
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushnumber(state, 1));
    try std.testing.expectEqual(api.Status.type, api.nilu_newthread(state));
    try std.testing.expectEqual(@as(c_int, -1), api.nilu_threadstatus(state, 1));
    _ = api.nilu_settop(state, 0);

    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state, "local a = yield_now(1, 2) return a * 10", "=t", null));
    try std.testing.expectEqual(api.Status.ok, api.nilu_newthread(state));
    try std.testing.expectEqual(@as(c_int, 0), api.nilu_threadstatus(state, 1));
    try std.testing.expectEqual(@as(c_int, 1), api.nilu_isyieldable(state, 1));
    var count: c_int = -1;
    try std.testing.expectEqual(api.Status.yielded, api.nilu_resume(state, 1, 0, &count));
    try std.testing.expectEqual(@as(c_int, 2), count);
    try std.testing.expectEqual(@as(c_int, 3), api.nilu_gettop(state));
    _ = api.nilu_settop(state, 1);
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushnumber(state, 4));
    try std.testing.expectEqual(api.Status.ok, api.nilu_resume(state, 1, 1, &count));
    try std.testing.expectEqual(@as(c_int, 1), count);
    try std.testing.expectEqual(@as(f64, 40), api.nilu_tonumberx(state, -1, null));
    try std.testing.expectEqual(@as(c_int, 3), api.nilu_threadstatus(state, 1));
    _ = api.nilu_settop(state, 1);
    try std.testing.expectEqual(api.Status.runtime, api.nilu_resume(state, 1, 0, &count));
    try std.testing.expectEqualStrings("cannot resume dead coroutine", std.mem.span(api.nilu_tolstring(state, -1, null).?));
    try std.testing.expectEqual(api.Status.ok, api.nilu_closethread(state, 1));

    // The main program cannot yield, and is closed by nobody.
    try std.testing.expectEqual(@as(c_int, 1), api.nilu_pushrunning(state));
    try std.testing.expectEqual(@as(c_int, 0), api.nilu_isyieldable(state, -1));
    try std.testing.expectEqual(api.Status.runtime, api.nilu_closethread(state, -1));
    try std.testing.expectEqualStrings("cannot close main thread", std.mem.span(api.nilu_tolstring(state, -1, null).?));

    // A yield under nilu_call fails the coroutine with Lua's sentence.
    _ = api.nilu_settop(state, 0);
    try std.testing.expectEqual(api.Status.ok, api.nilu_getglobal(state, "call_yielding"));
    try std.testing.expectEqual(api.Status.ok, api.nilu_newthread(state));
    try std.testing.expectEqual(api.Status.runtime, api.nilu_resume(state, 1, 0, &count));
    try std.testing.expectEqualStrings("attempt to yield across a C-call boundary", std.mem.span(api.nilu_tolstring(state, -1, null).?));
    try std.testing.expectEqual(@as(c_int, 3), api.nilu_threadstatus(state, 1));
}

test "coroutine a yield is refused under a message handler and outside a coroutine" {
    const state = try opened();
    defer api.nilu_close(state);
    try std.testing.expectEqualStrings("attempt to yield from outside a coroutine", try run(state, "return select(2, pcall(coroutine.yield))"));
    try std.testing.expectEqualStrings("attempt to yield across a C-call boundary", try run(state,
        \\local co = coroutine.create(function()
        \\  return select(2, xpcall(error, function() local ok, m = pcall(coroutine.yield) return m end, "x"))
        \\end)
        \\return select(2, coroutine.resume(co))
    ));
}

test "coroutine a yield passes pcall and xpcall, which still catch what fails after the resume" {
    const state = try opened();
    defer api.nilu_close(state);
    try std.testing.expectEqualStrings("in|false|t:3: late|handled t:4: boom|true|r", try run(state,
        \\local co = coroutine.wrap(function()
        \\  local a = select(2, pcall(coroutine.yield, "in"))
        \\  local ok, m = pcall(function() coroutine.yield() error("late") end)
        \\  local _, h = xpcall(function() coroutine.yield() error("boom") end, function(e) return "handled " .. e end)
        \\  local ok2, r = pcall(function() return (coroutine.yield()) end)
        \\  return table.concat({a, tostring(ok), m, h, tostring(ok2), r}, "|")
        \\end)
        \\local first = co()
        \\co(first) co() co() collectgarbage()
        \\return co("r")
    ));
}

test "coroutine a yield inside a metamethod finishes its instruction with the result, falsy ones too" {
    const state = try opened();
    defer api.nilu_close(state);
    try std.testing.expectEqualStrings("false true false true nil 0 x", try run(state,
        \\local Y = coroutine.yield
        \\local mt = {__eq = function() return Y() end, __lt = function() return Y() end,
        \\  __index = function() return Y() end, __len = function() return Y() end, __concat = function() return Y() end}
        \\local a, b = setmetatable({}, mt), setmetatable({}, mt)
        \\local co = coroutine.wrap(function()
        \\  return table.concat({tostring(a == b), tostring(a ~= b), tostring(a < b), tostring(not (a < b)), tostring(a.k), tostring(#a), a .. b}, " ")
        \\end)
        \\co() co(false) co(nil) co(false) co(nil) co(nil) co(0)
        \\return co("x")
    ));
}

var continued_status: c_int = -100;
var continued_context: isize = 0;

fn waitingContinuation(state: *runtime.State, status: c_int, context: isize) callconv(.c) c_int {
    continued_status = status;
    continued_context = context;
    return api.nilu_gettop(state);
}

fn callProtected(state: *runtime.State) callconv(.c) c_int {
    const status = api.nilu_pcallk(state, api.nilu_gettop(state) - 1, -1, 0, 42, waitingContinuation);
    if (status == .yielded) return api.nilu_yield(state, 0);
    return waitingContinuation(state, @backingInt(status), 0);
}

test "coroutine nilu_pcallk runs its continuation with the status and the stack nilu_pcall would give" {
    const state = try opened();
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushcfunction(state, callProtected));
    try std.testing.expectEqual(api.Status.ok, api.nilu_setglobal(state, "call_protected"));
    try std.testing.expectEqualStrings("2:a,b", try run(state,
        \\local co = coroutine.wrap(function() return call_protected(function(x) local y = coroutine.yield(x) return x, y end, "a") end)
        \\co()
        \\local p, q = co("b")
        \\return tostring(select("#", p, q)) .. ":" .. p .. "," .. q
    ));
    try std.testing.expectEqual(@as(c_int, @backingInt(api.Status.ok)), continued_status);
    try std.testing.expectEqual(@as(isize, 42), continued_context);
    try std.testing.expectEqualStrings("t:1: after", try run(state,
        \\local co = coroutine.wrap(function() return call_protected(function() coroutine.yield() error("after") end) end)
        \\co()
        \\return (co())
    ));
    try std.testing.expectEqual(@as(c_int, @backingInt(api.Status.runtime)), continued_status);
}

test "coroutine a collection in a coroutine keeps the thread waiting on it when the host consumed that thread's slot" {
    const state = try opened();
    defer api.nilu_close(state);
    // The thread is its own resume's only argument: the host's stack then
    // holds neither it nor, once it resumes the child, anything reaching it.
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state,
        \\local child = coroutine.create(function() collectgarbage("collect") return 7 end)
        \\return coroutine.resume(child)
    , "=t", null));
    try std.testing.expectEqual(api.Status.ok, api.nilu_newthread(state));
    var count: c_int = -1;
    try std.testing.expectEqual(api.Status.ok, api.nilu_resume(state, 1, 1, &count));
    try std.testing.expectEqual(@as(c_int, 2), count);
    try std.testing.expectEqual(@as(c_int, 1), api.nilu_toboolean(state, 1));
    try std.testing.expectEqual(@as(f64, 7), api.nilu_tonumberx(state, 2, null));
}

fn failingContinuation(state: *runtime.State, status: c_int, context: isize) callconv(.c) c_int {
    _ = status;
    _ = context;
    _ = api.nilu_pushstring(state, "continuation failure");
    return api.nilu_error(state);
}

fn bridgeFailing(state: *runtime.State) callconv(.c) c_int {
    const status = api.nilu_pcallk(state, 0, -1, 0, 0, failingContinuation);
    if (status == .yielded) return api.nilu_yield(state, 0);
    return failingContinuation(state, @backingInt(status), 0);
}

test "coroutine a continuation that fails after the resume is caught by the pcall outside its C function" {
    const state = try opened();
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushcfunction(state, bridgeFailing));
    try std.testing.expectEqual(api.Status.ok, api.nilu_setglobal(state, "bridge"));
    // Lua 5.5 answers the same with lua_pcallk.
    try std.testing.expectEqualStrings("true:pause / true:false:continuation failure", try run(state,
        \\local co = coroutine.create(function()
        \\  local ok, e = pcall(function() bridge(function() coroutine.yield("pause") end) end)
        \\  return tostring(ok) .. ":" .. tostring(e)
        \\end)
        \\local a, b = coroutine.resume(co)
        \\local c, d = coroutine.resume(co)
        \\return tostring(a) .. ":" .. tostring(b) .. " / " .. tostring(c) .. ":" .. tostring(d)
    ));
}

/// The second protected call's continuation: the status as a number after
/// what the call left, or, with context 1, a failure of its own.
fn secondContinuation(state: *runtime.State, status: c_int, context: isize) callconv(.c) c_int {
    if (context == 1) {
        _ = api.nilu_pushstring(state, "second continuation failure");
        return api.nilu_error(state);
    }
    _ = api.nilu_pushinteger(state, status);
    return api.nilu_gettop(state);
}

/// The first continuation calls the function left below with nilu_pcallk
/// again; when that yields, the C function waits on the second continuation.
fn firstContinuation(state: *runtime.State, status: c_int, context: isize) callconv(.c) c_int {
    if (status != @backingInt(api.Status.ok)) return api.nilu_error(state);
    const second = api.nilu_pcallk(state, 0, 1, 0, context, secondContinuation);
    if (second == .yielded) return api.nilu_yield(state, 0);
    return secondContinuation(state, @backingInt(second), context);
}

/// bridge_twice(g, f): f under nilu_pcallk, then g from the continuation.
fn bridgeTwice(state: *runtime.State, context: isize) c_int {
    const status = api.nilu_pcallk(state, 0, 0, 0, context, firstContinuation);
    if (status == .yielded) return api.nilu_yield(state, 0);
    return firstContinuation(state, @backingInt(status), context);
}

fn bridgeTwiceAnswering(state: *runtime.State) callconv(.c) c_int {
    return bridgeTwice(state, 0);
}

fn bridgeTwiceFailing(state: *runtime.State) callconv(.c) c_int {
    return bridgeTwice(state, 1);
}

test "coroutine a continuation that calls nilu_pcallk again and yields waits on its own continuation under the outer pcall" {
    const state = try opened();
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushcfunction(state, bridgeTwiceAnswering));
    try std.testing.expectEqual(api.Status.ok, api.nilu_setglobal(state, "bridge_twice"));
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushcfunction(state, bridgeTwiceFailing));
    try std.testing.expectEqual(api.Status.ok, api.nilu_setglobal(state, "bridge_twice_failing"));
    // As lua_pcallk: the second call's failure is its own status, given to
    // the second continuation; that continuation's failure reaches the pcall.
    var expected: [64]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "one|two|true|late|{d}", .{@backingInt(api.Status.runtime)}), try run(state,
        \\local co = coroutine.wrap(function()
        \\  return pcall(bridge_twice, function() coroutine.yield("two") error("late", 0) end, function() coroutine.yield("one") end)
        \\end)
        \\local a = co()
        \\local b = co()
        \\local ok, m, s = co()
        \\return a .. "|" .. b .. "|" .. tostring(ok) .. "|" .. m .. "|" .. tostring(s)
    ));
    try std.testing.expectEqualStrings("one|two|false|second continuation failure|dead", try run(state,
        \\local co = coroutine.create(function()
        \\  return pcall(bridge_twice_failing, function() coroutine.yield("two") end, function() coroutine.yield("one") end)
        \\end)
        \\local _, a = coroutine.resume(co)
        \\local _, b = coroutine.resume(co)
        \\local _, ok, m = coroutine.resume(co)
        \\return a .. "|" .. b .. "|" .. tostring(ok) .. "|" .. m .. "|" .. coroutine.status(co)
    ));
}

/// Drives a coroutine that yields 300 values, then takes 1000 values and
/// answers how many it got, with every allocation from the `fail_index`th on
/// failing in one resume. A resume that runs out of memory leaves the
/// coroutine waiting where it was or dead, and the main program running; one
/// still waiting then finishes as it would have. Answers whether a failure
/// was made.
fn resumeOutOfMemory(fail_index: usize) !bool {
    const state = try opened();
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state,
        \\local t = {}
        \\for i = 1, 300 do t[i] = i end
        \\return select("#", coroutine.yield(table.unpack(t)))
    , "=t", null));
    try std.testing.expectEqual(api.Status.ok, api.nilu_newthread(state));
    const normal = state.allocator;
    var failing = std.testing.FailingAllocator.init(normal, .{ .fail_index = fail_index, .resize_fail_index = 0 });
    var yielded = false;
    for (0..4) |_| {
        _ = api.nilu_settop(state, 1);
        if (yielded) for (0..1000) |i| try std.testing.expectEqual(api.Status.ok, api.nilu_pushnumber(state, @floatFromInt(i)));
        // Only the first resume to reach the failing index runs short.
        const short = !failing.has_induced_failure;
        if (short) state.allocator = failing.allocator();
        var count: c_int = -1;
        const status = api.nilu_resume(state, 1, if (yielded) 1000 else 0, &count);
        state.allocator = normal;
        try std.testing.expect(state.running == state.main_thread);
        try std.testing.expect(state.main_thread.status == .running);
        switch (status) {
            .yielded => {
                try std.testing.expect(!yielded);
                try std.testing.expectEqual(@as(c_int, 300), count);
                yielded = true;
            },
            .ok => {
                try std.testing.expectEqual(@as(c_int, 1), count);
                try std.testing.expectEqual(@as(f64, 1000), api.nilu_tonumberx(state, -1, null));
                return failing.has_induced_failure;
            },
            .memory => {
                try std.testing.expect(failing.has_induced_failure);
                switch (api.nilu_threadstatus(state, 1)) {
                    // Suspended: not started, or waiting in its yield
                    // whose values were lost; the next resume answers it.
                    0 => yielded = state.stack.items[0].unpack().thread.function.is(.nil),
                    // Dead.
                    3 => return true,
                    else => return error.TestUnexpectedResult,
                }
            },
            else => return error.TestUnexpectedResult,
        }
    }
    return error.TestUnexpectedResult;
}

test "coroutine a resume that runs out of memory leaves the coroutine resumable or dead" {
    var fail_index: usize = 0;
    while (try resumeOutOfMemory(fail_index)) fail_index += 1;
    // Every index up to the resumes' last allocation made one fail.
    try std.testing.expect(fail_index > 0);
}

fn catchInside(state: *runtime.State) callconv(.c) c_int {
    _ = api.nilu_loadnamed(state, "error('child', 0)", "=child", null);
    _ = api.nilu_pcall(state, 0, 0, 0);
    return 0;
}

test "coroutine nilu_where(N, 0) is each thread's own, and a resume counts as a call" {
    const state = try opened();
    defer api.nilu_close(state);
    var count: c_int = 0;
    var where = api.ErrorLocation{};
    // A failure caught inside the coroutine is not the resumer's.
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushcfunction(state, catchInside));
    try std.testing.expectEqual(api.Status.ok, api.nilu_newthread(state));
    try std.testing.expectEqual(api.Status.ok, api.nilu_resume(state, 1, 0, &count));
    try std.testing.expect(api.nilu_where(state, 0, &where) == null);
    // A resume that fails names where the coroutine failed.
    _ = api.nilu_settop(state, 0);
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state, "local x = nil\nreturn x.y", "=boom", null));
    try std.testing.expectEqual(api.Status.ok, api.nilu_newthread(state));
    try std.testing.expectEqual(api.Status.type, api.nilu_resume(state, 1, 0, &count));
    try std.testing.expectEqualStrings("boom", std.mem.span(api.nilu_where(state, 0, &where).?));
    try std.testing.expectEqual(@as(c_int, 2), where.line);
}

fn whereNow(state: *runtime.State) callconv(.c) c_int {
    var where = api.ErrorLocation{};
    const name = api.nilu_where(state, 0, &where);
    _ = api.nilu_pushstring(state, if (name) |n| n else "none");
    return 1;
}

test "coroutine a suspended coroutine keeps its own nilu_where(N, 0) while its resumer fails" {
    const state = try opened();
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushcfunction(state, catchInside));
    try std.testing.expectEqual(api.Status.ok, api.nilu_setglobal(state, "catch_inside"));
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushcfunction(state, whereNow));
    try std.testing.expectEqual(api.Status.ok, api.nilu_setglobal(state, "where_now"));
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state, "catch_inside() coroutine.yield() return where_now()", "=co", null));
    try std.testing.expectEqual(api.Status.ok, api.nilu_newthread(state));
    var count: c_int = 0;
    try std.testing.expectEqual(api.Status.yielded, api.nilu_resume(state, 1, 0, &count));
    _ = api.nilu_settop(state, 1);
    // The resumer fails in between; that is its own last failure.
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state, "error('main', 0)", "=mainfail", null));
    try std.testing.expectEqual(api.Status.runtime, api.nilu_pcall(state, 0, 0, 0));
    _ = api.nilu_settop(state, 1);
    try std.testing.expectEqual(api.Status.ok, api.nilu_resume(state, 1, 0, &count));
    try std.testing.expectEqualStrings("child", std.mem.span(api.nilu_tolstring(state, -1, null).?));
}

test "coroutine a comparison's branch answers as the comparison does, a metamethod's yield included" {
    // Each answer here was compared with lua5.5 when the fused comparison
    // and branch came in.
    const state = try opened();
    defer api.nilu_close(state);
    const text = try run(state,
        \\local out = {}
        \\local function add(s) out[#out + 1] = s end
        \\local a, b, nan = 1, 2, 0/0
        \\local function t(x) return x and "T" or "F" end
        \\for _, p in ipairs({{1, 2}, {2, 2}, {3, 2}}) do
        \\  local x, y = p[1], p[2]
        \\  local r = ""
        \\  if x == y then r = r .. "eq " end
        \\  if x ~= y then r = r .. "ne " end
        \\  if x < y then r = r .. "lt " end
        \\  if x <= y then r = r .. "le " end
        \\  if x > y then r = r .. "gt " end
        \\  if x >= y then r = r .. "ge " end
        \\  if x < 2 then r = r .. "lt2 " end
        \\  if x >= 2 then r = r .. "ge2 " end
        \\  add(r)
        \\end
        \\local r = ""
        \\if nan == nan then r = r .. "nan-eq " end
        \\if nan ~= nan then r = r .. "nan-ne " end
        \\if nan < 1 then r = r .. "nan-lt " end
        \\if nan >= 1 then r = r .. "nan-ge " end
        \\add(r)
        \\local s1, s2 = "abc", "abd"
        \\if s1 < s2 then add("str-lt") end
        \\if s1 == "abc" then add("str-eq-const") end
        \\local ok, msg = pcall(function() local n = nil if a < n then return 1 end end)
        \\add(tostring(ok) .. " " .. msg)
        \\ok, msg = pcall(function() local u = {} if u <= a then return 1 end end)
        \\add(tostring(ok) .. " " .. msg)
        \\local mt = {}
        \\mt.__lt = function(p, q) coroutine.yield("lt") return p.v < q.v end
        \\mt.__le = function(p, q) coroutine.yield("le") return p.v <= q.v end
        \\mt.__eq = function(p, q) coroutine.yield("eq") return p.v == q.v end
        \\local x, y, z = setmetatable({v = 1}, mt), setmetatable({v = 2}, mt), setmetatable({v = 1}, mt)
        \\local co = coroutine.wrap(function()
        \\  local x, y, z = x, y, z
        \\  local r = ""
        \\  if x < y then r = r .. "lt " else r = r .. "nlt " end
        \\  if y <= x then r = r .. "le " else r = r .. "nle " end
        \\  if x == z then r = r .. "eq " else r = r .. "neq " end
        \\  if x ~= z then r = r .. "ne " else r = r .. "nne " end
        \\  if x ~= y then r = r .. "ne2 " else r = r .. "nne2 " end
        \\  local n = 0
        \\  while x < y and n < 2 do n = n + 1 end
        \\  return r .. n
        \\end)
        \\local steps = {}
        \\while true do
        \\  local v = co()
        \\  steps[#steps + 1] = v
        \\  if v ~= "lt" and v ~= "le" and v ~= "eq" then break end
        \\end
        \\add(table.concat(steps, ","))
        \\local i, n = 0, 0
        \\while i < 10 do i = i + 1 if i % 3 == 0 then n = n + 1 elseif i > 8 then n = n + 10 end end
        \\add(i .. " " .. n)
        \\return table.concat(out, "|")
    );
    try std.testing.expectEqualStrings("ne lt le lt2 |eq le ge ge2 |ne gt ge ge2 |nan-ne |str-lt|str-eq-const|false t:27: attempt to compare number with nil|false t:29: attempt to compare table with number|lt,le,eq,eq,eq,lt,lt,lt,lt nle eq nne ne2 2|10 13", text);
}

test "coroutine one call instruction meeting callees of every kind answers as lua5.5" {
    // A call takes its callee's kind's arm directly once it has met one, and
    // falls back to the general arm for another kind.
    const state = try opened();
    defer api.nilu_close(state);
    const text = try run(state,
        \\local fs = {function(x) return x + 1 end, tostring, setmetatable({}, {__call = function(_, x) return x * 2 end}), math.abs, function(x) return -x end}
        \\local out = {}
        \\for i = 1, 15 do
        \\  local f = fs[(i - 1) % 5 + 1]
        \\  out[#out + 1] = tostring(f(i))
        \\end
        \\local function open(...) return ... end
        \\for i = 1, 4 do
        \\  local f = fs[(i - 1) % 5 + 1]
        \\  out[#out + 1] = tostring(f(open(i, 0)))
        \\end
        \\return table.concat(out, ",")
    );
    try std.testing.expectEqualStrings("2,2,6,4,-5,7,7,16,9,-10,12,12,26,14,-15,2,2,6,4", text);
}
