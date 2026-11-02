const std = @import("std");
const Token = @import("Token.zig");
const Ast = @This();

arena: std.heap.ArenaAllocator,
source: []const u8,
root: *const Node,
/// Whether the chunk makes a function anywhere; see `Function.holds_function`.
holds_function: bool = true,

pub fn deinit(self: *Ast) void {
    self.arena.deinit();
    self.* = undefined;
}

/// An operator as the tree keeps it: what it is and where. A whole token is
/// over a hundred bytes, which made every node of the tree that large.
pub const Operator = struct {
    kind: Token.Kind,
    position: Token.Position,

    pub fn of(token: Token) Operator {
        return .{ .kind = token.kind, .position = token.position };
    }
};

pub const Node = struct {
    span: Token.Span,
    position: Token.Position,
    /// Logical syntax depth; parser containers and sibling lists do not add levels.
    syntax_depth: usize = 0,
    data: Data,

    pub const Data = union(enum) {
        nil,
        boolean: bool,
        number: f64,
        /// A numeral that is an integer (`numeral.Parsed`).
        integer: i64,
        string: Token.StringLiteral,
        name,
        varargs,
        group: *const Node,
        unary: struct { operator: Operator, operand: *const Node },
        binary: struct { operator: Operator, left: *const Node, right: *const Node },
        index: struct { receiver: *const Node, key: *const Node },
        field: struct { receiver: *const Node, name: Token.Span },
        call: struct { receiver: *const Node, method: ?Token.Span, method_position: ?Token.Position, arguments_position: Token.Position, arguments: []const *const Node },
        table: []const Field,
        function: Function,
        block: []const *const Node,
        empty,
        declaration: struct { global: bool, default_attribute: ?Token.Span, names: []const Binding, values: []const *const Node, wildcard: bool },
        definition: struct { scope: enum { ordinary, local, global }, target: *const Node, value: *const Node },
        assignment: struct { targets: []const *const Node, values: []const *const Node },
        conditional: struct { arms: []const Arm, otherwise: ?*const Node },
        while_loop: struct { condition: *const Node, body: *const Node, do_position: Token.Position },
        repeat_loop: struct { body: *const Node, condition: *const Node },
        numeric_for: struct { name: Token.Span, initial: *const Node, limit: *const Node, step: ?*const Node, body: *const Node, do_position: Token.Position },
        generic_for: struct { names: []const Token.Span, values: []const *const Node, body: *const Node },
        do_block: *const Node,
        break_statement,
        goto_statement: Token.Span,
        label: Token.Span,
        return_statement: []const *const Node,
    };
};

/// `varargs` is the position of a trailing `...`, or null without one;
/// `varargs_name` is the name after it in `...name`, which names the table
/// that holds the extra arguments and `n`.
/// `holds_function` says whether the body makes a function anywhere inside,
/// which the compiler asks to know a local cannot be captured. The parser
/// records it; a tree built elsewhere keeps the default, which only forgoes
/// that answer.
pub const Function = struct { parameters: []const Token.Span, varargs: ?Token.Position, varargs_name: ?Token.Span = null, implicit_self: bool, body: *const Node, holds_function: bool = true };
pub const Binding = struct { name: Token.Span, attribute: ?Token.Span };
pub const Arm = struct { condition: *const Node, body: *const Node };

pub const Field = struct {
    key: union(enum) { list, name: Token.Span, expression: *const Node },
    value: *const Node,
};

/// How deep syntax may nest; the grammar states it (doc/en/15-grammar.md).
pub const max_syntax_depth = 200;
fn deepestOf(items: []const *const Node) usize {
    var result: usize = 0;
    for (items) |item| result = @max(result, item.syntax_depth);
    return result;
}
/// Logical tree height; each branch uses its maximum, never a sibling sum.
pub fn syntaxDepth(data: Node.Data) usize {
    return switch (data) {
        .nil, .boolean, .number, .integer, .string, .name, .varargs, .empty, .break_statement, .goto_statement, .label => 0,
        .group => |child| 1 + child.syntax_depth,
        .unary => |op| 1 + op.operand.syntax_depth,
        .binary => |op| 1 + @max(op.left.syntax_depth, op.right.syntax_depth),
        .field => |op| 1 + op.receiver.syntax_depth,
        .index => |op| 1 + @max(op.receiver.syntax_depth, op.key.syntax_depth),
        .call => |op| 1 + @max(op.receiver.syntax_depth, deepestOf(op.arguments)),
        .table => |fields| blk: {
            var depth: usize = 0;
            for (fields) |field| {
                depth = @max(depth, field.value.syntax_depth);
                if (field.key == .expression) depth = @max(depth, field.key.expression.syntax_depth);
            }
            break :blk 1 + depth;
        },
        .function => |f| 1 + f.body.syntax_depth,
        .block, .return_statement => |items| deepestOf(items),
        .declaration => |d| deepestOf(d.values),
        .definition => |d| @max(d.target.syntax_depth, d.value.syntax_depth),
        .assignment => |d| @max(deepestOf(d.targets), deepestOf(d.values)),
        .do_block => |body| 1 + body.syntax_depth,
        .conditional => |c| blk: {
            var depth: usize = if (c.otherwise) |body| body.syntax_depth else 0;
            for (c.arms) |arm| depth = @max(depth, @max(arm.condition.syntax_depth, arm.body.syntax_depth));
            break :blk 1 + depth;
        },
        .while_loop => |l| 1 + @max(l.condition.syntax_depth, l.body.syntax_depth),
        .repeat_loop => |l| 1 + @max(l.condition.syntax_depth, l.body.syntax_depth),
        .numeric_for => |l| 1 + @max(@max(l.initial.syntax_depth, l.limit.syntax_depth), @max(l.body.syntax_depth, if (l.step) |step| step.syntax_depth else 0)),
        .generic_for => |l| 1 + @max(deepestOf(l.values), l.body.syntax_depth),
    };
}
