//! The debug library's reading part (the owner's answer) and the C API's nilu_getinfo under it. The expected text is
//! lua5.5's output for the same source, less its `[C]: in ?` lines: the host's call
//! into the main chunk, which is not a frame here.
const std = @import("std");
const api = @import("c_api.zig");
const runtime = @import("runtime.zig");
const a = std.testing.allocator;

test "debug_library traceback and getinfo answer as lua5.5" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_openlibs(state));
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state,
        \\local out = {} local function print(...) local p = table.pack(...) for i = 1, p.n do p[i] = tostring(p[i]) end out[#out + 1] = table.concat(p, " | ", 1, p.n) end
        \\local function inner() print(debug.traceback("msg")) print(debug.traceback("lvl2", 2)) end
        \\local function outer() inner() end
        \\outer()
        \\print(debug.traceback(nil) == nil, type(debug.traceback({})))
        \\local co = coroutine.create(function() local function deep() coroutine.yield() end deep() end)
        \\coroutine.resume(co)
        \\print(debug.traceback(co))
        \\print(debug.traceback(co, "comsg", 1))
        \\local function show(i) local t = {} for k, v in pairs(i) do if type(v) ~= "table" and type(v) ~= "function" then t[#t+1] = k .. "=" .. tostring(v) end end table.sort(t) print(table.concat(t, " ")) end
        \\local function f(a, b, ...) show(debug.getinfo(1)) show(debug.getinfo(2, "nSl")) end
        \\f(1, 2)
        \\show(debug.getinfo(print))
        \\show(debug.getinfo(f, "S"))
        \\print(debug.getinfo(100))
        \\print(debug.getinfo(1, "f").func ~= nil, debug.getinfo(f, "u").nparams, debug.getinfo(1, "l").currentline)
        \\show(debug.getinfo(co, 1, "Sln"))
        \\local function lines() local a = 1
        \\  local b = 2
        \\  return a + b end
        \\local L = debug.getinfo(lines, "L").activelines local t = {} for k in pairs(L) do t[#t+1] = k end table.sort(t) print(table.concat(t, " "))
        \\local result = (table.concat(out, "\n"):gsub("\t", "    ")) if io then io.write(result) end return result
    , "@t", null));
    try std.testing.expectEqual(api.Status.ok, api.nilu_pcall(state, 0, 1, 0));
    try std.testing.expectEqualStrings(
        \\msg
        \\stack traceback:
        \\    t:2: in upvalue 'inner'
        \\    t:3: in local 'outer'
        \\    t:4: in main chunk
        \\lvl2
        \\stack traceback:
        \\    t:3: in local 'outer'
        \\    t:4: in main chunk
        \\false | table
        \\stack traceback:
        \\    [C]: in field 'yield'
        \\    t:6: in local 'deep'
        \\    t:6: in function <t:6>
        \\comsg
        \\stack traceback:
        \\    t:6: in local 'deep'
        \\    t:6: in function <t:6>
        \\currentline=11 extraargs=0 ftransfer=0 istailcall=false isvararg=true lastlinedefined=11 linedefined=11 name=f namewhat=local nparams=2 ntransfer=0 nups=2 short_src=t source=@t what=Lua
        \\currentline=12 lastlinedefined=0 linedefined=0 namewhat= short_src=t source=@t what=main
        \\currentline=-1 extraargs=0 ftransfer=0 istailcall=false isvararg=true lastlinedefined=1 linedefined=1 namewhat= nparams=0 ntransfer=0 nups=2 short_src=t source=@t what=Lua
        \\lastlinedefined=11 linedefined=11 short_src=t source=@t what=Lua
        \\nil
        \\true | 2 | 16
        \\currentline=6 lastlinedefined=6 linedefined=6 name=deep namewhat=local short_src=t source=@t what=Lua
        \\18 19 20
    , std.mem.span(api.nilu_tolstring(state, -1, null).?));
}

fn ask(state: *runtime.State) callconv(.c) c_int {
    var ar = api.Debug{};
    // Level 0 is this C function; 1 the script that called it.
    if (api.nilu_getinfo(state, 0, 0, "Sn", &ar) != 1 or !std.mem.eql(u8, std.mem.span(ar.what), "C")) return api.fail;
    if (api.nilu_getinfo(state, 0, 1, "Sl", &ar) != 1 or ar.currentline != 2) return api.fail;
    if (api.nilu_getinfo(state, 0, 1, "x", &ar) != -1) return api.fail;
    if (api.nilu_getinfo(state, 0, 50, "S", &ar) != 0) return api.fail;
    _ = api.nilu_pushcfunction(state, ask);
    if (api.nilu_getinfo(state, 0, 0, ">Su", &ar) != 1 or ar.isvararg != 1 or !std.mem.eql(u8, std.mem.sliceTo(&ar.short_src, 0), "[C]")) return api.fail;
    return 0;
}

test "debug_library nilu_getinfo levels, a function on top, and refusals" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushcfunction(state, ask));
    try std.testing.expectEqual(api.Status.ok, api.nilu_setglobal(state, "ask"));
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state, "local x = 1\nask()\n", "=t", null));
    try std.testing.expectEqual(api.Status.ok, api.nilu_pcall(state, 0, 0, 0));
}

test "debug_library a handler sees the line of an instruction that failed by itself" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_openlibs(state));
    // lua5.5 5.5.1 answers 3 for the same source: the frame stands on the
    // `for` that refused its initial value, though nothing it ran was a call.
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state,
        \\local function f()
        \\  local x = 1
        \\  for i = "a", 2 do end
        \\end
        \\return select(2, xpcall(f, function(m) return debug.getinfo(2, "l").currentline end))
    , "=t", null));
    try std.testing.expectEqual(api.Status.ok, api.nilu_pcall(state, 0, 1, 0));
    try std.testing.expectEqual(@as(f64, 3), api.nilu_tonumberx(state, -1, null));
}
