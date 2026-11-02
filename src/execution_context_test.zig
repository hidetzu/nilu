const std = @import("std");
const runtime = @import("runtime.zig");
const execution = @import("execution_context.zig");
const loader = @import("loader.zig");
const vm = @import("vm.zig");
const a = std.testing.allocator;
const equal = std.testing.expectEqual;
const expect = std.testing.expect;

fn prepare(state: *runtime.State, source: []const u8) !*runtime.Closure {
    var diagnostic: ?loader.Diagnostic = null;
    return loader.prepare(state, source, "=context", &diagnostic);
}

test "execution_context suspended failure values remain roots at every nesting level" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    const baseline = state.object_count;
    state.failure = .{ .kind = .runtime_error, .value = .from(.{ .string = try state.newString("outer") }) };
    var outer = execution.Context{ .window = execution.Window.above(&state) };
    outer.enter(&state);
    try expect(state.failure == null);
    state.collect();
    try equal(baseline + 1, state.object_count);
    state.failure = .{ .kind = .type_error, .value = .from(.{ .string = try state.newString("inner") }) };
    var inner = execution.Context{ .window = execution.Window.above(&state) };
    inner.enter(&state);
    state.collect();
    try equal(baseline + 2, state.object_count);
    inner.leave(&state, true);
    try equal(runtime.FailureKind.type_error, state.failure.?.kind);
    try std.testing.expectEqualStrings("inner", state.failure.?.value.unpack().string.bytes);
    outer.leave(&state, true);
    try expect(state.failure == null);
    try expect(state.execution == null);
    state.collect();
    try equal(baseline, state.object_count);
}

test "execution_context window rollback closes callee cells and preserves caller cells" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    const caller = try state.capture(0);
    const window = execution.Window.above(&state);
    try state.push(.from(.{ .number = 7 }));
    const callee = try state.capture(1);
    // Preserve both cells independently of the stack when collecting later.
    const closure = try state.newClosure(try state.newPrototype(&.{}), &.{ caller, callee });
    window.rollback(&state);
    try expect(caller.storage == .open);
    try expect(callee.storage == .closed);
    try expect(state.readCell(callee).equal(.from(.{ .number = 7 })));
    try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
    try state.push(.fromFunction(.{ .closure = closure }));
    state.collect();
    try expect(state.readCell(callee).equal(.from(.{ .number = 7 })));
}

test "execution_context script propagation retains first failure kind and source instruction" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    const closure = try prepare(&state, "local function inner()\n return 1+nil\nend\nlocal function outer() return inner() end\nreturn outer()");
    var diagnostic: ?vm.Diagnostic = null;
    try std.testing.expectError(error.Type, vm.run(&state, closure, &diagnostic));
    const record = state.failure.?;
    try equal(runtime.FailureKind.type_error, record.kind);
    try equal(@as(usize, 2), record.position.?.line);
    try equal(diagnostic.?.position, record.position.?);
    try equal(.binary, record.operation.?);
    try equal(.vm, record.origin);
    try std.testing.expectEqualStrings("context:2: attempt to perform arithmetic on a nil value", record.value.unpack().string.bytes);
    try equal(@as(usize, 1), state.top());
    try expect(state.execution == null);
    try equal(@as(usize, 0), state.frames.items.len);
    try equal(@as(usize, 0), state.vm_entries);
    _ = try vm.run(&state, try prepare(&state, "return 8"), &diagnostic);
    try expect(state.failure == null);
    try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
    try expect(state.get(2).?.equal(.from(.{ .number = 8 })));
}

fn reenter(state: *runtime.State) callconv(.c) c_int {
    if (state.execution == null) return -1;
    const callback = state.get(1).?.asFunction().?;
    const value = state.newTable() catch return -1;
    state.barrier(&value.header);
    value.set(state.allocator, .from(.{ .number = 1 }), .from(.{ .number = 91 })) catch return -1;
    state.failure = .{ .kind = .type_error, .value = .from(.{ .table = value }), .origin = .host };
    var diagnostic: ?vm.Diagnostic = null;
    _ = vm.runFunctionWithArguments(state, callback, 0, &diagnostic) catch return -1;
    // The nested VM collected while this record existed only in its context.
    if (state.failure == null or state.failure.?.kind != .type_error) return -1;
    if (!state.failure.?.value.unpack().table.get(.from(.{ .number = 1 })).equal(.from(.{ .number = 91 }))) return -1;
    state.collect();
    return 0;
}
test "execution_context native reentry restores caller record and successful exit clears caught state" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    state.barrier(&state.globals.header);
    try state.globals.set(a, .from(.{ .string = try state.newString("native") }), .fromFunction(.{ .native = reenter }));
    try state.push(.from(.{ .number = 42 }));
    state.setCollectionThreshold(0);
    var diagnostic: ?vm.Diagnostic = null;
    _ = try vm.run(&state, try prepare(&state, "local x=7 native(function() local n=0 while n<100 do local garbage={} n=n+1 end return x end) return x"), &diagnostic);
    try expect(state.failure == null);
    try expect(state.execution == null);
    try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
    try expect(state.get(2).?.equal(.from(.{ .number = 7 })));
    try equal(@as(usize, 0), state.frames.items.len);
}

fn caught(state: *runtime.State) callconv(.c) c_int {
    var diagnostic: ?vm.Diagnostic = null;
    _ = vm.runFunctionWithArguments(state, state.get(1).?.asFunction().?, 0, &diagnostic) catch |err| {
        if (err != error.Type or state.failure == null or state.failure.?.kind != .type_error) return -1;
        state.collect();
        state.push(.from(.{ .number = 9 })) catch return -1;
        return 1;
    };
    return -1;
}
test "execution_context native success consumes an internally caught failure without leaking it" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    state.barrier(&state.globals.header);
    try state.globals.set(a, .from(.{ .string = try state.newString("caught") }), .fromFunction(.{ .native = caught }));
    var diagnostic: ?vm.Diagnostic = null;
    _ = try vm.run(&state, try prepare(&state, "return caught(function() return 1+nil end)"), &diagnostic);
    try expect(state.get(1).?.equal(.from(.{ .number = 9 })));
    try expect(state.failure == null);
    try expect(state.execution == null);
}
