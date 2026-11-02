const std = @import("std");
const runtime = @import("runtime.zig");
const execution = @import("execution_context.zig");

pub const Error = @import("vm.zig").Error;
/// What `nilu_yield` answers, for a callback to return.
pub const yield_result: c_int = -2;

/// Internal native-call protocol. The top argument_count slots form
/// the callback's entire visible window. Explicit nilu_error relays the carried
/// origin; bare NILU_FAIL raises Runtime/nil unless this entry returned API Memory. Public calls and misuse aborts
/// remain separate.
pub fn call(state: *runtime.State, function: runtime.Function, argument_count: usize) Error!usize {
    return callWithSite(state, function, argument_count, null);
}

pub fn callWithSite(state: *runtime.State, function: runtime.Function, argument_count: usize, site: ?runtime.CallSite) Error!usize {
    return callInto(state, function, try execution.Window.arguments(state, argument_count), site, .window);
}

/// Where a C function's results go: the base of its window, as a host call
/// wants them, or one below, into the slot that held the function, as a
/// script's call wants them (one copy instead of two).
pub const Destination = enum { window, callee };

/// `window` is the arguments' (`Window.arguments`), made by the caller.
pub fn callInto(state: *runtime.State, function: runtime.Function, window: execution.Window, site: ?runtime.CallSite, comptime destination: Destination) Error!usize {
    const callback = switch (function) {
        .native => |f| f,
        .c_closure => |closure| closure.function,
        .closure => return error.InvalidBytecode,
    };
    errdefer window.rollback(state);
    if (window.frames >= state.callLimit()) return error.CallDepth;
    try state.ensureOrigins(state.stack.items.len);
    // The window's base lies within the stack and above the caller's
    // (Window.arguments checked the count against the top).
    if (std.debug.runtime_safety) std.debug.assert(window.base >= state.base() and window.base <= state.stack.items.len);
    if (state.frames.items.len < state.frames.capacity) {
        state.frames.appendAssumeCapacity(.native(window.base, function, site));
    } else try state.frames.append(state.allocator, .native(window.base, function, site));
    state.frame_base = window.base;
    return finishInto(state, window, callback(state), destination);
}

/// What a C function's frame becomes once it has returned `returned`: its
/// results, its failure raised, or, for a yield, the frame kept as it is.
/// Also how a continuation's return ends the frame it continued.
pub fn finish(state: *runtime.State, window: execution.Window, returned: c_int) Error!usize {
    return finishInto(state, window, returned, .window);
}

/// The count of results a C function whose frame starts at `base` returned
/// `returned` as, when that is an ordinary return: no failure, no yield, no
/// interruption, and as many results as its frame holds. The one test of it,
/// for `finishInto` and for the VM's own call of a C function.
pub inline fn answered(state: *const runtime.State, base: usize, returned: c_int) ?usize {
    if (returned < 0 or state.yielding or state.interrupted) return null;
    const count: usize = @intCast(returned);
    return if (count <= state.stack.items.len - base) count else null;
}

fn finishInto(state: *runtime.State, window: execution.Window, returned: c_int, comptime destination: Destination) Error!usize {
    errdefer window.rollback(state);
    if (answered(state, window.base, returned)) |count| {
        switch (destination) {
            .window => window.results(state, count),
            .callee => window.resultsIntoCallee(state, count),
        }
        return count;
    }
    // `return nilu_yield(N, n)`: the frame and its window stay for the resume.
    if (returned == yield_result and state.yielding) return error.Yield;
    // A C function that called nilu_yield, or whose nilu_pcallk answered
    // NILU_YIELD, and then returned something else would lose the yield and
    // leave the coroutine's frames kept for a resume that never comes. That
    // breaks the contract the header states, so it aborts as other misuse does.
    if (state.yielding) @panic("nilu_yield: a C function must return nilu_yield's answer after calling it, and return nilu_yield(N, 0) once nilu_pcallk has answered NILU_YIELD");
    // The hook stopped the program while this C function ran: whatever it
    // returns, the interruption goes on to the host.
    if (state.interrupted) return error.Interrupted;
    // Explicit nilu_error preserves transport origin; a bare -1 raises Runtime
    // with nil. Other invalid counts are host misuse, not a language failure.
    if (returned == -1) {
        const context = state.execution orelse return error.InvalidBytecode;
        var record = context.raised.get() orelse if (context.api_memory_failure)
            runtime.FailureRecord{ .kind = .out_of_memory, .value = .from(.{ .string = state.memory_failure }), .origin = .native }
        else
            runtime.FailureRecord{ .kind = .runtime_error, .origin = .native };
        @import("execution_location.zig").attachNativeCaller(state, &record);
        state.failure = record;
        return @import("failure_transport.zig").dispatch(state, @import("failure_transport.zig").errorFromKind(record.kind));
    }
    // A count below -1 or past what the frame holds: an ordinary return
    // was taken above.
    return error.InvalidNativeResult;
}
