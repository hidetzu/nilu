const std = @import("std");
const allocation_failures = @import("allocation_failures.zig");
const repeated = @import("repeated_text.zig").repeated;
const parser = @import("parser.zig");
const runtime = @import("runtime.zig");
const loader = @import("loader.zig");
const a = std.testing.allocator;
const equal = std.testing.expectEqual;
const expect = std.testing.expect;

fn source(prefix: []const u8, opening: []const u8, leaf: []const u8, closing: []const u8, count: usize) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(a);
    errdefer output.deinit();
    try output.writer.writeAll(prefix);
    for (0..count) |_| try output.writer.writeAll(opening);
    try output.writer.writeAll(leaf);
    for (0..count) |_| try output.writer.writeAll(closing);
    return output.toOwnedSlice();
}
fn accepts(input: []const u8, chunk: bool, depth: usize) !void {
    var diagnostic: ?parser.Diagnostic = null;
    var ast = if (chunk) try parser.parseChunk(a, input, &diagnostic) else try parser.parseExpression(a, input, &diagnostic);
    defer ast.deinit();
    try equal(depth, ast.root.syntax_depth);
    try expect(diagnostic == null);
}
fn refuses(input: []const u8, chunk: bool, line: usize, column: usize) !void {
    var diagnostic: ?parser.Diagnostic = null;
    if (chunk) try std.testing.expectError(error.Syntax, parser.parseChunk(a, input, &diagnostic)) else try std.testing.expectError(error.Syntax, parser.parseExpression(a, input, &diagnostic));
    const failure = diagnostic.?.syntax_limit;
    try equal(@as(usize, 200), failure.maximum);
    try equal(line, failure.position.line);
    try equal(column, failure.position.column);
}

test "syntax_depth every recursive construct accepts 200 and rejects the 201st opener" {
    for ([_]struct { opening: []const u8, leaf: []const u8, closing: []const u8, chunk: bool }{
        .{ .opening = "(", .leaf = "1", .closing = ")", .chunk = false },
        .{ .opening = "not ", .leaf = "true", .closing = "", .chunk = false },
        .{ .opening = "1^", .leaf = "1", .closing = "", .chunk = false },
        .{ .opening = "{", .leaf = "1", .closing = "}", .chunk = false },
        .{ .opening = "function() return ", .leaf = "1", .closing = " end", .chunk = false },
        .{ .opening = "do ", .leaf = "", .closing = "end ", .chunk = true },
        .{ .opening = "if true then ", .leaf = "", .closing = "end ", .chunk = true },
        .{ .opening = "while true do ", .leaf = "", .closing = "end ", .chunk = true },
        .{ .opening = "repeat ", .leaf = "", .closing = "until true ", .chunk = true },
        .{ .opening = "for i=1,1 do ", .leaf = "", .closing = "end ", .chunk = true },
        .{ .opening = "for k in f do ", .leaf = "", .closing = "end ", .chunk = true },
    }) |case| {
        const fits = try source("", case.opening, case.leaf, case.closing, 200);
        defer a.free(fits);
        try accepts(fits, case.chunk, 200);
        const past = try source("", case.opening, case.leaf, case.closing, 201);
        defer a.free(past);
        // A binary operator follows its left operand; all other cases point
        // at the new prefix/control opener itself.
        const extra: usize = if (std.mem.eql(u8, case.opening, "1^")) 1 else 0;
        try refuses(past, case.chunk, 1, case.opening.len * 200 + extra + 1);
    }
}

test "syntax_depth left right and suffix chains share a logical bound" {
    for ([_]struct { first: []const u8, suffix: []const u8 }{
        .{ .first = "1", .suffix = "+1" },
        .{ .first = "'x'", .suffix = "..'x'" },
        .{ .first = "a", .suffix = ".x" },
        .{ .first = "f", .suffix = "()" },
        .{ .first = "t", .suffix = "[1]" },
        .{ .first = "t", .suffix = ":m()" },
    }) |case| {
        const fits = try source(case.first, case.suffix, "", "", 200);
        defer a.free(fits);
        try accepts(fits, false, 200);
        const past = try source(case.first, case.suffix, "", "", 201);
        defer a.free(past);
        try refuses(past, false, 1, case.first.len + case.suffix.len * 200 + 1);
    }
}

test "syntax_depth mixed branches siblings and transparent statement containers use maximum" {
    const fits = repeated("do ", 100) ++ "return " ++ repeated("(", 100) ++ "1" ++ repeated(")", 100) ++ repeated(" end", 100);
    try accepts(fits, true, 200);
    const past = repeated("do\n", 100) ++ "return " ++ repeated("(", 101) ++ "1" ++ repeated(")", 101) ++ repeated(" end", 100);
    try refuses(past, true, 101, 108);
    try accepts("f(" ++ repeated("1,", 1000) ++ "1)", false, 1);
    try accepts("{" ++ repeated("x=1,", 1000) ++ "}", false, 1);
    try accepts(repeated("local x=1; ", 10000), true, 0);
    try accepts("if false then " ++ repeated("elseif false then ", 1000) ++ "end", true, 1);
    try accepts("return 1, " ++ repeated("(", 200) ++ "2" ++ repeated(")", 200), true, 200);
    try accepts("local x=" ++ repeated("(", 200) ++ "1" ++ repeated(")", 200), true, 200);
    try accepts("return " ++ repeated("(", 60) ++ "1" ++ repeated(")", 60) ++ "," ++ repeated("(", 60) ++ "2" ++ repeated(")", 60), true, 60);
}

test "syntax_depth nested limits publish the recorded message and C coordinates" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    var diagnostic: ?loader.Diagnostic = null;
    var where: loader.ErrorLocation = .{};
    try equal(loader.Result.syntax, try loader.loadLocated(&state, "return " ++ repeated("(", 201) ++ "1" ++ repeated(")", 201), "=depth", &diagnostic, &where));
    try equal(@as(c_int, 1), where.line);
    try equal(@as(c_int, 208), where.column);
    try std.testing.expectEqualStrings("depth:1:208: chunk has too many syntax levels (limit is 200)", state.get(-1).?.unpack().string.bytes);
    try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
}

fn allocationCase(allocator: std.mem.Allocator, input: []const u8, failure: bool) !void {
    var diagnostic: ?parser.Diagnostic = null;
    var ast = parser.parseChunk(allocator, input, &diagnostic) catch |err| {
        if (err == error.Syntax and failure) {
            try expect(diagnostic.? == .syntax_limit);
            return;
        }
        return err;
    };
    defer ast.deinit();
    try expect(!failure);
}
test "syntax_depth work stack and partial AST allocations are reclaimed on limit and OOM" {
    try allocation_failures.checkAll(a, allocationCase, .{ repeated("do ", 100) ++ "return " ++ repeated("(", 100) ++ "f({a=1})" ++ repeated(")", 100) ++ repeated(" end", 100), true });
    try allocation_failures.checkAll(a, allocationCase, .{ repeated("do ", 50) ++ "return " ++ repeated("(", 100) ++ "f({a=1})" ++ repeated(")", 100) ++ repeated(" end", 50), false });
}

test "syntax_depth parser uses a bounded native stack for deep and extreme inputs" {
    const Probe = struct {
        failed: bool = false,
        fn run(self: *@This()) void {
            var diagnostic: ?parser.Diagnostic = null;
            var ast = parser.parseChunk(std.heap.page_allocator, repeated("do ", 100) ++ "return " ++ repeated("(", 100) ++ "1" ++ repeated(")", 100) ++ repeated(" end", 100), &diagnostic) catch {
                self.failed = true;
                return;
            };
            ast.deinit();
            for ([_][]const u8{ "return " ++ repeated("1+", 100000) ++ "1", "return f" ++ repeated("()", 100000), "return " ++ repeated("(", 100000) }) |input| {
                if (parser.parseChunk(std.heap.page_allocator, input, &diagnostic)) |parsed| {
                    var unexpected = parsed;
                    unexpected.deinit();
                    self.failed = true;
                } else |err| {
                    if (err != error.Syntax or diagnostic.? != .syntax_limit) self.failed = true;
                }
            }
        }
    };
    var probe = Probe{};
    // 128 KiB for the parser. With libc, the thread's stack also holds the
    // static thread-local storage, most of it the standard library's signal
    // stack, so that is added on top rather than taken from the parser.
    const stack = 128 * 1024 + (std.options.signal_stack_size orelse 0);
    const thread = try std.Thread.spawn(.{ .stack_size = stack }, Probe.run, .{&probe});
    thread.join();
    try expect(!probe.failed);
}

test "syntax_depth receiver key and argument branches share a maximum instead of a sum" {
    try accepts("a" ++ repeated(".x", 100) ++ "[" ++ repeated("(", 100) ++ "1" ++ repeated(")", 100) ++ "]", false, 101);
    try accepts("a" ++ repeated(".x", 199) ++ "(" ++ repeated("(", 199) ++ "1" ++ repeated(")", 199) ++ ")", false, 200);
    try accepts("{[" ++ repeated("(", 199) ++ "1" ++ repeated(")", 199) ++ "]=1}", false, 200);
}

test "syntax_depth reports an excess function token before reading its malformed header" {
    try refuses(repeated("function() return ", 200) ++ "function '\\q", false, 1, 18 * 200 + 1);
    try refuses(repeated("do ", 200) ++ "local function '\\q", true, 1, 3 * 200 + 7);
}
