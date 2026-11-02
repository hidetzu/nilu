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
    return compiler.compile(allocator, state, &ast, "<numeric-for>", &diagnostic);
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

test "numeric_for inclusive bounds direction fractional and empty ranges" {
    try check("local n,s=0,0 for i=1,3 do n=n+1 s=s+i end return n,s", &.{ .{ .number = 3 }, .{ .number = 6 } });
    try check("local n=0 for i=1,1 do n=n+1 end return n", &.{.{ .number = 1 }});
    try check("local n=0 for i=1,0 do n=n+1 end return n", &.{.{ .number = 0 }});
    try check("local n,s=0,0 for i=3,1,-1 do n=n+1 s=s+i end return n,s", &.{ .{ .number = 3 }, .{ .number = 6 } });
    try check("local n=0 for i=1,3,-1 do n=n+1 end return n", &.{.{ .number = 0 }});
    try check("local n,s=0,0 for i=1,2,0.5 do n=n+1 s=s+i end return n,s", &.{ .{ .number = 3 }, .{ .number = 4.5 } });
}

test "numeric_for evaluates bounds once before the control variable enters scope" {
    try check("local start,limit,step=1,3,1 local n=0 for i=start,limit,step do n=n+1 start=99 limit=0 step=0 end return n,start,limit,step", &.{ .{ .number = 3 }, .{ .number = 99 }, .{ .number = 0 }, .{ .number = 0 } });
    try check("local i=40 local sum=0 for i=i,i+2 do sum=sum+i end return i,sum", &.{ .{ .number = 40 }, .{ .number = 123 } });
    try check("local n=0 for i=1,2 do n=n+1 end return n,i", &.{ .{ .number = 2 }, .nil });
    try check("local sum=0 for _ENV=1,3 do sum=sum+_ENV end return sum", &.{.{ .number = 6 }});
}

test "numeric_for control shadowing and per-turn locals do not clobber hidden state" {
    try check("local n,sum=0,0 for i=1,3 do local i=99 n=n+1 sum=sum+i end return n,sum", &.{ .{ .number = 3 }, .{ .number = 297 } });
    try check("local n=0 for i=1,3 do local x if x~=nil then return 99 end x=i n=n+1 end return n", &.{.{ .number = 3 }});
    try check("local n=0 for i=1,3 do global i i=99 n=n+1 end return n,i", &.{ .{ .number = 3 }, .{ .number = 99 } });
    for ([_][]const u8{ "for i=1,3 do i=9 end", "for i=1,3 do local f=function() i=9 end end", "for i=1,3 do function i() end end" }) |source| {
        var state = try State.init(allocator);
        defer state.deinit();
        try std.testing.expectError(error.Syntax, compile(&state, source));
        try expect(state.prototypes == null);
    }
}

test "numeric_for break return and nested loops keep the correct enclosing state" {
    try check("local n=0 for i=1,3 do for j=1,2 do n=n+i*j end end return n", &.{.{ .number = 18 }});
    try check("local n=0 for i=1,3 do for j=1,9 do n=n+1 break end end return n", &.{.{ .number = 3 }});
    try check("local n=0 for i=1,3 do do local x={} if i==2 then break end end n=n+1 end return n", &.{.{ .number = 1 }});
    try check("for i=1,3 do if i==2 then return i end end", &.{.{ .number = 2 }});
    try check("local n=0 repeat for i=1,3 do n=n+1 break end until n==2 return n", &.{.{ .number = 2 }});
    try check("local n=0 for i=1,3 do repeat n=n+1 break until false end return n", &.{.{ .number = 3 }});
    try check("local n=0 for i=1,3 do while true do n=n+1 break end end return n", &.{.{ .number = 3 }});
}

fn typeFailure(source: []const u8, argument: vm.ForArgument, kind: @import("runtime.zig").Type) !void {
    var state = try State.init(allocator);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    var diagnostic: ?vm.Diagnostic = null;
    try std.testing.expectError(error.Type, run(&state, source, &diagnostic));
    try equal(vm.Diagnostic{ .kind = .for_not_number, .position = diagnostic.?.position, .operation = .for_prepare, .operand_type = kind, .for_argument = argument }, diagnostic.?);
    try equal(@as(usize, 1), state.top());
    try expect(state.get(-1).?.equal(.from(.{ .number = 42 })));
    try equal(@as(usize, 0), state.frames.items.len);
}

test "numeric_for preparation validates limit then step then initial without coercion" {
    try typeFailure("for i=nil,false,{} do end", .limit, .boolean);
    try typeFailure("for i=nil,3,{} do end", .step, .table);
    try typeFailure("for i=nil,3,0 do end", .initial, .nil);
    try typeFailure("for i='1',3,1 do end", .initial, .string);
    try typeFailure("for i=1,'3',1 do end", .limit, .string);
    try typeFailure("for i=1,3,'1' do end", .step, .string);
    var state = try State.init(allocator);
    defer state.deinit();
    var diagnostic: ?vm.Diagnostic = null;
    try std.testing.expectError(error.Type, run(&state, "for i=1+nil,false,false do end", &diagnostic));
    try expect(diagnostic.?.operation == .binary);
    try expect(diagnostic.?.for_argument == null);
}

test "numeric_for zero steps fail at do and preserve earlier effects and caller slots" {
    var state = try State.init(allocator);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    for ([_][]const u8{ "mark=7 for i=1,3,0 do mark=9 end", "mark=7 for i=1,3,-0.0 do mark=9 end" }) |source| {
        var diagnostic: ?vm.Diagnostic = null;
        try std.testing.expectError(error.Runtime, run(&state, source, &diagnostic));
        try expect(diagnostic.?.kind == .for_step_zero);
        try expect(diagnostic.?.for_argument.? == .step);
        try expect(state.globals.getString("mark").equal(.from(.{ .number = 7 })));
        try equal(@as(usize, 1), state.top());
        try expect(state.get(-1).?.equal(.from(.{ .number = 42 })));
        try equal(@as(usize, 0), state.frames.items.len);
    }
    var diagnostic: ?vm.Diagnostic = null;
    try std.testing.expectError(error.Runtime, run(&state, "for i=1,\n3,\n0\n  do\nend", &diagnostic));
    try equal(@as(usize, 4), diagnostic.?.position.line);
    try equal(@as(usize, 3), diagnostic.?.position.column);
    try std.testing.expectError(error.Type, run(&state, "for i=1,\nfalse\n  do\nend", &diagnostic));
    try equal(@as(usize, 3), diagnostic.?.position.line);
}

test "numeric_for NaNs and infinities follow strict preparation and inclusive continuation" {
    try check("local nan=0/0 local n=0 local last for i=nan,3,1 do n=n+1 last=i end return n,last~=last", &.{ .{ .number = 1 }, .{ .boolean = true } });
    // An integer loop skips a NaN limit, as lua5.5's forlimit does
    //.
    try check("local nan=0/0 local n=0 local last for i=1,nan,1 do n=n+1 last=i end return n,last", &.{ .{ .number = 0 }, .nil });
    try check("local nan=0/0 local n=0 local last for i=3,1,nan do n=n+1 last=i end return n,last", &.{ .{ .number = 1 }, .{ .number = 3 } });
    try check("local nan=0/0 local n=0 for i=1,3,nan do n=n+1 end return n", &.{.{ .number = 0 }});
    try check("local n=0 local last for i=1,5,1/0 do n=n+1 last=i end return n,last", &.{ .{ .number = 1 }, .{ .number = 1 } });
    try check("local n=0 local last for i=5,1,-1/0 do n=n+1 last=i end return n,last", &.{ .{ .number = 1 }, .{ .number = 5 } });
    try check("local n=0 for i=1/0,5,1 do n=n+1 end return n", &.{.{ .number = 0 }});
    try check("local n=0 local last for i=-1/0,0,1/0 do n=n+1 last=i end return n,last==-1/0", &.{ .{ .number = 1 }, .{ .boolean = true } });
    // The bounds intentionally permit endless float loops; the body stops them.
    try check("local n=0 for i=1,1/0,1 do n=n+1 if n==3 then break end end return n", &.{.{ .number = 3 }});
    try check("local n=0 for i=1/0,1/0,1 do n=n+1 if n==3 then break end end return n", &.{.{ .number = 3 }});
}

test "numeric_for float counters retain signed zero and can stagnate at large magnitudes" {
    var state = try State.init(allocator);
    defer state.deinit();
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(&state, "local first for i=-0.0,0.0,1 do first=i end return first", &diagnostic);
    try equal(@as(u64, 1) << 63, @as(u64, @bitCast(state.get(-1).?.numberValue().?)));
    // Integer bounds make an integer loop, which counts past 2^53 exactly,
    // as lua5.5's.
    try check("local n,last=0,0 for i=9007199254740992,9007199254740994,1 do n=n+1 last=i if n==3 then break end end return n,last", &.{ .{ .number = 3 }, .{ .number = 9007199254740994 } });
}

test "numeric_for GC protects surrounding and body values during repeated execution" {
    var state = try State.init(allocator);
    defer state.deinit();
    const prototype = try compile(&state, "local kept={value=7} local n=0 for i=1,300 do local t={kept=kept} n=n+t.kept.value end return n,kept.value");
    const closure = try state.newChunk(prototype);
    state.setCollectionThreshold(0);
    var diagnostic: ?vm.Diagnostic = null;
    try equal(@as(usize, 2), try vm.run(&state, closure, &diagnostic));
    try expect(state.get(-2).?.equal(.from(.{ .number = 2100 })));
    try expect(state.get(-1).?.equal(.from(.{ .number = 7 })));
    try expect(state.object_count <= state.collection_threshold);
}

test "numeric_for validates register triples targets and unprepared loop operands" {
    var state = try State.init(allocator);
    defer state.deinit();
    const position = @import("Token.zig").Position{ .offset = 0, .line = 1, .column = 1 };
    for ([_]bytecode.Instruction.Operation{
        .{ .for_prepare = .{ .base = 1, .target = 0 } },
        .{ .for_loop = .{ .base = std.math.maxInt(usize), .target = 0 } },
        .{ .for_prepare = .{ .base = 0, .target = 9 } },
        .{ .for_loop = .{ .base = 0, .target = 9 } },
    }) |operation| {
        const prototype = try state.newProgram(&.{}, &.{.{ .position = position, .operation = operation }}, 3, "", "invalid");
        try std.testing.expectError(error.InvalidBytecode, vm.validate(prototype));
    }
    const prototype = try state.newProgram(&.{}, &.{
        .{ .position = position, .operation = .{ .for_loop = .{ .base = 0, .target = 0 } } },
        .{ .position = position, .operation = .{ .returns = .{ .first = 0, .count = 0 } } },
    }, 3, "", "unprepared");
    var diagnostic: ?vm.Diagnostic = null;
    try std.testing.expectError(error.InvalidBytecode, vm.run(&state, try state.newChunk(prototype), &diagnostic));
    try equal(@as(usize, 0), state.top());
    try equal(@as(usize, 0), state.frames.items.len);
}

fn allocationCase(failing: std.mem.Allocator, ast: *const @import("Ast.zig")) !void {
    var state = try State.init(failing);
    defer state.deinit();
    var compile_diagnostic: ?compiler.Diagnostic = null;
    const prototype = try compiler.compile(failing, &state, ast, "allocation", &compile_diagnostic);
    const closure = try state.newChunk(prototype);
    try state.push(.from(.{ .number = 42 }));
    var diagnostic: ?vm.Diagnostic = null;
    _ = vm.run(&state, closure, &diagnostic) catch |err| {
        try equal(@as(usize, 1), state.top());
        try equal(@as(usize, 0), state.frames.items.len);
        try expect(state.get(-1).?.equal(.from(.{ .number = 42 })));
        return err;
    };
    try expect(state.get(-1).?.equal(.from(.{ .number = 2 })));
}

test "numeric_for allocation failures release partial compiler and runtime storage" {
    var parse_diagnostic: ?parser.Diagnostic = null;
    var ast = try parser.parseChunk(allocator, "local n=0 for i=1,3 do local t={i=i} n=n+1 if i==2 then break end end return n", &parse_diagnostic);
    defer ast.deinit();
    try allocation_failures.checkAll(allocator, allocationCase, .{&ast});
}

test "numeric_for flat loops restore registers and count three slots toward the local limit" {
    try check(repeated("for i=1,1 do end ", 1000) ++ "return 7", &.{.{ .number = 7 }});
    var state = try State.init(allocator);
    defer state.deinit();
    const prototype = try compile(&state, repeated("for i=1,1 do end ", 1000));
    // Three loop registers plus the hidden chunk vararg table.
    try expect(prototype.registers <= 4);
    _ = try compile(&state, repeated("local x=1 ", 197) ++ "for i=1,1 do end return x");
    try std.testing.expectError(error.Syntax, compile(&state, repeated("local x=1 ", 198) ++ "for i=1,1 do end"));
}
