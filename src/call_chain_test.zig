const std = @import("std");
const allocation_failures = @import("allocation_failures.zig");
const runtime = @import("runtime.zig");
const loader = @import("loader.zig");
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
fn prepare(state: *State, source: []const u8) !*runtime.Closure {
    var diagnostic: ?loader.Diagnostic = null;
    return loader.prepare(state, source, "=spec", &diagnostic);
}
fn run(state: *State, source: []const u8, diagnostic: *?vm.Diagnostic) !usize {
    return vm.run(state, try prepare(state, source), diagnostic);
}
fn script(state: *State, source: []const u8) !Value {
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(state, source, &diagnostic);
    const value = state.get(-1).?;
    try state.setTop(-2);
    return value;
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
/// Builds `relays` tables whose __call is the next one, the last holding
/// `terminal`, the way the Lua capture does. The first table is returned.
fn chain(state: *State, relays: usize, terminal: Value) !Value {
    var current = terminal;
    var i = relays;
    while (i > 0) : (i -= 1) {
        const table = Value.from(.{ .table = try state.newTable() });
        _ = try attach(state, table, "__call", current);
        current = table;
    }
    return current;
}
/// The terminal in Lua's capture and in these cases: how many values it got
/// and their `id` fields joined by commas.
const describe = "return function(...) local r={...} local s='' for i=1,#r do s=s..r[i].id..',' end return #r, s end";
fn expectRefusal(state: *State, source: []const u8, err: vm.Error, message: []const u8) !void {
    var diagnostic: ?vm.Diagnostic = null;
    try std.testing.expectError(err, run(state, source, &diagnostic));
    try std.testing.expectEqualStrings(message, state.failure.?.value.unpack().string.bytes);
    try equal(@as(usize, 0), state.top());
    try equal(@as(usize, 0), state.frames.items.len);
}

test "call_chain captured Lua chunks agree through ordinary tail and iterator entries" {
    var lines = std.mem.tokenizeScalar(u8, @embedFile("lua55-call-chains"), '\n');
    var checked: usize = 0;
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const relays = try std.fmt.parseInt(usize, fields.next().?, 10);
        const terminal = fields.next().?;
        var buffer: [4096]u8 = undefined;
        const source = try std.fmt.hexToBytes(&buffer, fields.next().?);
        const count = fields.next().?;
        const expected = fields.next().?;
        try expect(fields.next() == null);
        errdefer std.debug.print("call chain fixture failed: {d} {s} {s}\n", .{ relays, terminal, source });
        var state = try State.init(a);
        defer state.deinit();
        const describer = try script(&state, describe);
        const last: Value = if (std.mem.eql(u8, terminal, "fn")) describer else if (std.mem.eql(u8, terminal, "false")) .from(.{ .boolean = false }) else if (std.mem.eql(u8, terminal, "number")) .from(.{ .number = 5 }) else if (std.mem.eql(u8, terminal, "string")) .from(.{ .string = try state.newString("s") }) else blk: {
            const end = Value.from(.{ .table = try state.newTable() });
            const meta = try state.newTable();
            try state.setMetatable(end, meta);
            if (std.mem.eql(u8, terminal, "index")) {
                try field(&state, end.unpack().table, "id", .from(.{ .string = try state.newString("end") }));
                const provider = try state.newTable();
                try field(&state, provider, "__call", describer);
                _ = try attach(&state, .from(.{ .table = meta }), "__index", .from(.{ .table = provider }));
            } else if (std.mem.eql(u8, terminal, "self")) {
                try field(&state, meta, "__call", end);
            } else if (std.mem.eql(u8, terminal, "mutual")) {
                const other = Value.from(.{ .table = try state.newTable() });
                _ = try attach(&state, other, "__call", end);
                try field(&state, meta, "__call", other);
            } else try expect(std.mem.eql(u8, terminal, "nocall"));
            break :blk end;
        };
        const first = try chain(&state, relays, last);
        // The capture's ids: t0 is the table the program names, t1 the next.
        var current = first;
        var index: usize = 0;
        while (current.is(.table) and index < relays) : (index += 1) {
            var id: [8]u8 = undefined;
            try field(&state, current.unpack().table, "id", .from(.{ .string = try state.newString(try std.fmt.bufPrint(&id, "t{d}", .{index})) }));
            current = current.unpack().table.metatable.?.getString("__call");
        }
        try install(&state, "t", first);
        var diagnostic: ?vm.Diagnostic = null;
        if (std.mem.eql(u8, terminal, "index")) {
            // The one recorded difference: Lua reads __call raw and refuses,
            // Nilu finds it along the metatable's __index link (ADR 0012,
            // 13.1). The capture keeps Lua's bytes; Nilu's answer is the
            // describer's count, the terminal and every relay before it.
            var bytes: [4096]u8 = undefined;
            try expect(std.mem.eql(u8, count, "error"));
            try std.testing.expectEqualStrings("attempt to call a table value (global 't')", try std.fmt.hexToBytes(&bytes, expected));
            try equal(@as(usize, 1), try run(&state, source, &diagnostic));
            try expect(state.get(-1).?.equal(.from(.{ .number = @floatFromInt(relays + 1) })));
        } else if (std.mem.eql(u8, count, "error")) {
            var bytes: [4096]u8 = undefined;
            const message = try std.fmt.hexToBytes(&bytes, expected);
            const err: vm.Error = if (std.mem.startsWith(u8, message, "'__call' chain too long")) error.Runtime else error.Type;
            try std.testing.expectError(err, run(&state, source, &diagnostic));
            try std.testing.expectEqualStrings(message, state.failure.?.value.unpack().string.bytes["spec:1: ".len..]);
            try equal(@as(usize, 0), state.top());
            try equal(@as(usize, 0), state.frames.items.len);
        } else {
            try equal(try std.fmt.parseInt(usize, count, 10), try run(&state, source, &diagnostic));
            var values = std.mem.tokenizeScalar(u8, expected, ',');
            for (state.stack.items) |actual| {
                const value = values.next().?;
                const colon = std.mem.indexOfScalar(u8, value, ':').?;
                try std.testing.expectEqualStrings(value[0..colon], actual.typeName());
                const payload = value[colon + 1 ..];
                if (actual.numberValue() != null) {
                    try equal(try std.fmt.parseInt(u64, payload, 16), @as(u64, @bitCast(actual.numberValue().?)));
                } else if (actual.is(.string)) {
                    var bytes: [4096]u8 = undefined;
                    try std.testing.expectEqualSlices(u8, if (std.mem.eql(u8, payload, "-")) "" else try std.fmt.hexToBytes(&bytes, payload), actual.unpack().string.bytes);
                } else try expect(false);
            }
            try expect(values.next() == null);
        }
        checked += 1;
    }
    try expect(checked > 0);
    std.debug.print("call chain fixture: {d} Lua chunks executed through parser, compiler and VM\n", .{checked});
}

/// The terminal for the long chains: records that it ran and answers how
/// many values it received, without building a string from 2000 relays.
const counting = "global * return function(...) ran=true local r={...} return #r end";

test "call_chain budget counts raw fetches and the fetch that yields the function" {
    // Each relay is one fetch, so the function is yielded by fetch `relays`.
    // C04/C05: the 1999th and 2000th fetches may yield the function.
    // C06: the 2001st fetch is never made. C07: a table at the budget is the limit.
    for ([_]struct { relays: usize, received: ?usize }{ .{ .relays = 1999, .received = 2000 }, .{ .relays = 2000, .received = 2001 }, .{ .relays = 2001, .received = null }, .{ .relays = 2002, .received = null } }) |case| {
        var state = try State.init(a);
        defer state.deinit();
        try install(&state, "t", try chain(&state, case.relays, try script(&state, counting)));
        try state.push(.from(.{ .number = 42 }));
        var diagnostic: ?vm.Diagnostic = null;
        if (case.received) |received| {
            _ = try run(&state, "local n=t(0) return n", &diagnostic);
            try expect(state.get(-1).?.equal(.from(.{ .number = @floatFromInt(received) })));
            try expect(state.globals.getString("ran").equal(.from(.{ .boolean = true })));
        } else {
            try std.testing.expectError(error.Runtime, run(&state, "local n=t(0) return n", &diagnostic));
            try equal(.call_chain_too_long, diagnostic.?.kind);
            try std.testing.expectEqualStrings("spec:1: '__call' chain too long", state.failure.?.value.unpack().string.bytes);
            try expect(state.globals.getString("ran").is(.nil));
            try equal(@as(usize, 1), state.top());
        }
        try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
        try equal(@as(usize, 0), state.frames.items.len);
    }
}

test "call_chain a value reached at the budget that cannot carry __call is refused as not callable" {
    // C11: the 2000th fetch yields false; nothing more is fetched.
    var state = try State.init(a);
    defer state.deinit();
    try install(&state, "t", try chain(&state, 2000, .from(.{ .boolean = false })));
    try expectRefusal(&state, "local n=t(0) return n", error.Type, "spec:1: attempt to call a boolean value (global 't')");
    // The 2000th fetch yields a table or userdata whose metatable is not read.
    try install(&state, "t", try chain(&state, 2000, .from(.{ .table = try state.newTable() })));
    try expectRefusal(&state, "local n=t(0) return n", error.Runtime, "spec:1: '__call' chain too long");
    try install(&state, "t", try chain(&state, 2000, .from(.{ .userdata = try state.newUserdata(0) })));
    try expectRefusal(&state, "local n=t(0) return n", error.Runtime, "spec:1: '__call' chain too long");
}

test "call_chain cycles spend the same budget through every entry and need no visited set" {
    var state = try State.init(a);
    defer state.deinit();
    const loop = Value.from(.{ .table = try state.newTable() });
    _ = try attach(&state, loop, "__call", loop);
    const other = Value.from(.{ .table = try state.newTable() });
    const mutual = Value.from(.{ .table = try state.newTable() });
    _ = try attach(&state, other, "__call", mutual);
    _ = try attach(&state, mutual, "__call", other);
    // The cycle begins after 1998 relays, so the budget is what stops it.
    const late = try chain(&state, 1998, loop);
    // Every start is rooted before a run can collect.
    try install(&state, "mutual", mutual);
    try install(&state, "late", late);
    state.setCollectionThreshold(0);
    for ([_]Value{ loop, mutual, late }) |start| {
        try install(&state, "t", start);
        for ([_][]const u8{ "local n=t() return n", "return t()", "for k in t do end", "local f=function(...) return t(...) end return f(1,2)" }) |source| {
            try expectRefusal(&state, source, error.Runtime, "spec:1: '__call' chain too long");
        }
    }
    // A second resolution on the grown stack needs no more stack and no
    // other memory, with a collection at every instruction.
    const capacity = state.stack.capacity;
    var diagnostic: ?vm.Diagnostic = null;
    try std.testing.expectError(error.Runtime, run(&state, "local n=t() return n", &diagnostic));
    try equal(capacity, state.stack.capacity);
    try equal(.call_chain_too_long, diagnostic.?.kind);
}

test "call_chain every relay is inserted before the arguments with the last relay first" {
    var state = try State.init(a);
    defer state.deinit();
    const function = try script(&state, "return function(...) return ... end");
    const u = Value.from(.{ .userdata = try state.newUserdata(4) });
    _ = try attach(&state, u, "__call", function);
    const t1 = Value.from(.{ .table = try state.newTable() });
    _ = try attach(&state, t1, "__call", u);
    const t0 = Value.from(.{ .table = try state.newTable() });
    _ = try attach(&state, t0, "__call", t1);
    try install(&state, "t", t0);
    var diagnostic: ?vm.Diagnostic = null;
    // C10: userdata and tables relay alike; the function sees u, t1, t0, then
    // the arguments, and open arguments stay open.
    for ([_][]const u8{ "return t(7,nil)", "local a,b,c,d,e=t(7,nil) return a,b,c,d,e", "local function f(...) return t(...) end return f(7,nil)" }) |source| {
        try equal(@as(usize, 5), try run(&state, source, &diagnostic));
        try expect(state.get(1).?.equal(u));
        try expect(state.get(2).?.equal(t1));
        try expect(state.get(3).?.equal(t0));
        try expect(state.get(4).?.equal(.from(.{ .number = 7 })));
        try expect(state.get(5).?.is(.nil));
        try state.setTop(0);
    }
    // A function never has its metatable consulted (C01), and the direct
    // handler still inserts only the value called (C02).
    try install(&state, "t", t1);
    try equal(@as(usize, 3), try run(&state, "return t(7)", &diagnostic));
    try expect(state.get(1).?.equal(u));
    try expect(state.get(2).?.equal(t1));
    try expect(state.get(3).?.equal(.from(.{ .number = 7 })));
}

fn nativeCount(state: *State) callconv(.c) c_int {
    state.collect();
    state.push(.from(.{ .number = @floatFromInt(state.top()) })) catch return -1;
    return 1;
}

test "call_chain native and C closure terminals receive rooted relays from tail and iterator entries" {
    for ([_]bool{ false, true }) |captured| {
        var state = try State.init(a);
        defer state.deinit();
        const function = Value.fromFunction(if (captured) try state.newCClosure(nativeCount, &.{.from(.{ .number = 1 })}) else .{ .native = nativeCount });
        try install(&state, "t", try chain(&state, 3, function));
        state.setCollectionThreshold(0);
        var diagnostic: ?vm.Diagnostic = null;
        for ([_]struct { source: []const u8, received: f64 }{ .{ .source = "return t(1,2)", .received = 5 }, .{ .source = "local n=t(1,2) return n", .received = 5 }, .{ .source = "for n in t,1,2 do return n end", .received = 5 }, .{ .source = "local function f(...) return t(...) end return f()", .received = 3 } }) |case| {
            try equal(@as(usize, 1), try run(&state, case.source, &diagnostic));
            try expect(state.get(1).?.equal(.from(.{ .number = case.received })));
            try equal(@as(usize, 0), state.frames.items.len);
            try state.setTop(0);
        }
    }
}

test "call_chain the handler name is found along the metatable's links and a chain step without one is refused in place" {
    var state = try State.init(a);
    defer state.deinit();
    const function = try script(&state, "global * return function() ran=true end");
    // C12: __call offered through the metatable's table-valued __index is
    // found, through every entry (ADR 0012; Lua reads the name raw, 13.1).
    const target = Value.from(.{ .table = try state.newTable() });
    const meta = try state.newTable();
    try state.setMetatable(target, meta);
    const provider = try state.newTable();
    try field(&state, provider, "__call", function);
    _ = try attach(&state, .from(.{ .table = meta }), "__index", .from(.{ .table = provider }));
    try install(&state, "t", try chain(&state, 2, target));
    var diagnostic: ?vm.Diagnostic = null;
    for ([_][]const u8{ "local n=t() return n", "return t()", "for k in t do end" }) |source| {
        try field(&state, state.globals, "ran", .nil);
        _ = try run(&state, source, &diagnostic);
        try expect(state.globals.getString("ran").equal(.from(.{ .boolean = true })));
        try state.setTop(0);
        try equal(@as(usize, 0), state.frames.items.len);
    }
    try field(&state, state.globals, "ran", .nil);
    // The step's own type is named, whichever entry made the call (C11).
    try install(&state, "t", try chain(&state, 3, .from(.{ .number = 1 })));
    try expectRefusal(&state, "local x=t() return x", error.Type, "spec:1: attempt to call a number value (global 't')");
    try expectRefusal(&state, "return t()", error.Type, "spec:1: attempt to call a number value (global 't')");
    try expectRefusal(&state, "local f=t local n=f() return n", error.Type, "spec:1: attempt to call a number value (local 'f')");
    try expect(state.globals.getString("ran").is(.nil));
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var state = try State.init(allocator);
    defer state.deinit();
    var diagnostic: ?vm.Diagnostic = null;
    _ = try vm.run(&state, try prepare(&state, "return function(...) local r={...} return #r end"), &diagnostic);
    const function = state.get(-1).?;
    try state.setTop(0);
    try install(&state, "t", try chain(&state, 3, function));
    const closure = try prepare(&state, "local n=t(7) return n");
    try state.push(.from(.{ .number = 42 }));
    _ = vm.run(&state, closure, &diagnostic) catch |err| {
        try equal(@as(usize, 1), state.top());
        try equal(@as(usize, 0), state.frames.items.len);
        return err;
    };
    try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
    try expect(state.get(2).?.equal(.from(.{ .number = 4 })));
}
test "call_chain allocation failures while growing the stack restore the caller" {
    try allocation_failures.checkAll(a, allocationCase, .{});
}

test "call_chain a long chain grows the stack and keeps the caller and captures intact" {
    var state = try State.init(a);
    defer state.deinit();
    try install(&state, "t", try chain(&state, 1999, try script(&state, counting)));
    try state.push(.from(.{ .number = 42 }));
    const capacity = state.stack.capacity;
    state.setCollectionThreshold(0);
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(&state, "local keep=9 local n=t(0) local function f() return keep end return keep,n,f()", &diagnostic);
    try expect(state.stack.capacity > capacity);
    for ([_]Value{ .from(.{ .number = 42 }), .from(.{ .number = 9 }), .from(.{ .number = 2000 }), .from(.{ .number = 9 }) }, state.stack.items) |wanted, actual| try expect(actual.equal(wanted));
    try equal(@as(usize, 0), state.frames.items.len);
}

var priority_terminal_calls: usize = 0;
fn priorityTerminal(_: *State) callconv(.c) c_int {
    priority_terminal_calls += 1;
    return 0;
}
fn priorityProgram(state: *State, target: Value) !*runtime.Closure {
    const bytecode = @import("bytecode.zig");
    const position = @import("Token.zig").Position{ .offset = 0, .line = 1, .column = 1 };
    const code = [_]bytecode.Written{
        .{ .position = position, .operation = .{ .constant = .{ .destination = 0, .index = 0 } } },
        .{ .position = position, .operation = .{ .call = .{ .base = 0, .arguments = 0, .results = 0 } } },
        .{ .position = position, .operation = .{ .returns = .{ .first = 0, .count = 0 } } },
    };
    return state.newChunk(try state.newProgram(&.{target}, &code, 1, "", "=priority"));
}
const PriorityCase = enum { invalid, budget, valid };
fn priorityCase(case: PriorityCase) !void {
    var state = try State.init(a);
    defer state.deinit();
    const target = try chain(&state, if (case == .budget) 2001 else 1, if (case == .invalid) .from(.{ .boolean = false }) else .fromFunction(.{ .native = priorityTerminal }));
    const chunk = try priorityProgram(&state, target);
    const caller_slots = State.max_stack - (if (case == .budget) @as(usize, 2000) else @as(usize, 1));
    try state.setTop(@intCast(caller_slots));
    state.stack.items[0] = .from(.{ .number = 42 });
    priority_terminal_calls = 0;
    var diagnostic: ?vm.Diagnostic = null;
    try std.testing.expectError(switch (case) {
        .invalid => error.Type,
        .budget => error.Runtime,
        .valid => error.StackLimit,
    }, vm.run(&state, chunk, &diagnostic));
    try equal(@as(usize, 0), priority_terminal_calls);
    try equal(caller_slots, state.top());
    try equal(@as(f64, 42), state.get(1).?.numberValue().?);
    try equal(@as(usize, 0), state.frames.items.len);
}
test "call_chain known invalid Type precedes allocating an impossible relay slot" {
    try priorityCase(.invalid);
    try priorityCase(.valid);
}
test "call_chain known budget refusal precedes allocating an impossible relay slot" {
    try priorityCase(.budget);
}
