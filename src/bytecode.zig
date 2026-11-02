const std = @import("std");
const Token = @import("Token.zig");

pub const Unary = enum { negate, not, length, bitwise_not };
pub const Binary = enum { add, subtract, multiply, divide, floor_divide, modulo, power, concatenate, equal, not_equal, less, less_equal, greater, greater_equal, bitwise_and, bitwise_or, bitwise_xor, shift_left, shift_right };
pub const Capture = union(enum) { local: usize, upvalue: usize };

/// What the prototype keeps of where an instruction came from, at the width
/// the VM and the C API read. The front end's `Token.Position` and
/// `Token.Span` are 32-bit to keep the syntax tree small; widening them here,
/// once per instruction, leaves every reader of a prototype as it was.
pub const Position = struct {
    offset: usize,
    line: usize,
    column: usize,

    pub fn of(position: Token.Position) Position {
        return .{ .offset = position.offset, .line = position.line, .column = position.column };
    }
};
pub const Span = struct {
    start: usize,
    end: usize,

    pub fn of(span: Token.Span) Span {
        return .{ .start = span.start, .end = span.end };
    }
};
pub const StringLiteral = struct {
    contents: Span,
    long_level: ?usize,

    pub fn of(literal: Token.StringLiteral) StringLiteral {
        return .{ .contents = .of(literal.contents), .long_level = literal.long_level };
    }
};

pub const Name = struct {
    kind: enum { local, global, field, method, upvalue, constant, for_iterator, metamethod },
    /// `fixed` is a text the source did not spell: a metamethod's event name
    /// ("add") for a handler that cannot be called, and Lua's `?` or
    /// `integer index` for a field read through a key that is not a name.
    text: union(enum) { span: Span, literal: StringLiteral, environment, iterator, fixed: []const u8 },
};
pub const Names = struct { primary: ?Name = null, secondary: ?Name = null, subject: ?Name = null };

/// With `target`, the one result goes into that register, a local below the
/// call's slots, once the call has returned, and every slot from `base` up is
/// left nil: `x = f()` needs neither a move nor a clear after it.
pub const Call = struct {
    base: usize,
    arguments: ?u32,
    results: ?u32,
    target: ?u8 = null,

    /// The counts as the VM uses them; they are stored narrow so that an
    /// instruction stays within a cache line (registers are at most 255).
    pub fn argumentCount(op: Call) ?usize {
        return if (op.arguments) |count| count else null;
    }
    pub fn resultCount(op: Call) ?usize {
        return if (op.results) |count| count else null;
    }
};

/// `to` is the instruction at `target`, set at validation so that a jump
/// loads it instead of computing it (null until then).
/// `captures` is false when the loop's body holds no function, so that no
/// cell can be open on the control variable or above it: a `for_loop` then
/// takes an arm that does not look for one.
pub const NumericFor = struct { base: usize, target: usize, to: ?*const anyopaque = null, captures: bool = true };
/// A `get`/`set` with no field cache: its key is not a constant string, or
/// the prototype has not been validated yet.
pub const no_cache = std.math.maxInt(u32);
/// An instruction as a compiler writes it: the operation, where in the source
/// it comes from, and the names a failure there words. `State.newProgram`
/// makes the prototype's `Instruction`s and `Info`s from these.
pub const Written = struct {
    position: Token.Position,
    operation: Instruction.Operation,
    names: Names = .{},
};

/// What only a failure, a listing or a host's query reads of an
/// instruction, kept beside the code as Lua keeps its line information, so
/// that what runs is the operation and the arm alone.
pub const Info = struct {
    position: Position,
    names: Names = .{},
    /// The call's index into the prototype's `call_names`; a prototype
    /// cannot hold 2^32 calls, each of which is an instruction.
    call_name_index: ?u32 = null,
};

/// What runs: the operation, its arm, and where its `Info` is, in one cache
/// line. The operation comes first: with the arm first, forsum and fields
/// measured 1.063 and 1.031 and method 0.938, against 1.002, 0.994 and 1.000
/// with it last (four layouts).
pub const Instruction = struct {
    operation: Operation,
    /// The frame loop's arm for this instruction, set by `assignDispatch`
    /// when the prototype is validated; derived, never printed.
    dispatch: Dispatch = .unassigned,
    /// This instruction's entry in its prototype's `info`.
    info: *const Info,
    /// The frame loop's arm itself (the VM's function for `dispatch`), set
    /// with it at validation: the loop jumps through it with no table to
    /// index. Null until then; a prototype is validated before it runs.
    arm: ?*const anyopaque = null,

    comptime {
        // One cache line an instruction.
        std.debug.assert(@sizeOf(Instruction) <= 64);
    }

    pub const Operation = union(enum) {
        closure: struct { destination: usize, child: usize },
        move: struct { destination: usize, source: usize },
        get_upvalue: struct { destination: usize, index: usize },
        set_upvalue: struct { source: usize, index: usize },
        jump: struct { target: usize, to: ?*const anyopaque = null },
        scope_exit: usize,
        for_prepare: NumericFor,
        for_loop: NumericFor,
        init_global: struct { environment: usize, key: usize, value: usize },
        constant: struct { destination: usize, index: usize },
        unary: struct { operator: Unary, register: usize },
        /// The operands are the registers `left` and `right`, or the constant
        /// `right` when `right_constant`. The result is written to
        /// `destination` only after both operands are read and the operator
        /// succeeded, so it may be a local named on either side.
        binary: struct { operator: Binary, destination: usize, left: usize, right: usize, right_constant: bool = false },
        /// A new table into `destination`, with room for the constructor's
        /// `items` (list entries, a trailing call or `...` not counted) and
        /// `fields` (keyed entries): a size the program states, so filling
        /// it does not regrow it.
        /// `template` names the prototype's table template, given at
        /// load (`no_cache` for none).
        table: struct { destination: usize, items: u32 = 0, fields: u32 = 0, template: u32 = no_cache },
        /// `table` is an upvalue index when `table_upvalue`: a global read
        /// takes `_ENV` from its cell in the same instruction.
        get: struct { destination: usize, table: usize, key: usize, key_constant: bool = false, table_upvalue: bool = false, cache: u32 = no_cache },
        /// `table` is an upvalue index when `table_upvalue`, as for `get`.
        set: struct { table: usize, key: usize, value: usize, key_constant: bool = false, value_constant: bool = false, table_upvalue: bool = false, cache: u32 = no_cache },
        branch: struct { register: usize, when: bool, target: usize, to: ?*const anyopaque = null },
        /// A comparison and the branch on its answer in one: jumps to
        /// `target` when the answer is `when`. `operator` is one of the six
        /// comparisons; the answer is never stored, so no register holds it.
        compare_branch: struct { operator: Binary, left: usize, right: usize, right_constant: bool = false, when: bool, target: u32, to: ?*const anyopaque = null },
        clear: struct { first: usize, count: usize },
        tail_call: struct { base: usize, arguments: ?usize },
        call: Call,
        generic_call: struct { base: usize, count: usize },
        generic_loop: NumericFor,
        move_results: struct { destination: usize, source: usize },
        varargs: struct { first: usize, count: ?usize },
        set_list: struct { table: usize, first: usize, index: usize },
        /// `close`: a to-be-closed variable may be live; its value is closed
        /// before the frame returns.
        returns: struct { first: usize, count: ?usize, close: bool = false },
        /// The register's value is a to-be-closed variable's (`<close>`):
        /// checked to be closable and remembered until the scope ending at
        /// or below `level` ends. A local's level is its register; a generic
        /// `for`'s closing value, read from its fourth slot, takes the loop's
        /// second hidden slot, below the body's variables.
        to_be_closed: struct { register: usize, level: usize },
    };
};

/// Which arm of the frame loop runs an instruction: the operation's own tag,
/// except that a binary operation is split by its operator, so that the
/// loop dispatches once. `binary_other` covers the operators the loop does
/// not compute itself.
pub const Dispatch = enum(u8) {
    unassigned,
    closure,
    move,
    get_upvalue,
    set_upvalue,
    jump,
    scope_exit,
    for_prepare,
    for_loop,
    init_global,
    constant,
    unary,
    table,
    get,
    set,
    /// A `set` whose table is the upvalue `_ENV`: an arm of its own, so the
    /// common `set` reads its table from a register without a test.
    set_global,
    branch,
    branch_equal,
    branch_not_equal,
    branch_less,
    branch_less_equal,
    branch_greater,
    branch_greater_equal,
    clear,
    tail_call,
    call,
    generic_call,
    generic_loop,
    move_results,
    varargs,
    set_list,
    returns,
    /// `returns` of one value with nothing to close, Lua's RETURN1.
    return_one,
    to_be_closed,
    add,
    subtract,
    multiply,
    less,
    less_equal,
    greater,
    greater_equal,
    equal,
    not_equal,
    binary_other,
};

comptime {
    // Every operation but `binary` and `compare_branch` keeps its own name
    // as its arm; those two have one arm per operator.
    for (@typeInfo(Instruction.Operation).@"union".field_names) |name| {
        if (!std.mem.eql(u8, name, "binary") and !std.mem.eql(u8, name, "compare_branch") and !@hasField(Dispatch, name)) @compileError("no dispatch arm for " ++ name);
    }
}

pub fn dispatchOf(operation: Instruction.Operation) Dispatch {
    return switch (operation) {
        .binary => |op| switch (op.operator) {
            .add => .add,
            .subtract => .subtract,
            .multiply => .multiply,
            .less => .less,
            .less_equal => .less_equal,
            .greater => .greater,
            .greater_equal => .greater_equal,
            .equal => .equal,
            .not_equal => .not_equal,
            .divide, .floor_divide, .modulo, .power, .concatenate, .bitwise_and, .bitwise_or, .bitwise_xor, .shift_left, .shift_right => .binary_other,
        },
        .set => |op| if (op.table_upvalue) .set_global else .set,
        .returns => |op| if (op.count == 1 and !op.close) .return_one else .returns,
        .compare_branch => |op| switch (op.operator) {
            .equal => .branch_equal,
            .not_equal => .branch_not_equal,
            .less => .branch_less,
            .less_equal => .branch_less_equal,
            .greater => .branch_greater,
            .greater_equal => .branch_greater_equal,
            // Validation refuses any other operator before dispatch is assigned.
            else => .branch_equal,
        },
        inline else => |_, tag| @field(Dispatch, @tagName(tag)),
    };
}

pub fn assignDispatch(code: []Instruction) void {
    for (code) |*instruction| instruction.dispatch = dispatchOf(instruction.operation);
}

/// Prints instructions without running them. Operands are register/constant
/// indices and source positions; no object addresses are part of this format.
pub fn write(writer: *std.Io.Writer, instructions: []const Instruction) std.Io.Writer.Error!void {
    for (instructions, 0..) |instruction, index| {
        const info = instruction.info;
        try writer.print("{d:0>4} {d}:{d} {any}", .{ index, info.position.line, info.position.column, instruction.operation });
        if (info.names.primary != null or info.names.secondary != null or info.names.subject != null) try writer.print(" names {any}", .{info.names});
        try writer.writeByte('\n');
    }
}
