const std = @import("std");
const allocation_failures = @import("allocation_failures.zig");
const repeated = @import("repeated_text.zig").repeated;
const runtime = @import("runtime.zig");
const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const vm = @import("vm.zig");
const bytecode = @import("bytecode.zig");
const State = runtime.State;
const Value = runtime.Value;
const allocator = std.testing.allocator;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const Expected = union(enum) { number: f64, boolean: bool, nil };

fn compile(state: *State, source: []const u8) !*runtime.Prototype {
    var parse_diagnostic: ?parser.Diagnostic = null;
    var ast = try parser.parseChunk(allocator, source, &parse_diagnostic);
    defer ast.deinit();
    var diagnostic: ?compiler.Diagnostic = null;
    return compiler.compile(allocator, state, &ast, "<goto>", &diagnostic);
}

fn run(state: *State, source: []const u8, diagnostic: *?vm.Diagnostic) !usize {
    const prototype = try compile(state, source);
    return vm.run(state, try state.newChunk(prototype), diagnostic);
}

fn check(source: []const u8, expected: []const Expected) !void {
    var state = try State.init(allocator);
    defer state.deinit();
    var diagnostic: ?vm.Diagnostic = null;
    try equal(expected.len, try run(&state, source, &diagnostic));
    try equal(expected.len, state.top());
    for (expected, state.stack.items) |wanted, actual| switch (wanted) {
        .number => |n| try expect(actual.equal(.from(.{ .number = n }))),
        .boolean => |b| try expect(actual.equal(.from(.{ .boolean = b }))),
        .nil => try expect(actual.is(.nil)),
    };
    try equal(@as(usize, 0), state.frames.items.len);
}

test "goto executes forward backward outward and sibling labels independently" {
    try check("local x=1 goto done x=99 ::done:: return x", &.{.{ .number = 1 }});
    try check("local n=0 ::again:: n=n+1 if n<4 then goto again end return n", &.{.{ .number = 4 }});
    try check("local n=0 do local x=9 do local y=8 n=x+y goto out end end ::out:: return n", &.{.{ .number = 17 }});
    try check("local n=0 do goto a n=99 ::a:: n=n+1 end do goto a n=99 ::a:: n=n+2 end return n", &.{.{ .number = 3 }});
    try check("local n=0 do goto a ::a:: n=2 end ::a:: return n", &.{.{ .number = 2 }});
}

test "goto terminal labels bypass declarations while repeat retains condition locals" {
    try check("local n=1 do goto done local x=1+nil ::done:: ; ::also:: ;; end return n", &.{.{ .number = 1 }});
    try check("goto done local x=1+nil ::done::", &.{});
    try check("local n=0 repeat local done=n==2 n=n+1 goto condition n=99 ::condition:: until done return n", &.{.{ .number = 3 }});
    try check("local n=0 for i=1,4 do if i==2 then goto continue end local x=i n=n+x ::continue:: end return n", &.{.{ .number = 8 }});
    try check("local n=0 while n<3 do n=n+1 goto continue local x=1+nil ::continue:: end return n", &.{.{ .number = 3 }});
}

test "goto clears reused local slots preserves enclosing state and exits loops" {
    try check("local n=0 ::again:: local x if x~=nil then return 99 end x={} n=n+1 if n<5 then goto again end return n", &.{.{ .number = 5 }});
    try check("local x=7 local n=0 ::again:: do local x=99 n=n+1 if n<3 then goto again end end return x,n", &.{ .{ .number = 7 }, .{ .number = 3 } });
    try check("local n=0 for i=1,9 do repeat do local x={} n=i goto out end until false end ::out:: local x return n,x", &.{ .{ .number = 1 }, .nil });
    try check("local n=0 ::again:: local _ENV={x=8} n=n+1 if n<3 then goto again end return n,x", &.{ .{ .number = 3 }, .{ .number = 8 } });
    try check("global * local n=0 do global x=3 n=x goto out end ::out:: return n", &.{.{ .number = 3 }});
}

test "goto retains static scope refusals before publication" {
    for ([_][]const u8{
        "goto missing",                              "goto x do ::x:: end",                      "::x:: do ::x:: end",
        "goto x local a=1 ::x:: return a",           "repeat goto x local a=1 ::x:: until true", "do goto x end local a=1 ::x:: return a",
        "global * do goto l global x ::l:: x=8 end", "::x:: local f=function() goto x end",
    }) |source| {
        var state = try State.init(allocator);
        defer state.deinit();
        try std.testing.expectError(error.Syntax, compile(&state, source));
        try expect(state.prototypes == null);
    }
}

fn allocationCase(a: std.mem.Allocator, ast: *const @import("Ast.zig")) !void {
    var state = try State.init(a);
    defer state.deinit();
    var diagnostic: ?compiler.Diagnostic = null;
    const prototype = try compiler.compile(a, &state, ast, "<goto-allocation>", &diagnostic);
    var failure: ?vm.Diagnostic = null;
    try equal(@as(usize, 1), try vm.run(&state, try state.newChunk(prototype), &failure));
    try expect(state.stack.items[0].equal(.from(.{ .number = 3 })));
}

test "goto lowering and execution reclaim every allocation failure" {
    var diagnostic: ?parser.Diagnostic = null;
    var ast = try parser.parseChunk(allocator, "local n=0 ::again:: do local x={} n=n+1 if n<3 then goto again end goto done end ::done:: return n", &diagnostic);
    defer ast.deinit();
    try allocation_failures.checkAll(allocator, allocationCase, .{&ast});
}

test "goto long flat label sequences lower iteratively" {
    try check("goto done " ++ repeated("do ::same:: end ", 1000) ++ "::done:: return 8", &.{.{ .number = 8 }});
}

test "goto bytecode closes to label level before jumping including terminal labels" {
    for ([_][]const u8{
        "local keep=7 ::again:: local dropped=8 goto again",
        "local keep=7 do goto done local dropped=8 ::done:: end",
    }) |source| {
        var state = try State.init(allocator);
        defer state.deinit();
        const prototype = try compile(&state, source);
        var found = false;
        for (prototype.code, 0..) |instruction, pc| {
            if (!std.mem.startsWith(u8, source[instruction.info.position.offset..], "goto ") or instruction.operation != .jump) continue;
            found = true;
            try expect(pc > 0);
            // Keep the hidden vararg table and the source local.
            try equal(@as(usize, 2), prototype.code[pc - 1].operation.scope_exit);
            try equal(instruction.info.position, prototype.code[pc - 1].info.position);
            try expect(instruction.operation.jump.target < prototype.code.len);
        }
        try expect(found);
    }
}

test "goto allocation heavy backward jumps collect and retain live values and caller slots" {
    var state = try State.init(allocator);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    var failure: ?vm.Diagnostic = null;
    try equal(@as(usize, 2), try run(&state, "local keep={v=9} local n=0 ::again:: local garbage={a={b=n}} n=n+1 if n<300 then goto again end return keep.v,n", &failure));
    try equal(@as(usize, 3), state.top());
    try expect(state.stack.items[0].equal(.from(.{ .number = 42 })));
    try expect(state.stack.items[1].equal(.from(.{ .number = 9 })));
    try expect(state.stack.items[2].equal(.from(.{ .number = 300 })));
    // The body allocates more than 600 tables; a small surviving graph
    // demonstrates that VM safepoints actually collected unreachable turns.
    // A young collection keeps what is alive at its moment until a full one
    // (ADR 0006), so the bound is a third of what was made, not a count of
    // the live graph.
    try expect(state.object_count < 200);
    try equal(@as(usize, 0), state.frames.items.len);
}
