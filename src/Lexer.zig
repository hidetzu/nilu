const std = @import("std");
const numeral = @import("numeral.zig");
const Token = @import("Token.zig");
const Lexer = @This();

source: []const u8,
cursor: usize = 0,
line: usize = 1,
column: usize = 1,
diagnostic: ?Diagnostic = null,

pub const DiagnosticKind = enum { malformed_number, unfinished_string, unfinished_long_string, unfinished_long_comment, invalid_long_delimiter };
pub const Diagnostic = struct {
    kind: DiagnosticKind,
    start: Token.Position,
    position: Token.Position,
    span: Token.Span,
};

const Delimiter = union(enum) {
    single,
    invalid,
    long: struct { level: usize, end: usize },
};

pub fn init(source: []const u8) Lexer {
    return .{ .source = source };
}

pub fn newlineWidth(source: []const u8, offset: usize) usize {
    if (offset >= source.len or (source[offset] != '\n' and source[offset] != '\r')) return 0;
    if (source.len - offset >= 2 and (source[offset + 1] == '\n' or source[offset + 1] == '\r') and source[offset] != source[offset + 1]) return 2;
    return 1;
}

pub const isSpace = numeral.isSpace;

/// The line and byte column of `offset`, counted from the start of `source`.
/// Only failure paths need this, so a linear scan is enough.
pub fn positionAt(source: []const u8, offset: usize) Token.Position {
    var result = Token.Position{ .offset = 0, .line = 1, .column = 1 };
    const end = @min(offset, source.len);
    while (result.offset < end) {
        const newline = newlineWidth(source, result.offset);
        if (newline > 0) {
            result.offset += @intCast(newline);
            result.line +|= 1;
            result.column = 1;
        } else {
            result.offset += 1;
            result.column +|= 1;
        }
    }
    return result;
}

/// Where each line of a source starts, for a pass that needs the line and
/// column of many offsets: `positionAt` scans from the start every time, so a
/// compiler that asked it for every declaration took time in the square of
/// the source's size. Built once in one scan, it answers in a binary search,
/// and agrees with `positionAt` at every offset.
pub const Lines = struct {
    /// The offset of each line's first byte; the first line starts at 0.
    starts: []const usize,

    /// The caller frees `starts` with the same allocator.
    pub fn init(allocator: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error!Lines {
        var starts: std.ArrayList(usize) = .empty;
        errdefer starts.deinit(allocator);
        try starts.append(allocator, 0);
        var offset: usize = 0;
        while (offset < source.len) {
            const newline = newlineWidth(source, offset);
            if (newline > 0) {
                offset += newline;
                try starts.append(allocator, offset);
            } else offset += 1;
        }
        return .{ .starts = try starts.toOwnedSlice(allocator) };
    }

    pub fn deinit(lines: Lines, allocator: std.mem.Allocator) void {
        allocator.free(lines.starts);
    }

    pub fn positionAt(lines: Lines, source: []const u8, offset: usize) Token.Position {
        const end = @min(offset, source.len);
        // The last line that starts at or before `end`.
        var low: usize = 0;
        var high: usize = lines.starts.len;
        while (high - low > 1) {
            const middle = low + (high - low) / 2;
            if (lines.starts[middle] <= end) low = middle else high = middle;
        }
        const start = lines.starts[low];
        // An offset inside a two-byte newline: the scan steps over the pair and
        // stops past it, on the next line.
        if (end > start) {
            const before = end - 1;
            if (newlineWidth(source, before) == 2) return .{ .offset = @intCast(before + 2), .line = @intCast(low + 2), .column = 1 };
        }
        return .{ .offset = @intCast(end), .line = @intCast(low + 1), .column = @intCast(end - start + 1) };
    }
};

fn position(self: *const Lexer) Token.Position {
    // The parser refused a source past `Token.max_source_bytes`, so each fits.
    return .{ .offset = @intCast(self.cursor), .line = @intCast(self.line), .column = @intCast(self.column) };
}

fn advance(self: *Lexer) void {
    if (self.cursor == self.source.len) return;
    const newline = newlineWidth(self.source, self.cursor);
    if (newline != 0) {
        self.cursor += newline;
        self.line +|= 1;
        self.column = 1;
    } else {
        self.cursor += 1;
        self.column +|= 1;
    }
}

fn token(self: *const Lexer, kind: Token.Kind, start: Token.Position) Token {
    return .{ .kind = kind, .position = start, .span = .{ .start = start.offset, .end = @intCast(self.cursor) } };
}

fn fail(self: *Lexer, kind: DiagnosticKind, start: Token.Position) error{Syntax} {
    self.diagnostic = .{
        .kind = kind,
        .start = start,
        .position = if (kind == .malformed_number) start else self.position(),
        .span = .{ .start = start.offset, .end = @intCast(self.cursor) },
    };
    return error.Syntax;
}

fn delimiter(self: *const Lexer, offset: usize, bracket: u8) Delimiter {
    if (offset >= self.source.len or self.source[offset] != bracket) return .single;
    var cursor = offset + 1;
    while (cursor < self.source.len and self.source[cursor] == '=') cursor += 1;
    if (cursor < self.source.len and self.source[cursor] == bracket) return .{ .long = .{ .level = cursor - offset - 1, .end = cursor + 1 } };
    return if (cursor == offset + 1) .single else .invalid;
}

fn longString(self: *Lexer, start: Token.Position, opening: Delimiter, comment: bool) error{Syntax}!Token {
    const opened = opening.long;
    while (self.cursor < opened.end) self.advance();
    const contents_start = self.cursor;
    while (self.cursor < self.source.len) {
        if (self.source[self.cursor] == ']') {
            switch (self.delimiter(self.cursor, ']')) {
                .long => |closing| if (closing.level == opened.level) {
                    const contents_end = self.cursor;
                    while (self.cursor < closing.end) self.advance();
                    var result = self.token(.string, start);
                    result.string = .{ .contents = .{ .start = @intCast(contents_start), .end = @intCast(contents_end) }, .long_level = opened.level };
                    return result;
                },
                else => {},
            }
        }
        self.advance();
    }
    return self.fail(if (comment) .unfinished_long_comment else .unfinished_long_string, start);
}

fn quotedString(self: *Lexer, start: Token.Position, quote: u8) error{Syntax}!Token {
    self.advance();
    const contents_start = self.cursor;
    while (self.cursor < self.source.len) {
        const byte = self.source[self.cursor];
        if (byte == quote) {
            const contents_end = self.cursor;
            self.advance();
            var result = self.token(.string, start);
            result.string = .{ .contents = .{ .start = @intCast(contents_start), .end = @intCast(contents_end) }, .long_level = null };
            return result;
        }
        if (newlineWidth(self.source, self.cursor) != 0) return self.fail(.unfinished_string, start);
        if (byte == '\\') {
            self.advance();
            if (self.cursor < self.source.len and self.source[self.cursor] == 'z') {
                self.advance();
                while (self.cursor < self.source.len and isSpace(self.source[self.cursor])) self.advance();
            } else self.advance();
        } else self.advance();
    }
    return self.fail(.unfinished_string, start);
}

fn number(self: *Lexer, start: Token.Position) error{Syntax}!Token {
    const hexadecimal = self.source.len - self.cursor >= 2 and self.source[self.cursor] == '0' and (self.source[self.cursor + 1] == 'x' or self.source[self.cursor + 1] == 'X');
    self.advance();
    if (hexadecimal) self.advance();
    while (self.cursor < self.source.len) {
        const byte = self.source[self.cursor];
        if (numeral.isExponent(byte, hexadecimal)) {
            self.advance();
            if (self.cursor < self.source.len and (self.source[self.cursor] == '+' or self.source[self.cursor] == '-')) self.advance();
        } else if (std.ascii.isHex(byte) or byte == '.') self.advance() else break;
    }
    if (self.cursor < self.source.len and isNameStart(self.source[self.cursor])) self.advance();
    const value = numeral.parse(self.source[start.offset..self.cursor]) orelse return self.fail(.malformed_number, start);
    var result = self.token(.number, start);
    switch (value) {
        .integer => |n| result.integer = n,
        .float => |f| result.number = f,
    }
    return result;
}

fn isNameStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_';
}

pub fn next(self: *Lexer) error{Syntax}!Token {
    if (self.diagnostic != null) return error.Syntax;
    while (self.cursor < self.source.len) {
        if (isSpace(self.source[self.cursor])) {
            self.advance();
            continue;
        }
        if (self.source[self.cursor] == '-' and self.source.len - self.cursor >= 2 and self.source[self.cursor + 1] == '-') {
            const start = self.position();
            self.advance();
            self.advance();
            if (self.cursor < self.source.len and self.source[self.cursor] == '[') {
                const opening = self.delimiter(self.cursor, '[');
                if (opening == .long) {
                    _ = try self.longString(start, opening, true);
                    continue;
                }
            }
            while (self.cursor < self.source.len and newlineWidth(self.source, self.cursor) == 0) self.advance();
            continue;
        }
        break;
    }
    const start = self.position();
    if (self.cursor == self.source.len) return self.token(.eof, start);
    const byte = self.source[self.cursor];
    if (isNameStart(byte)) {
        self.advance();
        while (self.cursor < self.source.len and (isNameStart(self.source[self.cursor]) or std.ascii.isDigit(self.source[self.cursor]))) self.advance();
        return self.token(Token.keywords.get(self.source[start.offset..self.cursor]) orelse .name, start);
    }
    if (std.ascii.isDigit(byte) or (byte == '.' and self.source.len - self.cursor >= 2 and std.ascii.isDigit(self.source[self.cursor + 1]))) return self.number(start);
    if (byte == '"' or byte == '\'') return self.quotedString(start, byte);
    if (byte == '[') switch (self.delimiter(self.cursor, '[')) {
        .long => |opening| return self.longString(start, .{ .long = opening }, false),
        .invalid => {
            self.advance();
            while (self.cursor < self.source.len and self.source[self.cursor] == '=') self.advance();
            return self.fail(.invalid_long_delimiter, start);
        },
        .single => {},
    };
    self.advance();
    const next_byte: ?u8 = if (self.cursor < self.source.len) self.source[self.cursor] else null;
    const paired: ?Token.Kind = switch (byte) {
        '=' => if (next_byte == '=') .@"==" else null,
        '<' => if (next_byte == '=') .@"<=" else if (next_byte == '<') .@"<<" else null,
        '>' => if (next_byte == '=') .@">=" else if (next_byte == '>') .@">>" else null,
        '~' => if (next_byte == '=') .@"~=" else null,
        '/' => if (next_byte == '/') .@"//" else null,
        ':' => if (next_byte == ':') .@"::" else null,
        '.' => if (next_byte == '.') .@".." else null,
        else => null,
    };
    if (paired) |kind| {
        self.advance();
        if (kind == .@".." and self.cursor < self.source.len and self.source[self.cursor] == '.') {
            self.advance();
            return self.token(.@"...", start);
        }
        return self.token(kind, start);
    }
    const kind: Token.Kind = switch (byte) {
        inline '+', '-', '*', '/', '%', '^', '#', '.', '=', '<', '>', '&', '|', '~', '(', ')', '{', '}', '[', ']', ';', ':', ',' => |symbol| @field(Token.Kind, &.{symbol}),
        else => .invalid,
    };
    return self.token(kind, start);
}

test "every recorded reserved word is recognized and global remains a name" {
    const words = "and break do else elseif end false for function goto if in local nil not or repeat return then true until while";
    var scanner = init(words);
    var expected = std.mem.tokenizeScalar(u8, words, ' ');
    while (expected.next()) |word| try std.testing.expectEqualStrings(word, @tagName((try scanner.next()).kind));
    try std.testing.expectEqual(Token.Kind.eof, (try scanner.next()).kind);
    scanner = init("global global1 _name falsehood");
    for (0..4) |_| try std.testing.expectEqual(Token.Kind.name, (try scanner.next()).kind);
}

test "punctuation is kept separate with longest matching operators" {
    const symbols = "+ - * / // % ^ # . .. ... = == ~= < <= > >= ( ) { } [ ] ; : :: ,";
    var scanner = init(symbols);
    var expected = std.mem.tokenizeScalar(u8, symbols, ' ');
    while (expected.next()) |symbol| try std.testing.expectEqualStrings(symbol, @tagName((try scanner.next()).kind));
    try std.testing.expectEqual(Token.Kind.eof, (try scanner.next()).kind);
}

test "number scanning does not absorb signs belonging to operators" {
    var scanner = init("3-4 0xe+1 0x1p-2 .5 3.");
    const expected = [_]Token.Kind{ .number, .@"-", .number, .number, .@"+", .number, .number, .number, .number, .eof };
    for (expected) |kind| try std.testing.expectEqual(kind, (try scanner.next()).kind);
    scanner = init("0xe 0x1p-2 .5 3.");
    // `0xe` is an integer; the others are floats.
    try std.testing.expectEqual(@as(?i64, 14), (try scanner.next()).integer);
    for ([_]f64{ 0.25, 0.5, 3 }) |value| try std.testing.expectEqual(value, (try scanner.next()).number.?);
}

test "malformed numbers point to their first byte and remain failures" {
    for ([_][]const u8{ "1_0", "0b101", "1e+", "0x", "0x1p", "3..4", "12word" }) |text| {
        var scanner = init(text);
        try std.testing.expectError(error.Syntax, scanner.next());
        try std.testing.expectEqual(DiagnosticKind.malformed_number, scanner.diagnostic.?.kind);
        try std.testing.expectEqual(@as(usize, 0), scanner.diagnostic.?.position.offset);
        const stopped = scanner.cursor;
        try std.testing.expectError(error.Syntax, scanner.next());
        try std.testing.expectEqual(stopped, scanner.cursor);
    }
    var scanner = init("\r\n  1_0");
    try std.testing.expectError(error.Syntax, scanner.next());
    try std.testing.expectEqual(Token.Position{ .offset = 4, .line = 2, .column = 3 }, scanner.diagnostic.?.position);
}

test "comments and whitespace leave following code on the same line visible" {
    var scanner = init("-- first\r\n--[==[ ignored\n]=] still ignored ]==] \x0b\x0c local x -- tail");
    const local = try scanner.next();
    try std.testing.expectEqual(Token.Kind.local, local.kind);
    try std.testing.expectEqual(@as(usize, 3), local.position.line);
    try std.testing.expectEqual(Token.Kind.name, (try scanner.next()).kind);
    try std.testing.expectEqual(Token.Kind.eof, (try scanner.next()).kind);
    scanner = init("--[=not a long comment\nreturn");
    try std.testing.expectEqual(Token.Kind.@"return", (try scanner.next()).kind);
}

test "all newline forms advance one line per paired break" {
    var scanner = init("a\r\nb\n\rc\rd\ne\r\rf");
    for ([_]usize{ 1, 2, 3, 4, 5, 7 }) |line| {
        const result = try scanner.next();
        try std.testing.expectEqual(line, result.position.line);
        try std.testing.expectEqual(@as(usize, 1), result.position.column);
    }
}

test "short string contents remain raw and escaped delimiters do not close them" {
    const source = "\"a\\\"b\" 'c\\'d' \"\\x41\\065\\u{3042}\"";
    var scanner = init(source);
    for ([_][]const u8{ "a\\\"b", "c\\'d", "\\x41\\065\\u{3042}" }) |contents| {
        const result = try scanner.next();
        try std.testing.expectEqual(Token.Kind.string, result.kind);
        const literal = result.string.?;
        try std.testing.expectEqual(@as(?usize, null), literal.long_level);
        try std.testing.expectEqualStrings(contents, source[literal.contents.start..literal.contents.end]);
    }
}

test "escaped line breaks and z escapes do not terminate short strings" {
    const source = "\"a\\\r\nb\" \"c\\z \r\n\t d\" next";
    var scanner = init(source);
    try std.testing.expectEqual(Token.Kind.string, (try scanner.next()).kind);
    try std.testing.expectEqual(Token.Kind.string, (try scanner.next()).kind);
    const following = try scanner.next();
    try std.testing.expectEqual(Token.Kind.name, following.kind);
    try std.testing.expectEqual(@as(usize, 3), following.position.line);
}

test "long strings retain raw newlines and the matching delimiter level" {
    const source = "[==[\r\na]=]b\\n]==]x";
    var scanner = init(source);
    const result = try scanner.next();
    const literal = result.string.?;
    try std.testing.expectEqual(@as(?usize, 2), literal.long_level);
    try std.testing.expectEqualStrings("\r\na]=]b\\n", source[literal.contents.start..literal.contents.end]);
    try std.testing.expectEqual(Token.Kind.name, (try scanner.next()).kind);
}

test "unfinished literals and invalid delimiters give structured failures" {
    const cases = .{
        .{ "\"abc", DiagnosticKind.unfinished_string },
        .{ "'abc\n", DiagnosticKind.unfinished_string },
        .{ "[[abc", DiagnosticKind.unfinished_long_string },
        .{ "--[==[abc\n", DiagnosticKind.unfinished_long_comment },
        .{ "[=x", DiagnosticKind.invalid_long_delimiter },
    };
    inline for (cases) |entry| {
        var scanner = init(entry[0]);
        try std.testing.expectError(error.Syntax, scanner.next());
        try std.testing.expectEqual(entry[1], scanner.diagnostic.?.kind);
    }
    var scanner = init("[=x");
    try std.testing.expectError(error.Syntax, scanner.next());
    const span = scanner.diagnostic.?.span;
    try std.testing.expectEqualStrings("[=", scanner.source[span.start..span.end]);
}

test "positions count bytes and unknown bytes are not ASCII names" {
    var scanner = init("あx");
    for (1..4) |column| {
        const result = try scanner.next();
        try std.testing.expectEqual(Token.Kind.invalid, result.kind);
        try std.testing.expectEqual(column, result.position.column);
    }
    const name = try scanner.next();
    try std.testing.expectEqual(Token.Kind.name, name.kind);
    try std.testing.expectEqual(@as(usize, 4), name.position.column);
}

test "arbitrary bytes either advance to EOF or produce a bounded diagnostic" {
    var bytes: [96]u8 = undefined;
    var seed: u64 = 0x123456789abcdef;
    for (0..512) |iteration| {
        for (&bytes) |*byte| {
            seed = seed *% 6364136223846793005 +% 1442695040888963407;
            byte.* = @truncate(seed >> 32);
        }
        var scanner = init(bytes[0 .. iteration % bytes.len]);
        var finished = false;
        for (0..scanner.source.len + 1) |_| {
            const previous = scanner.cursor;
            const result = scanner.next() catch {
                try std.testing.expect(scanner.diagnostic != null);
                finished = true;
                break;
            };
            try std.testing.expect(result.span.end <= scanner.source.len);
            if (result.kind == .eof) {
                try std.testing.expectEqual(scanner.source.len, scanner.cursor);
                finished = true;
                break;
            }
            try std.testing.expect(scanner.cursor > previous);
        }
        try std.testing.expect(finished);
    }
}

test "a line table answers every offset as positionAt does" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x6e696c75);
    const random = prng.random();
    const alphabet = "ab \n\r\t";
    var buffer: [96]u8 = undefined;
    const fixed = [_][]const u8{ "", "\n", "\r", "\r\n", "\n\r", "\r\r", "\n\n", "a\r\nb", "\r\n\r\n", "x\n\ry\r\rz" };
    var round: usize = 0;
    while (round < fixed.len + 400) : (round += 1) {
        const source = if (round < fixed.len) fixed[round] else blk: {
            const length = random.uintLessThan(usize, buffer.len);
            for (buffer[0..length]) |*byte| byte.* = alphabet[random.uintLessThan(usize, alphabet.len)];
            break :blk buffer[0..length];
        };
        const lines = try Lines.init(allocator, source);
        defer lines.deinit(allocator);
        var offset: usize = 0;
        while (offset <= source.len + 2) : (offset += 1) {
            try std.testing.expectEqual(positionAt(source, offset), lines.positionAt(source, offset));
        }
    }
}
