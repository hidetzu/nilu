//! `require`, `dofile`, `loadfile` and `load` (ADR 0003) through the C API, as
//! a host sees them. The reader is a script function over a table of files:
//! a module name has its dots made '/' and ".nilu" added, next to the file
//! being loaded first, then at the top; a file path is used as written.
const std = @import("std");
const api = @import("c_api.zig");
const runtime = @import("runtime.zig");
const allocation_failures = @import("allocation_failures.zig");
const a = std.testing.allocator;

const reader_source =
    \\local files = ...
    \\return function(name, from, kind)
    \\  local key = name
    \\  if kind == "module" then
    \\    local relative = (string.gsub(name, "%.", "/")) .. ".nilu"
    \\    local dir = from and string.match(from, "^(.*/)") or ""
    \\    key = dir .. relative
    \\    if files[key] == nil then key = relative end
    \\  end
    \\  if files[key] == nil then return nil, "no file '" .. key .. "'" end
    \\  return key, files[key]
    \\end
;

/// A state with the library open and a reader over `files`, a table
/// constructor's text such as `{["util.nilu"] = "return 1"}`.
fn withFiles(allocator: std.mem.Allocator, files: [:0]const u8) !*runtime.State {
    const state = try api.create(allocator);
    errdefer api.nilu_close(state);
    try expectOk(api.nilu_openlibs(state));
    try expectOk(api.nilu_loadnamed(state, reader_source, "=reader", null));
    var buffer: [4096]u8 = undefined;
    const table = try std.fmt.bufPrint(&buffer, "return {s}\x00", .{files});
    try expectOk(api.nilu_loadnamed(state, @ptrCast(table.ptr), "=files", null));
    try expectOk(api.nilu_call(state, 0, 1));
    try expectOk(api.nilu_call(state, 1, 1));
    try expectOk(api.nilu_setreader(state));
    try std.testing.expectEqual(@as(c_int, 0), api.nilu_gettop(state));
    return state;
}

/// A shortage is passed on as one, so the allocation-failure check can tell
/// it from a wrong answer; any other status fails the test.
fn expectOk(status: api.Status) !void {
    switch (status) {
        .ok => {},
        .memory, .stack => return error.OutOfMemory,
        else => {
            std.debug.print("unexpected status {t}\n", .{status});
            return error.TestUnexpectedResult;
        },
    }
}

/// Runs `source` as the main file and answers its one result as a string.
fn run(state: *runtime.State, source: [:0]const u8) ![]const u8 {
    _ = api.nilu_settop(state, 0);
    try expectOk(api.nilu_loadnamed(state, source, "@main.nilu", null));
    try expectOk(api.nilu_call(state, 0, 1));
    return std.mem.span(api.nilu_tolstring(state, -1, null) orelse return error.NotAString);
}

test "stdlib_package require runs a module once and caches it under the reader's key" {
    const state = try withFiles(a, "{[\"util.nilu\"] = \"count = (count or 0) + 1 return {n = count}\"}");
    defer api.nilu_close(state);
    // A cached module answers one result; the first load also answers the key.
    try std.testing.expectEqualStrings("true|util.nilu|1|true|1", try run(state,
        \\local first, key = require("util")
        \\local again = require("util")
        \\return tostring(first == again) .. "|" .. key .. "|" .. tostring(count)
        \\  .. "|" .. tostring(package.loaded["util.nilu"] == first) .. "|" .. tostring(select("#", require("util")))
    ));
}

test "stdlib_package a name is found next to the file that asks, so two directories hold two modules" {
    const state = try withFiles(a,
        \\{["a/m.nilu"] = "return 'a'", ["b/m.nilu"] = "return 'b'",
        \\ ["a/x.nilu"] = "return require('m')", ["b/y.nilu"] = "return require('m')", ["m.nilu"] = "return 'top'"}
    );
    defer api.nilu_close(state);
    try std.testing.expectEqualStrings("a b top", try run(state, "return require('a.x') .. ' ' .. require('b.y') .. ' ' .. require('m')"));
}

test "stdlib_package the standard tables are loaded modules and need no reader" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try expectOk(api.nilu_openlibs(state));
    try std.testing.expectEqualStrings("true true true true", try run(state,
        \\return tostring(require("string") == string) .. " " .. tostring(require("table") == table)
        \\  .. " " .. tostring(package.loaded.math == math) .. " " .. tostring(require("utf8") == utf8)
    ));
}

test "stdlib_package a module without a result is true, and one that fills package.loaded itself keeps it" {
    const state = try withFiles(a,
        \\{["none.nilu"] = "local x = 1", ["self.nilu"] = "package.loaded['self.nilu'] = 'mine'"}
    );
    defer api.nilu_close(state);
    try std.testing.expectEqualStrings("true mine", try run(state, "return tostring(require('none')) .. ' ' .. require('self')"));
}

test "stdlib_package package.preload supplies a module before the reader is asked" {
    const state = try withFiles(a, "{[\"util.nilu\"] = \"return 'file'\", [\"other.nilu\"] = \"return 'other'\"}");
    defer api.nilu_close(state);
    // As lua5.5 5.5.1 answers the same sources: the loader gets the name and
    // ":preload:", which is also the second result; the table require started
    // with is the one asked; a value that is not a function is no loader; a
    // loader that fails leaves nothing cached.
    try std.testing.expectEqualStrings("util :preload:|util|:preload:|1|kept|other|nil", try run(state,
        \\local seen
        \\package.preload.util = function(name, from) seen = name .. " " .. from return name end
        \\local value, from = require("util")
        \\local again = select("#", require("util"))
        \\local original = package.preload
        \\package.preload = {}
        \\original.late = function() return "kept" end
        \\original.other = 42
        \\original.broken = function() error("broken", 0) end
        \\pcall(require, "broken")
        \\return seen .. "|" .. value .. "|" .. from .. "|" .. again .. "|" .. require("late")
        \\  .. "|" .. require("other") .. "|" .. tostring(package.loaded.broken)
    ));
}

test "stdlib_package without a reader each loader says so" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try expectOk(api.nilu_openlibs(state));
    try std.testing.expectEqualStrings(
        "cannot load module 'util': no reader was given to this state|cannot load file 'x.nilu': no reader was given to this state|nil cannot load file 'x.nilu': no reader was given to this state",
        try run(state,
            \\local _, m = pcall(require, "util")
            \\local _, d = pcall(dofile, "x.nilu")
            \\local f, l = loadfile("x.nilu")
            \\return m .. "|" .. d .. "|" .. tostring(f) .. " " .. l
        ),
    );
}

test "stdlib_package a missing module or file passes on the reader's reason" {
    const state = try withFiles(a, "{}");
    defer api.nilu_close(state);
    try std.testing.expectEqualStrings(
        "main.nilu:1: cannot find module 'zzz': no file 'zzz.nilu'|main.nilu:2: cannot find file 'none': no file 'none'|cannot find file 'none': no file 'none'",
        try run(state,
            \\local ok1, m = pcall(function() return require("zzz") end)
            \\local ok2, d = pcall(function() return dofile("none") end)
            \\local _, l = loadfile("none")
            \\return m .. "|" .. d .. "|" .. l
        ),
    );
}

test "stdlib_package a cycle is refused with its links, and the chain is clean afterwards" {
    // After the refusal, `t` must resolve from the top again: a stale chain
    // would name c/b.nilu as the asker and find c/t.nilu instead.
    const state = try withFiles(a,
        \\{["c/a.nilu"] = "return require('b')", ["c/b.nilu"] = "return require('a')",
        \\ ["c/t.nilu"] = "return 'stale'", ["t.nilu"] = "return 'clean'"}
    );
    defer api.nilu_close(state);
    try std.testing.expectEqualStrings(
        "c/b.nilu:1: cannot load module 'a' while it is loading (c/a.nilu -> c/b.nilu -> c/a.nilu)|clean|false",
        try run(state,
            \\local _, why = pcall(require, "c.a")
            \\return why .. "|" .. require("t") .. "|" .. tostring(package.loaded["c/a.nilu"] ~= nil)
        ),
    );
}

test "stdlib_package a module that fails is not cached and fails again" {
    const state = try withFiles(a, "{[\"f.nilu\"] = \"tries = (tries or 0) + 1 error('boom')\", [\"s.nilu\"] = \"x =\"}");
    defer api.nilu_close(state);
    try std.testing.expectEqualStrings(
        "f.nilu:1: boom|f.nilu:1: boom|2|s.nilu:1:4: unexpected symbol near <eof>",
        try run(state,
            \\local _, one = pcall(require, "f")
            \\local _, two = pcall(require, "f")
            \\local _, syntax = pcall(require, "s")
            \\return one .. "|" .. two .. "|" .. tostring(tries) .. "|" .. syntax
        ),
    );
}

test "stdlib_package text with a zero byte and a reader's wrong answer are refused" {
    const state = try withFiles(a, "{[\"z.nilu\"] = \"return 1\\0\"}");
    defer api.nilu_close(state);
    try std.testing.expectEqualStrings("z.nilu: a zero byte, which a source may not contain", try run(state, "return select(2, pcall(require, 'z'))"));
    try expectOk(api.nilu_loadnamed(state, "return function() return 1, 2 end", "=bad", null));
    try expectOk(api.nilu_call(state, 0, 1));
    try expectOk(api.nilu_setreader(state));
    try std.testing.expectEqualStrings("the reader must answer a key and a text, or nil and a reason", try run(state, "return select(2, pcall(require, 'z'))"));
}

test "stdlib_package dofile passes on every result and loadfile takes a mode and an environment" {
    const state = try withFiles(a, "{[\"lib/run.nilu\"] = \"return 'ran', x\"}");
    defer api.nilu_close(state);
    try std.testing.expectEqualStrings("ran nil 2|ran 40|nil attempt to load a text chunk (mode is 'b')", try run(state,
        \\local r, x = dofile("lib/run.nilu")
        \\local n = select("#", dofile("lib/run.nilu"))
        \\local g = loadfile("lib/run.nilu", "t", {x = 40})
        \\local r2, x2 = g()
        \\local f, why = loadfile("lib/run.nilu", "b")
        \\return r .. " " .. tostring(x) .. " " .. tostring(n) .. "|" .. r2 .. " " .. tostring(x2) .. "|" .. tostring(f) .. " " .. why
    ));
}

test "stdlib_package load compiles text with a name, a mode and an environment" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    try expectOk(api.nilu_openlibs(state));
    try std.testing.expectEqualStrings(
        "3|nil c:1:3: unexpected symbol near <eof>|nil attempt to load a text chunk (mode is 'b')|5|e:1: attempt to index a nil value (upvalue '_ENV')|nil a zero byte, which a source may not contain|bad argument #1 to 'load' (string expected, got number)",
        try run(state,
            \\local out = {}
            \\out[1] = tostring(load("return 1 + 2")())
            \\out[2] = tostring(select(1, load("x=", "=c"))) .. " " .. select(2, load("x=", "=c"))
            \\out[3] = tostring(select(1, load("return 1", "c", "b"))) .. " " .. select(2, load("return 1", "c", "b"))
            \\out[4] = tostring(load("return y", "=e", "t", {y = 5})())
            \\out[5] = select(2, pcall(load("return y", "=e", "t", nil)))
            \\out[6] = tostring(select(1, load("return 1\0"))) .. " " .. select(2, load("return 1\0"))
            \\out[7] = select(2, pcall(load, 1))
            \\return table.concat(out, "|")
        ),
    );
}

fn native(_: *runtime.State) callconv(.c) c_int {
    return 0;
}

test "stdlib_package nilu_setenv and nilu_setreader refuse what they cannot take" {
    const state = try api.create(a);
    defer api.nilu_close(state);
    // setenv: a native is not a loaded chunk; nothing is popped.
    try expectOk(api.nilu_pushcfunction(state, native));
    try expectOk(api.nilu_newtable(state));
    try std.testing.expectEqual(api.Status.type, api.nilu_setenv(state, 1));
    try std.testing.expectEqual(@as(c_int, 2), api.nilu_gettop(state));
    _ = api.nilu_settop(state, 0);
    // A chunk that reads no global has no _ENV; the call still succeeds and pops.
    try expectOk(api.nilu_loadstring(state, "return 7", null));
    try expectOk(api.nilu_pushnil(state));
    try expectOk(api.nilu_setenv(state, 1));
    try std.testing.expectEqual(@as(c_int, 1), api.nilu_gettop(state));
    try expectOk(api.nilu_call(state, 0, 1));
    try std.testing.expectEqual(@as(f64, 7), api.nilu_tonumberx(state, -1, null));
    _ = api.nilu_settop(state, 0);
    // setreader: a number is refused and stays; nil removes the reader.
    try expectOk(api.nilu_pushnumber(state, 1));
    try std.testing.expectEqual(api.Status.type, api.nilu_setreader(state));
    try std.testing.expectEqual(@as(c_int, 1), api.nilu_gettop(state));
    _ = api.nilu_settop(state, 0);
    try expectOk(api.nilu_pushcfunction(state, native));
    try expectOk(api.nilu_setreader(state));
    try expectOk(api.nilu_getreader(state));
    try std.testing.expectEqual(@as(c_int, @backingInt(api.Type.function)), api.nilu_type(state, -1));
    try expectOk(api.nilu_pushnil(state));
    try expectOk(api.nilu_setreader(state));
    try expectOk(api.nilu_getreader(state));
    try std.testing.expectEqual(@as(c_int, @backingInt(api.Type.nil)), api.nilu_type(state, -1));
}

test "stdlib_package the reader is a collector root" {
    // The reader closure and the files table it holds are reachable from the
    // state alone once the stack is empty.
    const state = try withFiles(a, "{[\"kept.nilu\"] = \"return 'kept'\"}");
    defer api.nilu_close(state);
    state.collect();
    try std.testing.expectEqualStrings("kept", try run(state, "return require('kept')"));
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    const state = try withFiles(allocator, "{[\"m.nilu\"] = \"return {1, 2, 3}\"}");
    defer api.nilu_close(state);
    _ = api.nilu_settop(state, 0);
    try expectOk(api.nilu_loadnamed(state, "local t, k = require('m') return #t + #k", "@main.nilu", null));
    // The library turns its own shortage into a runtime failure carrying the
    // prepared sentence (manual 8.4); that is a shortage too.
    const status = api.nilu_call(state, 0, 1);
    if (status == .runtime and std.mem.eql(u8, std.mem.span(api.nilu_tolstring(state, -1, null).?), "not enough memory")) return error.OutOfMemory;
    try expectOk(status);
    try std.testing.expectEqual(@as(f64, 9), api.nilu_tonumberx(state, -1, null));
}

test "stdlib_package every allocation failure in a require releases what it made" {
    try allocation_failures.checkAll(a, allocationCase, .{});
}
