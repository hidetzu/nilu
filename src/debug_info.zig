//! What `nilu_getinfo` answers about a running function or a function value
//! (Lua's lua_getinfo), for the library's `debug.getinfo` and
//! `debug.traceback` and the command's traceback.
const std = @import("std");
const runtime = @import("runtime.zig");
const chunk_id = @import("chunk_id.zig");

/// NiluDebug in the header. Strings are borrowed from the function's
/// prototype, which the state keeps until it closes.
pub const Debug = extern struct {
    source: [*:0]const u8 = "=[C]",
    short_src: [chunk_id.capacity]u8 = @splat(0),
    what: [*:0]const u8 = "C",
    name: ?[*:0]const u8 = null,
    namewhat: [*:0]const u8 = "",
    currentline: c_int = -1,
    linedefined: c_int = -1,
    lastlinedefined: c_int = -1,
    nups: u8 = 0,
    nparams: u8 = 0,
    isvararg: u8 = 1,
    istailcall: u8 = 0,
    extraargs: c_int = 0,
};

fn line(n: usize) c_int {
    return std.math.cast(c_int, n) orelse 0;
}

fn small(n: usize) u8 {
    return std.math.cast(u8, n) orelse 255;
}

/// What `S` and `u` say: about the function itself, wherever it runs.
pub fn describeFunction(function: runtime.Function, out: *Debug) void {
    out.* = .{};
    @memcpy(out.short_src[0..3], "[C]");
    switch (function) {
        .closure => |closure| {
            const prototype = closure.prototype;
            out.source = prototype.chunk_name.ptr;
            out.short_src = prototype.display_id;
            out.what = if (prototype.chunk) "main" else "Lua";
            out.linedefined = if (prototype.chunk) 0 else line(prototype.line_defined);
            out.lastlinedefined = if (prototype.chunk) 0 else line(prototype.last_line_defined);
            out.nups = small(closure.upvalues.len);
            out.nparams = small(prototype.parameters);
            out.isvararg = @intFromBool(prototype.vararg);
        },
        .c_closure => |closure| out.nups = small(closure.upvalues.len),
        .native => {},
    }
}

/// Fills `out` about frames[index], with the line it is at and the name it
/// was called by.
pub fn describeFrame(frames: []const runtime.Frame, index: usize, out: *Debug) void {
    const frame = frames[index];
    describeFunction(frame.function, out);
    if (frame.function == .closure) {
        if (frame.position()) |position| out.currentline = line(position.line);
    }
    const site = callSite(frames, index) orelse return;
    const kind = site.classification() orelse return;
    const text = site.text() orelse return;
    out.name = text.ptr;
    out.namewhat = kindWord(kind);
}

/// The call site of frames[index]: a native's own record, or the call
/// instruction its script caller is executing.
pub fn callSite(frames: []const runtime.Frame, index: usize) ?runtime.CallSite {
    const frame = frames[index];
    if (frame.function != .closure) return frame.callSite();
    if (index == 0) return null;
    const caller = frames[index - 1];
    if (caller.function != .closure) return null;
    const instruction = caller.instruction orelse return null;
    const prototype = caller.function.closure.prototype;
    return .{ .prototype = prototype, .instruction = instruction, .through_call = false };
}

pub fn kindWord(kind: runtime.CallKind) [*:0]const u8 {
    return switch (kind) {
        .local => "local",
        .global => "global",
        .field => "field",
        .method => "method",
        .upvalue => "upvalue",
        .constant => "constant",
        .for_iterator => "for iterator",
        .metamethod => "metamethod",
    };
}

/// The letters `nilu_getinfo` knows, as Lua's lua_getinfo.
pub fn validOptions(what: []const u8) bool {
    for (what) |letter| if (std.mem.indexOfScalar(u8, "SlnurtfL", letter) == null) return false;
    return true;
}
