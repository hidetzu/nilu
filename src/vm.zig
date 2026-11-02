const std = @import("std");
/// This file, for the arms named as the functions they call.
const Vm = @This();
/// Each arm's alignment: a function's own on the target, where the compiler
/// places it anyway (asking for less would change the arms' pointer type), or
/// more for a measurement build (`-Darm-slot`, tools/README.md, "Measuring
/// speed").
const arm_alignment: u32 = @max(@alignOf(fn () void), @import("layout").arm_slot);
/// The section the arms go in, in every build: one of their own, so that a
/// change to the rest of the code (the compiler, the parser, I/O) does not
/// move them, and with it how fast a script runs (tools/README.md, "Code
/// layout"). Within it they keep the compiler's order, which such a change
/// leaves alone. A COFF image starts each section on a page; Mach-O packs
/// sections, so there `start` asks for a page, which aligns the section.
const arm_section = switch (@import("builtin").target.ofmt) {
    .macho => "__TEXT,__nilu_arms",
    .coff => ".nilarms",
    else => ".text.nilu_arms",
};
const start_alignment: u32 = if (@import("builtin").target.ofmt == .macho) @max(arm_alignment, 4096) else arm_alignment;
const runtime = @import("runtime.zig");
const native = @import("native.zig");
const execution = @import("execution_context.zig");
const bytecode = @import("bytecode.zig");
const HashPart = @import("HashPart.zig");
const numeral = @import("numeral.zig");
const arithmetic = @import("arithmetic.zig");
const Token = @import("Token.zig");
const Value = runtime.Value;
const max_list_index: usize = @min(std.math.maxInt(usize), 9007199254740992);

/// `Yield` is not a failure: a coroutine is suspending, and every level
/// between the yield and its resume passes it on without unwinding the
/// coroutine's frames (ADR 0013).
pub const Error = error{ OutOfMemory, StackLimit, CallDepth, Interrupted, Type, Runtime, PendingFeature, InvalidBytecode, InvalidNativeResult, Yield };
pub const ForArgument = @import("runtime_diagnostic.zig").ForArgument;
pub const Diagnostic = @import("runtime_diagnostic.zig").Diagnostic;

fn range(first: usize, count: usize, registers: usize) bool {
    return first <= registers and count <= registers - first;
}

/// The instruction format is internal, but malformed indices must never become
/// unchecked stack accesses. Backward branches implement source loops.
pub fn validate(prototype: *const runtime.Prototype) error{InvalidBytecode}!void {
    if (prototype.registers > runtime.State.max_stack or prototype.code.len == 0 or (prototype.parameters > prototype.registers) or (prototype.vararg and prototype.parameters >= prototype.registers) or prototype.upvalue_count > 255) return error.InvalidBytecode;
    const registers = prototype.registers;
    // The frame loop does not test for the end of the code before each
    // instruction: the last one must be one that never falls through.
    switch (prototype.code[prototype.code.len - 1].operation) {
        .returns, .jump, .tail_call => {},
        else => return error.InvalidBytecode,
    }
    for (prototype.code) |instruction| {
        if (instruction.info.call_name_index) |index| {
            if (index >= prototype.call_names.len or prototype.call_names[index] == null) return error.InvalidBytecode;
        }
        if (!validNames(instruction.info.names, prototype.source.len) or instruction.info.position.offset > prototype.source.len or instruction.info.position.line == 0 or instruction.info.position.column == 0) return error.InvalidBytecode;
        const valid = validRegisters(instruction.operation, registers) and switch (instruction.operation) {
            .constant => |op| op.index < prototype.constants.len,
            .binary => |op| !op.right_constant or op.right < prototype.constants.len,
            .get => |op| (!op.key_constant or op.key < prototype.constants.len) and (!op.table_upvalue or op.table < prototype.upvalue_count) and (op.cache == bytecode.no_cache or op.cache < prototype.field_caches.len),
            .set => |op| (!op.key_constant or op.key < prototype.constants.len) and (!op.value_constant or op.value < prototype.constants.len) and (!op.table_upvalue or op.table < prototype.upvalue_count) and (op.cache == bytecode.no_cache or op.cache < prototype.field_caches.len),
            .table => |op| op.template == bytecode.no_cache or op.template < prototype.table_templates.len,
            .get_upvalue => |op| op.index < prototype.upvalue_count,
            .set_upvalue => |op| op.index < prototype.upvalue_count,
            .jump => |op| op.target < prototype.code.len,
            .branch => |op| op.target < prototype.code.len,
            .compare_branch => |op| op.target < prototype.code.len and (!op.right_constant or op.right < prototype.constants.len) and switch (op.operator) {
                .equal, .not_equal, .less, .less_equal, .greater, .greater_equal => true,
                else => false,
            },
            .for_prepare, .for_loop, .generic_loop => |op| op.target < prototype.code.len,
            .closure => |op| closureDescriptorValid(prototype, op.child),
            .varargs => |op| prototype.vararg and op.first > prototype.parameters,
            else => true,
        };
        if (!valid) return error.InvalidBytecode;
    }
}

fn validNames(names: bytecode.Names, length: usize) bool {
    for ([_]?bytecode.Name{ names.primary, names.secondary, names.subject }) |optional| {
        const name = optional orelse continue;
        const span = switch (name.text) {
            .span => |span| span,
            .literal => |literal| literal.contents,
            .environment, .iterator, .fixed => continue,
        };
        if (span.start > span.end or span.end > length) return false;
    }
    return true;
}

fn closureDescriptorValid(parent: *const runtime.Prototype, index: usize) bool {
    if (index >= parent.children.len) return false;
    const child = parent.children[index];
    if (child.captures.len != child.upvalue_count or child.upvalue_count > 255) return false;
    for (child.captures) |capture| switch (capture) {
        .local => |slot| if (slot >= parent.registers) {
            return false;
        },
        .upvalue => |slot| if (slot >= parent.upvalue_count) {
            return false;
        },
    };
    return true;
}

fn validRegisters(operation: bytecode.Instruction.Operation, registers: usize) bool {
    return switch (operation) {
        .closure => |op| op.destination < registers,
        .move => |op| op.destination < registers and op.source < registers,
        .get_upvalue => |op| op.destination < registers,
        .set_upvalue => |op| op.source < registers,
        .jump => true,
        .scope_exit => |first| first <= registers,
        .to_be_closed => |op| op.register < registers and op.level < registers,
        .for_prepare, .for_loop, .generic_loop => |op| range(op.base, 3, registers),
        .generic_call => |op| op.count > 0 and range(op.base, 2, registers) and range(op.base + 2, @max(3, op.count), registers),
        .init_global => |op| op.environment < registers and op.key < registers and op.value < registers,
        .constant => |op| op.destination < registers,
        .unary => |op| op.register < registers,
        .binary => |op| op.destination < registers and op.left < registers and (op.right_constant or op.right < registers),
        .table => |op| op.destination < registers,
        .get => |op| op.destination < registers and (op.table_upvalue or op.table < registers) and (op.key_constant or op.key < registers),
        .set => |op| (op.table_upvalue or op.table < registers) and (op.key_constant or op.key < registers) and (op.value_constant or op.value < registers),
        .branch => |op| op.register < registers,
        .compare_branch => |op| op.left < registers and (op.right_constant or op.right < registers),
        .clear => |op| range(op.first, op.count, registers),
        .tail_call => |op| op.base < registers and (if (op.arguments) |count| range(op.base + 1, count, registers) else true),
        .call => |op| op.base < registers and (if (op.arguments) |count| range(op.base + 1, count, registers) else true) and (if (op.results) |count| range(op.base, count, registers) else true) and (if (op.target) |target| target < op.base and op.results == 1 else true),
        .move_results => |op| op.destination <= op.source and op.source <= registers,
        .varargs => |op| registers > 0 and op.first > 0 and (if (op.count) |count| range(op.first, count, registers) else op.first <= registers),
        .set_list => |op| op.table < registers and op.table < op.first and op.first <= registers and op.index > 0 and op.index <= max_list_index,
        .returns => |op| if (op.count) |count| range(op.first, count, registers) else op.first <= registers,
    };
}

fn forType(diagnostic: *?Diagnostic, instruction: *const bytecode.Instruction, argument: ForArgument, value: Value) Error {
    diagnostic.* = .{ .kind = .for_not_number, .position = instruction.info.position, .operation = .for_prepare, .for_argument = argument, .operand_type = value.type(), .type_name = customType(value) };
    return error.Type;
}

fn forPrepare(state: *runtime.State, instruction: *const bytecode.Instruction, registers: []Value, diagnostic: *?Diagnostic) Error!bool {
    const base = instruction.operation.for_prepare.base;
    // Values are evaluated in source order, then checked in Lua's limit/step/
    // initial order. No string-to-number conversion crosses this boundary.
    const limit_number = arithmetic.Number.of(registers[base + 1]) orelse return forType(diagnostic, instruction, .limit, registers[base + 1]);
    const step_number = arithmetic.Number.of(registers[base + 2]) orelse return forType(diagnostic, instruction, .step, registers[base + 2]);
    const initial_number = arithmetic.Number.of(registers[base]) orelse return forType(diagnostic, instruction, .initial, registers[base]);
    if (step_number.asFloat() == 0) {
        diagnostic.* = .{ .kind = .for_step_zero, .position = instruction.info.position, .operation = .for_prepare, .for_argument = .step };
        return error.Runtime;
    }
    // An integer start and step make an integer loop, as Lua's: the limit
    // made an integer the way Lua's forlimit does, and the loop then never
    // overflows (`forLoop`).
    if (initial_number == .integer and step_number == .integer) {
        const initial = initial_number.integer;
        const step = step_number.integer;
        const limit = integerLimit(initial, limit_number, step) orelse return true;
        const step_value = registers[base + 2];
        const initial_value = registers[base];
        registers[base] = try state.integer(limit);
        registers[base + 1] = step_value;
        registers[base + 2] = initial_value;
        return false;
    }
    const initial = initial_number.asFloat();
    const limit = limit_number.asFloat();
    const step = step_number.asFloat();
    if (if (step > 0) limit < initial else initial < limit) return true;
    // Rotate [initial, limit, step] to [limit, step, visible index]. The strict
    // skip test differs from the inclusive continuation test even with NaNs.
    // Already numbers: moved, not made, so no check.
    registers[base] = .fromNumberUnchecked(limit);
    registers[base + 1] = .fromNumberUnchecked(step);
    registers[base + 2] = .fromNumberUnchecked(initial);
    return false;
}

/// Lua's forlimit: the limit of an integer loop as an integer, rounded
/// toward the start; one past the 64-bit range is clipped to it, or skips
/// the loop when the start is beyond it. Null when the loop does not run.
fn integerLimit(initial: i64, limit: arithmetic.Number, step: i64) ?i64 {
    const bound: i64 = switch (limit) {
        .integer => |n| n,
        .float => |f| runtime.floatToInteger(if (step < 0) @ceil(f) else @floor(f)) orelse blk: {
            if (f > 0) {
                if (step < 0) return null;
                break :blk std.math.maxInt(i64);
            }
            if (step > 0) return null;
            break :blk std.math.minInt(i64);
        },
    };
    return if (if (step > 0) initial > bound else initial < bound) null else bound;
}

fn forLoop(state: *runtime.State, instruction: *const bytecode.Instruction, registers: []Value, frame_base: usize) Error!bool {
    const base = instruction.operation.for_loop.base;
    if (registers[base + 2].is(.integer)) {
        // `forPrepare` made all three integers.
        const limit = registers[base].asInteger();
        const step = registers[base + 1].asInteger();
        const index = registers[base + 2].asInteger();
        state.closeFrom(frame_base + base + 2);
        const next = @addWithOverflow(index, step);
        // Past the 64-bit range is past the limit too, which is inside it.
        if (next[1] != 0) return false;
        if (if (step > 0) next[0] <= limit else limit <= next[0]) {
            registers[base + 2] = try state.integer(next[0]);
            return true;
        }
        return false;
    }
    const limit = registers[base].numberIn() orelse return error.InvalidBytecode;
    const step = registers[base + 1].numberIn() orelse return error.InvalidBytecode;
    const index = registers[base + 2].numberIn() orelse return error.InvalidBytecode;
    // The visible variable belongs to the body's current turn. Preserve its
    // captured value before updating the reused stack slot for the next turn.
    state.closeFrom(frame_base + base + 2);
    const next = index + step;
    if (if (step > 0) next <= limit else limit <= next) {
        registers[base + 2].storeNumber(next);
        return true;
    }
    return false;
}

fn metatable(state: *const runtime.State, value: Value) ?*runtime.Table {
    return switch (value.unpack()) {
        .table => |table| table.metatable,
        .userdata => |userdata| userdata.metatable,
        .string => state.string_metatable,
        else => null,
    };
}

/// The ordinary __index chain's limit, shared by the inheritance walk so
/// that a metamethod is found exactly where `mt[name]` would find it (the
/// owner's answer of 2026-10-27).
const inheritance_link_budget = 2000;

/// Finds a metamethod by the one rule every handler shares (ADR 0012): raw
/// in the metatable, then along the table-valued __index of that metatable's
/// own metatable, each link read raw. A function __index is never run, so no
/// script runs and nothing is allocated while a name is looked up. The table
/// after the last permitted link is still read, as in an ordinary __index
/// chain, and a miss there is the chain refusal, whether the chain is long or
/// cyclic. Names that describe the metatable itself (__gc, __metatable) are
/// read where they are written, by their own callers, never through here.
fn lookup(state: *const runtime.State, value: Value, name: []const u8) error{ChainTooLong}!Value {
    return lookupFrom(metatable(state, value) orelse return .nil, name);
}

fn lookupFrom(first: *runtime.Table, name: []const u8) error{ChainTooLong}!Value {
    // Hashed once for the whole chain.
    return lookupFromHashed(first, name, runtime.hashString(name));
}

/// `lookupFrom` with the name's hash given: a name known at compile time is
/// hashed then (`metamethodNamed`).
fn lookupFromHashed(first: *runtime.Table, name: []const u8, hash: u64) error{ChainTooLong}!Value {
    var current = first;
    var links: usize = 0;
    while (true) {
        const found = current.getStringHashed(name, hash);
        if (!found.is(.nil)) return found;
        if (links == inheritance_link_budget) return error.ChainTooLong;
        const link: Value = if (current.metatable) |meta| meta.getName("__index") else .nil;
        if (!link.is(.table)) return .nil;
        current = link.unpack().table;
        links += 1;
    }
}

/// The VM's metamethod read: a chain that runs out is the same Runtime
/// refusal as an ordinary __index chain, placed at the instruction.
/// The metamethod the VM would find for the value, for the C API's query:
/// the same walk as every metamethod lookup, nothing run.
pub fn metafield(state: *const runtime.State, value: Value, name: []const u8) error{ChainTooLong}!Value {
    return lookup(state, value, name);
}

fn metamethod(state: *const runtime.State, value: Value, name: []const u8, instruction: *const bytecode.Instruction, diagnostic: *?Diagnostic) Error!Value {
    return lookup(state, value, name) catch chainTooLong(instruction, diagnostic);
}

/// `metamethod` for a name known at compile time, hashed then: the reads
/// every `__index`, `__newindex` and `__call` make.
fn metamethodNamed(state: *const runtime.State, value: Value, comptime name: []const u8, instruction: *const bytecode.Instruction, diagnostic: *?Diagnostic) Error!Value {
    const meta = metatable(state, value) orelse return .nil;
    return lookupFromHashed(meta, name, comptime runtime.hashString(name)) catch chainTooLong(instruction, diagnostic);
}

fn chainTooLong(instruction: *const bytecode.Instruction, diagnostic: *?Diagnostic) Error {
    diagnostic.* = .{ .kind = .index_chain_too_long, .position = instruction.info.position, .operation = std.meta.activeTag(instruction.operation) };
    return error.Runtime;
}

fn handler(state: *const runtime.State, value: Value, name: []const u8, instruction: *const bytecode.Instruction, diagnostic: *?Diagnostic) Error!bool {
    return !(try metamethod(state, value, name, instruction, diagnostic)).is(.nil);
}

/// A failure's sentence never fails: a __name the chain cannot reach leaves
/// the plain type word, as a __name that is not a string does, and the
/// failure being reported is kept (the owner's answer of 2026-10-27).
fn customType(value: Value) ?*runtime.String {
    // Only a table or a userdata names its type with __name, as in Lua.
    const meta = switch (value.unpack()) {
        .table => |table| table.metatable,
        .userdata => |userdata| userdata.metatable,
        else => null,
    } orelse return null;
    const name = lookupFrom(meta, "__name") catch return null;
    return if (name.is(.string)) name.unpack().string else null;
}

fn action(instruction: *const bytecode.Instruction) @FieldType(Diagnostic, "action") {
    return switch (instruction.operation) {
        .get, .set, .set_list, .init_global => .index,
        .call, .tail_call, .generic_call => .call,
        .unary => |op| switch (op.operator) {
            .length => .length,
            .bitwise_not => .bitwise,
            else => .arithmetic,
        },
        .binary => |op| operatorKind(op.operator),
        .compare_branch => |op| operatorKind(op.operator),
        else => null,
    };
}

fn rejectAt(diagnostic: *?Diagnostic, instruction: *const bytecode.Instruction, operand: Value, hint: ?bytecode.Name) Error {
    diagnostic.* = .{
        .kind = .type_error,
        .position = instruction.info.position,
        .operation = std.meta.activeTag(instruction.operation),
        .operand_type = operand.type(),
        .type_name = customType(operand),
        .action = action(instruction),
        .hint = hint,
    };
    return error.Type;
}
fn reject(diagnostic: *?Diagnostic, instruction: *const bytecode.Instruction, operand: Value) Error {
    return rejectAt(diagnostic, instruction, operand, instruction.info.names.primary);
}

fn unary(state: *runtime.State, instruction: *const bytecode.Instruction, value: Value, diagnostic: *?Diagnostic) Error!Value {
    return switch (instruction.operation.unary.operator) {
        .not => .fromBoolean(!value.truthy()),
        .negate => if (value.is(.number)) .from(.{ .number = -value.unpack().number }) else if (value.is(.integer)) try state.integer(0 -% value.asInteger()) else try operatorHandler(state, instruction, value, value, "__unm", .primary, diagnostic),
        .bitwise_not => if (arithmetic.Number.of(value)) |number| blk: {
            const n = number.asInteger() orelse return noInteger(diagnostic, instruction, instruction.info.names.primary);
            break :blk try state.integer(~n);
        } else try operatorHandler(state, instruction, value, value, "__bnot", .primary, diagnostic),
        .length => switch (value.unpack()) {
            .string => |string| try state.integer(@intCast(string.bytes.len)),
            .table => |table| if (try handler(state, value, "__len", instruction, diagnostic)) try operatorHandler(state, instruction, value, value, "__len", .primary, diagnostic) else try state.integer(@intCast(table.length())),
            else => try operatorHandler(state, instruction, value, value, "__len", .primary, diagnostic),
        },
    };
}

fn operatorHandler(state: *runtime.State, instruction: *const bytecode.Instruction, left: Value, right: Value, name: []const u8, side: enum { primary, secondary }, diagnostic: *?Diagnostic) Error!Value {
    var method = try metamethod(state, left, name, instruction, diagnostic);
    if (method.is(.nil)) method = try metamethod(state, right, name, instruction, diagnostic);
    const invalid_operand = if (side == .primary) left else right;
    const hint = if (side == .primary) instruction.info.names.primary else instruction.info.names.secondary;
    if (method.is(.nil)) {
        const err = rejectAt(diagnostic, instruction, invalid_operand, hint);
        if (action(instruction) == .compare) {
            diagnostic.*.?.other_type = right.type();
            diagnostic.*.?.other_name = customType(right);
            diagnostic.*.?.hint = null;
        }
        return err;
    }
    return invokeHandler(state, instruction, method, name, &.{ left, right }, diagnostic);
}

/// Share the actual operators without adding a bytecode or native frame.
/// Operands must remain rooted by the caller throughout the operation.
pub const Operation = union(enum) {
    get: [2]Value,
    set: [3]Value,
    length: Value,
    equal: [2]Value,
    less: [2]Value,
    less_equal: [2]Value,
};
pub fn operate(state: *runtime.State, operation: Operation, diagnostic: *?Diagnostic) Error!Value {
    diagnostic.* = null;
    // A host operation has no instruction of its own: one made here, at
    // the first line, names none.
    const info: bytecode.Info = .{ .position = .{ .offset = 0, .line = 1, .column = 1 } };
    return switch (operation) {
        .get => |values| get(state, &.{ .info = &info, .operation = .{ .get = .{ .destination = 0, .table = 0, .key = 1 } } }, values[0], values[1], diagnostic),
        .set => |values| blk: {
            try set(state, &.{ .info = &info, .operation = .{ .set = .{ .table = 0, .key = 1, .value = 2 } } }, values[0], values[1], values[2], diagnostic);
            break :blk .nil;
        },
        .length => |value| unary(state, &.{ .info = &info, .operation = .{ .unary = .{ .operator = .length, .register = 0 } } }, value, diagnostic),
        .equal, .less, .less_equal => |values| binary(state, &.{ .info = &info, .operation = .{ .binary = .{
            .operator = switch (operation) {
                .equal => .equal,
                .less => .less,
                .less_equal => .less_equal,
                else => unreachable,
            },
            .destination = 0,
            .left = 0,
            .right = 1,
        } } }, values[0], values[1], diagnostic),
    };
}

fn arithmeticHandler(operator: bytecode.Binary) []const u8 {
    return switch (operator) {
        .add => "__add",
        .subtract => "__sub",
        .multiply => "__mul",
        .divide => "__div",
        .floor_divide => "__idiv",
        .modulo => "__mod",
        .power => "__pow",
        .bitwise_and => "__band",
        .bitwise_or => "__bor",
        .bitwise_xor => "__bxor",
        .shift_left => "__shl",
        .shift_right => "__shr",
        else => "",
    };
}

/// Lua's refusal of a bitwise operand that has no integer value, naming
/// the operand when the source did.
fn noInteger(diagnostic: *?Diagnostic, instruction: *const bytecode.Instruction, hint: ?bytecode.Name) Error {
    diagnostic.* = .{
        .kind = .no_integer_representation,
        .position = instruction.info.position,
        .operation = std.meta.activeTag(instruction.operation),
        .hint = hint,
    };
    return error.Runtime;
}

fn byZero(diagnostic: *?Diagnostic, instruction: *const bytecode.Instruction, kind: @FieldType(Diagnostic, "kind")) Error {
    diagnostic.* = .{ .kind = kind, .position = instruction.info.position, .operation = std.meta.activeTag(instruction.operation) };
    return error.Runtime;
}

const modulo = arithmetic.floatModulo;

/// A string's bytes, or a number's spelling in `buffer` (the one `tostring`
/// gives), for `..`.
fn concatenationText(value: Value, buffer: *[64]u8) []const u8 {
    if (value.is(.string)) return value.asString().bytes;
    if (value.is(.integer)) return numeral.formatInteger(buffer, value.asInteger()) catch unreachable;
    return numeral.format(buffer, value.asNumber()) catch unreachable;
}

/// What an operator gives for two numbers, or null when it is not an
/// operator on numbers (concatenation). This is the one place the arithmetic
/// and the comparisons of numbers are spelled; the frame loop takes this path
/// before anything else, and `binary` takes it for the slow path's numbers.
fn numbers(operator: bytecode.Binary, a: f64, b: f64) ?Value {
    return switch (operator) {
        .add => .fromNumberUnchecked(a + b),
        .subtract => .fromNumberUnchecked(a - b),
        .multiply => .fromNumberUnchecked(a * b),
        .divide => .fromNumberUnchecked(a / b),
        .floor_divide => .from(.{ .number = @floor(a / b) }),
        .modulo => .from(.{ .number = modulo(a, b) }),
        .power => .from(.{ .number = std.math.pow(f64, a, b) }),
        .equal => .fromBoolean(a == b),
        .not_equal => .fromBoolean(a != b),
        .less => .fromBoolean(a < b),
        .less_equal => .fromBoolean(a <= b),
        .greater => .fromBoolean(a > b),
        .greater_equal => .fromBoolean(a >= b),
        // A bitwise result is an integer, which may need boxing: the slow path.
        .bitwise_and, .bitwise_or, .bitwise_xor, .shift_left, .shift_right => null,
        .concatenate => null,
    };
}

fn operatorKind(operator: bytecode.Binary) @FieldType(Diagnostic, "action") {
    return switch (operator) {
        .concatenate => .concatenate,
        .bitwise_and, .bitwise_or, .bitwise_xor, .shift_left, .shift_right => .bitwise,
        .less, .less_equal, .greater, .greater_equal => .compare,
        else => .arithmetic,
    };
}

fn binary(state: *runtime.State, instruction: *const bytecode.Instruction, left: Value, right: Value, diagnostic: *?Diagnostic) Error!Value {
    return binaryAs(state, instruction, instruction.operation.binary.operator, left, right, diagnostic);
}

/// `binary` for an instruction that names its operator elsewhere
/// (`compare_branch`).
fn binaryAs(state: *runtime.State, instruction: *const bytecode.Instruction, operator: bytecode.Binary, left: Value, right: Value, diagnostic: *?Diagnostic) Error!Value {
    if (left.is(.number) and right.is(.number)) {
        if (numbers(operator, left.asNumber(), right.asNumber())) |value| return value;
    }
    // An integer on either side, or a bitwise operator: Lua's two subtypes.
    if (arithmetic.Number.of(left)) |a| if (arithmetic.Number.of(right)) |b| {
        if (try arithmetic.binary(state, operator, a, b)) |outcome| switch (outcome) {
            .value => |value| return value,
            .divide_by_zero => return byZero(diagnostic, instruction, .divide_by_zero),
            .modulo_by_zero => return byZero(diagnostic, instruction, .modulo_by_zero),
            .no_integer => |side| return noInteger(diagnostic, instruction, if (side == 0) instruction.info.names.primary else instruction.info.names.secondary),
        };
    };
    switch (operator) {
        .equal, .not_equal => {
            var same = left.equal(right);
            if (!same and left.is(.table) and right.is(.table) and (try handler(state, left, "__eq", instruction, diagnostic) or try handler(state, right, "__eq", instruction, diagnostic))) same = (try operatorHandler(state, instruction, left, right, "__eq", .primary, diagnostic)).truthy();
            return .from(.{ .boolean = if (operator == .equal) same else !same });
        },
        .less, .less_equal, .greater, .greater_equal => {
            const reverse = operator == .greater or operator == .greater_equal;
            const a = if (reverse) right else left;
            const b = if (reverse) left else right;
            const inclusive = operator == .less_equal or operator == .greater_equal;
            if (a.is(.string) and b.is(.string)) {
                const order = a.unpack().string.order(b.unpack().string);
                return .from(.{ .boolean = order == .lt or (inclusive and order == .eq) });
            }
            // <= and >= never fall back to __lt: with no __le on either side
            // they are a Type failure, as the carried C case requires (the
            // owner's answer).
            const result = try operatorHandler(state, instruction, a, b, if (inclusive) "__le" else "__lt", .primary, diagnostic);
            return .from(.{ .boolean = result.truthy() });
        },
        .concatenate => {
            // A number joins as `tostring` spells it; arithmetic on a string
            // stays refused (the owner's answer).
            const left_joins = left.is(.string) or arithmetic.isNumber(left);
            if (!left_joins or !(right.is(.string) or arithmetic.isNumber(right))) return operatorHandler(state, instruction, left, right, "__concat", if (!left_joins) .primary else .secondary, diagnostic);
            var left_buffer: [64]u8 = undefined;
            var right_buffer: [64]u8 = undefined;
            const left_bytes = concatenationText(left, &left_buffer);
            const right_bytes = concatenationText(right, &right_buffer);
            const length = std.math.add(usize, left_bytes.len, right_bytes.len) catch return error.OutOfMemory;
            const bytes = try state.allocator.alloc(u8, length);
            defer state.allocator.free(bytes);
            @memcpy(bytes[0..left_bytes.len], left_bytes);
            @memcpy(bytes[left_bytes.len..], right_bytes);
            return .from(.{ .string = try state.newString(bytes) });
        },
        else => return operatorHandler(state, instruction, left, right, arithmeticHandler(operator), if (!arithmetic.isNumber(left)) .primary else .secondary, diagnostic),
    }
}

fn get(state: *runtime.State, instruction: *const bytecode.Instruction, receiver: Value, key: Value, diagnostic: *?Diagnostic) Error!Value {
    return getAfter(state, instruction, receiver, key, diagnostic, false);
}

/// `get`, where `receiver_missed` says the caller already found the
/// receiver, a table, holding nil for the key, so its search is not repeated.
fn getAfter(state: *runtime.State, instruction: *const bytecode.Instruction, receiver: Value, key: Value, diagnostic: *?Diagnostic, receiver_missed: bool) Error!Value {
    var current = receiver;
    var handlers: usize = 0;
    const valid_key = key.validKey();
    while (true) {
        if (current.is(.table)) {
            if (!(receiver_missed and handlers == 0)) {
                const value = current.unpack().table.get(key);
                if (!value.is(.nil)) return value;
            }
            // A key a table cannot hold reads nil without entering the
            // metatable (the owner's answer).
            if (!valid_key) return .nil;
        }
        // The lookup after the last handler can still find a value. A miss
        // there is the limit, before fetching another handler.
        if (handlers == 2000) {
            diagnostic.* = .{ .kind = .index_chain_too_long, .position = instruction.info.position, .operation = std.meta.activeTag(instruction.operation) };
            return error.Runtime;
        }
        const method = try metamethodNamed(state, current, "__index", instruction, diagnostic);
        if (method.is(.nil)) {
            if (current.is(.table)) return .nil;
            return rejectAt(diagnostic, instruction, current, if (handlers == 0) instruction.info.names.primary else null);
        }
        // A userdata receiver has no raw storage, but the same key still reads
        // nil without running its __index (the owner's follow-up).
        if (!valid_key) return .nil;
        if (method.isFunction()) return invokeHandler(state, instruction, method, "__index", &.{ current, key }, diagnostic);
        current = method;
        handlers += 1;
    }
}

fn set(state: *runtime.State, instruction: *const bytecode.Instruction, receiver: Value, key: Value, value: Value, diagnostic: *?Diagnostic) Error!void {
    var current = receiver;
    var handlers: usize = 0;
    while (true) {
        if (current.is(.table)) {
            // Reads of such keys are nil, but table writes reject them before
            // consulting a handler.
            const valid_key = key.validKey();
            if (!valid_key) {
                const err = rejectAt(diagnostic, instruction, key, null);
                diagnostic.*.?.action = .key;
                diagnostic.*.?.key_nan = key.is(.number);
                return err;
            }
            if (!current.unpack().table.get(key).is(.nil)) {
                state.barrier(&current.unpack().table.header);
                current.unpack().table.set(state.allocator, key, value) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.InvalidKey => error.InvalidBytecode,
                };
                return;
            }
        }
        // A present key after the final handler still accepts the write. A
        // miss there is a Runtime failure, as for reads (the owner's
        // answer), and nothing is stored.
        if (handlers == 2000) {
            diagnostic.* = .{ .kind = .newindex_chain_too_long, .position = instruction.info.position, .operation = std.meta.activeTag(instruction.operation) };
            return error.Runtime;
        }
        const method = try metamethodNamed(state, current, "__newindex", instruction, diagnostic);
        if (method.is(.nil)) {
            if (!current.is(.table)) return rejectAt(diagnostic, instruction, current, if (handlers == 0) instruction.info.names.primary else null);
            const stored_key = try state.storedKey(key);
            state.barrier(&current.unpack().table.header);
            current.unpack().table.set(state.allocator, stored_key, value) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidKey => error.InvalidBytecode,
            };
            return;
        }
        if (method.isFunction()) {
            _ = try invokeHandler(state, instruction, method, "__newindex", &.{ current, key, value }, diagnostic);
            return;
        }
        current = method;
        handlers += 1;
    }
}

// The handler and its arguments live above the caller's registers, using the
// same function entry as CALL. Nested execution may relocate the stack and GC
// may run, so no register slice may survive this call.
/// A handler is whatever a call accepts: a function, or a value whose `__call`
/// chain reaches one, which then receives the handler itself first, as Lua
/// does (the owner's answer of 2026-10-30). A handler nothing can
/// call fails as a call does, and the sentence names the metamethod instead of
/// a variable, since no variable was written.
fn invokeHandler(state: *runtime.State, instruction: *const bytecode.Instruction, method: Value, name: []const u8, arguments: []const Value, diagnostic: *?Diagnostic) Error!Value {
    const window = execution.Window.above(state);
    const saved_top = window.base;
    defer window.rollback(state);
    state.setLength(state.stack.items.len + 1 + arguments.len) catch |err| return stackError(err);
    state.stack.items[saved_top] = method;
    @memcpy(state.stack.items[saved_top + 1 ..], arguments);
    const frame_base = state.base();
    const prepared = resolveCallable(state, frame_base, instruction, saved_top - frame_base, arguments.len, null, diagnostic) catch |err| {
        if (err == error.Type) {
            if (diagnostic.*) |*found| {
                found.action = .call;
                found.hint = .{ .kind = .metamethod, .text = .{ .fixed = name[2..] } };
            }
        }
        return err;
    };
    // Run for a script frame's instruction, the instruction finishes when a
    // resume returns to it (`continueWaiting`). Run for a C API operation or
    // a frame that finishes its instruction itself (`init_global`), it is a
    // boundary a yield cannot cross (ADR 0013).
    const from_script = state.frames.items.len != 0 and state.frames.items[state.frames.items.len - 1].function == .closure and instruction.operation != .init_global;
    if (!from_script) state.non_yieldable += 1;
    defer if (!from_script) {
        state.non_yieldable -= 1;
    };
    const count = try runFunctionWithSite(state, prepared.function, prepared.arguments, diagnostic, prepared.site);
    return if (count == 0) .nil else state.stack.items[saved_top + 1];
}

fn failure(state: *runtime.State, prototype: *const runtime.Prototype, instruction: *const bytecode.Instruction, diagnostic: *?Diagnostic, err: Error) Error {
    // Every arm of the frame loop branches here on failure; marking it cold
    // keeps those branches out of the loop's hot path and its registers.
    @branchHint(.cold);
    if (err == error.Yield) return err;
    if (diagnostic.* == null) {
        if (state.failure) |record| {
            if (record.kind == failureKind(err)) diagnostic.* = record.diagnostic;
        }
    }
    if (diagnostic.* == null) diagnostic.* = .{
        .kind = switch (err) {
            error.Interrupted => .interrupted,
            error.CallDepth => .call_depth,
            error.PendingFeature => .pending_feature,
            error.OutOfMemory => .out_of_memory,
            error.StackLimit => .stack_limit,
            error.Type => .type_error,
            error.Runtime => .runtime_error,
            error.InvalidBytecode => .invalid_bytecode,
            error.InvalidNativeResult => .invalid_native_result,
            error.Yield => unreachable, // returned above
        },
        .position = instruction.info.position,
        .operation = std.meta.activeTag(instruction.operation),
    };
    const kind = failureKind(err);
    if (state.failure == null or state.failure.?.kind != kind) state.failure = .{
        .kind = kind,
        .value = if (err == error.OutOfMemory) .from(.{ .string = state.memory_failure }) else .nil,
        .position = diagnostic.*.?.position,
        .location = @import("execution_location.zig").Location.init(prototype.displayName(), diagnostic.*.?.position.line),
        .operation = diagnostic.*.?.operation,
        .origin = .vm,
        .needs_message = err == error.Type or err == error.Runtime or err == error.CallDepth,
    };
    if (state.failure.?.position == null) {
        state.failure.?.position = diagnostic.*.?.position;
        state.failure.?.location = @import("execution_location.zig").Location.init(prototype.displayName(), diagnostic.*.?.position.line);
        state.failure.?.operation = diagnostic.*.?.operation;
    }
    if (state.failure.?.diagnostic == null) state.failure.?.diagnostic = diagnostic.*;
    const completed = @import("runtime_diagnostic.zig").complete(state, prototype, err);
    const propagated = @import("failure_transport.zig").dispatch(state, completed);
    if (state.failure.?.diagnostic) |detail| diagnostic.* = detail;
    return propagated;
}

fn failureKind(err: Error) runtime.FailureKind {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.StackLimit => .stack_limit,
        error.CallDepth => .call_depth,
        error.Interrupted => .interrupted,
        error.Type => .type_error,
        error.Runtime => .runtime_error,
        error.PendingFeature => .pending_feature,
        error.InvalidBytecode => .invalid_bytecode,
        error.InvalidNativeResult => .invalid_native_result,
        // Every caller passes a yield on before asking what failed.
        error.Yield => unreachable,
    };
}

/// Every raw __call read is one fetch, the one that yields the function
/// included, and the budget is the manual's 1999 relays plus that last fetch
/// (owner's answer of 2026-10-27, the same unit Lua counts with 15).
const call_fetch_budget = 2000;

const PreparedCall = struct {
    function: runtime.Function,
    arguments: usize,
    site: ?runtime.CallSite,
};

/// Turns the value in the callee slot into a function the way every call
/// entry shares: ordinary, tail, generic-for iterator. Each relay puts the
/// value it replaces in front of the arguments, so the function finally called
/// sees the last relay first and the program's value after it, as in Lua.
/// A cycle spends the same budget as a long chain, so nothing is allocated
/// beyond stack growth and no visited set can run out of memory. Returns the
/// target, adjusted argument count and original call site as one result.
fn resolveCallable(state: *runtime.State, original_top: usize, instruction: *const bytecode.Instruction, base: usize, arguments: usize, caller: ?*const runtime.Prototype, diagnostic: *?Diagnostic) Error!PreparedCall {
    var count = arguments;
    var fetches: usize = 0;
    while (true) {
        const callee = state.stack.items[original_top + base];
        if (callee.asFunction()) |function| return .{
            .function = function,
            .arguments = count,
            // Only a native reads its call site; a script callee would drop it.
            .site = if (function == .closure) null else if (caller) |prototype| .{ .prototype = prototype, .instruction = instruction, .through_call = fetches != 0 } else null,
        };
        const method = try metamethodNamed(state, callee, "__call", instruction, diagnostic);
        // A relay without __call names its own type, and the sentence still
        // names the variable the call was written on, as Lua's does (the
        // owner's answer of 2026-10-27).
        if (method.is(.nil)) return reject(diagnostic, instruction, callee);
        fetches += 1;
        // Known chain refusals precede the next receiver insertion. Do not
        // misreport Type/Runtime as Stack/Memory for an already-invalid target.
        if (!method.isFunction()) {
            if (!method.is(.table) and !method.is(.userdata)) return reject(diagnostic, instruction, method);
            if (fetches == call_fetch_budget) {
                diagnostic.* = .{ .kind = .call_chain_too_long, .position = instruction.info.position, .operation = std.meta.activeTag(instruction.operation) };
                return error.Runtime;
            }
        }
        state.setLength(original_top + base + 2 + count) catch |err| return stackError(err);
        const absolute = original_top + base;
        std.mem.copyBackwards(Value, state.stack.items[absolute + 2 ..][0..count], state.stack.items[absolute + 1 ..][0..count]);
        if (state.origins.items.len != 0) {
            std.mem.copyBackwards(?*runtime.FailureOrigin, state.origins.items[absolute + 2 ..][0..count], state.origins.items[absolute + 1 ..][0..count]);
            state.origins.items[absolute + 1] = state.origins.items[absolute];
            state.origins.items[absolute] = null;
            // The shift moved every origin of the window up by two.
            if (state.origins_end > absolute) state.origins_end = @min(state.origins.items.len, state.origins_end + 2);
        }
        state.stack.items[absolute + 1] = callee;
        state.stack.items[absolute] = method;
        count += 1;
    }
}

fn call(state: *runtime.State, prototype: *const runtime.Prototype, original_top: usize, instruction: *const bytecode.Instruction, op: bytecode.Call, diagnostic: *?Diagnostic) Error!?usize {
    if (state.frames.items.len >= state.callLimit()) return failure(state, prototype, instruction, diagnostic, error.CallDepth);
    const arguments = op.arguments orelse state.stack.items.len - original_top - op.base - 1;
    const callee = state.stack.items[original_top + op.base];
    // A script function resolves to itself with no call site, which is what
    // resolveCallable would answer after its loop.
    const prepared: PreparedCall = if (callee.is(.closure)) .{ .function = .{ .closure = callee.unpack().closure }, .arguments = arguments, .site = null } else resolveCallable(state, original_top, instruction, op.base, arguments, prototype, diagnostic) catch |err| return failure(state, prototype, instruction, diagnostic, err);
    return finishCall(state, prototype, original_top, instruction, op.base, op.resultCount(), op.target, prepared, diagnostic);
}

/// The target has already been resolved. Native tail entries use this path
/// directly rather than resolving a second time and reconstructing provenance.
fn finishCall(state: *runtime.State, prototype: *const runtime.Prototype, original_top: usize, instruction: *const bytecode.Instruction, base: usize, requested: ?usize, target: ?u8, prepared: PreparedCall, diagnostic: *?Diagnostic) Error!?usize {
    state.setLength(original_top + base + 1 + prepared.arguments) catch |err| return failure(state, prototype, instruction, diagnostic, stackError(err));
    const count = runFunctionWithSite(state, prepared.function, prepared.arguments, diagnostic, prepared.site) catch |err| return failure(state, prototype, instruction, diagnostic, err);
    return @call(.always_inline, completeCall, .{ state, prototype, original_top, instruction, base, requested, target, count, diagnostic });
}

/// What a call does once its callee has returned `count` results, the last
/// slots of the stack: also how a call that yielded completes when resumed.
fn completeCall(state: *runtime.State, prototype: *const runtime.Prototype, original_top: usize, instruction: *const bytecode.Instruction, base: usize, requested: ?usize, target: ?u8, count: usize, diagnostic: *?Diagnostic) Error!?usize {
    if (target) |register| {
        // The one result into its local; the call's slots keep what they hold.
        const value = if (count > 0) state.stack.items[original_top + base + 1] else Value.nil;
        state.closeFrom(original_top + base);
        runtime.cutStack(&state.stack, original_top + base);
        state.stack.items[original_top + register] = value;
        state.extendRegisters(original_top + prototype.registers) catch |err| return failure(state, prototype, instruction, diagnostic, stackError(err));
        return null;
    }
    const wanted = requested orelse count;
    if (wanted > runtime.State.max_stack - original_top - base) return failure(state, prototype, instruction, diagnostic, error.StackLimit);
    state.closeFrom(original_top + base);
    const copied = @min(count, wanted);
    moveDown(state.stack.items[original_top + base ..][0..copied], state.stack.items[original_top + base + 1 ..][0..copied]);
    // Cut to the copied results and grow back, the missing results nil and
    // the slots above them keeping what they hold.
    runtime.cutStack(&state.stack, original_top + base + copied);
    const top = if (requested == null) base + wanted else prototype.registers;
    state.extendRegisters(original_top + top) catch |err| return failure(state, prototype, instruction, diagnostic, stackError(err));
    runtime.fillNil(state.stack.items[original_top + base + copied ..][0 .. wanted - copied]);
    return if (requested == null) base else null;
}

const moveDown = runtime.moveDown;

/// Sets every slot to nil with a plain loop: the ranges are a few registers
/// at a scope's end or a call's return, where a call to memset costs more
/// than the stores. The stores are volatile only so that the optimizer does
/// not turn the loop back into that call; nothing reads them concurrently.
fn clearSlots(slots: []Value) void {
    runtime.fillNil(slots);
}

fn stackError(err: error{ OutOfMemory, StackLimit, InvalidIndex }) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StackLimit => error.StackLimit,
        error.InvalidIndex => error.InvalidBytecode,
    };
}

fn packArguments(state: *runtime.State, arguments: []const Value) Error!*runtime.Table {
    const table = try state.newTable();
    const name = try state.newString("n");
    table.set(state.allocator, .from(.{ .string = name }), runtime.Value.fromCount(arguments.len)) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidKey => error.InvalidBytecode,
    };
    for (arguments, 0..) |value, i| table.set(state.allocator, runtime.Value.fromCount(i + 1), value) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidKey => error.InvalidBytecode,
    };
    return table;
}

/// Executes this increment's bytecode in a frame on the state's existing stack.
/// Results replace this frame's registers and remain rooted above the caller's
/// original top; the returned count borrows those stack slots, not a new slice.
/// Error paths restore stack/frame depth and core failures carry messages.
/// Complete public native/callable boundaries remain separate.
pub fn run(state: *runtime.State, closure: *runtime.Closure, diagnostic: *?Diagnostic) Error!usize {
    return runWithArguments(state, closure, 0, diagnostic);
}

/// Internal chunk entry: consumes the top argument_count slots and leaves every
/// result above the caller's preceding stack. After validation, failures consume
/// the arguments and restore that caller depth. This is not the public call API.
pub fn runWithArguments(state: *runtime.State, closure: *runtime.Closure, argument_count: usize, diagnostic: *?Diagnostic) Error!usize {
    return runFunctionWithArguments(state, .{ .closure = closure }, argument_count, diagnostic);
}

/// Internal host-stack entry. The callee precedes the top argument_count slots.
/// Resolve with the same budget and receiver ordering as bytecode calls. A host
/// entry has no source position; resolver diagnostics render without a chunk.
/// The caller has entered a context of its own around the call (the
/// transport, a coroutine's start), and a script callee runs in it
/// (`runInCallersContext`).
pub fn runCallableWithArguments(state: *runtime.State, argument_count: usize, diagnostic: *?Diagnostic) Error!usize {
    diagnostic.* = null;
    if (argument_count >= state.top()) return error.InvalidBytecode;
    const original_top = state.base();
    const base = state.top() - argument_count - 1;
    if (state.frames.items.len >= state.callLimit()) return failureAtHost(state, null, error.CallDepth);
    // A function is called as it is: what `resolveCallable` answers for one,
    // with no call site from a host, and without the instruction it needs
    // only to name a failure on the way through `__call`.
    if (state.stack.items[original_top + base].asFunction()) |function| return runInCallersContext(state, function, argument_count, diagnostic, null);
    const info: bytecode.Info = .{ .position = .{ .offset = 0, .line = 1, .column = 1 } };
    const instruction = bytecode.Instruction{
        .info = &info,
        .operation = .{ .call = .{ .base = base, .arguments = @intCast(argument_count), .results = null } },
    };
    const prepared = resolveCallable(state, original_top, &instruction, base, argument_count, null, diagnostic) catch |err| return failureAtHost(state, diagnostic.*, err);
    return runInCallersContext(state, prepared.function, prepared.arguments, diagnostic, prepared.site);
}

/// `runFunctionWithSite` without a context for a script callee, for a caller
/// that has just entered one around the call. That one already holds the
/// failure the caller had, rolls the call's window back and ends it; one
/// more, with no window anyone read and no protection, changed nothing, and
/// entering and leaving it was a third of a `pcall`'s contexts. A C
/// function still gets its own, which its API calls report into.
fn runInCallersContext(state: *runtime.State, function: runtime.Function, argument_count: usize, diagnostic: *?Diagnostic, site: ?runtime.CallSite) Error!usize {
    if (function != .closure) return runNative(state, function, argument_count, diagnostic, site, .window);
    if (std.debug.runtime_safety) std.debug.assert(state.execution != null and state.failure == null);
    if (diagnostic.* != null) diagnostic.* = null;
    _ = try execution.Window.arguments(state, argument_count);
    var succeeded = false;
    return runEntered(state, function, argument_count, diagnostic, &succeeded) catch |err| return scriptFailure(state, err);
}

fn failureAtHost(state: *runtime.State, diagnostic: ?Diagnostic, err: Error) Error {
    state.failure = .{
        .kind = failureKind(err),
        .value = if (err == error.OutOfMemory) .from(.{ .string = state.memory_failure }) else .nil,
        .origin = .native,
        .diagnostic = diagnostic,
        .needs_message = err == error.Type or err == error.Runtime or err == error.CallDepth,
    };
    return err;
}

/// Internal function entry shared by script calls, native reentry and handlers.
/// This is not the public C call API or its failure-value/status contract.
pub fn runFunctionWithArguments(state: *runtime.State, function: runtime.Function, argument_count: usize, diagnostic: *?Diagnostic) Error!usize {
    return runFunctionWithSite(state, function, argument_count, diagnostic, null);
}

// Aligned to a cache line: the frame loop is inlined here, and when other
// code moved it by 32 bytes, loops whose machine code had not changed ran up
// to 15% more cycles. Aligned, a change elsewhere cannot shift it. Both this
// function and `runEntered` carry it, since the compiler may inline the one
// into the other and keep only the outer function's alignment.
fn runFunctionWithSite(state: *runtime.State, function: runtime.Function, argument_count: usize, diagnostic: *?Diagnostic, site: ?runtime.CallSite) align(64) Error!usize {
    // Writing null writes the whole record; on the call path it is almost
    // always null already, so it is only written when it is not.
    if (function != .closure) return runNative(state, function, argument_count, diagnostic, site, .window);
    if (diagnostic.* != null) diagnostic.* = null;
    var context: execution.Context = undefined;
    context.begin(try execution.Window.arguments(state, argument_count));
    context.enter(state);
    var succeeded = false;
    defer context.leave(state, succeeded);
    return runEntered(state, function, argument_count, diagnostic, &succeeded) catch |err| return scriptFailure(state, err);
}

/// A script callee's failure as its entry leaves it: a record of its kind.
fn scriptFailure(state: *runtime.State, err: Error) Error {
    if (err == error.Yield) return err;
    if (state.failure == null or state.failure.?.kind != failureKind(err)) state.failure = .{
        .kind = failureKind(err),
        .value = if (err == error.OutOfMemory) .from(.{ .string = state.memory_failure }) else .nil,
        .origin = .vm,
        .needs_message = err == error.CallDepth,
    };
    return err;
}

/// A C function's entry, from the host or from a script's call: its own
/// context, and its results at `destination` (native.Destination).
/// Aligned to a cache line as `runFunctionWithSite` is: moved 48 bytes off
/// one by an unrelated change, `bench/native.nilu` ran 4% more cycles on the
/// same instructions in every arm layout.
noinline fn runNative(state: *runtime.State, function: runtime.Function, argument_count: usize, diagnostic: *?Diagnostic, site: ?runtime.CallSite, comptime destination: native.Destination) align(64) Error!usize {
    if (diagnostic.* != null) diagnostic.* = null;
    const window = try execution.Window.arguments(state, argument_count);
    var context: execution.Context = undefined;
    context.begin(window);
    context.enter(state);
    var succeeded = false;
    defer context.leave(state, succeeded);
    if (state.vm_entries == 0) state.hook_remaining = state.hook_interval;
    state.vm_entries += 1;
    defer state.vm_entries -= 1;
    const results = native.callInto(state, function, window, site, destination) catch |err| {
        if (err == error.Yield) return err;
        if (state.failure == null or state.failure.?.kind != failureKind(err)) state.failure = .{
            .kind = failureKind(err),
            .value = if (err == error.OutOfMemory) .from(.{ .string = state.memory_failure }) else .nil,
            .origin = .native,
            .needs_message = err == error.CallDepth,
        };
        return err;
    };
    succeeded = true;
    return results;
}

/// A script function's entry: its frame and those of its tail calls.
fn runEntered(state: *runtime.State, function: runtime.Function, argument_count: usize, diagnostic: *?Diagnostic, succeeded: *bool) align(64) Error!usize {
    if (state.vm_entries == 0) state.hook_remaining = state.hook_interval;
    state.vm_entries += 1;
    defer state.vm_entries -= 1;
    var current = function.closure;
    var count = argument_count;
    var prepared: ?*runtime.Table = null;
    // Inlined, as the compiler chose before a resumed frame became runFrame's
    // second user: called, a script call took about 9% more cycles.
    while (true) switch (try @call(.always_inline, runFrame, .{ state, current, count, prepared, diagnostic })) {
        .results => |results| {
            succeeded.* = true;
            return results;
        },
        .tail => |tail| {
            current = tail.closure;
            count = tail.arguments;
            prepared = tail.prepared;
        },
    };
}

const Outcome = union(enum) { results: usize, tail: struct { closure: *runtime.Closure, arguments: usize, prepared: ?*runtime.Table } };

/// Runs a resumed coroutine from its innermost frame outward: each frame
/// completes the instruction it was waiting on with its callee's results, the
/// last `count` slots of the stack, and runs on; its results then answer the
/// frame below, down to the coroutine's first function (ADR 0013).
pub fn continueThread(state: *runtime.State, count: usize, diagnostic: *?Diagnostic) Error!usize {
    return continueAbove(state, 0, count, diagnostic);
}

/// Continues the frames above `floor`, innermost first. A C function waiting
/// on a protected call it made with `nilu_pcallk` is a boundary: the frames
/// above it run under that call's protection, and then its continuation runs
/// in its place (ADR 0013). The outermost such function above `floor` is
/// taken first, so that its protection is in place before anything above it,
/// a continuation further in included, runs again.
fn continueAbove(state: *runtime.State, floor: usize, count: usize, diagnostic: *?Diagnostic) Error!usize {
    var results = count;
    while (state.frames.items.len > floor) {
        const top = state.frames.items.len - 1;
        if (state.frames.items[top].protected_call) {
            // A `pcall` whose callee returned: `true` and its results.
            state.stack.items[state.frames.items[top].base] = .from(.{ .boolean = true });
            state.frames.items.len = top;
            state.frameCountChanged();
            state.has_last_call_location = false;
            results += 1;
            continue;
        }
        results = (if (outermostWaiting(state, floor)) |record|
            continueProtected(state, record, results, diagnostic)
        else
            continueFrame(state, top, results, diagnostic)) catch |err| {
            if (err == error.Yield or !catchable(err)) return err;
            const index = protectedIndex(state, floor + 1) orelse return err;
            try catchProtected(state, index, err, diagnostic);
            diagnostic.* = null;
            results = 2;
            continue;
        };
    }
    return results;
}

/// The outermost C function at or above `floor` waiting on a protected call;
/// `continuations` is kept in frame order.
fn outermostWaiting(state: *const runtime.State, floor: usize) ?runtime.Continuation {
    for (state.continuations.items) |record| if (record.frame >= floor) return record;
    return null;
}

/// Runs the frames above the C function `record` names under the protection
/// its nilu_pcallk gave, ends that call as nilu_pcall would have, and runs
/// the C function's continuation in its frame with the status. The frames
/// above have `count` results waiting to be returned.
fn continueProtected(state: *runtime.State, record: runtime.Continuation, count: usize, diagnostic: *?Diagnostic) Error!usize {
    const transport = @import("failure_transport.zig");
    const Status = @import("c_api.zig").Status;
    const token = try state.reserveFailureOrigin();
    var published = false;
    defer if (!published) state.releaseFailureOrigin(token);
    var status = Status.ok;
    {
        var protection = execution.Protection{ .handler = record.handler };
        var context = execution.Context{ .window = .{ .base = record.base, .frames = record.frame + 1 }, .reserved_origin = token, .protection = &protection };
        context.enter(state);
        var captured = false;
        defer context.leave(state, captured);
        if (continueAbove(state, record.frame + 1, count, diagnostic)) |produced| {
            _ = transport.adjustResults(state, record.base, record.results, produced);
        } else |err| {
            // Still waiting: a yield above it leaves the record in place.
            if (err == error.Yield) return err;
            const failure_record = try transport.catchFailure(state, context.window, null, err, true);
            state.barrier(&token.header);
            token.record = failure_record;
            try runtime.growStack(&state.stack, state.open_cells.items, state.allocator, state.stack.items.len + 1);
            state.stack.appendAssumeCapacity(failure_record.value);
            // As nilu_pcall: the host's interruption keeps its origin and passes on.
            if (failure_record.kind == .interrupted) {
                state.publishFailureOrigin(token);
                published = true;
                state.setOrigin(record.base, token);
            } else state.setOrigin(record.base, null);
            status = switch (failure_record.kind) {
                .runtime_error => .runtime,
                .type_error => .type,
                .call_depth => .call_depth,
                .stack_limit => .stack,
                .out_of_memory => .memory,
                .interrupted => .interrupted,
                .invalid_native_result, .invalid_bytecode, .pending_feature => return error.InvalidBytecode,
            };
        }
        captured = status != .interrupted;
        state.has_last_call_location = false;
    }
    // Every continuation further in has run and gone, so this one is last.
    std.debug.assert(state.continuations.items[state.continuations.items.len - 1].frame == record.frame);
    _ = state.continuations.pop();
    const frame = state.frames.items[record.frame];
    const window = execution.Window{ .base = frame.base, .frames = record.frame };
    var context: execution.Context = undefined;
    context.begin(window);
    context.enter(state);
    var succeeded = false;
    defer context.leave(state, succeeded);
    state.vm_entries += 1;
    defer state.vm_entries -= 1;
    const results = try native.finish(state, window, record.k(state, @backingInt(status), record.context));
    succeeded = true;
    return results;
}

/// One frame of `continueThread`, entered as `runFunctionWithSite` enters a
/// new one: its own execution entry, and its window rolled back on failure.
fn continueFrame(state: *runtime.State, index: usize, count: usize, diagnostic: *?Diagnostic) Error!usize {
    if (diagnostic.* != null) diagnostic.* = null;
    const frame = state.frames.items[index];
    if (frame.function != .closure) return error.InvalidBytecode;
    const closure = frame.function.closure;
    const instruction = frame.instruction orelse return error.InvalidBytecode;
    const window = execution.Window{ .base = frame.base, .frames = index };
    var context: execution.Context = undefined;
    context.begin(window);
    context.enter(state);
    var succeeded = false;
    defer context.leave(state, succeeded);
    state.vm_entries += 1;
    defer state.vm_entries -= 1;
    errdefer window.rollback(state);
    const results = continueWaiting(state, closure, index, instruction, count, diagnostic) catch |err| {
        if (err == error.Yield) return err;
        if (state.failure == null or state.failure.?.kind != failureKind(err)) state.failure = .{
            .kind = failureKind(err),
            .value = if (err == error.OutOfMemory) .from(.{ .string = state.memory_failure }) else .nil,
            .origin = .vm,
            .needs_message = err == error.CallDepth,
        };
        return err;
    };
    succeeded = true;
    return results;
}

fn continueWaiting(state: *runtime.State, closure: *runtime.Closure, index: usize, instruction: *const bytecode.Instruction, count: usize, diagnostic: *?Diagnostic) Error!usize {
    const prototype = closure.prototype;
    const original_top = state.frames.items[index].base;
    const offset = @intFromPtr(instruction) -% @intFromPtr(prototype.code.ptr);
    if (offset % @sizeOf(bytecode.Instruction) != 0 or offset / @sizeOf(bytecode.Instruction) >= prototype.code.len) return error.InvalidBytecode;
    const next = offset / @sizeOf(bytecode.Instruction) + 1;
    var outcome: Outcome = switch (instruction.operation) {
        .call => |op| try runFrameIn(.resumed, state, closure, 0, null, .{ .frame_index = index, .start = next, .open_first = try completeCall(state, prototype, original_top, instruction, op.base, op.resultCount(), op.target, count, diagnostic) }, diagnostic),
        .generic_call => |op| blk: {
            _ = try completeCall(state, prototype, original_top, instruction, op.base + 2, op.count, null, count, diagnostic);
            break :blk try runFrameIn(.resumed, state, closure, 0, null, .{ .frame_index = index, .start = next, .open_first = null }, diagnostic);
        },
        .tail_call => |op| blk: {
            _ = try completeCall(state, prototype, original_top, instruction, op.base, null, null, count, diagnostic);
            break :blk endNativeTail(state, original_top, op.base);
        },
        // A metamethod the instruction was running has returned: the
        // instruction finishes as it would have with that value.
        .get => |op| blk: {
            state.stack.items[original_top + op.destination] = handlerResult(state, count);
            break :blk try runFrameIn(.resumed, state, closure, 0, null, .{ .frame_index = index, .start = next, .open_first = null }, diagnostic);
        },
        .set => blk: {
            _ = handlerResult(state, count);
            break :blk try runFrameIn(.resumed, state, closure, 0, null, .{ .frame_index = index, .start = next, .open_first = null }, diagnostic);
        },
        .unary => |op| blk: {
            state.stack.items[original_top + op.register] = handlerResult(state, count);
            break :blk try runFrameIn(.resumed, state, closure, 0, null, .{ .frame_index = index, .start = next, .open_first = null }, diagnostic);
        },
        .compare_branch => |op| blk: {
            const value = handlerResult(state, count);
            const answer = switch (op.operator) {
                .not_equal => !value.truthy(),
                else => value.truthy(),
            };
            break :blk try runFrameIn(.resumed, state, closure, 0, null, .{ .frame_index = index, .start = if (answer == op.when) op.target else next, .open_first = null }, diagnostic);
        },
        .binary => |op| blk: {
            const value = handlerResult(state, count);
            state.stack.items[original_top + op.destination] = switch (op.operator) {
                .equal, .less, .less_equal, .greater, .greater_equal => .fromBoolean(value.truthy()),
                .not_equal => .fromBoolean(!value.truthy()),
                else => value,
            };
            break :blk try runFrameIn(.resumed, state, closure, 0, null, .{ .frame_index = index, .start = next, .open_first = null }, diagnostic);
        },
        // A `__close` that yielded has returned: the instruction runs again
        // and closes what is left.
        .scope_exit => blk: {
            _ = handlerResult(state, count);
            break :blk try runFrameIn(.resumed, state, closure, 0, null, .{ .frame_index = index, .start = next - 1, .open_first = null }, diagnostic);
        },
        .returns => |op| blk: {
            _ = handlerResult(state, count);
            break :blk try runFrameIn(.resumed, state, closure, 0, null, .{ .frame_index = index, .start = next - 1, .open_first = if (op.count == null) op.first else null }, diagnostic);
        },
        // Nothing else waits on a callee (`invokeHandler` counts the rest as
        // boundaries); a frame that does is malformed.
        else => return error.InvalidBytecode,
    };
    // A tail call made after resuming runs on as `runEntered` runs one.
    while (true) switch (outcome) {
        .results => |results| return results,
        .tail => |tail| outcome = try runFrame(state, tail.closure, tail.arguments, tail.prepared, diagnostic),
    };
}

// The arms below run rarely or allocate; kept out of `runFrame` so its hot
// arms get the registers to themselves.
noinline fn makeClosure(state: *runtime.State, prototype: *const runtime.Prototype, closure: *runtime.Closure, original_top: usize, registers: []Value, instruction: *const bytecode.Instruction, op: @FieldType(bytecode.Instruction.Operation, "closure"), diagnostic: *?Diagnostic) Error!void {
    const child = prototype.children[op.child];
    // The cells go straight into the closure's own array.
    const made = state.reserveClosure(child, child.captures.len) catch |err| return failure(state, prototype, instruction, diagnostic, err);
    var owned = false;
    defer if (!owned) state.dropClosure(made);
    for (child.captures, made.upvalues) |capture, *cell| cell.* = switch (capture) {
        .local => |slot| blk: {
            if (slot >= registers.len) return failure(state, prototype, instruction, diagnostic, error.InvalidBytecode);
            break :blk state.capture(original_top + slot) catch |err| return failure(state, prototype, instruction, diagnostic, switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidIndex => error.InvalidBytecode,
            });
        },
        .upvalue => |slot| closure.upvalues[slot],
    };
    state.ownClosure(made);
    owned = true;
    registers[op.destination] = .fromFunction(.{ .closure = made });
}

noinline fn initGlobal(state: *runtime.State, prototype: *const runtime.Prototype, original_top: usize, registers: []Value, instruction: *const bytecode.Instruction, op: @FieldType(bytecode.Instruction.Operation, "init_global"), diagnostic: *?Diagnostic) Error!void {
    const previous = get(state, instruction, registers[op.environment], registers[op.key], diagnostic) catch |err| return failure(state, prototype, instruction, diagnostic, err);
    if (!previous.is(.nil)) {
        diagnostic.* = .{ .kind = .global_already_defined, .position = instruction.info.position, .operation = .init_global, .subject = instruction.info.names.subject };
        return failure(state, prototype, instruction, diagnostic, error.Runtime);
    }
    set(state, instruction, state.stack.items[original_top + op.environment], state.stack.items[original_top + op.key], state.stack.items[original_top + op.value], diagnostic) catch |err| return failure(state, prototype, instruction, diagnostic, err);
}

noinline fn tailCall(state: *runtime.State, prototype: *const runtime.Prototype, original_top: usize, registers: []Value, instruction: *const bytecode.Instruction, op: @FieldType(bytecode.Instruction.Operation, "tail_call"), previous_open: ?usize, diagnostic: *?Diagnostic) Error!Outcome {
    if (op.arguments == null and (previous_open == null or previous_open.? < op.base + 1)) return failure(state, prototype, instruction, diagnostic, error.InvalidBytecode);
    // Resolution may grow the stack, so the frame is re-read
    // from the state below instead of the registers slice.
    const arguments = op.arguments orelse registers.len - op.base - 1;
    const callee = registers[op.base];
    const prepared_call: PreparedCall = if (callee.asFunction()) |function|
        .{ .function = function, .arguments = arguments, .site = if (function == .closure) null else .{ .prototype = prototype, .instruction = instruction, .through_call = false } }
    else
        resolveCallable(state, original_top, instruction, op.base, arguments, prototype, diagnostic) catch |err| return failure(state, prototype, instruction, diagnostic, err);
    const count = prepared_call.arguments;
    if (prepared_call.function != .closure) {
        // A native tail target keeps the script frame while the
        // callback runs, including its callee slot and captures.
        if (state.frames.items.len >= state.callLimit()) return failure(state, prototype, instruction, diagnostic, error.CallDepth);
        // Its results go straight into the slot that held it, from which
        // they replace the frame.
        state.setLength(original_top + op.base + 1 + count) catch |err| return failure(state, prototype, instruction, diagnostic, stackError(err));
        _ = runNative(state, prepared_call.function, count, diagnostic, prepared_call.site, .callee) catch |err| return failure(state, prototype, instruction, diagnostic, err);
        return endNativeTail(state, original_top, op.base);
    }
    const next = prepared_call.function.closure;
    if (next.upvalues.len != next.prototype.upvalue_count) return failure(state, prototype, instruction, diagnostic, error.InvalidBytecode);
    if (!next.prototype.validated) {
        validate(next.prototype) catch |err| return failure(state, prototype, instruction, diagnostic, err);
        bytecode.assignDispatch(next.prototype.code);
        assignArms(next.prototype.code, next.prototype.constants);
        assignFieldCaches(state.allocator, next.prototype) catch |err| return failure(state, prototype, instruction, diagnostic, err);
        assignTemplates(state.allocator, next.prototype) catch |err| return failure(state, prototype, instruction, diagnostic, err);
        next.prototype.validated = true;
    }
    if (next.prototype.registers > runtime.State.max_stack - original_top) return failure(state, prototype, instruction, diagnostic, error.StackLimit);
    // Prepare every allocation while the current frame and all its
    // arguments are roots; replacing the frame then cannot allocate.
    const table = if (next.prototype.vararg) packArguments(state, state.stack.items[original_top + op.base + 1 + @min(count, next.prototype.parameters) ..][0 .. count - @min(count, next.prototype.parameters)]) catch |err| return failure(state, prototype, instruction, diagnostic, err) else null;
    runtime.growStack(&state.stack, state.open_cells.items, state.allocator, original_top + next.prototype.registers) catch |err| return failure(state, prototype, instruction, diagnostic, err);
    state.closeFrom(original_top);
    std.mem.copyForwards(Value, state.stack.items[original_top..][0..count], state.stack.items[original_top + op.base + 1 ..][0..count]);
    runtime.cutStack(&state.stack, original_top + count);
    _ = state.popFrame();
    return .{ .tail = .{ .closure = next, .arguments = count, .prepared = table } };
}

/// A metamethod that `invokeHandler` ran has returned `count` results, the
/// last slots of the stack, after its slot: its first result, and the stack
/// as it was before the call, as `invokeHandler` leaves them.
fn handlerResult(state: *runtime.State, count: usize) Value {
    const base = state.stack.items.len - count - 1;
    const value = if (count == 0) Value.nil else state.stack.items[base + 1];
    state.closeFrom(base);
    runtime.cutStack(&state.stack, base);
    return value;
}

/// `local x <close> = v`: v must be nil, false or have `__close`; it is
/// remembered to be closed when its scope ends (manual 3.1).
noinline fn toBeClosed(state: *runtime.State, prototype: *const runtime.Prototype, original_top: usize, registers: []Value, instruction: *const bytecode.Instruction, diagnostic: *?Diagnostic) Error!void {
    const op = instruction.operation.to_be_closed;
    const value = registers[op.register];
    if (!value.truthy()) return;
    const method = metamethod(state, value, "__close", instruction, diagnostic) catch |err| return failure(state, prototype, instruction, diagnostic, err);
    if (method.is(.nil)) {
        diagnostic.* = .{ .kind = .non_closable, .position = instruction.info.position, .operation = .to_be_closed, .subject = instruction.info.names.subject };
        return failure(state, prototype, instruction, diagnostic, error.Runtime);
    }
    state.closing.append(state.allocator, .{ .slot = original_top + op.level, .value = value }) catch |err| return failure(state, prototype, instruction, diagnostic, err);
}

/// Closes the to-be-closed variables at or above `level`, innermost first:
/// each value's `__close(value, nil)`, looked up now. A yield inside one is
/// resumed into the same instruction, which then closes the rest.
noinline fn closeScope(state: *runtime.State, prototype: *const runtime.Prototype, instruction: *const bytecode.Instruction, level: usize, diagnostic: *?Diagnostic) Error!void {
    while (state.closing.getLastOrNull()) |entry| {
        if (entry.slot < level) return;
        _ = state.closing.pop();
        const method = metamethod(state, entry.value, "__close", instruction, diagnostic) catch |err| return failure(state, prototype, instruction, diagnostic, err);
        _ = invokeHandler(state, instruction, method, "__close", &.{ entry.value, .nil }, diagnostic) catch |err| return failure(state, prototype, instruction, diagnostic, err);
    }
}

/// A failure unwinding past to-be-closed variables at or above `level`
/// closes them, innermost first, after any handler has run: each gets the
/// failure's value, and a `__close` that fails puts its own value in that
/// failure's place for the next and for the catcher, as in Lua. Each runs as
/// a protected call, so a yield there is refused. Called by
/// `Window.rollback`.
pub fn closeOnFailure(state: *runtime.State, level: usize) void {
    while (state.closing.getLastOrNull()) |entry| {
        if (entry.slot < level) return;
        _ = state.closing.pop();
        const carried = state.failure;
        // The host's interruption stops the program; nothing more runs.
        if (carried) |record| if (record.kind == .interrupted) continue;
        const method = metafield(state, entry.value, "__close") catch Value.nil;
        runtime.growStack(&state.stack, state.open_cells.items, state.allocator, state.stack.items.len + 3) catch continue;
        state.stack.appendAssumeCapacity(method);
        state.stack.appendAssumeCapacity(entry.value);
        state.stack.appendAssumeCapacity(if (carried) |record| record.value else .nil);
        var diagnostic: ?Diagnostic = null;
        const result = @import("failure_transport.zig").callAdjusted(state, 2, 0, true, null, &diagnostic) catch {
            state.failure = carried;
            continue;
        };
        var replaced = carried;
        switch (result) {
            .success => {},
            .failure => |kind| {
                const value = state.stack.pop() orelse Value.nil;
                // The hook stopped this `__close`: the program stops, and the
                // interruption, not the failure being closed for, goes on.
                if (kind == .interrupted) {
                    state.failure = .{ .kind = .interrupted, .value = .nil, .origin = .native };
                    continue;
                }
                if (replaced) |*record| {
                    record.value = value;
                    record.needs_message = false;
                    record.handled = true;
                } else replaced = .{ .kind = .runtime_error, .value = value, .origin = .native };
            },
        }
        state.failure = replaced;
    }
}

/// A native tail target has returned: its results replace the frame.
fn endNativeTail(state: *runtime.State, original_top: usize, base: usize) Outcome {
    const result_count = state.stack.items.len - original_top - base;
    state.closeFrom(original_top);
    std.mem.copyForwards(Value, state.stack.items[original_top..][0..result_count], state.stack.items[original_top + base ..]);
    runtime.cutStack(&state.stack, original_top + result_count);
    _ = state.popFrame();
    return .{ .results = result_count };
}

/// The largest `n` a vararg table may hold: Lua 5.5's INT_MAX / 2, measured
/// with lua5.5 as the last count that is not "no proper 'n'".
const max_vararg_count: i64 = std.math.maxInt(i32) / 2;

noinline fn varargs(state: *runtime.State, prototype: *const runtime.Prototype, original_top: usize, registers: []Value, instruction: *const bytecode.Instruction, op: @FieldType(bytecode.Instruction.Operation, "varargs"), diagnostic: *?Diagnostic) Error!?usize {
    if (prototype.parameters >= registers.len) return failure(state, prototype, instruction, diagnostic, error.InvalidBytecode);
    const table = registers[prototype.parameters];
    if (!table.is(.table)) return failure(state, prototype, instruction, diagnostic, error.InvalidBytecode);
    // `...name` hands the table to the program, which can change `n`: as in
    // Lua 5.5, `...` reads this call's table as it is now, and an `n` that is
    // not an integer from 0 to Lua's bound (INT_MAX / 2) is the program's
    // runtime error; a float, even a whole one, is not (lua5.5 refuses 2.0).
    const count_value = table.unpack().table.getString("n");
    if (!count_value.is(.integer) or count_value.asInteger() < 0 or count_value.asInteger() > max_vararg_count) {
        diagnostic.* = .{ .kind = .vararg_count, .position = instruction.info.position, .operation = .varargs };
        return failure(state, prototype, instruction, diagnostic, error.Runtime);
    }
    // Past the stack, an open count fails below as a stack overflow; a fixed
    // count reads only its own slots.
    const available: usize = if (count_value.asInteger() > runtime.State.max_stack) runtime.State.max_stack + 1 else @intCast(count_value.asInteger());
    const count = op.count orelse available;
    if (count > runtime.State.max_stack - original_top - op.first) {
        // More values than the stack holds, however `n` came to be: Lua's
        // `stack overflow`, the owner's answer.
        diagnostic.* = .{ .kind = .call_depth, .position = instruction.info.position, .operation = .varargs };
        return failure(state, prototype, instruction, diagnostic, error.Runtime);
    }
    if (op.count == null) {
        state.setLength(original_top + op.first + count) catch |err| return failure(state, prototype, instruction, diagnostic, stackError(err));
    }
    const output = state.stack.items[original_top + op.first ..][0..count];
    for (output, 0..) |*slot, i| slot.* = if (i < available) table.unpack().table.get(runtime.Value.fromCount(i + 1)) else .nil;
    // An open count leaves the produced values open for the next instruction.
    return if (op.count == null) op.first else null;
}

noinline fn setList(state: *runtime.State, prototype: *const runtime.Prototype, original_top: usize, registers: []Value, instruction: *const bytecode.Instruction, op: @FieldType(bytecode.Instruction.Operation, "set_list"), previous_open: ?usize, diagnostic: *?Diagnostic) Error!void {
    if (previous_open != op.first) return failure(state, prototype, instruction, diagnostic, error.InvalidBytecode);
    const count = registers.len - op.first;
    if (count > max_list_index - op.index + 1) return failure(state, prototype, instruction, diagnostic, error.InvalidBytecode);
    for (0..count) |i| {
        const receiver = state.stack.items[original_top + op.table];
        const value = state.stack.items[original_top + op.first + i];
        set(state, instruction, receiver, runtime.Value.fromCount(op.index + i), value, diagnostic) catch |err| return failure(state, prototype, instruction, diagnostic, err);
    }
    state.closeFrom(original_top + op.first);
    state.extendRegisters(original_top + prototype.registers) catch |err| return failure(state, prototype, instruction, diagnostic, stackError(err));
}

/// A binary operator whose operands are not two numbers, or whose operator
/// the arm does not compute: the general rule, metamethods included.
noinline fn binarySlow(state: *runtime.State, prototype: *const runtime.Prototype, original_top: usize, registers: []Value, instruction: *const bytecode.Instruction, op: *const @FieldType(bytecode.Instruction.Operation, "binary"), diagnostic: *?Diagnostic) Error!void {
    const left = registers[op.left];
    const right = if (op.right_constant) prototype.constants[op.right] else registers[op.right];
    // A handler may have moved the stack: write through the state.
    const value = binary(state, instruction, left, right, diagnostic) catch |err| return failure(state, prototype, instruction, diagnostic, err);
    state.stack.items[original_top + op.destination] = value;
}

/// A constant string key's slot in `table`: the one the cache holds while the
/// table and its hash part are the same, else a lookup that refills it.
/// Out of line, so the frame loop's arms stay small.
noinline fn cachedSlot(cache: *runtime.FieldCache, table: *runtime.Table, key: Value) ?*Value {
    if (table.cachedField(cache)) |slot| return slot;
    return table.refreshCache(cache, key);
}

/// Gives each `get`/`set` whose key is a constant string a field cache of
/// its own. Runs once, after validation; the caches belong to the prototype.
fn assignFieldCaches(allocator: std.mem.Allocator, prototype: *runtime.Prototype) error{OutOfMemory}!void {
    var count: u32 = 0;
    for (prototype.code) |instruction| switch (instruction.operation) {
        .get => |op| if (op.key_constant and prototype.constants[op.key].is(.string)) {
            count += 1;
        },
        .set => |op| if (op.key_constant and prototype.constants[op.key].is(.string)) {
            count += 1;
        },
        else => {},
    };
    if (count == 0) return;
    const caches = try allocator.alloc(runtime.FieldCache, count);
    @memset(caches, .{});
    var next: u32 = 0;
    for (prototype.code) |*instruction| switch (instruction.operation) {
        .get => |*op| if (op.key_constant and prototype.constants[op.key].is(.string)) {
            op.cache = next;
            next += 1;
        },
        .set => |*op| if (op.key_constant and prototype.constants[op.key].is(.string)) {
            op.cache = next;
            next += 1;
        },
        else => {},
    };
    prototype.field_caches = caches;
}

/// The constant string keys a constructor stores: the `set`s into the
/// `table` instruction's register that follow it, up to its count of keyed
/// fields, before anything that moves control. A key found there that the
/// constructor did not store is only a key with a nil value, which nothing
/// can tell from an absent one; so the walk needs to be cautious, not exact.
fn templateKeys(prototype: *const runtime.Prototype, at: usize, keys: *std.ArrayList(Value), allocator: std.mem.Allocator) error{OutOfMemory}!void {
    const op = prototype.code[at].operation.table;
    for (prototype.code[at + 1 ..]) |instruction| {
        if (keys.items.len >= op.fields) return;
        switch (instruction.operation) {
            .set => |store| if (!store.table_upvalue and store.table == op.destination) {
                if (!store.key_constant or !prototype.constants[store.key].is(.string)) return;
                try keys.append(allocator, prototype.constants[store.key]);
            },
            .jump, .branch, .compare_branch, .for_prepare, .for_loop, .generic_call, .generic_loop, .returns, .tail_call, .call, .table => return,
            else => {},
        }
    }
}

/// Gives each constructor with constant string keys a template of them
/// (`HashPart.template`). Runs once, after validation, as the field caches do.
fn assignTemplates(allocator: std.mem.Allocator, prototype: *runtime.Prototype) error{OutOfMemory}!void {
    var templates: std.ArrayList(HashPart) = .empty;
    defer templates.deinit(allocator);
    errdefer for (templates.items) |*part| part.deinit(allocator);
    var keys: std.ArrayList(Value) = .empty;
    defer keys.deinit(allocator);
    for (prototype.code, 0..) |instruction, index| {
        if (instruction.operation != .table or instruction.operation.table.fields == 0) continue;
        keys.clearRetainingCapacity();
        try templateKeys(prototype, index, &keys, allocator);
        if (keys.items.len == 0) continue;
        var part = try HashPart.template(allocator, keys.items);
        templates.append(allocator, part) catch |err| {
            part.deinit(allocator);
            return err;
        };
    }
    if (templates.items.len == 0) return;
    const owned = try templates.toOwnedSlice(allocator);
    var next: u32 = 0;
    for (prototype.code, 0..) |*instruction, index| {
        if (instruction.operation != .table or instruction.operation.table.fields == 0) continue;
        keys.clearRetainingCapacity();
        // The walk again, allocating nothing: the keys' room is already had.
        templateKeys(prototype, index, &keys, allocator) catch unreachable;
        if (keys.items.len == 0) continue;
        instruction.operation.table.template = next;
        next += 1;
    }
    prototype.table_templates = owned;
}

fn runFrame(state: *runtime.State, closure: *runtime.Closure, argument_count: usize, prepared: ?*runtime.Table, diagnostic: *?Diagnostic) Error!Outcome {
    return @call(.always_inline, runFrameIn, .{ .fresh, state, closure, argument_count, prepared, {}, diagnostic });
}

/// Where a resumed frame continues: after the instruction it waited on, with
/// that instruction's open results (ADR 0013).
const ResumePoint = struct { frame_index: usize, start: usize, open_first: ?usize };

/// A new frame (`.fresh`), or one a coroutine left that a resume continues
/// (`.resumed`): one frame loop for both. The mode is comptime and the loop
/// stays in this function, so that a new frame's code is what it was before
/// resuming existed: with the loop as a function of its own, even inlined, a
/// script call took up to 1.5 times the cycles.
fn runFrameIn(comptime mode: enum { fresh, resumed }, state: *runtime.State, closure: *runtime.Closure, argument_count: usize, prepared: ?*runtime.Table, resume_point: if (mode == .resumed) ResumePoint else void, diagnostic: *?Diagnostic) Error!Outcome {
    if (diagnostic.* != null) diagnostic.* = null;
    const prototype = closure.prototype;
    const window: execution.Window = if (mode == .resumed) .{ .base = state.frames.items[resume_point.frame_index].base, .frames = resume_point.frame_index } else try enter(false, state, closure, prototype, argument_count, null, prepared, diagnostic);
    const original_top = window.base;
    errdefer window.rollback(state);
    // The frame keeps its index while callees come and go above it.
    const frame_index = if (mode == .resumed) window.frames else state.frames.items.len - 1;
    const open_first: ?usize = if (mode == .resumed) resume_point.open_first else null;
    const pc: usize = if (mode == .resumed) resume_point.start else 0;
    var running: FrameRun = .{ .state = state, .prototype = prototype, .closure = closure, .original_top = original_top, .frame_index = frame_index, .floor = frame_index, .position = &state.frames.items[frame_index].instruction, .register_count = prototype.registers, .diagnostic = diagnostic };
    return switch (start(&running, &prototype.code[pc], state.stack.items[original_top..].ptr, open_first orelse no_open, state)) {
        .done => running.outcome,
        .failed => failedInChain(&running),
    };
}

/// A failure in a run of frames: a `pcall` frame in the run catches it, and
/// the run goes on from that `pcall`'s caller, as often as that happens;
/// otherwise the frames unwind to the floor (ADR 0009).
noinline fn failedInChain(running: *FrameRun) Error!Outcome {
    const state = running.state;
    while (true) {
        const index = protectedIndex(state, running.floor + 1) orelse return unwind(running);
        if (!catchable(running.err)) return unwind(running);
        catchProtected(state, index, running.err, running.diagnostic) catch |err| {
            // Not a failure a `pcall` catches after all: on from its caller.
            running.err = err;
            running.frame_index = index - 1;
            return unwind(running);
        };
        // The caller completes its call with `false` and the value.
        running.frame_index = index - 1;
        const frame = state.frames.items[running.frame_index];
        const closure = frame.function.closure;
        running.closure = closure;
        running.prototype = closure.prototype;
        running.original_top = frame.base;
        running.register_count = closure.prototype.registers;
        running.findPosition();
        running.diagnostic.* = null;
        const instruction = frame.instruction.?;
        const op = &instruction.operation.call;
        const opened = completeCall(state, running.prototype, running.original_top, instruction, op.base, op.resultCount(), op.target, 2, running.diagnostic) catch |err| {
            running.err = err;
            continue;
        };
        switch (start(running, &@as([*]const bytecode.Instruction, @ptrCast(instruction))[1], running.registers().ptr, opened orelse no_open, running.state)) {
            .done => return running.outcome,
            .failed => {},
        }
    }
}

/// The failures a `pcall` catches; an interruption, a yield and the
/// internal refusals pass it.
fn catchable(err: Error) bool {
    return switch (err) {
        error.Type, error.Runtime, error.CallDepth, error.StackLimit, error.OutOfMemory => true,
        else => false,
    };
}

/// The innermost `pcall` frame at or above `lowest`, if any.
fn protectedIndex(state: *const runtime.State, lowest: usize) ?usize {
    var index = state.frames.items.len;
    while (index > lowest) {
        index -= 1;
        if (state.frames.items[index].protected_call) return index;
    }
    return null;
}

/// A failure caught by the `pcall` frame at `index`, as the library's
/// `pcall` catches one: the frames above it unwound, the message completed,
/// a handler not run, its to-be-closed variables closed, and its window
/// dropped. The `pcall` frame goes, and `false` and the failure's value are
/// the stack's last two slots, where the callee was. Answers an error the
/// `pcall` does not catch.
fn catchProtected(state: *runtime.State, index: usize, failed: Error, diagnostic: *?Diagnostic) Error!void {
    var err = failed;
    var level = state.frames.items.len - 1;
    while (level > index) {
        (execution.Window{ .base = state.frames.items[level].base, .frames = level }).rollback(state);
        calleeRecord(state, err);
        level -= 1;
        const frame = state.frames.items[level];
        if (level > index and frame.function == .closure) if (frame.instruction) |instruction| {
            err = failure(state, frame.function.closure.prototype, instruction, diagnostic, err);
        };
    }
    const callee_slot = state.frames.items[index].base;
    const callee = state.stack.items[callee_slot];
    const record = try @import("failure_transport.zig").catchFailure(state, .{ .base = callee_slot, .frames = index + 1 }, if (callee.is(.closure)) callee.unpack().closure.prototype else null, err, true);
    state.frames.items.len = index;
    state.frameCountChanged();
    state.failure = null;
    // `pcall(f)` with no argument had only `f` above the call's slot.
    try runtime.growStack(&state.stack, state.open_cells.items, state.allocator, callee_slot + 2);
    state.stack.items.len = callee_slot + 2;
    state.stack.items[callee_slot] = .from(.{ .boolean = false });
    state.stack.items[callee_slot + 1] = record.value;
    state.has_last_call_location = record.location != null;
    if (record.location) |location| {
        const slot = @min(state.call_location_depth, state.call_locations.items.len - 1);
        state.call_locations.items[slot] = location;
        state.last_call_location_index = slot;
    }
}

/// A failure in a frame the chain entered above its floor leaves each such
/// frame as a host call's failure did: the frame's window rolled back, the
/// record made the callee's, then the caller's `failure` at its call
/// instruction, down to the floor, whose window `runFrameIn` rolls back. A
/// yield keeps every frame for the resume.
fn unwind(running: *FrameRun) Error {
    const state = running.state;
    var err = running.err;
    var level = running.frame_index;
    while (level > running.floor and err != error.Yield) {
        (execution.Window{ .base = state.frames.items[level].base, .frames = level }).rollback(state);
        calleeRecord(state, err);
        level -= 1;
        const frame = state.frames.items[level];
        err = failure(state, frame.function.closure.prototype, frame.instruction.?, running.diagnostic, err);
    }
    return err;
}

/// What `runFunctionWithSite` makes of a script callee's failure.
fn calleeRecord(state: *runtime.State, err: Error) void {
    if (err == error.Yield) return;
    if (state.failure == null or state.failure.?.kind != failureKind(err)) state.failure = .{
        .kind = failureKind(err),
        .value = if (err == error.OutOfMemory) .from(.{ .string = state.memory_failure }) else .nil,
        .origin = .vm,
        .needs_message = err == error.CallDepth,
    };
}

/// Enters a script callee whose arguments are the stack's last `arguments`
/// slots, as `runFrameIn` would, and runs on with its first instruction in
/// the same chain. `running` is its caller, at the call `instruction`.
inline fn enterInChain(running: *FrameRun, instruction: *const bytecode.Instruction, closure: *runtime.Closure, arguments: usize, at: ?usize, prepared: ?*runtime.Table) Exit {
    const state = running.state;
    const prototype = closure.prototype;
    if (running.diagnostic.* != null) running.diagnostic.* = null;
    const window = enter(true, state, closure, prototype, arguments, at, prepared, running.diagnostic) catch |err| {
        calleeRecord(state, err);
        return fail(running, instruction, err);
    };
    running.closure = closure;
    running.prototype = prototype;
    running.original_top = window.base;
    running.frame_index = state.frames.items.len - 1;
    running.register_count = closure.prototype.registers;
    running.findPosition();
    return proceed(running, &closure.prototype.code[0], running.registers().ptr, no_open, state);
}

/// A script's call of the library's `pcall` with a script function: a frame
/// for the `pcall`, as its C function would have had, marked as a boundary,
/// and the callee entered above it in this run of frames (ADR 0009).
inline fn protectedEnter(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value) Exit {
    const state = running.state;
    const op = &instruction.operation.call;
    running.position.* = instruction;
    if (state.frames.items.len >= state.callLimit()) return fail(running, instruction, error.CallDepth);
    if (state.frames.items.len >= state.frames.capacity) return fail(running, instruction, error.CallDepth);
    const slot = running.original_top + op.base;
    state.has_last_call_location = false;
    var frame: runtime.Frame = .native(slot + 1, registers[op.base].asFunction().?, .{ .prototype = running.prototype, .instruction = instruction, .through_call = false });
    frame.protected_call = true;
    state.frames.appendAssumeCapacity(frame);
    state.frame_base = slot + 1;
    // A callee too deep fails inside the `pcall`, which catches it, as the
    // library's `pcall` did.
    if (state.frames.items.len >= state.callLimit()) return raise(running, failureAtHost(state, null, error.CallDepth));
    return enterInChain(running, instruction, registers[op.base + 1].asClosure(), op.arguments.? - 1, slot + 2, null);
}

/// A frame above the floor has returned `count` results, the stack's last
/// slots, and is popped: its caller completes the call and runs on.
inline fn returnInChain(running: *FrameRun, count: usize) Exit {
    const state = running.state;
    running.frame_index -= 1;
    if (state.frames.items[running.frame_index].protected_call) {
        // A `pcall`'s callee returned: `true` takes the callee's slot, just
        // below its results, and the `pcall` frame goes, so the call it
        // stood for completes with `true` and them (ADR 0009).
        state.stack.items[state.frames.items[running.frame_index].base] = .from(.{ .boolean = true });
        state.popFrameInChain();
        state.has_last_call_location = false;
        running.frame_index -= 1;
        return completeInChain(running, count + 1);
    }
    return completeInChain(running, count);
}

/// The caller at `running.frame_index` completes its call with `count`
/// results, the stack's last slots, and runs on.
inline fn completeInChain(running: *FrameRun, count: usize) Exit {
    const state = running.state;
    const frame = state.frames.items[running.frame_index];
    const closure = frame.function.closure;
    running.closure = closure;
    running.prototype = closure.prototype;
    running.original_top = frame.base;
    running.register_count = closure.prototype.registers;
    const instruction = frame.instruction.?;
    const op = &instruction.operation.call;
    const opened = completeCall(state, running.prototype, running.original_top, instruction, op.base, op.resultCount(), op.target, count, running.diagnostic) catch |err| return raise(running, err);
    return followingAfterMove(running, instruction, opened orelse no_open, state);
}

/// One result for a caller whose call wants one, into its local (`x = f()`)
/// or into the call's own slot: `returns`, `returnInChain` and
/// `completeCall` in one pass, the value written once and the slots from the
/// call's up closed once.
inline fn returnIntoTarget(running: *FrameRun, value: Value, caller: *const runtime.Frame, waiting: *const bytecode.Call) Exit {
    const state = running.state;
    const base = caller.base + waiting.base;
    // The callee's frame sits just above the call's slot.
    state.closeFrom(base);
    state.popFrameInChain();
    return deliverOne(running, value, caller, waiting);
}

/// The rest of `returnIntoTarget`, once the callee's frame is gone: the
/// value into the caller's local or the call's slot, and the caller run on.
inline fn deliverOne(running: *FrameRun, value: Value, caller: *const runtime.Frame, waiting: *const bytecode.Call) Exit {
    const state = running.state;
    const instruction = caller.instruction.?;
    const closure = caller.function.closure;
    const base = caller.base + waiting.base;
    if (std.debug.runtime_safety) std.debug.assert(state.frames.items.len == running.frame_index);
    running.frame_index -= 1;
    running.closure = closure;
    running.prototype = closure.prototype;
    running.original_top = caller.base;
    running.register_count = closure.prototype.registers;
    if (waiting.target) |target| {
        runtime.cutStack(&state.stack, base);
        state.stack.items[caller.base + target] = value;
    } else {
        runtime.cutStack(&state.stack, base + 1);
        state.stack.items[base] = value;
    }
    state.extendRegisters(caller.base + closure.prototype.registers) catch |err| return fail(running, instruction, stackError(err));
    return followingAfterMove(running, instruction, no_open, state);
}

/// The caller of the frame at `running`, made the running frame, for a
/// frame that has replaced itself (a tail call above the floor). Below a
/// `pcall` frame it is the `pcall`'s caller, and the replacement enters above
/// the `pcall` frame, which stays (ADR 0009).
fn toCaller(running: *FrameRun) *const bytecode.Instruction {
    const state = running.state;
    running.frame_index -= 1;
    if (state.frames.items[running.frame_index].protected_call) running.frame_index -= 1;
    const frame = state.frames.items[running.frame_index];
    const closure = frame.function.closure;
    running.closure = closure;
    running.prototype = closure.prototype;
    running.original_top = frame.base;
    running.register_count = closure.prototype.registers;
    running.findPosition();
    return frame.instruction.?;
}

/// One frame's run, shared by its arms. Each arm is a function of its own
/// that ends by jumping to the next instruction's arm (`proceed`): in one
/// loop of 35 arms, every edit moved the register allocation of all of them,
/// and a change to one arm cost or saved 10% in loops that never ran it. An
/// arm answers only `done` or `failed`, the outcome or error kept here: a
/// tail call cannot return an error union, which is returned in memory.
const FrameRun = struct {
    state: *runtime.State,
    prototype: *const runtime.Prototype,
    closure: *runtime.Closure,
    original_top: usize,
    frame_index: usize,
    /// The frame `runFrameIn` entered: a script callee is entered and left
    /// within the chain, and only this frame's end answers the host.
    floor: usize,
    /// The frame's `instruction`, written before every instruction. Frames
    /// move only when a call pushes one past the reserve, so it is taken
    /// again after every arm that can call (`followingAfterMove`).
    position: *?*const bytecode.Instruction,
    register_count: usize,
    diagnostic: *?Diagnostic,
    outcome: Outcome = undefined,
    err: Error = undefined,

    fn registers(running: *const FrameRun) []Value {
        const state = running.state;
        return state.stack.items[running.original_top..];
    }

    fn findPosition(running: *FrameRun) void {
        const state = running.state;
        running.position = &state.frames.items[running.frame_index].instruction;
    }
};

const Exit = enum(u8) { done, failed };

/// The operand that left results open at the stack's end, or none.
const no_open = std.math.maxInt(usize);

const Arm = *const @TypeOf(arm_functions.move);

const arms = blk: {
    var table: [@typeInfo(bytecode.Dispatch).@"enum".field_names.len]Arm = undefined;
    for (@typeInfo(bytecode.Dispatch).@"enum".field_names, 0..) |name, index| table[index] = armOf(@field(bytecode.Dispatch, name));
    break :blk table;
};

fn armOf(comptime tag: bytecode.Dispatch) Arm {
    return switch (tag) {
        .add, .subtract, .multiply, .less, .less_equal, .greater, .greater_equal, .equal, .not_equal, .binary_other => BinaryArm(tag).arm,
        .branch_equal, .branch_not_equal, .branch_less, .branch_less_equal, .branch_greater, .branch_greater_equal => CompareBranchArm(tag).arm,
        else => @field(arm_functions, camelName(@tagName(tag))),
    };
}

/// An instruction's name as its arm's: `get_upvalue` is `getUpvalue`.
fn camelName(comptime name: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        var upper = false;
        for (name) |c| {
            if (c == '_') {
                upper = true;
                continue;
            }
            out = out ++ &[_]u8{if (upper) std.ascii.toUpper(c) else c};
            upper = false;
        }
        return out;
    }
}

/// Before every instruction: the frame's position, a collection or hook if
/// one is due, and the operand check for a frame that shrank below its
/// registers; then the instruction's arm.
/// How many registers the frame has now: the stack above its base. The
/// arms pass the registers as a pointer only, so that the length leaves an
/// argument register free; it is read here where it is needed.
inline fn registerCount(running: *const FrameRun, state: *const runtime.State) usize {
    return state.stack.items.len - running.original_top;
}

inline fn proceed(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, open: usize, state: *runtime.State) Exit {
    if (std.debug.runtime_safety) std.debug.assert(registers == state.stack.items.ptr + running.original_top and registerCount(running, state) == state.stack.items.len - running.original_top);
    // Register slots and the active frame are roots before every instruction.
    if (std.debug.runtime_safety) std.debug.assert(running.position == &state.frames.items[running.frame_index].instruction);
    // The frame's position is written only by the arms that can let anything
    // read it (a call, a metamethod, a `__close`, a hook, a failure): on every
    // instruction it was a store in each of the arms that cannot.
    // The rare cases go through an arm of their own, so that an arm whose
    // path makes no call saves no register. A frame below its registers has
    // made the step due too (`noteShort`), so one compare covers all three.
    if (std.debug.runtime_safety) std.debug.assert(registerCount(running, state) >= running.register_count or state.stepDue());
    if (state.stepDue()) return @call(.always_tail, beforeRarely, .{ running, instruction, registers, open, state });
    return @call(.always_tail, armOfInstruction(instruction), .{ running, instruction, registers, open, state });
}

inline fn armOfInstruction(instruction: *const bytecode.Instruction) Arm {
    return @ptrCast(@alignCast(instruction.arm.?));
}

/// Gives each instruction its arm, after `assignDispatch` gave it its tag.
fn assignArms(code: []bytecode.Instruction, constants: []const Value) void {
    for (code) |*instruction| {
        instruction.arm = @ptrCast(arms[@backingInt(instruction.dispatch)]);
        // A constant right operand that is an inline integer (`i + 1`,
        // `n < 2`) stays one, so its arm tests the left operand only.
        // Validation bounded every constant index by the pool's length.
        switch (instruction.dispatch) {
            inline .add, .subtract, .less, .less_equal, .greater, .greater_equal, .equal, .not_equal => |tag| {
                const op = instruction.operation.binary;
                if (op.right_constant and constants[op.right].isInlineInteger()) instruction.arm = @ptrCast(&BinaryArm(tag).constantInteger);
            },
            .set => {
                const op = instruction.operation.set;
                if (!op.key_constant and !op.table_upvalue) instruction.arm = @ptrCast(&arm_functions.setIndexed);
            },
            .get => {
                const op = instruction.operation.get;
                if (!op.key_constant and !op.table_upvalue) instruction.arm = @ptrCast(&arm_functions.getIndexed);
            },
            inline .branch_equal, .branch_not_equal, .branch_less, .branch_less_equal, .branch_greater, .branch_greater_equal => |tag| {
                const op = instruction.operation.compare_branch;
                if (op.right_constant and constants[op.right].isInlineInteger()) instruction.arm = @ptrCast(&CompareBranchArm(tag).constantInteger);
            },
            else => {},
        }
        // Validation bounded every target by the code's length.
        switch (instruction.operation) {
            .for_prepare, .generic_loop => |*op| op.to = &code[op.target],
            .for_loop => |*op| {
                op.to = &code[op.target];
                if (!op.captures) instruction.arm = @ptrCast(&arm_functions.forLoopUncaptured);
            },
            inline .branch, .jump, .compare_branch => |*op| op.to = &code[op.target],
            else => {},
        }
    }
}

/// A collection or hook due (one compare covers both), or a frame that
/// shrank below its registers: validation bounded every operand by the
/// prototype's register count, so only then is the operand check repeated.
noinline fn beforeRarely(running: *FrameRun, instruction: *const bytecode.Instruction, registers_in: [*]Value, open: usize, state: *runtime.State) align(arm_alignment) Exit {
    @branchHint(.cold);
    var registers = registers_in;
    if (state.stepDue()) {
        // A hook reads where the frame is.
        running.position.* = instruction;
        if (stepDue(state)) {
            state.interrupted = true;
            return fail(running, instruction, error.Interrupted);
        }
        registers = running.registers().ptr;
        running.findPosition();
    }
    if (registerCount(running, state) < running.prototype.registers) {
        if (!validRegisters(instruction.operation, registerCount(running, state))) return fail(running, instruction, error.InvalidBytecode);
        // Still short (a collection above may have reset the step).
        state.setStepThreshold(0);
    } else if (state.step_threshold == 0) state.updateStepThreshold();
    return @call(.always_tail, armOfInstruction(instruction), .{ running, instruction, registers, open, state });
}

/// The frame's first instruction: an ordinary call, from which the arms
/// jump to each other until one answers.
noinline fn start(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, open: usize, state: *runtime.State) align(start_alignment) linksection(arm_section) Exit {
    noteShort(running);
    return proceed(running, instruction, registers, open, state);
}

/// A collection, then the hook; answers whether the hook interrupted.
noinline fn stepDue(state: *runtime.State) bool {
    if (state.shouldCollect()) state.collectStep();
    if (state.hook != null) return state.hookStep();
    return false;
}

inline fn following(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, state: *runtime.State) Exit {
    return proceed(running, &@as([*]const bytecode.Instruction, @ptrCast(instruction))[1], registers, no_open, state);
}

/// A jump through the target instruction `assignArms` stored.
inline fn jumpVia(running: *FrameRun, to: ?*const anyopaque, registers: [*]Value, state: *runtime.State) Exit {
    return proceed(running, @ptrCast(@alignCast(to.?)), registers, no_open, state);
}

inline fn jumpTo(running: *FrameRun, target: usize, registers: [*]Value) Exit {
    const state = running.state;
    return proceed(running, &running.prototype.code[target], registers, no_open, state);
}

/// A jump after an arm that can move or resize the stack.
inline fn jumpAfterMove(running: *FrameRun, to: ?*const anyopaque, state: *runtime.State) Exit {
    running.findPosition();
    const registers = running.registers();
    noteShort(running);
    return proceed(running, @ptrCast(@alignCast(to.?)), registers.ptr, no_open, state);
}

/// After an arm that can move or resize the stack.
inline fn followingAfterMove(running: *FrameRun, instruction: *const bytecode.Instruction, open: usize, state: *runtime.State) Exit {
    running.findPosition();
    const registers = running.registers();
    noteShort(running);
    return proceed(running, &@as([*]const bytecode.Instruction, @ptrCast(instruction))[1], registers.ptr, open, state);
}

/// A frame below its registers (open results left it so) needs the operand
/// check on every instruction until it is whole again: the step is made due
/// so that the head takes `beforeRarely`, which does it.
inline fn noteShort(running: *FrameRun) void {
    const state = running.state;
    if (registerCount(running, state) < running.register_count) state.setStepThreshold(0);
}

/// A failure first met here, made into the frame's failure.
noinline fn fail(running: *FrameRun, instruction: *const bytecode.Instruction, err: Error) align(arm_alignment) Exit {
    @branchHint(.cold);
    const state = running.state;
    // A handler run at the raise reads where the frame is. A call made by
    // this instruction may have moved the frames, so the slot is taken again.
    running.findPosition();
    running.position.* = instruction;
    running.err = failure(state, running.prototype, instruction, running.diagnostic, err);
    return .failed;
}

/// A failure a helper has already made the frame's.
fn raise(running: *FrameRun, err: Error) Exit {
    @branchHint(.cold);
    running.err = err;
    return .failed;
}

fn openOf(open: usize) ?usize {
    return if (open == no_open) null else open;
}

fn BinaryArm(comptime tag: bytecode.Dispatch) type {
    return struct {
        // One arm per operator, made at compile time, so an instruction
        // dispatches once; through one binary arm the operator was a second
        // jump table.
        noinline fn arm(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, open: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
            const op = &instruction.operation.binary;
            integer: {
                const left_value = registers[op.left];
                const right_value = if (op.right_constant) running.prototype.constants[op.right] else registers[op.right];
                if (!Value.allInlineIntegers(.{ left_value, right_value })) break :integer;
                const destination = &registers[op.destination];
                // A sum, a difference and an order come from the bits alone.
                switch (tag) {
                    .add => {
                        destination.* = Value.inlineSum(left_value, right_value) orelse break :integer;
                        return following(running, instruction, registers, state);
                    },
                    .subtract => {
                        destination.* = Value.inlineDifference(left_value, right_value) orelse break :integer;
                        return following(running, instruction, registers, state);
                    },
                    .less, .less_equal, .greater, .greater_equal, .equal, .not_equal => {
                        destination.* = .fromBoolean(switch (tag) {
                            .less => Value.inlineLess(left_value, right_value),
                            .less_equal => !Value.inlineLess(right_value, left_value),
                            .greater => Value.inlineLess(right_value, left_value),
                            .greater_equal => !Value.inlineLess(left_value, right_value),
                            .equal => left_value.bits == right_value.bits,
                            .not_equal => left_value.bits != right_value.bits,
                            else => unreachable,
                        });
                        return following(running, instruction, registers, state);
                    },
                    else => {},
                }
                const x = left_value.asInlineInteger();
                const y = right_value.asInlineInteger();
                const result: i64 = switch (tag) {
                    .multiply => blk: {
                        const product = @mulWithOverflow(x, y);
                        if (product[1] != 0) break :integer;
                        break :blk product[0];
                    },
                    .binary_other => switch (op.operator) {
                        .floor_divide => if (y == 0) break :integer else arithmetic.floorDivide(x, y),
                        .modulo => if (y == 0) break :integer else arithmetic.modulo(x, y),
                        .bitwise_and, .bitwise_or, .bitwise_xor, .shift_left, .shift_right => arithmetic.bitwise(op.operator, x, y),
                        else => break :integer,
                    },
                    else => break :integer,
                };
                destination.* = Value.inlineInteger(result) orelse break :integer;
                return following(running, instruction, registers, state);
            }
            return @call(.always_tail, floats, .{ running, instruction, registers, open, state });
        }

        /// The arm of an instruction whose right operand is a constant
        /// inline integer (`assignArms`): only the left one is tested.
        noinline fn constantInteger(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, open: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
            const op = &instruction.operation.binary;
            const left_value = registers[op.left];
            if (!left_value.isInlineInteger()) return @call(.always_tail, floats, .{ running, instruction, registers, open, state });
            const right_value = running.prototype.constants[op.right];
            std.debug.assert(right_value.isInlineInteger());
            const destination = &registers[op.destination];
            destination.* = switch (tag) {
                .add => Value.inlineSum(left_value, right_value) orelse return @call(.always_tail, floats, .{ running, instruction, registers, open, state }),
                .subtract => Value.inlineDifference(left_value, right_value) orelse return @call(.always_tail, floats, .{ running, instruction, registers, open, state }),
                .less => .fromBoolean(Value.inlineLess(left_value, right_value)),
                .less_equal => .fromBoolean(!Value.inlineLess(right_value, left_value)),
                .greater => .fromBoolean(Value.inlineLess(right_value, left_value)),
                .greater_equal => .fromBoolean(!Value.inlineLess(left_value, right_value)),
                .equal => .fromBoolean(left_value.bits == right_value.bits),
                .not_equal => .fromBoolean(left_value.bits != right_value.bits),
                else => comptime unreachable,
            };
            return following(running, instruction, registers, state);
        }

        /// Two numbers, one of them a float or a boxed integer, apart from
        /// the inline integers so that their arm saves no register.
        noinline fn floats(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, open: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
            const op = &instruction.operation.binary;
            fast: {
                // Read through pointers: a copy of each operand, which the slow
                // path takes by value, was stored to memory before this test.
                const left_slot = &registers[op.left];
                const right_slot: *const Value = if (op.right_constant) &running.prototype.constants[op.right] else &registers[op.right];
                // Two numbers run no handler, so the registers slice is still the stack.
                // The cheap operators are computed here and written straight into the
                // register; `numbers` stays out of line because of `pow` and `modulo`.
                const a = left_slot.numberIn() orelse break :fast;
                const b = right_slot.numberIn() orelse break :fast;
                const destination = &registers[op.destination];
                switch (tag) {
                    .add => destination.storeNumber(a + b),
                    .subtract => destination.storeNumber(a - b),
                    .multiply => destination.storeNumber(a * b),
                    .less => destination.* = .fromBoolean(a < b),
                    .less_equal => destination.* = .fromBoolean(a <= b),
                    .greater => destination.* = .fromBoolean(a > b),
                    .greater_equal => destination.* = .fromBoolean(a >= b),
                    .equal => destination.* = .fromBoolean(a == b),
                    .not_equal => destination.* = .fromBoolean(a != b),
                    else => destination.* = numbers(op.operator, a, b) orelse break :fast,
                }
                return following(running, instruction, registers, state);
            }
            // Two integers the values hold themselves, and a result that one
            // holds too: computed here. Anything else,
            // a division by zero among it, takes `rare`.
            return @call(.always_tail, rare, .{ running, instruction, registers, open, state });
        }

        /// Anything but two numbers the fast path computes.
        noinline fn rare(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, _: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
            running.position.* = instruction;
            binarySlow(state, running.prototype, running.original_top, registers[0..registerCount(running, state)], instruction, &instruction.operation.binary, running.diagnostic) catch |err| return raise(running, err);
            return followingAfterMove(running, instruction, no_open, state);
        }
    };
}

/// A comparison and its branch (`compare_branch`), one arm per operator.
fn CompareBranchArm(comptime tag: bytecode.Dispatch) type {
    return struct {
        noinline fn arm(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, open: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
            const op = &instruction.operation.compare_branch;
            integer: {
                const left_value = registers[op.left];
                const right_value = if (op.right_constant) running.prototype.constants[op.right] else registers[op.right];
                if (!Value.allInlineIntegers(.{ left_value, right_value })) break :integer;
                const answer = switch (tag) {
                    .branch_equal => left_value.bits == right_value.bits,
                    .branch_not_equal => left_value.bits != right_value.bits,
                    .branch_less => Value.inlineLess(left_value, right_value),
                    .branch_less_equal => !Value.inlineLess(right_value, left_value),
                    .branch_greater => Value.inlineLess(right_value, left_value),
                    .branch_greater_equal => !Value.inlineLess(left_value, right_value),
                    else => comptime unreachable,
                };
                if (answer == op.when) return jumpVia(running, op.to, registers, state);
                return following(running, instruction, registers, state);
            }
            return @call(.always_tail, floats, .{ running, instruction, registers, open, state });
        }

        /// The arm of a comparison with a constant inline integer: only the
        /// left operand is tested.
        noinline fn constantInteger(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, open: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
            const op = &instruction.operation.compare_branch;
            const left_value = registers[op.left];
            if (!left_value.isInlineInteger()) return @call(.always_tail, floats, .{ running, instruction, registers, open, state });
            const right_value = running.prototype.constants[op.right];
            std.debug.assert(right_value.isInlineInteger());
            const answer = switch (tag) {
                .branch_equal => left_value.bits == right_value.bits,
                .branch_not_equal => left_value.bits != right_value.bits,
                .branch_less => Value.inlineLess(left_value, right_value),
                .branch_less_equal => !Value.inlineLess(right_value, left_value),
                .branch_greater => Value.inlineLess(right_value, left_value),
                .branch_greater_equal => !Value.inlineLess(left_value, right_value),
                else => comptime unreachable,
            };
            if (answer == op.when) return jumpVia(running, op.to, registers, state);
            return following(running, instruction, registers, state);
        }

        /// Two numbers, one of them a float or a boxed integer, apart from
        /// the inline integers so that their arm saves no register.
        noinline fn floats(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, open: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
            const op = &instruction.operation.compare_branch;
            fast: {
                const right_slot: *const Value = if (op.right_constant) &running.prototype.constants[op.right] else &registers[op.right];
                const a = registers[op.left].numberIn() orelse break :fast;
                const b = right_slot.numberIn() orelse break :fast;
                const answer = switch (tag) {
                    .branch_equal => a == b,
                    .branch_not_equal => a != b,
                    .branch_less => a < b,
                    .branch_less_equal => a <= b,
                    .branch_greater => a > b,
                    .branch_greater_equal => a >= b,
                    else => comptime unreachable,
                };
                if (answer == op.when) return jumpVia(running, op.to, registers, state);
                return following(running, instruction, registers, state);
            }
            return @call(.always_tail, rare, .{ running, instruction, registers, open, state });
        }

        /// Anything but two numbers: the comparison `binary` makes, which
        /// may run a metamethod, and its answer's truth.
        noinline fn rare(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, _: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
            running.position.* = instruction;
            const op = &instruction.operation.compare_branch;
            const right = if (op.right_constant) running.prototype.constants[op.right] else registers[op.right];
            const answer = binaryAs(state, instruction, op.operator, registers[op.left], right, running.diagnostic) catch |err| return raise(running, err);
            if (answer.truthy() == op.when) return jumpAfterMove(running, op.to, state);
            return followingAfterMove(running, instruction, no_open, state);
        }
    };
}

/// A `call` whose callee was of one kind takes that kind's arm directly
/// from then on. Code belongs to one state, which runs on one thread at a
/// time (ADR 0002), so writing it races with nothing.
fn guess(instruction: *const bytecode.Instruction, comptime arm: Arm) void {
    @constCast(instruction).arm = @ptrCast(arm);
}

/// A guessed `call` arm met a callee of another kind, or open arguments
/// it cannot take: the instruction goes back to the general arm, which
/// runs it.
noinline fn unguess(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, open: usize, state: *runtime.State) Exit {
    @constCast(instruction).arm = @ptrCast(&arm_functions.call);
    return @call(.always_tail, arm_functions.call, .{ running, instruction, registers, open, state });
}

/// A C function called from a script's frame with its `arguments` at
/// `base`, the window above the caller's registers: `runNative`, `callInto`
/// and `finishInto` in one pass for one that returns its results, which are
/// then the stack's last `count` slots, its frame gone. Any other answer goes
/// through `finish`, which fails for each of them.
inline fn runNativeHere(running: *FrameRun, instruction: *const bytecode.Instruction, function: runtime.Function, base: usize, arguments: usize) Error!usize {
    const state = running.state;
    if (running.diagnostic.* != null) running.diagnostic.* = null;
    const callback = switch (function) {
        .native => |native_function| native_function,
        .c_closure => |c_closure| c_closure.function,
        .closure => unreachable,
    };
    // The arguments are the stack's last slots (as `callNative`).
    state.clearOriginsFrom(base + arguments);
    runtime.cutStack(&state.stack, base + arguments);
    try state.ensureOrigins(state.stack.items.len);
    const window: execution.Window = .{ .base = base, .frames = state.frames.items.len };
    var context: execution.Context = undefined;
    context.begin(window);
    context.enter(state);
    state.frames.appendAssumeCapacity(.native(base, function, .{ .prototype = running.prototype, .instruction = instruction, .through_call = false }));
    state.frame_base = base;
    state.vm_entries += 1;
    const returned = callback(state);
    state.vm_entries -= 1;
    if (native.answered(state, base, returned)) |count| {
        state.frames.items.len = window.frames;
        state.frame_base = state.frames.items[window.frames - 1].base;
        context.leave(state, true);
        return count;
    }
    // `finish`, not the `.callee` way the general call takes: a second
    // caller of that one changed how a C function's tail call compiled, and
    // `bench/method.nilu` took 14 instructions more a turn.
    _ = native.finish(state, window, returned) catch |err| {
        if (err != error.Yield and (state.failure == null or state.failure.?.kind != failureKind(err))) state.failure = .{
            .kind = failureKind(err),
            .value = if (err == error.OutOfMemory) .from(.{ .string = state.memory_failure }) else .nil,
            .origin = .native,
            .needs_message = err == error.CallDepth,
        };
        context.leave(state, false);
        return err;
    };
    unreachable;
}

const arm_functions = struct {
    // Validation assigns every arm; a prototype run without it is malformed.
    noinline fn unassigned(running: *FrameRun, instruction: *const bytecode.Instruction, _: [*]Value, _: usize, _: *runtime.State) align(arm_alignment) Exit {
        return fail(running, instruction, error.InvalidBytecode);
    }

    noinline fn closure(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, _: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        running.position.* = instruction;
        const op = &instruction.operation.closure;
        makeClosure(state, running.prototype, running.closure, running.original_top, registers[0..registerCount(running, state)], instruction, op.*, running.diagnostic) catch |err| return raise(running, err);
        return following(running, instruction, registers, state);
    }

    noinline fn move(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, _: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        const op = &instruction.operation.move;
        registers[op.destination] = registers[op.source];
        return following(running, instruction, registers, state);
    }

    noinline fn getUpvalue(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, _: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        const op = &instruction.operation.get_upvalue;
        registers[op.destination] = state.readCell(running.closure.upvalues[op.index]);
        return following(running, instruction, registers, state);
    }

    noinline fn setUpvalue(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, _: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        const op = &instruction.operation.set_upvalue;
        state.writeCell(running.closure.upvalues[op.index], registers[op.source]);
        return following(running, instruction, registers, state);
    }

    noinline fn jump(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, _: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        return jumpVia(running, instruction.operation.jump.to, registers, state);
    }

    noinline fn scopeExit(running: *FrameRun, instruction: *const bytecode.Instruction, registers_in: [*]Value, _: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        running.position.* = instruction;
        var registers = registers_in;
        const first = instruction.operation.scope_exit;
        if (state.closing.items.len != 0 and state.closing.items[state.closing.items.len - 1].slot >= running.original_top + first) {
            closeScope(state, running.prototype, instruction, running.original_top + first, running.diagnostic) catch |err| return raise(running, err);
            registers = running.registers().ptr;
        }
        // The registers keep their values (ADR 0005): only cells close.
        state.closeFrom(running.original_top + first);
        return following(running, instruction, registers, state);
    }

    noinline fn toBeClosed(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, _: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        running.position.* = instruction;
        Vm.toBeClosed(state, running.prototype, running.original_top, registers[0..registerCount(running, state)], instruction, running.diagnostic) catch |err| return raise(running, err);
        return followingAfterMove(running, instruction, no_open, state);
    }

    noinline fn forPrepare(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, _: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        const op = &instruction.operation.for_prepare;
        if (@call(.always_inline, Vm.forPrepare, .{ state, instruction, registers[0..registerCount(running, state)], running.diagnostic }) catch |err| return fail(running, instruction, err)) return jumpVia(running, op.to, registers, state);
        return following(running, instruction, registers, state);
    }

    /// The common turn: three numbers, no captured control variable and no
    /// failure origin above it; anything else goes the general way.
    noinline fn forLoop(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, open: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        return @call(.always_inline, forLoopTurn, .{ true, running, instruction, registers, open, state });
    }

    /// A loop whose body holds no function (`NumericFor.captures`): no cell
    /// can be open on its variable, so none is looked for.
    noinline fn forLoopUncaptured(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, open: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        return @call(.always_inline, forLoopTurn, .{ false, running, instruction, registers, open, state });
    }

    inline fn forLoopTurn(comptime captures: bool, running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, open: usize, state: *runtime.State) Exit {
        const op = &instruction.operation.for_loop;
        const base = op.base;
        const slot = running.original_top + base + 2;
        // An integer loop, the usual one (`for i = 1, n`), whose three values
        // the registers hold themselves. A next index no value holds is past
        // the limit, which one does, so the loop ends.
        integer: {
            const index_value = registers[base + 2];
            const limit_value = registers[base];
            const step_value = registers[base + 1];
            if (!Value.allInlineIntegers(.{ index_value, limit_value, step_value })) break :integer;
            if (slot < state.origins_end) break :integer;
            if (captures and state.open_cells.items.len != 0 and state.open_cells.items[state.open_cells.items.len - 1].storage.open >= slot) break :integer;
            if (std.debug.runtime_safety) std.debug.assert(captures or state.open_cells.items.len == 0 or state.open_cells.items[state.open_cells.items.len - 1].storage.open < slot);
            const next = Value.inlineSum(index_value, step_value) orelse return following(running, instruction, registers, state);
            // A branch on the step's sign, which a loop never changes, rather
            // than a select that keeps both answers live.
            if (step_value.isPositiveInline()) {
                if (Value.inlineLess(limit_value, next)) return following(running, instruction, registers, state);
            } else {
                if (Value.inlineLess(next, limit_value)) return following(running, instruction, registers, state);
            }
            registers[base + 2] = next;
            return jumpVia(running, op.to, registers, state);
        }
        return @call(.always_tail, forLoopFloat, .{ running, instruction, registers, open, state });
    }

    /// A loop over floats, apart from the integer one so that the integer
    /// arm holds few enough values to save no register.
    noinline fn forLoopFloat(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, open: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        const op = &instruction.operation.for_loop;
        const base = op.base;
        const slot = running.original_top + base + 2;
        fast: {
            const limit = registers[base].numberIn() orelse break :fast;
            const step = registers[base + 1].numberIn() orelse break :fast;
            const index = registers[base + 2].numberIn() orelse break :fast;
            // What closeFrom would do for the visible variable's slot.
            if (slot < state.origins_end) break :fast;
            if (state.open_cells.items.len != 0 and state.open_cells.items[state.open_cells.items.len - 1].storage.open >= slot) break :fast;
            const next = index + step;
            if (if (step > 0) next <= limit else limit <= next) {
                registers[base + 2].storeNumber(next);
                return jumpVia(running, op.to, registers, state);
            }
            return following(running, instruction, registers, state);
        }
        return @call(.always_tail, forLoopRarely, .{ running, instruction, registers, open, state });
    }

    noinline fn forLoopRarely(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, _: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        const op = &instruction.operation.for_loop;
        if (Vm.forLoop(state, instruction, registers[0..registerCount(running, state)], running.original_top) catch |err| return fail(running, instruction, err)) return jumpVia(running, op.to, registers, state);
        return following(running, instruction, registers, state);
    }

    noinline fn initGlobal(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, _: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        running.position.* = instruction;
        const op = &instruction.operation.init_global;
        Vm.initGlobal(state, running.prototype, running.original_top, registers[0..registerCount(running, state)], instruction, op.*, running.diagnostic) catch |err| return raise(running, err);
        return followingAfterMove(running, instruction, no_open, state);
    }

    noinline fn constant(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, _: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        const op = &instruction.operation.constant;
        registers[op.destination] = running.prototype.constants[op.index];
        return following(running, instruction, registers, state);
    }

    noinline fn unary(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, _: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        running.position.* = instruction;
        const op = &instruction.operation.unary;
        const value = Vm.unary(state, instruction, registers[op.register], running.diagnostic) catch |err| return fail(running, instruction, err);
        state.stack.items[running.original_top + op.register] = value;
        return followingAfterMove(running, instruction, no_open, state);
    }

    noinline fn table(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, _: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        const op = &instruction.operation.table;
        // A constructor whose size gains nothing takes the plain table: the
        // sized one measured slower on `method`.
        const made = if (op.template != bytecode.no_cache)
            state.newTableFrom(op.items, &running.prototype.table_templates[op.template])
        else if (op.items == 0 and !HashPart.regrowsFilling(op.fields))
            state.newTable()
        else
            state.newTableSized(op.items, op.fields);
        registers[op.destination] = .from(.{ .table = made catch |err| return fail(running, instruction, err) });
        return following(running, instruction, registers, state);
    }

    /// A table answering from its field cache or its array part.
    noinline fn get(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, open: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        const op = &instruction.operation.get;
        const receiver = if (op.table_upvalue) state.readCell(running.closure.upvalues[op.table]) else registers[op.table];
        if (receiver.is(.table)) {
            const found_table = receiver.unpack().table;
            if (op.cache != bytecode.no_cache) {
                const cache = &running.prototype.field_caches[op.cache];
                if (found_table.cachedField(cache) orelse found_table.positionalSlot(cache)) |slot| {
                    const value = slot.load();
                    if (!value.is(.nil)) {
                        registers[op.destination].store(value);
                        return following(running, instruction, registers, state);
                    }
                }
            } else if (!op.key_constant) {
                if (found_table.arraySlot(registers[op.key])) |slot| {
                    const value = found_table.array.items[slot];
                    if (!value.is(.nil)) {
                        registers[op.destination] = value;
                        return following(running, instruction, registers, state);
                    }
                }
            }
        }
        return @call(.always_tail, getRarely, .{ running, instruction, registers, open, state });
    }

    /// A `get` whose key is in a register (`assignArms`): an integer key
    /// reads the array part directly, in an arm of its own as `setIndexed`.
    noinline fn getIndexed(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, open: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        const op = &instruction.operation.get;
        const receiver = registers[op.table];
        if (receiver.is(.table)) {
            const found_table = receiver.unpack().table;
            const key = registers[op.key];
            const slot: ?usize = if (key.isInlineInteger()) blk: {
                const index: u64 = @bitCast(key.asInlineInteger() -% 1);
                break :blk if (index < found_table.array.items.len) @intCast(index) else null;
            } else found_table.arraySlot(key);
            if (slot) |at| {
                const value = found_table.array.items[at];
                if (!value.is(.nil)) {
                    registers[op.destination] = value;
                    return following(running, instruction, registers, state);
                }
            }
        }
        return @call(.always_tail, getRarely, .{ running, instruction, registers, open, state });
    }

    noinline fn getRarely(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, _: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        running.position.* = instruction;
        const op = &instruction.operation.get;
        const key = if (op.key_constant) running.prototype.constants[op.key] else registers[op.key];
        const receiver = if (op.table_upvalue) state.readCell(running.closure.upvalues[op.table]) else registers[op.table];
        // A table holding the key answers at once, as `get` would on its
        // first step, and runs nothing, so the registers are still the stack.
        if (receiver.is(.table)) {
            const found_table = receiver.unpack().table;
            if (op.cache != bytecode.no_cache) {
                const cache = &running.prototype.field_caches[op.cache];
                if (cachedSlot(cache, found_table, key)) |found| {
                    const value = found.load();
                    if (!value.is(.nil)) {
                        registers[op.destination].store(value);
                        return following(running, instruction, registers, state);
                    }
                }
                // A method: the metatable holds `__index` itself, and it is a
                // table holding the key, as a class is; `getAfter`'s first
                // link, without its general way. The same cache serves, since
                // a receiver that never holds the key leaves it naming the
                // class. The key is a constant string, so a valid key.
                if (found_table.metatable) |meta| {
                    const link = meta.getName("__index");
                    if (link.is(.table)) if (cachedSlot(cache, link.unpack().table, key)) |found| {
                        const value = found.load();
                        if (!value.is(.nil)) {
                            registers[op.destination].store(value);
                            return following(running, instruction, registers, state);
                        }
                    };
                }
            } else {
                const found = found_table.get(key);
                if (!found.is(.nil)) {
                    registers[op.destination] = found;
                    return following(running, instruction, registers, state);
                }
            }
        }
        // A table receiver was searched above and held nil for the key.
        const value = Vm.getAfter(state, instruction, receiver, key, running.diagnostic, receiver.is(.table)) catch |err| return fail(running, instruction, err);
        state.stack.items[running.original_top + op.destination] = value;
        return followingAfterMove(running, instruction, no_open, state);
    }

    /// A table with no metatable taking the value in a cached field or its
    /// array part.
    noinline fn set(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, open: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        const op = &instruction.operation.set;
        const receiver = registers[op.table];
        if (receiver.is(.table) and receiver.unpack().table.metatable == null) {
            const found_table = receiver.unpack().table;
            const value = if (op.value_constant) running.prototype.constants[op.value] else registers[op.value].load();
            if (op.cache != bytecode.no_cache) {
                const cache = &running.prototype.field_caches[op.cache];
                // The table the cache names, else one made from the same
                // constructor template, whose key is in the same slot.
                if (found_table.cachedField(cache) orelse found_table.positionalSlot(cache)) |slot| {
                    state.barrier(&found_table.header);
                    found_table.storeAt(slot, value);
                    return following(running, instruction, registers, state);
                }
            } else if (!op.key_constant) {
                return @call(.always_tail, setIndexed, .{ running, instruction, registers, open, state });
            }
        }
        return @call(.always_tail, setRarely, .{ running, instruction, registers, open, state });
    }

    /// A global's assignment: `set` with its table read from the upvalue
    /// `_ENV` and its key a constant string, so a field cache serves it.
    noinline fn setGlobal(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, open: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        const op = &instruction.operation.set;
        const receiver = state.readCell(running.closure.upvalues[op.table]);
        if (op.cache != bytecode.no_cache and receiver.is(.table) and receiver.unpack().table.metatable == null) {
            const found_table = receiver.unpack().table;
            if (found_table.cachedField(&running.prototype.field_caches[op.cache])) |slot| {
                const value = if (op.value_constant) running.prototype.constants[op.value] else registers[op.value].load();
                state.barrier(&found_table.header);
                found_table.storeAt(slot, value);
                return following(running, instruction, registers, state);
            }
        }
        return @call(.always_tail, setRarely, .{ running, instruction, registers, open, state });
    }

    /// A `set` whose key is in a register (`assignArms`): an integer key's
    /// slot found once, for a store within the array part or the append
    /// just past it. In an arm of its own, so that the constant keys' `set`
    /// saves no register for it.
    noinline fn setIndexed(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, open: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        const op = &instruction.operation.set;
        const receiver = registers[op.table];
        if (!receiver.is(.table) or receiver.unpack().table.metatable != null) return @call(.always_tail, setRarely, .{ running, instruction, registers, open, state });
        const found_table = receiver.unpack().table;
        const value = if (op.value_constant) running.prototype.constants[op.value] else registers[op.value].load();
        const key = registers[op.key];
        if (key.isInlineInteger()) {
            const index: u64 = @bitCast(key.asInlineInteger() -% 1);
            if (index < found_table.array.items.len) {
                state.barrier(&found_table.header);
                found_table.storeInArray(@intCast(index), value);
                return following(running, instruction, registers, state);
            }
            if (index == found_table.array.items.len and found_table.appendHere(value)) {
                state.barrier(&found_table.header);
                return following(running, instruction, registers, state);
            }
        } else if (found_table.arraySlot(key)) |slot| {
            state.barrier(&found_table.header);
            found_table.storeInArray(slot, value);
            return following(running, instruction, registers, state);
        }
        return @call(.always_tail, setAppending, .{ running, instruction, registers, open, state });
    }

    /// A key past the array part: the sequence's next one appends.
    noinline fn setAppending(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, open: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        const op = &instruction.operation.set;
        // `set` saw a table with no metatable here.
        const found_table = registers[op.table].asTable();
        const value = if (op.value_constant) running.prototype.constants[op.value] else registers[op.value].load();
        state.barrier(&found_table.header);
        if (found_table.appendNext(registers[op.key], value)) return following(running, instruction, registers, state);
        return @call(.always_tail, setRarely, .{ running, instruction, registers, open, state });
    }

    noinline fn setRarely(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, _: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        running.position.* = instruction;
        const op = &instruction.operation.set;
        const receiver = if (op.table_upvalue) state.readCell(running.closure.upvalues[op.table]) else registers[op.table];
        const key = if (op.key_constant) running.prototype.constants[op.key] else registers[op.key];
        const value = if (op.value_constant) running.prototype.constants[op.value] else registers[op.value].load();
        // A table with no metatable takes a valid key raw, which is all
        // `set` does for one; anything else goes the general way.
        if (receiver.is(.table) and receiver.unpack().table.metatable == null and key.validKey()) {
            const found_table = receiver.unpack().table;
            if (op.cache != bytecode.no_cache) {
                // `set` found the cache naming another table: the slot where
                // the key is in a table like the last, else one probe that
                // stores and names the slot.
                const cache = &running.prototype.field_caches[op.cache];
                if (found_table.positionalField(cache)) |found| {
                    state.barrier(&found_table.header);
                    found_table.storeAt(found, value);
                    return following(running, instruction, registers, state);
                }
                state.barrier(&found_table.header);
                found_table.setRemembering(state.allocator, cache, key, value) catch |err| return fail(running, instruction, err);
                return following(running, instruction, registers, state);
            }
            const stored_key = state.storedKey(key) catch |err| return fail(running, instruction, err);
            state.barrier(&found_table.header);
            found_table.set(state.allocator, stored_key, value) catch |err| return fail(running, instruction, switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidKey => error.InvalidBytecode,
            });
            return following(running, instruction, registers, state);
        }
        Vm.set(state, instruction, receiver, key, value, running.diagnostic) catch |err| return fail(running, instruction, err);
        return followingAfterMove(running, instruction, no_open, state);
    }

    noinline fn branch(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, _: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        const op = &instruction.operation.branch;
        if (registers[op.register].truthy() == op.when) return jumpVia(running, op.to, registers, state);
        return following(running, instruction, registers, state);
    }

    noinline fn clear(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, _: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        const op = &instruction.operation.clear;
        // Under `-Dpoison-registers` the compiler's clears mark registers it
        // gave back (`release`), which hold a poison number instead.
        if (@import("layout").poison_registers) runtime.poison(registers[op.first..][0..op.count]) else clearSlots(registers[op.first..][0..op.count]);
        return following(running, instruction, registers, state);
    }

    noinline fn tailCall(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, open: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        running.position.* = instruction;
        const op = &instruction.operation.tail_call;
        // A C function above the floor, with counted arguments and room for
        // its frame: called in place, the script frame kept while it runs,
        // and its results then this frame's (`Vm.tailCall`'s native way).
        if (running.frame_index != running.floor and op.arguments != null and registers[op.base].cFunction() != null and registers[op.base].bits != state.protected_call.bits and
            state.frames.items.len < state.callLimit() and state.frames.items.len < state.frames.capacity)
        {
            const original_top = running.original_top;
            const count = runNativeHere(running, instruction, registers[op.base].asFunction().?, original_top + op.base + 1, op.arguments.?) catch |err| return fail(running, instruction, err);
            state.closeFrom(original_top);
            moveDown(state.stack.items[original_top..][0..count], state.stack.items[state.stack.items.len - count ..]);
            runtime.cutStack(&state.stack, original_top + count);
            state.popFrameInChain();
            const caller = &state.frames.items[running.frame_index - 1];
            if (caller.protected_call) return returnInChain(running, count);
            const waiting = &caller.instruction.?.operation.call;
            if (count == 1 and waiting.results == 1) {
                state.closeFrom(caller.base + waiting.base);
                return deliverOne(running, state.stack.items[original_top], caller, waiting);
            }
            return returnInChain(running, count);
        }
        // A script callee above the floor with its arguments counted, which
        // `enter` would take its common way: it replaces this frame in place,
        // at the same depth, with nothing that calls out.
        if (running.frame_index != running.floor and op.arguments != null and registers[op.base].is(.closure)) {
            const callee = registers[op.base].asClosure();
            const prototype = callee.prototype;
            const base = running.original_top;
            const end = base + prototype.registers;
            if (prototype.validated and !prototype.vararg and callee.upvalues.len == prototype.upvalue_count and
                end <= state.stack.capacity and end <= runtime.State.max_stack and base >= state.origins_end and (state.origins.items.len == 0 or end <= state.origins.items.len) and
                running.diagnostic.* == null)
            {
                const arguments = op.arguments.?;
                state.closeCellsFrom(base);
                moveDown(state.stack.items[base..][0..arguments], state.stack.items[base + op.base + 1 ..][0..arguments]);
                const supplied_end = base + arguments;
                const parameters_end = base + prototype.parameters;
                state.stack.items.len = end;
                runtime.poison(state.stack.items[@min(supplied_end, parameters_end)..end]);
                if (parameters_end > supplied_end) runtime.fillNil(state.stack.items[supplied_end..parameters_end]);
                state.frames.items[running.frame_index] = .{ .base = base, .function = .{ .closure = callee } };
                running.closure = callee;
                running.prototype = prototype;
                running.register_count = prototype.registers;
                return proceed(running, &prototype.code[0], state.stack.items[base..].ptr, no_open, state);
            }
        }
        const outcome = Vm.tailCall(state, running.prototype, running.original_top, registers[0..registerCount(running, state)], instruction, op.*, openOf(open), running.diagnostic) catch |err| return raise(running, err);
        if (running.frame_index == running.floor) {
            running.outcome = outcome;
            return .done;
        }
        // The frame is popped: its results, or its replacement, answer its
        // caller in the chain.
        switch (outcome) {
            .results => |count| {
                // One result for a call that wants one, as `return_one` does.
                const caller = &state.frames.items[running.frame_index - 1];
                if (caller.protected_call) return returnInChain(running, count);
                const waiting = &caller.instruction.?.operation.call;
                if (count == 1 and waiting.results == 1) {
                    state.closeFrom(caller.base + waiting.base);
                    return deliverOne(running, state.stack.items[running.original_top], caller, waiting);
                }
                return returnInChain(running, count);
            },
            .tail => |next| {
                const call_instruction = toCaller(running);
                return enterInChain(running, call_instruction, next.closure, next.arguments, null, next.prepared);
            },
        }
    }

    noinline fn genericCall(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, _: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        running.position.* = instruction;
        const op = &instruction.operation.generic_call;
        // Close all declared variables before their slots become call
        // operands/results, including on the terminating nil result.
        state.closeFrom(running.original_top + op.base + 2);
        registers[op.base + 4] = registers[op.base + 2];
        registers[op.base + 3] = registers[op.base + 1];
        registers[op.base + 2] = registers[op.base];
        _ = Vm.call(state, running.prototype, running.original_top, instruction, .{ .base = op.base + 2, .arguments = 2, .results = @intCast(op.count) }, running.diagnostic) catch |err| return raise(running, err);
        return followingAfterMove(running, instruction, no_open, state);
    }

    noinline fn genericLoop(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, _: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        const op = &instruction.operation.generic_loop;
        if (!registers[op.base + 2].is(.nil)) return jumpVia(running, op.to, registers, state);
        return following(running, instruction, registers, state);
    }

    noinline fn call(running: *FrameRun, instruction: *const bytecode.Instruction, _: [*]Value, open: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        running.position.* = instruction;
        const op = &instruction.operation.call;
        if (op.arguments == null and (open == no_open or open < op.base + 1)) return fail(running, instruction, error.InvalidBytecode);
        const callee = state.stack.items[running.original_top + op.base];
        // The arm the callee's kind takes becomes the instruction's own, so
        // that its next run goes straight there; that arm comes back here
        // when it meets another kind.
        if (callee.is(.closure)) {
            guess(instruction, callScript);
            return @call(.always_tail, callScript, .{ running, instruction, running.registers().ptr, open, state });
        }
        if (callee.cFunction() != null) {
            // A call that wants one result, of anything but the library's
            // `pcall`, goes straight to `callNativeOne` from now on.
            if (op.arguments != null and (op.target != null or op.results == 1) and callee.bits != state.protected_call.bits) {
                guess(instruction, callNativeOne);
                return @call(.always_tail, callNativeOne, .{ running, instruction, running.registers().ptr, open, state });
            }
            guess(instruction, callNative);
            return @call(.always_tail, callNative, .{ running, instruction, running.registers().ptr, open, state });
        }
        const results = Vm.call(state, running.prototype, running.original_top, instruction, op.*, running.diagnostic) catch |err| return raise(running, err);
        return followingAfterMove(running, instruction, results orelse no_open, state);
    }

    /// A C function: its call site made once, its results put straight into
    /// the slot that held it.
    noinline fn callNative(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, open: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        const op = &instruction.operation.call;
        // The library's `pcall` of a script function, with no failure held:
        // the callee runs in this run of frames (ADR 0009).
        if (registers[op.base].bits == state.protected_call.bits and op.arguments != null) {
            if (op.arguments.? >= 1 and registers[op.base + 1].is(.closure) and state.failure == null)
                return protectedEnter(running, instruction, registers);
        }
        if (registers[op.base].cFunction() == null or (op.arguments == null and (open == no_open or open < op.base + 1))) return unguess(running, instruction, registers, open, state);
        running.position.* = instruction;
        if (state.frames.items.len >= state.callLimit()) return fail(running, instruction, error.CallDepth);
        const function = registers[op.base].asFunction().?;
        const arguments = op.arguments orelse registerCount(running, state) - op.base - 1;
        const slot = running.original_top + op.base;
        // The arguments are the stack's last slots: the registers above them
        // are dropped, a cut that cannot fail. No cell is open there (a
        // call's slot is above every live local); an origin may be.
        state.clearOriginsFrom(slot + 1 + arguments);
        runtime.cutStack(&state.stack, slot + 1 + arguments);
        const site: runtime.CallSite = .{ .prototype = running.prototype, .instruction = instruction, .through_call = false };
        const count = runNative(state, function, arguments, running.diagnostic, site, .callee) catch |err| return fail(running, instruction, err);
        // `completeCall` with the results already in place: cut or padded
        // with nil to what the call wants, and the registers above cleared.
        if (op.target) |register| {
            // The results start at `slot`, which `resultsAt` closed from.
            const value = if (count > 0) state.stack.items[slot] else Value.nil;
            runtime.cutStack(&state.stack, slot);
            state.stack.items[running.original_top + register] = value;
            state.extendRegisters(running.original_top + running.prototype.registers) catch |err| return fail(running, instruction, stackError(err));
            return followingAfterMove(running, instruction, no_open, state);
        }
        const wanted = op.results orelse count;
        if (wanted > runtime.State.max_stack - running.original_top - op.base) return fail(running, instruction, error.StackLimit);
        const copied = @min(count, wanted);
        runtime.cutStack(&state.stack, slot + copied);
        const top = if (op.results == null) op.base + wanted else running.prototype.registers;
        state.extendRegisters(running.original_top + top) catch |err| return fail(running, instruction, stackError(err));
        runtime.fillNil(state.stack.items[slot + copied ..][0 .. wanted - copied]);
        return followingAfterMove(running, instruction, if (op.results == null) op.base else no_open, state);
    }

    /// A C function's common call: counted arguments and one result wanted,
    /// with room for its frame. `runNative`, `callInto` and `finishInto` in
    /// one pass for a C function that returns its results; any other answer
    /// (a failure, a yield, an interruption, a count it does not have) goes
    /// through `finishInto` as before.
    noinline fn callNativeOne(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, open: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        const op = &instruction.operation.call;
        // Guessed for this instruction (`call`): another kind of callee, or
        // the library's `pcall`, goes back to the general arm; a frame list
        // without room takes `callNative`'s way, which refuses the depth.
        const callee = registers[op.base];
        const function = callee.cFunction() orelse return unguess(running, instruction, registers, open, state);
        if (callee.bits == state.protected_call.bits) return unguess(running, instruction, registers, open, state);
        if (state.frames.items.len >= state.callLimit() or state.frames.items.len >= state.frames.capacity) return @call(.always_tail, callNative, .{ running, instruction, registers, open, state });
        running.position.* = instruction;
        const slot = running.original_top + op.base;
        const count = runNativeHere(running, instruction, function, slot + 1, op.arguments.?) catch |err| return fail(running, instruction, err);
        const value = if (count > 0) state.stack.items[state.stack.items.len - count] else Value.nil;
        // The value into its local or the call's slot, the registers above
        // as they were (ADR 0005).
        state.closeFrom(slot);
        runtime.cutStack(&state.stack, slot);
        state.extendRegisters(running.original_top + running.prototype.registers) catch |err| return fail(running, instruction, stackError(err));
        state.stack.items[running.original_top + (op.target orelse op.base)] = value;
        return followingAfterMove(running, instruction, no_open, state);
    }

    /// A script callee entered in the chain: `enter`'s common case, with
    /// nothing that calls out, so the arm saves few registers. A callee that
    /// needs validating or an argument table, a stack or frame list without
    /// room, a failure origin above the call or a call too deep take
    /// `callScriptRarely`.
    noinline fn callScript(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, open: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        const op = &instruction.operation.call;
        if (!registers[op.base].is(.closure) or (op.arguments == null and (open == no_open or open < op.base + 1))) return unguess(running, instruction, registers, open, state);
        const callee = registers[op.base].asClosure();
        const prototype = callee.prototype;
        const arguments = op.arguments orelse registerCount(running, state) - op.base - 1;
        const base = running.original_top + op.base + 1;
        const end = base + prototype.registers;
        const frame_count = state.frames.items.len;
        if (!(prototype.validated and !prototype.vararg and callee.upvalues.len == prototype.upvalue_count and
            end <= state.stack.capacity and end <= runtime.State.max_stack and base >= state.origins_end and (state.origins.items.len == 0 or end <= state.origins.items.len) and
            frame_count < state.frames.capacity and frame_count < state.callLimit() and running.diagnostic.* == null))
            return @call(.always_tail, callScriptRarely, .{ running, instruction, registers, open, state });
        running.position.* = instruction;
        state.closeCellsFrom(base);
        // Missing arguments are nil; every other register keeps what it
        // holds (ADR 0005).
        const supplied_end = base + arguments;
        const parameters_end = base + prototype.parameters;
        state.stack.items.len = end;
        runtime.poison(state.stack.items[@min(supplied_end, parameters_end)..end]);
        if (parameters_end > supplied_end) runtime.fillNil(state.stack.items[supplied_end..parameters_end]);
        state.frames.appendAssumeCapacity(.{ .base = base, .function = .{ .closure = callee } });
        state.frame_base = base;
        running.closure = callee;
        running.prototype = prototype;
        running.original_top = base;
        running.frame_index = frame_count;
        running.register_count = prototype.registers;
        running.position = &state.frames.items[frame_count].instruction;
        return proceed(running, &prototype.code[0], state.stack.items[base..].ptr, no_open, state);
    }

    noinline fn callScriptRarely(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, _: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        const op = &instruction.operation.call;
        running.position.* = instruction;
        if (state.frames.items.len >= state.callLimit()) return fail(running, instruction, error.CallDepth);
        const callee = registers[op.base].asClosure();
        const arguments = op.arguments orelse registerCount(running, state) - op.base - 1;
        return enterInChain(running, instruction, callee, arguments, running.original_top + op.base + 1, null);
    }

    noinline fn moveResults(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, open: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        running.position.* = instruction;
        const op = &instruction.operation.move_results;
        if (open != op.source) return fail(running, instruction, error.InvalidBytecode);
        const count = registerCount(running, state) - op.source;
        state.closeFrom(running.original_top + op.destination);
        std.mem.copyForwards(Value, registers[op.destination..][0..count], registers[op.source..registerCount(running, state)]);
        runtime.cutStack(&state.stack, running.original_top + op.destination + count);
        return followingAfterMove(running, instruction, op.destination, state);
    }

    noinline fn varargs(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, _: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        running.position.* = instruction;
        const op = &instruction.operation.varargs;
        const results = Vm.varargs(state, running.prototype, running.original_top, registers[0..registerCount(running, state)], instruction, op.*, running.diagnostic) catch |err| return raise(running, err);
        return followingAfterMove(running, instruction, results orelse no_open, state);
    }

    noinline fn setList(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, open: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        running.position.* = instruction;
        const op = &instruction.operation.set_list;
        Vm.setList(state, running.prototype, running.original_top, registers[0..registerCount(running, state)], instruction, op.*, openOf(open), running.diagnostic) catch |err| return raise(running, err);
        return followingAfterMove(running, instruction, no_open, state);
    }

    /// One value back to a caller in the chain whose call wants one: the
    /// work of `returns` and `returnIntoTarget` with nothing that calls out,
    /// so the arm saves no register. Anything else is `returns`.
    noinline fn returnOne(running: *FrameRun, instruction: *const bytecode.Instruction, registers: [*]Value, open: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        if (running.frame_index == running.floor) return @call(.always_tail, returns, .{ running, instruction, registers, open, state });
        const caller = &state.frames.items[running.frame_index - 1];
        if (caller.protected_call) return @call(.always_tail, returns, .{ running, instruction, registers, open, state });
        const resumed = caller.instruction.?;
        const waiting = &resumed.operation.call;
        const base = caller.base + waiting.base;
        const caller_closure = caller.function.closure;
        const end = caller.base + caller_closure.prototype.registers;
        // A failure's origin at or above the call, or room to make, takes
        // the general way (`closeFrom`'s memset, `extendRegisters`' growth).
        if (waiting.results != 1 or base < state.origins_end or end > state.stack.capacity or (state.origins.items.len != 0 and end > state.origins.items.len)) return @call(.always_tail, returns, .{ running, instruction, registers, open, state });
        const value = registers[instruction.operation.returns.first];
        state.closeCellsFrom(base);
        state.popFrameInChain();
        running.frame_index -= 1;
        running.closure = caller_closure;
        running.prototype = caller_closure.prototype;
        running.original_top = caller.base;
        running.register_count = caller_closure.prototype.registers;
        running.position = &caller.instruction;
        // The slots above the call keep what they hold (ADR 0005).
        const kept = if (waiting.target != null) base else base + 1;
        state.stack.items.len = end;
        runtime.poison(state.stack.items[kept..end]);
        state.stack.items[if (waiting.target) |target| caller.base + target else base] = value;
        return proceed(running, &@as([*]const bytecode.Instruction, @ptrCast(resumed))[1], state.stack.items[caller.base..].ptr, no_open, state);
    }

    noinline fn returns(running: *FrameRun, instruction: *const bytecode.Instruction, registers_in: [*]Value, open: usize, state: *runtime.State) align(arm_alignment) linksection(arm_section) Exit {
        running.position.* = instruction;
        var registers = registers_in;
        const op = &instruction.operation.returns;
        const count = op.count orelse blk: {
            if (open == no_open) return fail(running, instruction, error.InvalidBytecode);
            if (op.first > open) return fail(running, instruction, error.InvalidBytecode);
            break :blk registerCount(running, state) - op.first;
        };
        if (op.close) {
            closeScope(state, running.prototype, instruction, running.original_top, running.diagnostic) catch |err| return raise(running, err);
            registers = running.registers().ptr;
        }
        if (running.frame_index != running.floor and count == 1) {
            const caller = &state.frames.items[running.frame_index - 1];
            if (!caller.protected_call and caller.instruction.?.operation.call.results == 1) return returnIntoTarget(running, registers[op.first], caller, &caller.instruction.?.operation.call);
        }
        state.closeFrom(running.original_top);
        moveDown(registers[0..count], registers[op.first..][0..count]);
        runtime.cutStack(&state.stack, running.original_top + count);
        if (running.frame_index != running.floor) {
            state.popFrameInChain();
            return returnInChain(running, count);
        }
        _ = state.popFrame();
        running.outcome = .{ .results = count };
        return .done;
    }
};

/// A new frame's entry: checks, the argument table, the registers and the
/// pushed frame. Answers the callee's window; on failure rolls it back.
/// `arguments_on_stack` is a caller's promise that the arguments are the
/// stack's last `argument_count` slots (or at `at`), above the current
/// frame's base, and that it has checked the call depth.
/// `at`, when given, is where the arguments start, with anything above them
/// (a caller's other registers) to be dropped: the cut a call makes before
/// entering, done here in the same pass.
inline fn enter(comptime arguments_on_stack: bool, state: *runtime.State, closure: *runtime.Closure, prototype: *runtime.Prototype, argument_count: usize, at: ?usize, prepared: ?*runtime.Table, diagnostic: *?Diagnostic) Error!execution.Window {
    // The common callee, validated and with fixed parameters, with room for
    // its registers and frame: the steps below without the checks that
    // cannot fail then.
    if (arguments_on_stack or argument_count <= state.top()) {
        const base = at orelse state.stack.items.len - argument_count;
        const end = base + prototype.registers;
        if (prepared == null and prototype.validated and !prototype.vararg and closure.upvalues.len == prototype.upvalue_count and
            end <= state.stack.capacity and end <= runtime.State.max_stack and (state.origins.items.len == 0 or end <= state.origins.items.len) and
            state.frames.items.len < state.frames.capacity and (arguments_on_stack or state.frames.items.len < state.callLimit()))
        {
            const window: execution.Window = .{ .base = base, .frames = state.frames.items.len };
            state.closeFrom(base);
            const supplied_end = base + argument_count;
            const parameters_end = base + prototype.parameters;
            state.stack.items.len = end;
            // Missing arguments are nil; every other register, and any
            // argument past the parameters, keeps what it holds (`growStack`).
            runtime.poison(state.stack.items[@min(supplied_end, parameters_end)..end]);
            if (parameters_end > supplied_end) clearSlots(state.stack.items[supplied_end..parameters_end]);
            state.frames.appendAssumeCapacity(.{ .base = base, .function = .{ .closure = closure } });
            state.frame_base = base;
            return window;
        }
    }
    if (at) |first| {
        // The cut: a shorter stack, so it cannot fail.
        state.closeFrom(first + argument_count);
        runtime.cutStack(&state.stack, first + argument_count);
    }
    if (argument_count > state.top()) return error.InvalidBytecode;
    if (closure.upvalues.len != prototype.upvalue_count) return error.InvalidBytecode;
    if (!prototype.validated) {
        validate(prototype) catch |err| {
            if (prototype.code.len > 0) return failure(state, prototype, &prototype.code[0], diagnostic, err);
            return err;
        };
        bytecode.assignDispatch(prototype.code);
        assignArms(prototype.code, prototype.constants);
        assignFieldCaches(state.allocator, prototype) catch |err| return failure(state, prototype, &prototype.code[0], diagnostic, err);
        assignTemplates(state.allocator, prototype) catch |err| return failure(state, prototype, &prototype.code[0], diagnostic, err);
        prototype.validated = true;
    }
    const window = try execution.Window.arguments(state, argument_count);
    const original_top = window.base;
    errdefer window.rollback(state);
    if (state.frames.items.len >= state.callLimit()) return failure(state, prototype, &prototype.code[0], diagnostic, error.CallDepth);
    if (prototype.registers > runtime.State.max_stack - original_top) return failure(state, prototype, &prototype.code[0], diagnostic, error.StackLimit);
    // Build the counted table while every incoming value is still a stack root,
    // before entering the callee frame. Constructors do not collect.
    const argument_table = prepared orelse if (prototype.vararg) packArguments(state, state.stack.items[original_top + @min(argument_count, prototype.parameters) ..]) catch |err| return failure(state, prototype, &prototype.code[0], diagnostic, err) else null;
    state.closeFrom(original_top);
    // Slots the arguments did not reach are nil already: setLength fills
    // what it adds. Only arguments past the parameters need clearing.
    const supplied_end = state.stack.items.len;
    state.setLength(original_top + prototype.registers) catch |err| return failure(state, prototype, &prototype.code[0], diagnostic, stackError(err));
    state.pushFrame(.{ .base = original_top, .function = .{ .closure = closure } }) catch |err| return failure(state, prototype, &prototype.code[0], diagnostic, switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidIndex => error.InvalidBytecode,
    });
    const kept = original_top + @min(argument_count, prototype.parameters);
    if (supplied_end > kept) clearSlots(state.stack.items[kept..@min(supplied_end, state.stack.items.len)]);
    if (argument_table) |table| state.stack.items[original_top + prototype.parameters] = .from(.{ .table = table });
    return window;
}

test "numeric_for opcode closes the current captured control before reuse" {
    var state = try runtime.State.init(std.testing.allocator);
    defer state.deinit();
    try state.push(.from(.{ .number = 3 }));
    try state.push(.from(.{ .number = 1 }));
    try state.push(.from(.{ .number = 1 }));
    const first = try state.capture(2);
    const position = bytecode.Position{ .offset = 0, .line = 1, .column = 1 };
    const info: bytecode.Info = .{ .position = position };
    const instruction = bytecode.Instruction{ .info = &info, .operation = .{ .for_loop = .{ .base = 0, .target = 0 } } };
    try std.testing.expect(try forLoop(&state, &instruction, state.stack.items, 0));
    try std.testing.expect(first.storage == .closed);
    try std.testing.expect(state.readCell(first).equal(.from(.{ .number = 1 })));
    const second = try state.capture(2);
    try std.testing.expect(second != first);
    try std.testing.expect(try forLoop(&state, &instruction, state.stack.items, 0));
    try std.testing.expect(second.storage == .closed);
    try std.testing.expect(state.readCell(second).equal(.from(.{ .number = 2 })));
    const third = try state.capture(2);
    try std.testing.expect(!try forLoop(&state, &instruction, state.stack.items, 0));
    try std.testing.expect(third.storage == .closed);
    try std.testing.expect(state.readCell(third).equal(.from(.{ .number = 3 })));
}
