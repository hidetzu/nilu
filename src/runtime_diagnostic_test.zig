const std = @import("std");
const allocation_failures = @import("allocation_failures.zig");
const runtime = @import("runtime.zig");
const loader = @import("loader.zig");
const vm = @import("vm.zig");
const transport = @import("failure_transport.zig");
const api = @import("c_api.zig");
const a = std.testing.allocator;
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
fn prepare(state: *runtime.State, source: []const u8, name: []const u8) !*runtime.Closure {
    var diagnostic: ?loader.Diagnostic = null;
    return loader.prepare(state, source, name, &diagnostic);
}
fn check(source: []const u8, err: vm.Error, message: []const u8) !void {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    var diagnostic: ?vm.Diagnostic = null;
    try std.testing.expectError(err, vm.run(&state, try prepare(&state, source, "=spec"), &diagnostic));
    try expect(state.failure.?.value.is(.string));
    try std.testing.expectEqualStrings(message, state.failure.?.value.unpack().string.bytes);
    try expect(!state.failure.?.needs_message);
    try equal(@as(usize, 1), state.top());
    try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
    try equal(@as(usize, 0), state.frames.items.len);
}

test "runtime_diagnostic recorded core sentences retain operators lines and all seven name categories" {
    for ([_]struct { source: []const u8, message: []const u8 }{
        .{ .source = "return 1+nil", .message = "spec:1: attempt to perform arithmetic on a nil value" },
        .{ .source = "return #5", .message = "spec:1: attempt to get length of a number value" },
        .{ .source = "return 1 .. {}", .message = "spec:1: attempt to concatenate a table value" },
        .{ .source = "local n=5\nreturn n.field", .message = "spec:2: attempt to index a number value (local 'n')" },
        .{ .source = "local f=nil\nf\n(1)", .message = "spec:3: attempt to call a nil value (local 'f')" },
        .{ .source = "return missing()", .message = "spec:1: attempt to call a nil value (global 'missing')" },
        .{ .source = "local x=nil local function f() return x() end return f()", .message = "spec:1: attempt to call a nil value (upvalue 'x')" },
        .{ .source = "local t={} return t.a.b", .message = "spec:1: attempt to index a nil value (field 'a')" },
        .{ .source = "local t={} return t:m()", .message = "spec:1: attempt to call a nil value (method 'm')" },
        .{ .source = "return 'a'+1", .message = "spec:1: attempt to perform arithmetic on a string value (constant 'a')" },
        .{ .source = "for k in 7 do end", .message = "spec:1: attempt to call a number value (for iterator 'for iterator')" },
        .{ .source = "local x<const> =1 return x()", .message = "spec:1: attempt to call a number value (local 'x')" },
        .{ .source = "local t = {} local k = 'x' return t[k].z", .message = "spec:1: attempt to index a nil value (field '?')" },
        .{ .source = "local t = {} local k = 'x' t[k]()", .message = "spec:1: attempt to call a nil value (field '?')" },
        .{ .source = "local t = {} return t[1].z", .message = "spec:1: attempt to index a nil value (field '?')" },
        .{ .source = "local t = {} return t[true].z", .message = "spec:1: attempt to index a nil value (field '?')" },
        .{ .source = "local t = {} local k = 'x' return t[k] + 1", .message = "spec:1: attempt to perform arithmetic on a nil value (field '?')" },
        .{ .source = "local _ENV=1 x=2", .message = "spec:1: attempt to index a number value (local '_ENV')" },
        .{ .source = "return 1\n +nil", .message = "spec:2: attempt to perform arithmetic on a nil value" },
        .{ .source = "local a={} return 1+a", .message = "spec:1: attempt to perform arithmetic on a table value (local 'a')" },
    }) |case| try check(case.source, error.Type, case.message);
}

test "runtime_diagnostic comparison key for and global errors use their recorded special sentences" {
    try check("return 1<'x'", error.Type, "spec:1: attempt to compare number with string");
    try check("return 1>'x'", error.Type, "spec:1: attempt to compare string with number");
    try check("return {}<{}", error.Type, "spec:1: attempt to compare two table values");
    try check("local t={} t[nil]=1", error.Type, "spec:1: table index is nil");
    try check("local t={} t[0/0]=1", error.Type, "spec:1: table index is NaN");
    try check("for i=1,'x' do end", error.Type, "spec:1: bad 'for' limit (number expected, got string)");
    try check("for i=1,3,'x' do end", error.Type, "spec:1: bad 'for' step (number expected, got string)");
    try check("for i='x',3 do end", error.Type, "spec:1: bad 'for' initial value (number expected, got string)");
    try check("for i=1,3,0 do end", error.Runtime, "spec:1: 'for' step is zero");
    try check("global x=1\nglobal x=2", error.Runtime, "spec:2: global 'x' already defined");
}

test "runtime_diagnostic copied source and chunk ids survive input mutation and avoid double formatting" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    var source = "local a=nil\nreturn a.y".*;
    var name = "@config.nilu".*;
    const closure = try prepare(&state, &source, &name);
    @memset(&source, 'x');
    @memset(&name, 'x');
    var diagnostic: ?vm.Diagnostic = null;
    try std.testing.expectError(error.Type, vm.run(&state, closure, &diagnostic));
    try std.testing.expectEqualStrings("config.nilu:2: attempt to index a nil value (local 'a')", state.failure.?.value.unpack().string.bytes);
    var load: ?loader.Diagnostic = null;
    try equal(loader.Result.loaded, try loader.load(&state, "return 1+nil", "==odd", &load));
    try std.testing.expectError(error.Type, vm.run(&state, state.get(-1).?.unpack().closure, &diagnostic));
    try std.testing.expectEqualStrings("=odd:1: attempt to perform arithmetic on a nil value", state.failure.?.value.unpack().string.bytes);
}

fn field(state: *runtime.State, table: *runtime.Table, name: []const u8, value: runtime.Value) !void {
    state.barrier(&table.header);
    try table.set(a, .from(.{ .string = try state.newString(name) }), value);
}
test "runtime_diagnostic custom type snapshots are rooted and metatable chain values do not get false variable names" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    const table = try state.newTable();
    const meta = try state.newTable();
    try field(&state, meta, "__name", .from(.{ .string = try state.newString("Point") }));
    table.metatable = meta;
    try field(&state, state.globals, "point", .from(.{ .table = table }));
    try state.push(.fromFunction(.{ .closure = try prepare(&state, "return point+1", "=spec") }));
    var diagnostic: ?vm.Diagnostic = null;
    try equal(runtime.FailureKind.type_error, (try transport.call(&state, 0, false, &diagnostic)).failure);
    try std.testing.expectEqualStrings("spec:1: attempt to perform arithmetic on a Point value (global 'point')", state.get(-1).?.unpack().string.bytes);
    try field(&state, meta, "__name", .from(.{ .string = try state.newString("Vector") }));
    try field(&state, state.globals, "point", .nil);
    state.failure = null;
    state.collect();
    _ = api.nilu_error(&state);
    try std.testing.expectEqualStrings("Point", state.failure.?.diagnostic.?.type_name.?.bytes);
    try equal(api.Status.ok, api.nilu_settop(&state, 0));
    const root = try state.newTable();
    const fallback = try state.newTable();
    try field(&state, fallback, "__index", .from(.{ .number = 3 }));
    root.metatable = fallback;
    try field(&state, state.globals, "root", .from(.{ .table = root }));
    try std.testing.expectError(error.Type, vm.run(&state, try prepare(&state, "return root.x", "=spec"), &diagnostic));
    try std.testing.expectEqualStrings("spec:1: attempt to index a number value", state.failure.?.value.unpack().string.bytes);
}

var handler_saw_message = false;
fn handler(state: *runtime.State) callconv(.c) c_int {
    const value = state.get(1) orelse return -1;
    handler_saw_message = value.is(.string) and std.mem.eql(u8, value.unpack().string.bytes, "spec:1: attempt to perform arithmetic on a nil value");
    state.collect();
    if (api.nilu_pushvalue(state, 1) != .ok) return -1;
    return 1;
}
fn explicit(state: *runtime.State) callconv(.c) c_int {
    if (api.nilu_pushstring(state, "own words") != .ok) return -1;
    return api.nilu_error(state);
}
test "runtime_diagnostic formats before handler execution but never rewrites explicitly raised values" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try state.push(.fromFunction(.{ .closure = try prepare(&state, "return 1+nil", "=spec") }));
    handler_saw_message = false;
    var diagnostic: ?vm.Diagnostic = null;
    try equal(runtime.FailureKind.type_error, (try transport.callWithHandler(&state, 0, true, .fromFunction(.{ .native = handler }), &diagnostic)).failure);
    try expect(handler_saw_message);
    try field(&state, state.globals, "raise", .fromFunction(.{ .native = explicit }));
    try std.testing.expectError(error.Runtime, vm.run(&state, try prepare(&state, "return raise()", "=spec"), &diagnostic));
    try std.testing.expectEqualStrings("own words", state.failure.?.value.unpack().string.bytes);
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var state = try runtime.State.init(allocator);
    defer state.deinit();
    const closure = try prepare(&state, "local t={} return t['x'].y", "=spec");
    try state.push(.from(.{ .number = 42 }));
    state.setCollectionThreshold(0);
    var diagnostic: ?vm.Diagnostic = null;
    _ = vm.run(&state, closure, &diagnostic) catch |err| {
        try equal(@as(usize, 1), state.top());
        try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
        try expect(state.execution == null);
        try equal(@as(usize, 0), state.frames.items.len);
        if (err == error.OutOfMemory) {
            try expect(state.failure.?.value.unpack().string == state.memory_failure);
            return err;
        }
        try equal(error.Type, err);
        state.collect();
        try std.testing.expectEqualStrings("spec:1: attempt to index a nil value (field 'x')", state.failure.?.value.unpack().string.bytes);
        return;
    };
    return error.TestUnexpectedResult;
}
test "runtime_diagnostic all allocation failures clean partial formatting and carry the prepared OOM value" {
    try allocation_failures.checkAll(a, allocationCase, .{});
}

test "runtime_diagnostic invalid hint spans are rejected before execution" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    const prototype = try state.newProgram(&.{}, &.{.{ .position = .{ .offset = 0, .line = 1, .column = 1 }, .operation = .{ .returns = .{ .first = 0, .count = 0 } }, .names = .{ .primary = .{ .kind = .local, .text = .{ .span = .{ .start = 1, .end = 2 } } } } }}, 0, "", "=invalid");
    try std.testing.expectError(error.InvalidBytecode, vm.validate(prototype));
}

test "runtime_diagnostic both custom comparison names remain roots after receiver graphs are dropped" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    const left = try state.newTable();
    const right = try state.newTable();
    const left_meta = try state.newTable();
    const right_meta = try state.newTable();
    try field(&state, left_meta, "__name", .from(.{ .string = try state.newString("Point") }));
    try field(&state, right_meta, "__name", .from(.{ .string = try state.newString("Vector") }));
    left.metatable = left_meta;
    right.metatable = right_meta;
    try field(&state, state.globals, "left", .from(.{ .table = left }));
    try field(&state, state.globals, "right", .from(.{ .table = right }));
    var diagnostic: ?vm.Diagnostic = null;
    try std.testing.expectError(error.Type, vm.run(&state, try prepare(&state, "return left<right", "=spec"), &diagnostic));
    try std.testing.expectEqualStrings("spec:1: attempt to compare Point with Vector", state.failure.?.value.unpack().string.bytes);
    try field(&state, state.globals, "left", .nil);
    try field(&state, state.globals, "right", .nil);
    state.collect();
    try std.testing.expectEqualStrings("Point", state.failure.?.diagnostic.?.type_name.?.bytes);
    try std.testing.expectEqualStrings("Vector", state.failure.?.diagnostic.?.other_name.?.bytes);
}

test "runtime_diagnostic native overflow has the recorded bare sentence without a false chunk" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    state.failure = .{ .kind = .call_depth, .origin = .native, .needs_message = true };
    try equal(error.CallDepth, @import("runtime_diagnostic.zig").complete(&state, null, error.CallDepth));
    try std.testing.expectEqualStrings("stack overflow", state.failure.?.value.unpack().string.bytes);
}
