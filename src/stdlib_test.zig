//! The library against the manual: every `nilu` example block in the chapters
//! named below runs in a fresh state with the library open and a writer that
//! keeps what `print` writes, and its `output`/`stderr` block is the
//! expectation. `print` itself is the library's, the same one the command uses.
const std = @import("std");
const allocation_failures = @import("allocation_failures.zig");
const api = @import("c_api.zig");
const runtime = @import("runtime.zig");
const a = std.testing.allocator;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;

var captured: std.ArrayListUnmanaged(u8) = .empty;
/// What `warn` wrote: the command puts it on standard error.
var warned: std.ArrayListUnmanaged(u8) = .empty;
var capture_failed = false;

/// The writer the library's print hands each line to (ADR 0003): the command
/// gives one that writes to standard output; this one keeps the lines.
fn captureWriter(state: *runtime.State) callconv(.c) c_int {
    var length: usize = 0;
    const text = api.nilu_tolstring(state, 1, &length) orelse return 0;
    const warning = api.nilu_type(state, 2) == @backingInt(api.Type.string) and std.mem.eql(u8, std.mem.span(api.nilu_tolstring(state, 2, null).?), "warning");
    (if (warning) &warned else &captured).appendSlice(a, text[0..length]) catch {
        capture_failed = true;
        return api.fail;
    };
    return 0;
}

/// `expected` is the output block followed by the stderr block, when present.
const Block = struct { source: []const u8, expected: []const u8, failure: bool, line: usize, checked: bool };

fn fencedBlocks(text: []const u8, blocks: *std.ArrayListUnmanaged(Block)) !void {
    var position: usize = 0;
    var line: usize = 1;
    // A runnable example opens with `lua nilu`: `lua` for highlighting, `nilu`
    // for the checks (tools/reference-content.mjs, fenceTag).
    const opening = "```lua nilu\n";
    while (std.mem.indexOfPos(u8, text, position, opening)) |start| {
        line += std.mem.count(u8, text[position..start], "\n");
        const body_start = start + opening.len;
        const body_end = std.mem.indexOfPos(u8, text, body_start, "\n```") orelse break;
        const source = text[body_start..body_end];
        var next = body_end + "\n```".len;
        var expected: std.ArrayListUnmanaged(u8) = .empty;
        errdefer expected.deinit(a);
        var failure = false;
        var checked = false;
        while (true) {
            // The manual sometimes leaves a blank line between the fences.
            var gap = next;
            while (std.mem.startsWith(u8, text[gap..], "\n\n")) gap += 1;
            const is_output = std.mem.startsWith(u8, text[gap..], "\n```output\n");
            const is_failure = std.mem.startsWith(u8, text[gap..], "\n```stderr\n");
            if (!is_output and !is_failure) break;
            failure = failure or is_failure;
            checked = true;
            const expected_start = gap + "\n```output\n".len;
            const expected_end = std.mem.indexOfPos(u8, text, expected_start, "\n```") orelse break;
            if (expected.items.len > 0) try expected.append(a, '\n');
            try expected.appendSlice(a, text[expected_start..expected_end]);
            next = expected_end + "\n```".len;
        }
        try blocks.append(a, .{ .source = source, .expected = try expected.toOwnedSlice(a), .failure = failure, .line = line, .checked = checked });
        line += std.mem.count(u8, text[start..next], "\n");
        position = next;
    }
}

/// What the command's reader answers in the empty directory a manual example
/// runs in (manual 11.6): no module and no file is there. manual-check runs
/// the same examples through the command itself, so the two cannot drift.
fn emptyDirectoryReader(state: *runtime.State) callconv(.c) c_int {
    var length: usize = 0;
    const name = api.nilu_tolstring(state, 1, &length) orelse return 0;
    const kind = std.mem.span(api.nilu_tolstring(state, 3, null) orelse return 0);
    var buffer: [512]u8 = undefined;
    var reason: std.Io.Writer = .fixed(&buffer);
    reason.writeAll("no file '") catch return 0;
    for (name[0..length]) |byte| reason.writeByte(if (std.mem.eql(u8, kind, "module") and byte == '.') '/' else byte) catch return 0;
    reason.writeAll(if (std.mem.eql(u8, kind, "module")) ".nilu'" else "'") catch return 0;
    if (api.nilu_pushnil(state) != .ok) return 0;
    if (api.nilu_pushlstring(state, reason.buffered().ptr, reason.buffered().len) != .ok) return 0;
    return 2;
}

fn runBlock(block: Block) !bool {
    const state = try api.create(a);
    defer api.nilu_close(state);
    captured.clearRetainingCapacity();
    warned.clearRetainingCapacity();
    capture_failed = false;
    try equal(api.Status.ok, api.nilu_openlibs(state));
    try equal(api.Status.ok, api.nilu_pushcfunction(state, captureWriter));
    try equal(api.Status.ok, api.nilu_setwriter(state));
    try equal(api.Status.ok, api.nilu_pushcfunction(state, emptyDirectoryReader));
    try equal(api.Status.ok, api.nilu_setreader(state));
    const source = try a.dupeSentinel(u8, block.source, 0);
    defer a.free(source);
    const status = api.nilu_loadnamed(state, source, "=<manual>", null);
    var actual: std.ArrayListUnmanaged(u8) = .empty;
    defer actual.deinit(a);
    if (status != .ok) {
        try actual.appendSlice(a, "nilu: ");
        try actual.appendSlice(a, std.mem.span(api.nilu_tolstring(state, -1, null) orelse "?"));
    } else {
        const result = api.nilu_pcall(state, 0, 0, 0);
        try actual.appendSlice(a, captured.items);
        if (result != .ok) {
            if (!block.failure) {
                std.debug.print("manual block at line {d} failed unexpectedly: {s}\n", .{ block.line, api.nilu_tolstring(state, -1, null) orelse "(no message)" });
                return false;
            }
            try actual.appendSlice(a, "nilu: ");
            if (api.nilu_tolstring(state, -1, null)) |text| try actual.appendSlice(a, std.mem.span(text)) else try actual.appendSlice(a, "(no message)");
        } else if (block.failure) {
            // A stderr block after a success shows what `warn` wrote there.
            if (warned.items.len == 0) {
                std.debug.print("manual block at line {d} succeeded but a failure was expected\n", .{block.line});
                return false;
            }
            try actual.appendSlice(a, warned.items);
        }
        if (result != .ok and captured.items.len > 0 and !std.mem.endsWith(u8, captured.items, "\n")) try actual.append(a, '\n');
    }
    if (capture_failed) return error.OutOfMemory;
    // A block with no output fence only has to run; the manual shows nothing for it.
    if (!block.checked) return true;
    const trimmed = std.mem.trimEnd(u8, actual.items, "\n");
    const wanted = std.mem.trimEnd(u8, block.expected, "\n");
    if (!std.mem.eql(u8, trimmed, wanted)) {
        std.debug.print("manual block at line {d}:\n--- expected\n{s}\n--- actual\n{s}\n---\n", .{ block.line, wanted, trimmed });
        return false;
    }
    return true;
}

fn checkChapter(comptime name: []const u8, text: []const u8) !void {
    var blocks: std.ArrayListUnmanaged(Block) = .empty;
    defer {
        for (blocks.items) |block| a.free(block.expected);
        blocks.deinit(a);
    }
    try fencedBlocks(text, &blocks);
    var passed: usize = 0;
    for (blocks.items) |block| {
        if (try runBlock(block)) passed += 1;
    }
    std.debug.print("manual {s}: {d} of {d} example blocks agree\n", .{ name, passed, blocks.items.len });
    try expect(blocks.items.len > 0);
    try equal(blocks.items.len, passed);
}

fn release() void {
    warned.deinit(a);
    warned = .empty;
    captured.deinit(a);
    captured = .empty;
}

test "stdlib manual chapter 10 examples print what the manual shows" {
    defer release();
    try checkChapter("10-library", @embedFile("manual-library"));
}

test "stdlib manual chapter 8 examples print what the manual shows" {
    defer release();
    try checkChapter("08-failure", @embedFile("manual-failure"));
}

test "stdlib manual chapters 1 to 7 and 9 print what the manual shows" {
    defer release();
    try checkChapter("01-getting-started", @embedFile("manual-01"));
    try checkChapter("02-values", @embedFile("manual-02"));
    try checkChapter("03-variables", @embedFile("manual-03"));
    try checkChapter("04-statements", @embedFile("manual-04"));
    try checkChapter("05-expressions", @embedFile("manual-05"));
    try checkChapter("06-functions", @embedFile("manual-06"));
    try checkChapter("07-metatables", @embedFile("manual-07"));
    try checkChapter("09-gc", @embedFile("manual-09"));
}

test "stdlib carried smoke expectations for the library" {
    defer release();
    const state = try api.create(a);
    defer api.nilu_close(state);
    // A fresh state has no library; opening it twice makes it afresh.
    try equal(api.Status.ok, api.nilu_getglobal(state, "type"));
    try equal(@as(c_int, 0), api.nilu_type(state, -1));
    try equal(api.Status.ok, api.nilu_settop(state, 0));
    try equal(api.Status.ok, api.nilu_openlibs(state));
    try equal(@as(c_int, 0), api.nilu_gettop(state));
    const Case = struct { source: [:0]const u8, answer: []const u8 };
    for ([_]Case{
        .{ .source = "return type(string)", .answer = "table" },
        .{ .source = "return string.rep(\"a\", 3, \",\")", .answer = "a,a,a" },
        .{ .source = "if math.fmod(-1, 3) == -1 then return \"truncated\" end return \"floored\"", .answer = "truncated" },
        .{ .source = "return tostring(1 / 3)", .answer = "0.3333333333333333" },
        .{ .source = "return tostring(1000000000000000)", .answer = "1000000000000000" },
        .{ .source = "string = {} string.sub = function() return \"mine\" end return string.sub(\"x\", 1)", .answer = "mine" },
    }) |case| {
        try equal(api.Status.ok, api.nilu_settop(state, 0));
        try equal(api.Status.ok, api.nilu_loadstring(state, case.source, null));
        try equal(api.Status.ok, api.nilu_call(state, 0, 1));
        try std.testing.expectEqualStrings(case.answer, std.mem.span(api.nilu_tolstring(state, -1, null).?));
    }
    // Opening again restores the replaced library table.
    try equal(api.Status.ok, api.nilu_openlibs(state));
    try equal(api.Status.ok, api.nilu_settop(state, 0));
    try equal(api.Status.ok, api.nilu_loadstring(state, "return string.upper(\"ab\")", null));
    try equal(api.Status.ok, api.nilu_call(state, 0, 1));
    try std.testing.expectEqualStrings("AB", std.mem.span(api.nilu_tolstring(state, -1, null).?));
    // A refusal from a chunk carries the chunk and line; from the host, the bare sentence.
    try equal(api.Status.ok, api.nilu_settop(state, 0));
    try equal(api.Status.ok, api.nilu_loadnamed(state, "local a = 1\nreturn string.rep()", "=t", null));
    try equal(api.Status.runtime, api.nilu_call(state, 0, 1));
    try std.testing.expectEqualStrings("t:2: bad argument #1 to 'rep' (string expected, got no value)", std.mem.span(api.nilu_tolstring(state, -1, null).?));
    try equal(api.Status.ok, api.nilu_settop(state, 0));
    try equal(api.Status.ok, api.nilu_getglobal(state, "tostring"));
    try equal(api.Status.runtime, api.nilu_call(state, 0, 1));
    try std.testing.expectEqualStrings("bad argument #1 to 'tostring' (value expected)", std.mem.span(api.nilu_tolstring(state, -1, null).?));
    // io and os are the command's.
    for ([_][:0]const u8{ "io", "os" }) |name| {
        try equal(api.Status.ok, api.nilu_getglobal(state, name));
        try equal(@as(c_int, 0), api.nilu_type(state, -1));
    }
    // print is there, and without a writer it says so (ADR 0003).
    try equal(api.Status.ok, api.nilu_settop(state, 0));
    try equal(api.Status.ok, api.nilu_loadnamed(state, "print('lost')", "=t", null));
    try equal(api.Status.runtime, api.nilu_call(state, 0, 0));
    try std.testing.expectEqualStrings("t:1: cannot print: no writer was given to this state", std.mem.span(api.nilu_tolstring(state, -1, null).?));
}

// The refusal is the program's failure value, as lua5.5's is: the length
// the `__len` answered is popped before the message goes on top.
test "stdlib a table function refuses a length that is not an integer with Lua's sentence" {
    defer release();
    const state = try api.create(a);
    defer api.nilu_close(state);
    try equal(api.Status.ok, api.nilu_openlibs(state));
    for ([_][:0]const u8{ "2.5", "'x'" }) |length| {
        var source: [160]u8 = undefined;
        const text = try std.fmt.bufPrintSentinel(&source, "local t = setmetatable({{}}, {{__len = function() return {s} end}}) return select(2, pcall(table.concat, t))", .{length}, 0);
        try equal(api.Status.ok, api.nilu_settop(state, 0));
        try equal(api.Status.ok, api.nilu_loadstring(state, text, null));
        try equal(api.Status.ok, api.nilu_call(state, 0, 1));
        try std.testing.expectEqualStrings("object length is not an integer", std.mem.span(api.nilu_tolstring(state, -1, null).?));
    }
    // A float with an integer value is a length, as in Lua.
    try equal(api.Status.ok, api.nilu_settop(state, 0));
    try equal(api.Status.ok, api.nilu_loadstring(state, "local t = setmetatable({'a', 'b'}, {__len = function() return 2.0 end}) return table.concat(t)", null));
    try equal(api.Status.ok, api.nilu_call(state, 0, 1));
    try std.testing.expectEqualStrings("ab", std.mem.span(api.nilu_tolstring(state, -1, null).?));
}

/// Every allocation failure while the library builds strings and tables is
/// a failure the program sees as `not enough memory` (or the state's own
/// memory failure), never a crash or a wrong answer.
fn allocationCase(allocator: std.mem.Allocator) !void {
    const state = try api.create(allocator);
    defer api.nilu_close(state);
    if (api.nilu_openlibs(state) != .ok) return error.OutOfMemory;
    const source = "local s = string.rep('ab', 20, ',') return string.format('%5.2f|%s', 1.5, string.sub(s, 1, 5)) .. table.concat({'x', 'y'}, '-') .. (string.gsub('hello', 'l', 'L')) .. tostring(#utf8.char(0x3042, 0x3044))";
    if (api.nilu_loadstring(state, source, null) != .ok) return error.OutOfMemory;
    switch (api.nilu_pcall(state, 0, 1, 0)) {
        .ok => try std.testing.expectEqualStrings(" 1.50|ab,abx-yheLLo6", std.mem.span(api.nilu_tolstring(state, -1, null).?)),
        .runtime => {
            try std.testing.expectEqualStrings("not enough memory", std.mem.span(api.nilu_tolstring(state, -1, null).?));
            return error.OutOfMemory;
        },
        .memory => return error.OutOfMemory,
        else => return error.TestUnexpectedResult,
    }
}

test "stdlib every allocation failure is reported as a memory shortage" {
    try allocation_failures.checkAll(a, allocationCase, .{});
}
