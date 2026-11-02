//! Resuming a coroutine (ADR 0013). The state switches to the coroutine's
//! stack, runs it as a protected entry until it returns, yields or fails, and
//! switches back with its values.
const std = @import("std");
const runtime = @import("runtime.zig");
const execution = @import("execution_context.zig");
const vm = @import("vm.zig");

pub const Outcome = union(enum) {
    /// The coroutine returned; this many results were pushed.
    finished: usize,
    /// The coroutine yielded; this many values were pushed.
    yielded: usize,
    /// The coroutine failed; its failure value was pushed.
    failed: runtime.FailureKind,
};

pub const Error = error{ OutOfMemory, StackLimit, InvalidBytecode, InvalidNativeResult, PendingFeature };

/// Resumes `thread`, a suspended coroutine, with the top `count` values of the
/// running thread's stack, which it consumes; pushes what the coroutine gave.
pub fn resumeThread(state: *runtime.State, thread: *runtime.Thread, count: usize) Error!Outcome {
    std.debug.assert(thread.status == .suspended);
    const arguments = state.stack.items[state.stack.items.len - count ..];
    const fresh = !thread.function.is(.nil);
    const saved = &thread.saved;
    // Room is taken before anything moves, so that running out of memory
    // here leaves the coroutine where it was waiting and the values where
    // they were.
    if (fresh) {
        try runtime.growStack(&saved.stack, saved.open_cells.items, state.allocator, saved.stack.items.len + count + 1);
        saved.stack.appendAssumeCapacity(thread.function);
    } else {
        // Waiting in the yield's native frame: its window gives way to the
        // values resume passes, which become that call's results.
        if (saved.frames.items.len == 0) return error.InvalidBytecode;
        const base = saved.frames.items[saved.frames.items.len - 1].base;
        if (base > saved.stack.items.len) return error.InvalidBytecode;
        try runtime.growStack(&saved.stack, saved.open_cells.items, state.allocator, base + count);
        _ = saved.frames.pop();
        runtime.cutStack(&saved.stack, base);
    }
    saved.stack.appendSliceAssumeCapacity(arguments);
    state.barrier(&thread.header);
    thread.function = .nil;
    state.closeFrom(state.stack.items.len - count);
    runtime.cutStack(&state.stack, state.stack.items.len - count);

    const resumer = enter(state, thread);
    var failed_at: ?@import("execution_location.zig").Location = null;
    const outcome = run(state, fresh, count, &failed_at);
    leave(state, thread, resumer);
    // For nilu_where(N, 0) a resume is a call: a success leaves nothing, a
    // failure is where the coroutine failed (the owner's answer).
    state.has_last_call_location = failed_at != null;
    if (failed_at) |location| {
        const slot = @min(state.call_location_depth, state.call_locations.items.len - 1);
        state.call_locations.items[slot] = location;
        state.last_call_location_index = slot;
    }

    const result = outcome catch |err| {
        thread.status = .dead;
        return err;
    };
    const values = switch (result) {
        .finished => |n| saved.stack.items[1..][0..n],
        .yielded => |n| saved.stack.items[saved.stack.items.len - n ..],
        .failed => saved.stack.items[0..1],
    };
    // Out of memory for the values: a coroutine that yielded still waits in
    // its yield, and the next resume gives that call its results; one that
    // returned or failed has ended.
    runtime.growStack(&state.stack, state.open_cells.items, state.allocator, state.stack.items.len + values.len) catch |err| {
        switch (result) {
            .yielded => thread.status = .suspended,
            else => finish(state, thread, result),
        }
        return err;
    };
    state.stack.appendSliceAssumeCapacity(values);
    switch (result) {
        .yielded => thread.status = .suspended,
        else => finish(state, thread, result),
    }
    return result;
}

/// Makes `thread` the running one and answers the thread that was. While it
/// runs, the one it was resumed from waits as `normal` and is reached
/// through `thread.resumer` (ADR 0013's roots): the host may have consumed
/// the only stack slot that held either of them.
fn enter(state: *runtime.State, thread: *runtime.Thread) *runtime.Thread {
    const resumer = state.running;
    resumer.status = .normal;
    state.frames_below += state.frames.items.len;
    state.updateCallLimit();
    state.switchTo(thread);
    state.barrier(&thread.header);
    thread.resumer = resumer;
    thread.status = .running;
    return resumer;
}

/// Gives the state back to `resumer`, which runs again.
fn leave(state: *runtime.State, thread: *runtime.Thread, resumer: *runtime.Thread) void {
    state.barrier(&thread.header);
    thread.resumer = null;
    state.switchTo(resumer);
    state.frames_below -= state.frames.items.len;
    state.updateCallLimit();
    resumer.status = .running;
}

/// A coroutine that returned or failed keeps only what `close` reports.
fn finish(state: *runtime.State, thread: *runtime.Thread, result: Outcome) void {
    thread.status = .dead;
    state.barrier(&thread.header);
    if (result == .failed) thread.failure_value = thread.saved.stack.items[0];
    // A failed coroutine's to-be-closed variables wait for `close`.
    const closing = thread.saved.closing;
    thread.saved.closing = .empty;
    thread.saved.deinit(state.allocator);
    state.barrier(&thread.header);
    thread.saved = .{};
    thread.saved.closing = closing;
}

/// Runs the switched-in coroutine as a protected entry over its whole stack.
fn run(state: *runtime.State, fresh: bool, count: usize, failed_at: *?@import("execution_location.zig").Location) Error!Outcome {
    var diagnostic: ?vm.Diagnostic = null;
    var protection = execution.Protection{};
    var context = execution.Context{ .window = .{ .base = 0, .frames = 0 }, .protection = &protection };
    context.enter(state);
    var captured = false;
    defer context.leave(state, captured);
    const produced = (if (fresh) vm.runCallableWithArguments(state, count, &diagnostic) else vm.continueThread(state, count, &diagnostic)) catch |err| {
        if (err == error.Yield) {
            state.yielding = false;
            return .{ .yielded = state.yielded };
        }
        const record = @import("failure_transport.zig").catchFailure(state, context.window, null, err, false) catch |internal| return switch (internal) {
            error.PendingFeature => error.PendingFeature,
            error.InvalidNativeResult => error.InvalidNativeResult,
            error.OutOfMemory => error.OutOfMemory,
            error.StackLimit => error.StackLimit,
            else => error.InvalidBytecode,
        };
        try runtime.growStack(&state.stack, state.open_cells.items, state.allocator, state.stack.items.len + 1);
        state.stack.appendAssumeCapacity(record.value);
        failed_at.* = record.location;
        captured = true;
        return .{ .failed = record.kind };
    };
    // The results sit after the function's slot; every frame has returned.
    captured = true;
    return .{ .finished = produced };
}

/// coroutine.close on a suspended or dead coroutine: its frames are dropped
/// and its open upvalues closed over the values they hold. Answers the value a
/// failed coroutine failed with, once.
pub fn close(state: *runtime.State, thread: *runtime.Thread) ?runtime.Value {
    std.debug.assert(thread.status == .suspended or thread.status == .dead);
    const saved = &thread.saved;
    // Its to-be-closed variables are closed in it, innermost first, with no
    // failure to pass; a yield there is refused, as in Lua. One that fails
    // passes its value to the rest and is what close answers.
    if (saved.closing.items.len != 0) {
        const resumer = enter(state, thread);
        // They receive the failure the coroutine died by, as Lua's do.
        state.failure = if (thread.failure_value) |value| .{ .kind = .runtime_error, .value = value, .origin = .native } else null;
        state.non_yieldable += 1;
        vm.closeOnFailure(state, 0);
        state.non_yieldable -= 1;
        state.barrier(&thread.header);
        if (state.failure) |record| thread.failure_value = record.value;
        leave(state, thread, resumer);
    }
    for (saved.open_cells.items) |cell| {
        state.barrier(&cell.header);
        cell.close(saved.stack.items[cell.storage.open]);
    }
    saved.deinit(state.allocator);
    saved.* = .{};
    state.barrier(&thread.header);
    thread.function = .nil;
    thread.status = .dead;
    const failure = thread.failure_value;
    state.barrier(&thread.header);
    thread.failure_value = null;
    return failure;
}
