const std = @import("std");
const Token = @import("Token.zig");
const runtime = @import("runtime.zig");
const diagnostic_text = @import("load_diagnostic.zig");
const parser = @import("parser.zig");
const compiler = @import("compiler.zig");

pub const Error = parser.Error || compiler.Error || error{InvalidPrototype};
/// Value-only diagnostics: positions/spans refer to the caller's source, never
/// to the temporary AST arena. Source is needed later to spell a diagnostic.
pub const Diagnostic = union(enum) {
    parse: parser.Diagnostic,
    compile: compiler.Diagnostic,
};

/// Prepares a chunk without executing it or changing the caller's stack.
/// The state owns the copied source/name, code, constants and chunk environment.
/// Root the returned closure before any collection. No collection runs here.
/// A failed preparation releases its unpublished state allocations immediately.
/// Malformed internal ASTs remain distinct from source-language refusals.
/// This is not yet the public load API's status/message/stack contract.
pub fn prepare(state: *runtime.State, source: []const u8, chunk_name: []const u8, diagnostic: *?Diagnostic) Error!*runtime.Closure {
    diagnostic.* = null;
    const checkpoint = state.preparationCheckpoint();
    errdefer state.discardPreparation(checkpoint);
    var parse_diagnostic: ?parser.Diagnostic = null;
    var ast = parser.parseChunk(state.allocator, source, &parse_diagnostic) catch |err| {
        if (parse_diagnostic) |detail| diagnostic.* = .{ .parse = detail };
        return err;
    };
    defer ast.deinit();
    var compile_diagnostic: ?compiler.Diagnostic = null;
    const prototype = compiler.compile(state.allocator, state, &ast, chunk_name, &compile_diagnostic) catch |err| {
        if (compile_diagnostic) |detail| diagnostic.* = .{ .compile = detail };
        return err;
    };
    return try state.newChunk(prototype);
}

pub const LoadError = Error || diagnostic_text.Error || error{StackLimit};
pub const Result = enum { loaded, syntax };
/// Owner-confirmed: if either coordinate
/// cannot be represented, report the whole position as unknown, never truncate.
pub const ErrorLocation = extern struct {
    line: c_int = 0,
    column: c_int = 0,

    pub fn from(position: Token.Position) ErrorLocation {
        return .{
            .line = std.math.cast(c_int, position.line) orelse return .{},
            .column = std.math.cast(c_int, position.column) orelse return .{},
        };
    }
};

/// Internal staging for the recorded public load stack shape: append a closure
/// on success or a supported syntax message on refusal. Other failures append
/// nothing. No code runs. Public wrappers enforce C preconditions and map
/// resource outcomes; internal diagnostic invariant violations stay distinct.
pub fn load(state: *runtime.State, source: []const u8, name: []const u8, diagnostic: *?Diagnostic) LoadError!Result {
    return loadLocated(state, source, name, diagnostic, null);
}

/// Clear coordinates on every entry; publish them only with a syntax result.
/// A successful load, OOM, stack limit or pending path leaves zero coordinates.
pub fn loadLocated(state: *runtime.State, source: []const u8, name: []const u8, diagnostic: *?Diagnostic, where: ?*ErrorLocation) LoadError!Result {
    if (where) |output| output.* = .{};
    diagnostic.* = null;
    if (state.stack.items.len >= runtime.State.max_stack) return error.StackLimit;
    try state.ensureOrigins(state.stack.items.len + 1);
    try runtime.growStack(&state.stack, state.open_cells.items, state.allocator, state.stack.items.len + 1);
    const chunk = prepare(state, source, name, diagnostic) catch |err| {
        if (err != error.Syntax) return err;
        const detail = diagnostic.* orelse return error.PendingDiagnostic;
        const rendered = try diagnostic_text.renderLocated(state.allocator, source, name, detail);
        defer state.allocator.free(rendered.bytes);
        const location = if (where != null) ErrorLocation.from(rendered.position) else ErrorLocation{};
        const message = try state.newString(rendered.bytes);
        state.stack.appendAssumeCapacity(.from(.{ .string = message }));
        if (where) |output| output.* = location;
        return .syntax;
    };
    state.stack.appendAssumeCapacity(.fromFunction(.{ .closure = chunk }));
    return .loaded;
}
