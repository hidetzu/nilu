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
    return state.newChunk(try compiler.compile(allocator, state, &ast, "<operator-handler>", &diagnostic));
}
fn run(state: *State, source: []const u8, diagnostic: *?vm.Diagnostic) !usize {
    return vm.run(state, try compile(state, a, source), diagnostic);
}
fn script(state: *State, source: []const u8) !Value {
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(state, source, &diagnostic);
    const method = state.get(-1).?;
    try state.setTop(-2);
    return method;
}
fn attach(state: *State, receiver: Value, name: []const u8, method: Value) !*runtime.Table {
    const meta = try state.newTable();
    try field(state, meta, name, method);
    try state.setMetatable(receiver, meta);
    return meta;
}
fn install(state: *State, name: []const u8, value: Value) !void {
    try field(state, state.globals, name, value);
}

test "call_handler ordinary script calls insert receiver before fixed and open arguments" {
    var state = try State.init(a);
    defer state.deinit();
    const value = Value.from(.{ .table = try state.newTable() });
    try install(&state, "t", value);
    _ = try attach(&state, value, "__call", try script(&state, "global * return function(self,a,b,c) seen=self return a,b,c end"));
    try state.push(.from(.{ .number = 42 }));
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(&state, "local function args() return 1,nil,3 end local a,b,c,d=t(args()) local x=t(8) t() return a,b,c,d,x", &diagnostic);
    for ([_]Value{ .from(.{ .number = 42 }), .from(.{ .number = 1 }), .nil, .from(.{ .number = 3 }), .nil, .from(.{ .number = 8 }) }, state.stack.items) |wanted, actual| try expect(actual.equal(wanted));
    try expect(state.globals.getString("seen").equal(value));
    try equal(@as(usize, 0), state.frames.items.len);
}

fn nativeCall(state: *State) callconv(.c) c_int {
    if (state.top() != 3 or !state.get(1).?.is(.userdata) or !state.get(2).?.equal(.from(.{ .number = 7 })) or !state.get(3).?.is(.nil)) return -1;
    state.collect();
    state.push(.from(.{ .number = 9 })) catch return -1;
    state.push(.from(.{ .number = 10 })) catch return -1;
    return 2;
}
test "call_handler userdata native and C closures receive rooted receiver and arguments" {
    for ([_]bool{ false, true }) |captured| {
        var state = try State.init(a);
        defer state.deinit();
        const value = Value.from(.{ .userdata = try state.newUserdata(8) });
        try install(&state, "t", value);
        _ = try attach(&state, value, "__call", .fromFunction(if (captured) try state.newCClosure(nativeCall, &.{value}) else .{ .native = nativeCall }));
        state.setCollectionThreshold(0);
        var diagnostic: ?vm.Diagnostic = null;
        _ = try run(&state, "local a,b=t(7,nil) return a,b", &diagnostic);
        try expect(state.get(1).?.equal(.from(.{ .number = 9 })));
        try expect(state.get(2).?.equal(.from(.{ .number = 10 })));
    }
}

test "call_handler an inherited method is found and non-callable or cyclic handlers are refused" {
    var state = try State.init(a);
    defer state.deinit();
    const value = Value.from(.{ .table = try state.newTable() });
    try install(&state, "t", value);
    const meta = try attach(&state, value, "__call", .nil);
    const provider = try state.newTable();
    try field(&state, provider, "__call", try script(&state, "return function() return 9 end"));
    _ = try attach(&state, .from(.{ .table = meta }), "__index", .from(.{ .table = provider }));
    var diagnostic: ?vm.Diagnostic = null;
    // __call one table-valued __index link away is the handler (ADR 0012).
    try equal(@as(usize, 1), try run(&state, "return t()", &diagnostic));
    try expect(state.get(-1).?.equal(.from(.{ .number = 9 })));
    try state.setTop(0);
    for ([_][]const u8{ "local f=1 f()", "local f=false f()", "local f=nil f()" }) |source| {
        try std.testing.expectError(error.Type, run(&state, source, &diagnostic));
        try equal(@as(usize, 0), state.top());
    }
    for ([_]Value{ .from(.{ .boolean = false }), .from(.{ .number = 1 }) }) |method| {
        try field(&state, meta, "__call", method);
        diagnostic = null;
        try std.testing.expectError(error.Type, run(&state, "t()", &diagnostic));
        try equal(method.type(), diagnostic.?.operand_type.?);
        try equal(@as(usize, 0), state.top());
    }
    try field(&state, meta, "__call", value);
    diagnostic = null;
    try std.testing.expectError(error.Runtime, run(&state, "t()", &diagnostic));
    try expect(diagnostic.?.kind == .call_chain_too_long);
    try equal(@as(usize, 0), state.top());
    try equal(@as(usize, 0), state.frames.items.len);
}

test "call_handler tail and generic iterator entries resolve the handler like an ordinary call" {
    var state = try State.init(a);
    defer state.deinit();
    const value = Value.from(.{ .table = try state.newTable() });
    try install(&state, "t", value);
    _ = try attach(&state, value, "__call", try script(&state, "global * return function(self) called=self end"));
    var diagnostic: ?vm.Diagnostic = null;
    for ([_][]const u8{ "return t()", "for k in t do end" }) |source| {
        try field(&state, state.globals, "called", .nil);
        _ = try run(&state, source, &diagnostic);
        try expect(state.globals.getString("called").equal(value));
        try equal(@as(usize, 0), state.top());
        try equal(@as(usize, 0), state.frames.items.len);
    }
}

test "call_handler failure closes captures and recursive calls share depth" {
    var state = try State.init(a);
    defer state.deinit();
    const value = Value.from(.{ .table = try state.newTable() });
    try install(&state, "t", value);
    const meta = try attach(&state, value, "__call", try script(&state, "global * return function() local n=7 saved=function() return n end return 1+nil end"));
    try state.push(.from(.{ .number = 42 }));
    var diagnostic: ?vm.Diagnostic = null;
    try std.testing.expectError(error.Type, run(&state, "t()", &diagnostic));
    try equal(@as(usize, 1), state.top());
    state.collect();
    _ = try run(&state, "return saved()", &diagnostic);
    try expect(state.get(-1).?.equal(.from(.{ .number = 7 })));
    try state.setTop(1);
    try field(&state, meta, "__call", try script(&state, "return function(self) self() end"));
    try std.testing.expectError(error.CallDepth, run(&state, "t()", &diagnostic));
    try equal(@as(usize, 1), state.top());
    try equal(@as(usize, 0), state.frames.items.len);
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var state = try State.init(allocator);
    defer state.deinit();
    const value = Value.from(.{ .table = try state.newTable() });
    try install(&state, "t", value);
    var diagnostic: ?vm.Diagnostic = null;
    _ = try vm.run(&state, try compile(&state, allocator, "return function(self,x) return {n=x} end"), &diagnostic);
    _ = try attach(&state, value, "__call", state.get(-1).?);
    try state.setTop(0);
    const closure = try compile(&state, allocator, "local x=t(7) return x.n");
    try state.push(.from(.{ .number = 42 }));
    _ = vm.run(&state, closure, &diagnostic) catch |err| {
        try equal(@as(usize, 1), state.top());
        try equal(@as(usize, 0), state.frames.items.len);
        return err;
    };
    try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
    try expect(state.get(2).?.equal(.from(.{ .number = 7 })));
}
test "call_handler allocation failures restore caller and release partial setup" {
    try allocation_failures.checkAll(a, allocationCase, .{});
}

test "call_handler script stack growth preserves receiver results and caller" {
    var state = try State.init(a);
    defer state.deinit();
    const value = Value.from(.{ .table = try state.newTable() });
    try install(&state, "t", value);
    const method = try script(&state, "return function(self,x) return self,x end");
    method.unpack().closure.prototype.registers = 10000;
    _ = try attach(&state, value, "__call", method);
    try state.push(.from(.{ .number = 42 }));
    const capacity = state.stack.capacity;
    state.setCollectionThreshold(0);
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(&state, "local keep=9 local self,x=t(7) return keep,self,x", &diagnostic);
    try expect(state.stack.capacity > capacity);
    for ([_]Value{ .from(.{ .number = 42 }), .from(.{ .number = 9 }), value, .from(.{ .number = 7 }) }, state.stack.items) |wanted, actual| try expect(actual.equal(wanted));
}

test "call_handler open results expand in final argument and constructor positions" {
    var state = try State.init(a);
    defer state.deinit();
    const value = Value.from(.{ .table = try state.newTable() });
    try install(&state, "t", value);
    _ = try attach(&state, value, "__call", try script(&state, "return function(self,...) return ... end"));
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(&state, "local function f(...) return ... end local x={0,t(1,2)} local a,b,c=f(t(7,8,9)) return x[1],x[2],x[3],a,b,c", &diagnostic);
    for ([_]f64{ 0, 1, 2, 7, 8, 9 }, state.stack.items) |wanted, actual| try expect(actual.equal(.from(.{ .number = wanted })));
}
