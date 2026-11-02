const std = @import("std");
const allocation_failures = @import("allocation_failures.zig");
const Token = @import("Token.zig");
const Lexer = @import("Lexer.zig");
const utf8 = @import("utf8.zig");

pub const Error = error{ OutOfMemory, Syntax, InvalidSpan };
pub const Kind = enum { invalid_escape, unfinished_escape, hexadecimal_digit_expected, decimal_escape_too_large, missing_open_brace, missing_close_brace, utf8_value_too_large, raw_newline };
pub const Diagnostic = struct {
    kind: Kind,
    span: Token.Span,
    /// Text from the literal opening quote through the offending character.
    near: Token.Span,
};

pub fn decode(allocator: std.mem.Allocator, source: []const u8, literal: Token.StringLiteral, diagnostic: *?Diagnostic) Error![]u8 {
    diagnostic.* = null;
    if (literal.contents.start > literal.contents.end or literal.contents.end > source.len) return error.InvalidSpan;
    const raw = source[literal.contents.start..literal.contents.end];
    const output = try allocator.alloc(u8, raw.len);
    errdefer allocator.free(output);
    var cursor: usize = 0;
    var written: usize = 0;
    if (literal.long_level != null) cursor = Lexer.newlineWidth(raw, 0);
    while (cursor < raw.len) {
        const start = cursor;
        const newline = Lexer.newlineWidth(raw, cursor);
        if (literal.long_level != null) {
            output[written] = if (newline > 0) '\n' else raw[cursor];
            written += 1;
            cursor += if (newline > 0) newline else 1;
            continue;
        }
        if (newline > 0) return fail(diagnostic, .raw_newline, literal, source.len, start, start + newline);
        if (raw[cursor] != '\\') {
            output[written] = raw[cursor];
            written += 1;
            cursor += 1;
            continue;
        }
        cursor += 1;
        if (cursor == raw.len) return fail(diagnostic, .unfinished_escape, literal, source.len, start, cursor);
        const escaped_newline = Lexer.newlineWidth(raw, cursor);
        if (escaped_newline > 0) {
            output[written] = '\n';
            written += 1;
            cursor += escaped_newline;
            continue;
        }
        const escape = raw[cursor];
        cursor += 1;
        const simple: ?u8 = switch (escape) {
            'a' => 7,
            'b' => 8,
            'f' => 12,
            'n' => 10,
            'r' => 13,
            't' => 9,
            'v' => 11,
            '\\', '\'', '"' => escape,
            else => null,
        };
        if (simple) |byte| {
            output[written] = byte;
            written += 1;
        } else if (escape == 'z') {
            while (cursor < raw.len and Lexer.isSpace(raw[cursor])) cursor += 1;
        } else if (escape == 'x') {
            var value: u8 = 0;
            for (0..2) |_| {
                if (cursor == raw.len or hex(raw[cursor]) == null) return fail(diagnostic, .hexadecimal_digit_expected, literal, source.len, start, @min(cursor + 1, raw.len));
                value = value * 16 + hex(raw[cursor]).?;
                cursor += 1;
            }
            output[written] = value;
            written += 1;
        } else if (std.ascii.isDigit(escape)) {
            var value: u16 = escape - '0';
            var digits: usize = 1;
            while (digits < 3 and cursor < raw.len and std.ascii.isDigit(raw[cursor])) : (digits += 1) {
                value = value * 10 + raw[cursor] - '0';
                cursor += 1;
            }
            if (value > 255) return fail(diagnostic, .decimal_escape_too_large, literal, source.len, start, cursor);
            output[written] = @intCast(value);
            written += 1;
        } else if (escape == 'u') {
            if (cursor == raw.len or raw[cursor] != '{') return fail(diagnostic, .missing_open_brace, literal, source.len, start, @min(cursor + 1, raw.len));
            cursor += 1;
            if (cursor == raw.len or hex(raw[cursor]) == null) return fail(diagnostic, .hexadecimal_digit_expected, literal, source.len, start, @min(cursor + 1, raw.len));
            var value: u32 = 0;
            while (cursor < raw.len) {
                const digit = hex(raw[cursor]) orelse break;
                if (value > (0x7fffffff - @as(u32, digit)) / 16) return fail(diagnostic, .utf8_value_too_large, literal, source.len, start, cursor + 1);
                value = value * 16 + digit;
                cursor += 1;
            }
            if (cursor == raw.len or raw[cursor] != '}') return fail(diagnostic, .missing_close_brace, literal, source.len, start, @min(cursor + 1, raw.len));
            cursor += 1;
            var buffer: [6]u8 = undefined;
            const encoded = utf8.encode(&buffer, value) catch unreachable;
            @memcpy(output[written..][0..encoded.len], encoded);
            written += encoded.len;
        } else return fail(diagnostic, .invalid_escape, literal, source.len, start, cursor);
    }
    return allocator.realloc(output, written);
}

fn hex(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

fn fail(diagnostic: *?Diagnostic, kind: @FieldType(Diagnostic, "kind"), literal: Token.StringLiteral, source_length: usize, start: usize, end: usize) Error {
    const base = literal.contents.start;
    const absolute_end = base + end;
    var near_end = absolute_end;
    const include_next = kind == .decimal_escape_too_large or
        ((kind == .hexadecimal_digit_expected or kind == .missing_open_brace or kind == .missing_close_brace) and absolute_end == literal.contents.end);
    if (include_next and near_end < source_length) near_end += 1;
    diagnostic.* = .{
        .kind = kind,
        .span = .{ .start = @intCast(base + start), .end = @intCast(absolute_end) },
        .near = .{ .start = @intCast(base -| 1), .end = @intCast(near_end) },
    };
    return error.Syntax;
}

fn expectDecoded(source: []const u8, expected: []const u8) !void {
    var scanner = Lexer.init(source);
    const token = try scanner.next();
    try std.testing.expect(token.kind == .string);
    var diagnostic: ?Diagnostic = null;
    const decoded = try decode(std.testing.allocator, source, token.string.?, &diagnostic);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings(expected, decoded);
    try std.testing.expect(diagnostic == null);
    try std.testing.expect((try scanner.next()).kind == .eof);
}

test "short string escapes decode to the recorded bytes including embedded zero" {
    try expectDecoded("'\\a\\b\\f\\n\\r\\t\\v\\\\\\\"\\\''", "\x07\x08\x0c\n\r\t\x0b\\\"'");
    try expectDecoded("'\\x41\\66\\u{3042}\\0'", "ABあ\x00");
    try expectDecoded("'\\1\\12\\123\\255\\0659\\x414'", "\x01\x0c\x7b\xffA9A4");
    try expectDecoded("'raw\x00\xffあ'", "raw\x00\xffあ");
    try expectDecoded("''", "");
}

test "escaped line breaks normalize and z skips all six whitespace bytes" {
    for ([_][]const u8{ "\n", "\r", "\n\r", "\r\n" }) |newline| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "'a\\{s}b'", .{newline});
        defer std.testing.allocator.free(source);
        try expectDecoded(source, "a\nb");
    }
    try expectDecoded("'a\\z \t\n\r\x0b\x0c b'", "ab");
    try expectDecoded("'\\z'", "");
}

test "long strings drop one initial break normalize all others and never read escapes" {
    try expectDecoded("[==[\r\na\n\rb\r\rc\\n\x00\xff]==]", "a\nb\n\nc\\n\x00\xff");
    try expectDecoded("[[\n\n]]", "\n");
    try expectDecoded("[==[a]=]b]==]", "a]=]b");
    try expectDecoded("[[]]", "");
}

test "unicode escapes include surrogates and the full recorded six byte range" {
    try expectDecoded("'\\u{D800}\\u{110000}\\u{7FFFFFFF}'", "\xed\xa0\x80\xf4\x90\x80\x80\xfd\xbf\xbf\xbf\xbf\xbf");
    try expectDecoded("'\\u{000000000000000041}'", "A");
}

test "malformed escapes retain structured kinds and bounded offending spans" {
    const cases = .{
        .{ "'\\q'", Kind.invalid_escape },
        .{ "'\\x'", Kind.hexadecimal_digit_expected },
        .{ "'\\xg1'", Kind.hexadecimal_digit_expected },
        .{ "'\\x1'", Kind.hexadecimal_digit_expected },
        .{ "'\\256'", Kind.decimal_escape_too_large },
        .{ "'\\999'", Kind.decimal_escape_too_large },
        .{ "'\\u'", Kind.missing_open_brace },
        .{ "'\\u{}'", Kind.hexadecimal_digit_expected },
        .{ "'\\u{41'", Kind.missing_close_brace },
        .{ "'\\u{41g}'", Kind.missing_close_brace },
        .{ "'\\u{80000000}'", Kind.utf8_value_too_large },
        .{ "'\\u{FFFFFFFFFFFFFFFFFFFFFFFF}'", Kind.utf8_value_too_large },
    };
    inline for (cases) |case| {
        var scanner = Lexer.init(case[0]);
        const token = try scanner.next();
        var diagnostic: ?Diagnostic = null;
        try std.testing.expectError(error.Syntax, decode(std.testing.allocator, case[0], token.string.?, &diagnostic));
        try std.testing.expectEqual(case[1], diagnostic.?.kind);
        try std.testing.expectEqual(@as(usize, 1), diagnostic.?.span.start);
        try std.testing.expect(diagnostic.?.span.end <= token.string.?.contents.end);
    }
}

test "invalid spans and incomplete raw input never access outside source" {
    var diagnostic: ?Diagnostic = null;
    for ([_]Token.Span{ .{ .start = 2, .end = 1 }, .{ .start = 0, .end = 4 } }) |span| {
        try std.testing.expectError(error.InvalidSpan, decode(std.testing.allocator, "abc", .{ .contents = span, .long_level = null }, &diagnostic));
        try std.testing.expect(diagnostic == null);
    }
    for ([_][]const u8{ "\\", "\n" }) |raw| {
        try std.testing.expectError(error.Syntax, decode(std.testing.allocator, raw, .{ .contents = .{ .start = 0, .end = @intCast(raw.len) }, .long_level = null }, &diagnostic));
    }
}

fn allocationCase(allocator: std.mem.Allocator, source: []const u8, failure: bool) !void {
    var scanner = Lexer.init(source);
    const token = try scanner.next();
    var diagnostic: ?Diagnostic = null;
    const decoded = decode(allocator, source, token.string.?, &diagnostic) catch |err| {
        if (failure and err == error.Syntax) return;
        return err;
    };
    defer allocator.free(decoded);
    if (failure) return error.TestUnexpectedResult;
}

test "output storage is reclaimed on success syntax failure and every allocation failure" {
    try allocation_failures.checkAll(std.testing.allocator, allocationCase, .{ "'a\\u{7fffffff}\\z \n b\\0'", false });
    try allocation_failures.checkAll(std.testing.allocator, allocationCase, .{ "'a\\u{7fffffff}\\256'", true });
}

test "arbitrary raw bytes either decode within their size or fail without leaking" {
    var random = std.Random.DefaultPrng.init(0x57a1);
    var bytes: [128]u8 = undefined;
    var diagnostic: ?Diagnostic = null;
    for (0..1024) |_| {
        const length = random.random().uintLessThan(usize, bytes.len + 1);
        random.random().bytes(bytes[0..length]);
        for ([_]?usize{ null, 0 }) |level| {
            const decoded = decode(std.testing.allocator, bytes[0..length], .{ .contents = .{ .start = 0, .end = @intCast(length) }, .long_level = level }, &diagnostic) catch |err| {
                if (err != error.Syntax) return err;
                try std.testing.expect(diagnostic != null);
                continue;
            };
            defer std.testing.allocator.free(decoded);
            try std.testing.expect(decoded.len <= length);
            try std.testing.expect(diagnostic == null);
        }
    }
}

test "every byte can be represented by decimal and hexadecimal escapes" {
    for (0..256) |value| {
        const expected = [_]u8{@intCast(value)};
        const decimal = try std.fmt.allocPrint(std.testing.allocator, "'\\{d:0>3}'", .{value});
        defer std.testing.allocator.free(decimal);
        try expectDecoded(decimal, &expected);
        const hexadecimal = try std.fmt.allocPrint(std.testing.allocator, "'\\x{x:0>2}'", .{value});
        defer std.testing.allocator.free(hexadecimal);
        try expectDecoded(hexadecimal, &expected);
    }
}

test "decoded bytes own their storage and diagnostic spans remain source relative" {
    var source = [_]u8{ 'x', 'x', 'A', '\\', 'n' };
    var diagnostic: ?Diagnostic = null;
    const decoded = try decode(std.testing.allocator, &source, .{ .contents = .{ .start = 2, .end = 5 }, .long_level = null }, &diagnostic);
    defer std.testing.allocator.free(decoded);
    source[2] = 'B';
    try std.testing.expectEqualStrings("A\n", decoded);
    try std.testing.expectError(error.Syntax, decode(std.testing.allocator, "prefix\\q", .{ .contents = .{ .start = 6, .end = 8 }, .long_level = null }, &diagnostic));
    try std.testing.expectEqual(@as(usize, 6), diagnostic.?.span.start);
    try std.testing.expectEqual(@as(usize, 8), diagnostic.?.span.end);
}
