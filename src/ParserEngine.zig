const std = @import("std");
const Ast = @import("Ast.zig");
const Lexer = @import("Lexer.zig");
const Token = @import("Token.zig");
const parser = @import("parser.zig");
const Error = parser.Error;
const Node = *const Ast.Node;
const Nodes = []const Node;
const Engine = @This();
allocator: std.mem.Allocator,
lexer: Lexer,
current: Token = undefined,
diagnostic: *?parser.Diagnostic,
tasks: std.ArrayList(Task) = .empty,
/// How many function nodes have been made: a body holds a function when the
/// count grew while it was parsed.
functions_made: usize = 0,
result: Node = undefined,
list_result: Nodes = &.{},

const Expr = struct { depth: usize, minimum: u8 = 1 };
const Binary = struct { expr: Expr, left: Node, operator: Token };
const Prefix = struct { expr: Expr, operator: Token };
const Group = struct { depth: usize, opening: Token };
const Suffix = struct { depth: usize, receiver: Node };
const Index = struct { suffix: Suffix };
const List = struct { depth: usize, nodes: std.ArrayList(Node) = .empty };
const Block = struct { depth: usize, start: Token.Position, nodes: std.ArrayList(Node) = .empty };
const BlockAdd = struct { block: *Block, returned: bool };
const Call = struct { suffix: Suffix, opening: Token, method: ?Token.Span = null, method_position: ?Token.Position = null, arguments_position: Token.Position, arguments: std.ArrayList(Node) = .empty };
const Table = struct { depth: usize, opening: Token, fields: std.ArrayList(Ast.Field) = .empty, key: @FieldType(Ast.Field, "key") = .list };
const Function = struct { depth: usize, start: Token.Position, parameters: []const Token.Span, varargs: ?Token.Position, varargs_name: ?Token.Span, implicit_self: bool, functions_before: usize };
const Declaration = struct { depth: usize, first: Token, global: bool, attribute: ?Token.Span, names: []const Ast.Binding };
const Definition = struct { depth: usize, first: Token, scope: @FieldType(@FieldType(Ast.Node.Data, "definition"), "scope"), target: Node };
const Assignment = struct { depth: usize, first: Token, targets: std.ArrayList(Node) = .empty };
const Conditional = struct { depth: usize, first: Token, condition: Node = undefined, arms: std.ArrayList(Ast.Arm) = .empty, otherwise: ?Node = null };
const Loop = struct { depth: usize, first: Token, condition: Node = undefined, body: Node = undefined, opening: Token = undefined };
const For = struct { depth: usize, first: Token, name: Token, numeric: bool, names: std.ArrayList(Token.Span) = .empty, initial: Node = undefined, limit: Node = undefined, step: ?Node = null, values: Nodes = &.{}, opening: Token = undefined };
const Task = union(enum) {
    expression: Expr,
    prefix: Prefix,
    expression_loop: Expr,
    binary: Binary,
    primary: usize,
    group: Group,
    suffix: Suffix,
    index: Index,
    call_argument: *Call,
    call_sugar: *Call,
    table_next: *Table,
    table_key: *Table,
    table_first: *Table,
    table_value: *Table,
    function: *Function,
    list: usize,
    list_next: *List,
    block: usize,
    block_next: *Block,
    block_add: BlockAdd,
    statement: usize,
    returned: Group,
    do_done: Group,
    declaration: *Declaration,
    definition: Definition,
    assignment_target: *Assignment,
    assignment: *Assignment,
    if_condition: *Conditional,
    if_body: *Conditional,
    if_else: *Conditional,
    while_condition: *Loop,
    while_body: *Loop,
    repeat_body: *Loop,
    repeat_condition: *Loop,
    for_initial: *For,
    for_limit: *For,
    for_step: *For,
    for_values: *For,
    for_body: *For,
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8, diagnostic: *?parser.Diagnostic, chunk: bool) Error!Ast {
    diagnostic.* = null;
    if (source.len > Token.max_source_bytes) {
        diagnostic.* = .{ .chunk_too_large = .{ .maximum = Token.max_source_bytes } };
        return error.Syntax;
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var self = Engine{ .allocator = arena.allocator(), .lexer = Lexer.init(source), .diagnostic = diagnostic };
    try self.advance();
    try self.push(if (chunk) .{ .block = 0 } else .{ .expression = .{ .depth = 0 } });
    while (self.tasks.pop()) |task| try self.step(task);
    _ = try self.expect(.eof);
    return .{ .arena = arena, .source = source, .root = self.result, .holds_function = self.functions_made > 0 };
}
fn frame(self: *Engine, comptime T: type, value: T) Error!*T {
    const result = try self.allocator.create(T);
    result.* = value;
    return result;
}
fn push(self: *Engine, task: Task) Error!void {
    try self.tasks.append(self.allocator, task);
}
fn advance(self: *Engine) Error!void {
    self.current = self.lexer.next() catch {
        self.diagnostic.* = .{ .lexical = self.lexer.diagnostic.? };
        return error.Syntax;
    };
}
fn expect(self: *Engine, kind: Token.Kind) Error!Token {
    if (self.current.kind != kind) {
        self.diagnostic.* = .{ .expected_token = .{ .expected = kind, .found = self.current } };
        return error.Syntax;
    }
    const found = self.current;
    if (kind != .eof) try self.advance();
    return found;
}
fn check(self: *Engine, depth: usize, position: Token.Position) Error!void {
    if (depth > Ast.max_syntax_depth) {
        self.diagnostic.* = .{ .syntax_limit = .{ .position = position, .maximum = Ast.max_syntax_depth } };
        return error.Syntax;
    }
}
fn enter(self: *Engine, depth: usize, position: Token.Position) Error!usize {
    try self.check(depth + 1, position);
    return depth + 1;
}
fn make(self: *Engine, depth: usize, start: Token.Position, end: usize, data: Ast.Node.Data) Error!Node {
    const logical = Ast.syntaxDepth(data);
    try self.check(depth + logical, start);
    const node = try self.allocator.create(Ast.Node);
    node.* = .{ .span = .{ .start = start.offset, .end = @intCast(end) }, .position = start, .syntax_depth = logical, .data = data };
    return node;
}
fn precedence(kind: Token.Kind) u8 {
    return switch (kind) {
        .@"or" => 1,
        .@"and" => 2,
        .@"<", .@">", .@"<=", .@">=", .@"~=", .@"==" => 3,
        .@"|" => 4,
        .@"~" => 5,
        .@"&" => 6,
        .@"<<", .@">>" => 7,
        .@".." => 8,
        .@"+", .@"-" => 9,
        .@"*", .@"/", .@"//", .@"%" => 10,
        .@"^" => 12,
        else => 0,
    };
}
fn terminates(kind: Token.Kind) bool {
    return switch (kind) {
        .eof, .end, .@"else", .elseif, .until => true,
        else => false,
    };
}
fn attribute(self: *Engine) Error!?Token.Span {
    if (self.current.kind != .@"<") return null;
    try self.advance();
    const name = try self.expect(.name);
    _ = try self.expect(.@">");
    return name.span;
}
fn invalid(self: *Engine, first: Token) Error {
    self.diagnostic.* = .{ .invalid_statement = first };
    return error.Syntax;
}
fn finishCall(self: *Engine, call: *Call, end: usize) Error!void {
    const receiver = try self.make(call.suffix.depth, call.suffix.receiver.position, end, .{ .call = .{ .receiver = call.suffix.receiver, .method = call.method, .method_position = call.method_position, .arguments_position = call.arguments_position, .arguments = try call.arguments.toOwnedSlice(self.allocator) } });
    try self.push(.{ .suffix = .{ .depth = call.suffix.depth, .receiver = receiver } });
}
fn beginCall(self: *Engine, suffix: Suffix) Error!void {
    const opening = self.current;
    try self.check(suffix.depth + 1 + suffix.receiver.syntax_depth, opening.position);
    const call = try self.frame(Call, .{ .suffix = suffix, .opening = opening, .arguments_position = undefined });
    if (self.current.kind == .@":") {
        try self.advance();
        const name = try self.expect(.name);
        call.method = name.span;
        call.method_position = name.position;
    }
    call.arguments_position = self.current.position;
    if (self.current.kind == .string) {
        var offset = self.current.span.start;
        while (offset + 1 < self.current.span.end) {
            const c = self.lexer.source[offset];
            offset += 1;
            if (c == '\r' or c == '\n') {
                if (offset + 1 < self.current.span.end and self.lexer.source[offset] != c and (self.lexer.source[offset] == '\r' or self.lexer.source[offset] == '\n')) offset += 1;
                call.arguments_position.line += 1;
                call.arguments_position.column = 1;
            } else call.arguments_position.column += 1;
        }
        call.arguments_position.offset = offset;
    }
    switch (self.current.kind) {
        .@"(" => {
            try self.advance();
            if (self.current.kind == .@")") return self.finishCall(call, (try self.expect(.@")")).span.end);
            try self.push(.{ .call_argument = call });
            try self.push(.{ .expression = .{ .depth = suffix.depth + 1 } });
        },
        .@"{", .string => {
            try self.push(.{ .call_sugar = call });
            try self.push(.{ .expression = .{ .depth = suffix.depth + 1, .minimum = 9 } });
        },
        else => {
            _ = try self.expect(.@"(");
            unreachable;
        },
    }
}
fn finishTable(self: *Engine, table: *Table) Error!void {
    const closing = try self.expect(.@"}");
    self.result = try self.make(table.depth, table.opening.position, closing.span.end, .{ .table = try table.fields.toOwnedSlice(self.allocator) });
}
fn addField(self: *Engine, table: *Table, value: Node) Error!void {
    try table.fields.append(self.allocator, .{ .key = table.key, .value = value });
    table.key = .list;
    if (self.current.kind == .@"," or self.current.kind == .@";") {
        try self.advance();
        try self.push(.{ .table_next = table });
    } else try self.finishTable(table);
}
fn beginFunction(self: *Engine, depth: usize, start: Token.Position, cause: Token.Position, implicit_self: bool) Error!void {
    _ = try self.enter(depth, cause);
    _ = try self.expect(.@"(");
    var parameters: std.ArrayList(Token.Span) = .empty;
    var varargs: ?Token.Position = null;
    var varargs_name: ?Token.Span = null;
    if (self.current.kind != .@")") while (true) {
        if (self.current.kind == .@"...") {
            varargs = self.current.position;
            try self.advance();
            if (self.current.kind == .name) {
                varargs_name = self.current.span;
                try self.advance();
            }
            break;
        }
        try parameters.append(self.allocator, (try self.expect(.name)).span);
        if (self.current.kind != .@",") break;
        try self.advance();
    };
    _ = try self.expect(.@")");
    try self.push(.{ .function = try self.frame(Function, .{ .depth = depth, .start = start, .parameters = try parameters.toOwnedSlice(self.allocator), .varargs = varargs, .varargs_name = varargs_name, .implicit_self = implicit_self, .functions_before = self.functions_made }) });
    try self.push(.{ .block = depth + 1 });
}
fn beginDeclaration(self: *Engine, depth: usize, first: Token, global: bool) Error!void {
    try self.advance();
    if (self.current.kind == .function) {
        const cause = self.current.position;
        _ = try self.enter(depth, cause);
        try self.advance();
        const name = try self.expect(.name);
        const target = try self.make(depth, name.position, name.span.end, .name);
        try self.push(.{ .definition = .{ .depth = depth, .first = first, .scope = if (global) .global else .local, .target = target } });
        return self.beginFunction(depth, first.position, cause, false);
    }
    const default = try self.attribute();
    if (global and self.current.kind == .@"*") {
        const wildcard = self.current;
        try self.advance();
        self.result = try self.make(depth, first.position, wildcard.span.end, .{ .declaration = .{ .global = true, .default_attribute = default, .names = &.{}, .values = &.{}, .wildcard = true } });
        return;
    }
    var names: std.ArrayList(Ast.Binding) = .empty;
    while (true) {
        const name = try self.expect(.name);
        try names.append(self.allocator, .{ .name = name.span, .attribute = try self.attribute() });
        if (self.current.kind != .@",") break;
        try self.advance();
    }
    const decl = try self.frame(Declaration, .{ .depth = depth, .first = first, .global = global, .attribute = default, .names = try names.toOwnedSlice(self.allocator) });
    try self.push(.{ .declaration = decl });
    if (self.current.kind == .@"=") {
        try self.advance();
        try self.push(.{ .list = depth });
    } else self.list_result = &.{};
}
fn finishIf(self: *Engine, c: *Conditional) Error!void {
    const closing = try self.expect(.end);
    self.result = try self.make(c.depth, c.first.position, closing.span.end, .{ .conditional = .{ .arms = try c.arms.toOwnedSlice(self.allocator), .otherwise = c.otherwise } });
}
fn forBody(self: *Engine, f: *For) Error!void {
    f.opening = try self.expect(.do);
    try self.push(.{ .for_body = f });
    try self.push(.{ .block = f.depth + 1 });
}
fn statement(self: *Engine, depth: usize) Error!void {
    const first = self.current;
    switch (first.kind) {
        .local => try self.beginDeclaration(depth, first, false),
        .@";", .@"break" => {
            try self.advance();
            self.result = try self.make(depth, first.position, first.span.end, if (first.kind == .@";") .empty else .break_statement);
        },
        .goto, .@"::" => {
            try self.advance();
            const name = try self.expect(.name);
            const end = if (first.kind == .@"::") (try self.expect(.@"::")).span.end else name.span.end;
            self.result = try self.make(depth, first.position, end, if (first.kind == .goto) .{ .goto_statement = name.span } else .{ .label = name.span });
        },
        .@"return" => {
            try self.advance();
            try self.push(.{ .returned = .{ .depth = depth, .opening = first } });
            if (terminates(self.current.kind) or self.current.kind == .@";") self.list_result = &.{} else try self.push(.{ .list = depth });
        },
        .do => {
            const nested = try self.enter(depth, first.position);
            try self.advance();
            try self.push(.{ .do_done = .{ .depth = depth, .opening = first } });
            try self.push(.{ .block = nested });
        },
        .@"while", .repeat => {
            const nested = try self.enter(depth, first.position);
            try self.advance();
            const loop = try self.frame(Loop, .{ .depth = depth, .first = first });
            if (first.kind == .@"while") {
                try self.push(.{ .while_condition = loop });
                try self.push(.{ .expression = .{ .depth = nested } });
            } else {
                try self.push(.{ .repeat_body = loop });
                try self.push(.{ .block = nested });
            }
        },
        .@"if" => {
            const nested = try self.enter(depth, first.position);
            try self.advance();
            const c = try self.frame(Conditional, .{ .depth = depth, .first = first });
            try self.push(.{ .if_condition = c });
            try self.push(.{ .expression = .{ .depth = nested } });
        },
        .@"for" => {
            const nested = try self.enter(depth, first.position);
            try self.advance();
            const name = try self.expect(.name);
            const f = try self.frame(For, .{ .depth = depth, .first = first, .name = name, .numeric = self.current.kind == .@"=" });
            if (f.numeric) {
                try self.advance();
                try self.push(.{ .for_initial = f });
                try self.push(.{ .expression = .{ .depth = nested } });
            } else {
                if (self.current.kind != .in and self.current.kind != .@",") {
                    self.diagnostic.* = .{ .expected_for_separator = self.current };
                    return error.Syntax;
                }
                try f.names.append(self.allocator, name.span);
                while (self.current.kind == .@",") {
                    try self.advance();
                    try f.names.append(self.allocator, (try self.expect(.name)).span);
                }
                _ = try self.expect(.in);
                try self.push(.{ .for_values = f });
                try self.push(.{ .list = nested });
            }
        },
        .function => {
            _ = try self.enter(depth, first.position);
            try self.advance();
            const name = try self.expect(.name);
            var target = try self.make(depth, name.position, name.span.end, .name);
            while (self.current.kind == .@".") {
                try self.check(depth + 1 + target.syntax_depth, self.current.position);
                try self.advance();
                const field = try self.expect(.name);
                target = try self.make(depth, target.position, field.span.end, .{ .field = .{ .receiver = target, .name = field.span } });
            }
            const method = self.current.kind == .@":";
            if (method) {
                try self.check(depth + 1 + target.syntax_depth, self.current.position);
                try self.advance();
                const field = try self.expect(.name);
                target = try self.make(depth, target.position, field.span.end, .{ .field = .{ .receiver = target, .name = field.span } });
            }
            try self.push(.{ .definition = .{ .depth = depth, .first = first, .scope = .ordinary, .target = target } });
            try self.beginFunction(depth, first.position, first.position, method);
        },
        .name, .@"(" => {
            if (first.kind == .name and std.mem.eql(u8, self.lexer.source[first.span.start..first.span.end], "global")) {
                var lookahead = self.lexer;
                const next = lookahead.next() catch {
                    self.diagnostic.* = .{ .lexical = lookahead.diagnostic.? };
                    return error.Syntax;
                };
                if (next.kind == .name or next.kind == .function or next.kind == .@"<" or next.kind == .@"*") return self.beginDeclaration(depth, first, true);
            }
            try self.push(.{ .assignment_target = try self.frame(Assignment, .{ .depth = depth, .first = first }) });
            try self.push(.{ .primary = depth });
        },
        else => return self.invalid(first),
    }
}
fn step(self: *Engine, task: Task) Error!void {
    switch (task) {
        .expression => |expr| {
            if (self.current.kind == .@"-" or self.current.kind == .not or self.current.kind == .@"#" or self.current.kind == .@"~") {
                const operator = self.current;
                const depth = try self.enter(expr.depth, operator.position);
                try self.advance();
                try self.push(.{ .prefix = .{ .expr = expr, .operator = operator } });
                // A unary operator binds tighter than every binary one but `^`.
                try self.push(.{ .expression = .{ .depth = depth, .minimum = 11 } });
            } else {
                try self.push(.{ .expression_loop = expr });
                try self.push(.{ .primary = expr.depth });
            }
        },
        .prefix => |prefix| {
            const operand = self.result;
            const left = try self.make(prefix.expr.depth, prefix.operator.position, operand.span.end, .{ .unary = .{ .operator = .of(prefix.operator), .operand = operand } });
            self.result = left;
            try self.push(.{ .expression_loop = prefix.expr });
        },
        .expression_loop => |loop| {
            const left = self.result;
            const power = precedence(self.current.kind);
            if (power < loop.minimum) return;
            const operator = self.current;
            try self.check(loop.depth + 1 + left.syntax_depth, operator.position);
            try self.advance();
            try self.push(.{ .binary = .{ .expr = loop, .left = left, .operator = operator } });
            try self.push(.{ .expression = .{ .depth = loop.depth + 1, .minimum = if (operator.kind == .@"^" or operator.kind == .@"..") power else power + 1 } });
        },
        .binary => |binary| {
            self.result = try self.make(binary.expr.depth, binary.left.position, self.result.span.end, .{ .binary = .{ .operator = .of(binary.operator), .left = binary.left, .right = self.result } });
            try self.push(.{ .expression_loop = binary.expr });
        },
        .primary => |depth| {
            const first = self.current;
            switch (first.kind) {
                .name => {
                    try self.advance();
                    try self.push(.{ .suffix = .{ .depth = depth, .receiver = try self.make(depth, first.position, first.span.end, .name) } });
                },
                .@"(" => {
                    const nested = try self.enter(depth, first.position);
                    try self.advance();
                    try self.push(.{ .group = .{ .depth = depth, .opening = first } });
                    try self.push(.{ .expression = .{ .depth = nested } });
                },
                .@"{" => {
                    _ = try self.enter(depth, first.position);
                    try self.advance();
                    try self.push(.{ .table_next = try self.frame(Table, .{ .depth = depth, .opening = first }) });
                },
                .function => {
                    _ = try self.enter(depth, first.position);
                    try self.advance();
                    try self.beginFunction(depth, first.position, first.position, false);
                },
                .nil, .true, .false, .number, .string, .@"..." => {
                    try self.advance();
                    const data: Ast.Node.Data = switch (first.kind) {
                        .nil => .nil,
                        .true => .{ .boolean = true },
                        .false => .{ .boolean = false },
                        .number => if (first.integer) |n| .{ .integer = n } else .{ .number = first.number.? },
                        .string => .{ .string = first.string.? },
                        .@"..." => .varargs,
                        else => unreachable,
                    };
                    self.result = try self.make(depth, first.position, first.span.end, data);
                },
                else => {
                    self.diagnostic.* = .{ .expected_expression = first };
                    return error.Syntax;
                },
            }
        },
        .group => |group| {
            const closing = try self.expect(.@")");
            try self.push(.{ .suffix = .{ .depth = group.depth, .receiver = try self.make(group.depth, group.opening.position, closing.span.end, .{ .group = self.result }) } });
        },
        .suffix => |suffix| switch (self.current.kind) {
            .@"." => {
                try self.check(suffix.depth + 1 + suffix.receiver.syntax_depth, self.current.position);
                try self.advance();
                const name = try self.expect(.name);
                try self.push(.{ .suffix = .{ .depth = suffix.depth, .receiver = try self.make(suffix.depth, suffix.receiver.position, name.span.end, .{ .field = .{ .receiver = suffix.receiver, .name = name.span } }) } });
            },
            .@"[" => {
                const opening = self.current;
                try self.check(suffix.depth + 1 + suffix.receiver.syntax_depth, opening.position);
                try self.advance();
                try self.push(.{ .index = .{ .suffix = suffix } });
                try self.push(.{ .expression = .{ .depth = suffix.depth + 1 } });
            },
            .@"(", .@"{", .string, .@":" => try self.beginCall(suffix),
            else => self.result = suffix.receiver,
        },
        .index => |index| {
            const closing = try self.expect(.@"]");
            try self.push(.{ .suffix = .{ .depth = index.suffix.depth, .receiver = try self.make(index.suffix.depth, index.suffix.receiver.position, closing.span.end, .{ .index = .{ .receiver = index.suffix.receiver, .key = self.result } }) } });
        },
        .call_argument => |call| {
            try call.arguments.append(self.allocator, self.result);
            if (self.current.kind == .@",") {
                try self.advance();
                try self.push(.{ .call_argument = call });
                try self.push(.{ .expression = .{ .depth = call.suffix.depth + 1 } });
            } else try self.finishCall(call, (try self.expect(.@")")).span.end);
        },
        .call_sugar => |call| {
            try call.arguments.append(self.allocator, self.result);
            try self.finishCall(call, self.result.span.end);
        },
        .table_next => |table| {
            if (self.current.kind == .@"}") return self.finishTable(table);
            if (self.current.kind == .@"[") {
                try self.advance();
                try self.push(.{ .table_key = table });
            } else try self.push(.{ .table_first = table });
            try self.push(.{ .expression = .{ .depth = table.depth + 1 } });
        },
        .table_key => |table| {
            table.key = .{ .expression = self.result };
            _ = try self.expect(.@"]");
            _ = try self.expect(.@"=");
            try self.push(.{ .table_value = table });
            try self.push(.{ .expression = .{ .depth = table.depth + 1 } });
        },
        .table_first => |table| {
            if (self.result.data == .name and self.current.kind == .@"=") {
                table.key = .{ .name = self.result.span };
                try self.advance();
                try self.push(.{ .table_value = table });
                try self.push(.{ .expression = .{ .depth = table.depth + 1 } });
            } else try self.addField(table, self.result);
        },
        .table_value => |table| try self.addField(table, self.result),
        .function => |f| {
            const closing = try self.expect(.end);
            self.result = try self.make(f.depth, f.start, closing.span.end, .{ .function = .{ .parameters = f.parameters, .varargs = f.varargs, .varargs_name = f.varargs_name, .implicit_self = f.implicit_self, .body = self.result, .holds_function = self.functions_made > f.functions_before } });
            self.functions_made += 1;
        },
        .list => |depth| {
            const list = try self.frame(List, .{ .depth = depth });
            try self.push(.{ .list_next = list });
            try self.push(.{ .expression = .{ .depth = depth } });
        },
        .list_next => |list| {
            try list.nodes.append(self.allocator, self.result);
            if (self.current.kind == .@",") {
                try self.advance();
                try self.push(.{ .list_next = list });
                try self.push(.{ .expression = .{ .depth = list.depth } });
            } else self.list_result = try list.nodes.toOwnedSlice(self.allocator);
        },
        .block => |depth| try self.push(.{ .block_next = try self.frame(Block, .{ .depth = depth, .start = self.current.position }) }),
        .block_next => |block| {
            if (terminates(self.current.kind)) {
                self.result = try self.make(block.depth, block.start, self.current.span.start, .{ .block = try block.nodes.toOwnedSlice(self.allocator) });
                return;
            }
            try self.push(.{ .block_add = .{ .block = block, .returned = self.current.kind == .@"return" } });
            try self.push(.{ .statement = block.depth });
        },
        .block_add => |add| {
            try add.block.nodes.append(self.allocator, self.result);
            if (add.returned) self.result = try self.make(add.block.depth, add.block.start, self.current.span.start, .{ .block = try add.block.nodes.toOwnedSlice(self.allocator) }) else try self.push(.{ .block_next = add.block });
        },
        .statement => |depth| try self.statement(depth),
        .returned => |r| {
            const values = self.list_result;
            if (self.current.kind == .@";") try self.advance();
            self.result = try self.make(r.depth, r.opening.position, self.current.span.start, .{ .return_statement = values });
        },
        .do_done => |d| {
            const closing = try self.expect(.end);
            self.result = try self.make(d.depth, d.opening.position, closing.span.end, .{ .do_block = self.result });
        },
        .declaration => |d| self.result = try self.make(d.depth, d.first.position, self.current.span.start, .{ .declaration = .{ .global = d.global, .default_attribute = d.attribute, .names = d.names, .values = self.list_result, .wildcard = false } }),
        .definition => |d| self.result = try self.make(d.depth, d.first.position, self.result.span.end, .{ .definition = .{ .scope = d.scope, .target = d.target, .value = self.result } }),
        .assignment_target => |assignment| {
            const target = self.result;
            if (assignment.targets.items.len == 0 and self.current.kind != .@"=" and self.current.kind != .@",") {
                if (target.data == .call) return;
                return self.invalid(assignment.first);
            }
            if (target.data != .name and target.data != .index and target.data != .field) return self.invalid(assignment.first);
            try assignment.targets.append(self.allocator, target);
            if (self.current.kind == .@",") {
                try self.advance();
                if (self.current.kind != .name and self.current.kind != .@"(") return self.invalid(assignment.first);
                try self.push(.{ .assignment_target = assignment });
                try self.push(.{ .primary = assignment.depth });
            } else {
                if (self.current.kind != .@"=") return self.invalid(assignment.first);
                try self.advance();
                try self.push(.{ .assignment = assignment });
                try self.push(.{ .list = assignment.depth });
            }
        },
        .assignment => |a| self.result = try self.make(a.depth, a.first.position, self.list_result[self.list_result.len - 1].span.end, .{ .assignment = .{ .targets = try a.targets.toOwnedSlice(self.allocator), .values = self.list_result } }),
        .if_condition => |c| {
            c.condition = self.result;
            _ = try self.expect(.then);
            try self.push(.{ .if_body = c });
            try self.push(.{ .block = c.depth + 1 });
        },
        .if_body => |c| {
            try c.arms.append(self.allocator, .{ .condition = c.condition, .body = self.result });
            if (self.current.kind == .elseif) {
                try self.advance();
                try self.push(.{ .if_condition = c });
                try self.push(.{ .expression = .{ .depth = c.depth + 1 } });
            } else if (self.current.kind == .@"else") {
                try self.advance();
                try self.push(.{ .if_else = c });
                try self.push(.{ .block = c.depth + 1 });
            } else try self.finishIf(c);
        },
        .if_else => |c| {
            c.otherwise = self.result;
            try self.finishIf(c);
        },
        .while_condition => |loop| {
            loop.condition = self.result;
            loop.opening = try self.expect(.do);
            try self.push(.{ .while_body = loop });
            try self.push(.{ .block = loop.depth + 1 });
        },
        .while_body => |loop| {
            const closing = try self.expect(.end);
            self.result = try self.make(loop.depth, loop.first.position, closing.span.end, .{ .while_loop = .{ .condition = loop.condition, .body = self.result, .do_position = loop.opening.position } });
        },
        .repeat_body => |loop| {
            loop.body = self.result;
            _ = try self.expect(.until);
            try self.push(.{ .repeat_condition = loop });
            try self.push(.{ .expression = .{ .depth = loop.depth + 1 } });
        },
        .repeat_condition => |loop| self.result = try self.make(loop.depth, loop.first.position, self.result.span.end, .{ .repeat_loop = .{ .body = loop.body, .condition = self.result } }),
        .for_initial => |f| {
            f.initial = self.result;
            _ = try self.expect(.@",");
            try self.push(.{ .for_limit = f });
            try self.push(.{ .expression = .{ .depth = f.depth + 1 } });
        },
        .for_limit => |f| {
            f.limit = self.result;
            if (self.current.kind == .@",") {
                try self.advance();
                try self.push(.{ .for_step = f });
                try self.push(.{ .expression = .{ .depth = f.depth + 1 } });
            } else try self.forBody(f);
        },
        .for_step => |f| {
            f.step = self.result;
            try self.forBody(f);
        },
        .for_values => |f| {
            f.values = self.list_result;
            try self.forBody(f);
        },
        .for_body => |f| {
            const closing = try self.expect(.end);
            self.result = try self.make(f.depth, f.first.position, closing.span.end, if (f.numeric) .{ .numeric_for = .{ .name = f.name.span, .initial = f.initial, .limit = f.limit, .step = f.step, .body = self.result, .do_position = f.opening.position } } else .{ .generic_for = .{ .names = try f.names.toOwnedSlice(self.allocator), .values = f.values, .body = self.result } });
        },
    }
}
