const std = @import("std");
const runtime = @import("runtime.zig");
const execution = @import("execution_context.zig");
const vm = @import("vm.zig");

pub const Result = union(enum) { success: usize, failure: runtime.FailureKind };
pub fn errorFromKind(kind: runtime.FailureKind) vm.Error {
    return switch (kind) {
        .out_of_memory => error.OutOfMemory,
        .stack_limit => error.StackLimit,
        .call_depth => error.CallDepth,
        .interrupted => error.Interrupted,
        .type_error => error.Type,
        .runtime_error => error.Runtime,
        .pending_feature => error.PendingFeature,
        .invalid_bytecode => error.InvalidBytecode,
        .invalid_native_result => error.InvalidNativeResult,
    };
}

/// Internal callable-value boundary. The callee precedes the top count
/// arguments. Reserve transport before execution; setup errors preserve inputs.
/// A target error replaces function+arguments with its carried value. Protected
/// capture removes provenance. callWithHandler adds internal pre-unwind handling.
/// Full public call/pcall remains a separate increment.
pub fn call(state: *runtime.State, count: usize, protected: bool, diagnostic: *?vm.Diagnostic) vm.Error!Result {
    return callWithHandler(state, count, protected, null, diagnostic);
}

/// Handler is validated before target execution; a protected no-handler entry
/// still forms a boundary, so an outer handler cannot observe caught failures.
pub fn callWithHandler(state: *runtime.State, count: usize, protected: bool, handler: ?runtime.Value, diagnostic: *?vm.Diagnostic) vm.Error!Result {
    return callAdjusted(state, count, null, protected, handler, diagnostic);
}

/// Null requests all results; a fixed count drops extras or pads with nil.
/// Fixed requests past the available result window fail before target execution
/// and preserve function/arguments. Capacity for fixed results is reserved before
/// entry so adjustment cannot fail after the target has already run.
pub fn callAdjusted(state: *runtime.State, count: usize, requested: ?usize, protected: bool, handler: ?runtime.Value, diagnostic: *?vm.Diagnostic) vm.Error!Result {
    return callContinued(state, count, requested, protected, handler, null, diagnostic);
}

/// What a C function runs after a protected call of its that yielded (ADR 0013).
pub const Waiting = struct { k: runtime.KFunction, context: isize };

/// `callAdjusted`; with `waiting`, a protected call from a C function that a
/// yield may leave: the C function's frame then waits on `waiting.k` (Lua's
/// lua_pcallk), and the call answers `error.Yield`.
pub fn callContinued(state: *runtime.State, count: usize, requested: ?usize, protected: bool, handler: ?runtime.Value, waiting: ?Waiting, diagnostic: *?vm.Diagnostic) vm.Error!Result {
    diagnostic.* = null;
    state.has_last_call_location = false;
    errdefer state.has_last_call_location = false;
    if (handler) |value| {
        if (!protected or !value.isFunction()) return error.Type;
    }
    if (count >= state.top()) return error.InvalidBytecode;
    const base = state.stack.items.len - count - 1;
    if (state.interrupted and state.execution != null) {
        // The hook stopped the program: the call runs nothing and answers
        // the interruption with nil, as an interrupted call does.
        state.closeFrom(base);
        runtime.cutStack(&state.stack, base);
        state.stack.appendAssumeCapacity(.nil);
        state.failure = .{ .kind = .interrupted, .value = .nil, .origin = .native };
        return .{ .failure = .interrupted };
    }
    if (requested) |wanted| {
        if (wanted > runtime.State.max_stack - base) return error.StackLimit;
    }
    const callee = state.stack.items[base];
    const reserved = @max(state.stack.items.len, base + (requested orelse 0));
    try state.ensureOrigins(reserved);
    try runtime.growStack(&state.stack, state.open_cells.items, state.allocator, reserved);
    const token = try state.reserveFailureOrigin();
    var published = false;
    defer if (!published) state.releaseFailureOrigin(token);
    const caller_frame = state.frames.items.len -% 1;
    const yieldable = waiting != null and protected and state.frames.items.len != 0 and state.frames.items[caller_frame].function != .closure;
    // One unwinding yield records every waiting C function at once; a frame
    // holds at most one, so the frames bound them.
    if (yieldable) try state.continuations.ensureTotalCapacity(state.allocator, state.frames.items.len);
    const location_slot = state.call_location_depth;
    std.debug.assert(location_slot < state.call_locations.items.len);
    state.call_location_depth += 1;
    defer state.call_location_depth -= 1;
    var protection = execution.Protection{ .handler = if (handler) |value| value.asFunction() else null };
    // `begin` rather than a literal, which writes the held records too.
    var context: execution.Context = undefined;
    context.begin(.{ .base = base, .frames = state.frames.items.len });
    context.reserved_origin = token;
    context.protection = if (protected) &protection else null;
    context.enter(state);
    var captured = false;
    defer context.leave(state, captured);
    // A native's call back into the VM is a frame a resume cannot rebuild,
    // unless it names what to run after (ADR 0013): a yield under it is refused.
    if (!yieldable) state.non_yieldable += 1;
    defer if (!yieldable) {
        state.non_yieldable -= 1;
    };
    const produced = vm.runCallableWithArguments(state, count, diagnostic) catch |err| {
        if (err == error.Yield) {
            // Kept in frame order. A yield unwinds from the inside out, so a
            // C function further out records after one further in.
            var position = state.continuations.items.len;
            while (position > 0 and state.continuations.items[position - 1].frame > caller_frame) position -= 1;
            state.continuations.insertAssumeCapacity(position, .{ .frame = caller_frame, .base = base, .results = requested, .handler = protection.handler, .k = waiting.?.k, .context = waiting.?.context });
            return err;
        }
        const record = try catchFailure(state, context.window, if (callee.is(.closure)) callee.unpack().closure.prototype else null, err, true);
        state.barrier(&token.header);
        token.record = record;
        // The consumed function slot already reserved room for one failure.
        state.stack.appendAssumeCapacity(record.value);
        if (protected and record.kind != .interrupted) state.setOrigin(base, null) else {
            state.publishFailureOrigin(token);
            published = true;
            state.setOrigin(base, token);
        }
        captured = protected and record.kind != .interrupted;
        state.has_last_call_location = record.location != null;
        if (record.location) |location| {
            state.call_locations.items[location_slot] = location;
            state.last_call_location_index = location_slot;
        }
        return .{ .failure = record.kind };
    };
    // Success is a caught/completed boundary, not a transport of an old error.
    captured = true;
    state.has_last_call_location = false;
    return .{ .success = adjustResults(state, base, requested, produced) };
}

/// The `produced` results after the called function's slot `base` move down
/// to it, cut or padded with nil to `requested`. Answers how many there are.
pub fn adjustResults(state: *runtime.State, base: usize, requested: ?usize, produced: usize) usize {
    const wanted = requested orelse produced;
    const copied = @min(wanted, produced);
    state.closeFrom(base);
    std.mem.copyForwards(runtime.Value, state.stack.items[base..][0..copied], state.stack.items[base + 1 ..][0..copied]);
    runtime.cutStack(&state.stack, base + copied);
    // Fixed capacity was reserved before the call; all-results only shrinks.
    // Only missing results need padding.
    if (wanted != copied) state.setTop(@intCast(base + wanted - state.base())) catch unreachable;
    return wanted;
}

/// What a protected boundary does with a failure that reached it: the
/// sentence completed, the handler run, the window rolled back. Answers the
/// failure; an internal failure passes on.
/// `close` is false for a coroutine's own entry: a coroutine that failed
/// keeps its to-be-closed variables for `coroutine.close`, as Lua's does.
pub fn catchFailure(state: *runtime.State, window: execution.Window, prototype: ?*const runtime.Prototype, err: vm.Error, close: bool) vm.Error!runtime.FailureRecord {
    // Unfinished paths and host/internal misuse are never public language statuses.
    if (err == error.PendingFeature or err == error.InvalidBytecode or err == error.InvalidNativeResult) {
        drop(state, window, close);
        return err;
    }
    const completed = @import("runtime_diagnostic.zig").complete(state, prototype, err);
    if (completed == error.PendingFeature or completed == error.InvalidBytecode or completed == error.InvalidNativeResult) {
        drop(state, window, close);
        return completed;
    }
    const propagated = dispatch(state, completed);
    if (propagated == error.PendingFeature or propagated == error.InvalidBytecode or propagated == error.InvalidNativeResult) {
        drop(state, window, close);
        return propagated;
    }
    if (state.failure == null) return error.InvalidBytecode;
    // A `__close` that fails while closing replaces the failure.
    drop(state, window, close);
    return state.failure orelse error.InvalidBytecode;
}

fn drop(state: *runtime.State, window: execution.Window, close: bool) void {
    if (close) window.rollbackAndClose(state) else window.rollback(state);
}

/// Called at the raise before the failing script/native window unwinds.
/// A protected entry without a handler is still a stop boundary. The running
/// guard belongs to that boundary, so nested calls cannot reset it by catching.
pub fn dispatch(state: *runtime.State, err: vm.Error) vm.Error {
    switch (err) {
        error.OutOfMemory, error.Interrupted, error.PendingFeature, error.InvalidBytecode, error.InvalidNativeResult => return err,
        else => {},
    }
    const original = state.failure orelse return err;
    if (original.handled) return errorFromKind(original.kind);
    var current = state.execution;
    while (current) |context| : (current = context.previous) {
        const protection = context.protection orelse continue;
        // A script's `pcall` above this boundary is nearer, and has no
        // handler (ADR 0009).
        for (state.frames.items[@min(context.window.frames, state.frames.items.len)..]) |frame| {
            if (frame.protected_call) return err;
        }
        const handler = protection.handler orelse return err;
        if (protection.running) return err;
        protection.running = true;
        state.handlers_running += 1;
        state.updateCallLimit();
        defer {
            protection.running = false;
            state.handlers_running -= 1;
            state.updateCallLimit();
        }
        const window = execution.Window.above(state);
        defer window.rollback(state);
        // A handler runs where the failure happened; a yield there is refused.
        state.non_yieldable += 1;
        defer state.non_yieldable -= 1;
        state.setTop(@intCast(state.top() + 2)) catch return handlerFailed(state, original);
        state.stack.items[window.base] = .fromFunction(handler);
        state.stack.items[window.base + 1] = original.value;
        var diagnostic: ?vm.Diagnostic = null;
        const count = vm.runFunctionWithArguments(state, handler, 1, &diagnostic) catch |inner| {
            switch (inner) {
                error.Interrupted, error.PendingFeature, error.InvalidBytecode, error.InvalidNativeResult => return inner,
                else => return handlerFailed(state, original),
            }
        };
        var transformed = original;
        transformed.value = if (count == 0) .nil else state.stack.items[window.base + 1];
        transformed.handled = true;
        state.failure = transformed;
        return err;
    }
    return err;
}

fn handlerFailed(state: *runtime.State, original: runtime.FailureRecord) vm.Error {
    var record = original;
    record.kind = .runtime_error;
    record.value = .from(.{ .string = state.handling_failure });
    record.handled = true;
    if (record.diagnostic) |*diagnostic| diagnostic.kind = .runtime_error;
    state.failure = record;
    return error.Runtime;
}
