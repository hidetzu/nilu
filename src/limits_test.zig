const std = @import("std");
const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const runtime = @import("runtime.zig");
const allocator = std.testing.allocator;
const equal = std.testing.expectEqual;

const Subject = @FieldType(compiler.Limit, "subject");

fn compile(source: []const u8, diagnostic: *?compiler.Diagnostic) !void {
    var state = try runtime.State.init(allocator);
    defer state.deinit();
    var parse_diagnostic: ?parser.Diagnostic = null;
    var ast = try parser.parseChunk(allocator, source, &parse_diagnostic);
    defer ast.deinit();
    _ = try compiler.compile(allocator, &state, &ast, "<limits>", diagnostic);
}

// The owner's answer: a limit is a syntax error that points at
// the first item past it, with the subject and maximum its words name.
fn expectLimit(source: []const u8, subject: Subject, maximum: usize, line: usize, column: usize) !void {
    var diagnostic: ?compiler.Diagnostic = null;
    try std.testing.expectError(error.Syntax, compile(source, &diagnostic));
    const limit = diagnostic.?.limit;
    try equal(subject, limit.subject);
    try equal(maximum, limit.maximum);
    try equal(line, limit.position.line);
    try equal(column, limit.position.column);
}

fn accepts(source: []const u8) !void {
    var diagnostic: ?compiler.Diagnostic = null;
    try compile(source, &diagnostic);
}

/// `count` lines of `local v<i>=1`, owned by the caller.
fn locals(count: usize, rest: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (0..count) |i| try out.writer.print("local v{d}=1\n", .{i});
    try out.writer.writeAll(rest);
    return out.toOwnedSlice();
}

fn list(prefix: []const u8, count: usize, item: []const u8, separator: []const u8, suffix: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll(prefix);
    for (0..count) |i| {
        if (i > 0) try out.writer.writeAll(separator);
        try out.writer.print("{s}{d}", .{ item, i });
    }
    try out.writer.writeAll(suffix);
    return out.toOwnedSlice();
}

test "limits local variables point at the first name past 200" {
    const fits = try locals(200, "return v0");
    defer allocator.free(fits);
    try accepts(fits);
    const declaration = try locals(200, "local\n  extra = 1");
    defer allocator.free(declaration);
    try expectLimit(declaration, .local_variables, 200, 202, 3);
    const one = try list("local ", 201, "v", ",", " = 1");
    defer allocator.free(one);
    // v200 follows 200 commas and the names v0..v199 (10*2 + 90*3 + 100*4 bytes).
    try expectLimit(one, .local_variables, 200, 1, 7 + 690 + 200);
    const function = try locals(200, "local function\n  f() end");
    defer allocator.free(function);
    try expectLimit(function, .local_variables, 200, 202, 3);
}

test "limits parameters and the vararg slot count toward 200 locals" {
    const fits = try list("local f = function(", 200, "p", ",", ") end");
    defer allocator.free(fits);
    try accepts(fits);
    const parameters = try list("local f = function(", 201, "p", ",\n", ") end");
    defer allocator.free(parameters);
    try expectLimit(parameters, .local_variables, 200, 201, 1);
    const vararg = try list("local f = function(", 200, "p", ",\n", ",\n...) end");
    defer allocator.free(vararg);
    try expectLimit(vararg, .local_variables, 200, 201, 1);
    // Implicit self counts first, but method definitions do not compile yet.
}

test "limits loops count their hidden slots and report a declared name" {
    const numeric_fits = try locals(197, "for i = 1, 2 do end");
    defer allocator.free(numeric_fits);
    try accepts(numeric_fits);
    const numeric = try locals(198, "for\n  i = 1, 2 do end");
    defer allocator.free(numeric);
    try expectLimit(numeric, .local_variables, 200, 200, 3);
    // Two hidden slots plus the names: one name past the limit is that name,
    // a hidden slot past it is reported at the first name.
    const generic_fits = try locals(197, "for k in next, {} do end");
    defer allocator.free(generic_fits);
    try accepts(generic_fits);
    const second = try locals(197, "for k,\n  v in next, {} do end");
    defer allocator.free(second);
    try expectLimit(second, .local_variables, 200, 199, 3);
    const hidden = try locals(199, "for\n  k in next, {} do end");
    defer allocator.free(hidden);
    try expectLimit(hidden, .local_variables, 200, 201, 3);
}

test "limits upvalues point at the reference that would be the 256th capture" {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    // Two enclosing functions keep each under 200 locals.
    try out.writer.writeAll("local function g1()\n");
    for (0..150) |i| try out.writer.print("local u{d}=1\n", .{i});
    try out.writer.writeAll("local function g2()\n");
    for (150..256) |i| try out.writer.print("local u{d}=1\n", .{i});
    try out.writer.writeAll("return function() return (0\n");
    for (0..256) |i| {
        try out.writer.print("+u{d}", .{i});
        if ((i + 1) % 64 == 0 and i != 255) try out.writer.writeAll(")+(0");
        try out.writer.writeAll("\n");
    }
    try out.writer.writeAll(")end end end");
    // Line 1 opens g1, 2..151 and 153..258 declare, 259 opens the inner
    // function, and u<i> is on line 260 + i.
    try expectLimit(out.written(), .upvalues, 255, 260 + 255, 2);
}

test "limits constants point at the literal that would be the 65536th" {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("local x = 0\n");
    for (1..65535) |i| try out.writer.print("x = {d}\n", .{i});
    // 65535 distinct constants fit, and repeating one uses no further slot.
    for (0..1000) |_| try out.writer.writeAll("x = 7\n");
    try accepts(out.written());
    // Line 1 declares x, then 65534 + 1000 assignment lines.
    try out.writer.writeAll("x =\n  65535");
    try expectLimit(out.written(), .constants, 65535, 1 + 65534 + 1000 + 2, 3);
}

test "limits registers point at the value that would use the 256th register" {
    // Register 0 is the chunk's vararg table, so 254 remain.
    const fits = try list("return ", 254, "", ",", "");
    defer allocator.free(fits);
    try accepts(fits);
    const returned = try list("return\n", 255, "", ",\n", "");
    defer allocator.free(returned);
    try expectLimit(returned, .registers, 255, 256, 1);
    // A local takes register 1 and the function register 2, so the 253rd
    // argument is past the limit.
    const call = try list("local f\nf(\n", 253, "", ",\n", ")");
    defer allocator.free(call);
    try expectLimit(call, .registers, 255, 255, 1);
    const declaration = try list("local a, b = ", 300, "", ", ", "");
    defer allocator.free(declaration);
    var diagnostic: ?compiler.Diagnostic = null;
    try std.testing.expectError(error.Syntax, compile(declaration, &diagnostic));
    try equal(Subject.registers, diagnostic.?.limit.subject);
}
