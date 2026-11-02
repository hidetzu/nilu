const std = @import("std");
const Ast = @import("Ast.zig");
const Token = @import("Token.zig");
const runtime = @import("runtime.zig");
const bytecode = @import("bytecode.zig");
const decoder = @import("string_literal.zig");
const control = @import("validation.zig");
const scope = @import("scope.zig");
const jumps = @import("jumps.zig");
const Lexer = @import("Lexer.zig");

pub const Error = error{ OutOfMemory, Syntax, InvalidAst };
/// A function past one of the compiler's fixed limits, a syntax error. The
/// position is the first item past the limit, and the words are
/// `too many <subject> (limit is <maximum>)` (the owner's answer).
pub const Limit = struct {
    subject: enum { local_variables, upvalues, registers, constants },
    maximum: usize,
    position: Token.Position,
};
pub const Diagnostic = union(enum) {
    control: control.Diagnostic,
    names: scope.Diagnostic,
    jumps: jumps.Diagnostic,
    string: decoder.Diagnostic,
    limit: Limit,
};

const ConstantContext = struct {
    pub fn hash(_: @This(), value: runtime.Value) u64 {
        return switch (value.unpack()) {
            .nil => 0,
            .boolean => |b| if (b) 1 else 2,
            .number => |n| blk: {
                const bits: u64 = @bitCast(n);
                break :blk std.hash.Wyhash.hash(3, std.mem.asBytes(&bits));
            },
            .string => |s| std.hash.Wyhash.hash(4, s.bytes),
            .integer => |n| std.hash.Wyhash.hash(6, std.mem.asBytes(&n)),
            else => 5,
        };
    }

    pub fn eql(_: @This(), a: runtime.Value, b: runtime.Value) bool {
        // An integer and a float are equal values and two constants: `1`
        // and `1.0` stay apart.
        if (a.is(.integer) or b.is(.integer)) return a.is(.integer) and b.is(.integer) and a.asInteger() == b.asInteger();
        if (a.is(.number) and b.is(.number)) {
            return !std.math.isNan(a.unpack().number) and !std.math.isNan(b.unpack().number) and @as(u64, @bitCast(a.unpack().number)) == @as(u64, @bitCast(b.unpack().number));
        }
        return a.equal(b);
    }
};
const Expression = struct { node: *const Ast.Node, destination: usize };
/// `left` is set when the left operand is read from a local's register in
/// place; `right` when the right operand needs no evaluation (a local or a
/// literal). Both are chosen only where no code can run between reading the
/// operand and the operator, so the answer is the same as evaluating each into
/// a temporary first.
/// With `result`, the operation's value goes there (a local) and the left
/// operand's temporary at `destination` is cleared by the operation.
const BinaryRight = struct { node: *const Ast.Node, destination: usize, left: ?usize = null, right: ?Operand = null, result: ?usize = null };
const Operand = union(enum) {
    register: usize,
    constant: usize,

    /// The register or the constant's index, as an operation's field holds it.
    fn index(operand: Operand) usize {
        return switch (operand) {
            .register, .constant => |at| at,
        };
    }
};
const TableFields = struct {
    node: *const Ast.Node,
    destination: usize,
    index: usize = 0,
    list_count: usize = 0,
    pending_first: usize,
    pending_count: usize = 0,
    batch_limit: usize,
    restore: usize,
};
const Storage = union(enum) { local: usize, upvalue: usize, global };
const Binding = struct { parent: ?*const Binding, id: scope.BindingId, storage: Storage };
const Sequence = struct { nodes: []const *const Ast.Node, index: usize = 0, terminal_start: usize = std.math.maxInt(usize), base: usize = 0 };
const Leave = struct { environment: ?*const Binding, registers: usize, locals: usize, position: Token.Position };
const Loop = struct { parent: ?*Loop, first: usize, start: usize, exit_branch: usize = 0, breaks: std.ArrayList(usize) = .empty };
const If = struct { node: *const Ast.Node, arm: usize = 0, first: usize, ends: std.ArrayList(usize) = .empty };
/// A global's `environment` is a register, or the upvalue `_ENV` is when
/// `environment_upvalue`.
const Target = union(enum) { local: usize, upvalue: usize, global: struct { environment: usize, environment_upvalue: bool = false, key: usize, key_constant: bool, name: Token.Span, hint: bytecode.Name }, indexed: struct { receiver: usize, key: usize, key_constant: bool, hint: ?bytecode.Name } };
/// The runtime schedule is explicit: stabilize targets left-to-right, evaluate
/// all values left-to-right, then commit right-to-left. Slots remain roots until
/// the whole plan completes, including across calls and metamethods.
const AssignmentPlan = struct {
    node: *const Ast.Node,
    nodes: []const *const Ast.Node,
    expressions: []const *const Ast.Node,
    targets: []Target,
    first: usize,
    next: usize = 0,
    values: usize = 0,
    initialize: bool = false,
};
const FinishDeclaration = struct { node: *const Ast.Node, first: usize, values: usize, targets: []const Target = &.{} };
const RepeatEnd = struct { node: *const Ast.Node, loop: *Loop, leave: Leave };

const NumericFor = struct { node: *const Ast.Node, loop: *Loop, leave: Leave };

const Produce = struct { node: *const Ast.Node, destination: usize, count: ?usize, tail: bool = false };
const Call = struct { produce: Produce, base: usize, restore: usize, implicit: usize };

const Task = union(enum) {
    produce: Produce,
    call_receiver: Call,
    call_finish: Call,
    generic_prepare: NumericFor,
    generic_end: NumericFor,
    numeric_prepare: NumericFor,
    numeric_end: NumericFor,
    assignment_targets: *AssignmentPlan,
    statement: *const Ast.Node,
    sequence: Sequence,
    leave: Leave,
    declaration: FinishDeclaration,
    assignment: *AssignmentPlan,
    if_arm: *If,
    if_condition: struct { frame: *If, register: usize, restore: usize },
    if_after: struct { frame: *If, branch: usize },
    if_done: *If,
    while_condition: struct { node: *const Ast.Node, loop: *Loop, register: usize },
    while_end: *Loop,
    repeat_end: RepeatEnd,
    repeat_condition: struct { end: RepeatEnd, register: usize },

    expression: Expression,
    binary_right: BinaryRight,
    table_fields: TableFields,
    emit: bytecode.Written,
    patch: usize,
    release: struct { first: usize, position: Token.Position, emit_clear: bool = true },
};
const Compiler = struct {
    allocator: std.mem.Allocator,
    state: *runtime.State,
    source: []const u8,
    /// The source's line starts, shared by every function of the chunk.
    lines: *const Lexer.Lines,
    diagnostic: *?Diagnostic,
    constants: std.ArrayList(runtime.Value) = .empty,
    indices: std.HashMapUnmanaged(runtime.Value, usize, ConstantContext, 80) = .empty,
    code: std.ArrayList(bytecode.Written) = .empty,
    tasks: std.ArrayList(Task) = .empty,
    next_register: usize = 0,
    registers: usize = 0,
    environment: ?*const Binding = null,
    local_count: usize = 0,
    /// The registers of the to-be-closed variables in scope, outermost first.
    /// While there is one, a `return` closes them and is never a tail call.
    closing: std.ArrayList(usize) = .empty,
    /// Whether the function declared one anywhere: its last `returns` closes.
    declares_closing: bool = false,
    loop: ?*Loop = null,
    needs_environment: bool = false,
    parent: ?*Compiler = null,
    outer_environment: ?*const Binding = null,
    jobs: *std.ArrayList(*Compiler),
    children: std.ArrayList(*Compiler) = .empty,
    captures: std.ArrayList(bytecode.Capture) = .empty,
    prototype: ?*runtime.Prototype = null,
    parameters: usize = 0,
    body: *const Ast.Node,
    /// Whether the body makes a function anywhere, as the parser recorded it
    /// (`Ast.Function.holds_function`). Without one no local of this function
    /// is captured.
    holds_function: bool,
    /// The line of the `function` this job compiles; 0 for the chunk.
    defined_line: usize = 0,
    /// The line of that function's `end`; 0 for the chunk.
    end_line: usize = 0,
    expression_root: bool = false,
    vararg: bool = false,
    resolutions: []const jumps.Resolution = &.{},
    names: *const scope.Analysis,
    /// Nothing in the chunk assigns `_ENV` (`scope.analyze`), so a global
    /// assignment can read it at the store instead of first.
    environment_fixed: bool = false,
    labels: std.AutoHashMapUnmanaged(*const Ast.Node, Label) = .empty,
    gotos: std.ArrayList(Goto) = .empty,

    const Label = struct { pc: usize, first: usize };
    const Goto = struct { node: *const Ast.Node, close: usize, jump: usize };

    fn emit(self: *Compiler, instruction: bytecode.Written) Error!void {
        try self.code.append(self.allocator, instruction);
    }

    fn push(self: *Compiler, task: Task) Error!void {
        try self.tasks.append(self.allocator, task);
    }

    /// `position` is the item whose register would be past the limit. A run
    /// of items with positions of their own checks `pastRegisters` first.
    fn reserve(self: *Compiler, count: usize, position: Token.Position) Error!usize {
        if (self.pastRegisters(count) != null) return self.limit(.registers, 255, position);
        const first = self.next_register;
        self.next_register += count;
        self.registers = @max(self.registers, self.next_register);
        return first;
    }

    /// The index, within `count` new registers, of the first one past the
    /// limit, or null when all of them fit.
    fn pastRegisters(self: *const Compiler, count: usize) ?usize {
        const free = 255 - self.next_register;
        return if (count > free) free else null;
    }

    fn limit(self: *Compiler, subject: @FieldType(Limit, "subject"), maximum: usize, position: Token.Position) Error {
        self.diagnostic.* = .{ .limit = .{ .subject = subject, .maximum = maximum, .position = position } };
        return error.Syntax;
    }

    fn positionOf(self: *const Compiler, span: Token.Span) Token.Position {
        return self.lines.positionAt(self.source, span.start);
    }

    fn constant(self: *Compiler, value: runtime.Value, position: Token.Position) Error!usize {
        if (self.indices.get(value)) |index| return index;
        // The constant index is 16 bits wide (manual chapter 13).
        if (self.constants.items.len >= 65535) return self.limit(.constants, 65535, position);
        const index = self.constants.items.len;
        try self.constants.append(self.allocator, value);
        try self.indices.put(self.allocator, value, index);
        return index;
    }

    fn load(self: *Compiler, destination: usize, value: runtime.Value, position: Token.Position) Error!void {
        try self.emit(.{ .position = position, .operation = .{ .constant = .{ .destination = destination, .index = try self.constant(value, position) } } });
    }

    /// Gives back the registers from `first` up. They keep their values
    /// until written again (ADR 0005), so nothing is emitted, except under
    /// `-Dpoison-registers`, where a `clear` poisons them, so that a read
    /// before the next write changes an answer.
    fn release(self: *Compiler, first: usize, position: Token.Position) Error!void {
        if (@import("layout").poison_registers and first < self.next_register) try self.emit(.{ .position = position, .operation = .{ .clear = .{ .first = first, .count = self.next_register - first } } });
        self.next_register = first;
    }

    fn bind(self: *Compiler, id: scope.BindingId, storage: Storage) Error!void {
        const binding = try self.allocator.create(Binding);
        binding.* = .{ .parent = self.environment, .id = id, .storage = storage };
        self.environment = binding;
    }

    /// `position` is the reference, which the upvalue limit points at when
    /// this reference would be a function's 256th capture.
    fn lookup(self: *Compiler, name: []const u8, position: Token.Position) Error!Storage {
        const reference = self.names.get(position.offset) orelse return error.InvalidAst;
        const id = (if (std.mem.eql(u8, name, "_ENV")) reference.environment else reference.binding) orelse return .global;
        return self.lookupBinding(id, position);
    }

    fn lookupBinding(self: *Compiler, id: scope.BindingId, position: Token.Position) Error!Storage {
        var current = self;
        var environment = self.environment;
        var path: std.ArrayList(*Compiler) = .empty;
        while (true) {
            var binding = environment;
            while (binding) |item| : (binding = item.parent) {
                if (id != item.id) continue;
                var storage = item.storage;
                if (current.parent == null and storage == .upvalue) current.needs_environment = true;
                if (storage == .global) return .global;
                var remaining = path.items.len;
                while (remaining > 0) {
                    remaining -= 1;
                    const child = path.items[remaining];
                    const descriptor: bytecode.Capture = switch (storage) {
                        .local => |index| .{ .local = index },
                        .upvalue => |index| .{ .upvalue = index },
                        .global => return error.InvalidAst,
                    };
                    var index: usize = 0;
                    while (index < child.captures.items.len) : (index += 1) {
                        const candidate = child.captures.items[index];
                        if (std.meta.eql(candidate, descriptor)) break;
                    }
                    if (index == child.captures.items.len) {
                        if (index >= 255) return child.limit(.upvalues, 255, position);
                        try child.captures.append(child.allocator, descriptor);
                    }
                    storage = .{ .upvalue = index };
                }
                return storage;
            }
            const parent = current.parent orelse return error.InvalidAst;
            try path.append(self.allocator, current);
            environment = current.outer_environment;
            current = parent;
        }
    }

    fn text(self: *const Compiler, span: Token.Span) []const u8 {
        return self.source[span.start..span.end];
    }

    fn bindingHint(self: *Compiler, name: []const u8, position: Token.Position, text_value: @FieldType(bytecode.Name, "text")) Error!bytecode.Name {
        const storage = try self.lookup(name, position);
        return .{ .kind = switch (storage) {
            .local => .local,
            .upvalue => .upvalue,
            .global => .global,
        }, .text = text_value };
    }

    fn nameHint(self: *Compiler, original: *const Ast.Node) Error!?bytecode.Name {
        var node = original;
        while (node.data == .group) node = node.data.group;
        return switch (node.data) {
            .name => try self.bindingHint(self.text(node.span), node.position, .{ .span = .of(node.span) }),
            .field => |field| .{ .kind = .field, .text = .{ .span = .of(field.name) } },
            // A field read through a key that is not a name is Lua's `field '?'`
            // (the owner's answer of 2026-10-31).
            .index => |index| if (index.key.data == .string) .{ .kind = .field, .text = .{ .literal = .of(index.key.data.string) } } else .{ .kind = .field, .text = .{ .fixed = "?" } },
            .string => |literal| .{ .kind = .constant, .text = .{ .literal = .of(literal) } },
            else => null,
        };
    }

    fn readStorage(self: *Compiler, storage: Storage, destination: usize, position: Token.Position) Error!void {
        switch (storage) {
            .local => |source| try self.emit(.{ .position = position, .operation = .{ .move = .{ .source = source, .destination = destination } } }),
            .upvalue => |index| {
                if (self.parent == null) self.needs_environment = true;
                try self.emit(.{ .position = position, .operation = .{ .get_upvalue = .{ .destination = destination, .index = index } } });
            },
            .global => return error.InvalidAst, // Already refused by checkNames for _ENV.
        }
    }

    fn readName(self: *Compiler, name: []const u8, destination: usize, position: Token.Position) Error!void {
        const storage = try self.lookup(name, position);
        if (storage != .global) return self.readStorage(storage, destination, position);
        const environment = try self.lookup("_ENV", position);
        // `_ENV` as an upvalue is read from its cell by the `get` itself:
        // nothing runs between the two reads, so one instruction does both.
        if (environment == .upvalue) {
            if (self.parent == null) self.needs_environment = true;
            const key = try self.constant(.from(.{ .string = try self.state.newString(name) }), position);
            try self.emit(.{ .position = position, .names = .{ .primary = try self.bindingHint("_ENV", position, .environment) }, .operation = .{ .get = .{ .destination = destination, .table = environment.upvalue, .key = key, .key_constant = true, .table_upvalue = true } } });
            return;
        }
        try self.readStorage(environment, destination, position);
        const key = try self.constant(.from(.{ .string = try self.state.newString(name) }), position);
        try self.emit(.{ .position = position, .names = .{ .primary = try self.bindingHint("_ENV", position, .environment) }, .operation = .{ .get = .{ .destination = destination, .table = destination, .key = key, .key_constant = true } } });
    }

    fn target(self: *Compiler, name: []const u8, force_global: bool, position: Token.Position) Error!Target {
        const storage = if (force_global) Storage.global else try self.lookup(name, position);
        return switch (storage) {
            .local => |register| .{ .local = register },
            .upvalue => |index| .{ .upvalue = index },
            .global => blk: {
                const storage_of_environment = try self.lookup("_ENV", position);
                // `_ENV` keeps its value (nothing assigns it), so the store can
                // read the upvalue itself, as `readName` does, and nothing
                // needs a register to hold it until then.
                if (!force_global and self.environment_fixed and storage_of_environment == .upvalue) {
                    if (self.parent == null) self.needs_environment = true;
                    const index = try self.constant(.from(.{ .string = try self.state.newString(name) }), position);
                    break :blk .{ .global = .{ .environment = storage_of_environment.upvalue, .environment_upvalue = true, .key = index, .key_constant = true, .name = .{ .start = position.offset, .end = position.offset + @as(u32, @intCast(name.len)) }, .hint = try self.bindingHint("_ENV", position, .environment) } };
                }
                const environment = try self.reserve(1, position);
                // An assignment reads its key as a constant; a `global` definition
                // keeps a register for it, which `init_global` takes.
                const key = if (force_global) try self.reserve(1, position) else undefined;
                try self.readStorage(try self.lookup("_ENV", position), environment, position);
                const index = try self.constant(.from(.{ .string = try self.state.newString(name) }), position);
                if (force_global) try self.emit(.{ .position = position, .operation = .{ .constant = .{ .destination = key, .index = index } } });
                break :blk .{ .global = .{ .environment = environment, .key = if (force_global) key else index, .key_constant = !force_global, .name = .{ .start = position.offset, .end = position.offset + @as(u32, @intCast(name.len)) }, .hint = try self.bindingHint("_ENV", position, .environment) } };
            },
        };
    }

    fn store(self: *Compiler, target_value: Target, source: usize, initialize: bool, position: Token.Position) Error!void {
        const operation: bytecode.Instruction.Operation = switch (target_value) {
            .local => |destination| .{ .move = .{ .source = source, .destination = destination } },
            .upvalue => |index| blk: {
                if (self.parent == null) self.needs_environment = true;
                break :blk .{ .set_upvalue = .{ .source = source, .index = index } };
            },
            .indexed => |indexed| .{ .set = .{ .table = indexed.receiver, .key = indexed.key, .value = source, .key_constant = indexed.key_constant } },
            .global => |global| if (initialize) .{ .init_global = .{ .environment = global.environment, .key = global.key, .value = source } } else .{ .set = .{ .table = global.environment, .key = global.key, .value = source, .key_constant = global.key_constant, .table_upvalue = global.environment_upvalue } },
        };
        const names: bytecode.Names = switch (target_value) {
            .global => |global| .{ .primary = global.hint, .subject = .{ .kind = .global, .text = .{ .span = .of(global.name) } } },
            .indexed => |indexed| .{ .primary = indexed.hint },
            else => .{},
        };
        try self.emit(.{ .position = position, .operation = operation, .names = names });
    }

    fn planAssignment(self: *Compiler, node: *const Ast.Node, targets: []const *const Ast.Node, expressions: []const *const Ast.Node, initialize: bool) Error!void {
        const plan = try self.allocator.create(AssignmentPlan);
        plan.* = .{ .node = node, .nodes = targets, .expressions = expressions, .targets = try self.allocator.alloc(Target, targets.len), .first = self.next_register, .initialize = initialize };
        try self.push(.{ .assignment_targets = plan });
    }

    fn assignmentTargets(self: *Compiler, plan: *AssignmentPlan) Error!void {
        if (plan.next == plan.nodes.len) {
            const total = @max(plan.nodes.len, plan.expressions.len);
            if (self.pastRegisters(total)) |past| return self.limit(.registers, 255, if (past < plan.expressions.len) plan.expressions[past].position else plan.nodes[past].position);
            plan.values = try self.reserve(total, plan.node.position);
            try self.push(.{ .assignment = plan });
            try self.values(plan.expressions, plan.values, total, plan.node.position);
            return;
        }
        const index = plan.next;
        plan.next += 1;
        const node = plan.nodes[index];
        try self.push(.{ .assignment_targets = plan });
        if (node.data == .name) {
            plan.targets[index] = try self.target(self.text(node.span), plan.initialize, node.position);
            return;
        }
        const receiver = switch (node.data) {
            .index => |op| op.receiver,
            .field => |op| op.receiver,
            else => return error.InvalidAst,
        };
        const slot = try self.reserve(1, receiver.position);
        if (node.data == .index) {
            const key = try self.reserve(1, node.data.index.key.position);
            plan.targets[index] = .{ .indexed = .{ .receiver = slot, .key = key, .key_constant = false, .hint = try self.nameHint(receiver) } };
            try self.push(.{ .expression = .{ .node = node.data.index.key, .destination = key } });
        } else {
            // A field name is a constant key and needs no register. The receiver
            // is still evaluated into its own slot before the values, as before.
            const value = try self.state.newString(self.text(node.data.field.name));
            plan.targets[index] = .{ .indexed = .{ .receiver = slot, .key = try self.constant(.from(.{ .string = value }), node.position), .key_constant = true, .hint = try self.nameHint(receiver) } };
        }
        try self.push(.{ .expression = .{ .node = receiver, .destination = slot } });
    }

    fn values(self: *Compiler, nodes: []const *const Ast.Node, first: usize, total: usize, position: Token.Position) Error!void {
        var remaining = total;
        while (remaining > 0) {
            remaining -= 1;
            if (nodes.len > 0 and multiple(nodes[nodes.len - 1]) and remaining >= nodes.len - 1) {
                if (remaining == nodes.len - 1) try self.push(.{ .produce = .{ .node = nodes[remaining], .destination = first + remaining, .count = total - remaining } });
            } else if (remaining < nodes.len) {
                try self.push(.{ .expression = .{ .node = nodes[remaining], .destination = first + remaining } });
            } else {
                try self.push(.{ .emit = .{ .position = position, .operation = .{ .constant = .{ .destination = first + remaining, .index = try self.constant(.nil, position) } } } });
            }
        }
    }

    fn patch(self: *Compiler, index: usize, target_pc: usize) Error!void {
        switch (self.code.items[index].operation) {
            .branch => |*branch| branch.target = target_pc,
            // A u32 keeps the operation within an instruction's size; no
            // function has that many instructions.
            .compare_branch => |*branch| branch.target = std.math.cast(u32, target_pc) orelse return error.OutOfMemory,
            .jump => |*jump| jump.target = target_pc,
            .for_prepare => |*prepare| prepare.target = target_pc,
            else => return error.InvalidAst,
        }
    }

    fn emitJump(self: *Compiler, target_pc: usize, position: Token.Position) Error!usize {
        const index = self.code.items.len;
        try self.emit(.{ .position = position, .operation = .{ .jump = .{ .target = target_pc } } });
        return index;
    }

    fn exitScope(self: *Compiler, first: usize, position: Token.Position) Error!void {
        try self.emit(.{ .position = position, .operation = .{ .scope_exit = first } });
    }

    fn enterLoop(self: *Compiler) Error!*Loop {
        const loop = try self.allocator.create(Loop);
        loop.* = .{ .parent = self.loop, .first = self.next_register, .start = self.code.items.len };
        return loop;
    }

    fn finishLoop(self: *Compiler, loop: *Loop, exit: usize) Error!void {
        for (loop.breaks.items) |index| try self.patch(index, exit);
        self.loop = loop.parent;
    }

    fn statement(self: *Compiler, node: *const Ast.Node) Error!void {
        switch (node.data) {
            .empty => {},
            .definition => |definition| {
                if (definition.scope == .local) {
                    if (definition.target.data != .name) return error.InvalidAst;
                    if (self.local_count >= 200) return self.limit(.local_variables, 200, definition.target.position);
                    const slot = try self.reserve(1, definition.target.position);
                    try self.load(slot, .nil, node.position);
                    try self.bind(definition.target.span.start, .{ .local = slot });
                    self.local_count += 1;
                    try self.push(.{ .expression = .{ .node = definition.value, .destination = slot } });
                } else {
                    const targets = try self.allocator.alloc(*const Ast.Node, 1);
                    targets[0] = definition.target;
                    const expressions = try self.allocator.alloc(*const Ast.Node, 1);
                    expressions[0] = definition.value;
                    try self.planAssignment(node, targets, expressions, definition.scope == .global);
                    if (definition.scope == .global) try self.bind(definition.target.span.start, .global);
                }
            },
            .call => try self.push(.{ .produce = .{ .node = node, .destination = self.next_register, .count = 0 } }),
            .block => |nodes| {
                try self.push(.{ .leave = .{ .environment = self.environment, .registers = self.next_register, .locals = self.local_count, .position = node.position } });
                var terminal = nodes.len;
                while (terminal > 0) {
                    switch (nodes[terminal - 1].data) {
                        .label, .empty => terminal -= 1,
                        else => break,
                    }
                }
                try self.push(.{ .sequence = .{ .nodes = nodes, .terminal_start = terminal, .base = self.next_register } });
            },
            .do_block => |body| try self.push(.{ .statement = body }),
            .return_statement => |returned| {
                // A to-be-closed variable is closed after the results are made,
                // so `return f()` cannot reuse the frame (Lua 5.5).
                if (returned.len == 1 and returned[0].data == .call and self.closing.items.len == 0) {
                    try self.push(.{ .produce = .{ .node = returned[0], .destination = self.next_register, .count = null, .tail = true } });
                    return;
                }
                // One local, with nothing to close: returned from its own
                // register, since nothing runs between reading and returning.
                if (returned.len == 1 and self.closing.items.len == 0) {
                    if (try self.localRegister(returned[0])) |register| {
                        try self.emit(.{ .position = node.position, .operation = .{ .returns = .{ .first = register, .count = 1, .close = false } } });
                        return;
                    }
                }
                const open = returned.len > 0 and multiple(returned[returned.len - 1]);
                const prefix = if (open) returned.len - 1 else returned.len;
                if (self.pastRegisters(prefix)) |past| return self.limit(.registers, 255, returned[past].position);
                const first = try self.reserve(prefix, node.position);
                try self.push(.{ .release = .{ .first = first, .position = node.position } });
                try self.push(.{ .emit = .{ .position = node.position, .operation = .{ .returns = .{ .first = first, .count = if (open) null else returned.len, .close = self.closing.items.len != 0 } } } });
                if (open) try self.push(.{ .produce = .{ .node = returned[prefix], .destination = first + prefix, .count = null } });
                try self.values(returned[0..prefix], first, prefix, node.position);
            },
            .declaration => |declaration| {
                if (declaration.global and declaration.values.len == 0) {
                    for (declaration.names) |binding| try self.bind(binding.name.start, .global);
                    return;
                }
                const first = self.next_register;
                var targets: []Target = &.{};
                if (declaration.global) {
                    targets = try self.allocator.alloc(Target, declaration.names.len);
                    for (declaration.names, targets) |binding, *output| output.* = try self.target(self.text(binding.name), true, self.positionOf(binding.name));
                } else if (declaration.names.len > 200 - self.local_count) {
                    return self.limit(.local_variables, 200, self.positionOf(declaration.names[200 - self.local_count].name));
                }
                const total = @max(declaration.names.len, declaration.values.len);
                if (self.pastRegisters(total)) |past| {
                    return self.limit(.registers, 255, if (past < declaration.values.len) declaration.values[past].position else self.positionOf(declaration.names[past].name));
                }
                const output = try self.reserve(total, node.position);
                try self.push(.{ .declaration = .{ .node = node, .first = first, .values = output, .targets = targets } });
                // For globals, target registers precede the value run. Locals
                // initialize their future slots while their names remain hidden.
                try self.values(declaration.values, output, total, node.position);
            },
            .assignment => |assignment| if (!try self.directAssignment(assignment.targets, assignment.values)) try self.planAssignment(node, assignment.targets, assignment.values, false),
            .conditional => {
                const frame = try self.allocator.create(If);
                frame.* = .{ .node = node, .first = self.next_register };
                try self.push(.{ .if_arm = frame });
            },
            .while_loop => |loop_node| {
                const loop = try self.enterLoop();
                if (try self.compareBranch(loop_node.condition, false)) |index| {
                    loop.exit_branch = index;
                    self.loop = loop;
                    try self.push(.{ .while_end = loop });
                    try self.push(.{ .statement = loop_node.body });
                    return;
                }
                const register = try self.reserve(1, loop_node.condition.position);
                try self.push(.{ .while_condition = .{ .node = node, .loop = loop, .register = register } });
                try self.push(.{ .expression = .{ .node = loop_node.condition, .destination = register } });
            },
            .generic_for => |loop_node| {
                const count = loop_node.names.len;
                if (count == 0) return error.InvalidAst;
                // Two hidden slots and the names count toward the 200 locals
                // (the owner's answer). A hidden slot past the
                // limit is reported at the first name.
                if (count > 198 or self.local_count > 198 - count) {
                    const past = 200 -| self.local_count;
                    return self.limit(.local_variables, 200, self.positionOf(loop_node.names[if (past < 2) 0 else @min(past - 2, count - 1)]));
                }
                const loop = try self.enterLoop();
                const frame = NumericFor{ .node = node, .loop = loop, .leave = .{ .environment = self.environment, .registers = self.next_register, .locals = self.local_count, .position = node.position } };
                // The fourth value is the one the loop closes (Lua 5.4+).
                const total = @max(4, loop_node.values.len);
                const slots = @max(5, @max(2 + count, total));
                if (self.pastRegisters(slots)) |past| {
                    const name = if (past >= 2 and past - 2 < count) past - 2 else 0;
                    return self.limit(.registers, 255, if (past < loop_node.values.len) loop_node.values[past].position else self.positionOf(loop_node.names[name]));
                }
                _ = try self.reserve(slots, node.position);
                try self.push(.{ .generic_prepare = frame });
                try self.values(loop_node.values, loop.first, total, node.position);
            },
            .numeric_for => |loop_node| {
                // Two hidden slots and the control count toward the 200 locals
                // (the owner's answer), reported at the control.
                const control_position = self.positionOf(loop_node.name);
                if (self.local_count > 197) return self.limit(.local_variables, 200, control_position);
                const loop = try self.enterLoop();
                const frame = NumericFor{ .node = node, .loop = loop, .leave = .{ .environment = self.environment, .registers = self.next_register, .locals = self.local_count, .position = node.position } };
                if (self.pastRegisters(3)) |past| {
                    const slot = [_]?*const Ast.Node{ loop_node.initial, loop_node.limit, loop_node.step };
                    return self.limit(.registers, 255, if (slot[past]) |item| item.position else control_position);
                }
                const base = try self.reserve(3, node.position);
                try self.push(.{ .numeric_prepare = frame });
                if (loop_node.step) |step| {
                    try self.push(.{ .expression = .{ .node = step, .destination = base + 2 } });
                } else {
                    try self.push(.{ .emit = .{ .position = loop_node.do_position, .operation = .{ .constant = .{ .destination = base + 2, .index = try self.constant(.from(.{ .integer = 1 }), node.position) } } } });
                }
                try self.push(.{ .expression = .{ .node = loop_node.limit, .destination = base + 1 } });
                try self.push(.{ .expression = .{ .node = loop_node.initial, .destination = base } });
            },
            .repeat_loop => |loop_node| {
                const loop = try self.enterLoop();
                self.loop = loop;
                try self.push(.{ .repeat_end = .{ .node = node, .loop = loop, .leave = .{ .environment = self.environment, .registers = self.next_register, .locals = self.local_count, .position = node.position } } });
                try self.push(.{ .sequence = .{ .nodes = loop_node.body.data.block } });
            },
            .label => try self.labels.put(self.allocator, node, .{ .pc = self.code.items.len, .first = self.next_register }),
            .goto_statement => {
                const close = self.code.items.len;
                try self.exitScope(0, node.position);
                try self.gotos.append(self.allocator, .{ .node = node, .close = close, .jump = try self.emitJump(0, node.position) });
            },
            .break_statement => {
                const loop = self.loop orelse return error.InvalidAst;
                try self.exitScope(loop.first, node.position);
                try loop.breaks.append(self.allocator, try self.emitJump(0, node.position));
            },
            .nil, .boolean, .number, .integer, .string, .name, .varargs, .group, .unary, .binary, .index, .field, .table, .function => return error.InvalidAst,
        }
    }

    fn finishDeclaration(self: *Compiler, frame: FinishDeclaration) Error!void {
        const declaration = frame.node.data.declaration;
        if (declaration.global) {
            const first_value = frame.values;
            var remaining = declaration.names.len;
            const position = declaration.values[0].position;
            while (remaining > 0) {
                remaining -= 1;
                try self.store(frame.targets[remaining], first_value + remaining, true, position);
            }
            try self.release(frame.first, frame.node.position);
            for (declaration.names) |binding| try self.bind(binding.name.start, .global);
        } else {
            try self.release(frame.first + declaration.names.len, frame.node.position);
            self.local_count += declaration.names.len;
            for (declaration.names, 0..) |binding, i| {
                try self.bind(binding.name.start, .{ .local = frame.first + i });
                const attribute = binding.attribute orelse declaration.default_attribute orelse continue;
                if (!std.mem.eql(u8, self.text(attribute), "close")) continue;
                try self.emit(.{ .position = self.positionOf(binding.name), .names = .{ .subject = .{ .kind = .local, .text = .{ .span = .of(binding.name) } } }, .operation = .{ .to_be_closed = .{ .register = frame.first + i, .level = frame.first + i } } });
                try self.closing.append(self.allocator, frame.first + i);
                self.declares_closing = true;
            }
        }
    }

    fn ifArm(self: *Compiler, frame: *If) Error!void {
        const conditional = frame.node.data.conditional;
        if (frame.arm == conditional.arms.len) {
            try self.push(.{ .if_done = frame });
            if (conditional.otherwise) |body| try self.push(.{ .statement = body });
            return;
        }
        const restore = self.next_register;
        const condition = conditional.arms[frame.arm].condition;
        if (try self.compareBranch(condition, false)) |index| {
            try self.push(.{ .if_after = .{ .frame = frame, .branch = index } });
            try self.push(.{ .statement = conditional.arms[frame.arm].body });
            return;
        }
        const register = try self.reserve(1, condition.position);
        try self.push(.{ .if_condition = .{ .frame = frame, .register = register, .restore = restore } });
        try self.push(.{ .expression = .{ .node = condition, .destination = register } });
    }

    fn drain(self: *Compiler) Error!void {
        while (self.tasks.pop()) |task| switch (task) {
            .produce => |frame| try self.produce(frame),
            .call_receiver => |frame| try self.callReceiver(frame),
            .call_finish => |frame| {
                const position = frame.produce.node.data.call.arguments_position;
                if (frame.produce.tail) {
                    self.next_register = frame.restore;
                } else if (frame.produce.count) |count| {
                    if (frame.base == frame.produce.destination or resultIntoTarget(frame)) {
                        self.next_register = frame.restore;
                    } else {
                        for (0..count) |i| try self.emit(.{ .position = position, .operation = .{ .move = .{ .source = frame.base + i, .destination = frame.produce.destination + i } } });
                        try self.release(frame.restore, position);
                    }
                } else {
                    try self.emit(.{ .position = position, .operation = .{ .move_results = .{ .source = frame.base, .destination = frame.produce.destination } } });
                    self.next_register = frame.restore;
                }
            },
            .expression => |frame| try self.expression(frame),
            .binary_right => |frame| try self.binaryRight(frame),
            .table_fields => |frame| try self.tableFields(frame),
            .emit => |instruction| try self.emit(instruction),
            .patch => |index| try self.patch(index, self.code.items.len),
            .release => |frame| if (frame.emit_clear) {
                try self.release(frame.first, frame.position);
            } else {
                self.next_register = frame.first;
            },
            .assignment_targets => |plan| try self.assignmentTargets(plan),
            .statement => |node| try self.statement(node),
            .sequence => |frame| if (frame.index < frame.nodes.len) {
                var next = frame;
                next.index += 1;
                try self.push(.{ .sequence = next });
                const node = frame.nodes[frame.index];
                if (node.data == .label and frame.index >= frame.terminal_start) {
                    try self.labels.put(self.allocator, node, .{ .pc = self.code.items.len, .first = frame.base });
                } else try self.push(.{ .statement = node });
            },
            .leave => |frame| {
                // A block that declared no local has no cell to close, and each
                // temporary in it was cleared when released, so its exit would
                // do nothing; a loop body runs it every turn.
                if (self.local_count != frame.locals) try self.exitScope(frame.registers, frame.position);
                while (self.closing.getLastOrNull()) |register| {
                    if (register < frame.registers) break;
                    _ = self.closing.pop();
                }
                self.environment = frame.environment;
                self.next_register = frame.registers;
                self.local_count = frame.locals;
            },
            .declaration => |frame| try self.finishDeclaration(frame),
            .assignment => |frame| {
                var remaining = frame.targets.len;
                while (remaining > 0) {
                    remaining -= 1;
                    try self.store(frame.targets[remaining], frame.values + remaining, frame.initialize, if (frame.initialize) frame.expressions[remaining].position else frame.nodes[remaining].position);
                }
                try self.release(frame.first, frame.node.position);
            },
            .if_arm => |frame| try self.ifArm(frame),
            .if_condition => |condition| {
                const frame = condition.frame;
                const arm = frame.node.data.conditional.arms[frame.arm];
                const index = self.code.items.len;
                try self.emit(.{ .position = arm.condition.position, .operation = .{ .branch = .{ .register = condition.register, .when = false, .target = 0 } } });
                // A comparison leaves a boolean, which holds nothing for the
                // collector to keep, so its register needs no clear.
                if (comparison(arm.condition)) self.next_register = condition.restore else try self.release(condition.restore, arm.condition.position);
                try self.push(.{ .if_after = .{ .frame = frame, .branch = index } });
                try self.push(.{ .statement = arm.body });
            },
            .if_after => |after| {
                try after.frame.ends.append(self.allocator, try self.emitJump(0, after.frame.node.position));
                try self.patch(after.branch, self.code.items.len);
                after.frame.arm += 1;
                try self.push(.{ .if_arm = after.frame });
            },
            // No exit at the end: each condition's register was released, and
            // each arm is a block that closes and clears its own locals.
            .if_done => |frame| for (frame.ends.items) |index| try self.patch(index, self.code.items.len),
            .generic_prepare => |frame| {
                const node = frame.node.data.generic_for;
                try self.emit(.{ .position = frame.node.position, .names = .{ .subject = .{ .kind = .local, .text = .{ .fixed = "(for state)" } } }, .operation = .{ .to_be_closed = .{ .register = frame.loop.first + 3, .level = frame.loop.first + 1 } } });
                try self.closing.append(self.allocator, frame.loop.first + 1);
                self.declares_closing = true;
                try self.release(frame.loop.first + 3, frame.node.position);
                if (node.names.len > 1) _ = try self.reserve(node.names.len - 1, self.positionOf(node.names[1]));
                // Call scratch above a short visible-variable run is reused by
                // body locals, which leave their scope before the iterator call.
                self.next_register = frame.loop.first + 2 + node.names.len;
                for (node.names, 0..) |name, i| {
                    try self.bind(name.start, .{ .local = frame.loop.first + 2 + i });
                }
                self.local_count += 2 + node.names.len;
                self.loop = frame.loop;
                frame.loop.exit_branch = try self.emitJump(0, frame.node.position);
                frame.loop.start = self.code.items.len;
                try self.push(.{ .generic_end = frame });
                try self.push(.{ .statement = node.body });
            },
            .generic_end => |frame| {
                try self.patch(frame.loop.exit_branch, self.code.items.len);
                try self.emit(.{ .position = frame.node.position, .names = .{ .primary = .{ .kind = .for_iterator, .text = .iterator } }, .operation = .{ .generic_call = .{ .base = frame.loop.first, .count = frame.node.data.generic_for.names.len } } });
                try self.emit(.{ .position = frame.node.position, .operation = .{ .generic_loop = .{ .base = frame.loop.first, .target = frame.loop.start } } });
                const exit = self.code.items.len;
                try self.exitScope(frame.loop.first, frame.node.position);
                _ = self.closing.pop();
                try self.finishLoop(frame.loop, exit);
                self.environment = frame.leave.environment;
                self.next_register = frame.leave.registers;
                self.local_count = frame.leave.locals;
            },
            .numeric_prepare => |frame| {
                const node = frame.node.data.numeric_for;
                frame.loop.exit_branch = self.code.items.len;
                try self.emit(.{ .position = node.do_position, .operation = .{ .for_prepare = .{ .base = frame.loop.first, .target = 0 } } });
                frame.loop.start = self.code.items.len;
                try self.bind(node.name.start, .{ .local = frame.loop.first + 2 });
                self.local_count += 3;
                self.loop = frame.loop;
                try self.push(.{ .numeric_end = frame });
                try self.push(.{ .statement = node.body });
            },
            .numeric_end => |frame| {
                try self.emit(.{ .position = frame.node.position, .operation = .{ .for_loop = .{ .base = frame.loop.first, .target = frame.loop.start, .captures = holdsFunctionIn(frame.node.data.numeric_for.body) } } });
                const exit = self.code.items.len;
                try self.patch(frame.loop.exit_branch, exit);
                try self.exitScope(frame.loop.first, frame.node.position);
                try self.finishLoop(frame.loop, exit);
                self.environment = frame.leave.environment;
                self.next_register = frame.leave.registers;
                self.local_count = frame.leave.locals;
            },
            .while_condition => |condition| {
                const node = condition.node;
                const loop = condition.loop;
                loop.exit_branch = self.code.items.len;
                try self.emit(.{ .position = node.position, .operation = .{ .branch = .{ .register = condition.register, .when = false, .target = 0 } } });
                // A comparison leaves a boolean, which holds nothing for the
                // collector to keep, so its register needs no clear.
                if (comparison(node.data.while_loop.condition)) self.next_register = loop.first else try self.release(loop.first, node.position);
                self.loop = loop;
                try self.push(.{ .while_end = loop });
                try self.push(.{ .statement = node.data.while_loop.body });
            },
            .while_end => |loop| {
                _ = try self.emitJump(loop.start, self.code.items[loop.start].position);
                const exit = self.code.items.len;
                try self.patch(loop.exit_branch, exit);
                try self.exitScope(loop.first, self.code.items[loop.start].position);
                try self.finishLoop(loop, exit);
            },
            .repeat_end => |end| {
                const condition = end.node.data.repeat_loop.condition;
                const register = try self.reserve(1, condition.position);
                try self.push(.{ .repeat_condition = .{ .end = end, .register = register } });
                try self.push(.{ .expression = .{ .node = condition, .destination = register } });
            },
            .repeat_condition => |condition| {
                const end = condition.end;
                const position = end.node.data.repeat_loop.condition.position;
                const branch = self.code.items.len;
                try self.emit(.{ .position = position, .operation = .{ .branch = .{ .register = condition.register, .when = true, .target = 0 } } });
                try self.exitScope(end.loop.first, position);
                _ = try self.emitJump(end.loop.start, position);
                const exit = self.code.items.len;
                try self.patch(branch, exit);
                try self.exitScope(end.loop.first, position);
                try self.finishLoop(end.loop, exit);
                self.environment = end.leave.environment;
                self.next_register = end.leave.registers;
                self.local_count = end.leave.locals;
            },
        };
    }

    fn produce(self: *Compiler, frame: Produce) Error!void {
        if (frame.node.data == .varargs) {
            if (!self.vararg) return error.InvalidAst;
            try self.emit(.{ .position = frame.node.position, .operation = .{ .varargs = .{ .first = frame.destination, .count = frame.count } } });
            return;
        }
        const call = frame.node.data.call;
        const restore = self.next_register;
        const implicit: usize = if (call.method != null) 1 else 0;
        const slots = @max(1 + implicit + call.arguments.len, frame.count orelse 0);
        if (self.pastRegisters(slots)) |past| {
            // The function and self come from the receiver; result slots past
            // the arguments belong to the call.
            const position = if (past <= implicit) call.receiver.position else if (past - 1 - implicit < call.arguments.len) call.arguments[past - 1 - implicit].position else call.arguments_position;
            return self.limit(.registers, 255, position);
        }
        // A fixed number of results bound for the last reserved temporary can
        // land in place: the call starts there, and the VM leaves every slot
        // above its results nil, so neither a move nor a clear follows.
        // Only a temporary: a call returning closes the cells at and above its
        // base, and a local's register may be one a closure captured.
        const in_place = !frame.tail and frame.count != null and frame.destination + 1 == restore and !self.boundRegister(frame.destination);
        const base = if (in_place) blk: {
            if (slots > 1) _ = try self.reserve(slots - 1, call.arguments_position);
            break :blk frame.destination;
        } else try self.reserve(slots, call.arguments_position);
        try self.push(.{ .call_receiver = .{ .produce = frame, .base = base, .restore = restore, .implicit = implicit } });
        try self.push(.{ .expression = .{ .node = call.receiver, .destination = base + implicit } });
    }

    /// A count of registers, at most 255, as an instruction stores it.
    fn narrow(count: ?usize) ?u32 {
        return if (count) |n| @intCast(n) else null;
    }

    /// One result bound below the call's slots, which are the last ones
    /// reserved: the call writes it there itself and leaves its slots nil
    /// (`bytecode.Call.target`), so no move or clear follows.
    fn resultIntoTarget(frame: Call) bool {
        return !frame.produce.tail and frame.produce.count == 1 and frame.produce.destination < frame.base and frame.base == frame.restore;
    }

    fn callReceiver(self: *Compiler, frame: Call) Error!void {
        const call = frame.produce.node.data.call;
        if (call.method) |method| {
            const key = try self.constant(.from(.{ .string = try self.state.newString(self.text(method)) }), call.method_position.?);
            try self.emit(.{ .position = call.method_position.?, .names = .{ .primary = try self.nameHint(call.receiver) }, .operation = .{ .get = .{ .destination = frame.base, .table = frame.base + 1, .key = key, .key_constant = true } } });
        }
        const open = call.arguments.len > 0 and multiple(call.arguments[call.arguments.len - 1]);
        const prefix = if (open) call.arguments.len - 1 else call.arguments.len;
        try self.push(.{ .call_finish = frame });
        const arguments: ?usize = if (open) null else call.arguments.len + frame.implicit;
        const operation: bytecode.Instruction.Operation = if (frame.produce.tail) .{ .tail_call = .{ .base = frame.base, .arguments = arguments } } else .{ .call = .{ .base = frame.base, .arguments = narrow(arguments), .results = narrow(frame.produce.count), .target = if (resultIntoTarget(frame)) @intCast(frame.produce.destination) else null } };
        try self.push(.{ .emit = .{ .position = call.arguments_position, .names = .{ .primary = if (call.method) |name| .{ .kind = .method, .text = .{ .span = .of(name) } } else try self.nameHint(call.receiver) }, .operation = operation } });
        if (open) try self.push(.{ .produce = .{ .node = call.arguments[prefix], .destination = frame.base + 1 + frame.implicit + prefix, .count = null } });
        try self.values(call.arguments[0..prefix], frame.base + 1 + frame.implicit, prefix, call.arguments_position);
    }

    fn lowerFunction(self: *Compiler, node: *const Ast.Node, value: Ast.Function, destination: usize) Error!void {
        const child = try self.allocator.create(Compiler);
        child.* = .{ .allocator = self.allocator, .state = self.state, .source = self.source, .lines = self.lines, .diagnostic = self.diagnostic, .parent = self, .outer_environment = self.environment, .jobs = self.jobs, .body = value.body, .holds_function = value.holds_function, .defined_line = node.position.line, .end_line = self.positionOf(.{ .start = node.span.end -| 1, .end = node.span.end }).line, .resolutions = self.resolutions, .names = self.names, .environment_fixed = self.environment_fixed, .vararg = value.varargs != null };
        // self, the parameters and the vararg slot count toward the 200 locals,
        // in that order.
        const implicit: usize = if (value.implicit_self) 1 else 0;
        const slots = implicit + value.parameters.len + @as(usize, if (value.varargs != null) 1 else 0);
        if (slots > 200) {
            const past = 200 - implicit;
            return child.limit(.local_variables, 200, if (past < value.parameters.len) self.positionOf(value.parameters[past]) else value.varargs.?);
        }
        child.parameters = value.parameters.len + implicit;
        _ = try child.reserve(slots, node.position);
        child.local_count = child.next_register;
        if (value.implicit_self) try child.bind(node.span.start, .{ .local = 0 });
        for (value.parameters, 0..) |parameter, i| try child.bind(parameter.start, .{ .local = i + @as(usize, if (value.implicit_self) 1 else 0) });
        // `...name` names the vararg slot itself; the table is already there.
        if (value.varargs_name) |name| try child.bind(name.start, .{ .local = child.parameters });
        try self.emit(.{ .position = node.position, .operation = .{ .closure = .{ .destination = destination, .child = self.children.items.len } } });
        try self.children.append(self.allocator, child);
        try self.jobs.append(self.allocator, child);
    }

    fn lower(self: *Compiler) Error!void {
        if (self.expression_root) {
            _ = try self.reserve(1, self.body.position);
            try self.push(.{ .expression = .{ .node = self.body, .destination = 0 } });
        } else try self.push(.{ .statement = self.body });
        try self.drain();
        try self.emit(.{ .position = self.body.position, .operation = .{ .returns = .{ .first = 0, .count = if (self.expression_root) 1 else 0, .close = self.declares_closing } } });
        var targets: std.AutoHashMapUnmanaged(*const Ast.Node, *const Ast.Node) = .empty;
        for (self.resolutions) |resolved| try targets.put(self.allocator, resolved.jump, resolved.label);
        for (self.gotos.items) |jump| {
            const target_node = targets.get(jump.node) orelse return error.InvalidAst;
            const label = self.labels.get(target_node) orelse return error.InvalidAst;
            self.code.items[jump.close].operation = .{ .scope_exit = label.first };
            try self.patch(jump.jump, label.pc);
        }
    }

    fn expression(self: *Compiler, frame: Expression) Error!void {
        const node = frame.node;
        const destination = frame.destination;
        switch (node.data) {
            .function => |function| try self.lowerFunction(node, function, destination),
            .call => try self.produce(.{ .node = node, .destination = destination, .count = 1 }),
            .varargs => {
                if (!self.vararg) return error.InvalidAst;
                try self.emit(.{ .position = node.position, .operation = .{ .varargs = .{ .first = destination, .count = 1 } } });
            },
            .name => try self.readName(self.source[node.span.start..node.span.end], destination, node.position),
            .nil => try self.load(destination, .nil, node.position),
            .boolean => |b| try self.load(destination, .from(.{ .boolean = b }), node.position),
            .number => |n| try self.load(destination, .from(.{ .number = n }), node.position),
            .integer => |n| try self.load(destination, try self.state.integer(n), node.position),
            .string => |literal| {
                var diagnostic: ?decoder.Diagnostic = null;
                const bytes = decoder.decode(self.allocator, self.source, literal, &diagnostic) catch |err| {
                    if (diagnostic) |failure| self.diagnostic.* = .{ .string = failure };
                    return switch (err) {
                        error.OutOfMemory => error.OutOfMemory,
                        error.Syntax => error.Syntax,
                        error.InvalidSpan => error.InvalidAst,
                    };
                };
                defer self.allocator.free(bytes);
                try self.load(destination, .from(.{ .string = try self.state.newString(bytes) }), node.position);
            },
            .group => |inner| try self.push(.{ .expression = .{ .node = inner, .destination = destination } }),
            .unary => |unary| {
                const operator: bytecode.Unary = switch (unary.operator.kind) {
                    .@"-" => .negate,
                    .not => .not,
                    .@"#" => .length,
                    .@"~" => .bitwise_not,
                    else => return error.InvalidAst,
                };
                try self.push(.{ .emit = .{ .position = unary.operator.position, .names = .{ .primary = try self.nameHint(unary.operand) }, .operation = .{ .unary = .{ .operator = operator, .register = destination } } } });
                try self.push(.{ .expression = .{ .node = unary.operand, .destination = destination } });
            },
            .binary => |binary| {
                // In place only when neither operand needs evaluating: a local on
                // the left and a local or a literal on the right. Anything else
                // keeps the general form, whose instruction count the carried
                // hook cases observe (`return 10 + 20` runs four instructions).
                if (binary.operator.kind != .@"and" and binary.operator.kind != .@"or") {
                    if (try self.localRegister(binary.left)) |left| {
                        if (try self.operand(binary.right)) |right| {
                            try self.push(.{ .binary_right = .{ .node = node, .destination = destination, .left = left, .right = right } });
                            return;
                        }
                        // A local that no closure can capture keeps its value
                        // while the right operand is evaluated, so it is read
                        // where it is, after, with nothing copied first: the
                        // operands are still read left to right.
                        if (!self.holdsFunction()) {
                            const restore = self.next_register;
                            const right = try self.reserve(1, binary.right.position);
                            try self.push(.{ .release = .{ .first = restore, .position = node.position, .emit_clear = false } });
                            try self.push(.{ .emit = .{ .position = binary.operator.position, .names = .{ .primary = try self.nameHint(binary.left), .secondary = try self.nameHint(binary.right) }, .operation = .{ .binary = .{ .operator = binaryOperator(binary.operator.kind) orelse return error.InvalidAst, .destination = destination, .left = left, .right = right } } } });
                            try self.push(.{ .expression = .{ .node = binary.right, .destination = right } });
                            return;
                        }
                    }
                }
                try self.push(.{ .binary_right = .{ .node = node, .destination = destination } });
                try self.push(.{ .expression = .{ .node = binary.left, .destination = destination } });
            },
            .table => |fields| {
                var items: usize = 0;
                var keyed: usize = 0;
                for (fields, 0..) |field, index| switch (field.key) {
                    .list => if (!(index + 1 == fields.len and multiple(field.value))) {
                        items += 1;
                    },
                    .name, .expression => keyed += 1,
                };
                const sized: @FieldType(bytecode.Instruction.Operation, "table") = .{
                    .destination = destination,
                    // A hint only: a count past u32 is left to growth.
                    .items = std.math.cast(u32, items) orelse 0,
                    .fields = std.math.cast(u32, keyed) orelse 0,
                };
                try self.emit(.{ .position = node.position, .operation = .{ .table = sized } });
                try self.push(.{ .table_fields = .{ .node = node, .destination = destination, .pending_first = self.next_register, .restore = self.next_register, .batch_limit = batchLimit(self.next_register) } });
            },
            .index => |index| {
                // A key that needs no instruction is read in place. From a local
                // receiver it is read directly; otherwise `binaryRight` decides after
                // the receiver, which keeps the order of the constant table.
                if (try self.localRegister(index.receiver)) |receiver| {
                    if (try self.operand(index.key)) |key| {
                        try self.push(.{ .binary_right = .{ .node = node, .destination = destination, .left = receiver, .right = key } });
                        return;
                    }
                }
                // Reserve the key only after the receiver is compiled, so long
                // left-associated/suffix trees do not consume one register per node.
                try self.push(.{ .binary_right = .{ .node = node, .destination = destination } });
                try self.push(.{ .expression = .{ .node = index.receiver, .destination = destination } });
            },
            .field => |field| {
                // A field name is always a constant key, so it never takes a register.
                // The constant is made after the receiver, as the order of the
                // constant table and so the point its limit is reached depend on it.
                if (try self.localRegister(field.receiver)) |receiver| {
                    const key: Operand = .{ .constant = try self.constant(.from(.{ .string = try self.state.newString(self.source[field.name.start..field.name.end]) }), self.positionOf(field.name)) };
                    try self.push(.{ .binary_right = .{ .node = node, .destination = destination, .left = receiver, .right = key } });
                    return;
                }
                try self.push(.{ .binary_right = .{ .node = node, .destination = destination } });
                try self.push(.{ .expression = .{ .node = field.receiver, .destination = destination } });
            },
            .block, .empty, .declaration, .definition, .assignment, .conditional, .while_loop, .repeat_loop, .numeric_for, .generic_for, .do_block, .break_statement, .goto_statement, .label, .return_statement => return error.InvalidAst,
        }
    }

    fn binaryRight(self: *Compiler, frame: BinaryRight) Error!void {
        const node = frame.node;
        const destination = frame.destination;
        if (node.data == .binary) {
            const binary = node.data.binary;
            if (binary.operator.kind == .@"and" or binary.operator.kind == .@"or") {
                const patch_index = self.code.items.len;
                try self.emit(.{ .position = binary.operator.position, .operation = .{ .branch = .{ .register = destination, .when = binary.operator.kind == .@"or", .target = 0 } } });
                try self.push(.{ .patch = patch_index });
                try self.push(.{ .expression = .{ .node = binary.right, .destination = destination } });
                return;
            }
        }
        if (frame.right) |right| {
            if (node.data == .index or node.data == .field) {
                try self.emit(.{ .position = node.position, .names = .{ .primary = try self.nameHint(if (node.data == .index) node.data.index.receiver else node.data.field.receiver) }, .operation = .{ .get = .{
                    .destination = destination,
                    .table = frame.left orelse destination,
                    .key = switch (right) {
                        .register => |register| register,
                        .constant => |index| index,
                    },
                    .key_constant = right == .constant,
                } } });
                return;
            }
            const binary = node.data.binary;
            try self.emit(.{ .position = binary.operator.position, .names = .{ .primary = try self.nameHint(binary.left), .secondary = try self.nameHint(binary.right) }, .operation = .{ .binary = .{
                .operator = binaryOperator(binary.operator.kind) orelse return error.InvalidAst,
                .destination = destination,
                .left = frame.left orelse destination,
                .right = switch (right) {
                    .register => |register| register,
                    .constant => |index| index,
                },
                .right_constant = right == .constant,
            } } });
            return;
        }
        if (node.data == .field) {
            const field = node.data.field;
            const key = try self.constant(.from(.{ .string = try self.state.newString(self.source[field.name.start..field.name.end]) }), self.positionOf(field.name));
            try self.emit(.{ .position = node.position, .names = .{ .primary = try self.nameHint(field.receiver) }, .operation = .{ .get = .{ .destination = destination, .table = destination, .key = key, .key_constant = true } } });
            return;
        }
        if (node.data == .binary) {
            // The left operand is in the destination now, and the right one is
            // read after it either way: a literal or a local needs no copy. A
            // literal left keeps the general form, whose instruction count the
            // carried hook cases observe (`return 10 + 20` runs four).
            const binary = node.data.binary;
            if (!isLiteral(binary.left)) {
                if (try self.operand(binary.right)) |right| {
                    if (right == .constant or right.register != destination) {
                        try self.emit(.{ .position = binary.operator.position, .names = .{ .primary = try self.nameHint(binary.left), .secondary = try self.nameHint(binary.right) }, .operation = .{ .binary = .{
                            .operator = binaryOperator(binary.operator.kind) orelse return error.InvalidAst,
                            .destination = frame.result orelse destination,
                            .left = destination,
                            .right = switch (right) {
                                .register => |register| register,
                                .constant => |index| index,
                            },
                            .right_constant = right == .constant,
                        } } });
                        return;
                    }
                }
            }
        }
        if (node.data == .index) {
            // The receiver is in the destination now; a key in that same
            // register would be overwritten before it is read. No path gives a
            // bound local as the destination of a read today (`directAssignment`
            // does not take one), so this guards a later change, not a case.
            if (try self.operand(node.data.index.key)) |key| {
                if (key == .constant or key.register != destination) {
                    try self.emit(.{ .position = node.position, .names = .{ .primary = try self.nameHint(node.data.index.receiver) }, .operation = .{ .get = .{
                        .destination = destination,
                        .table = destination,
                        .key = switch (key) {
                            .register => |register| register,
                            .constant => |index| index,
                        },
                        .key_constant = key == .constant,
                    } } });
                    return;
                }
            }
        }
        const restore = self.next_register;
        const right = try self.reserve(1, switch (node.data) {
            .binary => |binary| binary.right.position,
            .index => |index| index.key.position,
            else => return error.InvalidAst,
        });
        try self.push(.{ .release = .{ .first = restore, .position = node.position, .emit_clear = node.data != .binary } });
        switch (node.data) {
            .binary => |binary| {
                try self.push(.{ .emit = .{ .position = binary.operator.position, .names = .{ .primary = try self.nameHint(binary.left), .secondary = try self.nameHint(binary.right) }, .operation = .{ .binary = .{ .operator = binaryOperator(binary.operator.kind) orelse return error.InvalidAst, .destination = frame.result orelse destination, .left = destination, .right = right } } } });
                try self.push(.{ .expression = .{ .node = binary.right, .destination = right } });
            },
            .index => |index| {
                try self.push(.{ .emit = .{ .position = node.position, .names = .{ .primary = try self.nameHint(index.receiver) }, .operation = .{ .get = .{ .destination = destination, .table = destination, .key = right } } } });
                try self.push(.{ .expression = .{ .node = index.key, .destination = right } });
            },
            else => return error.InvalidAst,
        }
    }

    fn holdsFunction(self: *Compiler) bool {
        return self.holds_function;
    }

    /// Whether a local of this function lives in `register`. The chain holds
    /// this function's bindings only; an outer function's are reached as upvalues.
    fn boundRegister(self: *const Compiler, register: usize) bool {
        var binding = self.environment;
        while (binding) |current| : (binding = current.parent) {
            if (current.storage == .local and current.storage.local == register) return true;
        }
        return false;
    }

    /// A condition comparing a local with a local or a literal: one
    /// `compare_branch`, which jumps when the answer is `when`, in place of
    /// the comparison and its `branch`. Answers its index for the patch, or
    /// null for any other condition, which takes the general form.
    fn compareBranch(self: *Compiler, condition: *const Ast.Node, when: bool) Error!?usize {
        var node = condition;
        while (node.data == .group) node = node.data.group;
        if (node.data != .binary) return null;
        const binary = node.data.binary;
        const operator = binaryOperator(binary.operator.kind) orelse return null;
        switch (operator) {
            .equal, .not_equal, .less, .less_equal, .greater, .greater_equal => {},
            else => return null,
        }
        const left = (try self.localRegister(binary.left)) orelse return null;
        const right = (try self.operand(binary.right)) orelse return null;
        const index = self.code.items.len;
        try self.emit(.{ .position = binary.operator.position, .names = .{ .primary = try self.nameHint(binary.left), .secondary = try self.nameHint(binary.right) }, .operation = .{ .compare_branch = .{
            .operator = operator,
            .left = left,
            .right = right.index(),
            .right_constant = right == .constant,
            .when = when,
            .target = 0,
        } } });
        return index;
    }

    fn comparison(original: *const Ast.Node) bool {
        var node = original;
        while (node.data == .group) node = node.data.group;
        return switch (node.data) {
            .binary => |binary| switch (binary.operator.kind) {
                .@"==", .@"~=", .@"<", .@"<=", .@">", .@">=" => true,
                else => false,
            },
            else => false,
        };
    }

    fn isLiteral(original: *const Ast.Node) bool {
        var node = original;
        while (node.data == .group) node = node.data.group;
        return switch (node.data) {
            .nil, .boolean, .number, .integer, .string => true,
            else => false,
        };
    }

    /// The register of a local the node names, or null for anything else.
    fn localRegister(self: *Compiler, original: *const Ast.Node) Error!?usize {
        var node = original;
        while (node.data == .group) node = node.data.group;
        if (node.data != .name) return null;
        return switch (try self.lookup(self.text(node.span), node.position)) {
            .local => |register| register,
            else => null,
        };
    }

    /// An operand that needs no instruction of its own: a local's register or
    /// a literal's constant index. Null for anything that has to be evaluated.
    fn operand(self: *Compiler, original: *const Ast.Node) Error!?Operand {
        var node = original;
        while (node.data == .group) node = node.data.group;
        const value: runtime.Value = switch (node.data) {
            .name => return if (try self.localRegister(node)) |register| .{ .register = register } else null,
            .nil => .nil,
            .boolean => |b| .from(.{ .boolean = b }),
            .number => |n| .from(.{ .number = n }),
            .integer => |n| try self.state.integer(n),
            .string => |literal| blk: {
                var diagnostic: ?decoder.Diagnostic = null;
                const bytes = decoder.decode(self.allocator, self.source, literal, &diagnostic) catch |err| {
                    if (diagnostic) |failure| self.diagnostic.* = .{ .string = failure };
                    return switch (err) {
                        error.OutOfMemory => error.OutOfMemory,
                        error.Syntax => error.Syntax,
                        error.InvalidSpan => error.InvalidAst,
                    };
                };
                defer self.allocator.free(bytes);
                break :blk .from(.{ .string = try self.state.newString(bytes) });
            },
            else => return null,
        };
        return .{ .constant = try self.constant(value, node.position) };
    }

    /// `name = value` with one local target and a value that writes the local
    /// only once, at the end: another local, a literal, or a binary operator
    /// whose left operand is a local and whose right needs no evaluation. The
    /// value goes straight into the local; anything else takes the general plan.
    fn directAssignment(self: *Compiler, targets: []const *const Ast.Node, expressions: []const *const Ast.Node) Error!bool {
        if (targets.len == 1 and expressions.len == 1 and (targets[0].data == .index or targets[0].data == .field)) return self.directStore(targets[0], expressions[0]);
        if (targets.len != 1 or expressions.len != 1 or targets[0].data != .name) return false;
        const destination = (try self.localRegister(targets[0])) orelse return false;
        var value = expressions[0];
        while (value.data == .group) value = value.data.group;
        switch (value.data) {
            .name => {
                const source = (try self.localRegister(value)) orelse return false;
                if (source != destination) try self.emit(.{ .position = targets[0].position, .operation = .{ .move = .{ .source = source, .destination = destination } } });
                return true;
            },
            .nil, .boolean, .number, .integer, .string => {
                const index = (try self.operand(value)).?.constant;
                try self.emit(.{ .position = targets[0].position, .operation = .{ .constant = .{ .destination = destination, .index = index } } });
                return true;
            },
            .binary => |binary| {
                if (binary.operator.kind == .@"and" or binary.operator.kind == .@"or") return false;
                if (try self.localRegister(binary.left)) |left| {
                    if (try self.operand(binary.right)) |right| {
                        try self.binaryRight(.{ .node = value, .destination = destination, .left = left, .right = right });
                        return true;
                    }
                    // A left local no closure can capture is read in place
                    // after the right operand, as in an expression (`.binary`).
                    if (!self.holdsFunction()) {
                        const right = try self.reserve(1, binary.right.position);
                        try self.push(.{ .release = .{ .first = right, .position = value.position, .emit_clear = false } });
                        try self.push(.{ .emit = .{ .position = binary.operator.position, .names = .{ .primary = try self.nameHint(binary.left), .secondary = try self.nameHint(binary.right) }, .operation = .{ .binary = .{ .operator = binaryOperator(binary.operator.kind) orelse return error.InvalidAst, .destination = destination, .left = left, .right = right } } } });
                        try self.push(.{ .expression = .{ .node = binary.right, .destination = right } });
                        return true;
                    }
                }
                // The operands are evaluated into temporaries as an
                // expression's are, in the same order; the operation writes
                // the local and clears them, so nothing follows it.
                const temporary = try self.reserve(1, value.position);
                try self.push(.{ .release = .{ .first = temporary, .position = value.position, .emit_clear = false } });
                try self.push(.{ .binary_right = .{ .node = value, .destination = temporary, .result = destination } });
                try self.push(.{ .expression = .{ .node = binary.left, .destination = temporary } });
                return true;
            },
            // The call's first result moves into the local after the call
            // returned, so a failing call leaves the local as it was.
            .call => {
                try self.push(.{ .produce = .{ .node = value, .destination = destination, .count = 1 } });
                return true;
            },
            else => return false,
        }
    }

    /// `t[k] = v` and `t.name = v` where the receiver is a local and the key
    /// and the value are locals or literals: no code runs between reading
    /// them and storing, so one `set` reads them where they are, in the order
    /// the general form would. Constants are made in that order too.
    fn directStore(self: *Compiler, target_node: *const Ast.Node, value_node: *const Ast.Node) Error!bool {
        const receiver_node = if (target_node.data == .index) target_node.data.index.receiver else target_node.data.field.receiver;
        const receiver = (try self.localRegister(receiver_node)) orelse return false;
        const key: Operand = if (target_node.data == .field)
            .{ .constant = try self.constant(.from(.{ .string = try self.state.newString(self.text(target_node.data.field.name)) }), target_node.position) }
        else
            (try self.operand(target_node.data.index.key)) orelse return false;
        const value = (try self.operand(value_node)) orelse return false;
        try self.emit(.{ .position = target_node.position, .names = .{ .primary = try self.nameHint(receiver_node) }, .operation = .{ .set = .{
            .table = receiver,
            .key = switch (key) {
                .register => |register| register,
                .constant => |index| index,
            },
            .value = switch (value) {
                .register => |register| register,
                .constant => |index| index,
            },
            .key_constant = key == .constant,
            .value_constant = value == .constant,
        } } });
        return true;
    }

    fn tableFields(self: *Compiler, frame: TableFields) Error!void {
        var next = frame;
        const fields = frame.node.data.table;
        const open_tail = frame.index + 1 == fields.len and fields[frame.index].key == .list and multiple(fields[frame.index].value);
        if (frame.pending_count == frame.batch_limit or frame.index == fields.len or open_tail) {
            if (frame.pending_count > 0) {
                const key = try self.reserve(1, frame.node.position);
                for (0..frame.pending_count) |i| {
                    try self.load(key, runtime.Value.fromCount(frame.list_count - frame.pending_count + i + 1), frame.node.position);
                    try self.emit(.{ .position = frame.node.position, .operation = .{ .set = .{ .table = frame.destination, .key = key, .value = frame.pending_first + i } } });
                }
                try self.release(frame.restore, frame.node.position);
                next.pending_count = 0;
                next.pending_first = frame.restore;
            }
            if (frame.index == fields.len) return;
        }
        const field = fields[frame.index];
        if (open_tail) {
            try self.push(.{ .emit = .{ .position = field.value.position, .operation = .{ .set_list = .{ .table = frame.destination, .first = self.next_register, .index = next.list_count + 1 } } } });
            try self.push(.{ .produce = .{ .node = field.value, .destination = self.next_register, .count = null } });
            return;
        }
        next.index += 1;
        switch (field.key) {
            .list => {
                const destination = try self.reserve(1, field.value.position);
                if (next.pending_count == 0) next.pending_first = destination;
                next.pending_count += 1;
                next.list_count += 1;
                try self.push(.{ .table_fields = next });
                try self.push(.{ .expression = .{ .node = field.value, .destination = destination } });
            },
            .name, .expression => {
                const restore = self.next_register;
                const key_position = switch (field.key) {
                    .expression => |expression_node| expression_node.position,
                    .name => |span| self.positionOf(span),
                    .list => return error.InvalidAst,
                };
                if (field.key == .name) {
                    // A name is a constant key and needs no register.
                    const span = field.key.name;
                    const key = try self.constant(.from(.{ .string = try self.state.newString(self.source[span.start..span.end]) }), key_position);
                    // A local or a literal is read where it is, as `directStore`
                    // reads it: nothing runs between reading and storing.
                    if (try self.operand(field.value)) |direct| {
                        try self.emit(.{ .position = field.value.position, .operation = .{ .set = .{
                            .table = frame.destination,
                            .key = key,
                            .value = direct.index(),
                            .key_constant = true,
                            .value_constant = direct == .constant,
                        } } });
                        try self.push(.{ .table_fields = next });
                        return;
                    }
                    const value = try self.reserve(1, field.value.position);
                    try self.push(.{ .table_fields = next });
                    try self.push(.{ .release = .{ .first = restore, .position = field.value.position } });
                    try self.push(.{ .emit = .{ .position = field.value.position, .operation = .{ .set = .{ .table = frame.destination, .key = key, .value = value, .key_constant = true } } } });
                    try self.push(.{ .expression = .{ .node = field.value, .destination = value } });
                    return;
                }
                if (try self.operand(field.key.expression)) |key| {
                    if (try self.operand(field.value)) |direct| {
                        try self.emit(.{ .position = field.value.position, .operation = .{ .set = .{
                            .table = frame.destination,
                            .key = key.index(),
                            .value = direct.index(),
                            .key_constant = key == .constant,
                            .value_constant = direct == .constant,
                        } } });
                        try self.push(.{ .table_fields = next });
                        return;
                    }
                }
                const key = try self.reserve(1, key_position);
                const value = try self.reserve(1, field.value.position);
                try self.push(.{ .table_fields = next });
                try self.push(.{ .release = .{ .first = restore, .position = field.value.position } });
                try self.push(.{ .emit = .{ .position = field.value.position, .operation = .{ .set = .{ .table = frame.destination, .key = key, .value = value } } } });
                try self.push(.{ .expression = .{ .node = field.value, .destination = value } });
                try self.push(.{ .expression = .{ .node = field.key.expression, .destination = key } });
            },
        }
    }
};

fn batchLimit(next_register: usize) usize {
    const free = 255 - next_register;
    return if (free >= 160) free / 5 else if (free >= 80) 10 else 1;
}

fn binaryOperator(kind: Token.Kind) ?bytecode.Binary {
    return switch (kind) {
        .@"+" => .add,
        .@"-" => .subtract,
        .@"*" => .multiply,
        .@"/" => .divide,
        .@"//" => .floor_divide,
        .@"%" => .modulo,
        .@"^" => .power,
        .@".." => .concatenate,
        .@"==" => .equal,
        .@"~=" => .not_equal,
        .@"<" => .less,
        .@"<=" => .less_equal,
        .@">" => .greater,
        .@">=" => .greater_equal,
        .@"&" => .bitwise_and,
        .@"|" => .bitwise_or,
        .@"~" => .bitwise_xor,
        .@"<<" => .shift_left,
        .@">>" => .shift_right,
        else => null,
    };
}

/// Compiles parsed expressions and chunks. AST/source are borrowed during the
/// call; the state owns resulting code, constants and copied source metadata.
/// Validation reports language refusals; malformed internal shapes are InvalidAst.
/// Exhaustive expression/statement switches require new AST tags to be classified.
pub fn compile(allocator: std.mem.Allocator, state: *runtime.State, ast: *const Ast, chunk_name: []const u8, diagnostic: *?Diagnostic) Error!*runtime.Prototype {
    diagnostic.* = null;
    var control_diagnostic: ?control.Diagnostic = null;
    control.checkControl(allocator, ast, &control_diagnostic) catch |err| {
        if (control_diagnostic) |failure| diagnostic.* = .{ .control = failure };
        return err;
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var names: scope.Analysis = .empty;
    var names_diagnostic: ?scope.Diagnostic = null;
    var environment_written = true;
    scope.analyze(arena.allocator(), ast, &names_diagnostic, &names, &environment_written) catch |err| {
        if (names_diagnostic) |failure| diagnostic.* = .{ .names = failure };
        return err;
    };
    var resolutions: std.ArrayList(jumps.Resolution) = .empty;
    var jumps_diagnostic: ?jumps.Diagnostic = null;
    jumps.resolve(arena.allocator(), ast, &jumps_diagnostic, &resolutions) catch |err| {
        if (jumps_diagnostic) |failure| diagnostic.* = .{ .jumps = failure };
        return err;
    };
    var jobs: std.ArrayList(*Compiler) = .empty;
    // In the arena, which frees it with the rest of the compilation.
    const lines = try Lexer.Lines.init(arena.allocator(), ast.source);
    const root = try arena.allocator().create(Compiler);
    root.* = .{ .allocator = arena.allocator(), .state = state, .source = ast.source, .lines = &lines, .diagnostic = diagnostic, .resolutions = resolutions.items, .names = &names, .environment_fixed = !environment_written, .jobs = &jobs, .body = ast.root, .holds_function = ast.holds_function, .expression_root = ast.root.data != .block };
    try root.bind(scope.root_environment, .{ .upvalue = 0 });
    if (ast.root.data == .block) {
        root.vararg = true;
        _ = try root.reserve(1, ast.root.position);
    }
    try jobs.append(root.allocator, root);
    var index: usize = 0;
    while (index < jobs.items.len) : (index += 1) try jobs.items[index].lower();
    // Capture discovery in descendants can extend an intermediate function's
    // upvalues. Publish metadata only after every body has been lowered.
    for (jobs.items, 0..) |job, order| {
        // The first function copies the source; the others share that copy.
        const prototype = if (order == 0)
            try state.newProgram(job.constants.items, job.code.items, job.registers, ast.source, chunk_name)
        else
            try state.newProgramSharing(job.constants.items, job.code.items, job.registers, jobs.items[0].prototype.?.source, chunk_name);
        prototype.parameters = job.parameters;
        prototype.vararg = job.vararg;
        prototype.line_defined = job.defined_line;
        prototype.last_line_defined = job.end_line;
        prototype.upvalue_count = if (job.parent == null) (if (job.needs_environment or ast.root.data == .block) @as(usize, 1) else 0) else job.captures.items.len;
        job.prototype = prototype;
    }
    for (jobs.items) |job| {
        const children = try job.allocator.alloc(*runtime.Prototype, job.children.items.len);
        for (job.children.items, children) |child, *output| output.* = child.prototype.?;
        try state.linkPrototype(job.prototype.?, job.captures.items, children);
    }
    return root.prototype.?;
}

pub fn write(writer: *std.Io.Writer, prototype: *const runtime.Prototype) std.Io.Writer.Error!void {
    try writer.print("chunk {s}; {d} registers; vararg={any}\n", .{ prototype.chunk_name, prototype.registers, prototype.vararg });
    try writer.print("parameters {d}; captures {d}; children {d}\n", .{ prototype.parameters, prototype.upvalue_count, prototype.children.len });
    for (prototype.captures, 0..) |capture, i| try writer.print("capture {d}: {any}\n", .{ i, capture });
    for (prototype.constants, 0..) |value, i| {
        try writer.print("constant {d}: {s}", .{ i, value.typeName() });
        switch (value.unpack()) {
            .number => |n| try writer.print(" {d}", .{n}),
            .integer => |n| try writer.print(" {d}", .{n}),
            .boolean => |b| try writer.print(" {any}", .{b}),
            .string => |s| {
                try writer.writeAll(" hex:");
                for (s.bytes) |b| try writer.print("{x:0>2}", .{b});
            },
            else => {},
        }
        try writer.writeByte('\n');
    }
    try bytecode.write(writer, prototype.code);
}

fn multiple(node: *const Ast.Node) bool {
    return node.data == .varargs or node.data == .call;
}

/// Whether a function is written anywhere in the node, nested functions'
/// own bodies aside: a closure made there is the only way a local of the
/// enclosing function can be captured.
fn holdsFunctionIn(node: *const Ast.Node) bool {
    return switch (node.data) {
        .nil, .boolean, .number, .integer, .string, .name, .varargs, .empty, .break_statement, .goto_statement, .label => false,
        .function => true,
        .group, .do_block => |inner| holdsFunctionIn(inner),
        .unary => |unary| holdsFunctionIn(unary.operand),
        .binary => |binary| holdsFunctionIn(binary.left) or holdsFunctionIn(binary.right),
        .index => |index| holdsFunctionIn(index.receiver) or holdsFunctionIn(index.key),
        .field => |field| holdsFunctionIn(field.receiver),
        .call => |call| holdsFunctionIn(call.receiver) or anyHoldsFunction(call.arguments),
        .table => |fields| for (fields) |field| {
            if (field.key == .expression and holdsFunctionIn(field.key.expression)) break true;
            if (holdsFunctionIn(field.value)) break true;
        } else false,
        .block, .return_statement => |nodes| anyHoldsFunction(nodes),
        .declaration => |declaration| anyHoldsFunction(declaration.values),
        .definition => |definition| holdsFunctionIn(definition.target) or holdsFunctionIn(definition.value),
        .assignment => |assignment| anyHoldsFunction(assignment.targets) or anyHoldsFunction(assignment.values),
        .conditional => |conditional| for (conditional.arms) |arm| {
            if (holdsFunctionIn(arm.condition) or holdsFunctionIn(arm.body)) break true;
        } else if (conditional.otherwise) |otherwise| holdsFunctionIn(otherwise) else false,
        .while_loop => |loop| holdsFunctionIn(loop.condition) or holdsFunctionIn(loop.body),
        .repeat_loop => |loop| holdsFunctionIn(loop.body) or holdsFunctionIn(loop.condition),
        .numeric_for => |loop| holdsFunctionIn(loop.initial) or holdsFunctionIn(loop.limit) or (if (loop.step) |step| holdsFunctionIn(step) else false) or holdsFunctionIn(loop.body),
        .generic_for => |loop| anyHoldsFunction(loop.values) or holdsFunctionIn(loop.body),
    };
}

fn anyHoldsFunction(nodes: []const *const Ast.Node) bool {
    for (nodes) |node| if (holdsFunctionIn(node)) return true;
    return false;
}

/// Every function node under `node`, the outermost first.
fn collectFunctions(node: *const Ast.Node, into: *std.ArrayList(Ast.Function), allocator: std.mem.Allocator) !void {
    switch (node.data) {
        .function => |function| {
            try into.append(allocator, function);
            try collectFunctions(function.body, into, allocator);
        },
        .group, .do_block => |inner| try collectFunctions(inner, into, allocator),
        .unary => |unary| try collectFunctions(unary.operand, into, allocator),
        .binary => |binary| {
            try collectFunctions(binary.left, into, allocator);
            try collectFunctions(binary.right, into, allocator);
        },
        .field => |field| try collectFunctions(field.receiver, into, allocator),
        .index => |index| {
            try collectFunctions(index.receiver, into, allocator);
            try collectFunctions(index.key, into, allocator);
        },
        .call => |call| {
            try collectFunctions(call.receiver, into, allocator);
            for (call.arguments) |argument| try collectFunctions(argument, into, allocator);
        },
        .table => |fields| for (fields) |field| {
            if (field.key == .expression) try collectFunctions(field.key.expression, into, allocator);
            try collectFunctions(field.value, into, allocator);
        },
        .block, .return_statement => |items| for (items) |item| try collectFunctions(item, into, allocator),
        .declaration => |declaration| for (declaration.values) |value| try collectFunctions(value, into, allocator),
        .definition => |definition| {
            try collectFunctions(definition.target, into, allocator);
            try collectFunctions(definition.value, into, allocator);
        },
        .assignment => |assignment| {
            for (assignment.targets) |target| try collectFunctions(target, into, allocator);
            for (assignment.values) |value| try collectFunctions(value, into, allocator);
        },
        .conditional => |conditional| {
            for (conditional.arms) |arm| {
                try collectFunctions(arm.condition, into, allocator);
                try collectFunctions(arm.body, into, allocator);
            }
            if (conditional.otherwise) |otherwise| try collectFunctions(otherwise, into, allocator);
        },
        .while_loop => |loop| {
            try collectFunctions(loop.condition, into, allocator);
            try collectFunctions(loop.body, into, allocator);
        },
        .repeat_loop => |loop| {
            try collectFunctions(loop.body, into, allocator);
            try collectFunctions(loop.condition, into, allocator);
        },
        .numeric_for => |loop| {
            try collectFunctions(loop.initial, into, allocator);
            try collectFunctions(loop.limit, into, allocator);
            if (loop.step) |step| try collectFunctions(step, into, allocator);
            try collectFunctions(loop.body, into, allocator);
        },
        .generic_for => |loop| {
            for (loop.values) |value| try collectFunctions(value, into, allocator);
            try collectFunctions(loop.body, into, allocator);
        },
        else => {},
    }
}

test "compiler the parser's holds_function agrees with a walk of each body" {
    const allocator = std.testing.allocator;
    const sources = [_][]const u8{
        "return 1",
        "local x = 1 return x",
        "local function f() return 1 end",
        "local function f() return function() return 2 end end",
        "local t = { a = function() end, [function() end] = 1 }",
        "for i = 1, 3 do local g = function() return i end end",
        "for k, v in pairs({}) do end while false do end repeat local h = 1 until true",
        "if x then local function a() end elseif y then return (function() end)() else end",
        "local f = function() local g = function() local h = function() end end end",
        "function t.m(self) return self end function t:n() return function() end end",
        "local a, b = 1, function() end; c = f(function() end)",
        "do local q = { [1] = { function() end } } end",
    };
    for (sources) |source| {
        var diagnostic: ?@import("parser.zig").Diagnostic = null;
        var ast = try @import("parser.zig").parseChunk(allocator, source, &diagnostic);
        defer ast.deinit();
        try std.testing.expectEqual(holdsFunctionIn(ast.root), ast.holds_function);
        var functions: std.ArrayList(Ast.Function) = .empty;
        defer functions.deinit(allocator);
        try collectFunctions(ast.root, &functions, allocator);
        for (functions.items) |function| try std.testing.expectEqual(holdsFunctionIn(function.body), function.holds_function);
    }
}
