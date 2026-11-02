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
fn field(state: *State, table: *runtime.Table, name: []const u8, value: Value) !void {
    state.barrier(&table.header);
    try table.set(state.allocator, .from(.{ .string = try state.newString(name) }), value);
}
fn compile(state: *State, allocator: std.mem.Allocator, source: []const u8) !*runtime.Closure {
    var parsed: ?parser.Diagnostic = null;
    var ast = try parser.parseChunk(allocator, source, &parsed);
    defer ast.deinit();
    var diagnostic: ?compiler.Diagnostic = null;
    return state.newChunk(try compiler.compile(allocator, state, &ast, "<index-handler>", &diagnostic));
}
fn run(state: *State, source: []const u8, diagnostic: *?vm.Diagnostic) !usize {
    return vm.run(state, try compile(state, a, source), diagnostic);
}
fn attach(state: *State, receiver: Value, name: []const u8, method: Value) !void {
    const meta = try state.newTable();
    try field(state, meta, name, method);
    try state.setMetatable(receiver, meta);
}
fn script(state: *State, source: []const u8) !Value {
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(state, source, &diagnostic);
    const method = state.get(-1).?;
    try state.setTop(-2);
    return method;
}
fn setup(state: *State, name: []const u8, method: Value) !*runtime.Table {
    const root = try state.newTable();
    try field(state, root, "own", .from(.{ .number = 9 }));
    try attach(state, .from(.{ .table = root }), name, method);
    try field(state, state.globals, "t", .from(.{ .table = root }));
    return root;
}

test "index_handler reads use one result including nil and false" {
    for ([_]struct { source: []const u8, expected: Value }{
        .{ .source = "return function(t,k) return t.own,77 end", .expected = .from(.{ .number = 9 }) },
        .{ .source = "return function(t,k) return end", .expected = .nil },
        .{ .source = "return function(t,k) return nil,77 end", .expected = .nil },
        .{ .source = "return function(t,k) return false,77 end", .expected = .from(.{ .boolean = false }) },
    }) |case| {
        var state = try State.init(a);
        defer state.deinit();
        _ = try setup(&state, "__index", try script(&state, case.source));
        try state.push(.from(.{ .number = 42 }));
        var diagnostic: ?vm.Diagnostic = null;
        try equal(@as(usize, 2), try run(&state, "return t.x,8", &diagnostic));
        try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
        try expect(state.get(2).?.equal(case.expected));
        try expect(state.get(3).?.equal(.from(.{ .number = 8 })));
        try equal(@as(usize, 0), state.frames.items.len);
    }
}

test "index_handler chains pass the current receiver and preserve method self" {
    var state = try State.init(a);
    defer state.deinit();
    const leaf = try setup(&state, "__index", try script(&state, "return function(t,k) return function(self,x) return t.own,self.own,x end end"));
    try field(&state, leaf, "own", .from(.{ .number = 11 }));
    const root = try state.newTable();
    try field(&state, root, "own", .from(.{ .number = 9 }));
    try attach(&state, .from(.{ .table = root }), "__index", .from(.{ .table = leaf }));
    try field(&state, state.globals, "t", .from(.{ .table = root }));
    state.setCollectionThreshold(0);
    var diagnostic: ?vm.Diagnostic = null;
    try equal(@as(usize, 3), try run(&state, "return t:m(7)", &diagnostic));
    for ([_]f64{ 11, 9, 7 }, state.stack.items) |wanted, actual| try expect(actual.equal(.from(.{ .number = wanted })));
}

test "index_handler writes pass all arguments ignore returns and preserve own fields" {
    var state = try State.init(a);
    defer state.deinit();
    const method = try script(&state, "global * return function(t,k,v) receiver=t key=k seen=v return 99,88 end");
    const leaf = try setup(&state, "__newindex", method);
    const root = try state.newTable();
    try field(&state, root, "own", .from(.{ .boolean = false }));
    try attach(&state, .from(.{ .table = root }), "__newindex", .from(.{ .table = leaf }));
    try field(&state, state.globals, "t", .from(.{ .table = root }));
    try state.push(.from(.{ .number = 42 }));
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(&state, "local _ENV=t own=1 x=7", &diagnostic);
    try expect(state.globals.getString("receiver").equal(.from(.{ .table = leaf })));
    try std.testing.expectEqualStrings("x", state.globals.getString("key").unpack().string.bytes);
    try expect(state.globals.getString("seen").equal(.from(.{ .number = 7 })));
    try expect(root.getString("own").equal(.from(.{ .number = 1 })));
    try expect(root.getString("x").is(.nil));
    try expect(leaf.getString("x").is(.nil));
    try equal(@as(usize, 1), state.top());
    _ = try run(&state, "local _ENV=t x=nil", &diagnostic);
    try expect(state.globals.getString("seen").is(.nil));
    try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
}

test "index_handler userdata receives itself and key or value" {
    var state = try State.init(a);
    defer state.deinit();
    const userdata = try state.newUserdata(0);
    try field(&state, state.globals, "u", .from(.{ .userdata = userdata }));
    const getter = try script(&state, "global * return function(t,k) return t==u and k=='x' end");
    const setter = try script(&state, "global * return function(t,k,v) seen=t==u and k=='x' and v==7 end");
    const meta = try state.newTable();
    try field(&state, meta, "__index", getter);
    try field(&state, meta, "__newindex", setter);
    try state.setMetatable(.from(.{ .userdata = userdata }), meta);
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(&state, "do local _ENV=u x=7 end return u.x,seen", &diagnostic);
    try expect(state.get(1).?.equal(.from(.{ .boolean = true })));
    try expect(state.get(2).?.equal(.from(.{ .boolean = true })));
}

test "index_handler returned closures and failure captures survive collections" {
    var state = try State.init(a);
    defer state.deinit();
    const root = try setup(&state, "__index", try script(&state, "return function(t,k) local x={v=7} return function() return x.v end end"));
    state.setCollectionThreshold(0);
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(&state, "local f=t.x local n=0 while n<200 do local garbage={} n=n+1 end return f()", &diagnostic);
    try expect(state.get(-1).?.equal(.from(.{ .number = 7 })));
    try state.setTop(0);
    const failing = try script(&state, "global * return function(t,k) local x={v=8} saved=function() return x.v end\nreturn 1+nil end");
    try attach(&state, .from(.{ .table = root }), "__index", failing);
    try state.push(.from(.{ .number = 42 }));
    try std.testing.expectError(error.Type, run(&state, "return t.x", &diagnostic));
    try equal(@as(usize, 2), diagnostic.?.position.line);
    try equal(.binary, diagnostic.?.operation);
    try equal(@as(usize, 1), state.top());
    try equal(@as(usize, 0), state.frames.items.len);
    state.collect();
    _ = try run(&state, "return saved()", &diagnostic);
    try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
    try expect(state.get(2).?.equal(.from(.{ .number = 8 })));
}

test "index_handler recursion uses the ordinary call depth limit and unwinds" {
    for ([_][]const u8{ "__index", "__newindex" }) |name| {
        var state = try State.init(a);
        defer state.deinit();
        const source = if (std.mem.eql(u8, name, "__index")) "return function(t,k) return t.x end" else "return function(t,k,v) local _ENV=t x=v end";
        _ = try setup(&state, name, try script(&state, source));
        try state.push(.from(.{ .number = 42 }));
        var diagnostic: ?vm.Diagnostic = null;
        const use = if (std.mem.eql(u8, name, "__index")) "return t.x" else "local _ENV=t x=7";
        try std.testing.expectError(error.CallDepth, run(&state, use, &diagnostic));
        try equal(.call_depth, diagnostic.?.kind);
        try equal(@as(usize, 1), state.top());
        try equal(@as(usize, 0), state.frames.items.len);
        _ = try run(&state, "return 9", &diagnostic);
        try expect(state.get(-1).?.equal(.from(.{ .number = 9 })));
    }
}

var hook_calls: usize = 0;
fn interrupt(_: *State) callconv(.c) c_int {
    hook_calls += 1;
    return if (hook_calls >= 30) 1 else 0;
}

test "index_handler hook interruption stops a running handler and restores caller" {
    var state = try State.init(a);
    defer state.deinit();
    _ = try setup(&state, "__index", try script(&state, "return function(t,k) while true do end end"));
    try state.push(.from(.{ .number = 42 }));
    hook_calls = 0;
    state.setHook(interrupt, 1);
    var diagnostic: ?vm.Diagnostic = null;
    try std.testing.expectError(error.Interrupted, run(&state, "return t.x", &diagnostic));
    try equal(@as(usize, 30), hook_calls);
    try equal(@as(usize, 1), state.top());
    try equal(@as(usize, 0), state.frames.items.len);
    try expect(state.failure.?.value.is(.nil));
    state.setHook(null, 0);
    _ = try run(&state, "return 7", &diagnostic);
    try expect(state.get(-1).?.equal(.from(.{ .number = 7 })));
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var state = try State.init(allocator);
    defer state.deinit();
    const getter = try compile(&state, allocator, "local t,k=... local x={v=7} return x");
    const setter = try compile(&state, allocator, "global * local t,k,v=... seen=v return 99");
    const root = try setup(&state, "__index", .fromFunction(.{ .closure = getter }));
    try field(&state, root.metatable.?, "__newindex", .fromFunction(.{ .closure = setter }));
    const closure = try compile(&state, allocator, "local v=t.x do local _ENV=t x=v end return seen.v");
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

test "index_handler every allocation failure restores caller and releases partial calls" {
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

test "index_handler stack relocation preserves read destinations and initializer operands" {
    for ([_]bool{ false, true }) |initializer| {
        var moving = MovingAllocator{ .child = a };
        var state = try State.init(moving.allocator());
        defer state.deinit();
        const method = try script(&state, if (initializer) "return function() return nil end" else "return function() return 7 end");
        method.unpack().closure.prototype.registers = 10000;
        _ = try setup(&state, "__index", method);
        const closure = try compile(&state, a, if (initializer) "local _ENV=t global x=7 return x,19" else "return t.x,19");
        try runtime.growStack(&state.stack, state.open_cells.items, state.allocator, closure.prototype.registers + 16);
        const before = @intFromPtr(state.stack.items.ptr);
        var diagnostic: ?vm.Diagnostic = null;
        _ = try vm.run(&state, closure, &diagnostic);
        try expect(before != @intFromPtr(state.stack.items.ptr));
        try expect(state.get(1).?.equal(.from(.{ .number = 7 })));
        try expect(state.get(2).?.equal(.from(.{ .number = 19 })));
    }
}

test "index_handler list stores reacquire values after a handler relocates the stack" {
    var moving = MovingAllocator{ .child = a };
    var state = try State.init(moving.allocator());
    defer state.deinit();
    const method = try script(&state, "global * return function(t,k,v) seen=seen*10+v keys=keys*10+k end");
    method.unpack().closure.prototype.registers = 10000;
    const root = try setup(&state, "__newindex", method);
    try field(&state, state.globals, "seen", .from(.{ .number = 0 }));
    try field(&state, state.globals, "keys", .from(.{ .number = 0 }));
    const producer = try script(&state, "return function() return 4,5,6 end");
    const p = @import("Token.zig").Position{ .offset = 0, .line = 1, .column = 1 };
    const code = [_]bytecode.Written{
        .{ .position = p, .operation = .{ .constant = .{ .destination = 0, .index = 0 } } },
        .{ .position = p, .operation = .{ .constant = .{ .destination = 1, .index = 1 } } },
        .{ .position = p, .operation = .{ .call = .{ .base = 1, .arguments = 0, .results = null } } },
        .{ .position = p, .operation = .{ .set_list = .{ .table = 0, .first = 1, .index = 1 } } },
        .{ .position = p, .operation = .{ .returns = .{ .first = 0, .count = 0 } } },
    };
    const closure = try state.newChunk(try state.newProgram(&.{ .from(.{ .table = root }), producer }, &code, 2, "", "<handler-list>"));
    try runtime.growStack(&state.stack, state.open_cells.items, state.allocator, 32);
    const before = @intFromPtr(state.stack.items.ptr);
    var diagnostic: ?vm.Diagnostic = null;
    _ = try vm.run(&state, closure, &diagnostic);
    try expect(before != @intFromPtr(state.stack.items.ptr));
    try expect(state.globals.getString("seen").equal(.from(.{ .number = 456 })));
    try expect(state.globals.getString("keys").equal(.from(.{ .number = 123 })));
    try equal(@as(usize, 0), state.top());
}

test "index_handler active closure stays rooted after its metatable drops it" {
    var state = try State.init(a);
    defer state.deinit();
    const method = try script(&state, "global * return function(t,k) do local _ENV=meta __index=nil end local n=0 while n<200 do local garbage={} n=n+1 end return t.own end");
    const root = try setup(&state, "__index", method);
    try field(&state, state.globals, "meta", .from(.{ .table = root.metatable.? }));
    state.setCollectionThreshold(0);
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(&state, "return t.x,t.x", &diagnostic);
    try expect(state.get(1).?.equal(.from(.{ .number = 9 })));
    try expect(state.get(2).?.is(.nil));
}

test "index_handler stack exhaustion while preparing arguments preserves caller" {
    var state = try State.init(a);
    defer state.deinit();
    const root = try setup(&state, "__index", try script(&state, "return function() return 7 end"));
    const key = try state.newString("x");
    const p = @import("Token.zig").Position{ .offset = 0, .line = 1, .column = 1 };
    const code = [_]bytecode.Written{
        .{ .position = p, .operation = .{ .constant = .{ .destination = 0, .index = 0 } } },
        .{ .position = p, .operation = .{ .constant = .{ .destination = 1, .index = 1 } } },
        .{ .position = p, .operation = .{ .get = .{ .destination = 0, .table = 0, .key = 1 } } },
        .{ .position = p, .operation = .{ .returns = .{ .first = 0, .count = 1 } } },
    };
    const closure = try state.newChunk(try state.newProgram(&.{ .from(.{ .table = root }), .from(.{ .string = key }) }, &code, State.max_stack - 1, "", "<handler-stack-limit>"));
    try state.push(.from(.{ .number = 42 }));
    var diagnostic: ?vm.Diagnostic = null;
    try std.testing.expectError(error.StackLimit, vm.run(&state, closure, &diagnostic));
    try equal(@as(usize, 1), state.top());
    try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
    try equal(@as(usize, 0), state.frames.items.len);
}

test "index_handler captured Lua calls agree on receivers arguments and result adjustment" {
    var lines = std.mem.tokenizeScalar(u8, @embedFile("lua55-index-handlers"), '\n');
    var checked: usize = 0;
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const name = fields.next().?;
        const links = try std.fmt.parseInt(usize, fields.next().?, 10);
        var handler_buffer: [4096]u8 = undefined;
        const handler_source = try std.fmt.hexToBytes(&handler_buffer, fields.next().?);
        var source_buffer: [4096]u8 = undefined;
        const source = try std.fmt.hexToBytes(&source_buffer, fields.next().?);
        const count = try std.fmt.parseInt(usize, fields.next().?, 10);
        const expected = fields.next().?;
        try expect(fields.next() == null);
        errdefer std.debug.print("index-handler fixture failed: {s}; {s}\n", .{ handler_source, source });
        var state = try State.init(a);
        defer state.deinit();
        var root = try setup(&state, name, try script(&state, handler_source));
        if (links > 0) try field(&state, root, "own", .from(.{ .number = 11 }));
        for (0..links) |_| {
            const outer = try state.newTable();
            try field(&state, outer, "own", .from(.{ .number = 9 }));
            try attach(&state, .from(.{ .table = outer }), name, .from(.{ .table = root }));
            root = outer;
        }
        try field(&state, state.globals, "t", .from(.{ .table = root }));
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
    std.debug.print("index-handler fixture: {d} Lua cases checked through parser, compiler and VM\n", .{checked});
}

test "index_handler function dispatch respects the final allowed handler fetch" {
    for ([_][]const u8{ "__index", "__newindex" }) |name| {
        for ([_]usize{ 1999, 2000 }) |links| {
            var state = try State.init(a);
            defer state.deinit();
            const getter = std.mem.eql(u8, name, "__index");
            const method = try script(&state, "global * return function(t,k,v) called=1 return 7 end");
            var root = try setup(&state, name, method);
            for (0..links) |_| {
                const outer = try state.newTable();
                try attach(&state, .from(.{ .table = outer }), name, .from(.{ .table = root }));
                root = outer;
            }
            try field(&state, state.globals, "t", .from(.{ .table = root }));
            try field(&state, state.globals, "called", .from(.{ .number = 0 }));
            var diagnostic: ?vm.Diagnostic = null;
            const source = if (getter) "return t.x" else "local _ENV=t x=7";
            if (links == 2000) {
                try std.testing.expectError(error.Runtime, run(&state, source, &diagnostic));
                try equal(@as(@FieldType(vm.Diagnostic, "kind"), if (getter) .index_chain_too_long else .newindex_chain_too_long), diagnostic.?.kind);
                try expect(state.globals.getString("called").equal(.from(.{ .number = 0 })));
            } else {
                _ = try run(&state, source, &diagnostic);
                try expect(state.globals.getString("called").equal(.from(.{ .number = 1 })));
            }
        }
    }
}

test "index_handler keys a table cannot hold never enter script handlers" {
    var state = try State.init(a);
    defer state.deinit();
    const method = try script(&state, "global * return function(t,k,v) called=1 return 7 end");
    const root = try setup(&state, "__index", method);
    try field(&state, root.metatable.?, "__newindex", method);
    const chained = try state.newTable();
    try attach(&state, .from(.{ .table = chained }), "__index", .from(.{ .table = root }));
    try field(&state, state.globals, "c", .from(.{ .table = chained }));
    try field(&state, state.globals, "u", .from(.{ .userdata = try state.newUserdata(0) }));
    var diagnostic: ?vm.Diagnostic = null;
    // The owner's answer: a key a table cannot hold (nil or NaN) reads nil and never enters __index, directly or
    // through a table-valued fallback.
    for ([_][]const u8{ "return t[nil]", "return t[0/0]", "return c[nil]", "return c[0/0]" }) |source| {
        try equal(@as(usize, 1), try run(&state, source, &diagnostic));
        try expect(state.get(-1).?.is(.nil));
        try state.setTop(0);
    }
    try expect(state.globals.getString("called").is(.nil));
    // The same holds for a userdata receiver with __index, whether that
    // __index is a function, a table or another userdata. Without __index the
    // read stays a Type failure.
    try std.testing.expectError(error.Type, run(&state, "return u[nil]", &diagnostic));
    const u = state.globals.getString("u");
    try attach(&state, u, "__index", method);
    const via_table = Value.from(.{ .userdata = try state.newUserdata(0) });
    try attach(&state, via_table, "__index", .from(.{ .table = root }));
    try field(&state, state.globals, "w", via_table);
    const via_userdata = Value.from(.{ .userdata = try state.newUserdata(0) });
    try attach(&state, via_userdata, "__index", u);
    try field(&state, state.globals, "v", via_userdata);
    for ([_][]const u8{ "return u[nil]", "return u[0/0]", "return w[nil]", "return w[0/0]", "return v[nil]" }) |source| {
        try equal(@as(usize, 1), try run(&state, source, &diagnostic));
        try expect(state.get(-1).?.is(.nil));
        try state.setTop(0);
    }
    try expect(state.globals.getString("called").is(.nil));
    _ = try run(&state, "return u.x, v.x", &diagnostic);
    try expect(state.get(-1).?.equal(.from(.{ .number = 7 })));
    try expect(state.globals.getString("called").equal(.from(.{ .number = 1 })));
    try field(&state, state.globals, "called", .nil);
    try state.setTop(0);
    const p = @import("Token.zig").Position{ .offset = 0, .line = 1, .column = 1 };
    const code = [_]bytecode.Written{
        .{ .position = p, .operation = .{ .constant = .{ .destination = 0, .index = 0 } } },
        .{ .position = p, .operation = .{ .constant = .{ .destination = 1, .index = 1 } } },
        .{ .position = p, .operation = .{ .set = .{ .table = 0, .key = 1, .value = 1 } } },
        .{ .position = p, .operation = .{ .returns = .{ .first = 0, .count = 0 } } },
    };
    const closure = try state.newChunk(try state.newProgram(&.{ .from(.{ .table = root }), .nil }, &code, 2, "", "<invalid-handler-key>"));
    try std.testing.expectError(error.Type, vm.run(&state, closure, &diagnostic));
    try expect(state.globals.getString("called").is(.nil));
    try equal(@as(usize, 0), state.top());
}
