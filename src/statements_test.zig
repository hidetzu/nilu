const std = @import("std");
const allocation_failures = @import("allocation_failures.zig");
const repeated = @import("repeated_text.zig").repeated;
const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const vm = @import("vm.zig");
const runtime = @import("runtime.zig");
const bytecode = @import("bytecode.zig");
const State = runtime.State;
const Value = runtime.Value;
const allocator = std.testing.allocator;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const Expected = union(enum) { nil, number: f64, boolean: bool, string: []const u8 };

fn compile(state: *State, source: []const u8) !*runtime.Prototype {
    var parse_diagnostic: ?parser.Diagnostic = null;
    var ast = try parser.parseChunk(allocator, source, &parse_diagnostic);
    defer ast.deinit();
    var diagnostic: ?compiler.Diagnostic = null;
    return compiler.compile(allocator, state, &ast, "<statements>", &diagnostic);
}

fn run(state: *State, source: []const u8) !usize {
    const prototype = try compile(state, source);
    const closure = try state.newChunk(prototype);
    var diagnostic: ?vm.Diagnostic = null;
    return vm.run(state, closure, &diagnostic);
}

fn check(source: []const u8, expected: []const Expected) !void {
    var state = try State.init(allocator);
    defer state.deinit();
    try equal(expected.len, try run(&state, source));
    try equal(expected.len, state.top());
    for (expected, state.stack.items) |wanted, actual| switch (wanted) {
        .nil => try expect(actual.is(.nil)),
        .number => |n| try expect(actual.equal(.from(.{ .number = n }))),
        .boolean => |b| try expect(actual.equal(.from(.{ .boolean = b }))),
        .string => |s| {
            try expect(actual.is(.string));
            try std.testing.expectEqualStrings(s, actual.unpack().string.bytes);
        },
    };
    try equal(@as(usize, 0), state.frames.items.len);
}

test "statements local declarations initialize before their names enter scope and pad or discard" {
    try check("local x = 1 local y local a,b = 10,20 return x,y,a,b", &.{ .{ .number = 1 }, .nil, .{ .number = 10 }, .{ .number = 20 } });
    try check("local a,b,c = 1,2 local d,e = 1,2,3 return a,b,c,d,e", &.{ .{ .number = 1 }, .{ .number = 2 }, .nil, .{ .number = 1 }, .{ .number = 2 } });
    try check("local x = 3 local x,y = x+1,x+2 return x,y", &.{ .{ .number = 4 }, .{ .number = 5 } });
    try check("local x=1 local x=2 return x", &.{.{ .number = 2 }});
    try check("local global=8 return global", &.{.{ .number = 8 }});
    try check("local <const> a,b = 1,2 return a,b", &.{ .{ .number = 1 }, .{ .number = 2 } });
}

test "statements names and assignment use temporaries and evaluate discarded values" {
    try check("local a,b = 1,2 a,b = b,a return a,b", &.{ .{ .number = 2 }, .{ .number = 1 } });
    try check("local x=5 x=1+x return x", &.{.{ .number = 6 }});
    try check("local a,b=9,8 a,b=1 return a,b", &.{ .{ .number = 1 }, .nil });
    try check("local a=1 a=2,3 return a", &.{.{ .number = 2 }});
    var state = try State.init(allocator);
    defer state.deinit();
    try std.testing.expectError(error.Type, run(&state, "local a=1 a=2,1+nil return a"));
    try equal(@as(usize, 0), state.top());
    try std.testing.expectError(error.Type, run(&state, "local a=1,1+nil return a"));
}

test "statements global names share the host table and declarations hide earlier locals" {
    try check("g=10 return g,h", &.{ .{ .number = 10 }, .nil });
    try check("local count=0 cuont=count+1 return count,cuont", &.{ .{ .number = 0 }, .{ .number = 1 } });
    try check("global count count=0 count=count+1 return count", &.{.{ .number = 1 }});
    try check("local x=1 global x x=2 return x,_ENV.x", &.{ .{ .number = 2 }, .{ .number = 2 } });
    try check("local x=1 global * x=2 return x,_ENV.x", &.{ .{ .number = 2 }, .nil });
    var state = try State.init(allocator);
    defer state.deinit();
    state.barrier(&state.globals.header);
    try state.globals.set(allocator, .from(.{ .string = try state.newString("host") }), .from(.{ .number = 17 }));
    try equal(@as(usize, 2), try run(&state, "copied=host+1 return host,copied"));
    try expect(state.globals.getString("copied").equal(.from(.{ .number = 18 })));
}

test "statements block branches and loops restore lexical bindings" {
    try check("local x='outer' do local x='inner' end return x", &.{.{ .string = "outer" }});
    try check("do local y=1 end return y", &.{.nil});
    try check("local n=2 local x=0 if n==1 then local n=8 x=1 elseif n==2 then local n=9 x=n else x=3 end return n,x", &.{ .{ .number = 2 }, .{ .number = 9 } });
    try check("if false then return 1 elseif true then return 2 else return 3 end", &.{.{ .number = 2 }});
    try check("local x=0 if nil then x=1 end if 0 then x=x+2 end if '' then x=x+3 end return x", &.{.{ .number = 5 }});
    try check("do global x x=1 end y=2 return x,y", &.{ .{ .number = 1 }, .{ .number = 2 } });
    try check("local x=0 if false then local y=1+nil else x=7 end return x", &.{.{ .number = 7 }});
}

test "statements while loops return and nested break leave only their owning loop" {
    try check("local i=0 while i<3 do i=i+1 end return i", &.{.{ .number = 3 }});
    try check("local i=0 while false do i=i+1 end return i", &.{.{ .number = 0 }});
    try check("local i,n=0,0 while i<3 do i=i+1 while true do n=n+1 break n=99 end end return i,n", &.{ .{ .number = 3 }, .{ .number = 3 } });
    try check("local i=0 while true do do local x=4 if x==4 then break end end i=99 end return i", &.{.{ .number = 0 }});
    try check("while true do local x=3 return x end", &.{.{ .number = 3 }});
    try check("local n=0 while n<3 do local x n=n+1 if x~=nil then return 99 end x=2 end return n", &.{.{ .number = 3 }});
}

test "statements repeat conditions see body locals and repeat iterations clear them" {
    try check("local n=0 repeat n=n+1 local done=n>=3 until done return n", &.{.{ .number = 3 }});
    try check("local n=0 repeat n=n+1 until true return n", &.{.{ .number = 1 }});
    try check("local n=0 repeat local x n=n+1 if x~=nil then return 99 end x=3 until n==3 return n,x", &.{ .{ .number = 3 }, .nil });
    try check("local n=0 repeat do local x=8 if x==8 then break end end n=99 until false return n", &.{.{ .number = 0 }});
    try check("local n=0 while n<3 do repeat n=n+1 break until false end return n", &.{.{ .number = 3 }});
    try check("local x=0 repeat local x=1 until x==1 return x", &.{.{ .number = 0 }});
}

test "statements ENV shadowing selects a table without changing the host globals" {
    try check("x=1 local root=_ENV local _ENV={} x=2 return x,root.x", &.{ .{ .number = 2 }, .{ .number = 1 } });
    try check("x=1 local root=_ENV do local _ENV={x=3} x=4 end return x,root.x", &.{ .{ .number = 1 }, .{ .number = 1 } });
    try check("local _ENV <const> = {} x=5 return x", &.{.{ .number = 5 }});
    try check("global x local _ENV={} x=3 return x", &.{.{ .number = 3 }});
    var state = try State.init(allocator);
    defer state.deinit();
    try equal(@as(usize, 1), try run(&state, "_ENV={x=7} return x"));
    try expect(state.globals.getString("x").is(.nil));
}

test "statements each loaded chunk owns an ENV cell shared across its repeated runs" {
    var state = try State.init(allocator);
    defer state.deinit();
    const prototype = try compile(&state, "local old=x _ENV={x=(x or 0)+1} return old,x");
    try equal(@as(usize, 1), prototype.upvalue_count);
    const first = try state.newChunk(prototype);
    const second = try state.newChunk(prototype);
    try expect(first.upvalues[0] != second.upvalues[0]);
    // Keep both closures rooted even after a run returns and direct GC occurs.
    try state.push(.fromFunction(.{ .closure = first }));
    try state.push(.fromFunction(.{ .closure = second }));
    var diagnostic: ?vm.Diagnostic = null;
    try equal(@as(usize, 2), try vm.run(&state, first, &diagnostic));
    try expect(state.get(-2).?.is(.nil));
    try expect(state.get(-1).?.equal(.from(.{ .number = 1 })));
    try state.setTop(2);
    state.collect();
    try equal(@as(usize, 2), try vm.run(&state, first, &diagnostic));
    try expect(state.get(-2).?.equal(.from(.{ .number = 1 })));
    try expect(state.get(-1).?.equal(.from(.{ .number = 2 })));
    try state.setTop(2);
    try equal(@as(usize, 2), try vm.run(&state, second, &diagnostic));
    try expect(state.get(-2).?.is(.nil));
    try expect(state.get(-1).?.equal(.from(.{ .number = 1 })));
    try expect(state.globals.getString("x").is(.nil));
}

test "statements global initializers guard existing values and store the last name first" {
    try check("global a,b=1,2 return a,b", &.{ .{ .number = 1 }, .{ .number = 2 } });
    try check("global a,b=1 return a,b", &.{ .{ .number = 1 }, .nil });
    try check("local x=3 global x=x+1 return x", &.{.{ .number = 4 }});
    try check("global x <const> = 3 return x", &.{.{ .number = 3 }});
    var state = try State.init(allocator);
    defer state.deinit();
    const prototype = try compile(&state, "x=5\nglobal x,y\n=\n 10,20");
    var diagnostic: ?vm.Diagnostic = null;
    try std.testing.expectError(error.Runtime, vm.run(&state, try state.newChunk(prototype), &diagnostic));
    try expect(diagnostic.?.kind == .global_already_defined);
    try equal(@as(usize, 4), diagnostic.?.position.line);
    try expect(state.globals.getString("x").equal(.from(.{ .number = 5 })));
    try expect(state.globals.getString("y").equal(.from(.{ .number = 20 })));
    try equal(@as(usize, 0), state.top());
    try equal(@as(usize, 0), state.frames.items.len);
    try std.testing.expectError(error.Runtime, run(&state, "global z,z=1,2"));
    try expect(state.globals.getString("z").equal(.from(.{ .number = 2 })));
}

test "statements long flat blocks reuse scope registers and elseif arms stay iterative" {
    try check(repeated("do local x=1 end ", 2000) ++ "return 7", &.{.{ .number = 7 }});
    try check("local x=0 if false then x=99 " ++ repeated("elseif false then x=99 ", 1000) ++ "else x=8 end return x", &.{.{ .number = 8 }});
    var state = try State.init(allocator);
    defer state.deinit();
    const prototype = try compile(&state, repeated("do local x=1 end ", 2000));
    try expect(prototype.registers < 5);
}

test "statements GC traces changing ENV cells and reclaims prior loop iterations" {
    var state = try State.init(allocator);
    defer state.deinit();
    const prototype = try compile(&state, "local i=0 while i<300 do i=i+1 _ENV={x=i} do local junk={} end end return x");
    const closure = try state.newChunk(prototype);
    state.setCollectionThreshold(0);
    var diagnostic: ?vm.Diagnostic = null;
    try equal(@as(usize, 1), try vm.run(&state, closure, &diagnostic));
    try expect(state.get(-1).?.equal(.from(.{ .number = 300 })));
    try expect(state.object_count <= state.collection_threshold);
    try expect(state.readCell(closure.upvalues[0]).unpack().table.getString("x").equal(.from(.{ .number = 300 })));
    try expect(state.globals.getString("x").is(.nil));
}

fn objectsAfterRun(lowered: bool) !usize {
    var state = try State.init(allocator);
    defer state.deinit();
    const prototype = try compile(&state, "return 1");
    const closure = try state.newChunk(prototype);
    // Unreachable tables, with the object count still below the default
    // threshold: only a lowered threshold makes the first step collect them.
    _ = try state.newTable();
    _ = try state.newTable();
    try expect(state.object_count < 64);
    if (lowered) state.setCollectionThreshold(0);
    var diagnostic: ?vm.Diagnostic = null;
    try equal(@as(usize, 1), try vm.run(&state, closure, &diagnostic));
    return state.object_count;
}

test "statements a lowered collection threshold collects before the next step" {
    try equal(try objectsAfterRun(false) - 2, try objectsAfterRun(true));
}

// Allocation alone brings the next collection: each new object uses up the
// room below the threshold that the frame loop tests before each step.
test "statements objects made by a running program bring a collection when they pass the threshold" {
    var state = try State.init(allocator);
    defer state.deinit();
    const before = state.object_count;
    _ = try run(&state, "for i = 1, 10000 do local t = {} end");
    try expect(state.object_count < before + 1000);
}

test "statements static failures remain syntax errors before any program is published" {
    var state = try State.init(allocator);
    defer state.deinit();
    for ([_][]const u8{
        "local x <const> = 1 x=2",                   "global x <const> x=1", "global x y=1",
        "global _ENV global x=1",                    "break",                "local f=function() break end",
        "global * do goto l global x ::l:: x=8 end",
    }) |source| {
        try std.testing.expectError(error.Syntax, compile(&state, source));
        try expect(state.prototypes == null);
    }
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
        try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
        return err;
    };
    try expect(state.get(-1).?.equal(.from(.{ .number = 5 })));
}

test "statements allocation failures clean binding loop and environment storage" {
    const source = "global total=0 local n=0 repeat n=n+1 do local x={} end if n==2 then total=total+3 elseif n==3 then break else total=total+2 end until n>4 return total";
    var parse_diagnostic: ?parser.Diagnostic = null;
    var ast = try parser.parseChunk(allocator, source, &parse_diagnostic);
    defer ast.deinit();
    try allocation_failures.checkAll(allocator, allocationCase, .{&ast});
}

test "statements newly added bytecode validates all operand ranges and frame upvalue counts" {
    var state = try State.init(allocator);
    defer state.deinit();
    const pos = @import("Token.zig").Position{ .offset = 0, .line = 1, .column = 1 };
    const invalid = [_]bytecode.Instruction.Operation{
        .{ .move = .{ .destination = 0, .source = 1 } },
        .{ .get_upvalue = .{ .destination = 0, .index = 0 } },
        .{ .set_upvalue = .{ .source = 0, .index = 0 } },
        .{ .jump = .{ .target = 9 } },
        .{ .scope_exit = 2 },
        .{ .init_global = .{ .environment = 0, .key = 1, .value = 0 } },
        .{ .table = .{ .destination = 0, .fields = 1, .template = 0 } },
    };
    // Each program ends in a return, so that the only thing wrong with it is
    // the operand under test: a program whose last instruction could fall off
    // the end is refused whatever its operands are.
    for (invalid) |operation| {
        const prototype = try state.newProgram(&.{}, &.{
            .{ .position = pos, .operation = operation },
            .{ .position = pos, .operation = .{ .returns = .{ .first = 0, .count = 0 } } },
        }, 1, "", "invalid");
        try std.testing.expectError(error.InvalidBytecode, vm.validate(prototype));
    }
    const prototype = try compile(&state, "return _ENV");
    var diagnostic: ?vm.Diagnostic = null;
    try std.testing.expectError(error.InvalidBytecode, vm.run(&state, try state.newClosure(prototype, &.{}), &diagnostic));
    prototype.upvalue_count = 2;
    try std.testing.expectError(error.InvalidPrototype, state.newChunk(prototype));
}

// The same program with and without a template index past the prototype's
// templates: only the index is refused, so the refusal is the index's.
test "statements a table instruction's template index is validated" {
    var state = try State.init(allocator);
    defer state.deinit();
    const pos = @import("Token.zig").Position{ .offset = 0, .line = 1, .column = 1 };
    for ([_]u32{ bytecode.no_cache, 0 }) |template| {
        const prototype = try state.newProgram(&.{}, &.{
            .{ .position = pos, .operation = .{ .table = .{ .destination = 0, .fields = 1, .template = template } } },
            .{ .position = pos, .operation = .{ .returns = .{ .first = 0, .count = 0 } } },
        }, 1, "", "template");
        if (template == bytecode.no_cache) try vm.validate(prototype) else try std.testing.expectError(error.InvalidBytecode, vm.validate(prototype));
    }
}

// `s + t[i]` with `s` a local no closure can capture reads `s` where it is:
// nothing is copied before the right operand is evaluated.
test "statements a left local no closure captures is not copied before its right operand" {
    var state = try State.init(allocator);
    defer state.deinit();
    const without = try compile(&state, "local s, t = 0, {1} s = s + t[1] return s");
    const with = try compile(&state, "local s, t = 0, {1} local f = function() return s end s = s + t[1] return s");
    var moves = [2]usize{ 0, 0 };
    for ([_]*runtime.Prototype{ without, with }, &moves) |prototype, *count| {
        for (prototype.code) |instruction| if (instruction.operation == .move) {
            count.* += 1;
        };
    }
    try std.testing.expectEqual(@as(usize, 0), moves[0]);
    try std.testing.expect(moves[1] > 0);
}

// A numeric `for` whose body holds a function, at any depth, keeps the arm
// that closes the control variable's cell each turn; one without takes the
// arm that looks for no cell.
test "statements a numeric for says whether its body can capture its variable" {
    var state = try State.init(allocator);
    defer state.deinit();
    const sources = [_]struct { []const u8, bool }{
        .{ "local s = 0 for i = 1, 3 do s = s + i end return s", false },
        .{ "local f for i = 1, 3 do if i > 1 then f = function() return i end end end return f()", true },
        .{ "local t = {} for i = 1, 3 do t[i] = {g = function() return i end} end return t[1].g()", true },
        .{ "for i = 1, 3 do local function f() end end", true },
    };
    for (sources) |entry| {
        const prototype = try compile(&state, entry[0]);
        var found = false;
        for (prototype.code) |instruction| if (instruction.operation == .for_loop) {
            try std.testing.expectEqual(entry[1], instruction.operation.for_loop.captures);
            found = true;
        };
        try std.testing.expect(found);
    }
}

test "statements captured Lua chunks agree through the compiler and VM" {
    var lines = std.mem.tokenizeScalar(u8, @embedFile("lua55-statements"), '\n');
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
        errdefer std.debug.print("statement fixture failed: {s}\n", .{source});
        var state = try State.init(allocator);
        defer state.deinit();
        try equal(count, try run(&state, source));
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
    std.debug.print("statement fixture: {d} Lua chunks executed through parser, compiler and VM\n", .{checked});
}

test "statements scope exit leaves dead registers as they are and local-count guards remain pending" {
    var state = try State.init(allocator);
    defer state.deinit();
    const pos = @import("Token.zig").Position{ .offset = 0, .line = 1, .column = 1 };
    const prototype = try state.newProgram(&.{.from(.{ .number = 9 })}, &.{
        .{ .position = pos, .operation = .{ .constant = .{ .destination = 0, .index = 0 } } },
        .{ .position = pos, .operation = .{ .scope_exit = 0 } },
        .{ .position = pos, .operation = .{ .returns = .{ .first = 0, .count = 1 } } },
    }, 1, "", "scope");
    var diagnostic: ?vm.Diagnostic = null;
    _ = try vm.run(&state, try state.newChunk(prototype), &diagnostic);
    // A register keeps its value until written (ADR 0005): a scope's exit
    // closes cells and clears nothing.
    try expect(state.get(-1).?.equal(.from(.{ .number = 9 })));
    _ = try compile(&state, repeated("local x=1 ", 200) ++ "return x");
    try std.testing.expectError(error.Syntax, compile(&state, repeated("local x=1 ", 201)));
}

test "statements repeat condition retains locals until the decision" {
    // The extra break keeps a broken compiler from making this regression hang.
    try check("local n=0 repeat n=n+1 local done=n>=3 if n>=5 then break end until done return n", &.{.{ .number = 3 }});
}
