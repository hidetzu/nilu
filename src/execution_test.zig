const std = @import("std");
const allocation_failures = @import("allocation_failures.zig");
const repeated = @import("repeated_text.zig").repeated;
const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const vm = @import("vm.zig");
const runtime = @import("runtime.zig");
const bytecode = @import("bytecode.zig");
const Token = @import("Token.zig");
const Value = runtime.Value;
const State = runtime.State;
const allocator = std.testing.allocator;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const position = Token.Position{ .offset = 0, .line = 1, .column = 1 };

fn compile(state: *State, source: []const u8, chunk: bool) !*runtime.Prototype {
    var parse_diagnostic: ?parser.Diagnostic = null;
    var ast = if (chunk) try parser.parseChunk(allocator, source, &parse_diagnostic) else try parser.parseExpression(allocator, source, &parse_diagnostic);
    defer ast.deinit();
    var diagnostic: ?compiler.Diagnostic = null;
    return compiler.compile(allocator, state, &ast, "<test>", &diagnostic);
}

fn execute(state: *State, source: []const u8, chunk: bool) !usize {
    const prototype = try compile(state, source, chunk);
    const closure = try state.newChunk(prototype);
    var diagnostic: ?vm.Diagnostic = null;
    return vm.run(state, closure, &diagnostic);
}

fn number(source: []const u8, expected: f64) !void {
    var state = try State.init(allocator);
    defer state.deinit();
    try equal(@as(usize, 1), try execute(&state, source, false));
    const actual = state.get(-1).?;
    // Either subtype; which one is the arithmetic tests' to say.
    try expect(actual.numberValue() != null);
    if (std.math.isNan(expected)) try expect(std.math.isNan(actual.numberValue().?)) else try equal(expected, actual.numberValue().?);
}

fn boolean(source: []const u8, expected: bool) !void {
    var state = try State.init(allocator);
    defer state.deinit();
    try equal(@as(usize, 1), try execute(&state, source, false));
    try expect(state.get(-1).?.equal(.from(.{ .boolean = expected })));
}

fn string(source: []const u8, expected: []const u8) !void {
    var state = try State.init(allocator);
    defer state.deinit();
    try equal(@as(usize, 1), try execute(&state, source, false));
    const actual = state.get(-1).?;
    try expect(actual.is(.string));
    try std.testing.expectEqualSlices(u8, expected, actual.unpack().string.bytes);
}

fn owned(state: *const State, address: usize) bool {
    var current = state.objects;
    while (current) |object| : (current = object.next) if (@intFromPtr(object) == address) return true;
    return false;
}

test "execution arithmetic uses AST precedence floating point division and Lua remainder correction" {
    try number("1 + 2 * 3", 7);
    try number("2 ^ 3 ^ 2", 512);
    try number("-2 ^ 2", -4);
    try number("7 / 2", 3.5);
    try number("7 // 2", 3);
    try number("-7 // 2", -4);
    try number("7 // -2", -4);
    try number("-7 % 2", 1);
    try number("7 % -2", -1);
    try number("1.0 % 0.0", std.math.nan(f64));
    try number("1.0 / 0.0", std.math.inf(f64));
    try number("0.0 / 0.0", std.math.nan(f64));
    try number("1.0 // 0.0", std.math.inf(f64));
    try number("1e300 % 0.1", @rem(@as(f64, 1e300), @as(f64, 0.1)));
    try number("(1 / 0) % 2", std.math.nan(f64));
    try number("1 % (-1 / 0)", -std.math.inf(f64));
}

test "execution comparisons preserve types string byte order NaNs and table identity" {
    try boolean("1 == '1'", false);
    try boolean("nil == false", false);
    try boolean("1 == 1.0", true);
    try boolean("1 ~= 2", true);
    try boolean("1 < 2", true);
    try boolean("2 <= 2", true);
    try boolean("3 > 2", true);
    try boolean("3 >= 4", false);
    try boolean("'a\\0' < 'a\\0b'", true);
    try boolean("'\\xff' > '\\x7f'", true);
    try boolean("'a' .. 'b' == 'ab'", true);
    try boolean("{} == {}", false);
    try boolean("({t = {}}).t ~= nil", true);
    try boolean("(0/0) == (0/0)", false);
    try boolean("(0/0) ~= (0/0)", true);
    try boolean("(0/0) <= 1", false);
    try boolean("(0/0) > 1", false);
}

test "execution logical branches skip failures and preserve the selected operand" {
    try boolean("false and (1 + nil)", false);
    try boolean("true or #5", true);
    try boolean("not nil", true);
    try boolean("not false", true);
    try boolean("not 0", false);
    try boolean("not ''", false);
    try number("1 and 2", 2);
    try number("0 or 2", 0);
    try string("false or 'default'", "default");
    try string("'' and 'selected'", "selected");
    try number("(false and 1 or 3) + (true and 2 or 4)", 5);
}

test "execution string decoding concatenation and byte lengths use owned contents" {
    try string("'a' .. 'b' .. 'c'", "abc");
    try string("'a\\0' .. '\\xff'", "a\x00\xff");
    try string("'\\x41\\66\\u{3042}'", "ABあ");
    try string("[==[\r\nfirst\rsecond]==]", "first\nsecond");
    try string("'a\\z \n b'", "ab");
    try number("#'あ'", 3);
    try number("#'a\\0b'", 3);
    try number("#''", 0);
}

test "execution constructors support every field shape mixed keys nils and keyed overwrite" {
    try number("({10, x = 1, [3] = 30})[1]", 10);
    try number("({10, x = 1, [3] = 30}).x", 1);
    try number("({10, x = 1, [3] = 30})[3]", 30);
    try number("({x = 1, x = 2}).x", 2);
    try number("({[1 + 1] = 9})[2]", 9);
    try number("#({1, 2; 3,})", 3);
    try number("#({})", 0);
    try number("#({nil, 2})", 0);
    try boolean("({x = 1}).missing == nil", true);
    try boolean("({})[true] == nil", true);
    try boolean("({})[nil] == nil", true);
    try boolean("({})[0 / 0] == nil", true);
    try number("({[-0.0] = 7})[0]", 7);
    try number("({[1/0] = 8})[1/0]", 8);
    // The duplicate list/record corner is unspecified: either write may win.
    try boolean("({1, [1] = 2})[1] == 1 or ({1, [1] = 2})[1] == 2", true);
}

test "execution a constructor states its size and the table is made with that room" {
    var state = try State.init(allocator);
    defer state.deinit();
    // Two list entries (the trailing call is not counted) and four keyed.
    const prototype = try compile(&state, "local function f() return 1, 2 end return {x = 1, [\"k\"] = 2, y = 3, z = 4, 10, 20, f()}", true);
    const closure = try state.newChunk(prototype);
    var sized: ?@FieldType(bytecode.Instruction.Operation, "table") = null;
    for (prototype.code) |instruction| if (instruction.operation == .table) {
        try expect(sized == null);
        sized = instruction.operation.table;
    };
    try equal(@as(u32, 2), sized.?.items);
    try equal(@as(u32, 4), sized.?.fields);
    var diagnostic: ?vm.Diagnostic = null;
    try equal(@as(usize, 1), try vm.run(&state, closure, &diagnostic));
    const table = state.get(-1).?.unpack().table;
    // Four keys fit eight slots under the load limit; nothing regrew them.
    try equal(@as(usize, 8), table.hash.slots.len);
    try equal(@as(u32, 0), table.layout);
    try equal(@as(usize, 4), table.length());
    // A trailing `...` is not counted either, and an empty constructor states nothing.
    const open = try compile(&state, "return {...}, {}", true);
    for (open.code) |instruction| if (instruction.operation == .table) {
        try equal(@as(u32, 0), instruction.operation.table.items);
        try equal(@as(u32, 0), instruction.operation.table.fields);
    };
}

test "execution return lists keep multiple values and caller slots rooted" {
    var state = try State.init(allocator);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    try equal(@as(usize, 5), try execute(&state, "return 1, 'a', {}, nil, false", true));
    try equal(@as(usize, 6), state.top());
    try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
    try expect(state.get(2).?.equal(.from(.{ .number = 1 })));
    try std.testing.expectEqualStrings("a", state.get(3).?.unpack().string.bytes);
    try expect(state.get(4).?.is(.table));
    try expect(state.get(5).?.is(.nil));
    try expect(state.get(6).?.equal(.from(.{ .boolean = false })));
    try equal(@as(usize, 0), state.frames.items.len);
    try state.setTop(1);
    try equal(@as(usize, 0), try execute(&state, ";; return", true));
    try equal(@as(usize, 1), state.top());
    try equal(@as(usize, 0), try execute(&state, ";;;", true));
}

test "execution compiler pools equal constants and reuses registers for long left trees" {
    var state = try State.init(allocator);
    defer state.deinit();
    // Stress code generation directly; source syntax depth is independently 200.
    var ast = try @import("synthetic_ast.zig").addition(allocator, 10000, false);
    defer ast.deinit();
    var compiled: ?compiler.Diagnostic = null;
    const prototype = try compiler.compile(allocator, &state, &ast, "<long-AST>", &compiled);
    try equal(@as(usize, 1), prototype.constants.len);
    // The count does not grow with the tree: one register for the sum, one for each right operand.
    try equal(@as(usize, 2), prototype.registers);
    var diagnostic: ?vm.Diagnostic = null;
    try equal(@as(usize, 1), try vm.run(&state, try state.newChunk(prototype), &diagnostic));
    try expect(state.get(-1).?.equal(.from(.{ .number = 10001 })));
    const strings = try compile(&state, "return 'same', 'same', 'same'", true);
    try equal(@as(usize, 1), strings.constants.len);
    const zeros = try compile(&state, "return 0, -0.0", true);
    try state.setTop(0);
    _ = try vm.run(&state, try state.newChunk(zeros), &diagnostic);
    try equal(@as(u64, 0), @as(u64, @bitCast(state.get(1).?.numberValue().?)));
    try equal(@as(u64, 1) << 63, @as(u64, @bitCast(state.get(2).?.numberValue().?)));
}

test "execution compiler owns source metadata and prints bytecode without evaluating" {
    var state = try State.init(allocator);
    defer state.deinit();
    const source = try allocator.dupe(u8, "return 'a\\0b' .. 'c'");
    defer allocator.free(source);
    var name = [_]u8{ 'n', 'a', 'm', 'e' };
    var parse_diagnostic: ?parser.Diagnostic = null;
    var ast = try parser.parseChunk(allocator, source, &parse_diagnostic);
    var diagnostic: ?compiler.Diagnostic = null;
    const prototype = try compiler.compile(allocator, &state, &ast, &name, &diagnostic);
    ast.deinit();
    @memset(source, 'x');
    @memset(&name, 'x');
    try std.testing.expectEqualStrings("name", prototype.chunk_name);
    try std.testing.expectEqualStrings("return 'a\\0b' .. 'c'", prototype.source);
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    const objects_before = state.object_count;
    try compiler.write(&writer.writer, prototype);
    const listing = writer.written();
    try expect(std.mem.indexOf(u8, listing, "chunk name; 3 registers; vararg=true") != null);
    try expect(std.mem.indexOf(u8, listing, "hex:610062") != null);
    try expect(std.mem.indexOf(u8, listing, "concatenate") != null);
    try expect(std.mem.indexOf(u8, listing, "returns") != null);
    try equal(objects_before, state.object_count);
    try equal(@as(usize, 0), state.top());
}

fn pending(source: []const u8, expected: compiler.Error, tag: std.meta.Tag(compiler.Diagnostic)) !void {
    var state = try State.init(allocator);
    defer state.deinit();
    var parse_diagnostic: ?parser.Diagnostic = null;
    var ast = try parser.parseChunk(allocator, source, &parse_diagnostic);
    defer ast.deinit();
    var diagnostic: ?compiler.Diagnostic = null;
    try std.testing.expectError(expected, compiler.compile(allocator, &state, &ast, "test", &diagnostic));
    try equal(tag, std.meta.activeTag(diagnostic.?));
    try expect(state.prototypes == null);
}

test "execution static validations reject before code publication" {
    try pending("break", error.Syntax, .control);
    try pending("local x <const> x = 1", error.Syntax, .names);
    try pending("goto nowhere", error.Syntax, .jumps);
    try pending("return false and '\\q'", error.Syntax, .string);
    try pending("return " ++ repeated("1,", 255) ++ "1", error.Syntax, .limit);
}

test "execution type failures preserve operator positions and restore stack and frame depth" {
    const cases = [_][]const u8{ "1 + nil", "'1' + 1", "1 .. {}", "#5", "1 < 'a'", "(1).field", "({[nil] = 1})", "({[0/0] = 1})" };
    var state = try State.init(allocator);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    for (cases) |source| {
        const prototype = try compile(&state, source, false);
        var diagnostic: ?vm.Diagnostic = null;
        try std.testing.expectError(error.Type, vm.run(&state, try state.newChunk(prototype), &diagnostic));
        try expect(diagnostic.?.kind == .type_error);
        try equal(@as(usize, 1), state.top());
        try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
        try equal(@as(usize, 0), state.frames.items.len);
    }
    const prototype = try compile(&state, "return 1\n  + nil", true);
    var diagnostic: ?vm.Diagnostic = null;
    try std.testing.expectError(error.Type, vm.run(&state, try state.newChunk(prototype), &diagnostic));
    try equal(@as(usize, 2), diagnostic.?.position.line);
    try equal(@as(usize, 3), diagnostic.?.position.column);
}

fn codeProgram(state: *State, operations: []const bytecode.Instruction.Operation, registers: usize, constants: []const Value) !*runtime.Prototype {
    const code = try allocator.alloc(bytecode.Written, operations.len);
    defer allocator.free(code);
    for (operations, code) |operation, *instruction| instruction.* = .{ .position = position, .operation = operation };
    return state.newProgram(constants, code, registers, "", "<bytecode>");
}

test "execution malformed bytecode is refused before unchecked indices and arithmetic" {
    const invalid = [_]bytecode.Instruction.Operation{
        .{ .constant = .{ .destination = 1, .index = 0 } },
        .{ .constant = .{ .destination = 0, .index = 1 } },
        .{ .unary = .{ .operator = .not, .register = 1 } },
        .{ .binary = .{ .operator = .add, .destination = 0, .left = 0, .right = 1 } },
        .{ .table = .{ .destination = 1 } },
        .{ .get = .{ .destination = 0, .table = 0, .key = 1 } },
        .{ .set = .{ .table = 0, .key = 0, .value = 1 } },
        .{ .branch = .{ .register = 0, .when = true, .target = std.math.maxInt(usize) } },
        .{ .clear = .{ .first = 1, .count = std.math.maxInt(usize) } },
        .{ .returns = .{ .first = std.math.maxInt(usize), .count = 1 } },
    };
    var state = try State.init(allocator);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    for (invalid) |operation| {
        const prototype = try codeProgram(&state, &.{operation}, 1, &.{.nil});
        var diagnostic: ?vm.Diagnostic = null;
        try std.testing.expectError(error.InvalidBytecode, vm.run(&state, try state.newChunk(prototype), &diagnostic));
        try equal(@as(usize, 1), state.top());
        try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
        try equal(@as(usize, 0), state.frames.items.len);
    }
    var diagnostic: ?vm.Diagnostic = null;
    const empty = try state.newPrototype(&.{});
    try std.testing.expectError(error.InvalidBytecode, vm.run(&state, try state.newChunk(empty), &diagnostic));
    const fallthrough = try codeProgram(&state, &.{.{ .constant = .{ .destination = 0, .index = 0 } }}, 1, &.{.nil});
    try std.testing.expectError(error.InvalidBytecode, vm.run(&state, try state.newChunk(fallthrough), &diagnostic));
    try equal(@as(usize, 1), state.top());
}

test "execution VM collection keeps the running closure and batched table graphs alive" {
    var state = try State.init(allocator);
    defer state.deinit();
    const baseline = state.object_count;
    _ = try state.newTable(); // Unreachable before the first VM safe point.
    const source = "return {" ++ repeated("{},", 300) ++ "}";
    const prototype = try compile(&state, source, true);
    try expect(prototype.registers <= 255);
    const closure = try state.newChunk(prototype);
    state.setCollectionThreshold(0);
    var diagnostic: ?vm.Diagnostic = null;
    try equal(@as(usize, 1), try vm.run(&state, closure, &diagnostic));
    // The chunk also retains its counted vararg table and its n key.
    try equal(baseline + 305, state.object_count);
    try expect(owned(&state, @intFromPtr(&closure.header)));
    const table = state.get(-1).?.unpack().table;
    try equal(@as(u64, 300), table.length());
    for (1..301) |i| {
        const child = table.get(.from(.{ .number = @floatFromInt(i) }));
        try expect(child.is(.table));
        try expect(owned(&state, @intFromPtr(&child.unpack().table.header)));
        try equal(@as(u32, 0), child.unpack().table.live);
    }
    state.collect();
    try equal(baseline + 301, state.object_count);
    try state.setTop(0);
    state.collect();
    try equal(baseline, state.object_count);
}

fn native(_: *State) callconv(.c) c_int {
    return 0;
}

test "execution empty native equality results are false" {
    var state = try State.init(allocator);
    defer state.deinit();
    const table = try state.newTable();
    const meta = try state.newTable();
    for ([_][]const u8{"__eq"}) |name| {
        state.barrier(&meta.header);
        try meta.set(allocator, .from(.{ .string = try state.newString(name) }), .fromFunction(.{ .native = native }));
    }
    try state.setMetatable(.from(.{ .table = table }), meta);
    const other = try state.newTable();
    const operations = [_]bytecode.Instruction.Operation{
        .{ .binary = .{ .operator = .equal, .destination = 0, .left = 0, .right = 1 } },
    };
    for (operations) |operation| {
        const prototype = try codeProgram(&state, &.{
            .{ .constant = .{ .destination = 0, .index = 0 } },
            .{ .constant = .{ .destination = 1, .index = 1 } },
            operation,
            .{ .returns = .{ .first = 0, .count = 1 } },
        }, 2, &.{ .from(.{ .table = table }), .from(.{ .table = other }) });
        var diagnostic: ?vm.Diagnostic = null;
        _ = try vm.run(&state, try state.newChunk(prototype), &diagnostic);
        try expect(state.get(-1).?.equal(.from(.{ .boolean = false })));
        try equal(@as(usize, 1), state.top());
    }
}

fn compileAllocationCase(failing: std.mem.Allocator, ast: *const @import("Ast.zig")) !void {
    var state = try State.init(failing);
    defer state.deinit();
    var diagnostic: ?compiler.Diagnostic = null;
    const prototype = compiler.compile(failing, &state, ast, "allocation", &diagnostic) catch |err| {
        try expect(state.prototypes == null);
        return err;
    };
    _ = try state.newChunk(prototype);
}

test "execution compiler reclaims every partial allocation including program publication" {
    var parse_diagnostic: ?parser.Diagnostic = null;
    var ast = try parser.parseChunk(allocator, "return ({1, x = 'a' .. 'b', [3] = 9}).x, false and #5", &parse_diagnostic);
    defer ast.deinit();
    try allocation_failures.checkAll(allocator, compileAllocationCase, .{&ast});
}

fn runAllocationCase(failing: std.mem.Allocator, ast: *const @import("Ast.zig")) !void {
    var state = try State.init(failing);
    defer state.deinit();
    var compile_diagnostic: ?compiler.Diagnostic = null;
    const prototype = try compiler.compile(failing, &state, ast, "allocation", &compile_diagnostic);
    const closure = try state.newChunk(prototype);
    try state.push(.from(.{ .number = 42 }));
    var diagnostic: ?vm.Diagnostic = null;
    const result = vm.run(&state, closure, &diagnostic) catch |err| {
        try equal(@as(usize, 1), state.top());
        try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
        try equal(@as(usize, 0), state.frames.items.len);
        if (err == error.OutOfMemory) {
            try expect(state.failure.?.value.is(.string));
            try std.testing.expectEqualStrings("not enough memory", state.failure.?.value.unpack().string.bytes);
        }
        return err;
    };
    try equal(@as(usize, 1), result);
    try equal(@as(usize, 2), state.top());
}

test "execution VM allocation failures keep the caller intact and use the prepared memory sentence" {
    var parse_diagnostic: ?parser.Diagnostic = null;
    var ast = try parser.parseChunk(allocator, "return { x = 'a' .. 'b', {1, 2, 3} }", &parse_diagnostic);
    defer ast.deinit();
    // Each sweep owns a fresh state. Objects retained until close after a VM
    // failure are not leaks; closing here also measures their eventual release.
    try allocation_failures.checkAll(allocator, runAllocationCase, .{&ast});
}

test "execution captured Lua expressions agree through the parser compiler and VM" {
    var lines = std.mem.tokenizeScalar(u8, @embedFile("lua55-expressions"), '\n');
    var checked: usize = 0;
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const encoded = fields.next().?;
        const kind = fields.next().?;
        const expected = fields.next().?;
        try expect(fields.next() == null);
        var input_buffer: [2048]u8 = undefined;
        const source = try std.fmt.hexToBytes(&input_buffer, encoded);
        var state = try State.init(allocator);
        defer state.deinit();
        try equal(@as(usize, 1), try execute(&state, source, false));
        const actual = state.get(-1).?;
        errdefer std.debug.print("expression fixture failed: {s}\n", .{source});
        try std.testing.expectEqualStrings(kind, actual.typeName());
        if (std.mem.eql(u8, kind, "number")) {
            if (std.mem.eql(u8, expected, "nan")) {
                try expect(std.math.isNan(actual.numberValue().?));
            } else {
                const bits = try std.fmt.parseInt(u64, expected, 16);
                try equal(bits, @as(u64, @bitCast(actual.numberValue().?)));
            }
        } else if (std.mem.eql(u8, kind, "string")) {
            var bytes: [2048]u8 = undefined;
            const decoded = if (std.mem.eql(u8, expected, "-")) "" else try std.fmt.hexToBytes(&bytes, expected);
            try std.testing.expectEqualSlices(u8, decoded, actual.unpack().string.bytes);
        } else if (std.mem.eql(u8, kind, "boolean")) {
            try equal(std.mem.eql(u8, expected, "true"), actual.unpack().boolean);
        } else try expect(actual.is(.nil));
        checked += 1;
    }
    try expect(checked > 0);
    std.debug.print("expression fixture: {d} Lua results executed through parser, compiler and VM\n", .{checked});
}

test "execution return windows overlap safely and nested caller visibility is restored" {
    var state = try State.init(allocator);
    defer state.deinit();
    try state.push(.from(.{ .number = 99 }));
    try state.push(.from(.{ .number = 42 }));
    try state.pushFrame(.{ .base = 1, .function = .{ .native = native } });
    const prototype = try codeProgram(&state, &.{
        .{ .constant = .{ .destination = 0, .index = 0 } },
        .{ .constant = .{ .destination = 1, .index = 1 } },
        .{ .constant = .{ .destination = 2, .index = 2 } },
        .{ .returns = .{ .first = 1, .count = 2 } },
    }, 3, &.{ .from(.{ .number = 1 }), .from(.{ .number = 2 }), .from(.{ .number = 3 }) });
    var diagnostic: ?vm.Diagnostic = null;
    try equal(@as(usize, 2), try vm.run(&state, try state.newChunk(prototype), &diagnostic));
    try equal(@as(usize, 1), state.frames.items.len);
    try equal(@as(usize, 3), state.top());
    for ([_]f64{ 42, 2, 3 }, 1..) |n, i| try expect(state.get(@intCast(i)).?.equal(.from(.{ .number = n })));
    try expect(state.get(-4) == null);
    _ = state.popFrame();
    try expect(state.get(1).?.equal(.from(.{ .number = 99 })));
}

test "execution register reservation refuses a full stack before altering the caller" {
    var state = try State.init(allocator);
    defer state.deinit();
    const prototype = try compile(&state, "1 + 2", false);
    const closure = try state.newChunk(prototype);
    try state.setTop(State.max_stack - 1);
    var diagnostic: ?vm.Diagnostic = null;
    try std.testing.expectError(error.StackLimit, vm.run(&state, closure, &diagnostic));
    try equal(@as(usize, State.max_stack - 1), state.top());
    try equal(@as(usize, 0), state.frames.items.len);
    try expect(diagnostic.?.kind == .stack_limit);
}

test "execution a table counts what it holds as a sequence grows and empties" {
    var state = try State.init(std.testing.allocator);
    defer state.deinit();
    // Appended one by one, emptied from the top, refilled: the live count
    // follows each write (it decides when the hash part is compacted).
    try equal(@as(usize, 1), try execute(&state, "local t = {} for i = 1, 50 do t[i] = i end t[50] = nil t[49] = nil t[49] = 1 return t", true));
    const table = state.get(-1).?.unpack().table;
    try equal(@as(u32, 49), table.live);
}
