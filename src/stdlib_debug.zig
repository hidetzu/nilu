//! The debug library's reading part (the owner's answer): `debug.traceback` and `debug.getinfo`, written against the C
//! API's nilu_getinfo. Nothing here changes a function from outside.
const std = @import("std");
const api = @import("c_api.zig");
const stdlib = @import("stdlib.zig");

const Call = stdlib.Call;
const Error = stdlib.Error;
const entry = stdlib.entry;

pub fn open(call: Call) Error!void {
    try stdlib.openTable(call, "debug", &.{
        .{ .name = "getinfo", .function = entry("getinfo", getinfo) },
        .{ .name = "traceback", .function = entry("traceback", traceback) },
    });
}

/// A leading thread argument, as Lua's getthread: its stack index and how
/// many arguments it took.
fn thread(call: Call) struct { index: c_int, shift: c_int } {
    return if (call.typeAt(1) == .thread) .{ .index = 1, .shift = 1 } else .{ .index = 0, .shift = 0 };
}

fn setString(call: Call, key: []const u8, value: []const u8) Error!void {
    try call.push(key);
    try call.push(value);
    try call.check(api.nilu_rawset(call.state, -3));
}

fn setInteger(call: Call, key: []const u8, value: i64) Error!void {
    try call.push(key);
    try call.pushInteger(value);
    try call.check(api.nilu_rawset(call.state, -3));
}

fn setBoolean(call: Call, key: []const u8, value: bool) Error!void {
    try call.push(key);
    try call.pushBoolean(value);
    try call.check(api.nilu_rawset(call.state, -3));
}

/// debug.getinfo([thread,] f [, what]): a table about the function `f`, or
/// the one running at level `f`; nil when there is no such level.
fn getinfo(call: Call) Error!c_int {
    const t = thread(call);
    const what = try call.optString(t.shift + 2, "flnSrtu");
    if (what.len > 0 and what[0] == '>') return call.argumentError(t.shift + 2, "invalid option");
    var options: [32]u8 = undefined;
    if (what.len + 1 > options.len) return call.argumentError(t.shift + 2, "invalid option");
    var ar = api.Debug{};
    var answered: c_int = undefined;
    if (call.typeAt(t.shift + 1) == .function) {
        options[0] = '>';
        @memcpy(options[1..][0..what.len], what);
        options[what.len + 1] = 0;
        try call.pushValue(t.shift + 1);
        answered = api.nilu_getinfo(call.state, t.index, 0, @ptrCast(&options), &ar);
    } else {
        if (call.typeAt(t.shift + 1) != .number) return call.argumentError(t.shift + 1, "function or level expected");
        const level = try call.checkInteger(t.shift + 1);
        @memcpy(options[0..what.len], what);
        options[what.len] = 0;
        // Counted from the caller of getinfo; another thread's from its top.
        if (level < 0 or level > std.math.maxInt(c_int)) {
            try call.pushNil();
            return 1;
        }
        answered = api.nilu_getinfo(call.state, t.index, @intCast(level), @ptrCast(&options), &ar);
    }
    if (answered < 0) return call.argumentError(t.shift + 2, "invalid option");
    if (answered == 0) {
        try call.pushNil();
        return 1;
    }
    // nilu_getinfo pushed the function for 'f' and the lines for 'L'.
    const pushed: c_int = @as(c_int, @intFromBool(std.mem.indexOfScalar(u8, what, 'f') != null)) + @intFromBool(std.mem.indexOfScalar(u8, what, 'L') != null);
    try call.check(api.nilu_newtable(call.state));
    for (what) |letter| switch (letter) {
        'S' => {
            try setString(call, "source", std.mem.span(ar.source));
            try setString(call, "short_src", std.mem.sliceTo(&ar.short_src, 0));
            try setString(call, "what", std.mem.span(ar.what));
            try setInteger(call, "linedefined", ar.linedefined);
            try setInteger(call, "lastlinedefined", ar.lastlinedefined);
        },
        'l' => try setInteger(call, "currentline", ar.currentline),
        'n' => {
            if (ar.name) |name| try setString(call, "name", std.mem.span(name));
            try setString(call, "namewhat", std.mem.span(ar.namewhat));
        },
        'u' => {
            try setInteger(call, "nups", ar.nups);
            try setInteger(call, "nparams", ar.nparams);
            try setBoolean(call, "isvararg", ar.isvararg != 0);
        },
        't' => {
            try setBoolean(call, "istailcall", ar.istailcall != 0);
            try setInteger(call, "extraargs", ar.extraargs);
        },
        'r' => {
            try setInteger(call, "ftransfer", 0);
            try setInteger(call, "ntransfer", 0);
        },
        else => {},
    };
    var slot: c_int = -1 - pushed;
    if (std.mem.indexOfScalar(u8, what, 'f') != null) {
        try call.push("func");
        try call.pushValue(slot - 1);
        try call.check(api.nilu_rawset(call.state, -3));
        slot += 1;
    }
    if (std.mem.indexOfScalar(u8, what, 'L') != null) {
        try call.push("activelines");
        try call.pushValue(slot - 1);
        try call.check(api.nilu_rawset(call.state, -3));
    }
    return 1;
}

/// How luaL_traceback names a function in a line.
fn describe(buffer: []u8, ar: *const api.Debug) []const u8 {
    const namewhat = std.mem.span(ar.namewhat);
    if (namewhat.len > 0) return std.fmt.bufPrint(buffer, "{s} '{s}'", .{ namewhat, std.mem.span(ar.name.?) }) catch "?";
    const what = std.mem.span(ar.what);
    if (std.mem.eql(u8, what, "main")) return "main chunk";
    if (std.mem.eql(u8, what, "Lua")) return std.fmt.bufPrint(buffer, "function <{s}:{d}>", .{ std.mem.sliceTo(&ar.short_src, 0), ar.linedefined }) catch "?";
    return "?";
}

/// debug.traceback([thread,] [message [, level]]): the message, then
/// `stack traceback:` and a line per level, the middle left out past 21 as
/// luaL_traceback does. A message that is not a string or nil comes back
/// as it is.
fn traceback(call: Call) Error!c_int {
    const t = thread(call);
    const message_type = call.typeAt(t.shift + 1);
    if (message_type != .string and message_type != .nil and message_type != .none) {
        try call.pushValue(t.shift + 1);
        return 1;
    }
    const first_level = try call.optInteger(t.shift + 2, if (t.index == 0) 1 else 0);
    var text = try stdlib.Buffer.init(call, 128);
    if (message_type == .string) {
        try text.append(call.bytesAt(t.shift + 1));
        try text.appendByte('\n');
    }
    try text.append("stack traceback:");
    if (first_level >= 0 and first_level <= std.math.maxInt(c_int)) {
        var ar = api.Debug{};
        var levels: c_int = 0;
        while (api.nilu_getinfo(call.state, t.index, @as(c_int, @intCast(first_level)) + levels, "Sln", &ar) == 1) levels += 1;
        var shown: c_int = 0;
        while (shown < levels) : (shown += 1) {
            if (levels > 21 and shown == 10) {
                var skip: [64]u8 = undefined;
                try text.append(std.fmt.bufPrint(&skip, "\n\t...\t(skipping {d} levels)", .{levels - 21}) catch "\n\t...");
                shown = levels - 11;
            }
            _ = api.nilu_getinfo(call.state, t.index, @as(c_int, @intCast(first_level)) + shown, "Sln", &ar);
            var line: [256]u8 = undefined;
            var name: [192]u8 = undefined;
            const where = if (ar.currentline > 0)
                std.fmt.bufPrint(&line, "\n\t{s}:{d}: in ", .{ std.mem.sliceTo(&ar.short_src, 0), ar.currentline }) catch "\n\t?: in "
            else
                std.fmt.bufPrint(&line, "\n\t{s}: in ", .{std.mem.sliceTo(&ar.short_src, 0)}) catch "\n\t?: in ";
            try text.append(where);
            try text.append(describe(&name, &ar));
        }
    }
    try text.finish();
    return 1;
}
