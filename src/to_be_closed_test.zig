//! To-be-closed variables (`<close>`, the owner's answer): one script whose every line of output was taken from lua5.5
//! running the same source.
const std = @import("std");
const api = @import("c_api.zig");
const runtime = @import("runtime.zig");
const a = std.testing.allocator;

test "to_be_closed closes on every exit, passes failures, and works with for and coroutines as lua5.5" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_openlibs(state));
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state,
        \\local out = {} local function print(...) local parts = table.pack(...) for i = 1, parts.n do parts[i] = tostring(parts[i]) end out[#out + 1] = table.concat(parts, " | ", 1, parts.n) end
        \\local log = {}
        \\local function r(name, fail) return setmetatable({}, {__close = function(_, e) log[#log + 1] = name .. ":" .. tostring(e) if fail then error(fail, 0) end end}) end
        \\local function step(s, c) c = (c or 0) + 1 if c <= s then return c end end
        \\-- 1 order, break, goto, return
        \\do local a <close> = r("a") do local b <close> = r("b") end end
        \\for i = 1, 2 do local c <close> = r("c" .. i) if i == 2 then break end end
        \\do local g <close> = r("g") goto out end ::out::
        \\local function ret() local x <close> = r("x") return "rv" end
        \\log[#log + 1] = ret()
        \\print(table.concat(log, " ")) log = {}
        \\-- 2 failures and replacement, xpcall order
        \\print(pcall(function() local a <close> = r("a", "A") local b <close> = r("b") error("orig", 0) end), table.concat(log, " ")) log = {}
        \\print(xpcall(function() local a <close> = r("a") error("E", 0) end, function(m) log[#log + 1] = "handler" return "H" .. m end), table.concat(log, " ")) log = {}
        \\-- 3 generic for: fourth closed after body, also only held by the loop
        \\for k in step, 2, nil, r("fourth") do local b <close> = r("body" .. k) collectgarbage() end
        \\print(table.concat(log, " ")) log = {}
        \\-- 4 coroutines
        \\local co = coroutine.wrap(function() local y <close> = setmetatable({}, {__close = function() log[#log + 1] = "y1" coroutine.yield("in close") log[#log + 1] = "y2" end}) end)
        \\print(co(), co(), table.concat(log, " ")) log = {}
        \\local c2 = coroutine.create(function() local a <close> = r("a") local b <close> = r("b", "bf") coroutine.yield() end)
        \\coroutine.resume(c2) print(coroutine.close(c2), table.concat(log, " ")) log = {}
        \\-- 5 refusals
        \\print(pcall(function() local z <close> = {} end))
        \\print(pcall(function() for k in step, 1, nil, 5 do end end))
        \\return table.concat(out, "\n")
    , "=t", null));
    try std.testing.expectEqual(api.Status.ok, api.nilu_pcall(state, 0, 1, 0));
    try std.testing.expectEqualStrings(
        \\b:nil a:nil c1:nil c2:nil g:nil rv
        \\false | b:orig a:orig
        \\false | handler a:HE
        \\body1:nil body2:nil fourth:nil
        \\in close | nil | y1 y2
        \\false | b:nil a:bf
        \\false | t:24: variable 'z' got a non-closable value
        \\false | t:25: variable '(for state)' got a non-closable value
    , std.mem.span(api.nilu_tolstring(state, -1, null).?));
}

test "to_be_closed a value only the closing list holds survives a collection" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_openlibs(state));
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state,
        \\closed = 0
        \\local function step(s, c) c = (c or 0) + 1 if c <= s then return c end end
        \\local function closer() return setmetatable({}, {__close = function() closed = closed + 1 end}) end
        \\for k, v, w in step, 3, nil, closer() do local junk = {} end
        \\return ""
    , "=t", null));
    try std.testing.expectEqual(api.Status.ok, api.nilu_pcall(state, 0, 0, 0));
    try std.testing.expectEqual(api.Status.ok, api.nilu_getglobal(state, "closed"));
    try std.testing.expectEqual(@as(f64, 1), api.nilu_tonumberx(state, -1, null));
}

test "to_be_closed a failure closes variables once the frames above its catcher are gone, as lua5.5" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_openlibs(state));
    // Expected lines taken from lua5.5 5.5.1 running the same source: no
    // frame of the failing calls is on the stack when a variable closes; a
    // failed coroutine keeps its variables for coroutine.close, and wrap
    // closes it as it fails.
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state,
        \\local inner, middle
        \\local seen = {}
        \\local function onstack(f) local level = 2 while true do local info = debug.getinfo(level, "f") if not info then return false end if info.func == f then return true end level = level + 1 end end
        \\local function closer(name) return setmetatable({}, {__close = function(_, e) seen[#seen + 1] = name .. ":" .. tostring(e) .. ":" .. tostring(onstack(inner)) .. "," .. tostring(onstack(middle)) end}) end
        \\function inner() local x <close> = closer("inner") error("boom", 0) end
        \\function middle() local y <close> = closer("middle") inner() end
        \\local out = {}
        \\out[#out + 1] = tostring(pcall(middle)) .. " " .. table.concat(seen, " ") seen = {}
        \\local co = coroutine.create(function() local z <close> = closer("co") error("cerr", 0) end)
        \\out[#out + 1] = tostring(coroutine.resume(co)) .. " [" .. table.concat(seen, " ") .. "]"
        \\out[#out + 1] = table.concat({tostring(coroutine.close(co))}, " ") .. " " .. table.concat(seen, " ") seen = {}
        \\local w = coroutine.wrap(function() local z <close> = closer("wrap") error("werr", 0) end)
        \\out[#out + 1] = select(2, pcall(w)) .. " " .. table.concat(seen, " ")
        \\return table.concat(out, "\n")
    , "=t", null));
    try std.testing.expectEqual(api.Status.ok, api.nilu_pcall(state, 0, 1, 0));
    try std.testing.expectEqualStrings(
        \\false inner:boom:false,false middle:boom:false,false
        \\false []
        \\false co:cerr:false,false
        \\werr wrap:werr:false,false
    , std.mem.span(api.nilu_tolstring(state, -1, null).?));
}
