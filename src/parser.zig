const std = @import("std");
const allocation_failures = @import("allocation_failures.zig");
const repeated = @import("repeated_text.zig").repeated;
const Ast = @import("Ast.zig");
const Lexer = @import("Lexer.zig");
const Token = @import("Token.zig");
pub const Error = error{ OutOfMemory, Syntax };
pub const Diagnostic = union(enum) {
    lexical: Lexer.Diagnostic,
    expected_expression: Token,
    invalid_statement: Token,
    expected_for_separator: Token,
    expected_token: struct { expected: Token.Kind, found: Token },
    syntax_limit: struct { position: Token.Position, maximum: usize },
    /// The source is longer than `Token.max_source_bytes`; nothing was read.
    chunk_too_large: struct { maximum: usize },
};
pub fn parseExpression(allocator: std.mem.Allocator, source: []const u8, diagnostic: *?Diagnostic) Error!Ast {
    return @import("ParserEngine.zig").parse(allocator, source, diagnostic, false);
}
pub fn parseChunk(allocator: std.mem.Allocator, source: []const u8, diagnostic: *?Diagnostic) Error!Ast {
    return @import("ParserEngine.zig").parse(allocator, source, diagnostic, true);
}
test "expression precedence and association match the manual trees" {
    var diagnostic: ?Diagnostic = null;
    var ast = try parseExpression(std.testing.allocator, "-2 ^ 3 ^ 2 + 1 * 4 .. 'a' .. 'b'", &diagnostic);
    defer ast.deinit();
    const concat = ast.root.data.binary;
    try std.testing.expectEqual(Token.Kind.@"..", concat.operator.kind);
    try std.testing.expect(concat.right.data.binary.operator.kind == .@"..");
    const addition = concat.left.data.binary;
    try std.testing.expect(addition.operator.kind == .@"+");
    try std.testing.expect(addition.right.data.binary.operator.kind == .@"*");
    const negation = addition.left.data.unary;
    try std.testing.expect(negation.operator.kind == .@"-");
    try std.testing.expect(negation.operand.data.binary.operator.kind == .@"^");
    try std.testing.expect(negation.operand.data.binary.right.data.binary.operator.kind == .@"^");
    try std.testing.expect(diagnostic == null);
}

test "left associative arithmetic and comparisons retain their grouping" {
    var diagnostic: ?Diagnostic = null;
    for ([_][]const u8{ "9 - 3 - 1", "1 < 2 < 3", "a or b or c", "a and b and c", "a / b // c % d" }) |source| {
        var ast = try parseExpression(std.testing.allocator, source, &diagnostic);
        defer ast.deinit();
        try std.testing.expect(ast.root.data.binary.left.data == .binary);
    }
    var ast = try parseExpression(std.testing.allocator, "not 1 == 2", &diagnostic);
    defer ast.deinit();
    try std.testing.expect(ast.root.data.binary.left.data == .unary);
}

test "prefix calls preserve receivers methods argument lists and parentheses" {
    const source = "(factory()).field[2]:method(1, ...)'raw'{x = true}";
    var diagnostic: ?Diagnostic = null;
    var ast = try parseExpression(std.testing.allocator, source, &diagnostic);
    defer ast.deinit();
    const last = ast.root.data.call;
    try std.testing.expectEqual(@as(usize, 1), last.arguments.len);
    try std.testing.expect(last.arguments[0].data == .table);
    const raw = last.receiver.data.call;
    try std.testing.expect(raw.arguments[0].data == .string);
    const method = raw.receiver.data.call;
    try std.testing.expectEqualStrings("method", source[method.method.?.start..method.method.?.end]);
    try std.testing.expectEqual(@as(usize, 2), method.arguments.len);
    try std.testing.expect(method.arguments[1].data == .varargs);
    const indexed = method.receiver.data.index;
    try std.testing.expect(indexed.receiver.data.field.receiver.data == .group);
    try std.testing.expectEqual(source.len, ast.root.span.end);
}

test "table fields distinguish list named and expression keys and separators" {
    var diagnostic: ?Diagnostic = null;
    var ast = try parseExpression(std.testing.allocator, "{nil; name = false, [f()] = 2; 3,}", &diagnostic);
    defer ast.deinit();
    const fields = ast.root.data.table;
    try std.testing.expectEqual(@as(usize, 4), fields.len);
    try std.testing.expect(fields[0].key == .list);
    try std.testing.expect(fields[1].key == .name);
    try std.testing.expect(fields[2].key.expression.data == .call);
    try std.testing.expect(fields[3].key == .list);
}

test "raw literals retain borrowed bytes positions and grouping" {
    const source = "\r\n ('a\\n')";
    var diagnostic: ?Diagnostic = null;
    var ast = try parseExpression(std.testing.allocator, source, &diagnostic);
    defer ast.deinit();
    try std.testing.expectEqual(@as(usize, 2), ast.root.position.line);
    try std.testing.expectEqual(@as(usize, 2), ast.root.position.column);
    const contents = ast.root.data.group.data.string.contents;
    try std.testing.expectEqualStrings("a\\n", ast.source[contents.start..contents.end]);
}

test "expression syntax failures retain expected tokens and lexical positions" {
    var diagnostic: ?Diagnostic = null;
    for ([_][]const u8{ "", "1 +", "f(,)", "f(1,)", "{a =}", "{[1] 2}", "t.end", "{}[1]", "'s':m()", "true()", "a b", "a:", "(x", "[[]" }) |source| {
        try std.testing.expectError(error.Syntax, parseExpression(std.testing.allocator, source, &diagnostic));
        try std.testing.expect(diagnostic != null);
    }
    try std.testing.expectError(error.Syntax, parseExpression(std.testing.allocator, "1e+", &diagnostic));
    try std.testing.expect(diagnostic.?.lexical.kind == .malformed_number);
    try std.testing.expectError(error.Syntax, parseExpression(std.testing.allocator, "(x]", &diagnostic));
    try std.testing.expect(diagnostic.?.expected_token.expected == .@")");
    try std.testing.expectEqual(@as(usize, 3), diagnostic.?.expected_token.found.position.column);
}

test "function expressions contain parameters varargs and a parsed body" {
    var diagnostic: ?Diagnostic = null;
    var ast = try parseExpression(std.testing.allocator, "function(a, ...) return a, ... end", &diagnostic);
    defer ast.deinit();
    try std.testing.expectEqual(@as(usize, 1), ast.root.data.function.parameters.len);
    try std.testing.expect(ast.root.data.function.varargs != null);
    try std.testing.expect(!ast.root.data.function.implicit_self);
    try std.testing.expectEqual(@as(usize, 2), ast.root.data.function.body.data.block[0].data.return_statement.len);
    try std.testing.expect(diagnostic == null);
}

fn allocationCase(allocator: std.mem.Allocator, source: []const u8, failure: bool) !void {
    var diagnostic: ?Diagnostic = null;
    if (failure) {
        _ = parseExpression(allocator, source, &diagnostic) catch |err| {
            if (err == error.Syntax) return;
            return err;
        };
        return error.TestUnexpectedResult;
    }
    var ast = try parseExpression(allocator, source, &diagnostic);
    defer ast.deinit();
}

test "expression allocations are reclaimed on success syntax failure and every allocation failure" {
    try allocation_failures.checkAll(std.testing.allocator, allocationCase, .{ "f({a = 1, [g()] = 2}, x:m('raw')).field[2]", false });
    try allocation_failures.checkAll(std.testing.allocator, allocationCase, .{ "f({a = 1, [g()] = 2}, x:m('raw')).field[", true });
}

test "deep parentheses and huge right associative chains cannot exhaust the host stack" {
    var diagnostic: ?Diagnostic = null;
    const boundary = repeated("(", 200) ++ "1" ++ repeated(")", 200);
    var ast = try parseExpression(std.testing.allocator, boundary, &diagnostic);
    ast.deinit();
    try std.testing.expectError(error.Syntax, parseExpression(std.testing.allocator, "(" ++ boundary ++ ")", &diagnostic));
    try std.testing.expect(diagnostic.? == .syntax_limit);
    for ([_][]const u8{ repeated("1 ^ ", 100000) ++ "1", repeated("'a' .. ", 100000) ++ "'b'", repeated("- ", 100000) ++ "1" }) |source| {
        try std.testing.expectError(error.Syntax, parseExpression(std.testing.allocator, source, &diagnostic));
    }
}

test "every binary operator has the precedence and association stated in the manual" {
    const operators = [_][]const u8{ "or", "and", "<", ">", "<=", ">=", "~=", "==", "|", "~", "&", "<<", ">>", "..", "+", "-", "*", "/", "//", "%", "^" };
    const powers = [_]u8{ 1, 2, 3, 3, 3, 3, 3, 3, 4, 5, 6, 7, 7, 8, 9, 9, 10, 10, 10, 10, 12 };
    var diagnostic: ?Diagnostic = null;
    for (operators, powers) |first, first_power| {
        for (operators, powers) |second, second_power| {
            const source = try std.fmt.allocPrint(std.testing.allocator, "a {s} b {s} c", .{ first, second });
            defer std.testing.allocator.free(source);
            var ast = try parseExpression(std.testing.allocator, source, &diagnostic);
            defer ast.deinit();
            const right_associative = std.mem.eql(u8, first, "^") or std.mem.eql(u8, first, "..");
            const right_group = second_power > first_power or (second_power == first_power and right_associative);
            const root = ast.root.data.binary;
            try std.testing.expectEqualStrings(if (right_group) first else second, @tagName(root.operator.kind));
            try std.testing.expect(if (right_group) root.right.data == .binary else root.left.data == .binary);
        }
    }
}

test "all reserved words are refused as expression field names but global remains a name" {
    var diagnostic: ?Diagnostic = null;
    for (Token.keywords.keys()) |word| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "t.{s}", .{word});
        defer std.testing.allocator.free(source);
        try std.testing.expectError(error.Syntax, parseExpression(std.testing.allocator, source, &diagnostic));
        try std.testing.expect(diagnostic.?.expected_token.expected == .name);
    }
    var ast = try parseExpression(std.testing.allocator, "global.global", &diagnostic);
    defer ast.deinit();
    try std.testing.expect(ast.root.data.field.receiver.data == .name);
}

// Every reserved word in each key and name position, against Lua 5.5's
// captured answers: the parser accepts the same inputs and refuses the rest
// with the same kind of failure at the same token.
test "reserved words in key and name positions match captured Lua parse results" {
    var lines = std.mem.tokenizeScalar(u8, @embedFile("lua55-reserved-word-keys"), '\n');
    var checked: usize = 0;
    var words: std.EnumSet(Token.Kind) = .empty;
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        var buffer: [64]u8 = undefined;
        const source = try std.fmt.hexToBytes(&buffer, fields.next().?);
        const class = fields.next().?;
        const near = fields.next() orelse "";
        try std.testing.expect(fields.next() == null);
        var diagnostic: ?Diagnostic = null;
        if (std.mem.eql(u8, class, "parsed")) {
            var ast = try parseChunk(std.testing.allocator, source, &diagnostic);
            ast.deinit();
        } else {
            try std.testing.expectError(error.Syntax, parseChunk(std.testing.allocator, source, &diagnostic));
            const found = if (std.mem.eql(u8, class, "unexpected")) diagnostic.?.expected_expression else found: {
                const expected = diagnostic.?.expected_token.expected;
                const wanted = class["expected:".len..];
                try std.testing.expectEqualStrings(wanted, if (expected == .name) "<name>" else @tagName(expected));
                break :found diagnostic.?.expected_token.found;
            };
            try std.testing.expectEqualStrings(near, source[found.span.start..found.span.end]);
        }
        if (std.mem.startsWith(u8, source, "return t[")) {
            const word = Token.keywords.get(source["return t[".len .. source.len - 1]).?;
            try std.testing.expect(!words.contains(word));
            words.insert(word);
        }
        checked += 1;
    }
    // The capture's reserved words are exactly Nilu's, each once per form.
    try std.testing.expectEqual(Token.keywords.keys().len, words.count());
    try std.testing.expectEqual(6 * words.count(), checked);
    std.debug.print("reserved-word fixture: {d} Lua parse results checked\n", .{checked});
}

test "empty tables calls and trailing table separators are distinct from missing arguments" {
    var diagnostic: ?Diagnostic = null;
    for ([_][]const u8{ "{}", "f()", "{1,}", "{1;}", "f{}", "f''" }) |source| {
        var ast = try parseExpression(std.testing.allocator, source, &diagnostic);
        defer ast.deinit();
    }
    for ([_][]const u8{ "{,}", "{1,,}", "{1;;}", "f(,)", "f(1,)" }) |source| {
        try std.testing.expectError(error.Syntax, parseExpression(std.testing.allocator, source, &diagnostic));
    }
}

test "arbitrary input is parsed or returned as a structured failure without leaking" {
    var random = std.Random.DefaultPrng.init(0x97f43);
    var bytes: [128]u8 = undefined;
    var diagnostic: ?Diagnostic = null;
    for (0..1024) |_| {
        const length = random.random().uintLessThan(usize, bytes.len + 1);
        random.random().bytes(bytes[0..length]);
        var ast = parseExpression(std.testing.allocator, bytes[0..length], &diagnostic) catch |err| {
            switch (err) {
                error.Syntax => try std.testing.expect(diagnostic != null),
                error.OutOfMemory => return err,
            }
            continue;
        };
        ast.deinit();
    }
}

test "chunks retain declarations assignment targets and call statements" {
    var diagnostic: ?Diagnostic = null;
    var ast = try parseChunk(std.testing.allocator, "; local <const> a, b <const> = 1, 2 a, t.x, t[k] = b, a, nil f(a)", &diagnostic);
    defer ast.deinit();
    const statements = ast.root.data.block;
    try std.testing.expectEqual(@as(usize, 4), statements.len);
    try std.testing.expect(statements[0].data == .empty);
    const declaration_node = statements[1].data.declaration;
    try std.testing.expect(declaration_node.default_attribute != null);
    try std.testing.expectEqual(@as(usize, 2), declaration_node.names.len);
    try std.testing.expect(declaration_node.names[1].attribute != null);
    const assignment = statements[2].data.assignment;
    try std.testing.expectEqual(@as(usize, 3), assignment.targets.len);
    try std.testing.expect(assignment.targets[0].data == .name);
    try std.testing.expect(assignment.targets[1].data == .field);
    try std.testing.expect(assignment.targets[2].data == .index);
    try std.testing.expectEqual(@as(usize, 3), assignment.values.len);
    try std.testing.expect(statements[3].data == .call);
}

test "contextual global declarations do not reserve the name" {
    var diagnostic: ?Diagnostic = null;
    var ast = try parseChunk(std.testing.allocator, "local global = 1 global = 2 global() global.x = 3 global[k] = 4 global * global <const> * global x, y = 1, 2 global function f() end", &diagnostic);
    defer ast.deinit();
    const statements = ast.root.data.block;
    try std.testing.expectEqual(@as(usize, 9), statements.len);
    try std.testing.expect(statements[1].data == .assignment);
    try std.testing.expect(statements[2].data == .call);
    try std.testing.expect(statements[3].data == .assignment);
    try std.testing.expect(statements[4].data == .assignment);
    try std.testing.expect(statements[5].data.declaration.wildcard);
    try std.testing.expect(statements[6].data.declaration.default_attribute != null);
    try std.testing.expectEqual(@as(usize, 2), statements[7].data.declaration.names.len);
    try std.testing.expect(statements[8].data.definition.scope == .global);
}

test "conditional arms are flat and contain separate blocks" {
    var diagnostic: ?Diagnostic = null;
    const source = "if a then local x elseif b then f() elseif c then return else do end end";
    var ast = try parseChunk(std.testing.allocator, source, &diagnostic);
    defer ast.deinit();
    const conditional_node = ast.root.data.block[0].data.conditional;
    try std.testing.expectEqual(@as(usize, 3), conditional_node.arms.len);
    try std.testing.expect(conditional_node.arms[0].body.data.block[0].data == .declaration);
    try std.testing.expect(conditional_node.arms[1].body.data.block[0].data == .call);
    try std.testing.expect(conditional_node.arms[2].body.data.block[0].data == .return_statement);
    try std.testing.expect(conditional_node.otherwise.?.data.block[0].data == .do_block);
}

test "loop trees preserve conditions iterator lists optional steps and do locations" {
    var diagnostic: ?Diagnostic = null;
    const source = "while a do break end repeat local done = true until done for i = 1, 3\ndo f() end for j = 3, 1, -1 do end for k, v in next, t do goto done ::done:: end";
    var ast = try parseChunk(std.testing.allocator, source, &diagnostic);
    defer ast.deinit();
    const statements = ast.root.data.block;
    try std.testing.expectEqual(@as(usize, 5), statements.len);
    try std.testing.expect(statements[0].data.while_loop.body.data.block[0].data == .break_statement);
    try std.testing.expect(statements[1].data.repeat_loop.condition.data == .name);
    try std.testing.expect(statements[2].data.numeric_for.step == null);
    try std.testing.expectEqual(@as(usize, 2), statements[2].data.numeric_for.do_position.line);
    try std.testing.expect(statements[3].data.numeric_for.step.?.data == .unary);
    const generic = statements[4].data.generic_for;
    try std.testing.expectEqual(@as(usize, 2), generic.names.len);
    try std.testing.expectEqual(@as(usize, 2), generic.values.len);
    try std.testing.expect(generic.body.data.block[0].data == .goto_statement);
    try std.testing.expect(generic.body.data.block[1].data == .label);
}

test "function definitions retain binding scopes and implicit method parameters" {
    var diagnostic: ?Diagnostic = null;
    var ast = try parseChunk(std.testing.allocator, "local function fact(n) return fact(n - 1) end function t.n:m(a, ...) return self, a, ... end global function g() end local f = function() return function(x) return x end end", &diagnostic);
    defer ast.deinit();
    const statements = ast.root.data.block;
    try std.testing.expect(statements[0].data.definition.scope == .local);
    const method = statements[1].data.definition;
    try std.testing.expect(method.scope == .ordinary);
    try std.testing.expect(method.target.data.field.receiver.data == .field);
    try std.testing.expect(method.value.data.function.implicit_self);
    try std.testing.expect(method.value.data.function.varargs != null);
    try std.testing.expectEqual(@as(usize, 1), method.value.data.function.parameters.len);
    try std.testing.expect(statements[2].data.definition.scope == .global);
    const literal = statements[3].data.declaration.values[0].data.function;
    try std.testing.expect(literal.body.data.block[0].data.return_statement[0].data == .function);
}

test "return ends its block and points at the disallowed following token" {
    var diagnostic: ?Diagnostic = null;
    for ([_][]const u8{ "return", "return;", "do return; end", "if x then return else return 1, 2 end" }) |source| {
        var ast = try parseChunk(std.testing.allocator, source, &diagnostic);
        defer ast.deinit();
    }
    try std.testing.expectError(error.Syntax, parseChunk(std.testing.allocator, "return 1\nf()", &diagnostic));
    try std.testing.expect(diagnostic.?.expected_token.expected == .eof);
    try std.testing.expectEqual(@as(usize, 2), diagnostic.?.expected_token.found.position.line);
    try std.testing.expectError(error.Syntax, parseChunk(std.testing.allocator, "do return; ; end", &diagnostic));
    try std.testing.expect(diagnostic.?.expected_token.expected == .end);
}

test "non-call statements and non-variable assignment targets point at the statement start" {
    var diagnostic: ?Diagnostic = null;
    for ([_][]const u8{ "x", "1 + 2", "f() = 1", "a, b", "(a) = 1", "a, f() = 1, 2" }) |source| {
        try std.testing.expectError(error.Syntax, parseChunk(std.testing.allocator, source, &diagnostic));
        try std.testing.expectEqual(@as(usize, 0), diagnostic.?.invalid_statement.span.start);
    }
    for ([_][]const u8{ "f()", "(f)(x)", "f().x = 1", "(t)[1] = 2" }) |source| {
        var ast = try parseChunk(std.testing.allocator, source, &diagnostic);
        defer ast.deinit();
    }
}

test "malformed blocks declarations loops labels and parameters are refused" {
    var diagnostic: ?Diagnostic = null;
    for ([_][]const u8{ "if x end", "if x then", "while x end", "repeat end", "for i = 1 do end", "for i in do end", "local", "local <const x", "local x, = 1", "global function t.x() end", "function f(a,) end", "function f(..., a) end", "function f()", "goto", "::x", "end", "else", "until x" }) |source| {
        try std.testing.expectError(error.Syntax, parseChunk(std.testing.allocator, source, &diagnostic));
        try std.testing.expect(diagnostic != null);
    }
}

fn chunkAllocationCase(allocator: std.mem.Allocator, source: []const u8, failure: bool) !void {
    var diagnostic: ?Diagnostic = null;
    var ast = parseChunk(allocator, source, &diagnostic) catch |err| {
        if (failure and err == error.Syntax) return;
        return err;
    };
    defer ast.deinit();
    if (failure) return error.TestUnexpectedResult;
}

test "chunk allocations are reclaimed on success syntax failure and every allocation failure" {
    const source = "global print local function f(a, ...) if a then return {...} else for k, v in next, t do t[k] = v end end end function t:m(x) while x do x = f(x) end end";
    try allocation_failures.checkAll(std.testing.allocator, chunkAllocationCase, .{ source, false });
    try allocation_failures.checkAll(std.testing.allocator, chunkAllocationCase, .{ source ++ " do", true });
}

test "deep blocks functions and large flat elseif lists cannot exhaust the host stack" {
    var diagnostic: ?Diagnostic = null;
    for ([_][]const u8{ repeated("do ", 10000) ++ repeated("end ", 10000), repeated("local f = function() ", 10000) ++ repeated("end ", 10000) }) |source| {
        try std.testing.expectError(error.Syntax, parseChunk(std.testing.allocator, source, &diagnostic));
        try std.testing.expect(diagnostic.? == .syntax_limit);
    }
    var ast = try parseChunk(std.testing.allocator, "if false then " ++ repeated("elseif false then ", 1000) ++ "end", &diagnostic);
    defer ast.deinit();
    try std.testing.expectEqual(@as(usize, 1001), ast.root.data.block[0].data.conditional.arms.len);
}

test "scope-sensitive refusals remain the responsibility of the unfinished validation stage" {
    var diagnostic: ?Diagnostic = null;
    for ([_][]const u8{ "break", "local f = function() return ... end", "goto missing", "local x <const> = 1 x = 2", "local x <close>", "global <close> x", "for i = 1, 3 do i = 4 end" }) |source| {
        var ast = try parseChunk(std.testing.allocator, source, &diagnostic);
        defer ast.deinit();
    }
}

test "arbitrary chunk input returns a tree or a bounded structured failure" {
    var random = std.Random.DefaultPrng.init(0x57a7e);
    var bytes: [256]u8 = undefined;
    var diagnostic: ?Diagnostic = null;
    for (0..1024) |_| {
        const length = random.random().uintLessThan(usize, bytes.len + 1);
        random.random().bytes(bytes[0..length]);
        var ast = parseChunk(std.testing.allocator, bytes[0..length], &diagnostic) catch |err| {
            switch (err) {
                error.Syntax => try std.testing.expect(diagnostic != null),
                error.OutOfMemory => return err,
            }
            continue;
        };
        defer ast.deinit();
        try std.testing.expect(ast.root.data == .block);
    }
}
