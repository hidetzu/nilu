const std = @import("std");
const loader = @import("loader.zig");
const Token = @import("Token.zig");
const chunk_id = @import("chunk_id.zig");
const Lexer = @import("Lexer.zig");

pub const Error = error{ OutOfMemory, PendingDiagnostic, InvalidSpan };
const WriteError = std.Io.Writer.Error || error{ PendingDiagnostic, InvalidSpan };

fn text(source: []const u8, span: Token.Span) error{InvalidSpan}![]const u8 {
    if (span.start > span.end or span.end > source.len) return error.InvalidSpan;
    return source[span.start..span.end];
}
fn expected(writer: *std.Io.Writer, kind: Token.Kind) std.Io.Writer.Error!void {
    switch (kind) {
        .eof => try writer.writeAll("<eof>"),
        .name => try writer.writeAll("<name>"),
        else => try writer.print("'{s}'", .{@tagName(kind)}),
    }
}
fn near(writer: *std.Io.Writer, source: []const u8, token: Token) WriteError!void {
    if (token.kind == .eof) return writer.writeAll(" near <eof>");
    const spelling = try text(source, token.span);
    if (token.kind == .invalid and spelling.len == 1 and !std.ascii.isPrint(spelling[0])) {
        try writer.print(" near '<\\{d}>'", .{spelling[0]});
    } else try writer.print(" near '{s}'", .{spelling});
}
fn body(writer: *std.Io.Writer, source: []const u8, diagnostic: loader.Diagnostic) WriteError!Token.Position {
    switch (diagnostic) {
        .parse => |detail| switch (detail) {
            .chunk_too_large => |failure| {
                try writer.print("chunk is too large (limit is {d} bytes)", .{failure.maximum});
                return .{ .offset = 0, .line = 1, .column = 1 };
            },
            .syntax_limit => |failure| {
                try writer.print("chunk has too many syntax levels (limit is {d})", .{failure.maximum});
                return failure.position;
            },
            .lexical => |failure| {
                const spelling = try text(source, failure.span);
                switch (failure.kind) {
                    .malformed_number => try writer.print("malformed number near '{s}'", .{spelling}),
                    .unfinished_string => {
                        try writer.writeAll("unfinished string");
                        if (failure.span.end == source.len) try writer.writeAll(" near <eof>") else try writer.print(" near '{s}'", .{spelling});
                    },
                    .unfinished_long_string, .unfinished_long_comment => try writer.print("unfinished long {s} (starting at line {d}) near <eof>", .{ if (failure.kind == .unfinished_long_string) "string" else "comment", failure.start.line }),
                    .invalid_long_delimiter => try writer.print("invalid long string delimiter near '{s}'", .{spelling}),
                }
                return failure.position;
            },
            .expected_expression, .invalid_statement => |token| {
                const bare_name = detail == .invalid_statement and token.kind == .name;
                try writer.writeAll(if (bare_name) "syntax error" else "unexpected symbol");
                try near(writer, source, token);
                return token.position;
            },
            .expected_for_separator => |token| {
                try writer.writeAll("'=' or 'in' expected");
                try near(writer, source, token);
                return token.position;
            },
            .expected_token => |failure| {
                if (failure.found.kind == .invalid) {
                    try writer.writeAll("unexpected symbol");
                } else {
                    try expected(writer, failure.expected);
                    try writer.writeAll(" expected");
                }
                try near(writer, source, failure.found);
                return failure.found.position;
            },
        },
        .compile => |detail| switch (detail) {
            .string => |failure| {
                const message = switch (failure.kind) {
                    .invalid_escape => "invalid escape sequence",
                    .hexadecimal_digit_expected => "hexadecimal digit expected",
                    .decimal_escape_too_large => "decimal escape too large",
                    .missing_open_brace => "missing '{'",
                    .missing_close_brace => "missing '}'",
                    .utf8_value_too_large => "UTF-8 value too large",
                    .unfinished_escape, .raw_newline => return error.PendingDiagnostic,
                };
                try writer.print("{s} near '{s}'", .{ message, try text(source, failure.near) });
                return Lexer.positionAt(source, failure.span.start);
            },
            .jumps => |failure| {
                const name = try text(source, failure.name);
                switch (failure.kind) {
                    .missing_label => try writer.print("no visible label '{s}' for <goto> at line {d}", .{ name, failure.position.line }),
                    .duplicate_label => {
                        const previous = failure.previous_position orelse return error.PendingDiagnostic;
                        try writer.print("label '{s}' already defined on line {d}", .{ name, previous.line });
                    },
                    .enters_local_scope => {
                        const related = failure.related orelse return error.PendingDiagnostic;
                        try writer.print("<goto {s}> at line {d} jumps into the scope of '{s}'", .{ name, failure.position.line, try text(source, related) });
                    },
                }
                return failure.position;
            },
            .names => |failure| {
                const name = try text(source, failure.name);
                switch (failure.kind) {
                    .undeclared_global => try writer.print("variable '{s}' not declared", .{name}),
                    .const_assignment => try writer.print("attempt to assign to const variable '{s}'", .{name}),
                    .global_environment => try writer.print("_ENV is global when accessing variable '{s}'", .{name}),
                }
                return failure.position;
            },
            .control => |failure| {
                const message = switch (failure.kind) {
                    .break_outside_loop => "break outside loop",
                    .varargs_outside_vararg_function => "cannot use '...' outside a vararg function",
                    .unsupported_attribute => {
                        try writer.print("unknown attribute '{s}'", .{try text(source, failure.span)});
                        return failure.position;
                    },
                    .multiple_to_be_closed => {
                        try writer.writeAll("multiple to-be-closed variables in local list");
                        return failure.position;
                    },
                    .global_close_attribute => {
                        try writer.writeAll("global variables cannot be to-be-closed");
                        return failure.position;
                    },
                };
                try writer.writeAll(message);
                try writer.print(" near '{s}'", .{try text(source, failure.span)});
                return failure.position;
            },
            .limit => |failure| {
                const subject = switch (failure.subject) {
                    .local_variables => "local variables",
                    .upvalues => "upvalues",
                    .registers => "registers",
                    .constants => "constants",
                };
                try writer.print("too many {s} (limit is {d})", .{ subject, failure.maximum });
                return failure.position;
            },
        },
    }
}

/// Renders only diagnosed categories whose wording is settled and implemented.
/// Unavailable diagnostic categories stay explicit; no generic syntax fallback.
/// Own the returned bytes with allocator; neither source nor diagnostic changes.
pub const Rendered = struct { bytes: []u8, position: Token.Position };
pub fn render(allocator: std.mem.Allocator, source: []const u8, name: []const u8, diagnostic: loader.Diagnostic) Error![]u8 {
    return (try renderLocated(allocator, source, name, diagnostic)).bytes;
}
pub fn renderLocated(allocator: std.mem.Allocator, source: []const u8, name: []const u8, diagnostic: loader.Diagnostic) Error!Rendered {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const position = body(&output.writer, source, diagnostic) catch |err| return switch (err) {
        error.WriteFailed => error.OutOfMemory,
        error.PendingDiagnostic => error.PendingDiagnostic,
        error.InvalidSpan => error.InvalidSpan,
    };
    var id: [chunk_id.capacity]u8 = undefined;
    return .{
        .bytes = try std.fmt.allocPrint(allocator, "{s}:{d}:{d}: {s}", .{ chunk_id.format(&id, name), position.line, position.column, output.written() }),
        .position = position,
    };
}
