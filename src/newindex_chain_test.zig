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
fn fallback(state: *State, target: Value) !*runtime.Table {
    const table = try state.newTable();
    const meta = try state.newTable();
    try field(state, meta, "__newindex", target);
    table.metatable = meta;
    return table;
}
fn chain(state: *State, count: usize, terminal: *runtime.Table) !*runtime.Table {
    var current = terminal;
    for (0..count) |_| current = try fallback(state, .from(.{ .table = current }));
    return current;
}
fn compile(state: *State, allocator: std.mem.Allocator, source: []const u8) !*runtime.Closure {
    var parsed: ?parser.Diagnostic = null;
    var ast = try parser.parseChunk(allocator, source, &parsed);
    defer ast.deinit();
    var diagnostic: ?compiler.Diagnostic = null;
    return state.newChunk(try compiler.compile(allocator, state, &ast, "<newindex-chain>", &diagnostic));
}
fn run(state: *State, source: []const u8, diagnostic: *?vm.Diagnostic) !usize {
    return vm.run(state, try compile(state, a, source), diagnostic);
}
fn install(state: *State, value: Value) !void {
    try field(state, state.globals, "t", value);
}

// Handwritten bytecode isolates VM stores; assignment_test additionally covers
// compiled indexed stores and their evaluation/commit schedule.
fn storeProgram(state: *State, receiver: Value, key: Value, value: Value) !*runtime.Closure {
    const position = @import("Token.zig").Position{ .offset = 0, .line = 1, .column = 1 };
    const code = [_]bytecode.Written{
        .{ .position = position, .operation = .{ .constant = .{ .destination = 0, .index = 0 } } },
        .{ .position = position, .operation = .{ .constant = .{ .destination = 1, .index = 1 } } },
        .{ .position = position, .operation = .{ .constant = .{ .destination = 2, .index = 2 } } },
        .{ .position = position, .operation = .{ .set = .{ .table = 0, .key = 1, .value = 2 } } },
        .{ .position = position, .operation = .{ .returns = .{ .first = 0, .count = 0 } } },
    };
    return state.newChunk(try state.newProgram(&.{ receiver, key, value }, &code, 3, "", "<newindex-store>"));
}
fn write(state: *State, receiver: Value, key: Value, value: Value, diagnostic: *?vm.Diagnostic) !void {
    _ = try vm.run(state, try storeProgram(state, receiver, key, value), diagnostic);
}

test "newindex_chain own false zero updates and deletion bypass handlers" {
    var state = try State.init(a);
    defer state.deinit();
    const leaf = try state.newTable();
    const root = try chain(&state, 3, leaf);
    try field(&state, root, "flag", .from(.{ .boolean = false }));
    try field(&state, root, "zero", .from(.{ .number = 0 }));
    try field(&state, root, "gone", .from(.{ .number = 8 }));
    try install(&state, .from(.{ .table = root }));
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(&state, "local _ENV=t flag=1 zero=2 gone=nil x=7", &diagnostic);
    try expect(root.getString("flag").equal(.from(.{ .number = 1 })));
    try expect(root.getString("zero").equal(.from(.{ .number = 2 })));
    try expect(root.getString("gone").is(.nil));
    try expect(root.getString("x").is(.nil));
    try expect(leaf.getString("flag").is(.nil));
    try expect(leaf.getString("zero").is(.nil));
    try expect(leaf.getString("x").equal(.from(.{ .number = 7 })));
    _ = try run(&state, "local _ENV=t gone=9 x=nil", &diagnostic);
    try expect(leaf.getString("gone").equal(.from(.{ .number = 9 })));
    try expect(leaf.getString("x").is(.nil));
    // Host raw access ignores __newindex.
    try field(&state, root, "raw", .from(.{ .number = 3 }));
    try expect(leaf.getString("raw").is(.nil));
}

test "newindex_chain stops at intermediate existing keys and finds an inherited handler name" {
    var state = try State.init(a);
    defer state.deinit();
    const leaf = try state.newTable();
    const middle = try fallback(&state, .from(.{ .table = leaf }));
    try field(&state, middle, "x", .from(.{ .boolean = false }));
    const root = try fallback(&state, .from(.{ .table = middle }));
    try install(&state, .from(.{ .table = root }));
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(&state, "local _ENV=t x=7", &diagnostic);
    try expect(middle.getString("x").equal(.from(.{ .number = 7 })));
    try expect(leaf.getString("x").is(.nil));
    // A metatable inheriting a handler through its own metatable's
    // table-valued __index supplies that handler (ADR 0012).
    const provider = try state.newTable();
    try field(&state, provider, "__newindex", .from(.{ .table = leaf }));
    const meta = try state.newTable();
    const meta_meta = try state.newTable();
    try field(&state, meta_meta, "__index", .from(.{ .table = provider }));
    meta.metatable = meta_meta;
    root.metatable = meta;
    _ = try run(&state, "local _ENV=t y=8", &diagnostic);
    try expect(root.getString("y").is(.nil));
    try expect(leaf.getString("y").equal(.from(.{ .number = 8 })));
}

fn native(_: *State) callconv(.c) c_int {
    return 0;
}

test "newindex_chain invalid table keys refuse before function or table handlers" {
    var state = try State.init(a);
    defer state.deinit();
    const leaf = try state.newTable();
    const root = try fallback(&state, .from(.{ .table = leaf }));
    try install(&state, .from(.{ .table = root }));
    var diagnostic: ?vm.Diagnostic = null;
    for ([_]Value{ .from(.{ .table = leaf }), .fromFunction(.{ .native = native }) }) |target| {
        try field(&state, root.metatable.?, "__newindex", target);
        for ([_]Value{ .nil, .from(.{ .number = std.math.nan(f64) }) }) |key| {
            try std.testing.expectError(error.Type, write(&state, .from(.{ .table = root }), key, .from(.{ .number = 7 }), &diagnostic));
            try equal(.type_error, diagnostic.?.kind);
            try equal(@as(usize, 0), state.top());
        }
    }
    _ = try run(&state, "local _ENV=t x=7", &diagnostic);
    try expect(root.getString("x").is(.nil));
    try expect(leaf.getString("x").is(.nil));
}

test "newindex_chain userdata and primitive handler targets" {
    var state = try State.init(a);
    defer state.deinit();
    const leaf = try state.newTable();
    const userdata = try state.newUserdata(0);
    const meta = try state.newTable();
    try field(&state, meta, "__newindex", .from(.{ .table = try chain(&state, 2, leaf) }));
    try state.setMetatable(.from(.{ .userdata = userdata }), meta);
    try install(&state, .from(.{ .userdata = userdata }));
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(&state, "local _ENV=t x=7", &diagnostic);
    try write(&state, .from(.{ .userdata = userdata }), .from(.{ .number = -0.0 }), .from(.{ .number = 11 }), &diagnostic);
    try write(&state, .from(.{ .userdata = userdata }), .from(.{ .number = std.math.inf(f64) }), .from(.{ .number = 12 }), &diagnostic);
    try expect(leaf.getString("x").equal(.from(.{ .number = 7 })));
    try expect(leaf.get(.from(.{ .number = 0 })).equal(.from(.{ .number = 11 })));
    try expect(leaf.get(.from(.{ .number = std.math.inf(f64) })).equal(.from(.{ .number = 12 })));
    try field(&state, meta, "__newindex", .from(.{ .boolean = false }));
    try std.testing.expectError(error.Type, run(&state, "local _ENV=t y=8", &diagnostic));
    try equal(.boolean, diagnostic.?.operand_type.?);
    try field(&state, meta, "__newindex", .nil);
    try std.testing.expectError(error.Type, run(&state, "local _ENV=t y=8", &diagnostic));
    try equal(.userdata, diagnostic.?.operand_type.?);
}

test "newindex_chain boundary success and runtime refusal agree with Lua traversal" {
    var lines = std.mem.tokenizeScalar(u8, @embedFile("lua55-newindex-chains"), '\n');
    var checked: usize = 0;
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const length = try std.fmt.parseInt(usize, fields.next().?, 10);
        const present = std.mem.eql(u8, fields.next().?, "true");
        const kind = fields.next().?;
        try expect(fields.next() == null);
        var state = try State.init(a);
        defer state.deinit();
        const terminal = try state.newTable();
        if (present) try field(&state, terminal, "x", .from(.{ .boolean = false }));
        const root = try chain(&state, length, terminal);
        try install(&state, .from(.{ .table = root }));
        try state.push(.from(.{ .number = 42 }));
        var diagnostic: ?vm.Diagnostic = null;
        if (std.mem.eql(u8, kind, "runtime")) {
            try std.testing.expectError(error.Runtime, run(&state, "local _ENV=t\nx=7", &diagnostic));
            try equal(.newindex_chain_too_long, diagnostic.?.kind);
            try equal(@as(usize, 2), diagnostic.?.position.line);
            try expect(terminal.getString("x").equal(if (present) .from(.{ .boolean = false }) else .nil));
        } else {
            try std.testing.expectEqualStrings("stored", kind);
            _ = try run(&state, "local _ENV=t x=7", &diagnostic);
            try expect(terminal.getString("x").equal(.from(.{ .number = 7 })));
            if (length > 0) try expect(root.getString("x").is(.nil));
        }
        try equal(@as(usize, 1), state.top());
        try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
        try equal(@as(usize, 0), state.frames.items.len);
        checked += 1;
    }
    try expect(checked > 0);
    std.debug.print("newindex-chain fixture: {d} Lua traversal boundaries checked\n", .{checked});
}

test "newindex_chain cycles stop within one instruction and recover on own writes" {
    var state = try State.init(a);
    defer state.deinit();
    const root = try state.newTable();
    const meta = try state.newTable();
    try field(&state, meta, "__newindex", .from(.{ .table = root }));
    root.metatable = meta;
    try field(&state, root, "own", .from(.{ .number = 1 }));
    try install(&state, .from(.{ .table = root }));
    var diagnostic: ?vm.Diagnostic = null;
    try std.testing.expectError(error.Runtime, run(&state, "local _ENV=t x=7", &diagnostic));
    try equal(.newindex_chain_too_long, diagnostic.?.kind);
    try expect(root.getString("x").is(.nil));
    _ = try run(&state, "local _ENV=t own=8", &diagnostic);
    try expect(root.getString("own").equal(.from(.{ .number = 8 })));
}

test "newindex_chain global writes and initializer stores share fallback" {
    var state = try State.init(a);
    defer state.deinit();
    const leaf = try state.newTable();
    const meta = try state.newTable();
    try field(&state, meta, "__newindex", .from(.{ .table = leaf }));
    state.globals.metatable = meta;
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(&state, "x=7 global y=8", &diagnostic);
    try expect(leaf.getString("x").equal(.from(.{ .number = 7 })));
    try expect(leaf.getString("y").equal(.from(.{ .number = 8 })));
    try expect(state.globals.getString("x").is(.nil));
    try expect(state.globals.getString("y").is(.nil));
}

test "newindex_chain graph and stored values survive VM collection" {
    var state = try State.init(a);
    defer state.deinit();
    const leaf = try state.newTable();
    try install(&state, .from(.{ .table = try chain(&state, 8, leaf) }));
    state.setCollectionThreshold(0);
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(&state, "local _ENV=t x={v=9} local n=0 while n<200 do local garbage={} n=n+1 end", &diagnostic);
    try expect(leaf.getString("x").is(.table));
    try expect(leaf.getString("x").unpack().table.getString("v").equal(.from(.{ .number = 9 })));
    const before = state.object_count;
    try field(&state, state.globals, "t", .nil);
    state.collect();
    try expect(state.object_count < before);
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var state = try State.init(allocator);
    defer state.deinit();
    const leaf = try state.newTable();
    try install(&state, .from(.{ .table = try chain(&state, 3, leaf) }));
    const closure = try compile(&state, allocator, "local _ENV=t x={v=9}");
    try state.push(.from(.{ .number = 42 }));
    var diagnostic: ?vm.Diagnostic = null;
    _ = vm.run(&state, closure, &diagnostic) catch |err| {
        try equal(@as(usize, 1), state.top());
        try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
        try equal(@as(usize, 0), state.frames.items.len);
        return err;
    };
    try expect(leaf.getString("x").unpack().table.getString("v").equal(.from(.{ .number = 9 })));
}

test "newindex_chain every allocation failure cleans partial setup and caller frames" {
    try allocation_failures.checkAll(a, allocationCase, .{});
}

test "newindex_chain traversal of existing terminal key allocates nothing" {
    var state = try State.init(a);
    defer state.deinit();
    const leaf = try state.newTable();
    const key = Value.from(.{ .string = try state.newString("x") });
    state.barrier(&leaf.header);
    try leaf.set(a, key, .from(.{ .boolean = false }));
    const root = try chain(&state, 2000, leaf);
    const closure = try storeProgram(&state, .from(.{ .table = root }), key, .from(.{ .number = 7 }));
    try runtime.growStack(&state.stack, state.open_cells.items, state.allocator, 3);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    const original = state.allocator;
    defer state.allocator = original;
    state.allocator = failing.allocator();
    var diagnostic: ?vm.Diagnostic = null;
    _ = try vm.run(&state, closure, &diagnostic);
    try expect(leaf.get(key).equal(.from(.{ .number = 7 })));
    try equal(@as(usize, 0), failing.alloc_index);
}

var hook_calls: usize = 0;
fn observer(_: *State) callconv(.c) c_int {
    hook_calls += 1;
    return 0;
}

test "newindex_chain handler traversal adds no instruction hook events" {
    var expected: ?usize = null;
    for ([_]usize{ 1, 2000 }) |length| {
        var state = try State.init(a);
        defer state.deinit();
        const leaf = try state.newTable();
        try field(&state, leaf, "x", .from(.{ .number = 1 }));
        try install(&state, .from(.{ .table = try chain(&state, length, leaf) }));
        hook_calls = 0;
        state.setHook(observer, 1);
        var diagnostic: ?vm.Diagnostic = null;
        _ = try run(&state, "local _ENV=t x=7", &diagnostic);
        if (expected) |count| try equal(count, hook_calls) else expected = hook_calls;
    }
    try expect(expected.? > 0);
}
