//! Synthetic ASTs for downstream traversal stress, independent of source limits.
const std = @import("std");
const Ast = @import("Ast.zig");
const Token = @import("Token.zig");
const position = Token.Position{ .offset = 0, .line = 1, .column = 1 };
pub fn addition(allocator: std.mem.Allocator, count: usize, chunk: bool) !Ast {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const leaf = try a.create(Ast.Node);
    leaf.* = .{ .span = .{ .start = 0, .end = 1 }, .position = position, .data = .{ .number = 1 } };
    var root: *const Ast.Node = leaf;
    for (0..count) |i| {
        const node = try a.create(Ast.Node);
        node.* = .{ .span = leaf.span, .position = position, .syntax_depth = i + 1, .data = .{ .binary = .{ .operator = .{ .kind = .@"+", .position = position }, .left = root, .right = leaf } } };
        root = node;
    }
    if (chunk) {
        const values = try a.alloc(*const Ast.Node, 1);
        values[0] = root;
        const returned = try a.create(Ast.Node);
        returned.* = .{ .span = leaf.span, .position = position, .syntax_depth = count, .data = .{ .return_statement = values } };
        const statements = try a.alloc(*const Ast.Node, 1);
        statements[0] = returned;
        const block = try a.create(Ast.Node);
        block.* = .{ .span = leaf.span, .position = position, .syntax_depth = count, .data = .{ .block = statements } };
        root = block;
    }
    return .{ .arena = arena, .source = "1", .root = root };
}
