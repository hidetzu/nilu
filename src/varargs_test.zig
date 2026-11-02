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
const api = @import("c_api.zig");
const a = std.testing.allocator;

const Item = union(enum) { nil, number: f64, boolean: bool, string: []const u8 };

fn compile(state: *State, source: []const u8) !*runtime.Prototype {
    var parse_diagnostic: ?parser.Diagnostic = null;
    var ast = try parser.parseChunk(allocator, source, &parse_diagnostic);
    defer ast.deinit();
    var diagnostic: ?compiler.Diagnostic = null;
    return compiler.compile(allocator, state, &ast, "<varargs>", &diagnostic);
}

fn value(state: *State, item: Item) !Value {
    return switch (item) {
        .nil => .nil,
        .number => |n| .from(.{ .number = n }),
        .boolean => |b| .from(.{ .boolean = b }),
        .string => |s| .from(.{ .string = try state.newString(s) }),
    };
}

fn check(source: []const u8, arguments: []const Item, expected: []const Item) !void {
    var state = try State.init(allocator);
    defer state.deinit();
    const prototype = try compile(&state, source);
    const closure = try state.newChunk(prototype);
    try state.push(.from(.{ .number = 42 }));
    for (arguments) |item| try state.push(try value(&state, item));
    var diagnostic: ?vm.Diagnostic = null;
    try equal(expected.len, try vm.runWithArguments(&state, closure, arguments.len, &diagnostic));
    try equal(expected.len + 1, state.top());
    try expect(state.stack.items[0].equal(.from(.{ .number = 42 })));
    for (expected, state.stack.items[1..]) |wanted, actual| try expect(actual.equal(try value(&state, wanted)));
    try equal(@as(usize, 0), state.frames.items.len);
}

test "varargs chunk returns exactly every argument including trailing nils" {
    try check("return ...", &.{}, &.{});
    try check("return ...", &.{ .nil, .{ .number = 2 }, .nil }, &.{ .nil, .{ .number = 2 }, .nil });
    try check("local x=8 return x,...", &.{ .{ .number = 1 }, .nil, .{ .number = 3 } }, &.{ .{ .number = 8 }, .{ .number = 1 }, .nil, .{ .number = 3 } });
    try check("local x=8 return x,...", &.{}, &.{.{ .number = 8 }});
    try check("return ...,9", &.{ .{ .number = 1 }, .{ .number = 2 } }, &.{ .{ .number = 1 }, .{ .number = 9 } });
    try check("return ...,9", &.{}, &.{ .nil, .{ .number = 9 } });
    try check("return ...,...", &.{ .{ .number = 1 }, .nil }, &.{ .{ .number = 1 }, .{ .number = 1 }, .nil });
}

test "varargs scalar contexts and parentheses truncate or supply one nil" {
    try check("return (...)", &.{}, &.{.nil});
    try check("return (...)", &.{ .{ .number = 1 }, .{ .number = 2 } }, &.{.{ .number = 1 }});
    try check("local a,b=(...) return a,b", &.{ .{ .number = 1 }, .{ .number = 2 } }, &.{ .{ .number = 1 }, .nil });
    try check("return ...+2, not ...", &.{.{ .number = 3 }}, &.{ .{ .number = 5 }, .{ .boolean = false } });
    try check("return false or ..., true and ...", &.{.{ .string = "x" }}, &.{ .{ .string = "x" }, .{ .string = "x" } });
}

test "varargs declarations and assignments expand only the final expression and pad" {
    const args: []const Item = &.{ .{ .number = 1 }, .nil, .{ .number = 3 } };
    try check("local a,b,c,d=... return a,b,c,d", args, &.{ .{ .number = 1 }, .nil, .{ .number = 3 }, .nil });
    try check("local a,b,c=...,9 return a,b,c", args, &.{ .{ .number = 1 }, .{ .number = 9 }, .nil });
    try check("local a,b,c=9,... return a,b,c", args, &.{ .{ .number = 9 }, .{ .number = 1 }, .nil });
    try check("local a,b,c a,b,c=... return a,b,c", args, &.{ .{ .number = 1 }, .nil, .{ .number = 3 } });
    try check("global a,b,c=... return a,b,c", args, &.{ .{ .number = 1 }, .nil, .{ .number = 3 } });
    try check("global a,b a,b=... return a,b", &.{}, &.{ .nil, .nil });
    try check("local a=... return a", args, &.{.{ .number = 1 }});
    try check("local a=9,... return a", args, &.{.{ .number = 9 }});
}

test "varargs table constructors expand the final list field and preserve holes" {
    const args: []const Item = &.{ .{ .number = 1 }, .nil, .{ .number = 3 }, .nil };
    try check("local t={8,...} return t[1],t[2],t[3],t[4],t[5],t[6]", args, &.{ .{ .number = 8 }, .{ .number = 1 }, .nil, .{ .number = 3 }, .nil, .nil });
    try check("local t={...,8} return t[1],t[2],t[3]", args, &.{ .{ .number = 1 }, .{ .number = 8 }, .nil });
    try check("local t={(...)} return t[1],t[2]", args, &.{ .{ .number = 1 }, .nil });
    try check("local t={...,x=8} return t[1],t[2],t.x", args, &.{ .{ .number = 1 }, .nil, .{ .number = 8 } });
    try check("local t={x=8,...,} return t.x,t[1],t[3]", args, &.{ .{ .number = 8 }, .{ .number = 1 }, .{ .number = 3 } });
    try check("local t={8,...} return t[1],t[2]", &.{}, &.{ .{ .number = 8 }, .nil });
    try check("local t={...} return t[1],t[2]", &.{}, &.{ .nil, .nil });
    try check("local t={a={...},...} return t.a[3],t[3]", args, &.{ .{ .number = 3 }, .{ .number = 3 } });
    try check("local t={" ++ repeated("1,", 300) ++ "...} return t[300],t[301],t[302]", &.{.{ .number = 7 }}, &.{ .{ .number = 1 }, .{ .number = 7 }, .nil });
}

test "varargs remain available through loops goto and separate invocations" {
    try check("local n=0 ::again:: local t={...} n=n+1 if n<3 then goto again end return n,...", &.{.{ .number = 7 }}, &.{ .{ .number = 3 }, .{ .number = 7 } });
    try check("local n=0 for i=1,3 do local a,b=... n=n+a+b end return n", &.{ .{ .number = 2 }, .{ .number = 3 } }, &.{.{ .number = 15 }});
    var state = try State.init(allocator);
    defer state.deinit();
    const closure = try state.newChunk(try compile(&state, "return ..."));
    var diagnostic: ?vm.Diagnostic = null;
    try state.push(.from(.{ .number = 1 }));
    try equal(@as(usize, 1), try vm.runWithArguments(&state, closure, 1, &diagnostic));
    try state.setTop(0);
    try equal(@as(usize, 0), try vm.run(&state, closure, &diagnostic));
}

test "varargs return and table expansion grow beyond the static register window" {
    var state = try State.init(allocator);
    defer state.deinit();
    const closure = try state.newChunk(try compile(&state, "local t={9,...} return t[1001],8,..."));
    for (0..1000) |i| try state.push(.from(.{ .number = @floatFromInt(i) }));
    var diagnostic: ?vm.Diagnostic = null;
    try equal(@as(usize, 1002), try vm.runWithArguments(&state, closure, 1000, &diagnostic));
    try expect(state.stack.items[0].equal(.from(.{ .number = 999 })));
    try expect(state.stack.items[1].equal(.from(.{ .number = 8 })));
    for (state.stack.items[2..], 0..) |actual, i| try expect(actual.equal(.from(.{ .number = @floatFromInt(i) })));
}

fn native(_: *State) callconv(.c) c_int {
    return 0;
}

test "varargs table is rooted across collection and consumed argument cells close before reuse" {
    var state = try State.init(allocator);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    try state.pushFrame(.{ .base = 1, .function = .{ .native = native } });
    try state.push(.from(.{ .number = 77 }));
    const source = "local n=0 while n<200 do local garbage={{}} n=n+1 end local t={...} return t[1],...";
    const closure = try state.newChunk(try compile(&state, source));
    const argument = try state.newTable();
    state.barrier(&argument.header);
    try argument.set(allocator, .from(.{ .number = 1 }), .from(.{ .number = 9 }));
    try state.push(.from(.{ .table = argument }));
    const cell = try state.capture(2);
    // Keep the captured cell rooted, independently of the running chunk.
    const holder = try state.newClosure(try state.newPrototype(&.{}), &.{cell});
    state.barrier(&state.globals.header);
    try state.globals.set(allocator, .from(.{ .number = 1 }), .fromFunction(.{ .closure = holder }));
    state.setCollectionThreshold(0);
    var diagnostic: ?vm.Diagnostic = null;
    try equal(@as(usize, 2), try vm.runWithArguments(&state, closure, 1, &diagnostic));
    try equal(@as(usize, 3), state.top());
    try expect(state.stack.items[0].equal(.from(.{ .number = 42 })));
    try expect(state.get(1).?.equal(.from(.{ .number = 77 })));
    try expect(state.get(2).?.unpack().table == argument);
    try expect(state.get(3).?.unpack().table == argument);
    try expect(state.readCell(cell).unpack().table == argument);
    try expect(cell.storage == .closed);
    try expect(argument.get(.from(.{ .number = 1 })).equal(.from(.{ .number = 9 })));
    try expect(state.object_count < 100);
    try equal(@as(usize, 1), state.frames.items.len);
}

fn allocationCase(under_test: std.mem.Allocator, ast: *const @import("Ast.zig")) !void {
    var state = try State.init(under_test);
    defer state.deinit();
    var compilation: ?compiler.Diagnostic = null;
    const closure = try state.newChunk(try compiler.compile(under_test, &state, ast, "<varargs-allocation>", &compilation));
    try state.push(.from(.{ .number = 42 }));
    for (0..40) |i| try state.push(.from(.{ .number = @floatFromInt(i) }));
    var diagnostic: ?vm.Diagnostic = null;
    const count = vm.runWithArguments(&state, closure, 40, &diagnostic) catch |err| {
        try equal(@as(usize, 1), state.top());
        try expect(state.stack.items[0].equal(.from(.{ .number = 42 })));
        try equal(@as(usize, 0), state.frames.items.len);
        if (err == error.OutOfMemory) try expect(state.failure.?.value.unpack().string == state.memory_failure);
        return err;
    };
    try equal(@as(usize, 41), count);
    try expect(state.stack.items[1].equal(.from(.{ .number = 39 })));
}

test "varargs packing table expansion and open returns clean every allocation failure" {
    var diagnostic: ?parser.Diagnostic = null;
    var ast = try parser.parseChunk(allocator, "local t={9,...} return t[41],...", &diagnostic);
    defer ast.deinit();
    try allocation_failures.checkAll(allocator, allocationCase, .{&ast});
}

test "varargs runtime errors consume arguments and preserve the active caller window" {
    var state = try State.init(allocator);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    try state.pushFrame(.{ .base = 1, .function = .{ .native = native } });
    try state.push(.from(.{ .number = 77 }));
    const closure = try state.newChunk(try compile(&state, "local t={...} return 1+nil"));
    try state.push(.from(.{ .number = 2 }));
    var diagnostic: ?vm.Diagnostic = null;
    try std.testing.expectError(error.Type, vm.runWithArguments(&state, closure, 1, &diagnostic));
    try equal(@as(usize, 1), state.top());
    try expect(state.get(1).?.equal(.from(.{ .number = 77 })));
    try equal(@as(usize, 1), state.frames.items.len);
    try std.testing.expectError(error.InvalidBytecode, vm.runWithArguments(&state, closure, 2, &diagnostic));
    try equal(@as(usize, 1), state.top());
}

fn program(state: *State, operations: []const bytecode.Instruction.Operation, registers: usize, vararg: bool) !*runtime.Closure {
    const code = try allocator.alloc(bytecode.Written, operations.len);
    defer allocator.free(code);
    for (operations, code) |operation, *instruction| instruction.* = .{ .position = .{ .offset = 0, .line = 1, .column = 1 }, .operation = operation };
    const prototype = try state.newProgram(&.{.nil}, code, registers, "", "<invalid-varargs>");
    prototype.vararg = vararg;
    return state.newChunk(prototype);
}

test "varargs malformed operands and absent open producers fail without unchecked access" {
    var state = try State.init(allocator);
    defer state.deinit();
    const bad = [_]bytecode.Instruction.Operation{
        .{ .varargs = .{ .first = 0, .count = 1 } },
        .{ .varargs = .{ .first = 1, .count = std.math.maxInt(usize) } },
        .{ .varargs = .{ .first = std.math.maxInt(usize), .count = null } },
        .{ .set_list = .{ .table = 0, .first = 1, .index = 0 } },
        .{ .set_list = .{ .table = 1, .first = 1, .index = 1 } },
        .{ .returns = .{ .first = std.math.maxInt(usize), .count = null } },
    };
    for (bad) |operation| {
        const closure = try program(&state, &.{operation}, 2, true);
        try std.testing.expectError(error.InvalidBytecode, vm.validate(closure.prototype));
    }
    const zero = try program(&state, &.{
        .{ .varargs = .{ .first = 1, .count = 0 } },
        .{ .returns = .{ .first = 1, .count = 0 } },
    }, 2, true);
    try state.push(.from(.{ .number = 3 }));
    var zero_diagnostic: ?vm.Diagnostic = null;
    try equal(@as(usize, 0), try vm.runWithArguments(&state, zero, 1, &zero_diagnostic));
    try equal(@as(usize, 0), state.top());
    const nonvararg = try program(&state, &.{.{ .varargs = .{ .first = 1, .count = 1 } }}, 2, false);
    try std.testing.expectError(error.InvalidBytecode, vm.validate(nonvararg.prototype));
    const empty = try program(&state, &.{.{ .returns = .{ .first = 0, .count = 0 } }}, 0, true);
    try std.testing.expectError(error.InvalidBytecode, vm.validate(empty.prototype));
    const sequences = [_][]const bytecode.Instruction.Operation{
        &.{.{ .returns = .{ .first = 1, .count = null } }},
        &.{.{ .set_list = .{ .table = 0, .first = 1, .index = 1 } }},
        &.{ .{ .constant = .{ .destination = 0, .index = 0 } }, .{ .varargs = .{ .first = 1, .count = 1 } } },
        // Open results shrink the window; the following static operand is no
        // longer in it even though it passed prototype validation.
        &.{ .{ .varargs = .{ .first = 1, .count = null } }, .{ .move = .{ .destination = 2, .source = 0 } } },
        &.{ .{ .varargs = .{ .first = 1, .count = null } }, .{ .jump = .{ .target = 2 } }, .{ .returns = .{ .first = 1, .count = null } } },
    };
    for (sequences) |operations| {
        const closure = try program(&state, operations, 3, true);
        var diagnostic: ?vm.Diagnostic = null;
        try std.testing.expectError(error.InvalidBytecode, vm.run(&state, closure, &diagnostic));
        try equal(@as(usize, 0), state.top());
        try equal(@as(usize, 0), state.frames.items.len);
    }
}

// An expansion the stack cannot hold is Lua's `stack overflow`, a runtime
// failure (the owner's answer), whatever made it large.
test "varargs open expansion respects the stack limit and restores callers" {
    var state = try State.init(allocator);
    defer state.deinit();
    const closure = try state.newChunk(try compile(&state, "return ..."));
    try state.setTop(State.max_stack - 1);
    state.stack.items[0] = .from(.{ .number = 42 });
    try state.push(.from(.{ .number = 3 }));
    var diagnostic: ?vm.Diagnostic = null;
    try std.testing.expectError(error.Runtime, vm.runWithArguments(&state, closure, 1, &diagnostic));
    try std.testing.expect(diagnostic.?.kind == .call_depth);
    try equal(State.max_stack - 1, state.top());
    try expect(state.stack.items[0].equal(.from(.{ .number = 42 })));
    try equal(@as(usize, 0), state.frames.items.len);
}

fn decode(state: *State, encoded: []const u8) !Value {
    const colon = std.mem.indexOfScalar(u8, encoded, ':') orelse return error.TestUnexpectedResult;
    const kind = encoded[0..colon];
    const payload = encoded[colon + 1 ..];
    if (std.mem.eql(u8, kind, "nil")) return .nil;
    if (std.mem.eql(u8, kind, "boolean")) return .from(.{ .boolean = std.mem.eql(u8, payload, "true") });
    if (std.mem.eql(u8, kind, "number")) return .from(.{ .number = if (std.mem.eql(u8, payload, "nan")) std.math.nan(f64) else @bitCast(try std.fmt.parseInt(u64, payload, 16)) });
    try std.testing.expectEqualStrings("string", kind);
    var buffer: [4096]u8 = undefined;
    return .from(.{ .string = try state.newString(if (std.mem.eql(u8, payload, "-")) "" else try std.fmt.hexToBytes(&buffer, payload)) });
}

test "varargs captured Lua argument and result lists agree through source execution" {
    var lines = std.mem.tokenizeScalar(u8, @embedFile("lua55-varargs"), '\n');
    var checked: usize = 0;
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        var source_buffer: [4096]u8 = undefined;
        const source = try std.fmt.hexToBytes(&source_buffer, fields.next().?);
        const argument_count = try std.fmt.parseInt(usize, fields.next().?, 10);
        const arguments = fields.next().?;
        const result_count = try std.fmt.parseInt(usize, fields.next().?, 10);
        const results = fields.next().?;
        try expect(fields.next() == null);
        errdefer std.debug.print("vararg fixture failed: {s} arguments {s}\n", .{ source, arguments });
        var state = try State.init(allocator);
        defer state.deinit();
        const closure = try state.newChunk(try compile(&state, source));
        var args = std.mem.tokenizeScalar(u8, arguments, ',');
        for (0..argument_count) |_| try state.push(try decode(&state, args.next().?));
        if (argument_count > 0) try expect(args.next() == null);
        var diagnostic: ?vm.Diagnostic = null;
        try equal(result_count, try vm.runWithArguments(&state, closure, argument_count, &diagnostic));
        try equal(result_count, state.top());
        var expected = std.mem.tokenizeScalar(u8, results, ',');
        for (state.stack.items) |actual| {
            const wanted = try decode(&state, expected.next().?);
            if (actual.numberValue() != null and wanted.numberValue() != null) {
                if (std.math.isNan(wanted.numberValue().?)) try expect(std.math.isNan(actual.numberValue().?)) else try equal(@as(u64, @bitCast(wanted.numberValue().?)), @as(u64, @bitCast(actual.numberValue().?)));
            } else try expect(actual.equal(wanted));
        }
        if (result_count > 0) try expect(expected.next() == null);
        checked += 1;
    }
    try expect(checked > 0);
    std.debug.print("vararg fixture: {d} Lua argument/result cases executed through parser, compiler and VM\n", .{checked});
}

// `...name` hands the vararg table to the program, so its `n` is the
// program's to break: Lua 5.5's runtime error, and a count past the stack is
// a stack overflow, not an internal failure.
test "varargs an improper count in the vararg table is the program's runtime error" {
    var state = try State.init(allocator);
    defer state.deinit();
    const counts = [_]Value{ .nil, .from(.{ .number = -1 }), .from(.{ .number = 1.5 }), .from(.{ .number = std.math.inf(f64) }), .from(.{ .number = std.math.nan(f64) }), Value.fromCount(1073741824), Value.fromCount(State.max_stack + 1) };
    for (counts, 0..) |count, i| {
        const table = try state.newTable();
        state.barrier(&table.header);
        try table.set(allocator, .from(.{ .string = try state.newString("n") }), count);
        const closure = try program(&state, &.{
            .{ .constant = .{ .destination = 0, .index = 0 } },
            .{ .varargs = .{ .first = 1, .count = null } },
            .{ .returns = .{ .first = 1, .count = null } },
        }, 2, true);
        closure.prototype.constants[0] = .from(.{ .table = table });
        var diagnostic: ?vm.Diagnostic = null;
        if (i == counts.len - 1) {
            // Past the stack: Lua's `stack overflow` (the owner's answer).
            try std.testing.expectError(error.Runtime, vm.run(&state, closure, &diagnostic));
            try std.testing.expect(diagnostic.?.kind == .call_depth);
        } else {
            try std.testing.expectError(error.Runtime, vm.run(&state, closure, &diagnostic));
            try std.testing.expect(diagnostic.?.kind == .vararg_count);
        }
        try equal(@as(usize, 0), state.top());
    }
}

// Named varargs, `...name` (the owner's answer
// item 15: as Lua 5.5). The name is a read-only local holding this call's
// table of extra arguments and `n`, and `...` reads that table as it is now.
// The expected texts were taken from lua5.5 running the same source; where
// Nilu adds a column to a load failure, only Lua's sentence is compared.
fn answer(state: *runtime.State, source: [:0]const u8) ![]const u8 {
    _ = api.nilu_settop(state, 0);
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state, source, "=t", null));
    _ = api.nilu_pcall(state, 0, 1, 0);
    // A source that answers `nil` (a `load` that accepted) reads as "nil",
    // so the comparison names it instead of stopping the runner.
    const text = api.nilu_tolstring(state, -1, null) orelse return "nil";
    return std.mem.span(text);
}

fn opened() !*runtime.State {
    const state = try api.create(a);
    errdefer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_openlibs(state));
    return state;
}

test "a named vararg table holds the extra arguments and n" {
    const state = try opened();
    defer api.nilu_close(state);
    const cases = .{
        .{ "return table.concat({(function(a, ...rest) return a, #rest, rest.n end)(1, 2, 3)}, ' ')", "1 2 2" },
        .{ "local r = (function(...r) return r end)() return type(r) .. ' ' .. r.n .. ' ' .. #r .. ' ' .. tostring(next(r))", "table 0 0 n" },
        .{ "local f = function(...r) return r end return tostring(f(1) == f(1))", "false" },
        .{ "local f = function(...r) return function() return r.n, r[1] end end return table.concat({f(4, 5)()}, ' ')", "2 4" },
        .{ "local t = {} function t:m(...r) return self, r.n end return select(2, t.m(1, 2, 3))", "2" },
        .{ "local f = function(... r) return r.n end return f(1, 2)", "2" },
        .{ "local f = function(...self) return self.n end return f(1, 2)", "2" },
        .{ "local f = function(a, ...a) return type(a) end return f(1, 2)", "table" },
        .{ "local function f(...r) local r = 3 return r end return f(1, 2)", "3" },
        .{ "local f = function(...r) return #{...} .. ' ' .. r.n end return f(nil, nil)", "0 2" },
    };
    inline for (cases) |case| try std.testing.expectEqualStrings(case[1], try answer(state, case[0]));
}

test "... still reads the arguments, from the named vararg table as it is now" {
    const state = try opened();
    defer api.nilu_close(state);
    const cases = .{
        .{ "return table.concat({(function(...r) return select('#', ...), ... end)(1, 2, 3)}, ' ')", "3 1 2 3" },
        .{ "local f = function(...r) r[1] = 9 r.n = 3 return select('#', ...) .. ' ' .. tostring(...) end return f(1, 2)", "3 9" },
        .{ "local f = function(...r) r[2] = 99 return table.concat({...}, ' ') end return f(1, 2)", "1 99" },
        .{ "local f = function(...r) r.n = 1 return select('#', ...) end return f(1, 2)", "1" },
        .{ "local f = function(...r) r.n = 3 local a, b, c = ... return tostring(a) .. tostring(b) .. tostring(c) end return f(1)", "1nilnil" },
        .{ "local f = function(...r) r.n = 1000000 local a = ... return a end return f(1, 2)", "1" },
        .{ "local f = function(...r) r.n = 1073741823 local a = ... return a end return f(1, 2)", "1" },
        // Lua reads the raw table: a metatable on it changes nothing.
        .{ "local f = function(...r) setmetatable(r, {__index = function() return 7 end}) return tostring(select(2, ...)) end return f(1, nil)", "nil" },
        // Without `...` in the way, a broken `n` is never read.
        .{ "local f = function(...r) r.n = nil return 1 end return f(1)", "1" },
        // `n` must be an integer: a float, even 2.0, is refused, as lua5.5
        // refuses it. The earlier answer, a count for a whole float, rested
        // on there being one number type.
        .{ "local f = function(...r) r.n = 2.0 return select('#', ...) end return f(1)", "t:1: vararg table has no proper 'n'" },
    };
    inline for (cases) |case| try std.testing.expectEqualStrings(case[1], try answer(state, case[0]));
}

test "a named vararg table whose n is not a whole count fails where ... reads it" {
    const state = try opened();
    defer api.nilu_close(state);
    const cases = .{
        .{ "local f = function(...r) r.n = nil return ... end return f(1, 2)", "t:1: vararg table has no proper 'n'" },
        .{ "local f = function(...r) r.n = nil local x = ... return x end return f(1, 2)", "t:1: vararg table has no proper 'n'" },
        .{ "local f = function(...r) r.n = 2.5 return ... end return f(1, 2)", "t:1: vararg table has no proper 'n'" },
        .{ "local f = function(...r) r.n = -1 return ... end return f(1, 2)", "t:1: vararg table has no proper 'n'" },
        .{ "local f = function(...r) r.n = '2' return ... end return f(1, 2)", "t:1: vararg table has no proper 'n'" },
        .{ "local f = function(...r) r.n = 1073741824 local x = ... return x end return f(1, 2)", "t:1: vararg table has no proper 'n'" },
        .{ "local f = function(...r) r.n = 0/0 return ... end return f(1, 2)", "t:1: vararg table has no proper 'n'" },
        // More values than the stack holds: Lua's sentence (the owner's answer).
        .{ "local f = function(...r) r.n = 1000000 return select('#', ...) end return f(1)", "t:1: stack overflow" },
    };
    inline for (cases) |case| try std.testing.expectEqualStrings(case[1], try answer(state, case[0]));
}

test "a named vararg is read-only, last, and plain" {
    const state = try opened();
    defer api.nilu_close(state);
    const cases = .{
        .{ "return select(2, load('local f = function(...r) r = 5 end'))", "attempt to assign to const variable 'r'" },
        .{ "return select(2, load('local f = function(...r) local g = function() r = {n = 0} end end'))", "attempt to assign to const variable 'r'" },
        .{ "return select(2, load('local f = function(...r, a) end'))", "')' expected near ','" },
        .{ "return select(2, load('local f = function(...r <const>) end'))", "')' expected near '<'" },
        .{ "return select(2, load('local function f(...1) end'))", "')' expected near '1'" },
        .{ "return select(2, load('return ...rest'))", "<eof> expected near 'rest'" },
    };
    inline for (cases) |case| {
        const text = try answer(state, case[0]);
        if (!std.mem.endsWith(u8, text, case[1])) {
            std.debug.print("got: {s}\n", .{text});
            return error.TestExpectedEqual;
        }
    }
}

test "a named vararg is the parser's: the name after ... is kept in the tree" {
    var diagnostic: ?parser.Diagnostic = null;
    const source = "function(a, ...rest) return rest end";
    var ast = try parser.parseExpression(a, source, &diagnostic);
    defer ast.deinit();
    const function = ast.root.data.function;
    try std.testing.expectEqual(@as(usize, 1), function.parameters.len);
    try std.testing.expect(function.varargs != null);
    const name = function.varargs_name orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("rest", source[name.start..name.end]);
    var plain = try parser.parseExpression(a, "function(...) end", &diagnostic);
    defer plain.deinit();
    try std.testing.expect(plain.root.data.function.varargs_name == null);
}
