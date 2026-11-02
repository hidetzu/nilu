//! The standard library (ADR 0010): host functions that read and write values
//! only through the C API in include/nilu.h, registered the way a host registers
//! its own, so a host can replace or leave out any of them. The two stateless
//! helpers shared with the core are the number spelling (reached through
//! nilu_tolstring) and the UTF-8 encoder (utf8.encode). Memory for a result
//! under construction is a userdata the state owns (`Buffer`), never a global
//! allocator. `open` is what nilu_openlibs does: base functions, then the
//! string, table, math and utf8 tables, then `load`, `require`, `dofile`,
//! `loadfile` and `package`, each made afresh and assigned on every call (the
//! owner's answer of 2026-10-30).
const std = @import("std");
const api = @import("c_api.zig");
const runtime = @import("runtime.zig");
const string_library = @import("stdlib_string.zig");
const table_library = @import("stdlib_table.zig");
const math_library = @import("stdlib_math.zig");
const utf8_library = @import("stdlib_utf8.zig");
const package_library = @import("stdlib_package.zig");
const coroutine_library = @import("stdlib_coroutine.zig");
const debug_library = @import("stdlib_debug.zig");

pub const State = runtime.State;
pub const Native = runtime.Native;
/// `Raised`: the failure value is on top and the entry answers nilu_error.
/// `OutOfMemory`/`Stack`: an API call could not allocate or grow; the entry
/// answers with the prepared sentence when it can push it, else NILU_FAIL.
pub const Error = error{ Raised, OutOfMemory, Stack };

pub const Type = enum(c_int) { none = -1, nil = 0, number = 1, function = 2, boolean = 3, string = 4, table = 5, userdata = 6, thread = 7 };
pub const multret: c_int = -1;

/// One library function's invocation: the state and the registered name, which
/// names the function in a refusal when the caller's code gave it no name.
pub const Call = struct {
    state: *State,
    name: []const u8,

    pub fn top(call: Call) c_int {
        return api.nilu_gettop(call.state);
    }
    pub fn typeAt(call: Call, index: c_int) Type {
        return @fromBackingInt(@intCast(api.nilu_type(call.state, index)));
    }
    pub fn check(call: Call, status: api.Status) Error!void {
        _ = call;
        return switch (status) {
            .ok => {},
            .memory => error.OutOfMemory,
            .stack => error.Stack,
            // A metamethod or a callee failed; the carried value is on top.
            else => error.Raised,
        };
    }
    pub fn push(call: Call, text: []const u8) Error!void {
        try call.check(api.nilu_pushlstring(call.state, text.ptr, text.len));
    }
    /// Whether the value is the integer subtype (`nilu_isinteger`).
    pub fn isIntegerAt(call: Call, index: c_int) bool {
        return api.nilu_isinteger(call.state, index) != 0;
    }
    /// A float that is an integer within 64 bits as that integer, else the
    /// float, as Lua's math.floor and ceil answer (lua_Number2Integer).
    pub fn pushFloatAsInteger(call: Call, value: f64) Error!void {
        if (@import("runtime.zig").floatToInteger(value)) |whole| return call.pushInteger(whole);
        try call.pushNumber(value);
    }
    pub fn pushInteger(call: Call, value: i64) Error!void {
        try call.check(api.nilu_pushinteger(call.state, value));
    }
    pub fn pushNumber(call: Call, value: f64) Error!void {
        try call.check(api.nilu_pushnumber(call.state, value));
    }
    pub fn pushValue(call: Call, index: c_int) Error!void {
        try call.check(api.nilu_pushvalue(call.state, index));
    }
    pub fn pushNil(call: Call) Error!void {
        try call.check(api.nilu_pushnil(call.state));
    }
    pub fn pushBoolean(call: Call, value: bool) Error!void {
        try call.check(api.nilu_pushboolean(call.state, @intFromBool(value)));
    }
    pub fn pushFunction(call: Call, function: Native) Error!void {
        try call.check(api.nilu_pushcfunction(call.state, function));
    }
    pub fn setTop(call: Call, index: c_int) Error!void {
        try call.check(api.nilu_settop(call.state, index));
    }
    pub fn pop(call: Call, count: c_int) void {
        // Shrinking never fails; the status is the precondition's only.
        _ = api.nilu_settop(call.state, -count - 1);
    }
    pub fn remove(call: Call, index: c_int) void {
        api.nilu_rotate(call.state, index, -1);
        call.pop(1);
    }
    pub fn insert(call: Call, index: c_int) void {
        api.nilu_rotate(call.state, index, 1);
    }
    /// The bytes of a string slot, borrowed while the value stays on the stack.
    pub fn bytesAt(call: Call, index: c_int) []const u8 {
        var length: usize = 0;
        const text = api.nilu_tolstring(call.state, index, &length) orelse return "";
        return text[0..length];
    }
    pub fn numberAt(call: Call, index: c_int) f64 {
        return api.nilu_tonumberx(call.state, index, null);
    }
    pub fn truthy(call: Call, index: c_int) bool {
        return api.nilu_toboolean(call.state, index) != 0;
    }

    // Argument checks. The sentences are Lua 5.5's, as 10.6 of the manual says.
    pub fn checkAny(call: Call, index: c_int) Error!void {
        if (call.typeAt(index) == .none) return call.argumentError(index, "value expected");
    }
    pub fn checkString(call: Call, index: c_int) Error![]const u8 {
        if (call.typeAt(index) != .string) return call.typeError(index, "string");
        return call.bytesAt(index);
    }
    pub fn optString(call: Call, index: c_int, default: []const u8) Error![]const u8 {
        return switch (call.typeAt(index)) {
            .none, .nil => default,
            else => call.checkString(index),
        };
    }
    pub fn checkNumber(call: Call, index: c_int) Error!f64 {
        if (call.typeAt(index) != .number) return call.typeError(index, "number");
        return call.numberAt(index);
    }
    pub fn optNumber(call: Call, index: c_int, default: f64) Error!f64 {
        return switch (call.typeAt(index)) {
            .none, .nil => default,
            else => call.checkNumber(index),
        };
    }
    /// An integer, or a float that is one within 64 bits; another float
    /// has no integer representation, as Lua says.
    pub fn checkInteger(call: Call, index: c_int) Error!i64 {
        _ = try call.checkNumber(index);
        var isnum: c_int = 0;
        const value = api.nilu_tointegerx(call.state, index, &isnum);
        if (isnum == 0) return call.argumentError(index, "number has no integer representation");
        return value;
    }
    pub fn optInteger(call: Call, index: c_int, default: i64) Error!i64 {
        return switch (call.typeAt(index)) {
            .none, .nil => default,
            else => call.checkInteger(index),
        };
    }
    pub fn checkTable(call: Call, index: c_int) Error!void {
        if (call.typeAt(index) != .table) return call.typeError(index, "table");
    }
    pub fn checkFunction(call: Call, index: c_int) Error!void {
        if (call.typeAt(index) != .function) return call.typeError(index, "function");
    }

    /// `bad argument #n to 'name' (expected expected, got actual)`; the actual
    /// name is the value's `__name` when it has one, as Lua's luaL_typeerror.
    pub fn typeError(call: Call, index: c_int, expected: []const u8) Error {
        var buffer: [256]u8 = undefined;
        const actual = call.typeNameAt(index, &buffer);
        var sentence: [320]u8 = undefined;
        const text = std.fmt.bufPrint(&sentence, "{s} expected, got {s}", .{ expected, actual }) catch return call.argumentError(index, "bad type");
        return call.argumentError(index, text);
    }
    /// The name of the value's type for a sentence, "no value" for an absent
    /// slot; a `__name` string on the metatable stands in for table/userdata.
    pub fn typeNameAt(call: Call, index: c_int, buffer: []u8) []const u8 {
        const kind = call.typeAt(index);
        if (kind == .table or kind == .userdata) {
            if (call.metaMethod(index, "__name")) {
                defer call.pop(1);
                if (call.typeAt(-1) == .string) {
                    const name = call.bytesAt(-1);
                    const length = @min(name.len, buffer.len);
                    @memcpy(buffer[0..length], name[0..length]);
                    return buffer[0..length];
                }
            }
        }
        return typeName(kind);
    }
    /// Pushes the metamethod the VM would find (manual 7.4: raw, then along
    /// the metatable's own `__index` links) and answers true; pushes nothing
    /// and answers false when there is none. Nothing runs.
    pub fn metaMethod(call: Call, index: c_int, name: [:0]const u8) bool {
        if (api.nilu_getmetafield(call.state, index, name.ptr) != .ok) return false;
        if (call.typeAt(-1) == .nil) {
            call.pop(1);
            return false;
        }
        return true;
    }
    /// Pushes the raw metatable field when the value has a metatable holding
    /// it; otherwise pushes nothing and answers false. Nothing runs. Only
    /// `__metatable` is read this way: it describes the metatable itself.
    pub fn metaField(call: Call, index: c_int, name: []const u8) bool {
        if (api.nilu_getmetatable(call.state, index) != .ok) return false;
        if (call.typeAt(-1) != .table) {
            call.pop(1);
            return false;
        }
        if (api.nilu_pushlstring(call.state, name.ptr, name.len) != .ok or api.nilu_rawget(call.state, -2) != .ok) {
            call.pop(1);
            return false;
        }
        call.remove(-2);
        if (call.typeAt(-1) == .nil) {
            call.pop(1);
            return false;
        }
        return true;
    }

    /// Lua's luaL_argerror: a method call counts its receiver as argument 0,
    /// and the function's name is the one the caller wrote when there is one.
    pub fn argumentError(call: Call, index: c_int, detail: []const u8) Error {
        var number = index;
        var self = false;
        if (api.nilu_namewhat(call.state)) |what| {
            if (std.mem.eql(u8, std.mem.span(what), "method")) {
                number -= 1;
                self = number == 0;
            }
        }
        var buffer: [512]u8 = undefined;
        const text = if (self)
            std.fmt.bufPrint(&buffer, "calling '{s}' on bad self ({s})", .{ call.calledAs(), detail })
        else
            std.fmt.bufPrint(&buffer, "bad argument #{d} to '{s}' ({s})", .{ number, call.calledAs(), detail });
        return call.raise(text catch detail);
    }
    /// The name the caller wrote, else the registered name (manual 10.6).
    pub fn calledAs(call: Call) []const u8 {
        var length: usize = 0;
        const written = api.nilu_calledas(call.state, &length) orelse return call.name;
        return written[0..length];
    }
    /// Lua's luaL_error: the caller's position in front, when it has one.
    pub fn raise(call: Call, message: []const u8) Error {
        var buffer: [768]u8 = undefined;
        const text = call.locate(&buffer, 1, message);
        try call.push(text);
        return error.Raised;
    }
    /// `name:line: ` + message for a script frame at the level; a native or
    /// host frame adds nothing, as luaL_where answers "" for it.
    pub fn locate(call: Call, buffer: []u8, level: c_int, message: []const u8) []const u8 {
        var where = api.ErrorLocation{};
        const name = api.nilu_where(call.state, level, &where) orelse return message;
        if (where.line <= 0) return message;
        return std.fmt.bufPrint(buffer, "{s}:{d}: {s}", .{ std.mem.span(name), where.line, message }) catch message;
    }
};

pub fn typeName(kind: Type) []const u8 {
    return switch (kind) {
        .none => "no value",
        .nil => "nil",
        .number => "number",
        .function => "function",
        .boolean => "boolean",
        .string => "string",
        .table => "table",
        .userdata => "userdata",
        .thread => "thread",
    };
}

/// Wraps a library body as a C function. The registered name travels with it
/// so a refusal can name the function when no caller's code named it.
pub fn entry(comptime name: []const u8, comptime body: fn (Call) Error!c_int) Native {
    return Entry(name, body).run;
}

/// A named type, so that an entry's symbol is named by its library function.
/// An anonymous struct is numbered by the order types are made in, and a
/// change anywhere else renumbered the entries: the linker script places the
/// running code by name, so they moved in it.
fn Entry(comptime name: []const u8, comptime body: fn (Call) Error!c_int) type {
    return struct {
        fn run(state: *State) callconv(.c) c_int {
            return body(.{ .state = state, .name = name }) catch |err| failed(state, err);
        }
    };
}

/// A library's own shortage is a runtime failure a handler sees, carrying the
/// prepared sentence (manual 8.4); only when that sentence cannot be pushed
/// either does the entry answer the bare memory failure that runs no handler.
pub fn failed(state: *State, err: Error) c_int {
    switch (err) {
        error.Raised => return api.nilu_error(state),
        error.OutOfMemory => {
            if (api.nilu_pushstring(state, "not enough memory") == .ok) return api.nilu_error(state);
            return api.fail;
        },
        error.Stack => {
            if (api.nilu_pushstring(state, "stack overflow") == .ok) return api.nilu_error(state);
            return api.fail;
        },
    }
}

/// A growing byte buffer kept in a userdata the state owns, so the result of
/// a library function is built from the state's memory alone. The userdata sits
/// in one stack slot until `finish` replaces it with the string.
pub const Buffer = struct {
    call: Call,
    slot: c_int,
    bytes: [*]u8,
    capacity: usize,
    length: usize = 0,

    pub fn init(call: Call, initial: usize) Error!Buffer {
        const capacity = @max(initial, 64);
        var block: ?*anyopaque = null;
        try call.check(api.nilu_newuserdata(call.state, capacity, &block));
        return .{ .call = call, .slot = call.top(), .bytes = @ptrCast(block.?), .capacity = capacity };
    }
    pub fn reserve(self: *Buffer, extra: usize) Error!void {
        const needed = std.math.add(usize, self.length, extra) catch return error.OutOfMemory;
        if (needed <= self.capacity) return;
        var capacity = self.capacity;
        while (capacity < needed) capacity = std.math.mul(usize, capacity, 2) catch return error.OutOfMemory;
        var block: ?*anyopaque = null;
        try self.call.check(api.nilu_newuserdata(self.call.state, capacity, &block));
        const grown: [*]u8 = @ptrCast(block.?);
        @memcpy(grown[0..self.length], self.bytes[0..self.length]);
        api.nilu_copy(self.call.state, -1, self.slot);
        self.call.pop(1);
        self.bytes = grown;
        self.capacity = capacity;
    }
    pub fn append(self: *Buffer, data: []const u8) Error!void {
        try self.reserve(data.len);
        @memcpy(self.bytes[self.length..][0..data.len], data);
        self.length += data.len;
    }
    pub fn appendByte(self: *Buffer, byte: u8) Error!void {
        try self.reserve(1);
        self.bytes[self.length] = byte;
        self.length += 1;
    }
    pub fn contents(self: *const Buffer) []const u8 {
        return self.bytes[0..self.length];
    }
    /// Leaves the string in the buffer's slot and drops the userdata.
    pub fn finish(self: *Buffer) Error!void {
        try self.call.push(self.contents());
        api.nilu_copy(self.call.state, -1, self.slot);
        self.call.pop(1);
    }
};

/// Registers a function in the table on top of the stack.
pub fn setField(call: Call, name: []const u8, function: Native) Error!void {
    try call.push(name);
    try call.pushFunction(function);
    try call.check(api.nilu_settable(call.state, -3));
}
pub fn setNumberField(call: Call, name: []const u8, value: f64) Error!void {
    try call.push(name);
    try call.pushNumber(value);
    try call.check(api.nilu_settable(call.state, -3));
}

pub const Registration = struct { name: [:0]const u8, function: Native };

/// Makes a fresh table holding the functions and assigns it to the global.
pub fn openTable(call: Call, global: [:0]const u8, functions: []const Registration) Error!void {
    try call.check(api.nilu_newtable(call.state));
    for (functions) |function| try setField(call, function.name, function.function);
    try call.check(api.nilu_setglobal(call.state, global.ptr));
}

/// `pcall`, which the core recognises in a script's call (ADR 0009).
pub const protected_call = entry("pcall", protectedCall);

const base = [_]Registration{
    .{ .name = "print", .function = entry("print", print) },
    .{ .name = "type", .function = entry("type", typeOf) },
    .{ .name = "tostring", .function = entry("tostring", toString) },
    .{ .name = "tonumber", .function = entry("tonumber", toNumber) },
    .{ .name = "assert", .function = entry("assert", assert) },
    .{ .name = "select", .function = entry("select", select) },
    .{ .name = "error", .function = entry("error", raiseValue) },
    .{ .name = "pcall", .function = protected_call },
    .{ .name = "xpcall", .function = entry("xpcall", protectedCallWithHandler) },
    .{ .name = "next", .function = entry("next", next) },
    .{ .name = "pairs", .function = entry("pairs", pairs) },
    .{ .name = "ipairs", .function = entry("ipairs", ipairs) },
    .{ .name = "rawget", .function = entry("rawget", rawGet) },
    .{ .name = "rawset", .function = entry("rawset", rawSet) },
    .{ .name = "rawequal", .function = entry("rawequal", rawEqual) },
    .{ .name = "rawlen", .function = entry("rawlen", rawLength) },
    .{ .name = "setmetatable", .function = entry("setmetatable", setMetatable) },
    .{ .name = "getmetatable", .function = entry("getmetatable", getMetatable) },
    .{ .name = "collectgarbage", .function = entry("collectgarbage", collectGarbage) },
};

/// nilu_openlibs. Every status an API call answers while opening is the
/// answer; a partly opened state keeps what was assigned before the failure.
pub fn open(state: *State) api.Status {
    return openSelected(state, all_libraries);
}

/// The bits of nilu_openselectedlibs: Lua 5.5's values for the libraries
/// the core has (io and os are the host's).
pub const Library = struct {
    pub const base: c_int = 1;
    pub const package: c_int = 2;
    pub const coroutine: c_int = 4;
    pub const debug: c_int = 8;
    pub const math: c_int = 32;
    pub const string: c_int = 128;
    pub const table: c_int = 256;
    pub const utf8: c_int = 512;
};
const all_libraries: c_int = ~@as(c_int, 0);

/// nilu_openselectedlibs: the libraries whose bits are set, in the order
/// nilu_openlibs opens them.
pub fn openSelected(state: *State, libraries: c_int) api.Status {
    const call = Call{ .state = state, .name = "openlibs" };
    const depth = call.top();
    openAll(call, libraries) catch |err| {
        _ = api.nilu_settop(state, depth);
        return switch (err) {
            error.OutOfMemory => .memory,
            error.Stack => .stack,
            error.Raised => .runtime,
        };
    };
    _ = api.nilu_settop(state, depth);
    return .ok;
}

fn openAll(call: Call, libraries: c_int) Error!void {
    if (libraries & Library.base != 0) try openBase(call);
    if (libraries & Library.string != 0) try string_library.open(call);
    if (libraries & Library.table != 0) try table_library.open(call);
    if (libraries & Library.math != 0) try math_library.open(call);
    if (libraries & Library.utf8 != 0) try utf8_library.open(call);
    if (libraries & Library.package != 0) try package_library.open(call);
    if (libraries & Library.coroutine != 0) try coroutine_library.open(call);
    if (libraries & Library.debug != 0) try debug_library.open(call);
}

fn openBase(call: Call) Error!void {
    for (base) |function| {
        try call.pushFunction(function.function);
        try call.check(api.nilu_setglobal(call.state, function.name.ptr));
    }
    // _G is the globals table, as in Lua; _VERSION names the language and
    // its MAJOR.MINOR.
    // The C API has no call for the globals table; a chunk's _ENV is that
    // table, so a chunk that returns it hands it over.
    try call.check(api.nilu_loadstring(call.state, "return _ENV", null));
    try call.check(api.nilu_call(call.state, 0, 1));
    try call.check(api.nilu_setglobal(call.state, "_G"));
    try call.push("Nilu 0.1");
    try call.check(api.nilu_setglobal(call.state, "_VERSION"));
    try call.check(api.nilu_newtable(call.state));
    try call.check(api.nilu_pushcclosure(call.state, entry("warn", warn), 1));
    try call.check(api.nilu_setglobal(call.state, "warn"));
}

// Base functions (manual 10.1, 8.4, 8.5).

/// collectgarbage([opt]): "collect" (the default) answers 0, "count" the KiB
/// in use, "step" true (a step is a whole collection), "isrunning" whether
/// collections start by themselves, which "stop" and "restart" set, both
/// answering 0. The options sit at nilu_gc's numbers.
fn collectGarbage(call: Call) Error!c_int {
    const option = try call.optString(1, "collect");
    const options = [_][]const u8{ "collect", "count", "step", "isrunning", "stop", "restart" };
    const what = for (options, 0..) |name, i| {
        if (std.mem.eql(u8, name, option)) break i;
    } else {
        var buffer: [96]u8 = undefined;
        return call.argumentError(1, std.fmt.bufPrint(&buffer, "invalid option '{s}'", .{option}) catch "invalid option");
    };
    var answer: f64 = 0;
    try call.check(api.nilu_gc(call.state, @intCast(what), &answer));
    switch (what) {
        // The count in KiB is a float; the other answers are the integer 0,
        // as Lua's.
        1 => try call.pushNumber(answer),
        0, 4, 5 => try call.pushInteger(@intFromFloat(answer)),
        else => try call.pushBoolean(answer != 0),
    }
    return 1;
}

/// print (ADR 0003): the global `tostring` on each argument, tabs between and
/// a newline, handed to the host's writer as one string. The line is built
/// first, so a refusal writes nothing.
fn print(call: Call) Error!c_int {
    const count = call.top();
    try call.check(api.nilu_getwriter(call.state));
    if (call.typeAt(-1) == .nil) return call.raise("cannot print: no writer was given to this state");
    var line = try Buffer.init(call, 64);
    var index: c_int = 1;
    while (index <= count) : (index += 1) {
        try call.check(api.nilu_getglobal(call.state, "tostring"));
        try call.pushValue(index);
        try call.check(api.nilu_call(call.state, 1, 1));
        if (call.typeAt(-1) != .string) return call.raise("'tostring' must return a string to 'print'");
        if (index > 1) try line.appendByte('\t');
        try line.append(call.bytesAt(-1));
        call.pop(1);
    }
    try line.appendByte('\n');
    try line.finish();
    try call.check(api.nilu_call(call.state, 1, 0));
    return 0;
}

/// warn(msg, ...): joins its strings and hands them, with `Nilu warning: `
/// before and a newline after, to the writer as `writer(text, "warning")`.
/// Off until `warn("@on")`; `"@off"` turns it off, and any other one-piece
/// message that starts with `@` is a control message nothing knows, ignored,
/// as in Lua. Without a writer it does nothing. Its one upvalue is a table
/// holding whether it is on.
fn warn(call: Call) Error!c_int {
    const count = call.top();
    _ = try call.checkString(1);
    var index: c_int = 2;
    while (index <= count) : (index += 1) _ = try call.checkString(index);
    try call.check(api.nilu_getupvalue(call.state, 1));
    const switches = call.top();
    const first = call.bytesAt(1);
    if (count == 1 and first.len > 0 and first[0] == '@') {
        if (std.mem.eql(u8, first, "@on") or std.mem.eql(u8, first, "@off")) {
            try call.push("on");
            try call.pushBoolean(std.mem.eql(u8, first, "@on"));
            try call.check(api.nilu_rawset(call.state, switches));
        }
        return 0;
    }
    try call.push("on");
    try call.check(api.nilu_rawget(call.state, switches));
    if (!call.truthy(-1)) return 0;
    try call.check(api.nilu_getwriter(call.state));
    if (call.typeAt(-1) == .nil) return 0;
    var line = try Buffer.init(call, 64);
    try line.append("Nilu warning: ");
    index = 1;
    while (index <= count) : (index += 1) try line.append(call.bytesAt(index));
    try line.appendByte('\n');
    try line.finish();
    try call.push("warning");
    try call.check(api.nilu_call(call.state, 2, 0));
    return 0;
}

fn typeOf(call: Call) Error!c_int {
    try call.checkAny(1);
    try call.push(typeName(call.typeAt(1)));
    return 1;
}

/// Pushes the string for the value at the index, the way `tostring` does:
/// `__tostring` first, then `__name` for a table/userdata, then the value's own
/// spelling (a number's is the core's). Shared by `tostring` and `%s`.
pub fn pushToString(call: Call, index: c_int) Error!void {
    const absolute = if (index < 0) call.top() + index + 1 else index;
    if (call.metaMethod(absolute, "__tostring")) {
        try call.pushValue(absolute);
        switch (api.nilu_call(call.state, 1, 1)) {
            .ok => {},
            .type => {
                // A __tostring nothing can call is the library's refusal, not
                // the core's type failure (carried C case): the same sentence,
                // raised afresh as a runtime failure.
                var sentence: [128]u8 = undefined;
                const text = call.bytesAt(-1);
                const length = @min(text.len, sentence.len);
                @memcpy(sentence[0..length], text[0..length]);
                call.pop(1);
                try call.push(sentence[0..length]);
                return error.Raised;
            },
            else => |status| try call.check(status),
        }
        if (call.typeAt(-1) != .string) return call.raise("'__tostring' must return a string");
        return;
    }
    switch (call.typeAt(absolute)) {
        .nil => try call.push("nil"),
        .boolean => try call.push(if (call.truthy(absolute)) "true" else "false"),
        .number => {
            try call.pushValue(absolute);
            if (api.nilu_tolstring(call.state, -1, null) == null) return error.OutOfMemory;
        },
        .string => try call.pushValue(absolute),
        .table, .function, .userdata, .thread => {
            var kind: []const u8 = typeName(call.typeAt(absolute));
            var name_buffer: [128]u8 = undefined;
            if (call.metaMethod(absolute, "__name")) {
                if (call.typeAt(-1) == .string) {
                    const name = call.bytesAt(-1);
                    const length = @min(name.len, name_buffer.len);
                    @memcpy(name_buffer[0..length], name[0..length]);
                    kind = name_buffer[0..length];
                }
                call.pop(1);
            }
            var buffer: [192]u8 = undefined;
            const identity = @intFromPtr(api.nilu_topointer(call.state, absolute));
            const text = std.fmt.bufPrint(&buffer, "{s}: 0x{x}", .{ kind, identity }) catch return error.Stack;
            try call.push(text);
        },
        .none => try call.push("nil"),
    }
}

fn toString(call: Call) Error!c_int {
    try call.checkAny(1);
    try pushToString(call, 1);
    return 1;
}

fn toNumber(call: Call) Error!c_int {
    if (call.typeAt(2) == .none or call.typeAt(2) == .nil) {
        switch (call.typeAt(1)) {
            .number => try call.pushValue(1),
            .string => {
                const text = call.bytesAt(1);
                if (api.nilu_stringtonumber(call.state, text.ptr, text.len) != .ok) try call.pushNil();
            },
            .none => return call.argumentError(1, "value expected"),
            else => try call.pushNil(),
        }
        return 1;
    }
    const base_value = try call.checkInteger(2);
    if (call.typeAt(1) != .string) return call.typeError(1, "string");
    if (base_value < 2 or base_value > 36) return call.argumentError(2, "base out of range");
    const digits = std.mem.trim(u8, call.bytesAt(1), " \t\n\r\x0b\x0c");
    var negative = false;
    var rest = digits;
    if (rest.len > 0 and rest[0] == '-') {
        negative = true;
        rest = rest[1..];
    }
    if (rest.len == 0) {
        try call.pushNil();
        return 1;
    }
    // An integer, wrapping around in 64 bits, as Lua's tonumber with a base.
    var value: u64 = 0;
    for (rest) |byte| {
        const digit: u8 = if (std.ascii.isDigit(byte)) byte - '0' else if (std.ascii.isAlphabetic(byte)) std.ascii.toLower(byte) - 'a' + 10 else 255;
        if (digit >= base_value) {
            try call.pushNil();
            return 1;
        }
        value = value *% @as(u64, @intCast(base_value)) +% digit;
    }
    const integer: i64 = @bitCast(value);
    try call.pushInteger(if (negative) 0 -% integer else integer);
    return 1;
}

fn assert(call: Call) Error!c_int {
    try call.checkAny(1);
    if (call.truthy(1)) return call.top();
    if (call.typeAt(2) == .none) return call.raise("assertion failed!");
    // The message is thrown as it is; a string gets the caller's position, as error does.
    try call.setTop(2);
    call.remove(1);
    if (call.typeAt(1) == .string) {
        var buffer: [768]u8 = undefined;
        try call.push(call.locate(&buffer, 1, call.bytesAt(1)));
    }
    return error.Raised;
}

fn select(call: Call) Error!c_int {
    const count = call.top();
    if (call.typeAt(1) == .string and std.mem.eql(u8, call.bytesAt(1), "#")) {
        try call.pushInteger(@intCast(count - 1));
        return 1;
    }
    var index = try call.checkInteger(1);
    if (index < 0) index += count else if (index > count) index = count;
    if (index < 1) return call.argumentError(1, "index out of range");
    return count - @as(c_int, @intCast(index));
}

fn raiseValue(call: Call) Error!c_int {
    const level = try call.optInteger(2, 1);
    try call.setTop(1);
    if (call.typeAt(1) == .string and level > 0 and level <= std.math.maxInt(c_int)) {
        var buffer: [768]u8 = undefined;
        const text = call.locate(&buffer, @intCast(level), call.bytesAt(1));
        try call.push(text);
    }
    return error.Raised;
}

// A yield inside the protected call suspends pcall too; it finishes in its
// continuation, with the status nilu_pcall would have answered (ADR 0013).

fn protectedCall(call: Call) Error!c_int {
    try call.checkAny(1);
    const status = api.nilu_pcallk(call.state, call.top() - 1, multret, 0, 0, protectedCallContinued);
    if (status == .yielded) return api.nilu_yield(call.state, 0);
    return finishProtected(call, status, 1);
}

fn protectedCallContinued(state: *State, status: c_int, _: isize) callconv(.c) c_int {
    return finishProtected(.{ .state = state, .name = "pcall" }, @fromBackingInt(@intCast(status)), 1) catch |err| failed(state, err);
}

fn protectedCallWithHandler(call: Call) Error!c_int {
    try call.checkFunction(2);
    // [f, h, args...] becomes [h, f, args...] so the handler sits below the callee.
    try call.pushValue(1);
    api.nilu_copy(call.state, 2, 1);
    api.nilu_copy(call.state, -1, 2);
    call.pop(1);
    const status = api.nilu_pcallk(call.state, call.top() - 2, multret, 1, 0, protectedCallWithHandlerContinued);
    if (status == .yielded) return api.nilu_yield(call.state, 0);
    return finishWithHandler(call, status);
}

fn protectedCallWithHandlerContinued(state: *State, status: c_int, _: isize) callconv(.c) c_int {
    return finishWithHandler(.{ .state = state, .name = "xpcall" }, @fromBackingInt(@intCast(status))) catch |err| failed(state, err);
}

fn finishWithHandler(call: Call, status: api.Status) Error!c_int {
    const count = try finishProtected(call, status, 2);
    call.remove(1);
    return count;
}

/// After nilu_pcall: `true` and the results, or `false` and the carried value.
/// The host's interruption is not caught; it is passed on as it is.
fn finishProtected(call: Call, status: api.Status, first: c_int) Error!c_int {
    switch (status) {
        .ok => {
            try call.pushBoolean(true);
            call.insert(first);
            return call.top() - first + 1;
        },
        .interrupted => return error.Raised,
        .memory => {
            // The carried value is the prepared sentence; a handler already ran where it could.
            try call.pushBoolean(false);
            call.insert(first);
            return 2;
        },
        else => {
            try call.pushBoolean(false);
            call.insert(first);
            return 2;
        },
    }
}

fn next(call: Call) Error!c_int {
    try call.checkTable(1);
    try call.setTop(2);
    var more: c_int = 0;
    switch (api.nilu_next(call.state, 1, &more)) {
        .ok => {
            if (more != 0) return 2;
            try call.pushNil();
            return 1;
        },
        .memory => return error.OutOfMemory,
        .stack => return error.Stack,
        // An unknown key has no position in Lua's sentence either.
        else => {
            try call.push("invalid key to 'next'");
            return error.Raised;
        },
    }
}

fn pairs(call: Call) Error!c_int {
    try call.checkAny(1);
    // Four values, as Lua 5.5's: the fourth is what a generic `for` closes.
    if (call.metaMethod(1, "__pairs")) {
        try call.pushValue(1);
        try call.check(api.nilu_call(call.state, 1, 4));
        return 4;
    }
    try call.pushFunction(entry("next", next));
    try call.pushValue(1);
    try call.pushNil();
    try call.pushNil();
    return 4;
}

fn ipairsStep(call: Call) Error!c_int {
    const index = (try call.checkInteger(2)) + 1;
    try call.pushInteger(@intCast(index));
    try call.pushInteger(@intCast(index));
    try call.check(api.nilu_gettable(call.state, 1));
    if (call.typeAt(-1) == .nil) return 1;
    return 2;
}

fn ipairs(call: Call) Error!c_int {
    try call.checkAny(1);
    try call.pushFunction(entry("ipairs", ipairsStep));
    try call.pushValue(1);
    try call.pushNumber(0);
    return 3;
}

fn rawGet(call: Call) Error!c_int {
    try call.checkTable(1);
    try call.checkAny(2);
    try call.setTop(2);
    try call.check(api.nilu_rawget(call.state, 1));
    return 1;
}

fn rawSet(call: Call) Error!c_int {
    try call.checkTable(1);
    try call.checkAny(2);
    try call.checkAny(3);
    try call.setTop(3);
    switch (api.nilu_rawset(call.state, 1)) {
        .ok => {},
        .memory => return error.OutOfMemory,
        .stack => return error.Stack,
        else => {
            // The core's own sentences for a key a table cannot hold.
            const key = call.typeAt(2);
            if (key == .nil) return call.raise("table index is nil");
            if (key == .number and std.math.isNan(call.numberAt(2))) return call.raise("table index is NaN");
            var buffer: [64]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "table index is a {s} value", .{typeName(key)}) catch "table index is invalid";
            return call.raise(text);
        },
    }
    try call.setTop(1);
    return 1;
}

fn rawEqual(call: Call) Error!c_int {
    try call.checkAny(1);
    try call.checkAny(2);
    try call.pushBoolean(api.nilu_rawequal(call.state, 1, 2) != 0);
    return 1;
}

fn rawLength(call: Call) Error!c_int {
    const kind = call.typeAt(1);
    if (kind != .table and kind != .string) return call.argumentError(1, "table or string expected");
    try call.check(api.nilu_rawlen(call.state, 1));
    return 1;
}

fn setMetatable(call: Call) Error!c_int {
    try call.checkTable(1);
    const kind = call.typeAt(2);
    if (kind != .nil and kind != .table) return call.typeError(2, "nil or table");
    if (call.metaField(1, "__metatable")) {
        call.pop(1);
        return call.raise("cannot change a protected metatable");
    }
    try call.setTop(2);
    try call.check(api.nilu_setmetatable(call.state, 1));
    return 1;
}

fn getMetatable(call: Call) Error!c_int {
    try call.checkAny(1);
    if (call.metaField(1, "__metatable")) return 1;
    try call.check(api.nilu_getmetatable(call.state, 1));
    return 1;
}
