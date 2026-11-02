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
const comparisons = [_]struct { name: []const u8, source: []const u8, reversed: bool }{
    .{ .name = "__lt", .source = "return left < right", .reversed = false },
    .{ .name = "__le", .source = "return left <= right", .reversed = false },
    .{ .name = "__lt", .source = "return left > right", .reversed = true },
    .{ .name = "__le", .source = "return left >= right", .reversed = true },
};
fn field(state: *State, table: *runtime.Table, name: []const u8, value: Value) !void {
    state.barrier(&table.header);
    try table.set(state.allocator, .from(.{ .string = try state.newString(name) }), value);
}
fn compile(state: *State, allocator: std.mem.Allocator, source: []const u8) !*runtime.Closure {
    var parsed: ?parser.Diagnostic = null;
    var ast = try parser.parseChunk(allocator, source, &parsed);
    defer ast.deinit();
    var diagnostic: ?compiler.Diagnostic = null;
    return state.newChunk(try compiler.compile(allocator, state, &ast, "<order-handler>", &diagnostic));
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

test "order_handler normalized operands determine priority and argument order" {
    for (comparisons) |op| {
        var state = try State.init(a);
        defer state.deinit();
        const left = Value.from(.{ .table = try state.newTable() });
        const right = Value.from(.{ .table = try state.newTable() });
        try install(&state, "left", left);
        try install(&state, "right", right);
        const left_meta = try attach(&state, left, op.name, try script(&state, "global * return function(x,y) first=x second=y selected=1 return 0 end"));
        const right_meta = try attach(&state, right, op.name, try script(&state, "global * return function(x,y) first=x second=y selected=2 return false end"));
        var diagnostic: ?vm.Diagnostic = null;
        _ = try run(&state, op.source, &diagnostic);
        try expect(state.get(-1).?.equal(.from(.{ .boolean = !op.reversed })));
        try expect(state.globals.getString("selected").equal(.from(.{ .number = if (op.reversed) 2 else 1 })));
        try expect(state.globals.getString("first").equal(if (op.reversed) right else left));
        try expect(state.globals.getString("second").equal(if (op.reversed) left else right));
        try state.setTop(0);
        try field(&state, if (op.reversed) right_meta else left_meta, op.name, .nil);
        _ = try run(&state, op.source, &diagnostic);
        try expect(state.get(-1).?.equal(.from(.{ .boolean = op.reversed })));
        try expect(state.globals.getString("first").equal(if (op.reversed) right else left));
        try expect(state.globals.getString("second").equal(if (op.reversed) left else right));
    }
}

test "order_handler result truth uses only nil and false including no or multiple results" {
    for ([_]struct { body: []const u8, truth: bool }{
        .{ .body = "return function() return end", .truth = false },
        .{ .body = "return function() return nil,true end", .truth = false },
        .{ .body = "return function() return false,true end", .truth = false },
        .{ .body = "return function() return 0,false end", .truth = true },
        .{ .body = "return function() return '' end", .truth = true },
        .{ .body = "return function() return {} end", .truth = true },
        .{ .body = "return function() return function()end end", .truth = true },
    }) |case| {
        var state = try State.init(a);
        defer state.deinit();
        const value = Value.from(.{ .table = try state.newTable() });
        try install(&state, "left", value);
        const method = try script(&state, case.body);
        const meta = try attach(&state, value, "__lt", method);
        try field(&state, meta, "__le", method);
        var diagnostic: ?vm.Diagnostic = null;
        // Same identity does not bypass order handlers.
        try equal(@as(usize, 4), try run(&state, "return left<left,left<=left,left>left,left>=left", &diagnostic));
        for (state.stack.items) |actual| try expect(actual.equal(.from(.{ .boolean = case.truth })));
    }
}

test "order_handler an inherited handler is found and an uncallable handler fails as a call" {
    var state = try State.init(a);
    defer state.deinit();
    const left = Value.from(.{ .table = try state.newTable() });
    const right = Value.from(.{ .table = try state.newTable() });
    try install(&state, "left", left);
    try install(&state, "right", right);
    const method = try script(&state, "global * return function() called=true return true end");
    const meta = try attach(&state, left, "__lt", .nil);
    const provider = try state.newTable();
    try field(&state, provider, "__lt", method);
    _ = try attach(&state, .from(.{ .table = meta }), "__index", .from(.{ .table = provider }));
    var diagnostic: ?vm.Diagnostic = null;
    // __lt one table-valued __index link away is the handler (ADR 0012).
    _ = try run(&state, "return left<right", &diagnostic);
    try expect(state.get(-1).?.equal(.from(.{ .boolean = true })));
    try expect(state.globals.getString("called").equal(.from(.{ .boolean = true })));
    try state.setTop(0);
    try field(&state, state.globals, "called", .nil);
    _ = try attach(&state, right, "__lt", method);
    // An uncallable handler fails as a call and names the metamethod.
    const Uncallable = struct { method: Value, message: []const u8 };
    for ([_]Uncallable{
        .{ .method = .from(.{ .boolean = false }), .message = "[string \"<order-handler>\"]:1: attempt to call a boolean value (metamethod 'lt')" },
        .{ .method = .from(.{ .number = 0 }), .message = "[string \"<order-handler>\"]:1: attempt to call a number value (metamethod 'lt')" },
        .{ .method = .from(.{ .table = provider }), .message = "[string \"<order-handler>\"]:1: attempt to call a table value (metamethod 'lt')" },
    }) |case| {
        try field(&state, meta, "__lt", case.method);
        try std.testing.expectError(error.Type, run(&state, "return left<right", &diagnostic));
        try std.testing.expectEqualStrings(case.message, state.failure.?.value.unpack().string.bytes);
        try state.setTop(0);
        try expect(state.globals.getString("called").is(.nil));
    }
    try field(&state, meta, "__le", .from(.{ .boolean = false }));
    try std.testing.expectError(error.Type, run(&state, "return left<=right", &diagnostic));
    try std.testing.expectEqualStrings("[string \"<order-handler>\"]:1: attempt to call a boolean value (metamethod 'le')", state.failure.?.value.unpack().string.bytes);
    try state.setTop(0);
    // A callable table handler is called with itself first.
    const callable = Value.from(.{ .table = try state.newTable() });
    try install(&state, "callable", callable);
    _ = try attach(&state, callable, "__call", try script(&state, "global * return function(self, x, y) seen_self = self return true end"));
    try field(&state, meta, "__lt", callable);
    _ = try run(&state, "return left<right", &diagnostic);
    try expect(state.get(-1).?.equal(.from(.{ .boolean = true })));
    try expect(state.globals.getString("seen_self").equal(callable));
}

test "order_handler inclusive comparisons never fall back to lt" {
    var state = try State.init(a);
    defer state.deinit();
    const left = Value.from(.{ .table = try state.newTable() });
    const right = Value.from(.{ .table = try state.newTable() });
    try install(&state, "left", left);
    try install(&state, "right", right);
    const method = try script(&state, "global * return function() called=true return true end");
    const meta = try attach(&state, left, "__lt", method);
    try field(&state, meta, "__eq", method);
    var diagnostic: ?vm.Diagnostic = null;
    for ([_][]const u8{ "return left<=right", "return left>=right", "return right<=left", "return right>=left", "return left<=left" }) |source| {
        try std.testing.expectError(error.Type, run(&state, source, &diagnostic));
        try equal(.type_error, diagnostic.?.kind);
        try expect(state.globals.getString("called").is(.nil));
    }
    try field(&state, meta, "__le", method);
    _ = try run(&state, "return left<=right,left>=right,left==left,left==1", &diagnostic);
    for ([_]bool{ true, true, true, false }, state.stack.items) |wanted, actual| try expect(actual.equal(.from(.{ .boolean = wanted })));
}

test "order_handler userdata and mixed primitive operands retain source identity" {
    for (comparisons) |op| {
        var state = try State.init(a);
        defer state.deinit();
        const value = Value.from(.{ .userdata = try state.newUserdata(0) });
        try install(&state, "left", .from(.{ .number = 7 }));
        try install(&state, "right", value);
        _ = try attach(&state, value, op.name, try script(&state, "global * return function(x,y) first=x second=y return {} end"));
        var diagnostic: ?vm.Diagnostic = null;
        _ = try run(&state, op.source, &diagnostic);
        try expect(state.get(-1).?.equal(.from(.{ .boolean = true })));
        try expect(state.globals.getString("first").equal(if (op.reversed) value else .from(.{ .number = 7 })));
        try expect(state.globals.getString("second").equal(if (op.reversed) .from(.{ .number = 7 }) else value));
    }
}

test "order_handler ordinary numbers strings and absent handlers preserve behavior" {
    var state = try State.init(a);
    defer state.deinit();
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(&state, "return 1<2,2<=2,2>1,2>=2,'a'<'b','b'>='b',(0/0)<1,(0/0)>=1", &diagnostic);
    for ([_]bool{ true, true, true, true, true, true, false, false }, state.stack.items) |wanted, actual| try expect(actual.equal(.from(.{ .boolean = wanted })));
    try state.setTop(0);
    for ([_][]const u8{ "return {}<{}", "return {}<={}", "return 1<'2'", "return false>=true" }) |source| try std.testing.expectError(error.Type, run(&state, source, &diagnostic));
}

test "order_handler failure captures and truthy objects survive collection" {
    var state = try State.init(a);
    defer state.deinit();
    const value = Value.from(.{ .table = try state.newTable() });
    try install(&state, "left", value);
    const meta = try attach(&state, value, "__lt", try script(&state, "return function(x,y) local n=0 while n<200 do local garbage={} n=n+1 end return {} end"));
    state.setCollectionThreshold(0);
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(&state, "return left<7", &diagnostic);
    try expect(state.get(-1).?.equal(.from(.{ .boolean = true })));
    try state.setTop(0);
    try field(&state, meta, "__lt", try script(&state, "global * return function(x,y) local box={v=y} saved=function() return box.v end\nreturn 1+nil end"));
    try state.push(.from(.{ .number = 42 }));
    try std.testing.expectError(error.Type, run(&state, "return left<8", &diagnostic));
    try equal(@as(usize, 2), diagnostic.?.position.line);
    try equal(@as(usize, 1), state.top());
    try equal(@as(usize, 0), state.frames.items.len);
    state.collect();
    _ = try run(&state, "return saved()", &diagnostic);
    try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
    try expect(state.get(2).?.equal(.from(.{ .number = 8 })));
}

var hook_calls: usize = 0;
fn interrupt(_: *State) callconv(.c) c_int {
    hook_calls += 1;
    return if (hook_calls >= 30) 1 else 0;
}

test "order_handler recursive depth and interruption restore caller" {
    for ([_]bool{ false, true }) |loop| {
        var state = try State.init(a);
        defer state.deinit();
        const value = Value.from(.{ .table = try state.newTable() });
        try install(&state, "left", value);
        _ = try attach(&state, value, "__le", try script(&state, if (loop) "return function() while true do end end" else "return function(x,y) return x<=y end"));
        try state.push(.from(.{ .number = 42 }));
        var diagnostic: ?vm.Diagnostic = null;
        if (loop) {
            hook_calls = 0;
            state.setHook(interrupt, 1);
            try std.testing.expectError(error.Interrupted, run(&state, "return left<=7", &diagnostic));
            try equal(@as(usize, 30), hook_calls);
            state.setHook(null, 0);
        } else try std.testing.expectError(error.CallDepth, run(&state, "return left<=7", &diagnostic));
        try equal(@as(usize, 1), state.top());
        try equal(@as(usize, 0), state.frames.items.len);
        _ = try run(&state, "return 9", &diagnostic);
        try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
        try expect(state.get(2).?.equal(.from(.{ .number = 9 })));
    }
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var state = try State.init(allocator);
    defer state.deinit();
    const method = try compile(&state, allocator, "local x,y=... local box={v=y} return box");
    const value = Value.from(.{ .table = try state.newTable() });
    _ = try attach(&state, value, "__lt", .fromFunction(.{ .closure = method }));
    try install(&state, "left", value);
    const closure = try compile(&state, allocator, "return left<7");
    try state.push(.from(.{ .number = 42 }));
    var diagnostic: ?vm.Diagnostic = null;
    _ = vm.run(&state, closure, &diagnostic) catch |err| {
        try equal(@as(usize, 1), state.top());
        try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
        try equal(@as(usize, 0), state.frames.items.len);
        return err;
    };
    try expect(state.get(2).?.equal(.from(.{ .boolean = true })));
}

test "order_handler allocation failures release partial calls and preserve caller" {
    try allocation_failures.checkAll(a, allocationCase, .{});
}

const MovingAllocator = struct {
    child: std.mem.Allocator,
    fn allocator(self: *MovingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *MovingAllocator = @ptrCast(@alignCast(context));
        return self.child.rawAlloc(len, alignment, ret_addr);
    }
    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *MovingAllocator = @ptrCast(@alignCast(context));
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

test "order_handler stack relocation preserves boolean destination and caller slots" {
    for (comparisons) |op| {
        var moving = MovingAllocator{ .child = a };
        var state = try State.init(moving.allocator());
        defer state.deinit();
        const left = Value.from(.{ .table = try state.newTable() });
        try install(&state, "left", left);
        try install(&state, "right", .from(.{ .number = 7 }));
        const method = try script(&state, "return function() return {} end");
        method.unpack().closure.prototype.registers = 10000;
        _ = try attach(&state, left, op.name, method);
        const source = try std.fmt.allocPrint(a, "{s},19", .{op.source});
        defer a.free(source);
        const closure = try compile(&state, a, source);
        try state.push(.from(.{ .number = 42 }));
        try runtime.growStack(&state.stack, state.open_cells.items, state.allocator, 32);
        const before = @intFromPtr(state.stack.items.ptr);
        state.setCollectionThreshold(0);
        var diagnostic: ?vm.Diagnostic = null;
        _ = try vm.run(&state, closure, &diagnostic);
        try expect(before != @intFromPtr(state.stack.items.ptr));
        try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
        try expect(state.get(2).?.equal(.from(.{ .boolean = true })));
        try expect(state.get(3).?.equal(.from(.{ .number = 19 })));
    }
}

test "order_handler captured Lua cases agree on priority truth and evaluation order" {
    var lines = std.mem.tokenizeScalar(u8, @embedFile("lua55-order-handlers"), '\n');
    var checked: usize = 0;
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const name = fields.next().?;
        const side = fields.next().?;
        var left_buffer: [4096]u8 = undefined;
        const left_source = try std.fmt.hexToBytes(&left_buffer, fields.next().?);
        var right_buffer: [4096]u8 = undefined;
        const right_source = try std.fmt.hexToBytes(&right_buffer, fields.next().?);
        var source_buffer: [4096]u8 = undefined;
        const source = try std.fmt.hexToBytes(&source_buffer, fields.next().?);
        const count = try std.fmt.parseInt(usize, fields.next().?, 10);
        const expected = fields.next().?;
        try expect(fields.next() == null);
        errdefer std.debug.print("order-handler fixture failed: {s}, {s}, {s}\n", .{ name, side, source });
        var state = try State.init(a);
        defer state.deinit();
        const left = Value.from(.{ .table = try state.newTable() });
        const right = Value.from(.{ .table = try state.newTable() });
        try field(&state, left.unpack().table, "v", .from(.{ .number = 2 }));
        try field(&state, right.unpack().table, "v", .from(.{ .number = 3 }));
        try install(&state, "left", left);
        try install(&state, "right", right);
        if (!std.mem.eql(u8, side, "right")) _ = try attach(&state, left, name, try script(&state, left_source));
        if (!std.mem.eql(u8, side, "left")) _ = try attach(&state, right, name, try script(&state, right_source));
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
            } else if (actual.is(.boolean)) try equal(std.mem.eql(u8, payload, "true"), actual.unpack().boolean) else try expect(actual.is(.nil));
        }
        try expect(values.next() == null);
        checked += 1;
    }
    try expect(checked > 0);
    std.debug.print("order-handler fixture: {d} Lua cases checked through parser, compiler and VM\n", .{checked});
}
