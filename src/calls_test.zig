const std = @import("std");
const allocation_failures = @import("allocation_failures.zig");
const repeated = @import("repeated_text.zig").repeated;
const runtime = @import("runtime.zig");
const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const vm = @import("vm.zig");
const State = runtime.State;
const Value = runtime.Value;
const a = std.testing.allocator;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;

fn compile(state: *State, source: []const u8) !*runtime.Prototype {
    var parsed: ?parser.Diagnostic = null;
    var ast = try parser.parseChunk(a, source, &parsed);
    defer ast.deinit();
    var diagnostic: ?compiler.Diagnostic = null;
    return compiler.compile(a, state, &ast, "<calls>", &diagnostic);
}
fn define(state: *State, name: []const u8, source: []const u8) !*runtime.Closure {
    const closure = try state.newChunk(try compile(state, source));
    state.barrier(&state.globals.header);
    try state.globals.set(state.allocator, .from(.{ .string = try state.newString(name) }), .fromFunction(.{ .closure = closure }));
    return closure;
}
fn run(state: *State, source: []const u8, diagnostic: *?vm.Diagnostic) !usize {
    return vm.run(state, try state.newChunk(try compile(state, source)), diagnostic);
}
fn check(source: []const u8, expected: []const Value) !void {
    var state = try State.init(a);
    defer state.deinit();
    _ = try define(&state, "f", "return ...");
    _ = try define(&state, "none", "return");
    _ = try define(&state, "two", "return 1,2");
    var diagnostic: ?vm.Diagnostic = null;
    try equal(expected.len, try run(&state, source, &diagnostic));
    try equal(expected.len, state.top());
    for (expected, state.stack.items) |wanted, actual| try expect(actual.equal(wanted));
    try equal(@as(usize, 0), state.frames.items.len);
}

test "calls scalar fixed open and parenthesized results adjust without spare nils" {
    try check("return false and unknown()", &.{.from(.{ .boolean = false })});
    try check("return f()", &.{});
    try check(repeated("two() ", 1000) ++ "return 7", &.{.from(.{ .number = 7 })});
    try check("return (none())", &.{.nil});
    try check("return f(1,nil,3,nil)", &.{ .from(.{ .number = 1 }), .nil, .from(.{ .number = 3 }), .nil });
    try check("return 8,two()", &.{ .from(.{ .number = 8 }), .from(.{ .number = 1 }), .from(.{ .number = 2 }) });
    try check("return two(),8", &.{ .from(.{ .number = 1 }), .from(.{ .number = 8 }) });
    try check("local a,b,c=two() return a,b,c", &.{ .from(.{ .number = 1 }), .from(.{ .number = 2 }), .nil });
    try check("local a,b,c=9,two() return a,b,c", &.{ .from(.{ .number = 9 }), .from(.{ .number = 1 }), .from(.{ .number = 2 }) });
    try check("local a,b=1,2 a,b=two() return a,b", &.{ .from(.{ .number = 1 }), .from(.{ .number = 2 }) });
    try check("two() none() return 7", &.{.from(.{ .number = 7 })});
    try check("return two()+3", &.{.from(.{ .number = 4 })});
    try check("return f(none())", &.{});
    try check("return f(two())", &.{ .from(.{ .number = 1 }), .from(.{ .number = 2 }) });
    try check("return f(two(),9)", &.{ .from(.{ .number = 1 }), .from(.{ .number = 9 }) });
    try check("return f(9,two())", &.{ .from(.{ .number = 9 }), .from(.{ .number = 1 }), .from(.{ .number = 2 }) });
    try check("return f((two()))", &.{.from(.{ .number = 1 })});
    try check("local t={8,two()} return t[1],t[2],t[3]", &.{ .from(.{ .number = 8 }), .from(.{ .number = 1 }), .from(.{ .number = 2 }) });
    try check("local t={two(),8} return t[1],t[2],t[3]", &.{ .from(.{ .number = 1 }), .from(.{ .number = 8 }), .nil });
    try check("local t={8,none()} return #t", &.{.from(.{ .number = 1 })});
    try check("return (f{} )[1]", &.{.nil});
    try check("return #(f 'abc')", &.{.from(.{ .number = 3 })});
}

test "calls evaluate receivers and arguments once in source order including methods" {
    var state = try State.init(a);
    defer state.deinit();
    _ = try define(&state, "step", "global n local x=... n=n*10+x return x");
    _ = try define(&state, "f", "return ...");
    const method = try define(&state, "method", "local self,x,y=... return self.v+x+y");
    const object = try state.newTable();
    state.barrier(&object.header);
    try object.set(state.allocator, .from(.{ .string = try state.newString("m") }), .fromFunction(.{ .closure = method }));
    state.barrier(&object.header);
    try object.set(state.allocator, .from(.{ .string = try state.newString("v") }), .from(.{ .number = 5 }));
    state.barrier(&state.globals.header);
    try state.globals.set(state.allocator, .from(.{ .string = try state.newString("object") }), .from(.{ .table = object }));
    _ = try define(&state, "receiver", "global n,object n=n*10+1 return object");
    var diagnostic: ?vm.Diagnostic = null;
    try equal(@as(usize, 4), try run(&state, "n=0 local a,b,c=f(step(1),step(2),step(3)) return n,a,b,c", &diagnostic));
    try expect(state.stack.items[0].equal(.from(.{ .number = 123 })));
    try state.setTop(0);
    try equal(@as(usize, 2), try run(&state, "n=0 local x=receiver():m(step(2),step(3)) return n,x", &diagnostic));
    try expect(state.stack.items[0].equal(.from(.{ .number = 123 })));
    try expect(state.stack.items[1].equal(.from(.{ .number = 10 })));
}

test "calls preserve caller windows live values and callee roots through nested collections" {
    var state = try State.init(a);
    defer state.deinit();
    _ = try define(&state, "f", "local x=... local i=0 while i<100 do local garbage={{}} i=i+1 end return x,nil,x");
    try state.push(.from(.{ .number = 42 }));
    var diagnostic: ?vm.Diagnostic = null;
    state.setCollectionThreshold(0);
    try equal(@as(usize, 4), try run(&state, "local keep={v=9} local x,y,z=f({v=7}) return keep.v,x.v,y,z.v", &diagnostic));
    try equal(@as(usize, 5), state.top());
    for ([_]Value{ .from(.{ .number = 42 }), .from(.{ .number = 9 }), .from(.{ .number = 7 }), .nil, .from(.{ .number = 7 }) }, state.stack.items) |wanted, actual| try expect(actual.equal(wanted));
    try expect(state.object_count < 100);
}

test "calls tail transitions reuse frames while non-tail recursion respects the recorded depth" {
    var state = try State.init(a);
    defer state.deinit();
    _ = try define(&state, "tail", "local n=... if n==0 then return 7,nil end return tail(n-1)");
    var diagnostic: ?vm.Diagnostic = null;
    try equal(@as(usize, 2), try run(&state, "return tail(1000)", &diagnostic));
    try expect(state.stack.items[0].equal(.from(.{ .number = 7 })));
    try expect(state.stack.items[1].is(.nil));
    try state.setTop(0);
    _ = try define(&state, "recursive", "return 1+recursive()");
    try std.testing.expectError(error.CallDepth, run(&state, "return (recursive())", &diagnostic));
    try equal(vm.Diagnostic{ .kind = .call_depth, .position = diagnostic.?.position, .operation = diagnostic.?.operation }, diagnostic.?);
    try equal(@as(usize, 0), state.top());
    try equal(@as(usize, 0), state.frames.items.len);
}

test "calls failures point at argument opening or string end and method indexing at the name" {
    for ([_]struct { source: []const u8, line: usize, operation: std.meta.Tag(@import("bytecode.zig").Instruction.Operation) }{
        .{ .source = "local f=nil\nf\n(1)", .line = 3, .operation = .call },
        .{ .source = "local f=nil\nf\n{}", .line = 3, .operation = .call },
        .{ .source = "local f=nil\nf [[a\r\nb]]", .line = 3, .operation = .call },
        .{ .source = "local t=nil\nt:\nm\n()", .line = 3, .operation = .get },
        .{ .source = "local t={}\nt:m\n()", .line = 3, .operation = .call },
    }) |case| {
        var state = try State.init(a);
        defer state.deinit();
        var diagnostic: ?vm.Diagnostic = null;
        try std.testing.expectError(error.Type, run(&state, case.source, &diagnostic));
        try equal(case.line, diagnostic.?.position.line);
        try equal(case.operation, diagnostic.?.operation);
    }
}

test "calls tail callee survives when only the active frame retains its function" {
    var state = try State.init(a);
    defer state.deinit();
    _ = try define(&state, "f", "global f f=nil local x=... local n=0 while n<100 do local t={{}} n=n+1 end return x");
    var diagnostic: ?vm.Diagnostic = null;
    state.setCollectionThreshold(0);
    try equal(@as(usize, 1), try run(&state, "return f({v=7})", &diagnostic));
    try expect(state.get(1).?.unpack().table.getString("v").equal(.from(.{ .number = 7 })));
    try expect(state.globals.getString("f").is(.nil));
}

fn allocationCase(alloc: std.mem.Allocator, caller: *const @import("Ast.zig"), callee: *const @import("Ast.zig"), identity: *const @import("Ast.zig")) !void {
    var state = try State.init(alloc);
    defer state.deinit();
    var compilation: ?compiler.Diagnostic = null;
    const f = try state.newChunk(try compiler.compile(alloc, &state, callee, "f", &compilation));
    const g = try state.newChunk(try compiler.compile(alloc, &state, identity, "g", &compilation));
    state.barrier(&state.globals.header);
    try state.globals.set(alloc, .from(.{ .string = try state.newString("f") }), .fromFunction(.{ .closure = f }));
    state.barrier(&state.globals.header);
    try state.globals.set(alloc, .from(.{ .string = try state.newString("g") }), .fromFunction(.{ .closure = g }));
    const closure = try state.newChunk(try compiler.compile(alloc, &state, caller, "caller", &compilation));
    try state.push(.from(.{ .number = 42 }));
    var diagnostic: ?vm.Diagnostic = null;
    const count = vm.run(&state, closure, &diagnostic) catch |err| {
        try equal(@as(usize, 1), state.top());
        try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
        try equal(@as(usize, 0), state.frames.items.len);
        return err;
    };
    try equal(@as(usize, 3), count);
    try expect(state.stack.items[1].equal(.from(.{ .number = 8 })));
    try expect(state.stack.items[2].equal(.from(.{ .number = 7 })));
    try expect(state.stack.items[3].is(.nil));
}

test "calls normal tail and open result paths clean every allocation failure" {
    var diagnostic: ?parser.Diagnostic = null;
    var caller = try parser.parseChunk(a, "local x=f(1) return 8,f(0)", &diagnostic);
    defer caller.deinit();
    var callee = try parser.parseChunk(a, "local n=... if n==0 then return 7,nil end return g(n-1)", &diagnostic);
    defer callee.deinit();
    var identity = try parser.parseChunk(a, "return ...", &diagnostic);
    defer identity.deinit();
    try allocation_failures.checkAll(a, allocationCase, .{ &caller, &callee, &identity });
}

fn native(_: *State) callconv(.c) c_int {
    return 0;
}

test "calls native and callable-value invocation succeed in direct and tail position" {
    var state = try State.init(a);
    defer state.deinit();
    state.barrier(&state.globals.header);
    try state.globals.set(state.allocator, .from(.{ .string = try state.newString("f") }), .fromFunction(.{ .native = native }));
    var diagnostic: ?vm.Diagnostic = null;
    try equal(@as(usize, 0), try run(&state, "f()", &diagnostic));
    const table = try state.newTable();
    const metatable = try state.newTable();
    state.barrier(&metatable.header);
    try metatable.set(state.allocator, .from(.{ .string = try state.newString("__call") }), .fromFunction(.{ .native = native }));
    table.metatable = metatable;
    state.barrier(&state.globals.header);
    try state.globals.set(state.allocator, .from(.{ .string = try state.newString("t") }), .from(.{ .table = table }));
    try equal(@as(usize, 0), try run(&state, "t()", &diagnostic));
    try equal(@as(usize, 0), try run(&state, "return t()", &diagnostic));
    try equal(@as(usize, 0), state.top());
}

test "calls malformed operand and open-result protocols fail without indexing invalid registers" {
    const bytecode = @import("bytecode.zig");
    var state = try State.init(a);
    defer state.deinit();
    for ([_]bytecode.Instruction.Operation{
        .{ .call = .{ .base = std.math.maxInt(usize), .arguments = 0, .results = 0 } },
        .{ .call = .{ .base = 0, .arguments = std.math.maxInt(u32), .results = 1 } },
        .{ .call = .{ .base = 0, .arguments = 0, .results = std.math.maxInt(u32) } },
        .{ .tail_call = .{ .base = 0, .arguments = std.math.maxInt(usize) } },
        .{ .move_results = .{ .destination = 2, .source = 1 } },
    }) |operation| {
        const prototype = try state.newProgram(&.{}, &.{.{ .position = .{ .offset = 0, .line = 1, .column = 1 }, .operation = operation }}, 2, "", "invalid");
        try std.testing.expectError(error.InvalidBytecode, vm.validate(prototype));
    }
    for ([_]bytecode.Instruction.Operation{
        .{ .call = .{ .base = 0, .arguments = null, .results = null } },
        .{ .tail_call = .{ .base = 0, .arguments = null } },
        .{ .move_results = .{ .destination = 0, .source = 1 } },
    }) |operation| {
        const prototype = try state.newProgram(&.{}, &.{.{ .position = .{ .offset = 0, .line = 1, .column = 1 }, .operation = operation }}, 2, "", "invalid");
        var diagnostic: ?vm.Diagnostic = null;
        try std.testing.expectError(error.InvalidBytecode, vm.run(&state, try state.newChunk(prototype), &diagnostic));
        try equal(@as(usize, 0), state.top());
    }
}

test "calls captured Lua chunks agree through the compiler and VM" {
    var lines = std.mem.tokenizeScalar(u8, @embedFile("lua55-calls"), '\n');
    var checked: usize = 0;
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const encoded = fields.next().?;
        const count = try std.fmt.parseInt(usize, fields.next().?, 10);
        const expected = fields.next().?;
        try expect(fields.next() == null);
        var buffer: [4096]u8 = undefined;
        const source = try std.fmt.hexToBytes(&buffer, encoded);
        errdefer std.debug.print("call fixture failed: {s}\n", .{source});
        var state = try State.init(a);
        defer state.deinit();
        _ = try define(&state, "f", "return ...");
        _ = try define(&state, "none", "return");
        _ = try define(&state, "two", "return 1,2");
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
                if (std.mem.eql(u8, payload, "nan")) {
                    try expect(std.math.isNan(actual.numberValue().?));
                } else try equal(try std.fmt.parseInt(u64, payload, 16), @as(u64, @bitCast(actual.numberValue().?)));
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
    std.debug.print("call fixture: {d} Lua chunks executed through parser, compiler and VM\n", .{checked});
}

test "calls script recursion stops at 200 frames, the main chunk and pcall counted" {
    // ADR 0009: ordinarily 200 frames. The chunk and pcall take two, so the
    // function recursing gets 198 before the 199th call is refused.
    const api = @import("c_api.zig");
    const state = try api.create(a);
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_openlibs(state));
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state, "local n = 0 local function r() n = n + 1 r() end local ok = pcall(r) return n", "=t", null));
    try std.testing.expectEqual(api.Status.ok, api.nilu_pcall(state, 0, 1, 0));
    try std.testing.expectEqual(@as(f64, 198), api.nilu_tonumberx(state, -1, null));
}
