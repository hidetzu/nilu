const std = @import("std");
const arithmetic = @import("arithmetic.zig");
const runtime = @import("runtime.zig");
const numeral = @import("numeral.zig");

pub const fail: c_int = -1;
pub const ErrorLocation = @import("loader.zig").ErrorLocation;

/// Keep independent of internal Value tag order.
pub const Type = enum(c_int) {
    none = -1,
    nil = 0,
    number = 1,
    function = 2,
    boolean = 3,
    string = 4,
    table = 5,
    userdata = 6,
    thread = 7,
};

pub const Status = enum(c_int) {
    ok = 0,
    runtime,
    syntax,
    memory,
    call_depth,
    stack,
    type,
    interrupted,
    yielded,
};

fn callStatus(state: *runtime.State, kind: runtime.FailureKind, comptime name: []const u8) Status {
    return switch (kind) {
        .runtime_error => .runtime,
        .type_error => .type,
        .call_depth => .call_depth,
        .stack_limit => .stack,
        .out_of_memory => memory(state),
        .interrupted => .interrupted,
        .invalid_native_result => @panic(name ++ ": native callback returned an invalid result count"),
        .invalid_bytecode => @panic(name ++ ": internal bytecode invariant violated"),
        .pending_feature => @panic(name ++ ": execution path is not implemented"),
    };
}

fn operationError(state: *runtime.State, err: @import("vm.zig").Error, comptime name: []const u8) Status {
    return callStatus(state, switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.StackLimit => .stack_limit,
        error.CallDepth => .call_depth,
        error.Type => .type_error,
        error.Runtime => .runtime_error,
        error.Interrupted => .interrupted,
        error.InvalidNativeResult => .invalid_native_result,
        error.InvalidBytecode => .invalid_bytecode,
        error.PendingFeature => .pending_feature,
        // A C entry counts as a boundary, so a yield never unwinds through one.
        error.Yield => @panic(name ++ ": internal invariant violated: a yield crossed a C call"),
    }, name);
}

/// A C call's shape, checked without executing or changing the stack; the
/// public entry points abort, naming themselves, on a host's misuse.
pub const CallRequest = struct {
    arguments: usize,
    results: ?usize,
    handler: ?runtime.Value,

    pub const Error = error{ InvalidArgumentCount, InvalidResultCount, InvalidHandlerIndex, InvalidHandlerType };

    /// The callee precedes nargs visible slots; a nonzero handler index must name
    /// a function strictly below it. -1 requests every result; all other negative result counts are host misuse. No allocator,
    /// metatable lookup or function call is needed to validate the request.
    pub fn prepare(state: *const runtime.State, nargs: c_int, nresults: c_int, msgh: c_int) Error!CallRequest {
        if (nargs < 0) return error.InvalidArgumentCount;
        const count: usize = @intCast(nargs);
        if (count >= state.top()) return error.InvalidArgumentCount;
        if (nresults < -1) return error.InvalidResultCount;
        var handler: ?runtime.Value = null;
        if (msgh != 0) {
            const index = state.absoluteIndex(msgh) orelse return error.InvalidHandlerIndex;
            const callee = state.stack.items.len - count - 1;
            if (index >= callee) return error.InvalidHandlerIndex;
            const value = state.stack.items[index];
            if (!value.isFunction()) return error.InvalidHandlerType;
            handler = value;
        }
        return .{ .arguments = count, .results = if (nresults == -1) null else @intCast(nresults), .handler = handler };
    }
};

fn callPublic(maybe_state: ?*runtime.State, nargs: c_int, nresults: c_int, msgh: c_int, protected: bool, comptime name: []const u8) Status {
    return callWith(maybe_state, nargs, nresults, msgh, protected, null, name);
}

fn callWith(maybe_state: ?*runtime.State, nargs: c_int, nresults: c_int, msgh: c_int, protected: bool, waiting: ?@import("failure_transport.zig").Waiting, comptime name: []const u8) Status {
    const state = require(maybe_state, name);
    const request = CallRequest.prepare(state, nargs, nresults, msgh) catch |err| switch (err) {
        error.InvalidArgumentCount => @panic(name ++ ": invalid argument count or missing function slot"),
        error.InvalidResultCount => @panic(name ++ ": invalid result count"),
        error.InvalidHandlerIndex => @panic(name ++ ": handler must name a slot below the function"),
        error.InvalidHandlerType => @panic(name ++ ": handler must be a function"),
    };
    var diagnostic: ?@import("vm.zig").Diagnostic = null;
    const result = @import("failure_transport.zig").callContinued(state, request.arguments, request.results, protected, request.handler, waiting, &diagnostic) catch |err| {
        if (err == error.Yield) return .yielded;
        return operationError(state, err, name);
    };
    return switch (result) {
        .success => .ok,
        .failure => |kind| callStatus(state, kind, name),
    };
}

pub export fn nilu_call(maybe_state: ?*runtime.State, nargs: c_int, nresults: c_int) Status {
    return callPublic(maybe_state, nargs, nresults, 0, false, "nilu_call");
}

pub export fn nilu_pcall(maybe_state: ?*runtime.State, nargs: c_int, nresults: c_int, msgh: c_int) Status {
    return callPublic(maybe_state, nargs, nresults, msgh, true, "nilu_pcall");
}

/// nilu_pcall from a C function that a yield in the callee may suspend
/// (ADR 0013): then it answers NILU_YIELD, the C function returns
/// `nilu_yield(N, 0)`, and when the callee finishes after a resume, `k` runs
/// in the C function's place with the status nilu_pcall would have answered,
/// the stack as it would have left it, and `ctx`.
pub export fn nilu_pcallk(maybe_state: ?*runtime.State, nargs: c_int, nresults: c_int, msgh: c_int, ctx: isize, k: ?runtime.KFunction) Status {
    const continuation = k orelse @panic("nilu_pcallk: no continuation");
    return callWith(maybe_state, nargs, nresults, msgh, true, .{ .k = continuation, .context = ctx }, "nilu_pcallk");
}

/// Allocator is explicit inside Zig; a C host without one gets the default.
/// A state allocating through a byte count over `allocator`; nilu_close
/// frees both.
pub fn create(allocator: std.mem.Allocator) error{OutOfMemory}!*runtime.State {
    const count = try allocator.create(runtime.MemoryCount);
    errdefer {
        count.flush();
        allocator.destroy(count);
    }
    count.* = .{ .backing = allocator };
    const state = try allocator.create(runtime.State);
    errdefer allocator.destroy(state);
    state.* = try runtime.State.init(count.allocator());
    state.memory = count;
    return state;
}

fn require(state: ?*runtime.State, comptime name: []const u8) *runtime.State {
    return state orelse @panic(name ++ ": NiluState is NULL; check nilu_new's result");
}

// Only a Memory status returned inside this native entry affects bare NILU_FAIL.
// Explicit raises retain their own origin; completed and nested entries are separate.
fn memory(state: *runtime.State) Status {
    if (state.execution) |context| {
        if (state.frames.items.len != 0 and state.frames.items[state.frames.items.len - 1].function != .closure)
            context.api_memory_failure = true;
    }
    return .memory;
}

/// What a C operation answers: its value, or the origin of the failure a
/// metamethod it ran raised. It reuses the VM's semantics without a frame of
/// its own; an ordinary refusal is a status instead.
const OperationResult = union(enum) { success: runtime.Value, failure: *runtime.FailureOrigin };

fn runOperation(state: *runtime.State, operation: @import("vm.zig").Operation) @import("vm.zig").Error!OperationResult {
    const window = @import("execution_context.zig").Window.above(state);
    defer window.rollbackAndClose(state);
    var roots = [_]runtime.Value{ .nil, .nil, .nil };
    switch (operation) {
        .length => |value| roots[0] = value,
        .equal, .less, .less_equal => |values| @memcpy(roots[0..2], &values),
        .get => |values| @memcpy(roots[0..2], &values),
        .set => |values| roots = values,
    }
    // Reserve provenance before executing: publishing a carried failure must
    // not allocate after a handler has already produced it.
    const token = try state.reserveFailureOrigin();
    var published = false;
    defer if (!published) state.releaseFailureOrigin(token);
    // `begin` rather than a literal, which writes the held records too.
    var context: @import("execution_context.zig").Context = undefined;
    context.begin(window);
    context.roots = &roots;
    context.reserved_origin = token;
    context.enter(state);
    defer {
        context.leave(state, false);
        if (state.failure == null) state.failure = context.suspended.get();
    }
    var diagnostic: ?@import("vm.zig").Diagnostic = null;
    const value = @import("vm.zig").operate(state, operation, &diagnostic) catch |err| {
        switch (err) {
            error.PendingFeature, error.InvalidBytecode, error.InvalidNativeResult => return err,
            else => {},
        }
        if (state.failure == null) return err;
        @import("execution_location.zig").attachNativeCaller(state, &state.failure.?);
        const completed = @import("runtime_diagnostic.zig").complete(state, null, err);
        const propagated = @import("failure_transport.zig").dispatch(state, completed);
        switch (propagated) {
            error.PendingFeature, error.InvalidBytecode, error.InvalidNativeResult => return propagated,
            else => {},
        }
        state.barrier(&token.header);
        token.record = state.failure orelse return error.InvalidBytecode;
        state.publishFailureOrigin(token);
        published = true;
        return .{ .failure = token };
    };
    return .{ .success = value };
}

fn operatorQuery(state: *runtime.State, query: @import("vm.zig").Operation, comptime name: []const u8) Status {
    // Reserve before a handler can execute or return an unrooted result.
    const status = reservePush(state);
    if (status != .ok) return status;
    const result = runOperation(state, query) catch |err| return operationError(state, err, name);
    return switch (result) {
        .success => |value| blk: {
            state.stack.appendAssumeCapacity(value);
            break :blk .ok;
        },
        .failure => |token| blk: {
            const slot = state.stack.items.len;
            state.stack.appendAssumeCapacity(token.record.value);
            state.setOrigin(slot, token);
            break :blk callStatus(state, token.record.kind, name);
        },
    };
}

fn tableOperation(state: *runtime.State, operation: @import("vm.zig").Operation, consumed: usize, produces: bool, comptime name: []const u8) Status {
    const base = state.stack.items.len - consumed;
    if (consumed == 0) {
        const status = reservePush(state);
        if (status != .ok) return status;
    } else state.ensureOrigins(state.stack.items.len) catch return memory(state);
    const result = runOperation(state, operation) catch |err| return operationError(state, err, name);
    const has_value = produces or result == .failure;
    const final_top = base + @intFromBool(has_value);
    state.closeFrom(final_top);
    runtime.cutStack(&state.stack, base);
    return switch (result) {
        .success => |value| blk: {
            if (produces) {
                state.stack.appendAssumeCapacity(value);
                state.origins.items[base] = null;
            }
            break :blk .ok;
        },
        .failure => |token| blk: {
            state.stack.appendAssumeCapacity(token.record.value);
            state.setOrigin(base, token);
            break :blk callStatus(state, token.record.kind, name);
        },
    };
}

pub export fn nilu_gettable(maybe_state: ?*runtime.State, index: c_int) Status {
    const state = require(maybe_state, "nilu_gettable");
    const slot = requireIndex(state, index, "nilu_gettable");
    const key = state.get(-1) orelse @panic("nilu_gettable: no visible key");
    return tableOperation(state, .{ .get = .{ state.stack.items[slot], key } }, 1, true, "nilu_gettable");
}

pub export fn nilu_settable(maybe_state: ?*runtime.State, index: c_int) Status {
    const state = require(maybe_state, "nilu_settable");
    const slot = requireIndex(state, index, "nilu_settable");
    if (state.top() < 2) @panic("nilu_settable: no visible key/value pair");
    const values = state.stack.items;
    return tableOperation(state, .{ .set = .{ values[slot], values[values.len - 2], values[values.len - 1] } }, 2, false, "nilu_settable");
}

pub export fn nilu_getglobal(maybe_state: ?*runtime.State, maybe_name: ?[*:0]const u8) Status {
    const state = require(maybe_state, "nilu_getglobal");
    const name = maybe_name orelse @panic("nilu_getglobal: name is NULL");
    // Check the public result window before allocating the copied name.
    const status = reservePush(state);
    if (status != .ok) return status;
    const key = state.newString(std.mem.span(name)) catch return memory(state);
    return tableOperation(state, .{ .get = .{ .from(.{ .table = state.globals }), .from(.{ .string = key }) } }, 0, true, "nilu_getglobal");
}

pub export fn nilu_setglobal(maybe_state: ?*runtime.State, maybe_name: ?[*:0]const u8) Status {
    const state = require(maybe_state, "nilu_setglobal");
    const name = maybe_name orelse @panic("nilu_setglobal: name is NULL");
    const value = state.get(-1) orelse @panic("nilu_setglobal: no visible value");
    const key = state.newString(std.mem.span(name)) catch return memory(state);
    return tableOperation(state, .{ .set = .{ .from(.{ .table = state.globals }), .from(.{ .string = key }), value } }, 1, false, "nilu_setglobal");
}

/// t[key] for the value at `index` and a string key, as Lua's lua_getfield:
/// gettable with the key made from `key`, so `__index` runs as it would.
pub export fn nilu_getfield(maybe_state: ?*runtime.State, index: c_int, maybe_key: ?[*:0]const u8) Status {
    const state = require(maybe_state, "nilu_getfield");
    const slot = requireIndex(state, index, "nilu_getfield");
    const name = maybe_key orelse @panic("nilu_getfield: key is NULL");
    // Check the public result window before allocating the copied key.
    const status = reservePush(state);
    if (status != .ok) return status;
    const key = state.newString(std.mem.span(name)) catch return memory(state);
    return tableOperation(state, .{ .get = .{ state.stack.items[slot], .from(.{ .string = key }) } }, 0, true, "nilu_getfield");
}

/// t[key] = the top value, for the value at `index`, as Lua's lua_setfield:
/// settable with the key made from `key`, so `__newindex` runs as it would.
pub export fn nilu_setfield(maybe_state: ?*runtime.State, index: c_int, maybe_key: ?[*:0]const u8) Status {
    const state = require(maybe_state, "nilu_setfield");
    const slot = requireIndex(state, index, "nilu_setfield");
    const name = maybe_key orelse @panic("nilu_setfield: key is NULL");
    const value = state.get(-1) orelse @panic("nilu_setfield: no visible value");
    const key = state.newString(std.mem.span(name)) catch return memory(state);
    return tableOperation(state, .{ .set = .{ state.stack.items[slot], .from(.{ .string = key }), value } }, 1, false, "nilu_setfield");
}

pub export fn nilu_len(maybe_state: ?*runtime.State, index: c_int) Status {
    const state = require(maybe_state, "nilu_len");
    const slot = requireIndex(state, index, "nilu_len");
    return operatorQuery(state, .{ .length = state.stack.items[slot] }, "nilu_len");
}

pub export fn nilu_compare(maybe_state: ?*runtime.State, first: c_int, second: c_int, operation: c_int) Status {
    const state = require(maybe_state, "nilu_compare");
    const left = requireIndex(state, first, "nilu_compare");
    const right = requireIndex(state, second, "nilu_compare");
    const values = [2]runtime.Value{ state.stack.items[left], state.stack.items[right] };
    const query: @import("vm.zig").Operation = switch (operation) {
        0 => .{ .equal = values },
        1 => .{ .less = values },
        2 => .{ .less_equal = values },
        else => @panic("nilu_compare: invalid comparison operation"),
    };
    return operatorQuery(state, query, "nilu_compare");
}

pub export fn nilu_new() ?*runtime.State {
    return create(std.heap.smp_allocator) catch null;
}

const HostAllocator = @import("host_allocator.zig").HostAllocator;

/// A state whose memory comes from the host's `f` (Lua's lua_newstate).
/// NULL when even the state could not be allocated.
pub export fn nilu_newstate(f: ?@import("host_allocator.zig").Function, ud: ?*anyopaque) ?*runtime.State {
    const function = f orelse @panic("nilu_newstate: the allocation function is NULL");
    const block = function(ud, null, 0, @sizeOf(HostAllocator)) orelse return null;
    const host: *HostAllocator = @ptrCast(@alignCast(block));
    host.* = .{ .function = function, .data = ud };
    return create(host.allocator()) catch {
        _ = function(ud, block, @sizeOf(HostAllocator), 0);
        return null;
    };
}

pub export fn nilu_close(maybe_state: ?*runtime.State) void {
    const state = maybe_state orelse return;
    const count = state.memory.?;
    const allocator = count.backing;
    state.deinit();
    count.flush();
    allocator.destroy(state);
    allocator.destroy(count);
    // A host's allocator lives in a block of its own, freed last.
    if (allocator.vtable == &HostAllocator.vtable) {
        const host: *HostAllocator = @ptrCast(@alignCast(allocator.ptr));
        _ = host.function(host.data, host, @sizeOf(HostAllocator), 0);
    }
}

/// The collector for the host and for `collectgarbage`:
/// 0 collects; 1 answers the KiB in use in *out; 2 runs one step, which is a
/// whole collection, and answers 1 (a cycle finished); 3 answers 1 unless the
/// collector is stopped; 4 stops collections starting by themselves and 5
/// lets them again, both answering 0. Any other `what` answers TYPE.
pub export fn nilu_gc(maybe_state: ?*runtime.State, what: c_int, out: ?*f64) Status {
    const state = require(maybe_state, "nilu_gc");
    const answer: f64 = switch (what) {
        0 => blk: {
            state.collect();
            break :blk 0;
        },
        1 => if (state.memory) |count| @as(f64, @floatFromInt(count.in_use)) / 1024 else 0,
        2 => blk: {
            state.collect();
            break :blk 1;
        },
        3 => @floatFromInt(@intFromBool(!state.collector_stopped)),
        4, 5 => blk: {
            state.setCollectorStopped(what == 4);
            break :blk 0;
        },
        else => return .type,
    };
    if (out) |result| result.* = answer;
    return .ok;
}

pub export fn nilu_gettop(maybe_state: ?*runtime.State) c_int {
    return @intCast(require(maybe_state, "nilu_gettop").top());
}

pub export fn nilu_settop(maybe_state: ?*runtime.State, index: c_int) Status {
    const state = require(maybe_state, "nilu_settop");
    if (index >= 0) {
        // The common call, a count from the base: resolved once.
        const base = state.base();
        const count: usize = @intCast(index);
        if (count > runtime.State.max_stack - base) return .stack;
        const target = base + count;
        if (target == state.stack.items.len) return .ok;
        if (target < state.stack.items.len) {
            state.closeFrom(target);
            runtime.cutStack(&state.stack, target);
            return .ok;
        }
        state.ensureOrigins(target) catch return memory(state);
        state.setLength(target) catch |err| return switch (err) {
            error.OutOfMemory => memory(state),
            error.StackLimit => .stack,
        };
        return .ok;
    }
    // A pop, `nilu_pop(N, n)`: n values off the top, within the window.
    const remove: usize = @intCast(-(@as(i64, index) + 1));
    if (remove > state.top()) @panic("nilu_settop: index is below the visible stack bottom");
    const target = state.stack.items.len - remove;
    state.closeFrom(target);
    runtime.cutStack(&state.stack, target);
    return .ok;
}

fn pushValue(state: *runtime.State, value: runtime.Value) Status {
    state.push(value) catch |err| return switch (err) {
        error.OutOfMemory => memory(state),
        error.StackLimit => .stack,
    };
    return .ok;
}

pub export fn nilu_pushnil(maybe_state: ?*runtime.State) Status {
    return pushValue(require(maybe_state, "nilu_pushnil"), .nil);
}

pub export fn nilu_pushnumber(maybe_state: ?*runtime.State, value: f64) Status {
    return pushValue(require(maybe_state, "nilu_pushnumber"), .from(.{ .number = value }));
}

pub export fn nilu_tonumberx(maybe_state: ?*runtime.State, index: c_int, isnum: ?*c_int) f64 {
    const value = require(maybe_state, "nilu_tonumberx").get(index);
    const number = if (value) |found| found.numberValue() else null;
    if (isnum) |out| out.* = @intFromBool(number != null);
    return number orelse 0;
}

pub export fn nilu_pushinteger(maybe_state: ?*runtime.State, value: c_longlong) Status {
    const state = require(maybe_state, "nilu_pushinteger");
    const status = reservePush(state);
    if (status != .ok) return status;
    const integer = state.integer(value) catch return memory(state);
    state.stack.appendAssumeCapacity(integer);
    return .ok;
}

/// An integer, or a float that is one within 64 bits, as Lua's
/// lua_tointegerx; nothing else converts.
pub export fn nilu_tointegerx(maybe_state: ?*runtime.State, index: c_int, isnum: ?*c_int) c_longlong {
    const value = require(maybe_state, "nilu_tointegerx").get(index);
    const integer: ?i64 = if (value) |found| if (arithmetic.Number.of(found)) |number| number.asInteger() else null else null;
    if (isnum) |out| out.* = @intFromBool(integer != null);
    return integer orelse 0;
}

pub export fn nilu_isinteger(maybe_state: ?*runtime.State, index: c_int) c_int {
    const value = require(maybe_state, "nilu_isinteger").get(index) orelse return 0;
    return @intFromBool(value.is(.integer));
}

fn reservePush(state: *runtime.State) Status {
    if (state.stack.items.len >= runtime.State.max_stack) return .stack;
    state.ensureOrigins(state.stack.items.len + 1) catch return memory(state);
    runtime.growStack(&state.stack, state.open_cells.items, state.allocator, state.stack.items.len + 1) catch return memory(state);
    return .ok;
}

fn pushBytes(state: *runtime.State, bytes: []const u8) Status {
    const status = reservePush(state);
    if (status != .ok) return status;
    const string = state.newString(bytes) catch return memory(state);
    state.stack.appendAssumeCapacity(.from(.{ .string = string }));
    return .ok;
}

pub export fn nilu_pushlstring(maybe_state: ?*runtime.State, bytes: ?[*]const u8, length: usize) Status {
    const state = require(maybe_state, "nilu_pushlstring");
    if (length == 0) return pushBytes(state, "");
    const pointer = bytes orelse @panic("nilu_pushlstring: bytes is NULL with nonzero length");
    // newString needs one additional sentinel byte; never overflow on C input.
    if (length == std.math.maxInt(usize)) return memory(state);
    return pushBytes(state, pointer[0..length]);
}

pub export fn nilu_pushstring(maybe_state: ?*runtime.State, text: ?[*:0]const u8) Status {
    const state = require(maybe_state, "nilu_pushstring");
    const pointer = text orelse return nilu_pushnil(state);
    return pushBytes(state, std.mem.span(pointer));
}

// The C API's argument checks (Lua's luaL_check*, luaL_opt*, luaL_argerror
// and luaL_typeerror; the owner's answer). The
// sentences are the library's own, so a host's C function refuses an
// argument exactly as `string.rep` does. A check cannot leave the C function
// (no longjmp): it answers 0, or NILU_FAIL with the failure raised, which the
// C function returns.

/// A host's function has no registered name: Lua's `?` when the caller wrote
/// none either.
fn argumentCall(state: *runtime.State) @import("stdlib.zig").Call {
    return .{ .state = state, .name = "?" };
}

fn argumentAnswer(state: *runtime.State, result: @import("stdlib.zig").Error!void) c_int {
    result catch |err| return @import("stdlib.zig").failed(state, err);
    return 0;
}

pub export fn nilu_argerror(maybe_state: ?*runtime.State, arg: c_int, extramsg: ?[*:0]const u8) c_int {
    const state = require(maybe_state, "nilu_argerror");
    return @import("stdlib.zig").failed(state, argumentCall(state).argumentError(arg, std.mem.span(extramsg orelse "")));
}

pub export fn nilu_typeerror(maybe_state: ?*runtime.State, arg: c_int, tname: ?[*:0]const u8) c_int {
    const state = require(maybe_state, "nilu_typeerror");
    return @import("stdlib.zig").failed(state, argumentCall(state).typeError(arg, std.mem.span(tname orelse "?")));
}

pub export fn nilu_checkany(maybe_state: ?*runtime.State, arg: c_int) c_int {
    const state = require(maybe_state, "nilu_checkany");
    return argumentAnswer(state, argumentCall(state).checkAny(arg));
}

pub export fn nilu_checktype(maybe_state: ?*runtime.State, arg: c_int, t: c_int) c_int {
    const state = require(maybe_state, "nilu_checktype");
    const c = argumentCall(state);
    if (@backingInt(c.typeAt(arg)) == t) return 0;
    if (t < -1 or t > @backingInt(@import("stdlib.zig").Type.thread)) @panic("nilu_checktype: not a NILU_T* type");
    const kind: @import("stdlib.zig").Type = @fromBackingInt(@intCast(t));
    return @import("stdlib.zig").failed(state, c.typeError(arg, @import("stdlib.zig").typeName(kind)));
}

pub export fn nilu_checknumber(maybe_state: ?*runtime.State, arg: c_int, out: ?*f64) c_int {
    const state = require(maybe_state, "nilu_checknumber");
    const value = argumentCall(state).checkNumber(arg) catch |err| return @import("stdlib.zig").failed(state, err);
    (out orelse @panic("nilu_checknumber: out is NULL")).* = value;
    return 0;
}

pub export fn nilu_optnumber(maybe_state: ?*runtime.State, arg: c_int, default: f64, out: ?*f64) c_int {
    const state = require(maybe_state, "nilu_optnumber");
    const value = argumentCall(state).optNumber(arg, default) catch |err| return @import("stdlib.zig").failed(state, err);
    (out orelse @panic("nilu_optnumber: out is NULL")).* = value;
    return 0;
}

/// Any 64-bit integer, or a float with an integer value, as Lua's
/// luaL_checkinteger takes one.
pub export fn nilu_checkinteger(maybe_state: ?*runtime.State, arg: c_int, out: ?*c_longlong) c_int {
    const state = require(maybe_state, "nilu_checkinteger");
    const value = argumentCall(state).checkInteger(arg) catch |err| return @import("stdlib.zig").failed(state, err);
    (out orelse @panic("nilu_checkinteger: out is NULL")).* = value;
    return 0;
}

pub export fn nilu_optinteger(maybe_state: ?*runtime.State, arg: c_int, default: c_longlong, out: ?*c_longlong) c_int {
    const state = require(maybe_state, "nilu_optinteger");
    const value = argumentCall(state).optInteger(arg, default) catch |err| return @import("stdlib.zig").failed(state, err);
    (out orelse @panic("nilu_optinteger: out is NULL")).* = value;
    return 0;
}

/// The string's bytes, NUL-terminated, borrowed while the value is on the
/// stack, as nilu_tolstring's.
pub export fn nilu_checklstring(maybe_state: ?*runtime.State, arg: c_int, out: ?*[*:0]const u8, length: ?*usize) c_int {
    const state = require(maybe_state, "nilu_checklstring");
    _ = argumentCall(state).checkString(arg) catch |err| return @import("stdlib.zig").failed(state, err);
    (out orelse @panic("nilu_checklstring: out is NULL")).* = @import("c_api.zig").nilu_tolstring(state, arg, length).?;
    return 0;
}

/// With no argument or nil, `default` (borrowed from the caller) and its length.
pub export fn nilu_optlstring(maybe_state: ?*runtime.State, arg: c_int, default: ?[*:0]const u8, out: ?*[*:0]const u8, length: ?*usize) c_int {
    const state = require(maybe_state, "nilu_optlstring");
    const c = argumentCall(state);
    switch (c.typeAt(arg)) {
        .none, .nil => {
            const text = default orelse @panic("nilu_optlstring: default is NULL");
            (out orelse @panic("nilu_optlstring: out is NULL")).* = text;
            if (length) |l| l.* = std.mem.len(text);
            return 0;
        },
        else => return nilu_checklstring(state, arg, out, length),
    }
}

pub export fn nilu_tolstring(maybe_state: ?*runtime.State, index: c_int, length: ?*usize) ?[*:0]const u8 {
    const state = require(maybe_state, "nilu_tolstring");
    if (length) |out| out.* = 0;
    const absolute = state.absoluteIndex(index) orelse return null;
    const value = state.stack.items[absolute];
    const string = switch (value.unpack()) {
        .string => |string| string,
        .number => |number| blk: {
            var buffer: [64]u8 = undefined;
            const bytes = numeral.format(&buffer, number) catch @panic("nilu_tolstring: numeric buffer invariant");
            const string = state.newString(bytes) catch return null;
            state.stack.items[absolute] = .from(.{ .string = string });
            if (absolute < state.origins.items.len) state.origins.items[absolute] = null;
            break :blk string;
        },
        .integer => |number| blk: {
            var buffer: [64]u8 = undefined;
            const bytes = numeral.formatInteger(&buffer, number) catch @panic("nilu_tolstring: numeric buffer invariant");
            const string = state.newString(bytes) catch return null;
            state.stack.items[absolute] = .from(.{ .string = string });
            if (absolute < state.origins.items.len) state.origins.items[absolute] = null;
            break :blk string;
        },
        else => return null,
    };
    if (length) |out| out.* = string.bytes.len;
    return string.bytes.ptr;
}

pub export fn nilu_pushboolean(maybe_state: ?*runtime.State, value: c_int) Status {
    return pushValue(require(maybe_state, "nilu_pushboolean"), .from(.{ .boolean = value != 0 }));
}

pub export fn nilu_toboolean(maybe_state: ?*runtime.State, index: c_int) c_int {
    const value = require(maybe_state, "nilu_toboolean").get(index) orelse return 0;
    return @intFromBool(value.truthy());
}

fn requireIndex(state: *runtime.State, index: c_int, comptime name: []const u8) usize {
    return state.absoluteIndex(index) orelse @panic(name ++ ": index names no visible stack slot");
}

pub export fn nilu_pushvalue(maybe_state: ?*runtime.State, index: c_int) Status {
    const state = require(maybe_state, "nilu_pushvalue");
    // Copy the value before growth can relocate the source slot.
    const source = requireIndex(state, index, "nilu_pushvalue");
    const value = state.stack.items[source];
    const origin = state.originAt(source);
    const status = pushValue(state, value);
    if (status == .ok) state.setOrigin(state.stack.items.len - 1, origin);
    return status;
}

pub export fn nilu_copy(maybe_state: ?*runtime.State, from: c_int, to: c_int) void {
    const state = require(maybe_state, "nilu_copy");
    const source = requireIndex(state, from, "nilu_copy");
    const destination = requireIndex(state, to, "nilu_copy");
    state.stack.items[destination] = state.stack.items[source];
    if (destination < state.origins.items.len) state.setOrigin(destination, state.originAt(source));
}

pub export fn nilu_rotate(maybe_state: ?*runtime.State, index: c_int, count: c_int) void {
    const state = require(maybe_state, "nilu_rotate");
    const first = requireIndex(state, index, "nilu_rotate");
    const segment = state.stack.items[first..];
    // Widen before negation so INT_MIN is a named precondition failure.
    const signed: i64 = count;
    const magnitude: u64 = @intCast(if (signed < 0) -signed else signed);
    if (magnitude > segment.len) @panic("nilu_rotate: count exceeds the visible segment");
    const shift: usize = if (signed < 0) segment.len - @as(usize, @intCast(magnitude)) else @intCast(magnitude);
    rotate(runtime.Value, segment, shift);
    // No origin is at or above `origins_end`.
    if (state.origins.items.len == 0 or first >= state.origins_end) return;
    rotate(?*runtime.FailureOrigin, state.origins.items[first..state.stack.items.len], shift);
}

/// The last `shift` items of `items` moved to its front. By one either way,
/// as nilu_insert and nilu_remove do, it is one move rather than three
/// reversals.
fn rotate(comptime T: type, items: []T, shift: usize) void {
    if (shift == 0 or shift == items.len) return;
    if (shift == 1) {
        const last = items[items.len - 1];
        std.mem.copyBackwards(T, items[1..], items[0 .. items.len - 1]);
        items[0] = last;
    } else if (shift == items.len - 1) {
        const head = items[0];
        std.mem.copyForwards(T, items[0 .. items.len - 1], items[1..]);
        items[items.len - 1] = head;
    } else {
        std.mem.reverse(T, items[0 .. items.len - shift]);
        std.mem.reverse(T, items[items.len - shift ..]);
        std.mem.reverse(T, items);
    }
}

/// A new table with room for `narr` sequence elements and `nrec` other
/// fields (Lua's lua_createtable). Negative sizes abort.
pub export fn nilu_createtable(maybe_state: ?*runtime.State, narr: c_int, nrec: c_int) Status {
    const state = require(maybe_state, "nilu_createtable");
    if (narr < 0 or nrec < 0) @panic("nilu_createtable: negative size");
    const status = reservePush(state);
    if (status != .ok) return status;
    const table = state.newTableSized(@intCast(narr), @intCast(nrec)) catch return memory(state);
    state.stack.appendAssumeCapacity(.from(.{ .table = table }));
    return .ok;
}

pub export fn nilu_newtable(maybe_state: ?*runtime.State) Status {
    const state = require(maybe_state, "nilu_newtable");
    const status = reservePush(state);
    if (status != .ok) return status;
    const table = state.newTable() catch return memory(state);
    state.stack.appendAssumeCapacity(.from(.{ .table = table }));
    return .ok;
}

pub export fn nilu_newuserdata(maybe_state: ?*runtime.State, size: usize, block: ?*?*anyopaque) Status {
    const state = require(maybe_state, "nilu_newuserdata");
    if (block) |out| out.* = null;
    const status = reservePush(state);
    if (status != .ok) return status;
    // An allocation must also represent its alignment padding without wrapping.
    _ = std.math.add(usize, size, runtime.userdata_alignment) catch return memory(state);
    const userdata = state.newUserdata(size) catch return memory(state);
    state.stack.appendAssumeCapacity(.from(.{ .userdata = userdata }));
    if (block) |out| out.* = userdata.bytes.ptr;
    return .ok;
}

/// A userdata with `nuvalue` user values, all nil (Lua's lua_newuserdatauv).
pub export fn nilu_newuserdatauv(maybe_state: ?*runtime.State, size: usize, nuvalue: c_int, block: ?*?*anyopaque) Status {
    const state = require(maybe_state, "nilu_newuserdatauv");
    if (block) |out| out.* = null;
    if (nuvalue < 0) @panic("nilu_newuserdatauv: negative count of user values");
    const status = reservePush(state);
    if (status != .ok) return status;
    _ = std.math.add(usize, size, runtime.userdata_alignment) catch return memory(state);
    const userdata = state.newUserdataWith(size, @intCast(nuvalue)) catch return memory(state);
    state.stack.appendAssumeCapacity(.from(.{ .userdata = userdata }));
    if (block) |out| out.* = userdata.bytes.ptr;
    return .ok;
}

fn userValue(state: *runtime.State, index: c_int, n: c_int, comptime name: []const u8) ?*runtime.Value {
    const value = state.get(index) orelse @panic(name ++ ": no value at that index");
    if (!value.is(.userdata)) @panic(name ++ ": not a userdata");
    const values = value.unpack().userdata.user_values;
    if (n < 1 or @as(usize, @intCast(n)) > values.len) return null;
    return &values[@as(usize, @intCast(n)) - 1];
}

/// Pushes the userdata's n-th user value and answers its type; with no n-th,
/// pushes nil and answers NILU_TNONE.
pub export fn nilu_getiuservalue(maybe_state: ?*runtime.State, index: c_int, n: c_int) c_int {
    const state = require(maybe_state, "nilu_getiuservalue");
    const slot = userValue(state, index, n, "nilu_getiuservalue");
    if (reservePush(state) != .ok) return @backingInt(Type.none);
    state.stack.appendAssumeCapacity(if (slot) |found| found.* else .nil);
    if (slot == null) return @backingInt(Type.none);
    return nilu_type(state, -1);
}

/// Pops the top value into the userdata's n-th user value; answers 0 when it
/// has no n-th (the value is popped all the same).
pub export fn nilu_setiuservalue(maybe_state: ?*runtime.State, index: c_int, n: c_int) c_int {
    const state = require(maybe_state, "nilu_setiuservalue");
    const top = state.absoluteIndex(-1) orelse @panic("nilu_setiuservalue: no value to set");
    const slot = userValue(state, index, n, "nilu_setiuservalue");
    const owner = state.get(index).?.unpack().userdata;
    const value = state.stack.items[top];
    state.closeFrom(top);
    runtime.cutStack(&state.stack, top);
    const found = slot orelse return 0;
    state.barrier(&owner.header);
    found.* = value;
    return 1;
}

/// Pops the top value into the registry, a table only C reaches, and
/// answers its reference (Lua's luaL_ref): NILU_REFNIL for nil, NILU_NOREF
/// when there was no memory for it.
pub export fn nilu_ref(maybe_state: ?*runtime.State) c_int {
    const state = require(maybe_state, "nilu_ref");
    const top = state.absoluteIndex(-1) orelse @panic("nilu_ref: no value to keep");
    const value = state.stack.items[top];
    state.closeFrom(top);
    runtime.cutStack(&state.stack, top);
    if (value.is(.nil)) return -1;
    const reference = state.free_references.pop() orelse blk: {
        if (state.next_reference == std.math.maxInt(c_int)) return -2;
        defer state.next_reference += 1;
        break :blk state.next_reference;
    };
    state.barrier(&state.registry.header);
    state.registry.set(state.allocator, runtime.Value.fromCount(@intCast(reference)), value) catch {
        state.free_references.append(state.allocator, reference) catch {};
        return -2;
    };
    return reference;
}

/// Pushes what the reference holds; nil for NILU_REFNIL, NILU_NOREF or one
/// released.
pub export fn nilu_getref(maybe_state: ?*runtime.State, reference: c_int) Status {
    const state = require(maybe_state, "nilu_getref");
    const status = reservePush(state);
    if (status != .ok) return status;
    state.stack.appendAssumeCapacity(if (reference > 0) state.registry.get(runtime.Value.fromCount(@intCast(reference))) else .nil);
    return .ok;
}

/// Lets the reference go; it may be answered again by a later nilu_ref.
pub export fn nilu_unref(maybe_state: ?*runtime.State, reference: c_int) void {
    const state = require(maybe_state, "nilu_unref");
    if (reference <= 0) return;
    const key: runtime.Value = runtime.Value.fromCount(@intCast(reference));
    if (state.registry.get(key).is(.nil)) return;
    state.barrier(&state.registry.header);
    state.registry.set(state.allocator, key, .nil) catch {};
    state.free_references.append(state.allocator, reference) catch {};
}

pub export fn nilu_touserdata(maybe_state: ?*runtime.State, index: c_int) ?*anyopaque {
    const value = require(maybe_state, "nilu_touserdata").get(index) orelse return null;
    return if (value.is(.userdata)) value.unpack().userdata.bytes.ptr else null;
}

pub export fn nilu_rawlen(maybe_state: ?*runtime.State, index: c_int) Status {
    const state = require(maybe_state, "nilu_rawlen");
    const value = state.get(index) orelse runtime.Value.nil;
    const length: usize = switch (value.unpack()) {
        .string => |string| string.bytes.len,
        .table => |table| table.length(),
        .userdata => |userdata| userdata.bytes.len,
        else => 0,
    };
    return pushValue(state, runtime.Value.fromCount(length));
}

pub export fn nilu_rawequal(maybe_state: ?*runtime.State, first: c_int, second: c_int) c_int {
    const state = require(maybe_state, "nilu_rawequal");
    const left = state.get(first) orelse return 0;
    const right = state.get(second) orelse return 0;
    return @intFromBool(left.equal(right));
}

pub export fn nilu_stringtonumber(maybe_state: ?*runtime.State, bytes: ?[*]const u8, length: usize) Status {
    const state = require(maybe_state, "nilu_stringtonumber");
    const pointer = bytes orelse @panic("nilu_stringtonumber: bytes is NULL");
    return switch (numeral.parse(pointer[0..length]) orelse return .syntax) {
        .integer => |n| pushValue(state, state.integer(n) catch return memory(state)),
        .float => |f| pushValue(state, .from(.{ .number = f })),
    };
}

pub export fn nilu_topointer(maybe_state: ?*runtime.State, index: c_int) ?*const anyopaque {
    const value = require(maybe_state, "nilu_topointer").get(index) orelse return null;
    return switch (value.unpack()) {
        .string => |string| @ptrCast(string),
        .table => |table| @ptrCast(table),
        .userdata => |userdata| userdata.bytes.ptr,
        .native => |callback| @ptrFromInt(@intFromPtr(callback)),
        .c_closure => |closure| @ptrCast(closure),
        .closure => |closure| @ptrCast(closure),
        .thread => |thread| @ptrCast(thread),
        else => null,
    };
}

pub export fn nilu_next(maybe_state: ?*runtime.State, index: c_int, more: ?*c_int) Status {
    const state = require(maybe_state, "nilu_next");
    if (more) |out| out.* = 0;
    const slot = requireIndex(state, index, "nilu_next");
    const key = state.get(-1) orelse @panic("nilu_next: no visible key");
    const target = state.stack.items[slot];
    if (!target.is(.table)) return .type;
    const pair = target.unpack().table.next(key) catch return .runtime;
    if (pair) |entry| {
        const status = reservePush(state);
        if (status != .ok) return status;
        const top = state.stack.items.len;
        state.stack.items[top - 1] = entry.key;
        state.origins.items[top - 1] = null;
        state.stack.appendAssumeCapacity(entry.value);
        state.origins.items[top] = null;
        if (more) |out| out.* = 1;
    } else state.pop(1);
    return .ok;
}

pub export fn nilu_setmetatable(maybe_state: ?*runtime.State, index: c_int) Status {
    const state = require(maybe_state, "nilu_setmetatable");
    const slot = requireIndex(state, index, "nilu_setmetatable");
    const top = state.get(-1) orelse @panic("nilu_setmetatable: no visible metatable");
    const meta: ?*runtime.Table = switch (top.unpack()) {
        .nil => null,
        .table => |table| table,
        else => return .type,
    };
    state.setMetatable(state.stack.items[slot], meta) catch return .type;
    state.pop(1);
    return .ok;
}

/// Gives the state its reader (ADR 0003): the function on top, or nil to take
/// it away, popped. Any other value answers TYPE and stays.
pub export fn nilu_setreader(maybe_state: ?*runtime.State) Status {
    const state = require(maybe_state, "nilu_setreader");
    const top = state.get(-1) orelse @panic("nilu_setreader: no visible reader");
    if (!top.isFunction() and !top.is(.nil)) return .type;
    state.reader = top;
    state.pop(1);
    return .ok;
}

pub export fn nilu_getreader(maybe_state: ?*runtime.State) Status {
    const state = require(maybe_state, "nilu_getreader");
    return pushValue(state, state.reader);
}

/// Gives the state its writer for `print` (ADR 0003), as nilu_setreader does
/// its reader: the function on top, or nil, popped; anything else is TYPE.
pub export fn nilu_setwriter(maybe_state: ?*runtime.State) Status {
    const state = require(maybe_state, "nilu_setwriter");
    const top = state.get(-1) orelse @panic("nilu_setwriter: no visible writer");
    if (!top.isFunction() and !top.is(.nil)) return .type;
    state.writer = top;
    state.pop(1);
    return .ok;
}

pub export fn nilu_getwriter(maybe_state: ?*runtime.State) Status {
    const state = require(maybe_state, "nilu_getwriter");
    return pushValue(state, state.writer);
}

/// Replaces the `_ENV` of a function nilu_loadstring/nilu_loadnamed made with
/// the top value, popped. A chunk that reads no global has no `_ENV`, and is
/// left as it is. Any other function or value at the index answers TYPE.
pub export fn nilu_setenv(maybe_state: ?*runtime.State, index: c_int) Status {
    const state = require(maybe_state, "nilu_setenv");
    const slot = requireIndex(state, index, "nilu_setenv");
    const environment = state.get(-1) orelse @panic("nilu_setenv: no visible environment");
    const target = state.stack.items[slot];
    if (!target.is(.closure) or !target.asClosure().prototype.chunk) return .type;
    const closure = target.asClosure();
    if (closure.upvalues.len == 1) state.writeCell(closure.upvalues[0], environment);
    state.pop(1);
    return .ok;
}

pub export fn nilu_calledas(maybe_state: ?*runtime.State, length: ?*usize) ?[*:0]const u8 {
    const state = require(maybe_state, "nilu_calledas");
    if (length) |out| out.* = 0;
    const site = state.nativeCallSite() orelse return null;
    const text = site.text() orelse return null;
    if (length) |out| out.* = text.len;
    return text.ptr;
}

pub export fn nilu_getmetatable(maybe_state: ?*runtime.State, index: c_int) Status {
    const state = require(maybe_state, "nilu_getmetatable");
    const value = state.get(index) orelse runtime.Value.nil;
    const meta = switch (value.unpack()) {
        .table => |table| table.metatable,
        .userdata => |userdata| userdata.metatable,
        .string => state.string_metatable,
        else => null,
    };
    return pushValue(state, if (meta) |table| .from(.{ .table = table }) else .nil);
}

/// The metamethod the VM would find for the value at the index: raw in its
/// metatable, then along the table-valued `__index` links of that metatable's
/// own metatable (manual 7.4), nothing run. Pushes the value, or nil when
/// there is none or the value has no metatable. RUNTIME, pushing nothing, when
/// the chain is longer than the VM follows. The library reads `__tostring`,
/// `__name` and `__pairs` through this entry (ADR 0010, ADR 0012).
pub export fn nilu_getmetafield(maybe_state: ?*runtime.State, index: c_int, maybe_name: ?[*:0]const u8) Status {
    const state = require(maybe_state, "nilu_getmetafield");
    const name = maybe_name orelse @panic("nilu_getmetafield: name is NULL");
    const value = state.get(index) orelse runtime.Value.nil;
    const found = @import("vm.zig").metafield(state, value, std.mem.span(name)) catch return .runtime;
    return pushValue(state, found);
}

pub export fn nilu_pushcfunction(maybe_state: ?*runtime.State, maybe_callback: ?runtime.Native) Status {
    const state = require(maybe_state, "nilu_pushcfunction");
    const callback = maybe_callback orelse @panic("nilu_pushcfunction: callback is NULL");
    return pushValue(state, .fromFunction(.{ .native = callback }));
}

pub export fn nilu_pushcclosure(maybe_state: ?*runtime.State, maybe_callback: ?runtime.Native, n: c_int) Status {
    const state = require(maybe_state, "nilu_pushcclosure");
    const callback = maybe_callback orelse @panic("nilu_pushcclosure: callback is NULL");
    if (n < 0 or n > runtime.State.max_upvalues) @panic("nilu_pushcclosure: upvalue count is outside 0..255");
    const count: usize = @intCast(n);
    if (count > state.top()) @panic("nilu_pushcclosure: count exceeds visible values");
    if (count == 0) return pushValue(state, .fromFunction(.{ .native = callback }));
    const base = state.stack.items.len - count;
    const function = state.newCClosure(callback, state.stack.items[base..]) catch |err| return switch (err) {
        error.OutOfMemory => memory(state),
        error.TooManyUpvalues => unreachable,
    };
    state.closeFrom(base);
    runtime.cutStack(&state.stack, base);
    state.stack.appendAssumeCapacity(.fromFunction(function));
    return .ok;
}

fn currentUpvalue(state: *runtime.State, n: c_int) ?*runtime.Value {
    const frame = state.frames.getLastOrNull() orelse return null;
    if (frame.function != .c_closure) return null;
    const values = frame.function.c_closure.upvalues;
    if (n <= 0 or @as(u64, @intCast(n)) > values.len) return null;
    return &values[@as(usize, @intCast(n)) - 1];
}

pub export fn nilu_getupvalue(maybe_state: ?*runtime.State, n: c_int) Status {
    const state = require(maybe_state, "nilu_getupvalue");
    const value = currentUpvalue(state, n) orelse return .type;
    return pushValue(state, value.*);
}

pub export fn nilu_setupvalue(maybe_state: ?*runtime.State, n: c_int) Status {
    const state = require(maybe_state, "nilu_setupvalue");
    const destination = currentUpvalue(state, n) orelse return .type;
    const value = state.get(-1) orelse @panic("nilu_setupvalue: no visible value to store");
    state.barrier(&state.frames.getLast().function.c_closure.header);
    destination.* = value;
    state.pop(1);
    return .ok;
}

/// Opens the standard library (ADR 0010): the base functions and the string,
/// table, math and utf8 tables, each made afresh and assigned on every call,
/// as luaL_openlibs does (the owner's answer of 2026-10-30). A status other
/// than OK leaves what was assigned before it and nothing on the stack.
pub export fn nilu_openlibs(maybe_state: ?*runtime.State) Status {
    const state = require(maybe_state, "nilu_openlibs");
    state.protected_call = .fromFunction(.{ .native = @import("stdlib.zig").protected_call });
    return @import("stdlib.zig").open(state);
}

/// Opens only the libraries whose NILU_LIB_* bits are set (Lua's
/// luaL_openselectedlibs, without its preload part); unknown bits are ignored.
pub export fn nilu_openselectedlibs(maybe_state: ?*runtime.State, libs: c_int) Status {
    const state = require(maybe_state, "nilu_openselectedlibs");
    state.protected_call = .fromFunction(.{ .native = @import("stdlib.zig").protected_call });
    return @import("stdlib.zig").openSelected(state, libs);
}

/// Observer installation. The callback may call back into this state.
pub export fn nilu_sethook(maybe_state: ?*runtime.State, hook: ?runtime.Hook, count: c_uint) void {
    require(maybe_state, "nilu_sethook").setHook(hook, count);
}

/// Explicitly marks this callback's failure; bare NILU_FAIL is distinct.
pub export fn nilu_error(maybe_state: ?*runtime.State) c_int {
    const state = require(maybe_state, "nilu_error");
    const slot = state.absoluteIndex(-1) orelse @panic("nilu_error: no visible failure value");
    const record = if (state.originAt(slot)) |origin| origin.record else runtime.FailureRecord{ .kind = .runtime_error, .value = state.stack.items[slot], .origin = .native };
    state.failure = record;
    if (state.execution) |context| context.raised.put(record);
    return fail;
}

// Coroutines (ADR 0013): a thread is a value on the stack.

fn threadAt(state: *runtime.State, index: c_int) ?*runtime.Thread {
    const value = state.get(index) orelse return null;
    return if (value.is(.thread)) value.unpack().thread else null;
}

/// Replaces the function on top with a thread that will run it.
pub export fn nilu_newthread(maybe_state: ?*runtime.State) Status {
    const state = require(maybe_state, "nilu_newthread");
    const slot = state.absoluteIndex(-1) orelse @panic("nilu_newthread: no function on the stack");
    const function = state.stack.items[slot];
    if (!function.isFunction()) return .type;
    const thread = state.newThread(function) catch return memory(state);
    state.stack.items[slot] = .from(.{ .thread = thread });
    return .ok;
}

/// Resumes the thread at `index` with the top `nargs` values, which it
/// consumes. Pushes the values the thread returned (NILU_OK) or yielded
/// (NILU_YIELD) and stores their count, or pushes its failure value and
/// answers the failure's status.
pub export fn nilu_resume(maybe_state: ?*runtime.State, index: c_int, nargs: c_int, nresults: ?*c_int) Status {
    const state = require(maybe_state, "nilu_resume");
    if (nresults) |out| out.* = 0;
    if (nargs < 0 or nargs > state.top()) @panic("nilu_resume: invalid argument count");
    const thread = threadAt(state, index) orelse return .type;
    const count: usize = @intCast(nargs);
    if (thread.status != .suspended) {
        state.closeFrom(state.stack.items.len - count);
        runtime.cutStack(&state.stack, state.stack.items.len - count);
        const status = pushBytes(state, if (thread.status == .dead) "cannot resume dead coroutine" else "cannot resume non-suspended coroutine");
        if (status != .ok) return status;
        if (nresults) |out| out.* = 1;
        return .runtime;
    }
    const outcome = @import("coroutine.zig").resumeThread(state, thread, count) catch |err| return switch (err) {
        error.OutOfMemory => memory(state),
        error.StackLimit => .stack,
        error.InvalidBytecode => @panic("nilu_resume: internal bytecode invariant violated"),
        error.InvalidNativeResult => @panic("nilu_resume: native callback returned an invalid result count"),
        error.PendingFeature => @panic("nilu_resume: execution path is not implemented"),
    };
    switch (outcome) {
        .finished => |n| {
            if (nresults) |out| out.* = @intCast(n);
            return .ok;
        },
        .yielded => |n| {
            if (nresults) |out| out.* = @intCast(n);
            return .yielded;
        },
        .failed => |kind| {
            if (nresults) |out| out.* = 1;
            // The coroutine ran on its own thread, whose flag its own entry
            // cleared. Inside a host's call the interruption still stops the
            // program, so the resuming thread takes it up: the C function
            // that resumed cannot answer it away. A host's own resume gets
            // the status alone; a flag left set would stop its next call.
            if (kind == .interrupted and state.execution != null) state.interrupted = true;
            return callStatus(state, kind, "nilu_resume");
        },
    }
}

/// `return nilu_yield(N, n)` from a C function suspends the running
/// coroutine, giving it the top `n` values. Refused, with Lua's sentence,
/// outside a coroutine or under a boundary a resume cannot return through.
pub export fn nilu_yield(maybe_state: ?*runtime.State, nresults: c_int) c_int {
    const state = require(maybe_state, "nilu_yield");
    // After nilu_pcallk answered NILU_YIELD: the yield is already under way.
    if (state.yielding) return @import("native.zig").yield_result;
    if (nresults < 0 or nresults > state.top()) @panic("nilu_yield: invalid result count");
    const in_native = state.frames.items.len != 0 and state.frames.items[state.frames.items.len - 1].function != .closure;
    const refusal: ?[]const u8 = if (state.running == state.main_thread)
        "attempt to yield from outside a coroutine"
    else if (state.non_yieldable > 0 or !in_native)
        "attempt to yield across a C-call boundary"
    else
        null;
    if (refusal) |sentence| {
        if (pushBytes(state, sentence) != .ok) return fail;
        return nilu_error(state);
    }
    state.yielding = true;
    state.yielded = @intCast(nresults);
    return @import("native.zig").yield_result;
}

/// NILU_THREAD_SUSPENDED, _RUNNING, _NORMAL or _DEAD; -1 if not a thread.
pub export fn nilu_threadstatus(maybe_state: ?*runtime.State, index: c_int) c_int {
    const state = require(maybe_state, "nilu_threadstatus");
    const thread = threadAt(state, index) orelse return -1;
    return switch (thread.status) {
        .suspended => 0,
        .running => 1,
        .normal => 2,
        .dead => 3,
    };
}

/// Pushes the running thread; answers 1 when it is the main program's.
pub export fn nilu_pushrunning(maybe_state: ?*runtime.State) c_int {
    const state = require(maybe_state, "nilu_pushrunning");
    if (reservePush(state) != .ok) return -1;
    state.stack.appendAssumeCapacity(.from(.{ .thread = state.running }));
    return @intFromBool(state.running == state.main_thread);
}

/// Whether the thread at `index` can yield: never the main program's; the
/// running one only where a C function may yield now; any other coroutine.
/// -1 if not a thread.
pub export fn nilu_isyieldable(maybe_state: ?*runtime.State, index: c_int) c_int {
    const state = require(maybe_state, "nilu_isyieldable");
    const thread = threadAt(state, index) orelse return -1;
    if (thread == state.main_thread) return 0;
    if (thread == state.running) return @intFromBool(state.non_yieldable == 0);
    return 1;
}

/// Closes the suspended or dead thread at `index`: NILU_OK, or the status of
/// the failure it died by with that value pushed. A running or normal thread,
/// or the main one, is refused with NILU_ERR_RUNTIME and Lua's sentence.
pub export fn nilu_closethread(maybe_state: ?*runtime.State, index: c_int) Status {
    const state = require(maybe_state, "nilu_closethread");
    const thread = threadAt(state, index) orelse return .type;
    const refusal: ?[]const u8 = if (thread == state.main_thread)
        "cannot close main thread"
    else switch (thread.status) {
        .running => "cannot close a running coroutine",
        .normal => "cannot close a normal coroutine",
        .suspended, .dead => null,
    };
    if (refusal) |sentence| {
        const status = pushBytes(state, sentence);
        return if (status != .ok) status else .runtime;
    }
    const status = reservePush(state);
    if (status != .ok) return status;
    const failure = @import("coroutine.zig").close(state, thread) orelse return .ok;
    state.stack.appendAssumeCapacity(failure);
    return .runtime;
}

pub export fn nilu_type(maybe_state: ?*runtime.State, index: c_int) c_int {
    const state = require(maybe_state, "nilu_type");
    const value = state.get(index) orelse return @backingInt(Type.none);
    // The kind alone: unpacking would read a boxed integer's value too.
    return @backingInt(switch (value.kind()) {
        .nil => Type.nil,
        .number, .integer => Type.number,
        .native, .c_closure, .closure => Type.function,
        .boolean => Type.boolean,
        .string => Type.string,
        .table => Type.table,
        .userdata => Type.userdata,
        .thread => Type.thread,
    });
}

pub export fn nilu_rawget(maybe_state: ?*runtime.State, index: c_int) Status {
    const state = require(maybe_state, "nilu_rawget");
    const target = state.get(index) orelse @panic("nilu_rawget: index names no visible slot");
    const key = state.get(-1) orelse @panic("nilu_rawget: no visible key");
    if (!target.is(.table)) return .type;
    state.closeFrom(state.stack.items.len - 1);
    state.stack.items[state.stack.items.len - 1] = target.unpack().table.get(key);
    return .ok;
}

pub export fn nilu_rawset(maybe_state: ?*runtime.State, index: c_int) Status {
    const state = require(maybe_state, "nilu_rawset");
    const target = state.get(index) orelse @panic("nilu_rawset: index names no visible slot");
    const key = state.get(-2) orelse @panic("nilu_rawset: no visible key/value pair");
    const value = state.get(-1) orelse unreachable;
    if (!target.is(.table)) return .type;
    const stored_key = state.storedKey(key) catch return memory(state);
    state.barrier(&target.unpack().table.header);
    target.unpack().table.set(state.allocator, stored_key, value) catch |err| return switch (err) {
        error.InvalidKey => .type,
        error.OutOfMemory => memory(state),
    };
    state.pop(2);
    return .ok;
}

fn loadSource(maybe_state: ?*runtime.State, source: ?[*:0]const u8, name: ?[*:0]const u8, where: ?*ErrorLocation, comptime api_name: []const u8) Status {
    const state = require(maybe_state, api_name);
    const text = source orelse @panic(api_name ++ ": source is NULL");
    const chunk_name = name orelse @panic(api_name ++ ": name is NULL");
    var diagnostic: ?@import("loader.zig").Diagnostic = null;
    const result = @import("loader.zig").loadLocated(state, std.mem.span(text), std.mem.span(chunk_name), &diagnostic, where) catch |err| return switch (err) {
        error.OutOfMemory => memory(state),
        error.StackLimit => .stack,
        // Source refusals are already rendered by loadLocated. These indicate
        // broken internal AST/diagnostic invariants, never a new public status.
        else => @panic(api_name ++ ": internal loader invariant violated"),
    };
    return if (result == .loaded) .ok else .syntax;
}

pub export fn nilu_loadstring(maybe_state: ?*runtime.State, source: ?[*:0]const u8, where: ?*ErrorLocation) Status {
    return loadSource(maybe_state, source, source, where, "nilu_loadstring");
}

pub export fn nilu_loadnamed(maybe_state: ?*runtime.State, source: ?[*:0]const u8, name: ?[*:0]const u8, where: ?*ErrorLocation) Status {
    return loadSource(maybe_state, source, name, where, "nilu_loadnamed");
}

/// Static classification of the current native's bytecode call site. Host and
/// metamethod entries have no classification. No allocation or stack change.
pub export fn nilu_namewhat(maybe_state: ?*runtime.State) ?[*:0]const u8 {
    const state = require(maybe_state, "nilu_namewhat");
    const site = state.nativeCallSite() orelse return null;
    return debug_info.kindWord(site.classification() orelse return null);
}

const debug_info = @import("debug_info.zig");

/// The call site of the function running at `level` (counted as nilu_where
/// counts): a native's own record, or the call instruction its script
/// caller is executing.
fn frameCallSite(state: *const runtime.State, level: c_int) ?runtime.CallSite {
    if (level <= 0) return null;
    _ = @import("execution_location.zig").callerFrame(state, @intCast(level)) orelse return null;
    const frames = state.frames.items;
    return @import("debug_info.zig").callSite(frames, frames.len - 1 - @as(usize, @intCast(level)));
}

pub const Debug = @import("debug_info.zig").Debug;

/// Lua's lua_getstack and lua_getinfo in one. Fills `ar` about the function
/// at `level` of the thread at stack index `thread` (0: the running one),
/// counted as nilu_where counts, the running thread's level 0 being the C
/// function asking; or, with `what` starting with '>', about the function on
/// top, which it pops. The letters after it pick what is filled as Lua's do
/// (S l n u t r); 'f' pushes the function and 'L' a table of the lines that
/// have code (nil for a C function). Answers 1, 0 when there is no such
/// level, or -1 for a letter it does not know.
pub export fn nilu_getinfo(maybe_state: ?*runtime.State, thread: c_int, level: c_int, what: ?[*:0]const u8, ar: ?*Debug) c_int {
    const state = require(maybe_state, "nilu_getinfo");
    const info = @import("debug_info.zig");
    const out = ar orelse @panic("nilu_getinfo: ar is NULL");
    var options = std.mem.span(what orelse @panic("nilu_getinfo: what is NULL"));
    var function: runtime.Function = undefined;
    if (options.len > 0 and options[0] == '>') {
        options = options[1..];
        if (!info.validOptions(options)) return -1;
        const slot = state.absoluteIndex(-1) orelse @panic("nilu_getinfo: no function on the stack");
        function = state.stack.items[slot].asFunction() orelse @panic("nilu_getinfo: '>' needs a function on top");
        runtime.cutStack(&state.stack, slot);
        info.describeFunction(function, out);
    } else {
        if (!info.validOptions(options)) return -1;
        const frames = if (thread == 0) state.frames.items else (threadAt(state, thread) orelse @panic("nilu_getinfo: no thread at that index")).saved.frames.items;
        if (thread != 0 and threadAt(state, thread).? == state.running) return nilu_getinfo(state, 0, level, what, ar);
        if (level < 0 or @as(usize, @intCast(level)) >= frames.len) return 0;
        const index = frames.len - 1 - @as(usize, @intCast(level));
        info.describeFrame(frames, index, out);
        function = frames[index].function;
    }
    if (std.mem.indexOfScalar(u8, options, 'f') != null) {
        if (reservePush(state) != .ok) return -1;
        state.stack.appendAssumeCapacity(.fromFunction(function));
    }
    if (std.mem.indexOfScalar(u8, options, 'L') != null) {
        if (reservePush(state) != .ok) return -1;
        if (function != .closure) {
            state.stack.appendAssumeCapacity(.nil);
        } else {
            const table = state.newTable() catch return -1;
            state.stack.appendAssumeCapacity(.from(.{ .table = table }));
            for (function.closure.prototype.code) |instruction| {
                state.barrier(&table.header);
                table.set(state.allocator, runtime.Value.fromCount(instruction.info.position.line), .true) catch return -1;
            }
        }
    }
    return 1;
}

/// The name the function at `level` was called by, for a traceback (Lua's
/// lua_getinfo "n"); NULL when it has none. *namewhat, when given, is the
/// kind of name as nilu_namewhat words it, or "" with no name. Borrowed as
/// nilu_calledas's name is.
pub export fn nilu_callername(maybe_state: ?*runtime.State, level: c_int, namewhat: ?*[*:0]const u8) ?[*:0]const u8 {
    const state = require(maybe_state, "nilu_callername");
    if (namewhat) |out| out.* = "";
    const site = frameCallSite(state, level) orelse return null;
    const kind = site.classification() orelse return null;
    const text = site.text() orelse return null;
    if (namewhat) |out| out.* = debug_info.kindWord(kind);
    return text.ptr;
}

/// The line where the function at `level` was defined: 0 for a chunk, -1 for
/// a native or a level with no function.
pub export fn nilu_linedefined(maybe_state: ?*runtime.State, level: c_int) c_int {
    const state = require(maybe_state, "nilu_linedefined");
    if (level <= 0) return -1;
    const frame = @import("execution_location.zig").callerFrame(state, @intCast(level)) orelse return -1;
    if (frame.function != .closure) return -1;
    const prototype = frame.function.closure.prototype;
    if (prototype.chunk) return 0;
    return std.math.cast(c_int, prototype.line_defined) orelse 0;
}

/// Owner-confirmed: repeated queries retain earlier names. Live names
/// belong to prototypes (or static [C]); completed failures have dedicated state
/// storage independent of protected capture and propagating failure records.
pub export fn nilu_where(maybe_state: ?*runtime.State, level: c_int, where: ?*ErrorLocation) ?[*:0]const u8 {
    const state = require(maybe_state, "nilu_where");
    if (where) |out| out.* = .{};
    if (level < 0) return null;
    if (level == 0) {
        if (!state.has_last_call_location) return null;
        const location = &state.call_locations.items[state.last_call_location_index];
        if (where) |out| out.line = std.math.cast(c_int, location.line) orelse 0;
        return @ptrCast(&location.chunk);
    }
    const frame = @import("execution_location.zig").callerFrame(state, @intCast(level)) orelse return null;
    if (frame.function != .closure) return "[C]";
    const position = frame.position() orelse return null;
    if (where) |out| out.line = std.math.cast(c_int, position.line) orelse 0;
    return @ptrCast(&frame.function.closure.prototype.display_id);
}
