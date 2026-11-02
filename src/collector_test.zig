//! Weak tables (ADR 0005): what a collection removes from a table whose
//! metatable has `__mode`, and what it keeps.
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

/// Runs `setup`, collects with nothing on the stack, then answers `check`.
fn afterCollection(state: *runtime.State, setup: [:0]const u8, check: [:0]const u8) ![]const u8 {
    _ = try run(state, setup);
    _ = api.nilu_settop(state, 0);
    state.collect();
    return run(state, check);
}

const count =
    \\local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
    \\
;

test "weak_table weak keys go with their keys, strong ones and strings stay" {
    const state = try opened();
    defer api.nilu_close(state);
    try std.testing.expectEqualStrings("3 2 table table", try afterCollection(state,
        \\kept = {}
        \\wk = setmetatable({}, {__mode = "k"})
        \\wk[{}] = 1 wk[kept] = 2 wk["s"] = {} wk[1] = {}
        \\return ""
    , count ++ "return count(wk) .. ' ' .. wk[kept] .. ' ' .. type(wk.s) .. ' ' .. type(wk[1])"));
}

test "weak_table weak values become nil and their keys stay, array part included" {
    const state = try opened();
    defer api.nilu_close(state);
    try std.testing.expectEqualStrings("nil true nil str 5 3", try afterCollection(state,
        \\kept = {}
        \\wv = setmetatable({}, {__mode = "v"})
        \\wv[1] = {} wv[2] = kept wv.x = {} wv.y = "str" wv.z = 5
        \\return ""
    , count ++ "return tostring(wv[1]) .. ' ' .. tostring(wv[2] == kept) .. ' ' .. tostring(wv.x) .. ' ' .. wv.y .. ' ' .. wv.z .. ' ' .. count(wv)"));
}

test "weak_table an ephemeron does not keep a key its own value refers to, and follows chains" {
    const state = try opened();
    defer api.nilu_close(state);
    try std.testing.expectEqualStrings("0 3 1", try afterCollection(state,
        \\eph = setmetatable({}, {__mode = "k"})
        \\do local k = {} eph[k] = {k} end
        \\chain = setmetatable({}, {__mode = "k"})
        \\root = {}
        \\do local x, y = {}, {} chain[root] = x chain[x] = y chain[y] = "end" end
        \\both = setmetatable({}, {__mode = "kv"})
        \\both[{}] = 1 both.a = root both.b = {}
        \\return ""
    , count ++ "return count(eph) .. ' ' .. count(chain) .. ' ' .. count(both)"));
}

test "weak_table a traversal and a cached field survive a collection that clears entries" {
    const state = try opened();
    defer api.nilu_close(state);
    try std.testing.expectEqualStrings("true nil nil", try run(state,
        \\local tr = setmetatable({}, {__mode = "v"})
        \\for i = 1, 40 do tr["k" .. i] = {} end
        \\local seen = 0
        \\for k, v in pairs(tr) do seen = seen + 1 collectgarbage() end
        \\local c = setmetatable({}, {__mode = "k"})
        \\local key = {}
        \\c[key] = 1
        \\local v = setmetatable({}, {__mode = "v"})
        \\v.f = {}
        \\local function get() return v.f end
        \\get() collectgarbage()
        \\key = nil collectgarbage()
        \\return tostring(seen >= 1) .. " " .. tostring(get()) .. " " .. tostring(next(c))
    ));
}

test "weak_table a dropped weak table is freed with what it held" {
    const state = try opened();
    defer api.nilu_close(state);
    _ = try run(state, "return ''");
    _ = api.nilu_settop(state, 0);
    state.collect();
    const baseline = state.object_count;
    _ = try run(state, "keep = setmetatable({}, {__mode = 'kv'}) for i = 1, 100 do keep[{}] = {} end keep = nil return ''");
    _ = api.nilu_settop(state, 0);
    state.collect();
    // What is left beyond the baseline is the chunk's strings, not 200 tables.
    try std.testing.expect(state.object_count <= baseline + 8);
}

// A young collection marks from the roots and from the old objects written
// since the last collection (ADR 0006). Each case makes an old object with
// a full collection, stores a new object into it one way, makes enough
// garbage for young collections to run, and reads the new object back: a
// store that skipped `State.barrier` would have let it be freed. A safe
// build's `verifyYoung` stops at such a store; a fast build reads freed
// memory, which the churn reuses.
const churn = "local function churn() for i = 1, 20000 do local g = {i} end end ";

fn answer(state: *runtime.State, source: [:0]const u8) ![]const u8 {
    _ = api.nilu_settop(state, 0);
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state, source, "=t", null));
    try std.testing.expectEqual(api.Status.ok, api.nilu_call(state, 0, 1));
    return std.mem.span(api.nilu_tolstring(state, -1, null).?);
}

test "generational what a script stores into an old object survives young collections" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_openlibs(state));
    const cases = .{
        .{ "local t = {} collectgarbage() t.x = {v = 1} churn() return t.x.v", "1" },
        .{ "local t = {0} collectgarbage() t[1] = {v = 2} t[2] = {v = 3} churn() return t[1].v + t[2].v", "5" },
        .{ "local t = {} collectgarbage() t[string.rep('k', 3)] = 4 churn() return next(t) .. t.kkk", "kkk4" },
        .{ "local f do local c = 0 f = function(v) if v then c = v end return c end end collectgarbage() f({v = 6}) churn() return f().v", "6" },
        .{ "local t = {} collectgarbage() setmetatable(t, {__index = function() return 7 end}) churn() return t.y", "7" },
        .{ "collectgarbage() held = {v = 8} churn() return held.v", "8" },
        .{ "local co = coroutine.create(function() local x = {v = 9} coroutine.yield() return x.v end) collectgarbage() coroutine.resume(co) churn() return select(2, coroutine.resume(co))", "9" },
        .{ "local co = coroutine.create(function() churn() local y = {v = 14} coroutine.yield() return y.v end) collectgarbage() coroutine.resume(co) churn() return select(2, coroutine.resume(co))", "14" },
        .{ "local t = setmetatable({}, {__mode = 'v'}) local keep = {v = 10} collectgarbage() t[1] = keep churn() return t[1].v", "10" },
    };
    inline for (cases) |case| {
        try std.testing.expectEqualStrings(case[1], try answer(state, churn ++ case[0]));
    }
}

/// Sets field `v` of the table on top to `n`.
fn setV(state: *runtime.State, n: i64) api.Status {
    if (api.nilu_pushstring(state, "v") != .ok) return .memory;
    if (api.nilu_pushinteger(state, n) != .ok) return .memory;
    return api.nilu_settable(state, -3);
}

/// With no argument, stores a new table into its upvalue; with one, answers
/// the upvalue.
fn upvalueBox(state: *runtime.State) callconv(.c) c_int {
    if (api.nilu_gettop(state) > 0) {
        if (api.nilu_getupvalue(state, 1) != .ok) return -1;
        return 1;
    }
    if (api.nilu_newtable(state) != .ok) return -1;
    if (setV(state, 11) != .ok) return -1;
    if (api.nilu_setupvalue(state, 1) != .ok) return -1;
    return 0;
}

test "generational what the C API stores into an old object survives young collections" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_openlibs(state));
    // A C closure's upvalue, written while it runs.
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushnil(state));
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushcclosure(state, upvalueBox, 1));
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushvalue(state, -1));
    try std.testing.expectEqual(api.Status.ok, api.nilu_setglobal(state, "box_up"));
    try std.testing.expectEqual(api.Status.ok, api.nilu_settop(state, 0));
    // A userdata's user value and the registry, written from the host.
    var block: ?*anyopaque = null;
    try std.testing.expectEqual(api.Status.ok, api.nilu_newuserdatauv(state, 8, 1, &block));
    try std.testing.expectEqual(api.Status.ok, api.nilu_setglobal(state, "box"));
    state.collect();
    try std.testing.expectEqual(api.Status.ok, api.nilu_getglobal(state, "box"));
    try std.testing.expectEqual(api.Status.ok, api.nilu_newtable(state));
    try std.testing.expectEqual(api.Status.ok, setV(state, 12));
    try std.testing.expectEqual(@as(c_int, 1), api.nilu_setiuservalue(state, -2, 1));
    try std.testing.expectEqual(api.Status.ok, api.nilu_newtable(state));
    try std.testing.expectEqual(api.Status.ok, setV(state, 13));
    const reference = api.nilu_ref(state);
    try std.testing.expect(reference >= 0);
    try std.testing.expectEqual(api.Status.ok, api.nilu_settop(state, 0));
    try std.testing.expectEqualStrings("11", try answer(state, churn ++ "box_up() churn() return box_up(true).v"));
    try std.testing.expectEqual(api.Status.ok, api.nilu_getglobal(state, "box"));
    try std.testing.expectEqual(@as(c_int, 5), api.nilu_getiuservalue(state, -1, 1));
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushstring(state, "v"));
    try std.testing.expectEqual(api.Status.ok, api.nilu_gettable(state, -2));
    try std.testing.expectEqual(@as(i64, 12), api.nilu_tointegerx(state, -1, null));
    try std.testing.expectEqual(api.Status.ok, api.nilu_getref(state, reference));
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushstring(state, "v"));
    try std.testing.expectEqual(api.Status.ok, api.nilu_gettable(state, -2));
    try std.testing.expectEqual(@as(i64, 13), api.nilu_tointegerx(state, -1, null));
}

// `collectgarbage`, `_G` and `_VERSION`, and nilu_gc.

test "collect_garbage the count grows with what is held and falls after a collection" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_openlibs(state));
    try std.testing.expectEqualStrings("true true true|0 true true", try answer(state,
        \\local before = collectgarbage("count")
        \\local t = {} for i = 1, 20000 do t[i] = {} end
        \\local held = collectgarbage("count")
        \\t = nil
        \\collectgarbage()
        \\local after = collectgarbage("count")
        \\return tostring(before > 0) .. " " .. tostring(held > before) .. " " .. tostring(after < held)
        \\  .. "|" .. tostring(collectgarbage("collect")) .. " " .. tostring(collectgarbage("step"))
        \\  .. " " .. tostring(collectgarbage("isrunning"))
    ));
    // The modes are not there by decision (the owner's answer).
    try std.testing.expectEqualStrings("bad argument #1 to 'collectgarbage' (invalid option 'generational')", try answer(state, "return select(2, pcall(collectgarbage, 'generational'))"));
}

test "collect_garbage stop keeps collections from starting by themselves until restart" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_openlibs(state));
    // As lua5.5 5.5.1 answers, but for "step": a step here is a whole
    // collection, so it answers true.
    try std.testing.expectEqualStrings("0 false 0 true false 0 false", try answer(state,
        \\return table.concat({tostring(collectgarbage("stop")), tostring(collectgarbage("isrunning")), collectgarbage("stop"),
        \\  tostring(collectgarbage("step")), tostring(collectgarbage("isrunning")), collectgarbage("collect"), tostring(collectgarbage("isrunning"))}, " ")
    ));
    // Garbage piles up past the threshold while stopped...
    _ = try answer(state, "for i = 1, 5000 do local t = {} end return ''");
    try std.testing.expect(state.object_count > 5000);
    try std.testing.expect(state.object_count > state.collection_threshold);
    // ...and the next steps after restart collect it.
    try std.testing.expectEqualStrings("0 true", try answer(state, "local r = collectgarbage('restart') for i = 1, 10 do end return r .. ' ' .. tostring(collectgarbage('isrunning'))"));
    try std.testing.expect(state.object_count < 5000);
}

test "collect_garbage _G is the globals table and _VERSION names the language" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_openlibs(state));
    try std.testing.expectEqualStrings("Nilu 0.1 true true 7", try answer(state, "x = 7 return _VERSION .. ' ' .. tostring(_G == _ENV) .. ' ' .. tostring(_G._G == _G) .. ' ' .. _G.x"));
}

test "collect_garbage nilu_gc answers each query and refuses an unknown one" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    var out: f64 = -1;
    try std.testing.expectEqual(api.Status.ok, api.nilu_gc(state, 1, &out));
    try std.testing.expect(out > 0);
    try std.testing.expectEqual(api.Status.ok, api.nilu_gc(state, 0, null));
    try std.testing.expectEqual(api.Status.ok, api.nilu_gc(state, 3, &out));
    try std.testing.expectEqual(@as(f64, 1), out);
    try std.testing.expectEqual(api.Status.ok, api.nilu_gc(state, 4, &out));
    try std.testing.expectEqual(@as(f64, 0), out);
    try std.testing.expectEqual(api.Status.ok, api.nilu_gc(state, 3, &out));
    try std.testing.expectEqual(@as(f64, 0), out);
    try std.testing.expectEqual(api.Status.ok, api.nilu_gc(state, 5, null));
    try std.testing.expectEqual(api.Status.ok, api.nilu_gc(state, 3, &out));
    try std.testing.expectEqual(@as(f64, 1), out);
    try std.testing.expectEqual(api.Status.type, api.nilu_gc(state, 9, &out));
}

test "collect_garbage a register a frame left is never marked after what it held was freed" {
    // Callees leave tables in registers past their caller's frame; others
    // regrow over those slots without filling them (ADR 0005) and collect.
    // The answer is lua5.5's. The invariant itself is runtime_test's "a
    // stack's room past its length is nil ...".
    const state = try api.create(std.testing.allocator);
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_openlibs(state));
    const text = try answer(state,
        \\local function leave(depth)
        \\  local a, b, c, d, e, f, g, h = {}, {}, {}, {}, {}, {}, {}, {}
        \\  if depth > 0 then local r = leave(depth - 1) return r end
        \\  return 1
        \\end
        \\local function regrow(depth)
        \\  if depth == 0 then collectgarbage() return 0 end
        \\  local r = regrow(depth - 1)
        \\  local a, b, c, d, e, f, g, h = depth, depth, depth, depth, depth, depth, depth, depth
        \\  return r + a + b + c + d + e + f + g + h
        \\end
        \\local sum = 0
        \\for i = 1, 4 do
        \\  leave(60)
        \\  collectgarbage()
        \\  sum = sum + regrow(60)
        \\end
        \\local co = coroutine.wrap(function()
        \\  local total = 0
        \\  for i = 1, 3 do
        \\    leave(60)
        \\    coroutine.yield()
        \\    total = total + regrow(60)
        \\  end
        \\  return total
        \\end)
        \\for i = 1, 3 do co() collectgarbage() end
        \\sum = sum + co()
        \\local function deep(n) if n == 0 then collectgarbage() return 0 end local x, y, z = {}, {}, {} local r = deep(n - 1) return 1 + r end
        \\sum = sum + deep(150)
        \\return tostring(sum)
    );
    try std.testing.expectEqualStrings("102630", text);
}

// The registry's references and a userdata's user values (the owner's
// answer): what only they hold survives a
// collection, and both give their values back.
/// t[key] = the string value, t being the table on top.
fn setString(state: *runtime.State, key: [:0]const u8, value: [:0]const u8) !void {
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushstring(state, key));
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushstring(state, value));
    try std.testing.expectEqual(api.Status.ok, api.nilu_settable(state, -3));
}

/// Pushes t[key], t being the table on top.
fn getString(state: *runtime.State, key: [:0]const u8) !void {
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushstring(state, key));
    try std.testing.expectEqual(api.Status.ok, api.nilu_gettable(state, -2));
}

fn stringAt(state: *runtime.State, index: c_int) []const u8 {
    return std.mem.span(api.nilu_tolstring(state, index, null) orelse "(not a string)");
}

test "references what only a reference holds survives, and a reference is given back" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_newtable(state));
    try setString(state, "name", "kept");
    const reference = api.nilu_ref(state);
    try std.testing.expect(reference > 0);
    try std.testing.expectEqual(@as(c_int, 0), api.nilu_gettop(state));
    state.collect();
    try std.testing.expectEqual(api.Status.ok, api.nilu_getref(state, reference));
    try getString(state, "name");
    try std.testing.expectEqualStrings("kept", stringAt(state, -1));
    _ = api.nilu_settop(state, 0);
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushnil(state));
    try std.testing.expectEqual(@as(c_int, -1), api.nilu_ref(state));
    api.nilu_unref(state, reference);
    try std.testing.expectEqual(api.Status.ok, api.nilu_getref(state, reference));
    try std.testing.expectEqual(@backingInt(api.Type.nil), api.nilu_type(state, -1));
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushnumber(state, 7));
    try std.testing.expectEqual(reference, api.nilu_ref(state));
}

test "references user values survive a collection and answer nothing past their count" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    var block: ?*anyopaque = null;
    try std.testing.expectEqual(api.Status.ok, api.nilu_newuserdatauv(state, 8, 2, &block));
    try std.testing.expect(block != null);
    try std.testing.expectEqual(@backingInt(api.Type.nil), api.nilu_getiuservalue(state, 1, 2));
    _ = api.nilu_settop(state, 1);
    try std.testing.expectEqual(api.Status.ok, api.nilu_newtable(state));
    try setString(state, "what", "inside");
    try std.testing.expectEqual(@as(c_int, 1), api.nilu_setiuservalue(state, 1, 2));
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushnumber(state, 3));
    try std.testing.expectEqual(@as(c_int, 0), api.nilu_setiuservalue(state, 1, 3));
    try std.testing.expectEqual(@as(c_int, 1), api.nilu_gettop(state));
    state.collect();
    try std.testing.expectEqual(@backingInt(api.Type.table), api.nilu_getiuservalue(state, 1, 2));
    try getString(state, "what");
    try std.testing.expectEqualStrings("inside", stringAt(state, -1));
    try std.testing.expectEqual(@backingInt(api.Type.none), api.nilu_getiuservalue(state, 1, 3));
    try std.testing.expectEqual(@backingInt(api.Type.nil), api.nilu_type(state, -1));
    try std.testing.expectEqual(@backingInt(api.Type.none), api.nilu_getiuservalue(state, 1, 0));
}
