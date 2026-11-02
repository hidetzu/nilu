const std = @import("std");
const runtime = @import("runtime.zig");

/// A callee owns only this suffix of the stack. Rollback closes its captured
/// cells before dropping either values or frames; caller slots remain roots.
pub const Window = struct {
    base: usize,
    frames: usize,

    pub fn arguments(state: *const runtime.State, count: usize) error{InvalidBytecode}!Window {
        if (count > state.top()) return error.InvalidBytecode;
        return .{ .base = state.stack.items.len - count, .frames = state.frames.items.len };
    }

    pub fn above(state: *const runtime.State) Window {
        return .{ .base = state.stack.items.len, .frames = state.frames.items.len };
    }

    /// Drops the window. Its to-be-closed variables wait on the closing list
    /// for the boundary that catches the failure (`rollbackAndClose`), so
    /// they close with every frame above it gone, as Lua closes them.
    pub fn rollback(window: Window, state: *runtime.State) void {
        // A yield keeps the coroutine's frames and stack for the resume (ADR 0013).
        if (state.yielding) return;
        state.closeFrom(window.base);
        runtime.cutStack(&state.stack, window.base);
        state.frames.shrinkRetainingCapacity(window.frames);
        state.frameCountChanged();
    }

    /// The rollback of a boundary that catches a failure: the frames above
    /// it are dropped first, then the window's to-be-closed variables close,
    /// innermost first, and then its values go.
    pub fn rollbackAndClose(window: Window, state: *runtime.State) void {
        if (state.yielding) return;
        state.frames.shrinkRetainingCapacity(window.frames);
        state.frameCountChanged();
        if (state.closing.items.len != 0 and state.closing.items[state.closing.items.len - 1].slot >= window.base) @import("vm.zig").closeOnFailure(state, window.base);
        window.rollback(state);
    }

    /// Callee results are trailing slots, potentially overlapping arguments.
    pub fn results(window: Window, state: *runtime.State, count: usize) void {
        window.resultsAt(state, count, window.base);
    }

    /// The results moved to `destination`, at or below the window's base.
    pub fn resultsAt(window: Window, state: *runtime.State, count: usize, destination: usize) void {
        std.debug.assert(count <= state.stack.items.len - window.base and destination <= window.base);
        state.closeFrom(destination);
        // One result, a C function's usual answer: one store, without the
        // loop's setup.
        if (count == 1)
            state.stack.items[destination] = state.stack.items[state.stack.items.len - 1]
        else
            runtime.moveDown(state.stack.items[destination..][0..count], state.stack.items[state.stack.items.len - count ..]);
        runtime.cutStack(&state.stack, destination + count);
        state.frames.shrinkRetainingCapacity(window.frames);
        state.frameCountChanged();
    }

    /// `resultsAt` for a C function a script's call ran, its results into
    /// the slot that held it: the frame below is that script's, in the same
    /// run, so it is the base (as `popFrameInChain` has it).
    pub fn resultsIntoCallee(window: Window, state: *runtime.State, count: usize) void {
        const destination = window.base - 1;
        std.debug.assert(count <= state.stack.items.len - window.base);
        state.closeFrom(destination);
        if (count == 1)
            state.stack.items[destination] = state.stack.items[state.stack.items.len - 1]
        else
            runtime.moveDown(state.stack.items[destination..][0..count], state.stack.items[state.stack.items.len - count ..]);
        runtime.cutStack(&state.stack, destination + count);
        state.frames.items.len = window.frames;
        state.frame_base = state.frames.items[window.frames - 1].base;
        if (std.debug.runtime_safety) std.debug.assert(state.frame_base == state.base());
    }
};

/// The nearest protected boundary owns its handler and recursion guard.
pub const Protection = struct {
    handler: ?runtime.Function = null,
    running: bool = false,
};

/// A failure record an entry holds. Entries are made on every call and almost
/// never hold one, and the record is hundreds of bytes: as an optional it was
/// written whole on every entry, null included. Here absence is a flag and the
/// record is left undefined until one is put.
pub const HeldFailure = struct {
    present: bool = false,
    record: runtime.FailureRecord = undefined,

    pub fn get(held: *const HeldFailure) ?runtime.FailureRecord {
        return if (held.present) held.record else null;
    }

    pub fn put(held: *HeldFailure, record: runtime.FailureRecord) void {
        held.record = record;
        held.present = true;
    }
};

/// One execution entry, shared by script and native calls. Suspended failures
/// belong to the caller and remain collector roots while this entry runs. This
/// object is activated only after it reaches its final address on the host stack.
pub const Context = struct {
    previous: ?*Context = null,
    suspended: HeldFailure = .{},
    window: Window,
    reserved_origin: ?*runtime.FailureOrigin = null,
    roots: []const runtime.Value = &.{},
    raised: HeldFailure = .{},
    api_memory_failure: bool = false,
    protection: ?*Protection = null,

    /// Sets every field of an entry made on the host stack as `undefined`,
    /// leaving the held records' bytes alone. A struct literal of this type
    /// is written whole, the undefined records included, on every call.
    pub fn begin(context: *Context, window: Window) void {
        // A field added to Context must be set here too.
        comptime std.debug.assert(@typeInfo(Context).@"struct".field_names.len == 8);
        context.previous = null;
        context.suspended.present = false;
        context.window = window;
        context.reserved_origin = null;
        context.roots = &.{};
        context.raised.present = false;
        context.api_memory_failure = false;
        context.protection = null;
    }

    // A record is large and almost always absent on entry, so it is copied
    // only when there is one.
    pub fn enter(context: *Context, state: *runtime.State) void {
        context.previous = state.execution;
        if (state.failure) |record| {
            context.suspended.put(record);
            state.failure = null;
        }
        state.execution = context;
    }

    pub fn leave(context: *Context, state: *runtime.State, success: bool) void {
        std.debug.assert(state.execution == context);
        state.execution = context.previous;
        // The host's call has returned: an interruption stops nothing more.
        if (context.previous == null) state.interrupted = false;
        // A top-level success clears old failures. Nested success restores only
        // the caller's record, never the callee's caught/internal failure.
        if (!success) return;
        if (context.previous != null) {
            if (context.suspended.get()) |record| {
                state.failure = record;
                return;
            }
        }
        // Most calls end with no record: a test, not a store of the whole
        // optional record.
        if (state.failure != null) state.failure = null;
    }
};
