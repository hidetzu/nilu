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
fn fallback(state: *State, target: Value) !*runtime.Table {
    const table = try state.newTable();
    const meta = try state.newTable();
    try field(state, meta, "__index", target);
    table.metatable = meta;
    return table;
}
fn chain(state: *State, count: usize, terminal: *runtime.Table) !*runtime.Table {
    var current = terminal;
    for (0..count) |_| current = try fallback(state, .from(.{ .table = current }));
    return current;
}
fn compile(state: *State, source: []const u8) !*runtime.Closure {
    var parsed: ?parser.Diagnostic = null;
    var ast = try parser.parseChunk(a, source, &parsed);
    defer ast.deinit();
    var diagnostic: ?compiler.Diagnostic = null;
    return state.newChunk(try compiler.compile(a, state, &ast, "<index-chain>", &diagnostic));
}
fn run(state: *State, source: []const u8, diagnostic: *?vm.Diagnostic) !usize {
    return vm.run(state, try compile(state, source), diagnostic);
}
fn install(state: *State, value: Value) !void {
    try field(state, state.globals, "t", value);
}

test "index_chain own false zero and existing values bypass fallback while misses traverse" {
    var state = try State.init(a);
    defer state.deinit();
    const base = try state.newTable();
    try field(&state, base, "x", .from(.{ .number = 7 }));
    try field(&state, base, "flag", .from(.{ .boolean = true }));
    try field(&state, base, "zero", .from(.{ .number = 99 }));
    const root = try chain(&state, 3, base);
    try field(&state, root, "flag", .from(.{ .boolean = false }));
    try field(&state, root, "zero", .from(.{ .number = 0 }));
    try install(&state, .from(.{ .table = root }));
    var diagnostic: ?vm.Diagnostic = null;
    try equal(@as(usize, 4), try run(&state, "return t.x,t.flag,t.zero,t.missing", &diagnostic));
    for ([_]Value{ .from(.{ .number = 7 }), .from(.{ .boolean = false }), .from(.{ .number = 0 }), .nil }, state.stack.items) |wanted, actual| try expect(actual.equal(wanted));
    try expect(root.getString("x").is(.nil)); // raw access still bypasses __index
    try state.setTop(0);
    try field(&state, root, "x", .from(.{ .number = 9 }));
    _ = try run(&state, "return t.x", &diagnostic);
    try expect(state.get(-1).?.equal(.from(.{ .number = 9 })));
    try field(&state, root, "x", .nil);
    _ = try run(&state, "return t.x", &diagnostic);
    try expect(state.get(-1).?.equal(.from(.{ .number = 7 })));
    state.barrier(&base.header);
    try base.set(a, .from(.{ .number = 0 }), .from(.{ .number = 11 }));
    state.barrier(&base.header);
    try base.set(a, .from(.{ .number = std.math.inf(f64) }), .from(.{ .number = 12 }));
    try state.setTop(0);
    _ = try run(&state, "return t[-0.0],t[1/0]", &diagnostic);
    try expect(state.get(1).?.equal(.from(.{ .number = 11 })));
    try expect(state.get(2).?.equal(.from(.{ .number = 12 })));
}

test "index_chain counts handlers and still permits a hit after the last handler" {
    for ([_]struct { count: usize, present: bool, refused: bool }{
        .{ .count = 1999, .present = false, .refused = false },
        .{ .count = 2000, .present = true, .refused = false },
        .{ .count = 2000, .present = false, .refused = true },
        .{ .count = 2001, .present = true, .refused = true },
    }) |case| {
        var state = try State.init(a);
        defer state.deinit();
        const terminal = try state.newTable();
        if (case.present) try field(&state, terminal, "x", .from(.{ .number = 7 }));
        try install(&state, .from(.{ .table = try chain(&state, case.count, terminal) }));
        try state.push(.from(.{ .number = 42 }));
        var diagnostic: ?vm.Diagnostic = null;
        if (case.refused) {
            try std.testing.expectError(error.Runtime, run(&state, "\nreturn t.x", &diagnostic));
            try equal(.index_chain_too_long, diagnostic.?.kind);
            try equal(@as(usize, 2), diagnostic.?.position.line);
            try equal(@as(usize, 1), state.top());
        } else {
            try equal(@as(usize, 1), try run(&state, "return t.x", &diagnostic));
            if (case.present) try expect(state.get(-1).?.equal(.from(.{ .number = 7 }))) else try expect(state.get(-1).?.is(.nil));
        }
        try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
        try equal(@as(usize, 0), state.frames.items.len);
    }
}

test "index_chain cycles refuse without host recursion and a present key still wins" {
    var state = try State.init(a);
    defer state.deinit();
    const table = try state.newTable();
    const meta = try state.newTable();
    try field(&state, meta, "__index", .from(.{ .table = table }));
    table.metatable = meta;
    try field(&state, table, "own", .from(.{ .number = 8 }));
    try install(&state, .from(.{ .table = table }));
    var diagnostic: ?vm.Diagnostic = null;
    try std.testing.expectError(error.Runtime, run(&state, "return t.absent", &diagnostic));
    try equal(.index_chain_too_long, diagnostic.?.kind);
    _ = try run(&state, "return t.own", &diagnostic);
    try expect(state.get(-1).?.equal(.from(.{ .number = 8 })));
}

fn native(_: *State) callconv(.c) c_int {
    return 0;
}

test "index_chain empty native results are nil and unholdable keys read nil" {
    var state = try State.init(a);
    defer state.deinit();
    const table = try fallback(&state, .fromFunction(.{ .native = native }));
    try install(&state, .from(.{ .table = table }));
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(&state, "return t.x", &diagnostic);
    try expect(state.get(-1).?.is(.nil));
    try state.setTop(0);
    const leaf = try state.newTable();
    try field(&state, leaf, "x", .from(.{ .number = 7 }));
    try install(&state, .from(.{ .table = try fallback(&state, .from(.{ .table = leaf })) }));
    for ([_][]const u8{ "return t[nil]", "return t[false]", "return t[0/0]", "return t[{}]" }) |source| {
        try equal(@as(usize, 1), try run(&state, source, &diagnostic));
        try expect(state.get(-1).?.is(.nil));
        try state.setTop(0);
    }
    try install(&state, .from(.{ .table = try state.newTable() }));
    _ = try run(&state, "return t[nil],t[false],t[0/0]", &diagnostic);
    for (state.stack.items) |value| try expect(value.is(.nil));
}

test "index_chain the handler is found along the metatable's links and non-table targets retain type failures" {
    var state = try State.init(a);
    defer state.deinit();
    const inherited = try state.newTable();
    try field(&state, inherited, "x", .from(.{ .number = 99 }));
    const provider = try state.newTable();
    try field(&state, provider, "__index", .from(.{ .table = inherited }));
    const meta = try fallback(&state, .from(.{ .table = provider }));
    const root = try state.newTable();
    root.metatable = meta;
    // meta inherits its __index entry through its own metatable's table
    // __index, and root consults it (ADR 0012).
    try install(&state, .from(.{ .table = root }));
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(&state, "return t.x", &diagnostic);
    try expect(state.get(-1).?.equal(.from(.{ .number = 99 })));
    try state.setTop(0);
    try install(&state, .from(.{ .table = try fallback(&state, .from(.{ .boolean = false })) }));
    try std.testing.expectError(error.Type, run(&state, "return t.x", &diagnostic));
    try equal(.boolean, diagnostic.?.operand_type.?);
}

test "index_chain userdata and inherited method values preserve the original receiver" {
    var state = try State.init(a);
    defer state.deinit();
    const base = try state.newTable();
    try field(&state, base, "x", .from(.{ .number = 7 }));
    const userdata = try state.newUserdata(0);
    const meta = try state.newTable();
    try field(&state, meta, "__index", .from(.{ .table = base }));
    try state.setMetatable(.from(.{ .userdata = userdata }), meta);
    try install(&state, .from(.{ .userdata = userdata }));
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(&state, "return t.x", &diagnostic);
    try expect(state.get(-1).?.equal(.from(.{ .number = 7 })));
    try state.setTop(0);
    const method = try compile(&state, "local self,x=... return self.own+x");
    try field(&state, base, "m", .fromFunction(.{ .closure = method }));
    const table = try fallback(&state, .from(.{ .table = base }));
    try field(&state, table, "own", .from(.{ .number = 9 }));
    try install(&state, .from(.{ .table = table }));
    _ = try run(&state, "return t:m(3)", &diagnostic);
    try expect(state.get(-1).?.equal(.from(.{ .number = 12 })));
}

test "index_chain graph survives VM collection through metatable edges" {
    var state = try State.init(a);
    defer state.deinit();
    const child = try state.newTable();
    try field(&state, child, "v", .from(.{ .number = 9 }));
    const terminal = try state.newTable();
    try field(&state, terminal, "x", .from(.{ .table = child }));
    try install(&state, .from(.{ .table = try chain(&state, 8, terminal) }));
    state.setCollectionThreshold(0);
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(&state, "local n=0 while n<200 do local garbage={} n=n+1 end return t.x.v", &diagnostic);
    try expect(state.get(-1).?.equal(.from(.{ .number = 9 })));
    const before = state.object_count;
    try field(&state, state.globals, "t", .nil);
    state.collect();
    try expect(state.object_count < before);
}

test "index_chain traversal allocates nothing after frame preparation" {
    const bytecode = @import("bytecode.zig");
    var state = try State.init(a);
    defer state.deinit();
    const leaf = try state.newTable();
    try field(&state, leaf, "x", .from(.{ .number = 7 }));
    const root = try chain(&state, 20, leaf);
    const key = try state.newString("x");
    const position = @import("Token.zig").Position{ .offset = 0, .line = 1, .column = 1 };
    const code = [_]bytecode.Written{
        .{ .position = position, .operation = .{ .constant = .{ .destination = 0, .index = 0 } } },
        .{ .position = position, .operation = .{ .constant = .{ .destination = 1, .index = 1 } } },
        .{ .position = position, .operation = .{ .get = .{ .destination = 0, .table = 0, .key = 1 } } },
        .{ .position = position, .operation = .{ .returns = .{ .first = 0, .count = 1 } } },
    };
    const closure = try state.newChunk(try state.newProgram(&.{ .from(.{ .table = root }), .from(.{ .string = key }) }, &code, 2, "", "<noalloc-chain>"));
    try runtime.growStack(&state.stack, state.open_cells.items, state.allocator, 2);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    const original = state.allocator;
    defer state.allocator = original;
    state.allocator = failing.allocator();
    var diagnostic: ?vm.Diagnostic = null;
    try equal(@as(usize, 1), try vm.run(&state, closure, &diagnostic));
    try expect(state.get(-1).?.equal(.from(.{ .number = 7 })));
    try equal(@as(usize, 0), failing.alloc_index);
}

fn allocationCase(allocator: std.mem.Allocator, ast: *const @import("Ast.zig")) !void {
    var state = try State.init(allocator);
    defer state.deinit();
    const leaf = try state.newTable();
    try field(&state, leaf, "x", .from(.{ .number = 7 }));
    try install(&state, .from(.{ .table = try chain(&state, 4, leaf) }));
    var compilation: ?compiler.Diagnostic = null;
    const closure = try state.newChunk(try compiler.compile(allocator, &state, ast, "<chain-allocation>", &compilation));
    try state.push(.from(.{ .number = 42 }));
    var diagnostic: ?vm.Diagnostic = null;
    const count = vm.run(&state, closure, &diagnostic) catch |err| {
        try equal(@as(usize, 1), state.top());
        try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
        try equal(@as(usize, 0), state.frames.items.len);
        return err;
    };
    try equal(@as(usize, 1), count);
    try expect(state.get(2).?.equal(.from(.{ .number = 7 })));
}

test "index_chain setup and execution release every allocation failure" {
    var parsed: ?parser.Diagnostic = null;
    var ast = try parser.parseChunk(a, "return t.x", &parsed);
    defer ast.deinit();
    try allocation_failures.checkAll(a, allocationCase, .{&ast});
}

var hook_calls: usize = 0;
fn observer(_: *State) callconv(.c) c_int {
    hook_calls += 1;
    return 0;
}

test "index_chain handler steps stay within a single VM instruction" {
    var expected: ?usize = null;
    for ([_]usize{ 1, 2000 }) |length| {
        var state = try State.init(a);
        defer state.deinit();
        const leaf = try state.newTable();
        try field(&state, leaf, "x", .from(.{ .number = 7 }));
        try install(&state, .from(.{ .table = try chain(&state, length, leaf) }));
        hook_calls = 0;
        state.setHook(observer, 1);
        var diagnostic: ?vm.Diagnostic = null;
        _ = try run(&state, "return t.x", &diagnostic);
        if (expected) |count| try equal(count, hook_calls) else expected = hook_calls;
    }
    try expect(expected.? > 0);
}

test "index_chain captured Lua handler boundaries agree through source execution" {
    var lines = std.mem.tokenizeScalar(u8, @embedFile("lua55-index-chains"), '\n');
    var checked: usize = 0;
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const length = try std.fmt.parseInt(usize, fields.next().?, 10);
        const present = std.mem.eql(u8, fields.next().?, "true");
        const kind = fields.next().?;
        const payload = fields.next().?;
        try expect(fields.next() == null);
        var state = try State.init(a);
        defer state.deinit();
        const terminal = try state.newTable();
        if (present) try field(&state, terminal, "x", .from(.{ .number = 7 }));
        try install(&state, .from(.{ .table = try chain(&state, length, terminal) }));
        var diagnostic: ?vm.Diagnostic = null;
        if (std.mem.eql(u8, kind, "runtime")) {
            try std.testing.expectError(error.Runtime, run(&state, "return t.x", &diagnostic));
            try equal(.index_chain_too_long, diagnostic.?.kind);
        } else {
            try equal(@as(usize, 1), try run(&state, "return t.x", &diagnostic));
            const actual = state.get(-1).?;
            try std.testing.expectEqualStrings(kind, actual.typeName());
            if (actual.numberValue() != null) try equal(try std.fmt.parseInt(u64, payload, 16), @as(u64, @bitCast(actual.numberValue().?)));
        }
        checked += 1;
    }
    try expect(checked > 0);
    std.debug.print("index-chain fixture: {d} Lua handler boundaries checked through parser, compiler and VM\n", .{checked});
}

test "index_chain lexical global reads and initializer guards honor fallback" {
    var state = try State.init(a);
    defer state.deinit();
    const base = try state.newTable();
    try field(&state, base, "x", .from(.{ .number = 7 }));
    const meta = try state.newTable();
    try field(&state, meta, "__index", .from(.{ .table = base }));
    state.globals.metatable = meta;
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(&state, "return x", &diagnostic);
    try expect(state.get(-1).?.equal(.from(.{ .number = 7 })));
    try state.setTop(0);
    _ = try run(&state, "x=9 return x", &diagnostic);
    try expect(state.get(-1).?.equal(.from(.{ .number = 9 })));
    try expect(base.getString("x").equal(.from(.{ .number = 7 })));
    try state.setTop(0);
    try field(&state, state.globals, "x", .nil);
    try std.testing.expectError(error.Runtime, run(&state, "global x=11", &diagnostic));
    try equal(.global_already_defined, diagnostic.?.kind);
    try expect(state.globals.getString("x").is(.nil));
}
