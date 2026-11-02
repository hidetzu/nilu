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

test "equality_handler selects left then right converts first result and negates inequality" {
    const cases = [_]struct { source: []const u8, truth: bool }{
        .{ .source = "", .truth = false },              .{ .source = "nil,true", .truth = false },
        .{ .source = "false,true", .truth = false },    .{ .source = "0,false", .truth = true },
        .{ .source = "'',false", .truth = true },       .{ .source = "{},false", .truth = true },
        .{ .source = "function() end", .truth = true },
    };
    for (cases) |case| {
        var state = try State.init(a);
        defer state.deinit();
        const left = Value.from(.{ .table = try state.newTable() });
        const right = Value.from(.{ .table = try state.newTable() });
        try install(&state, "left", left);
        try install(&state, "right", right);
        const source = try std.fmt.allocPrint(a, "global * return function(x,y) first=x second=y chosen=1 return {s} end", .{case.source});
        defer a.free(source);
        const meta = try attach(&state, left, "__eq", try script(&state, source));
        _ = try attach(&state, right, "__eq", try script(&state, "global * return function(x,y) first=x second=y chosen=2 return true end"));
        try state.push(.from(.{ .number = 42 }));
        var diagnostic: ?vm.Diagnostic = null;
        _ = try run(&state, "return left==right,left~=right", &diagnostic);
        try expect(state.get(2).?.equal(.from(.{ .boolean = case.truth })));
        try expect(state.get(3).?.equal(.from(.{ .boolean = !case.truth })));
        try expect(state.globals.getString("chosen").equal(.from(.{ .number = 1 })));
        try expect(state.globals.getString("first").equal(left));
        try expect(state.globals.getString("second").equal(right));
        try state.setTop(1);
        try field(&state, meta, "__eq", .nil);
        _ = try run(&state, "return left==right", &diagnostic);
        try expect(state.get(2).?.equal(.from(.{ .boolean = true })));
        try expect(state.globals.getString("chosen").equal(.from(.{ .number = 2 })));
        try expect(state.globals.getString("first").equal(left));
        try expect(state.globals.getString("second").equal(right));
        try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
    }
}

test "equality_handler identity mixed types and userdata bypass handlers" {
    var state = try State.init(a);
    defer state.deinit();
    const left = Value.from(.{ .table = try state.newTable() });
    const u = Value.from(.{ .userdata = try state.newUserdata(0) });
    const v = Value.from(.{ .userdata = try state.newUserdata(0) });
    const method = try script(&state, "global * return function() called=true return true end");
    for ([_]Value{ left, u, v }) |value| _ = try attach(&state, value, "__eq", method);
    try install(&state, "t", left);
    try install(&state, "u", u);
    try install(&state, "v", v);
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(&state, "return t==t,t~=t,t==1,t==nil,t==false,t=='x',t==u,u==t,u==v,u~=v,u==u,{}=={}", &diagnostic);
    for ([_]bool{ true, false, false, false, false, false, false, false, false, true, true, false }, state.stack.items) |wanted, actual| try expect(actual.equal(.from(.{ .boolean = wanted })));
    try expect(state.globals.getString("called").is(.nil));
}

test "equality_handler an inherited handler is found and an uncallable left handler fails as a call" {
    var state = try State.init(a);
    defer state.deinit();
    const left = Value.from(.{ .table = try state.newTable() });
    const right = Value.from(.{ .table = try state.newTable() });
    try install(&state, "left", left);
    try install(&state, "right", right);
    const method = try script(&state, "global * return function() called=true return true end");
    const meta = try attach(&state, left, "__eq", .nil);
    const provider = try state.newTable();
    try field(&state, provider, "__eq", method);
    _ = try attach(&state, .from(.{ .table = meta }), "__index", .from(.{ .table = provider }));
    var diagnostic: ?vm.Diagnostic = null;
    // __eq one table-valued __index link away is the handler (ADR 0012).
    _ = try run(&state, "return left==right", &diagnostic);
    try expect(state.get(-1).?.equal(.from(.{ .boolean = true })));
    try expect(state.globals.getString("called").equal(.from(.{ .boolean = true })));
    try state.setTop(0);
    try field(&state, state.globals, "called", .nil);
    _ = try attach(&state, right, "__eq", method);
    // An uncallable handler fails as a call and names the metamethod.
    const Uncallable = struct { method: Value, message: []const u8 };
    for ([_]Uncallable{
        .{ .method = .from(.{ .boolean = false }), .message = "[string \"<operator-handler>\"]:1: attempt to call a boolean value (metamethod 'eq')" },
        .{ .method = .from(.{ .number = 0 }), .message = "[string \"<operator-handler>\"]:1: attempt to call a number value (metamethod 'eq')" },
        .{ .method = .from(.{ .table = provider }), .message = "[string \"<operator-handler>\"]:1: attempt to call a table value (metamethod 'eq')" },
    }) |case| {
        try field(&state, meta, "__eq", case.method);
        try std.testing.expectError(error.Type, run(&state, "return left==right", &diagnostic));
        try std.testing.expectEqualStrings(case.message, state.failure.?.value.unpack().string.bytes);
        try state.setTop(0);
        try expect(state.globals.getString("called").is(.nil));
    }
    // A callable table handler is called with itself first.
    const callable = Value.from(.{ .table = try state.newTable() });
    try install(&state, "callable", callable);
    _ = try attach(&state, callable, "__call", try script(&state, "global * return function(self, x, y) seen_self = self return true end"));
    try field(&state, meta, "__eq", callable);
    _ = try run(&state, "return left==right", &diagnostic);
    try expect(state.get(-1).?.equal(.from(.{ .boolean = true })));
    try expect(state.globals.getString("seen_self").equal(callable));
}

fn nativeEqual(state: *State) callconv(.c) c_int {
    if (state.top() != 2 or !state.get(1).?.is(.table) or !state.get(2).?.is(.table)) return -1;
    state.collect();
    state.push(.from(.{ .number = 0 })) catch return -1;
    state.push(.from(.{ .boolean = false })) catch return -1;
    return 2;
}
test "equality_handler native C closures GC and source evaluation order" {
    for ([_]bool{ false, true }) |captured| {
        var state = try State.init(a);
        defer state.deinit();
        const left = Value.from(.{ .table = try state.newTable() });
        try install(&state, "left", left);
        try install(&state, "right", .from(.{ .table = try state.newTable() }));
        _ = try attach(&state, left, "__eq", .fromFunction(if (captured) try state.newCClosure(nativeEqual, &.{left}) else .{ .native = nativeEqual }));
        state.setCollectionThreshold(0);
        var diagnostic: ?vm.Diagnostic = null;
        _ = try run(&state, "local n=0 local function take(i,x) n=n*10+i return x end local r=take(1,left)==take(2,right) return r,n", &diagnostic);
        try expect(state.get(1).?.equal(.from(.{ .boolean = true })));
        try expect(state.get(2).?.equal(.from(.{ .number = 12 })));
    }
}

test "equality_handler failures close escaped captures and recursive calls unwind" {
    var state = try State.init(a);
    defer state.deinit();
    const left = Value.from(.{ .table = try state.newTable() });
    try install(&state, "left", left);
    try install(&state, "right", .from(.{ .table = try state.newTable() }));
    const meta = try attach(&state, left, "__eq", try script(&state, "global * return function() local n=7 saved=function() return n end return 1+nil end"));
    try state.push(.from(.{ .number = 42 }));
    var diagnostic: ?vm.Diagnostic = null;
    try std.testing.expectError(error.Type, run(&state, "return left==right", &diagnostic));
    try equal(@as(usize, 1), state.top());
    state.collect();
    _ = try run(&state, "return saved()", &diagnostic);
    try expect(state.get(-1).?.equal(.from(.{ .number = 7 })));
    try state.setTop(1);
    try field(&state, meta, "__eq", try script(&state, "return function(x,y) return x==y end"));
    try std.testing.expectError(error.CallDepth, run(&state, "return left==right", &diagnostic));
    try equal(@as(usize, 1), state.top());
    try equal(@as(usize, 0), state.frames.items.len);
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var state = try State.init(allocator);
    defer state.deinit();
    const left = Value.from(.{ .table = try state.newTable() });
    try install(&state, "left", left);
    try install(&state, "right", .from(.{ .table = try state.newTable() }));
    var diagnostic: ?vm.Diagnostic = null;
    _ = try vm.run(&state, try compile(&state, allocator, "return function() return {} end"), &diagnostic);
    _ = try attach(&state, left, "__eq", state.get(-1).?);
    try state.setTop(0);
    const closure = try compile(&state, allocator, "return left==right");
    try state.push(.from(.{ .number = 42 }));
    _ = vm.run(&state, closure, &diagnostic) catch |err| {
        try equal(@as(usize, 1), state.top());
        try equal(@as(usize, 0), state.frames.items.len);
        return err;
    };
    try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
    try expect(state.get(2).?.equal(.from(.{ .boolean = true })));
}
test "equality_handler allocation failures reclaim setup and restore caller" {
    try allocation_failures.checkAll(a, allocationCase, .{});
}
