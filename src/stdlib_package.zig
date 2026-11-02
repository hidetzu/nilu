//! Loading code (ADR 0003, manual 10.7). `load` compiles a string and needs
//! no host. `require`, `dofile` and `loadfile` ask the reader the host gave
//! with nilu_setreader for a key and a text; the core opens no file
//! (ADR 0003). `package.loaded` caches modules under the key the reader
//! answered, so two files of the same name in different places are two
//! modules. The three share two upvalues: the `package.loaded` table and the
//! chain of keys being loaded, which names the file a nested `require` comes
//! from and refuses a cycle. `require` has a third, `package.preload`'s
//! table, asked before the reader (the owner's answer).
const std = @import("std");
const api = @import("c_api.zig");
const stdlib = @import("stdlib.zig");

const Call = stdlib.Call;
const Error = stdlib.Error;
const entry = stdlib.entry;

const loaded_upvalue = 1;
const chain_upvalue = 2;
const preload_upvalue = 3;

pub fn open(call: Call) Error!void {
    try call.check(api.nilu_newtable(call.state));
    try call.check(api.nilu_newtable(call.state));
    // The standard tables are modules already loaded, as in Lua: `require
    // "string"` answers the table without asking the reader.
    for ([_][:0]const u8{ "string", "table", "math", "utf8" }) |name| {
        try call.push(name);
        try call.check(api.nilu_getglobal(call.state, name.ptr));
        try call.check(api.nilu_settable(call.state, -3));
    }
    try call.push("loaded");
    try call.pushValue(-2);
    try call.check(api.nilu_settable(call.state, -4));
    // package.preload: the table require keeps, as Lua's keeps its own
    // even when the field is replaced.
    try call.check(api.nilu_newtable(call.state));
    try call.push("preload");
    try call.pushValue(-2);
    try call.check(api.nilu_settable(call.state, -5));
    try call.check(api.nilu_newtable(call.state));
    for ([_]stdlib.Registration{
        .{ .name = "require", .function = entry("require", require) },
        .{ .name = "dofile", .function = entry("dofile", doFile) },
        .{ .name = "loadfile", .function = entry("loadfile", loadFile) },
    }) |function| {
        const preload = function.function == entry("require", require);
        try call.pushValue(-3);
        try call.pushValue(-2);
        if (preload) try call.pushValue(-4);
        try call.check(api.nilu_pushcclosure(call.state, function.function, if (preload) 3 else 2));
        try call.check(api.nilu_setglobal(call.state, function.name.ptr));
    }
    call.pop(3);
    try call.check(api.nilu_setglobal(call.state, "package"));
    try call.pushFunction(entry("load", load));
    try call.check(api.nilu_setglobal(call.state, "load"));
}

const Answer = enum { found, missing, no_reader };

/// Asks the reader for the argument at `name_index`. `found` leaves the key
/// and the text on top; `missing` leaves the reason; `no_reader` leaves
/// nothing. The chain is at `chain_index`.
fn ask(call: Call, name_index: c_int, chain_index: c_int, kind: []const u8) Error!Answer {
    try call.check(api.nilu_getreader(call.state));
    if (call.typeAt(-1) == .nil) {
        call.pop(1);
        return .no_reader;
    }
    try call.pushValue(name_index);
    try pushInnermost(call, chain_index);
    try call.push(kind);
    try call.check(api.nilu_call(call.state, 3, 2));
    if (call.typeAt(-2) == .nil) {
        call.remove(-2);
        return .missing;
    }
    if (call.typeAt(-2) != .string or call.typeAt(-1) != .string)
        return call.raise("the reader must answer a key and a text, or nil and a reason");
    return .found;
}

/// The key of the file being loaded now, or nil when none is.
fn pushInnermost(call: Call, chain_index: c_int) Error!void {
    const depth = chainDepth(call, chain_index);
    if (depth == 0) return call.pushNil();
    try call.pushInteger(@intCast(depth));
    try call.check(api.nilu_rawget(call.state, chain_index));
}

fn chainDepth(call: Call, chain_index: c_int) usize {
    _ = api.nilu_rawlen(call.state, chain_index);
    const depth = call.numberAt(-1);
    call.pop(1);
    return @intFromFloat(depth);
}

/// Compiles the text at -1 under the key at -2, replacing the text with the
/// function. A syntax failure leaves its message on top and answers false.
fn compile(call: Call, key_index: c_int) Error!bool {
    const text = call.bytesAt(-1);
    if (std.mem.indexOfScalar(u8, text, 0) != null) {
        call.pop(1);
        var buffer: [512]u8 = undefined;
        const key = call.bytesAt(key_index);
        try call.push(std.fmt.bufPrint(&buffer, "{s}: a zero byte, which a source may not contain", .{key}) catch "a zero byte, which a source may not contain");
        return false;
    }
    var name_buffer: [4096]u8 = undefined;
    const key = call.bytesAt(key_index);
    if (key.len + 2 > name_buffer.len or std.mem.indexOfScalar(u8, key, 0) != null) {
        call.pop(1);
        try call.push("the reader's key is too long or holds a zero byte");
        return false;
    }
    name_buffer[0] = '@';
    @memcpy(name_buffer[1..][0..key.len], key);
    name_buffer[key.len + 1] = 0;
    const source = api.nilu_tolstring(call.state, -1, null).?;
    const status = api.nilu_loadnamed(call.state, source, @ptrCast(&name_buffer), null);
    switch (status) {
        .ok => {
            call.remove(-2);
            return true;
        },
        .syntax => {
            call.remove(-2);
            return false;
        },
        else => try call.check(status),
    }
    unreachable;
}

/// Runs the function at -1 with `arguments` values pushed above it, with
/// `key_index`'s key on the chain while it runs. The chain is put back
/// whatever the call answers; a failure is passed on as it came.
fn runLoaded(call: Call, chain_index: c_int, key_index: c_int, arguments: c_int, results: c_int) Error!void {
    const depth = chainDepth(call, chain_index);
    try call.pushInteger(@intCast(depth + 1));
    try call.pushValue(key_index);
    try call.check(api.nilu_rawset(call.state, chain_index));
    const status = api.nilu_call(call.state, arguments, results);
    try call.pushInteger(@intCast(depth + 1));
    try call.pushNil();
    try call.check(api.nilu_rawset(call.state, chain_index));
    try call.check(status);
}

fn raiseFormatted(call: Call, comptime format: []const u8, arguments: anytype) Error {
    var buffer: [1024]u8 = undefined;
    return call.raise(std.fmt.bufPrint(&buffer, format, arguments) catch format);
}

fn require(call: Call) Error!c_int {
    _ = try call.checkString(1);
    try call.setTop(1);
    try call.check(api.nilu_getupvalue(call.state, loaded_upvalue));
    try call.check(api.nilu_getupvalue(call.state, chain_upvalue));
    const loaded: c_int = 2;
    const chain: c_int = 3;
    // A name already in package.loaded (a standard table, or what the host or
    // a program put there) answers without the reader.
    try call.pushValue(1);
    try call.check(api.nilu_rawget(call.state, loaded));
    if (call.typeAt(-1) != .nil) return 1;
    call.pop(1);
    if (try fromPreload(call, loaded)) return 2;
    const name = call.bytesAt(1);
    switch (try ask(call, 1, chain, "module")) {
        .no_reader => return raiseFormatted(call, "cannot load module '{s}': no reader was given to this state", .{name}),
        .missing => return raiseFormatted(call, "cannot find module '{s}': {s}", .{ name, call.bytesAt(-1) }),
        .found => {},
    }
    const key: c_int = 4;
    try call.pushValue(key);
    try call.check(api.nilu_rawget(call.state, loaded));
    if (call.typeAt(-1) != .nil) return 1;
    call.pop(1);
    try refuseCycle(call, chain, key, name);
    if (!try compile(call, key)) return error.Raised;
    try call.pushValue(1);
    try call.pushValue(key);
    try runLoaded(call, chain, key, 2, 1);
    // The module's first result, else what it put in package.loaded itself,
    // else true.
    if (call.typeAt(-1) != .nil) {
        try call.pushValue(key);
        try call.pushValue(-2);
        try call.check(api.nilu_rawset(call.state, loaded));
    }
    call.pop(1);
    try call.pushValue(key);
    try call.check(api.nilu_rawget(call.state, loaded));
    if (call.typeAt(-1) == .nil) {
        call.pop(1);
        try call.pushValue(key);
        try call.pushBoolean(true);
        try call.check(api.nilu_rawset(call.state, loaded));
        try call.pushBoolean(true);
    }
    try call.pushValue(key);
    return 2;
}

/// A function in package.preload under the name is the module's loader,
/// called with the name and ":preload:" as Lua calls it; what it answers is
/// kept under the name, as from the reader. Anything else there is not a
/// loader, and the reader is asked, as Lua goes on to its next searcher.
/// Leaves the value and ":preload:" on top when it answers true.
fn fromPreload(call: Call, loaded: c_int) Error!bool {
    try call.check(api.nilu_getupvalue(call.state, preload_upvalue));
    try call.pushValue(1);
    try call.check(api.nilu_rawget(call.state, -2));
    call.remove(-2);
    if (call.typeAt(-1) != .function) {
        call.pop(1);
        return false;
    }
    try call.pushValue(1);
    try call.push(":preload:");
    try call.check(api.nilu_call(call.state, 2, 1));
    if (call.typeAt(-1) != .nil) {
        try call.pushValue(1);
        try call.pushValue(-2);
        try call.check(api.nilu_rawset(call.state, loaded));
    }
    call.pop(1);
    try call.pushValue(1);
    try call.check(api.nilu_rawget(call.state, loaded));
    if (call.typeAt(-1) == .nil) {
        call.pop(1);
        try call.pushValue(1);
        try call.pushBoolean(true);
        try call.check(api.nilu_rawset(call.state, loaded));
        try call.pushBoolean(true);
    }
    try call.push(":preload:");
    return true;
}

/// Refuses a key already on the chain, naming every link and the key again.
fn refuseCycle(call: Call, chain: c_int, key: c_int, name: []const u8) Error!void {
    const depth = chainDepth(call, chain);
    const wanted = call.bytesAt(key);
    var found = false;
    for (1..depth + 1) |i| {
        try call.pushInteger(@intCast(i));
        try call.check(api.nilu_rawget(call.state, chain));
        if (std.mem.eql(u8, call.bytesAt(-1), wanted)) found = true;
        call.pop(1);
    }
    if (!found) return;
    var buffer: [1024]u8 = undefined;
    var links: std.Io.Writer = .fixed(&buffer);
    for (1..depth + 1) |i| {
        try call.pushInteger(@intCast(i));
        try call.check(api.nilu_rawget(call.state, chain));
        links.print("{s} -> ", .{call.bytesAt(-1)}) catch {};
        call.pop(1);
    }
    links.print("{s}", .{wanted}) catch {};
    return raiseFormatted(call, "cannot load module '{s}' while it is loading ({s})", .{ name, links.buffered() });
}

/// dofile(path): the reader's text for the path, run here, every result
/// passed on; a failure is raised.
fn doFile(call: Call) Error!c_int {
    _ = try call.checkString(1);
    try call.setTop(1);
    try call.check(api.nilu_getupvalue(call.state, chain_upvalue));
    const chain: c_int = 2;
    const path = call.bytesAt(1);
    switch (try ask(call, 1, chain, "file")) {
        .no_reader => return raiseFormatted(call, "cannot load file '{s}': no reader was given to this state", .{path}),
        .missing => return raiseFormatted(call, "cannot find file '{s}': {s}", .{ path, call.bytesAt(-1) }),
        .found => {},
    }
    const key: c_int = 3;
    if (!try compile(call, key)) return error.Raised;
    // The results replace the function, from its slot up.
    const function = call.top();
    try runLoaded(call, chain, key, 0, stdlib.multret);
    return call.top() - function + 1;
}

/// loadfile(path [, mode [, env]]): the function, or nil and the reason;
/// nothing is raised for a file that cannot be read or compiled.
fn loadFile(call: Call) Error!c_int {
    _ = try call.checkString(1);
    const given = call.top();
    const mode = try call.optString(2, "bt");
    try call.setTop(3);
    try call.check(api.nilu_getupvalue(call.state, chain_upvalue));
    const chain: c_int = 4;
    if (!textAllowed(mode)) return answerFailure(call, "attempt to load a text chunk (mode is '{s}')", .{mode});
    const path = call.bytesAt(1);
    switch (try ask(call, 1, chain, "file")) {
        .no_reader => return answerFailure(call, "cannot load file '{s}': no reader was given to this state", .{path}),
        .missing => {
            var buffer: [1024]u8 = undefined;
            const reason = std.fmt.bufPrint(&buffer, "cannot find file '{s}': {s}", .{ path, call.bytesAt(-1) }) catch "cannot find file";
            return answerFailure(call, "{s}", .{reason});
        },
        .found => {},
    }
    const key: c_int = 5;
    if (!try compile(call, key)) return answerMessage(call);
    if (given >= 3) try setEnvironment(call, 3);
    return 1;
}

/// load(text [, chunkname [, mode [, env]]]): text only; the function, or nil
/// and the reason.
fn load(call: Call) Error!c_int {
    _ = try call.checkString(1);
    const given = call.top();
    const mode = try call.optString(3, "bt");
    if (!textAllowed(mode)) return answerFailure(call, "attempt to load a text chunk (mode is '{s}')", .{mode});
    try call.setTop(4);
    const text = call.bytesAt(1);
    if (std.mem.indexOfScalar(u8, text, 0) != null) return answerFailure(call, "a zero byte, which a source may not contain", .{});
    const source = api.nilu_tolstring(call.state, 1, null).?;
    const status = if (call.typeAt(2) == .nil)
        api.nilu_loadstring(call.state, source, null)
    else blk: {
        const name = try call.checkString(2);
        if (std.mem.indexOfScalar(u8, name, 0) != null) return answerFailure(call, "a chunk name cannot hold a zero byte", .{});
        break :blk api.nilu_loadnamed(call.state, source, api.nilu_tolstring(call.state, 2, null).?, null);
    };
    switch (status) {
        .ok => {},
        .syntax => return answerMessage(call),
        else => try call.check(status),
    }
    if (given >= 4) try setEnvironment(call, 4);
    return 1;
}

fn textAllowed(mode: []const u8) bool {
    return std.mem.indexOfScalar(u8, mode, 't') != null;
}

/// The function on top gets the value at `index` as its `_ENV`.
fn setEnvironment(call: Call, index: c_int) Error!void {
    try call.pushValue(index);
    try call.check(api.nilu_setenv(call.state, -2));
}

/// nil and the message on top.
fn answerMessage(call: Call) Error!c_int {
    try call.pushNil();
    call.insert(-2);
    return 2;
}

fn answerFailure(call: Call, comptime format: []const u8, arguments: anytype) Error!c_int {
    var buffer: [1024]u8 = undefined;
    try call.pushNil();
    try call.push(std.fmt.bufPrint(&buffer, format, arguments) catch format);
    return 2;
}
