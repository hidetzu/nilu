//! Fuzz targets (hidetzu/nilu#6). `zig build test` runs each target over its
//! corpus and an empty input; `zig build fuzz --fuzz=<limit>` searches.
//! Each input must end without a crash or a leak, and the state must answer
//! `return 1 + 1` afterwards. A host contract the header says aborts is not
//! exercised: every index and count passed here is valid.
const std = @import("std");
const api = @import("c_api.zig");
const runtime = @import("runtime.zig");
const parser = @import("parser.zig");
const numeral = @import("numeral.zig");
const Smith = std.testing.Smith;

/// Refuses requests that would hold more than `limit` bytes at once, so an
/// input cannot exhaust the machine, and every refusal is an allocation
/// failure the core must answer.
const Limited = struct {
    backing: std.mem.Allocator,
    limit: usize,
    held: usize = 0,

    fn allocator(self: *Limited) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn room(self: *Limited, old: usize, new: usize) bool {
        return new <= old or self.held - old + new <= self.limit;
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Limited = @ptrCast(@alignCast(context));
        if (!self.room(0, len)) return null;
        const block = self.backing.rawAlloc(len, alignment, ret) orelse return null;
        self.held += len;
        return block;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) bool {
        const self: *Limited = @ptrCast(@alignCast(context));
        if (!self.room(memory.len, new_len)) return false;
        if (!self.backing.rawResize(memory, alignment, new_len, ret)) return false;
        self.held = self.held - memory.len + new_len;
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) ?[*]u8 {
        const self: *Limited = @ptrCast(@alignCast(context));
        if (!self.room(memory.len, new_len)) return null;
        const block = self.backing.rawRemap(memory, alignment, new_len, ret) orelse return null;
        self.held = self.held - memory.len + new_len;
        return block;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Limited = @ptrCast(@alignCast(context));
        self.backing.rawFree(memory, alignment, ret);
        self.held -= memory.len;
    }
};

/// How much an input may hold, and how far it may run: small enough that an
/// input ends in milliseconds, large enough for collections and refusals.
const memory_limit = 1 << 20;
const hook_interval = 1000;
const hook_stops = 50;

var stops: usize = 0;

fn budget(_: *runtime.State) callconv(.c) c_int {
    stops += 1;
    return @intFromBool(stops >= hook_stops);
}

/// Called far more often, it asks for a collection at the next instruction
/// each time: a value the collector cannot reach is freed while still in use,
/// and the testing allocator or a safety check sees it.
fn collecting(state: *runtime.State) callconv(.c) c_int {
    stops += 1;
    state.setCollectionThreshold(0);
    return @intFromBool(stops >= hook_stops * collect_ratio);
}
const collect_ratio = hook_interval / collect_interval;
const collect_interval = 50;

/// Runs a script of its own on the same state from inside the hook, as the
/// header allows: the outer program's frames must survive the inner call and
/// the collections it makes.
fn reentering(state: *runtime.State) callconv(.c) c_int {
    stops += 1;
    if (stops % 4 == 0 and api.nilu_loadnamed(state, "local t = {} for i = 1, 20 do t[i] = {i} end collectgarbage() return #t", "=inner", null) == .ok)
        _ = api.nilu_pcall(state, 0, 1, 0);
    return @intFromBool(stops >= hook_stops);
}

/// How the hook watches an input's run.
const Watch = enum { budget, collecting, reentering };

/// A state with the libraries open, minus pattern matching: a pattern's time
/// has no bound and the hook does not see it (manual 12.5), so an input could
/// run for ever. Null when the limit refused the state itself.
fn open(limited: *Limited) !?*runtime.State {
    const state = api.create(limited.allocator()) catch return null;
    errdefer api.nilu_close(state);
    if (api.nilu_openlibs(state) != .ok) {
        api.nilu_close(state);
        return null;
    }
    const strip = "string.find, string.match, string.gmatch, string.gsub = nil";
    if (api.nilu_loadnamed(state, strip, "=strip", null) != .ok or api.nilu_pcall(state, 0, 0, 0) != .ok) {
        api.nilu_close(state);
        return null;
    }
    return state;
}

/// After whatever the input did, with the limit lifted and a collection: the
/// state answers a fresh call.
fn expectReusable(state: *runtime.State, limited: *Limited) !void {
    api.nilu_sethook(state, null, 0);
    limited.limit = std.math.maxInt(usize);
    _ = api.nilu_settop(state, 0);
    try std.testing.expectEqual(api.Status.ok, api.nilu_gc(state, 0, null));
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state, "return 1 + 1", "=after", null));
    try std.testing.expectEqual(api.Status.ok, api.nilu_pcall(state, 0, 1, 0));
    try std.testing.expectEqual(@as(c_longlong, 2), api.nilu_tointegerx(state, -1, null));
}

/// Loads `source` and runs it under the hook's budget and the memory limit.
fn runSource(source: [:0]const u8, watch: Watch) !void {
    var limited = Limited{ .backing = std.testing.allocator, .limit = memory_limit };
    const state = try open(&limited) orelse return;
    defer api.nilu_close(state);
    stops = 0;
    switch (watch) {
        .budget => api.nilu_sethook(state, budget, hook_interval),
        .collecting => api.nilu_sethook(state, collecting, collect_interval),
        .reentering => api.nilu_sethook(state, reentering, hook_interval),
    }
    if (api.nilu_loadnamed(state, source.ptr, "=fuzz", null) == .ok)
        _ = api.nilu_pcall(state, 0, -1, 0);
    try expectReusable(state, &limited);
}

const max_source = 2048;

fn fuzzSourceBytes(_: void, smith: *Smith) anyerror!void {
    var buffer: [max_source + 1]u8 = undefined;
    const watch = smith.value(Watch);
    const length = smith.slice(buffer[0..max_source]);
    // The C API reads NUL-terminated text, so a zero byte would end it early.
    for (buffer[0..length]) |*byte| if (byte.* == 0) {
        byte.* = ' ';
    };
    buffer[length] = 0;
    try runSource(buffer[0..length :0], watch);
}

test "fuzz source bytes load and run, and the state answers afterwards" {
    try std.testing.fuzz({}, fuzzSourceBytes, .{ .corpus = &.{
        "local t = {} for i = 1, 100 do t[i] = {i} end return #t",
        "local function f(n) if n == 0 then return 0 end return 1 + f(n - 1) end return f(100)",
        "return setmetatable({}, {__index = function(t, k) return k end}).x",
        "local co = coroutine.wrap(function(a) local b = coroutine.yield(a + 1) return b * 2 end) return co(1), co(5)",
        "while true do end",
    } });
}

/// Pieces of programs, so that most sequences reach the compiler and the VM
/// rather than stopping at the first byte the lexer refuses.
const vocabulary = [_][]const u8{
    "local",          "function",       "end",        "if",          "then",       "else",         "elseif",       "while",              "do",
    "for",            "in",             "repeat",     "until",       "return",     "break",        "goto",         "and",                "or",
    "not",            "nil",            "true",       "false",       "a",          "b",            "t",            "f",                  "x",
    "_ENV",           "_G",             "...",        "0",           "1",          "-1",           "2^63",         "0x7fffffffffffffff", "1e308",
    "0.5",            "\"s\"",          "''",         "[[x]]",       "+",          "-",            "*",            "/",                  "//",
    "%",              "^",              "..",         "#",           "==",         "~=",           "<",            "<=",                 ">",
    ">=",             "&",              "|",          "~",           "<<",         ">>",           "=",            "(",                  ")",
    "{",              "}",              "[",          "]",           ";",          ":",            ",",            ".",                  "::l::",
    "<close>",        "<const>",        "{}",         "pcall",       "error",      "setmetatable", "getmetatable", "collectgarbage",     "select",
    "tostring",       "tonumber",       "load",       "next",        "pairs",      "ipairs",       "rawset",       "rawget",             "rawlen",
    "rawequal",       "type",           "assert",     "xpcall",      "string",     "table",        "math",         "utf8",               "coroutine",
    "debug",          ".rep",           ".sub",       ".format",     ".insert",    ".remove",      ".concat",      ".sort",              ".unpack",
    ".wrap",          ".yield",         ".resume",    ".create",     ".close",     ".huge",        ".maxinteger",  ".mininteger",        ".char",
    "\"__index\"",    "\"__newindex\"", "\"__call\"", "\"__close\"", "\"__mode\"", "\"__len\"",    "\"__eq\"",     "\"__lt\"",           "\"__concat\"",
    "\"__tostring\"", "\"k\"",          "\"v\"",      "\"collect\"", "\"step\"",   "\"stop\"",     "\"restart\"",  "\"count\"",          "\n",
};

fn fuzzTokens(_: void, smith: *Smith) anyerror!void {
    var buffer: [max_source + 1]u8 = undefined;
    const watch = smith.value(Watch);
    var length: usize = 0;
    var count: usize = 0;
    while (count < 96 and !smith.eos()) : (count += 1) {
        const piece = vocabulary[smith.index(vocabulary.len)];
        if (length + piece.len + 1 > max_source) break;
        @memcpy(buffer[length..][0..piece.len], piece);
        length += piece.len;
        buffer[length] = ' ';
        length += 1;
    }
    buffer[length] = 0;
    try runSource(buffer[0..length :0], watch);
}

test "fuzz token sequences load and run, and the state answers afterwards" {
    try std.testing.fuzz({}, fuzzTokens, .{});
}

/// Raw bytes, zero bytes included, into the parser, under an allocator that
/// refuses from a point the input picks.
fn fuzzParser(_: void, smith: *Smith) anyerror!void {
    var buffer: [max_source]u8 = undefined;
    const fail_index = smith.value(u16);
    const length = smith.slice(&buffer);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
    var diagnostic: ?parser.Diagnostic = null;
    var ast = parser.parseChunk(failing.allocator(), buffer[0..length], &diagnostic) catch |err| switch (err) {
        error.Syntax => return std.testing.expect(diagnostic != null),
        error.OutOfMemory => return,
    };
    defer ast.deinit();
    try std.testing.expect(ast.root.data == .block);
}

test "fuzz parser takes raw bytes and refused allocations without a crash or a leak" {
    try std.testing.fuzz({}, fuzzParser, .{ .corpus = &.{ "local a <const> = 1 return a", "return ((((1))))", "x = [==[\x00]==]" } });
}

/// A numeral read and written back: an integer comes back as itself, and
/// writing any number succeeds.
fn fuzzNumeral(_: void, smith: *Smith) anyerror!void {
    var buffer: [128]u8 = undefined;
    const length = smith.slice(&buffer);
    const parsed = numeral.parse(buffer[0..length]) orelse return;
    var text: [64]u8 = undefined;
    switch (parsed) {
        .integer => |value| {
            const written = try numeral.formatInteger(&text, value);
            const again = numeral.parse(written) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(value, again.integer);
        },
        .float => |value| _ = try numeral.format(&text, value),
    }
}

test "fuzz numerals parse, and an integer is written back as itself" {
    try std.testing.fuzz({}, fuzzNumeral, .{ .corpus = &.{ "0x7fffffffffffffff", "-9223372036854775808", "1e308", "0x1p-1074", "  12  " } });
}

/// A sequence of C API calls, each with valid indices and counts, on a state
/// under the memory limit, with collections between them.
fn fuzzApi(_: void, smith: *Smith) anyerror!void {
    var limited = Limited{ .backing = std.testing.allocator, .limit = memory_limit };
    const state = try open(&limited) orelse return;
    defer api.nilu_close(state);
    var text: [16]u8 = undefined;
    var steps: usize = 0;
    while (steps < 64 and !smith.eos()) : (steps += 1) {
        const top = api.nilu_gettop(state);
        const any: c_int = if (top > 0) @intCast(smith.valueRangeAtMost(u8, 1, @intCast(@min(top, 255)))) else 0;
        switch (smith.index(18)) {
            0 => _ = api.nilu_pushinteger(state, smith.value(i64)),
            1 => _ = api.nilu_pushnumber(state, @bitCast(smith.value(u64))),
            2 => {
                const length = smith.slice(&text);
                _ = api.nilu_pushlstring(state, &text, length);
            },
            3 => _ = api.nilu_newtable(state),
            4 => _ = api.nilu_pushnil(state),
            5 => if (top > 0) {
                _ = api.nilu_settop(state, -2);
            },
            6 => if (top > 0) {
                _ = api.nilu_pushvalue(state, any);
            },
            7 => if (top > 0) {
                _ = api.nilu_gettable(state, any);
            },
            8 => if (top >= 2) {
                _ = api.nilu_settable(state, any);
            },
            9 => if (top > 0) {
                _ = api.nilu_getfield(state, any, "k");
            },
            10 => if (top >= 1) {
                _ = api.nilu_setfield(state, any, "k");
            },
            11 => if (top > 0) {
                _ = api.nilu_len(state, any);
            },
            12 => if (top > 0) {
                _ = api.nilu_rawlen(state, any);
            },
            13 => if (top > 0) {
                const other: c_int = @intCast(smith.valueRangeAtMost(u8, 1, @intCast(@min(top, 255))));
                _ = api.nilu_compare(state, any, other, @intCast(smith.index(3)));
            },
            14 => if (top > 0) {
                _ = api.nilu_tolstring(state, any, null);
            },
            15 => _ = api.nilu_gc(state, 0, null),
            16 => if (top >= 2) {
                _ = api.nilu_setmetatable(state, any);
            },
            else => if (top > 0) {
                _ = api.nilu_getmetatable(state, any);
            },
        }
    }
    try expectReusable(state, &limited);
}

test "fuzz C API call sequences leave a state that answers afterwards" {
    try std.testing.fuzz({}, fuzzApi, .{});
}
