const std = @import("std");
const Token = @import("Token.zig");
const runtime = @import("runtime.zig");
const bytecode = @import("bytecode.zig");
const name_text = @import("name_text.zig");
const vm = @import("vm.zig");
/// What the VM records about a failure it raises; rendered into a sentence
/// below, once the source is at hand.
pub const ForArgument = enum { initial, limit, step };
pub const Diagnostic = struct {
    kind: enum { type_error, runtime_error, for_not_number, for_step_zero, global_already_defined, invalid_bytecode, invalid_native_result, out_of_memory, stack_limit, call_depth, pending_feature, interrupted, index_chain_too_long, newindex_chain_too_long, call_chain_too_long, no_integer_representation, vararg_count, non_closable, divide_by_zero, modulo_by_zero },
    position: @import("bytecode.zig").Position,
    operation: std.meta.Tag(bytecode.Instruction.Operation),
    operand_type: ?runtime.Type = null,
    for_argument: ?ForArgument = null,
    action: ?enum { arithmetic, bitwise, concatenate, length, index, call, compare, key } = null,
    hint: ?bytecode.Name = null,
    subject: ?bytecode.Name = null,
    other_type: ?runtime.Type = null,
    type_name: ?*runtime.String = null,
    other_name: ?*runtime.String = null,
    key_nan: bool = false,
};

const Error = error{ OutOfMemory, InvalidSpan, PendingDiagnostic };
const WriteError = std.Io.Writer.Error || error{ OutOfMemory, InvalidSpan, PendingDiagnostic };

fn typename(tag: ?runtime.Type, custom: ?*runtime.String) []const u8 {
    return if (custom) |name| std.mem.sliceTo(name.bytes, 0) else if (tag) |kind| @tagName(kind) else "?";
}
fn nameText(allocator: std.mem.Allocator, writer: *std.Io.Writer, source: []const u8, name: bytecode.Name) WriteError!void {
    const text = try name_text.resolve(allocator, source, name);
    defer text.deinit(allocator);
    // Failure prose keeps the established C-string display rule; internal
    // name preparation retains the bytes after NUL for length-aware consumers.
    try writer.writeAll(std.mem.sliceTo(text.bytes, 0));
}

fn body(allocator: std.mem.Allocator, writer: *std.Io.Writer, source: []const u8, diagnostic: Diagnostic) WriteError!void {
    const kind = typename(diagnostic.operand_type, diagnostic.type_name);
    switch (diagnostic.kind) {
        .for_step_zero => try writer.writeAll("'for' step is zero"),
        // Lua's words for an integer division or modulo by zero.
        .divide_by_zero => try writer.writeAll("attempt to divide by zero"),
        .modulo_by_zero => try writer.writeAll("attempt to perform 'n%0'"),
        .for_not_number => {
            const argument = diagnostic.for_argument orelse return error.PendingDiagnostic;
            try writer.print("bad 'for' {s} (number expected, got {s})", .{ if (argument == .initial) "initial value" else @tagName(argument), kind });
        },
        .global_already_defined => {
            const name = diagnostic.subject orelse return error.PendingDiagnostic;
            try writer.writeAll("global '");
            try nameText(allocator, writer, source, name);
            try writer.writeAll("' already defined");
        },
        .non_closable => {
            const name = diagnostic.subject orelse return error.PendingDiagnostic;
            try writer.writeAll("variable '");
            try nameText(allocator, writer, source, name);
            try writer.writeAll("' got a non-closable value");
        },
        .index_chain_too_long => try writer.writeAll("'__index' chain too long; possible loop"),
        .newindex_chain_too_long => try writer.writeAll("'__newindex' chain too long; possible loop"),
        .call_chain_too_long => try writer.writeAll("'__call' chain too long"),
        .call_depth => try writer.writeAll("stack overflow"),
        .vararg_count => try writer.writeAll("vararg table has no proper 'n'"),
        // Lua's luaG_tointerror: the operand's name when it has one; a
        // constant has none.
        .no_integer_representation => {
            try writer.writeAll("number");
            if (diagnostic.hint) |name| {
                try writer.print(" ({s} '", .{if (name.kind == .for_iterator) "for iterator" else @tagName(name.kind)});
                try nameText(allocator, writer, source, name);
                try writer.writeAll("')");
            }
            try writer.writeAll(" has no integer representation");
        },
        .type_error => {
            switch (diagnostic.action orelse return error.PendingDiagnostic) {
                .key => {
                    if (diagnostic.key_nan) try writer.writeAll("table index is NaN") else if (diagnostic.operand_type == .nil) try writer.writeAll("table index is nil") else try writer.print("table index is a {s} value", .{kind});
                    return;
                },
                .compare => {
                    const other = typename(diagnostic.other_type, diagnostic.other_name);
                    if (std.mem.eql(u8, kind, other)) try writer.print("attempt to compare two {s} values", .{kind}) else try writer.print("attempt to compare {s} with {s}", .{ kind, other });
                    return;
                },
                else => |operation| try writer.print("attempt to {s} a {s} value", .{ switch (operation) {
                    .arithmetic => "perform arithmetic on",
                    .bitwise => "perform bitwise operation on",
                    .length => "get length of",
                    .concatenate => "concatenate",
                    .index => "index",
                    .call => "call",
                    else => unreachable,
                }, kind }),
            }
            if (diagnostic.hint) |name| {
                try writer.print(" ({s} '", .{if (name.kind == .for_iterator) "for iterator" else @tagName(name.kind)});
                try nameText(allocator, writer, source, name);
                try writer.writeAll("')");
            }
        },
        else => return error.PendingDiagnostic,
    }
}

/// Pure formatting; names/spans refer only to copied prototype source. Runtime
/// messages have a line, never a column. Explicitly raised values bypass this.
pub fn render(allocator: std.mem.Allocator, prototype: ?*const runtime.Prototype, diagnostic: Diagnostic, positioned: bool) Error![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    if (positioned) {
        const program = prototype orelse return error.PendingDiagnostic;
        output.writer.print("{s}:{d}: ", .{ program.displayName(), diagnostic.position.line }) catch return error.OutOfMemory;
    }
    body(allocator, &output.writer, if (prototype) |program| program.source else "", diagnostic) catch |err| return switch (err) {
        error.WriteFailed, error.OutOfMemory => error.OutOfMemory,
        error.InvalidSpan => error.InvalidSpan,
        error.PendingDiagnostic => error.PendingDiagnostic,
    };
    return output.toOwnedSlice();
}

/// Complete a core failure before handler dispatch and before its frame unwinds.
/// Formatting OOM becomes the prepared memory failure; never lose caller roots.
pub fn complete(state: *runtime.State, prototype: ?*const runtime.Prototype, original: vm.Error) vm.Error {
    const record = if (state.failure) |*record| record else return original;
    if (!record.needs_message) return original;
    const diagnostic = record.diagnostic orelse switch (record.kind) {
        .call_depth => Diagnostic{ .kind = .call_depth, .position = .{ .offset = 0, .line = 1, .column = 1 }, .operation = .call },
        else => return original,
    };
    const bytes = render(state.allocator, prototype, diagnostic, record.origin == .vm and prototype != null) catch |err| return switch (err) {
        error.OutOfMemory => memoryFailure(state),
        error.InvalidSpan => error.InvalidBytecode,
        error.PendingDiagnostic => error.PendingFeature,
    };
    defer state.allocator.free(bytes);
    const string = state.newString(bytes) catch return memoryFailure(state);
    state.failure.?.value = .from(.{ .string = string });
    state.failure.?.needs_message = false;
    return original;
}
fn memoryFailure(state: *runtime.State) vm.Error {
    state.failure.?.kind = .out_of_memory;
    state.failure.?.value = .from(.{ .string = state.memory_failure });
    state.failure.?.needs_message = false;
    if (state.failure.?.diagnostic) |*diagnostic| diagnostic.kind = .out_of_memory;
    return error.OutOfMemory;
}
