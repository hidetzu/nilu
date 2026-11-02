//! The coroutine library (manual 10, ADR 0013), written against the C API's
//! threads. The sentences are Lua 5.5's.
const std = @import("std");
const api = @import("c_api.zig");
const stdlib = @import("stdlib.zig");

const Call = stdlib.Call;
const Error = stdlib.Error;
const entry = stdlib.entry;

pub fn open(call: Call) Error!void {
    try stdlib.openTable(call, "coroutine", &.{
        .{ .name = "create", .function = entry("create", create) },
        .{ .name = "resume", .function = entry("resume", resumeThread) },
        .{ .name = "yield", .function = entry("yield", yieldThread) },
        .{ .name = "status", .function = entry("status", status) },
        .{ .name = "wrap", .function = entry("wrap", wrap) },
        .{ .name = "isyieldable", .function = entry("isyieldable", isYieldable) },
        .{ .name = "running", .function = entry("running", running) },
        .{ .name = "close", .function = entry("close", close) },
    });
}

fn checkThread(call: Call, index: c_int) Error!void {
    if (call.typeAt(index) != .thread) return call.typeError(index, "thread");
}

fn create(call: Call) Error!c_int {
    try call.checkFunction(1);
    try call.setTop(1);
    try call.check(api.nilu_newthread(call.state));
    return 1;
}

/// Resumes the thread at 1 with the values above it; leaves on the stack
/// what it gave, or its failure value. Answers how many values that is, or
/// null for a failure.
fn resumeWith(call: Call) Error!?c_int {
    var count: c_int = 0;
    const result = api.nilu_resume(call.state, 1, call.top() - 1, &count);
    return switch (result) {
        .ok, .yielded => count,
        // The host's interruption is not caught; it is passed on.
        .interrupted => error.Raised,
        else => null,
    };
}

/// coroutine.resume(co, ...): true and what it gave, or false and its failure.
fn resumeThread(call: Call) Error!c_int {
    try checkThread(call, 1);
    const count = try resumeWith(call) orelse {
        try call.pushBoolean(false);
        call.insert(-2);
        return 2;
    };
    try call.pushBoolean(true);
    call.insert(call.top() - count);
    return count + 1;
}

fn yieldThread(call: Call) Error!c_int {
    return api.nilu_yield(call.state, call.top());
}

const status_words = [_][]const u8{ "suspended", "running", "normal", "dead" };

fn status(call: Call) Error!c_int {
    try checkThread(call, 1);
    try call.push(status_words[@intCast(api.nilu_threadstatus(call.state, 1))]);
    return 1;
}

/// coroutine.wrap(f): a function that resumes a new thread and gives what it
/// gave, raising its failure; a string failure gets the caller's position, as
/// Lua's auxwrap gives it.
fn wrap(call: Call) Error!c_int {
    try call.checkFunction(1);
    try call.setTop(1);
    try call.check(api.nilu_newthread(call.state));
    try call.check(api.nilu_pushcclosure(call.state, entry("wrap", resumeWrapped), 1));
    return 1;
}

fn resumeWrapped(call: Call) Error!c_int {
    try call.check(api.nilu_getupvalue(call.state, 1));
    call.insert(1);
    if (try resumeWith(call)) |count| return count;
    // A failed coroutine is closed, as Lua's auxwrap closes it: its
    // to-be-closed variables close, and one that fails replaces the failure.
    try call.check(api.nilu_getupvalue(call.state, 1));
    switch (api.nilu_closethread(call.state, -1)) {
        .ok => call.pop(1),
        .memory => return error.OutOfMemory,
        .stack => return error.Stack,
        else => {
            call.remove(-2);
            call.remove(-2);
        },
    }
    if (call.typeAt(-1) == .string) {
        var where = api.ErrorLocation{};
        if (api.nilu_where(call.state, 1, &where)) |name| {
            if (where.line > 0) {
                var prefix: [512]u8 = undefined;
                const text = std.fmt.bufPrint(&prefix, "{s}:{d}: ", .{ std.mem.span(name), where.line }) catch "";
                var buffer = try stdlib.Buffer.init(call, text.len + call.bytesAt(-1).len);
                try buffer.append(text);
                try buffer.append(call.bytesAt(-2));
                try buffer.finish();
                call.remove(-2);
            }
        }
    }
    return error.Raised;
}

fn isYieldable(call: Call) Error!c_int {
    if (call.typeAt(1) == .none) {
        if (api.nilu_pushrunning(call.state) < 0) return error.Stack;
    } else try checkThread(call, 1);
    try call.pushBoolean(api.nilu_isyieldable(call.state, if (call.typeAt(1) == .none) -1 else 1) == 1);
    return 1;
}

fn running(call: Call) Error!c_int {
    const main = api.nilu_pushrunning(call.state);
    if (main < 0) return error.Stack;
    try call.pushBoolean(main == 1);
    return 2;
}

/// coroutine.close(co): true, or false and the failure it died by.
fn close(call: Call) Error!c_int {
    try checkThread(call, 1);
    // A running or normal thread, the main one among them, is refused with
    // the sentence the C API pushes; a failure the thread died by is answered.
    const refused = switch (api.nilu_threadstatus(call.state, 1)) {
        1, 2 => true,
        else => false,
    };
    switch (api.nilu_closethread(call.state, 1)) {
        .ok => {
            try call.pushBoolean(true);
            return 1;
        },
        .memory => return error.OutOfMemory,
        .stack => return error.Stack,
        else => {
            if (refused) return error.Raised;
            try call.pushBoolean(false);
            call.insert(-2);
            return 2;
        },
    }
}
