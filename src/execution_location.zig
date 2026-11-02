//! Internal location snapshots for future public diagnostics. This does not
//! decide C pointer lifetimes, signed levels or last-call publication rules.
const std = @import("std");
const runtime = @import("runtime.zig");
const chunk_id = @import("chunk_id.zig");

/// A runtime location owns the already-formatted chunk ID and a line. It has
/// no source/AST/prototype pointers, C integer conversion or borrowed lifetime.
pub const Location = struct {
    chunk: [chunk_id.capacity]u8 = @splat(0),
    length: usize = 0,
    line: usize,

    /// The caller supplies a bounded display ID, not an unformatted C name.
    pub fn init(display_name: []const u8, line: usize) Location {
        std.debug.assert(display_name.len < chunk_id.capacity);
        var result = Location{ .length = display_name.len, .line = line };
        @memcpy(result.chunk[0..display_name.len], display_name);
        return result;
    }

    pub fn name(location: *const Location) []const u8 {
        return location.chunk[0..location.length];
    }
};

/// Snapshot a live caller of the running native: 1 is its immediate caller.
/// Native callers are [C]:0; no running native or an absent level is unknown.
pub fn callerFrame(state: *const runtime.State, level: usize) ?*const runtime.Frame {
    const frames = state.frames.items;
    if (level == 0 or level >= frames.len or frames[frames.len - 1].function == .closure) return null;
    return &frames[frames.len - 1 - level];
}

pub fn caller(state: *const runtime.State, level: usize) ?Location {
    const frame = callerFrame(state, level) orelse return null;
    if (frame.function != .closure) return Location.init("[C]", 0);
    const position = frame.position() orelse return null;
    return Location.init(frame.function.closure.prototype.displayName(), position.line);
}

/// Active propagation only. A protected call may clear this record; publishing
/// the last completed C call's location is separate from active VM failure.
pub fn activeFailure(state: *const runtime.State) ?Location {
    return if (state.failure) |record| record.location else null;
}

/// A fresh native failure belongs to its nearest script caller. Attach the
/// location while the native frame is still live, before handler dispatch.
/// Relayed records keep their original position/location as an indivisible pair.
pub fn attachNativeCaller(state: *const runtime.State, record: *runtime.FailureRecord) void {
    if (record.position != null or record.location != null) return;
    var index = state.frames.items.len;
    while (index > 0) {
        index -= 1;
        const frame = state.frames.items[index];
        if (frame.function != .closure) continue;
        const position = frame.position() orelse continue;
        record.position = position;
        record.location = Location.init(frame.function.closure.prototype.displayName(), position.line);
        return;
    }
}
