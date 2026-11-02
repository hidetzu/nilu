const std = @import("std");
const allocation_failures = @import("allocation_failures.zig");
const runtime = @import("runtime.zig");
const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const vm = @import("vm.zig");
const a = std.testing.allocator;
const State = runtime.State;
const Value = runtime.Value;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
fn field(state: *State, table: *runtime.Table, name: []const u8, value: Value) !void {
    state.barrier(&table.header);
    try table.set(state.allocator, .from(.{ .string = try state.newString(name) }), value);
}
fn compile(state: *State, allocator: std.mem.Allocator, source: []const u8) !*runtime.Closure {
    var parsed: ?parser.Diagnostic = null;
    var ast = try parser.parseChunk(allocator, source, &parsed);
    defer ast.deinit();
    var diagnostic: ?compiler.Diagnostic = null;
    return state.newChunk(try compiler.compile(allocator, state, &ast, "<native>", &diagnostic));
}
fn run(state: *State, source: []const u8, diagnostic: *?vm.Diagnostic) !usize {
    return vm.run(state, try compile(state, a, source), diagnostic);
}
fn install(state: *State, name: []const u8, callback: runtime.Native) !void {
    try field(state, state.globals, name, .fromFunction(.{ .native = callback }));
}
fn identity(state: *State) callconv(.c) c_int {
    return @intCast(state.top());
}
fn none(_: *State) callconv(.c) c_int {
    return 0;
}
fn two(state: *State) callconv(.c) c_int {
    state.push(.from(.{ .number = 1 })) catch return -1;
    state.push(.from(.{ .number = 2 })) catch return -1;
    return 2;
}
fn window(state: *State) callconv(.c) c_int {
    const count = state.top();
    if (state.get(0) != null or state.get(@intCast(count + 1)) != null or state.get(-@as(i64, @intCast(count)) - 1) != null) return -1;
    state.push(.from(.{ .number = @floatFromInt(count) })) catch return -1;
    return 1;
}

test "native_call window contains only arguments and result adjustment preserves caller" {
    var state = try State.init(a);
    defer state.deinit();
    try install(&state, "f", window);
    try install(&state, "two", two);
    try install(&state, "none", none);
    try state.push(.from(.{ .number = 42 }));
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(&state, "local keep=9 local n=f(1,nil,3) local a,b,c,d=two() none() return keep,n,a,b,c,d,f()", &diagnostic);
    for ([_]Value{ .from(.{ .number = 42 }), .from(.{ .number = 9 }), .from(.{ .number = 3 }), .from(.{ .number = 1 }), .from(.{ .number = 2 }), .nil, .nil, .from(.{ .number = 0 }) }, state.stack.items) |wanted, actual| try expect(actual.equal(wanted));
    try equal(@as(usize, 0), state.frames.items.len);
}

fn counter(state: *State) callconv(.c) c_int {
    const function = state.frames.items[state.frames.items.len - 1].function;
    if (function != .c_closure) return -1;
    const slot = &function.c_closure.upvalues[0];
    slot.* = Value.fromNumber(slot.numberValue().? + 1);
    state.push(slot.*) catch return -1;
    return 1;
}

test "native_call C closures preserve independent mutable upvalues" {
    var state = try State.init(a);
    defer state.deinit();
    try field(&state, state.globals, "f", .fromFunction(try state.newCClosure(counter, &.{.from(.{ .number = 0 })})));
    try field(&state, state.globals, "g", .fromFunction(try state.newCClosure(counter, &.{.from(.{ .number = 10 })})));
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(&state, "return f(),f(),g()", &diagnostic);
    for ([_]f64{ 1, 2, 11 }, state.stack.items) |wanted, actual| try expect(actual.equal(.from(.{ .number = wanted })));
}

fn collectedUpvalue(state: *State) callconv(.c) c_int {
    const key = state.newString("f") catch return -1;
    state.barrier(&state.globals.header);
    state.globals.set(state.allocator, .from(.{ .string = key }), .nil) catch return -1;
    state.collect();
    const function = state.frames.items[state.frames.items.len - 1].function;
    if (function != .c_closure) return -1;
    state.push(function.c_closure.upvalues[0]) catch return -1;
    return 1;
}

test "native_call active C closure stays rooted through direct and tail collections" {
    for ([_]bool{ false, true }) |tail| {
        var state = try State.init(a);
        defer state.deinit();
        const payload = try state.newString("retained");
        const function = try state.newCClosure(collectedUpvalue, &.{.from(.{ .string = payload })});
        var diagnostic: ?vm.Diagnostic = null;
        if (tail) {
            try field(&state, state.globals, "f", .fromFunction(function));
            _ = try run(&state, "return f()", &diagnostic);
        } else _ = try vm.runFunctionWithArguments(&state, function, 0, &diagnostic);
        try std.testing.expectEqualStrings("retained", state.get(-1).?.unpack().string.bytes);
        try equal(@as(usize, 0), state.frames.items.len);
        state.collect();
        try std.testing.expectEqualStrings("retained", state.get(-1).?.unpack().string.bytes);
    }
}

var saw_open_capture: bool = false;
fn reenterCapture(state: *State) callconv(.c) c_int {
    const function = state.get(1).?.asFunction().?;
    saw_open_capture = function == .closure and function.closure.upvalues[0].storage == .open;
    var diagnostic: ?vm.Diagnostic = null;
    const count = vm.runFunctionWithArguments(state, function, 0, &diagnostic) catch return -1;
    return @intCast(count);
}

test "native_call tail targets retain the script frame and support script reentry" {
    var state = try State.init(a);
    defer state.deinit();
    try install(&state, "native", reenterCapture);
    try state.push(.from(.{ .number = 42 }));
    state.setCollectionThreshold(0);
    saw_open_capture = false;
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(&state, "local x=7 local f=function() return x end return native(f)", &diagnostic);
    try expect(saw_open_capture);
    try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
    try expect(state.get(2).?.equal(.from(.{ .number = 7 })));
    try equal(@as(usize, 0), state.frames.items.len);
}

fn iterator(state: *State) callconv(.c) c_int {
    if (state.top() != 2) return -1;
    const limit = state.get(1).?.numberValue().?;
    const previous = state.get(2).?.numberValue().?;
    if (previous >= limit) return 0;
    state.push(.from(.{ .number = previous + 1 })) catch return -1;
    return 1;
}

test "native_call generic iterators use the same argument and result protocol" {
    var state = try State.init(a);
    defer state.deinit();
    try install(&state, "iter", iterator);
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(&state, "local sum=0 for k in iter,3,0 do sum=sum+k end return sum", &diagnostic);
    try expect(state.get(1).?.equal(.from(.{ .number = 6 })));
}

fn grow(state: *State) callconv(.c) c_int {
    for (0..5000) |i| state.push(.from(.{ .number = @floatFromInt(i) })) catch return -1;
    return 2;
}

test "native_call stack growth returns trailing values without overwriting caller slots" {
    var state = try State.init(a);
    defer state.deinit();
    try install(&state, "grow", grow);
    try state.push(.from(.{ .number = 42 }));
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(&state, "local keep=9 local x,y=grow(1,2) return keep,x,y,grow()", &diagnostic);
    for ([_]f64{ 42, 9, 4998, 4999, 4998, 4999 }, state.stack.items) |wanted, actual| try expect(actual.equal(.from(.{ .number = wanted })));
}

var max_native_depth: usize = 0;
var saw_depth_limit: bool = false;
fn recurse(state: *State) callconv(.c) c_int {
    max_native_depth = @max(max_native_depth, state.frames.items.len);
    var diagnostic: ?vm.Diagnostic = null;
    _ = vm.runFunctionWithArguments(state, .{ .native = recurse }, 0, &diagnostic) catch |err| {
        if (err == error.CallDepth) {
            saw_depth_limit = true;
            return 0;
        }
        return -1;
    };
    return 0;
}

test "native_call depth is shared across native and script frames" {
    var state = try State.init(a);
    defer state.deinit();
    try install(&state, "f", recurse);
    max_native_depth = 0;
    saw_depth_limit = false;
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(&state, "f() return 7", &diagnostic);
    try expect(saw_depth_limit);
    try equal(State.max_calls, max_native_depth);
    try equal(@as(usize, 0), state.frames.items.len);
    try expect(state.get(-1).?.equal(.from(.{ .number = 7 })));
}

var hooks: usize = 0;
fn observer(_: *State) callconv(.c) c_int {
    hooks += 1;
    return 0;
}
fn twice(state: *State) callconv(.c) c_int {
    const function = state.get(1).?.asFunction().?;
    var diagnostic: ?vm.Diagnostic = null;
    for (0..2) |_| {
        _ = vm.runFunctionWithArguments(state, function, 0, &diagnostic) catch return -1;
        state.setTop(1) catch return -1;
    }
    return 0;
}

test "native_call hooks count only VM dispatch and remain continuous across reentry" {
    var state = try State.init(a);
    defer state.deinit();
    const closure = try compile(&state, a, "return 1");
    state.setHook(observer, 1);
    hooks = 0;
    var diagnostic: ?vm.Diagnostic = null;
    _ = try vm.run(&state, closure, &diagnostic);
    const single = hooks;
    try state.setTop(0);
    hooks = 0;
    _ = try vm.runFunctionWithArguments(&state, .{ .native = none }, 0, &diagnostic);
    try equal(@as(usize, 0), hooks);
    try state.push(.fromFunction(.{ .closure = closure }));
    _ = try vm.runFunctionWithArguments(&state, .{ .native = twice }, 1, &diagnostic);
    try equal(single * 2 + 1, hooks);
}

fn negative(_: *State) callconv(.c) c_int {
    return -1;
}
fn badNegative(_: *State) callconv(.c) c_int {
    return -2;
}
fn tooMany(_: *State) callconv(.c) c_int {
    return std.math.maxInt(c_int);
}
var inner_type_seen: bool = false;
fn relay(state: *State) callconv(.c) c_int {
    var diagnostic: ?vm.Diagnostic = null;
    _ = vm.runFunctionWithArguments(state, state.get(1).?.asFunction().?, 0, &diagnostic) catch |err| {
        inner_type_seen = err == error.Type;
        return -1;
    };
    return 0;
}

test "native_call bare failure is Runtime while invalid counts are internal host misuse" {
    var state = try State.init(a);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    var diagnostic: ?vm.Diagnostic = null;
    for ([_]runtime.Native{ negative, badNegative, tooMany }) |callback| {
        try install(&state, "f", callback);
        try std.testing.expectError(if (callback == negative) error.Runtime else error.InvalidNativeResult, run(&state, "f()", &diagnostic));
        try equal(@as(usize, 1), state.top());
        try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
        try equal(@as(usize, 0), state.frames.items.len);
    }
    try install(&state, "relay", relay);
    inner_type_seen = false;
    try std.testing.expectError(error.Runtime, run(&state, "return relay(function() return 1+nil end)", &diagnostic));
    try expect(inner_type_seen);
    try equal(@as(usize, 1), state.top());
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var state = try State.init(allocator);
    defer state.deinit();
    try install(&state, "f", identity);
    const closure = try compile(&state, allocator, "local x={v=7} return f(x).v");
    try state.push(.from(.{ .number = 42 }));
    var diagnostic: ?vm.Diagnostic = null;
    _ = vm.run(&state, closure, &diagnostic) catch |err| {
        try equal(@as(usize, 1), state.top());
        try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
        try equal(@as(usize, 0), state.frames.items.len);
        return err;
    };
    try expect(state.get(2).?.equal(.from(.{ .number = 7 })));
}

test "native_call VM allocation failures release partial native-call setup" {
    try allocation_failures.checkAll(a, allocationCase, .{});
}

test "native_call prior Lua call fixtures agree with native callback equivalents" {
    var lines = std.mem.tokenizeScalar(u8, @embedFile("lua55-calls"), '\n');
    var checked: usize = 0;
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        var buffer: [4096]u8 = undefined;
        const source = try std.fmt.hexToBytes(&buffer, fields.next().?);
        const count = try std.fmt.parseInt(usize, fields.next().?, 10);
        const expected = fields.next().?;
        try expect(fields.next() == null);
        errdefer std.debug.print("native fixture failed: {s}\n", .{source});
        var state = try State.init(a);
        defer state.deinit();
        try install(&state, "f", identity);
        try install(&state, "none", none);
        try install(&state, "two", two);
        var diagnostic: ?vm.Diagnostic = null;
        try equal(count, try run(&state, source, &diagnostic));
        var values = std.mem.tokenizeScalar(u8, expected, ',');
        for (state.stack.items) |actual| {
            const value = values.next().?;
            const colon = std.mem.indexOfScalar(u8, value, ':').?;
            const kind = value[0..colon];
            const payload = value[colon + 1 ..];
            try std.testing.expectEqualStrings(kind, actual.typeName());
            if (actual.numberValue() != null) {
                try equal(try std.fmt.parseInt(u64, payload, 16), @as(u64, @bitCast(actual.numberValue().?)));
            } else if (actual.is(.string)) {
                var bytes: [4096]u8 = undefined;
                const decoded = if (std.mem.eql(u8, payload, "-")) "" else try std.fmt.hexToBytes(&bytes, payload);
                try std.testing.expectEqualSlices(u8, decoded, actual.unpack().string.bytes);
            } else if (actual.is(.boolean)) try equal(std.mem.eql(u8, payload, "true"), actual.unpack().boolean) else try expect(actual.is(.nil));
        }
        if (count > 0) try expect(values.next() == null);
        checked += 1;
    }
    try expect(checked > 0);
    std.debug.print("native-call fixture: {d} unchanged Lua call cases checked with native callbacks\n", .{checked});
}

fn record(state: *State) callconv(.c) c_int {
    field(state, state.globals, "argc", .from(.{ .number = @floatFromInt(state.top()) })) catch return -1;
    field(state, state.globals, "first", state.get(1) orelse .nil) catch return -1;
    field(state, state.globals, "second", state.get(2) orelse .nil) catch return -1;
    field(state, state.globals, "third", state.get(3) orelse .nil) catch return -1;
    state.collect();
    state.push(.from(.{ .number = 7 })) catch return -1;
    state.push(.from(.{ .boolean = false })) catch return -1;
    return 2;
}

test "native_call native and C closure handlers share supported metamethod paths" {
    for ([_]bool{ false, true }) |captured| {
        var state = try State.init(a);
        defer state.deinit();
        const function: runtime.Function = if (captured) try state.newCClosure(record, &.{.from(.{ .number = 1 })}) else .{ .native = record };
        const table = try state.newTable();
        const meta = try state.newTable();
        for ([_][]const u8{ "__index", "__newindex", "__add", "__sub", "__mul", "__div", "__idiv", "__mod", "__pow", "__unm", "__concat", "__lt", "__le" }) |name| try field(&state, meta, name, .fromFunction(function));
        table.metatable = meta;
        try field(&state, state.globals, "t", .from(.{ .table = table }));
        try state.push(.from(.{ .number = 42 }));
        var diagnostic: ?vm.Diagnostic = null;
        for ([_][]const u8{ "return t.x", "return t+1", "return t-1", "return t*1", "return t/1", "return t//1", "return t%1", "return t^1", "return t..'x'", "return -t" }) |source| {
            _ = try run(&state, source, &diagnostic);
            try equal(@as(usize, 2), state.top());
            try expect(state.get(2).?.equal(.from(.{ .number = 7 })));
            try expect(state.globals.getString("argc").equal(.from(.{ .number = 2 })));
            try expect(state.globals.getString("first").equal(.from(.{ .table = table })));
            try state.setTop(1);
        }
        try expect(state.globals.getString("second").equal(.from(.{ .table = table })));
        _ = try run(&state, "local _ENV=t x=9", &diagnostic);
        try equal(@as(usize, 1), state.top());
        try expect(state.globals.getString("argc").equal(.from(.{ .number = 3 })));
        try expect(state.globals.getString("third").equal(.from(.{ .number = 9 })));
        try expect(table.getString("x").is(.nil));
        _ = try run(&state, "return t<1,t<=1,t>1,t>=1", &diagnostic);
        for (state.stack.items[1..]) |value| try expect(value.equal(.from(.{ .boolean = true })));
        try expect(state.globals.getString("first").equal(.from(.{ .number = 1 })));
        try expect(state.globals.getString("second").equal(.from(.{ .table = table })));
        try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
    }
}

fn allocatingFailure(state: *State) callconv(.c) c_int {
    _ = state.newString("allocation") catch return -1;
    return 0;
}

test "native_call bare callback allocation refusal is Runtime with caller restored" {
    var state = try State.init(a);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    const original = state.allocator;
    defer state.allocator = original;
    state.allocator = failing.allocator();
    var diagnostic: ?vm.Diagnostic = null;
    try std.testing.expectError(error.Runtime, vm.runFunctionWithArguments(&state, .{ .native = allocatingFailure }, 0, &diagnostic));
    try equal(@as(usize, 1), state.top());
    try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
    try equal(@as(usize, 0), state.frames.items.len);
}

var hook_entry_failed: bool = false;
var hook_target_calls: usize = 0;
fn hookTarget(state: *State) callconv(.c) c_int {
    hook_target_calls += 1;
    // The callee sees its own argument window, not the hook's empty one.
    if (state.top() != 1 or !state.get(1).?.equal(.from(.{ .number = 8 }))) return 1;
    return 0;
}
fn reenterFromHook(state: *State) callconv(.c) c_int {
    var diagnostic: ?vm.Diagnostic = null;
    state.push(.from(.{ .number = 8 })) catch return 1;
    _ = vm.runFunctionWithArguments(state, .{ .native = hookTarget }, 1, &diagnostic) catch {
        hook_entry_failed = true;
        return 1;
    };
    return 0;
}

test "native_call hook callback runs a native target with its own argument window" {
    var state = try State.init(a);
    defer state.deinit();
    state.setHook(reenterFromHook, 1);
    hook_entry_failed = false;
    hook_target_calls = 0;
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(&state, "local x = 1 return x", &diagnostic);
    try expect(!hook_entry_failed);
    try expect(hook_target_calls > 0);
    try equal(@as(usize, 0), state.frames.items.len);
    try equal(@as(usize, 1), state.top());
    try expect(state.get(-1).?.equal(.from(.{ .number = 1 })));
}

extern fn test_native_invalid_negative(*State) callconv(.c) c_int;
extern fn test_native_overcount(*State) callconv(.c) c_int;
extern fn test_native_exact_results(*State) callconv(.c) c_int;

test "native_call actual C result misuse propagates through direct tail and iterator entries" {
    for ([_]runtime.Native{ test_native_invalid_negative, test_native_overcount }) |callback| {
        for ([_]bool{ false, true }) |captured| {
            var state = try State.init(a);
            defer state.deinit();
            const function: runtime.Function = if (captured) try state.newCClosure(callback, &.{.nil}) else .{ .native = callback };
            try field(&state, state.globals, "f", .fromFunction(function));
            try state.push(.from(.{ .number = 42 }));
            for ([_][]const u8{ "f()", "return f()", "for k in f,nil,0 do end" }) |source| {
                var diagnostic: ?vm.Diagnostic = null;
                try std.testing.expectError(error.InvalidNativeResult, run(&state, source, &diagnostic));
                try equal(runtime.FailureKind.invalid_native_result, state.failure.?.kind);
                try equal(@as(usize, 1), state.top());
                try equal(@as(usize, 0), state.frames.items.len);
                try expect(state.execution == null);
                try equal(@as(f64, 42), state.get(1).?.numberValue().?);
            }
        }
    }
}

test "native_call exact visible C result counts including zero remain valid" {
    var state = try State.init(a);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    var diagnostic: ?vm.Diagnostic = null;
    try equal(@as(usize, 0), try vm.runFunctionWithArguments(&state, .{ .native = test_native_exact_results }, 0, &diagnostic));
    try state.push(.from(.{ .number = 7 }));
    try state.push(.from(.{ .number = 8 }));
    try equal(@as(usize, 2), try vm.runFunctionWithArguments(&state, .{ .native = test_native_exact_results }, 2, &diagnostic));
    try equal(@as(usize, 3), state.top());
    try equal(@as(f64, 42), state.get(1).?.numberValue().?);
    try equal(@as(f64, 7), state.get(2).?.numberValue().?);
    try equal(@as(f64, 8), state.get(3).?.numberValue().?);
}
