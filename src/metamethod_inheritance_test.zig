//! Metamethod names are found along the metatable's table-valued __index
//! links (ADR 0012, the owner's answers of 2026-10-27): the
//! same walk `mt[name]` would make, except that a function __index is never
//! run. These cases pin the rule through every handler kind, the 2000-link
//! budget shared with the ordinary __index chain, cycles, the diagnostic
//! __name, the raw attributes of a metatable, allocation failure and GC.
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
fn install(state: *State, name: []const u8, value: Value) !void {
    try field(state, state.globals, name, value);
}
/// A metatable for `receiver` that inherits from `base`: its own metatable
/// holds `base` in __index, the shape of the cases the owner decided.
fn inherit(state: *State, receiver: Value, base: *runtime.Table) !*runtime.Table {
    const meta = try state.newTable();
    const link = try state.newTable();
    try field(state, link, "__index", .from(.{ .table = base }));
    meta.metatable = link;
    try state.setMetatable(receiver, meta);
    return meta;
}
/// `links` inheritance links from the receiver's metatable to `terminal`.
fn linked(state: *State, receiver: Value, links: usize, terminal: *runtime.Table) !void {
    var current = terminal;
    for (0..links) |_| {
        const meta = try state.newTable();
        const link = try state.newTable();
        try field(state, link, "__index", .from(.{ .table = current }));
        meta.metatable = link;
        current = meta;
    }
    try state.setMetatable(receiver, current);
}
fn expectValue(state: *State, source: []const u8, wanted: Value) !void {
    var diagnostic: ?vm.Diagnostic = null;
    try equal(@as(usize, 1), try run(state, source, &diagnostic));
    try expect(state.get(-1).?.equal(wanted));
    try state.setTop(0);
    try equal(@as(usize, 0), state.frames.items.len);
}
fn expectString(state: *State, source: []const u8, wanted: []const u8) !void {
    // The wanted bytes are compared, not a string the collector could free
    // while the script runs.
    var diagnostic: ?vm.Diagnostic = null;
    try equal(@as(usize, 1), try run(state, source, &diagnostic));
    try std.testing.expectEqualStrings(wanted, state.get(-1).?.unpack().string.bytes);
    try state.setTop(0);
    try equal(@as(usize, 0), state.frames.items.len);
}
fn expectRefusal(state: *State, source: []const u8, err: vm.Error, message: []const u8) !void {
    var diagnostic: ?vm.Diagnostic = null;
    try std.testing.expectError(err, run(state, source, &diagnostic));
    try std.testing.expectEqualStrings(message, state.failure.?.value.unpack().string.bytes);
    try equal(@as(usize, 0), state.top());
    try equal(@as(usize, 0), state.frames.items.len);
}
const chain_refusal = "spec:1: '__index' chain too long; possible loop";
/// The terminal of a call chain: how many values it got and their ids.
const describe = "return function(...) local r={...} local s='' for i=1,#r do s=s..r[i].id..',' end return #r, s end";

test "metamethod_inheritance a name is found along the links through every call entry and a direct name shadows it" {
    var state = try State.init(a);
    defer state.deinit();
    // Handlers are compiled before the tables that hold them exist: a table
    // nothing reaches yet would be collected while the script runs.
    const double = try script(&state, "return function(self, x) return x * 2 end");
    const base = try state.newTable();
    try field(&state, base, "__call", double);
    const value = Value.from(.{ .table = try state.newTable() });
    try install(&state, "t", value);
    const meta = try inherit(&state, value, base);
    for ([_][]const u8{ "local n=t(21) return n", "return t(21)", "for k in t,21 do return k end" }) |source| try expectValue(&state, source, .from(.{ .number = 42 }));
    // A name in a nearer table wins, as for any __index chain.
    try field(&state, meta, "__call", try script(&state, "return function(self, x) return x + 1 end"));
    try expectValue(&state, "return t(21)", .from(.{ .number = 22 }));
    // Two links: the base inherits in turn.
    const deep = try script(&state, "return function(l, r) return 'deep' end");
    const deeper = try state.newTable();
    try field(&state, deeper, "__add", deep);
    const link = try state.newTable();
    try field(&state, link, "__index", .from(.{ .table = deeper }));
    base.metatable = link;
    try expectString(&state, "return t + 1", "deep");
}

test "metamethod_inheritance a function __index link is not run and the name counts as absent" {
    var state = try State.init(a);
    defer state.deinit();
    const value = Value.from(.{ .table = try state.newTable() });
    try install(&state, "t", value);
    const getter = try script(&state, "global * return function(_, k) ran=k return function() return 1 end end");
    const meta = try state.newTable();
    const link = try state.newTable();
    try field(&state, link, "__index", getter);
    meta.metatable = link;
    try state.setMetatable(value, meta);
    try expectRefusal(&state, "local n=t() return n", error.Type, "spec:1: attempt to call a table value (global 't')");
    try expectRefusal(&state, "return t + 1", error.Type, "spec:1: attempt to perform arithmetic on a table value (global 't')");
    try expectRefusal(&state, "return t.x.y", error.Type, "spec:1: attempt to index a nil value (field 'x')");
    try expect(state.globals.getString("ran").is(.nil));
}

test "metamethod_inheritance operators comparison length equality index and newindex use the same rule" {
    var state = try State.init(a);
    defer state.deinit();
    const base = try state.newTable();
    try install(&state, "base", .from(.{ .table = base }));
    for ([_]struct { name: []const u8, source: []const u8 }{
        .{ .name = "__add", .source = "return function(l, r) return 'add' end" },
        .{ .name = "__unm", .source = "return function(v) return 'unm' end" },
        .{ .name = "__concat", .source = "return function(l, r) return 'concat' end" },
        .{ .name = "__len", .source = "return function(v) return 'len' end" },
        .{ .name = "__eq", .source = "return function(l, r) return true end" },
        .{ .name = "__lt", .source = "return function(l, r) return true end" },
        .{ .name = "__le", .source = "return function(l, r) return false end" },
    }) |case| try field(&state, base, case.name, try script(&state, case.source));
    const fields = try state.newTable();
    try field(&state, fields, "x", .from(.{ .number = 7 }));
    try field(&state, base, "__index", .from(.{ .table = fields }));
    const store = try state.newTable();
    try field(&state, base, "__newindex", .from(.{ .table = store }));
    const value = Value.from(.{ .table = try state.newTable() });
    const other = Value.from(.{ .table = try state.newTable() });
    try install(&state, "t", value);
    try install(&state, "u", other);
    _ = try inherit(&state, value, base);
    _ = try inherit(&state, other, base);
    try expectString(&state, "return t + 1", "add");
    try expectString(&state, "return 1 + t", "add");
    try expectString(&state, "return -t", "unm");
    try expectString(&state, "return t .. 's'", "concat");
    try expectString(&state, "return #t", "len");
    try expectValue(&state, "return t == u", .from(.{ .boolean = true }));
    try expectValue(&state, "return t < u", .from(.{ .boolean = true }));
    try expectValue(&state, "return t >= u", .from(.{ .boolean = false }));
    try expectValue(&state, "return t.x", .from(.{ .number = 7 }));
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(&state, "t.y = 3", &diagnostic);
    try expect(store.getString("y").equal(.from(.{ .number = 3 })));
    try expect(value.unpack().table.getString("y").is(.nil));
}

test "metamethod_inheritance links count like an __index chain and the table after the last is read" {
    for ([_]struct { links: usize, present: bool, refused: bool }{
        .{ .links = 1999, .present = false, .refused = false },
        .{ .links = 2000, .present = true, .refused = false },
        .{ .links = 2000, .present = false, .refused = true },
        .{ .links = 2001, .present = true, .refused = true },
    }) |case| {
        var state = try State.init(a);
        defer state.deinit();
        const seven = try script(&state, "return function() return 7 end");
        const terminal = try state.newTable();
        if (case.present) try field(&state, terminal, "__call", seven);
        const value = Value.from(.{ .table = try state.newTable() });
        try install(&state, "t", value);
        try linked(&state, value, case.links, terminal);
        if (case.refused) {
            try expectRefusal(&state, "local n=t() return n", error.Runtime, chain_refusal);
            try expectRefusal(&state, "return t + 1", error.Runtime, chain_refusal);
            try expectRefusal(&state, "return t.x", error.Runtime, chain_refusal);
        } else if (case.present) {
            try expectValue(&state, "local n=t() return n", .from(.{ .number = 7 }));
        } else {
            try expectRefusal(&state, "local n=t() return n", error.Type, "spec:1: attempt to call a table value (global 't')");
        }
    }
}

test "metamethod_inheritance a cyclic link spends the budget without host recursion and a direct name still wins" {
    var state = try State.init(a);
    defer state.deinit();
    const value = Value.from(.{ .table = try state.newTable() });
    try install(&state, "t", value);
    const meta = try state.newTable();
    const link = try state.newTable();
    try field(&state, link, "__index", .from(.{ .table = meta }));
    meta.metatable = link;
    try state.setMetatable(value, meta);
    try expectRefusal(&state, "local n=t() return n", error.Runtime, chain_refusal);
    try expectRefusal(&state, "return #t", error.Runtime, chain_refusal);
    try expectRefusal(&state, "return t == {}", error.Runtime, chain_refusal);
    try field(&state, meta, "__call", try script(&state, "return function() return 'own' end"));
    try expectString(&state, "local n=t() return n", "own");
    // Two metatables inheriting from each other.
    const other = Value.from(.{ .table = try state.newTable() });
    try install(&state, "u", other);
    const second = try inherit(&state, other, meta);
    try field(&state, link, "__index", .from(.{ .table = second }));
    try expectRefusal(&state, "return u + 1", error.Runtime, chain_refusal);
    try expectString(&state, "local n=u() return n", "own");
}

test "metamethod_inheritance __name is found along the links and one out of reach keeps the failure being reported" {
    var state = try State.init(a);
    defer state.deinit();
    const base = try state.newTable();
    try field(&state, base, "__name", .from(.{ .string = try state.newString("Point") }));
    const value = Value.from(.{ .table = try state.newTable() });
    try install(&state, "t", value);
    _ = try inherit(&state, value, base);
    try expectRefusal(&state, "return t + 1", error.Type, "spec:1: attempt to perform arithmetic on a Point value (global 't')");
    try expectRefusal(&state, "for i = t, 1 do end", error.Type, "spec:1: bad 'for' initial value (number expected, got Point)");
    try expectRefusal(&state, "return 1 < t", error.Type, "spec:1: attempt to compare number with Point");
    // A cyclic chain: the for loop's own failure is reported with the plain
    // word, since no metamethod read precedes it.
    const looping = Value.from(.{ .table = try state.newTable() });
    try install(&state, "l", looping);
    const meta = try state.newTable();
    const link = try state.newTable();
    try field(&state, link, "__index", .from(.{ .table = meta }));
    meta.metatable = link;
    try state.setMetatable(looping, meta);
    try expectRefusal(&state, "for i = l, 1 do end", error.Type, "spec:1: bad 'for' initial value (number expected, got table)");
}

test "metamethod_inheritance each relay of a __call chain may inherit its handler and still costs one fetch" {
    var state = try State.init(a);
    defer state.deinit();
    const describer = try script(&state, describe);
    // Three relays, each finding __call one link away.
    var current = describer;
    var index: usize = 3;
    while (index > 0) : (index -= 1) {
        const relay = Value.from(.{ .table = try state.newTable() });
        var id: [4]u8 = undefined;
        try field(&state, relay.unpack().table, "id", .from(.{ .string = try state.newString(try std.fmt.bufPrint(&id, "t{d}", .{index - 1})) }));
        const base = try state.newTable();
        try field(&state, base, "__call", current);
        _ = try inherit(&state, relay, base);
        current = relay;
    }
    try install(&state, "t", current);
    var diagnostic: ?vm.Diagnostic = null;
    try equal(@as(usize, 2), try run(&state, "return t({id='arg'})", &diagnostic));
    try expect(state.get(1).?.equal(.from(.{ .number = 4 })));
    try std.testing.expectEqualStrings("t2,t1,t0,arg,", state.get(2).?.unpack().string.bytes);
    try state.setTop(0);
    // The budget is unchanged: the 2000th fetch may yield the function, the
    // 2001st is never made.
    for ([_]struct { relays: usize, refused: bool }{ .{ .relays = 2000, .refused = false }, .{ .relays = 2001, .refused = true } }) |case| {
        var terminal = try script(&state, "global * return function(...) ran=true local r={...} return #r end");
        for (0..case.relays) |_| {
            const relay = Value.from(.{ .table = try state.newTable() });
            const base = try state.newTable();
            try field(&state, base, "__call", terminal);
            _ = try inherit(&state, relay, base);
            terminal = relay;
        }
        try install(&state, "t", terminal);
        try field(&state, state.globals, "ran", .nil);
        if (case.refused) {
            try expectRefusal(&state, "local n=t(0) return n", error.Runtime, "spec:1: '__call' chain too long");
            try expect(state.globals.getString("ran").is(.nil));
        } else {
            try expectValue(&state, "local n=t(0) return n", .from(.{ .number = @floatFromInt(case.relays + 1) }));
            try expect(state.globals.getString("ran").equal(.from(.{ .boolean = true })));
        }
    }
}

test "metamethod_inheritance a userdata finaliser is refused only where it is written" {
    var state = try State.init(a);
    defer state.deinit();
    const nine = try script(&state, "return function() return 9 end");
    const userdata = try state.newUserdata(4);
    const base = try state.newTable();
    try field(&state, base, "__gc", .from(.{ .boolean = false }));
    try field(&state, base, "__len", nine);
    // __gc one link away is not a finaliser on this metatable; the metatable
    // is accepted and its other names are still inherited.
    _ = try inherit(&state, .from(.{ .userdata = userdata }), base);
    try install(&state, "u", .from(.{ .userdata = userdata }));
    try expectValue(&state, "return #u", .from(.{ .number = 9 }));
    const direct = try state.newTable();
    try field(&state, direct, "__gc", .from(.{ .boolean = false }));
    try std.testing.expectError(error.Finalizer, state.setMetatable(.from(.{ .userdata = userdata }), direct));
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var state = try State.init(allocator);
    defer state.deinit();
    var diagnostic: ?vm.Diagnostic = null;
    _ = try vm.run(&state, try prepare(&state, "return function(self, x) return {x, x} end"), &diagnostic);
    const function = state.get(-1).?;
    try state.setTop(0);
    const base = try state.newTable();
    try field(&state, base, "__call", function);
    try field(&state, base, "__add", function);
    const value = Value.from(.{ .table = try state.newTable() });
    try install(&state, "t", value);
    try linked(&state, value, 3, base);
    const closure = try prepare(&state, "local r=t(7) local s=t+1 return r[2], s[1]");
    try state.push(.from(.{ .number = 42 }));
    _ = vm.run(&state, closure, &diagnostic) catch |err| {
        try equal(@as(usize, 1), state.top());
        try equal(@as(usize, 0), state.frames.items.len);
        return err;
    };
    try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
    try expect(state.get(2).?.equal(.from(.{ .number = 7 })));
    try expect(state.get(3).?.equal(.from(.{ .number = 1 })));
}
test "metamethod_inheritance allocation failures while a handler runs restore the caller" {
    try allocation_failures.checkAll(a, allocationCase, .{});
}

test "metamethod_inheritance the linked metatables survive collection while a handler runs" {
    var state = try State.init(a);
    defer state.deinit();
    const allocating = try script(&state, "return function(self, n) local t = {} for i = 1, n do t[i] = {} end return #t end");
    const base = try state.newTable();
    try field(&state, base, "__call", allocating);
    try field(&state, base, "__index", .from(.{ .table = try state.newTable() }));
    const value = Value.from(.{ .table = try state.newTable() });
    try install(&state, "t", value);
    try linked(&state, value, 50, base);
    state.setCollectionThreshold(0);
    try expectValue(&state, "local n = t(300) return n + t(300)", .from(.{ .number = 600 }));
    try expectValue(&state, "return t.absent == nil", .from(.{ .boolean = true }));
}

test "metamethod_inheritance internal callable transport shares inherited handlers and host failure placement" {
    const transport = @import("failure_transport.zig");
    var state = try State.init(a);
    defer state.deinit();
    const double = try script(&state, "return function(self,x) return x*2 end");
    const base = try state.newTable();
    try field(&state, base, "__call", double);
    const value = Value.from(.{ .table = try state.newTable() });
    try install(&state, "t", value);
    const meta = try inherit(&state, value, base);
    try state.push(.from(.{ .number = 42 }));
    try state.push(value);
    try state.push(.from(.{ .number = 7 }));
    var diagnostic: ?vm.Diagnostic = null;
    try equal(@as(usize, 1), (try transport.call(&state, 1, true, &diagnostic)).success);
    try equal(@as(f64, 14), state.get(2).?.numberValue().?);
    try state.setTop(1);
    // Break the inheritance into a cycle lacking __call: transport must publish
    // the lookup Runtime, not InvalidBytecode or an invented source location.
    try field(&state, base, "__call", .nil);
    try field(&state, meta.metatable.?, "__index", .from(.{ .table = meta }));
    try state.push(value);
    try equal(runtime.FailureKind.runtime_error, (try transport.call(&state, 0, false, &diagnostic)).failure);
    try std.testing.expectEqualStrings("'__index' chain too long; possible loop", state.get(2).?.unpack().string.bytes);
    try expect(state.failure.?.position == null);
    try equal(@as(f64, 42), state.get(1).?.numberValue().?);
    try equal(@as(usize, 2), state.top());
    try expect(state.execution == null and state.frames.items.len == 0);
}
