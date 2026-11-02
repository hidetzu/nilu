const std = @import("std");
const allocation_failures = @import("allocation_failures.zig");
const runtime = @import("runtime.zig");
const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const vm = @import("vm.zig");
const bytecode = @import("bytecode.zig");
const a = std.testing.allocator;
const State = runtime.State;
const Value = runtime.Value;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const operators = [_]struct { name: []const u8, source: []const u8 }{
    .{ .name = "__add", .source = "return left + right" },
    .{ .name = "__sub", .source = "return left - right" },
    .{ .name = "__mul", .source = "return left * right" },
    .{ .name = "__div", .source = "return left / right" },
    .{ .name = "__idiv", .source = "return left // right" },
    .{ .name = "__mod", .source = "return left % right" },
    .{ .name = "__pow", .source = "return left ^ right" },
    .{ .name = "__concat", .source = "return left .. right" },
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

fn expectUncallable(state: *State, source: []const u8, message: []const u8) !void {
    var diagnostic: ?vm.Diagnostic = null;
    try std.testing.expectError(error.Type, run(state, source, &diagnostic));
    try std.testing.expectEqualStrings(message, state.failure.?.value.unpack().string.bytes);
    try state.setTop(0);
}

test "operator_handler binary operations select left then right and preserve operand order" {
    for (operators) |op| {
        var state = try State.init(a);
        defer state.deinit();
        const left = Value.from(.{ .table = try state.newTable() });
        const right = Value.from(.{ .table = try state.newTable() });
        try install(&state, "left", left);
        try install(&state, "right", right);
        const left_meta = try attach(&state, left, op.name, try script(&state, "global * return function(x,y) first=x second=y return 23,99 end"));
        _ = try attach(&state, right, op.name, try script(&state, "global * return function(x,y) first=x second=y return 31,99 end"));
        var diagnostic: ?vm.Diagnostic = null;
        _ = try run(&state, op.source, &diagnostic);
        try expect(state.get(-1).?.equal(.from(.{ .number = 23 })));
        try expect(state.globals.getString("first").equal(left));
        try expect(state.globals.getString("second").equal(right));
        try state.setTop(0);
        try field(&state, left_meta, op.name, .nil);
        _ = try run(&state, op.source, &diagnostic);
        try expect(state.get(-1).?.equal(.from(.{ .number = 31 })));
        try expect(state.globals.getString("first").equal(left));
        try expect(state.globals.getString("second").equal(right));
        try state.setTop(0);
        try install(&state, "left", .from(.{ .number = 7 }));
        _ = try run(&state, op.source, &diagnostic);
        try expect(state.globals.getString("first").equal(.from(.{ .number = 7 })));
        try expect(state.globals.getString("second").equal(right));
    }
}

test "operator_handler unary minus passes the operand twice" {
    var state = try State.init(a);
    defer state.deinit();
    const value = Value.from(.{ .table = try state.newTable() });
    try install(&state, "value", value);
    _ = try attach(&state, value, "__unm", try script(&state, "global * return function(x,y,...) first=x second=y local rest={...} return #rest end"));
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(&state, "return -value", &diagnostic);
    try expect(state.get(-1).?.equal(.from(.{ .number = 0 })));
    try expect(state.globals.getString("first").equal(value));
    try expect(state.globals.getString("second").equal(value));
}

test "operator_handler results remain arbitrary values with one result or nil" {
    for ([_]struct { body: []const u8, expected: Value }{
        .{ .body = "return function() return end", .expected = .nil },
        .{ .body = "return function() return nil,99 end", .expected = .nil },
        .{ .body = "return function() return false,99 end", .expected = .from(.{ .boolean = false }) },
        .{ .body = "return function() return 0,99 end", .expected = .from(.{ .number = 0 }) },
    }) |case| {
        var state = try State.init(a);
        defer state.deinit();
        const value = Value.from(.{ .table = try state.newTable() });
        try install(&state, "value", value);
        const method = try script(&state, case.body);
        const meta = try attach(&state, value, "__add", method);
        try field(&state, meta, "__unm", method);
        try field(&state, meta, "__concat", method);
        var diagnostic: ?vm.Diagnostic = null;
        try equal(@as(usize, 3), try run(&state, "return value+1,-value,value..'x'", &diagnostic));
        for (state.stack.items) |actual| try expect(actual.equal(case.expected));
    }
}

// A handler is anything a call accepts (the owner's answer of 2026-10-30): a
// callable table receives itself before the operands, and a value
// nothing can call fails as a call does, naming the metamethod. The other
// operand's handler is never consulted once the first operand has one.
test "operator_handler a callable handler is called with itself first and an uncallable one fails as a call" {
    var state = try State.init(a);
    defer state.deinit();
    const left = Value.from(.{ .table = try state.newTable() });
    const right = Value.from(.{ .table = try state.newTable() });
    try install(&state, "left", left);
    try install(&state, "right", right);
    const meta = try attach(&state, left, "__add", .nil);
    _ = try attach(&state, right, "__add", try script(&state, "global * return function() called=true return 7 end"));
    const callable = Value.from(.{ .table = try state.newTable() });
    try install(&state, "callable", callable);
    _ = try attach(&state, callable, "__call", try script(&state, "global * return function(self, x, y) seen = {self, x, y} return 9 end"));
    var diagnostic: ?vm.Diagnostic = null;
    try field(&state, meta, "__add", callable);
    _ = try run(&state, "return left+right", &diagnostic);
    try expect(state.get(-1).?.equal(.from(.{ .number = 9 })));
    const seen = state.globals.getString("seen").unpack().table;
    try expect(seen.get(.from(.{ .number = 1 })).equal(callable) and seen.get(.from(.{ .number = 2 })).equal(left) and seen.get(.from(.{ .number = 3 })).equal(right));
    try expect(state.globals.getString("called").is(.nil));
    try state.setTop(0);
    const Uncallable = struct { method: Value, message: []const u8 };
    const plain = Value.from(.{ .table = try state.newTable() });
    try install(&state, "plain", plain);
    for ([_]Uncallable{
        .{ .method = .from(.{ .boolean = false }), .message = "[string \"<operator-handler>\"]:1: attempt to call a boolean value (metamethod 'add')" },
        .{ .method = .from(.{ .number = 0 }), .message = "[string \"<operator-handler>\"]:1: attempt to call a number value (metamethod 'add')" },
        .{ .method = plain, .message = "[string \"<operator-handler>\"]:1: attempt to call a table value (metamethod 'add')" },
    }) |case| {
        try field(&state, meta, "__add", case.method);
        try expectUncallable(&state, "return left+right", case.message);
        try expect(state.globals.getString("called").is(.nil));
        // The first operand's handler decides; the right operand's function
        // is used only when the left operand has no handler at all.
        _ = try run(&state, "return right+left", &diagnostic);
        try expect(state.get(-1).?.equal(.from(.{ .number = 7 })));
        try expect(state.globals.getString("called").equal(.from(.{ .boolean = true })));
        try field(&state, state.globals, "called", .nil);
        try state.setTop(0);
    }
    // Every operator names its own event, as Lua does.
    try field(&state, meta, "__add", .nil);
    for ([_][2][]const u8{ .{ "__sub", "return left-1" }, .{ "__mul", "return left*1" }, .{ "__div", "return left/1" }, .{ "__mod", "return left%1" }, .{ "__pow", "return left^1" }, .{ "__idiv", "return left//1" }, .{ "__unm", "return -left" }, .{ "__concat", "return left..'x'" } }) |case| {
        try field(&state, meta, case[0], .from(.{ .boolean = false }));
        var message: [96]u8 = undefined;
        const text = try std.fmt.bufPrint(&message, "[string \"<operator-handler>\"]:1: attempt to call a boolean value (metamethod '{s}')", .{case[0][2..]});
        try expectUncallable(&state, case[1], text);
        try field(&state, meta, case[0], .nil);
    }
}

test "operator_handler an inherited handler is found and primitive coercions stay refused" {
    var state = try State.init(a);
    defer state.deinit();
    const value = Value.from(.{ .table = try state.newTable() });
    try install(&state, "value", value);
    const provider = try state.newTable();
    try field(&state, provider, "__add", try script(&state, "return function() return 7 end"));
    const meta = try attach(&state, value, "__index", .nil);
    _ = try attach(&state, .from(.{ .table = meta }), "__index", .from(.{ .table = provider }));
    var diagnostic: ?vm.Diagnostic = null;
    // __add one table-valued __index link away is the handler (ADR 0012).
    _ = try run(&state, "return value+1", &diagnostic);
    try expect(state.get(-1).?.equal(.from(.{ .number = 7 })));
    try state.setTop(0);
    for ([_][]const u8{ "return '2'+3", "return true .. 'x'", "return -'2'" }) |source| {
        try std.testing.expectError(error.Type, run(&state, source, &diagnostic));
    }
    _ = try run(&state, "return 2+3,'a'..'b',-7,not value", &diagnostic);
    try expect(state.get(1).?.equal(.from(.{ .number = 5 })));
    try std.testing.expectEqualStrings("ab", state.get(2).?.unpack().string.bytes);
    try expect(state.get(3).?.equal(.from(.{ .number = -7 })));
    try expect(state.get(4).?.equal(.from(.{ .boolean = false })));
}

test "operator_handler userdata supplies arithmetic concat and unary handlers" {
    var state = try State.init(a);
    defer state.deinit();
    const value = Value.from(.{ .userdata = try state.newUserdata(0) });
    try install(&state, "left", value);
    try install(&state, "right", .from(.{ .number = 7 }));
    const meta = try attach(&state, value, "__unm", try script(&state, "global * return function(x,y) return x==left and y==left end"));
    const method = try script(&state, "global * return function(x,y) return x==left and y==7 end");
    for (operators) |op| try field(&state, meta, op.name, method);
    var diagnostic: ?vm.Diagnostic = null;
    for (operators) |op| {
        _ = try run(&state, op.source, &diagnostic);
        try expect(state.get(-1).?.equal(.from(.{ .boolean = true })));
        try state.setTop(0);
    }
    _ = try run(&state, "return -left", &diagnostic);
    try expect(state.get(-1).?.equal(.from(.{ .boolean = true })));
}

test "operator_handler returned closures and failure captures survive collection" {
    var state = try State.init(a);
    defer state.deinit();
    const value = Value.from(.{ .table = try state.newTable() });
    try install(&state, "value", value);
    _ = try attach(&state, value, "__add", try script(&state, "return function(x,y) local box={v=y} return function() return box.v end end"));
    state.setCollectionThreshold(0);
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(&state, "local f=value+7 local n=0 while n<200 do local garbage={} n=n+1 end return f()", &diagnostic);
    try expect(state.get(-1).?.equal(.from(.{ .number = 7 })));
    try state.setTop(0);
    _ = try attach(&state, value, "__add", try script(&state, "global * return function(x,y) local box={v=y} saved=function() return box.v end\nreturn 1+nil end"));
    try state.push(.from(.{ .number = 42 }));
    try std.testing.expectError(error.Type, run(&state, "return value+8", &diagnostic));
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

test "operator_handler recursive depth and hook interruption restore caller state" {
    for ([_]bool{ false, true }) |loop| {
        var state = try State.init(a);
        defer state.deinit();
        const value = Value.from(.{ .table = try state.newTable() });
        try install(&state, "value", value);
        _ = try attach(&state, value, "__add", try script(&state, if (loop) "return function() while true do end end" else "return function(x,y) return x+y end"));
        try state.push(.from(.{ .number = 42 }));
        var diagnostic: ?vm.Diagnostic = null;
        if (loop) {
            hook_calls = 0;
            state.setHook(interrupt, 1);
            try std.testing.expectError(error.Interrupted, run(&state, "return value+7", &diagnostic));
            try equal(@as(usize, 30), hook_calls);
            state.setHook(null, 0);
        } else try std.testing.expectError(error.CallDepth, run(&state, "return value+7", &diagnostic));
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
    const method = try compile(&state, allocator, "local x,y=... return {v=y}");
    const value = Value.from(.{ .table = try state.newTable() });
    _ = try attach(&state, value, "__add", .fromFunction(.{ .closure = method }));
    try install(&state, "value", value);
    const closure = try compile(&state, allocator, "return (value+7).v");
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

test "operator_handler every allocation failure releases partial execution" {
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

test "operator_handler stack relocation preserves unary and binary slots" {
    for ([_]usize{ 0, 1, 3, 4 }) |mode| {
        var moving = MovingAllocator{ .child = a };
        var state = try State.init(moving.allocator());
        defer state.deinit();
        const value = Value.from(.{ .table = try state.newTable() });
        const method = try script(&state, "return function() return 17 end");
        method.unpack().closure.prototype.registers = 10000;
        _ = try attach(&state, value, if (mode == 0) "__unm" else if (mode == 3) "__len" else if (mode == 4) "__eq" else "__add", method);
        const p = @import("Token.zig").Position{ .offset = 0, .line = 1, .column = 1 };
        const code = [_]bytecode.Written{
            .{ .position = p, .operation = .{ .constant = .{ .destination = 0, .index = 0 } } },
            .{ .position = p, .operation = .{ .constant = .{ .destination = 1, .index = 1 } } },
            .{ .position = p, .operation = .{ .constant = .{ .destination = 2, .index = 2 } } },
            .{ .position = p, .operation = if (mode == 0 or mode == 3) .{ .unary = .{ .operator = if (mode == 3) .length else .negate, .register = 0 } } else .{ .binary = .{ .operator = if (mode == 4) .equal else .add, .destination = 0, .left = 0, .right = 1 } } },
            .{ .position = p, .operation = .{ .returns = .{ .first = 0, .count = 3 } } },
        };
        const right: Value = if (mode == 4) .from(.{ .table = try state.newTable() }) else .from(.{ .number = 7 });
        const closure = try state.newChunk(try state.newProgram(&.{ value, right, .from(.{ .number = 42 }) }, &code, 3, "", "<operator-relocation>"));
        try state.push(.from(.{ .number = 99 }));
        try runtime.growStack(&state.stack, state.open_cells.items, state.allocator, 32);
        const before = @intFromPtr(state.stack.items.ptr);
        var diagnostic: ?vm.Diagnostic = null;
        _ = try vm.run(&state, closure, &diagnostic);
        try expect(before != @intFromPtr(state.stack.items.ptr));
        try expect(state.get(1).?.equal(.from(.{ .number = 99 })));
        try expect(state.get(2).?.equal(if (mode == 4) .from(.{ .boolean = true }) else .from(.{ .number = 17 })));
        try expect(state.get(3).?.equal(right));
        try expect(state.get(4).?.equal(.from(.{ .number = 42 })));
    }
}

test "operator_handler captured Lua cases agree on dispatch results and association" {
    var lines = std.mem.tokenizeScalar(u8, @embedFile("lua55-operator-handlers"), '\n');
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
        errdefer std.debug.print("operator-handler fixture failed: {s}, {s}, {s}\n", .{ name, side, source });
        var state = try State.init(a);
        defer state.deinit();
        const left = Value.from(.{ .table = try state.newTable() });
        const right = Value.from(.{ .table = try state.newTable() });
        try field(&state, left.unpack().table, "v", .from(.{ .number = 2 }));
        try field(&state, right.unpack().table, "v", .from(.{ .number = 3 }));
        try install(&state, "left", left);
        try install(&state, "right", right);
        try install(&state, "log", .from(.{ .number = 0 }));
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
            } else if (actual.is(.string)) {
                var bytes: [4096]u8 = undefined;
                const decoded = if (std.mem.eql(u8, payload, "-")) "" else try std.fmt.hexToBytes(&bytes, payload);
                try std.testing.expectEqualSlices(u8, decoded, actual.unpack().string.bytes);
            } else if (actual.is(.boolean)) try equal(std.mem.eql(u8, payload, "true"), actual.unpack().boolean) else try expect(actual.is(.nil));
        }
        try expect(values.next() == null);
        checked += 1;
    }
    try expect(checked > 0);
    std.debug.print("operator-handler fixture: {d} Lua cases checked through parser, compiler and VM\n", .{checked});
}
