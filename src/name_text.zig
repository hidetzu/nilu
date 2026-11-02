//! Resolve bytecode names to bytes while keeping ownership explicit.
//! This is internal text preparation, not the public calledas lifetime contract.
const std = @import("std");
const bytecode = @import("bytecode.zig");
const decoder = @import("string_literal.zig");

pub const Error = error{ OutOfMemory, InvalidSpan };
pub const Text = struct {
    bytes: []const u8,
    allocation: ?[]u8 = null,

    /// Borrowed source/static text is never freed; decoded text owns one buffer.
    pub fn deinit(text: Text, allocator: std.mem.Allocator) void {
        if (text.allocation) |bytes| allocator.free(bytes);
    }
};

/// Preserve all decoded bytes, including NUL. Presentation decides whether
/// to display a prefix; source spans are borrowed only for the caller's use.
pub fn resolve(allocator: std.mem.Allocator, source: []const u8, name: bytecode.Name) Error!Text {
    return switch (name.text) {
        .environment => .{ .bytes = "_ENV" },
        .iterator => .{ .bytes = "for iterator" },
        .fixed => |bytes| .{ .bytes = bytes },
        .span => |span| blk: {
            if (span.start > span.end or span.end > source.len) return error.InvalidSpan;
            break :blk .{ .bytes = source[span.start..span.end] };
        },
        .literal => |wide| blk: {
            // The decoder reads the front end's 32-bit spans; a span that does
            // not fit came from malformed bytecode, like one past the source.
            const literal: @import("Token.zig").StringLiteral = .{
                .contents = .{
                    .start = std.math.cast(u32, wide.contents.start) orelse return error.InvalidSpan,
                    .end = std.math.cast(u32, wide.contents.end) orelse return error.InvalidSpan,
                },
                .long_level = wide.long_level,
            };
            var diagnostic: ?decoder.Diagnostic = null;
            const bytes = decoder.decode(allocator, source, literal, &diagnostic) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidSpan, error.Syntax => error.InvalidSpan,
            };
            break :blk .{ .bytes = bytes, .allocation = bytes };
        },
    };
}
