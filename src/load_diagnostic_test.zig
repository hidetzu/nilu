const std = @import("std");
const allocation_failures = @import("allocation_failures.zig");
const repeated = @import("repeated_text.zig").repeated;
const runtime = @import("runtime.zig");
const loader = @import("loader.zig");
const chunk_id = @import("chunk_id.zig");
const diagnostic_text = @import("load_diagnostic.zig");
const a = std.testing.allocator;
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
const strings = std.testing.expectEqualStrings;

test "load_diagnostic chunk ids follow literal file and source conventions at exact byte boundaries" {
    var buffer: [60]u8 = undefined;
    for ([_][2][]const u8{
        .{ "=probe", "probe" },                 .{ "@path/test.nilu", "path/test.nilu" },
        .{ "", "[string \"\"]" },               .{ "=", "" },
        .{ "@", "" },                           .{ "return 1", "[string \"return 1\"]" },
        .{ "abc\ndef", "[string \"abc...\"]" }, .{ "abc\rdef", "[string \"abc\rdef\"]" },
    }) |case| {
        const answer = chunk_id.format(&buffer, case[0]);
        try strings(case[1], answer);
        try equal(@as(u8, 0), answer[answer.len]);
    }
    try strings(repeated("a", 59), chunk_id.format(&buffer, "=" ++ repeated("a", 60)));
    try strings(repeated("b", 59), chunk_id.format(&buffer, "@" ++ repeated("b", 59)));
    try strings("..." ++ repeated("b", 55) ++ "z", chunk_id.format(&buffer, "@" ++ repeated("a", 4) ++ repeated("b", 55) ++ "z"));
    try strings("[string \"" ++ repeated("s", 44) ++ "\"]", chunk_id.format(&buffer, repeated("s", 44)));
    try strings("[string \"" ++ repeated("s", 45) ++ "...\"]", chunk_id.format(&buffer, repeated("s", 45)));
    try strings("[string \"...\"]", chunk_id.format(&buffer, "\nignored"));
}

test "load_diagnostic recorded parser words and semantic refusals keep the near split" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    // Semantic positions are checked independently by the scope, control and
    // compiler tests.
    for ([_][2][]const u8{
        .{ "local = 1", "<name> expected near '='" },
        .{ "return (1", "')' expected near <eof>" },
        .{ "local t={} return t[1", "']' expected near <eof>" },
        .{ "local function f() end f(1", "')' expected near <eof>" },
        .{ "local function f end", "'(' expected near 'end'" },
        .{ "if 1 then return 1", "'end' expected near <eof>" },
        .{ "while 1 return 1 end", "'do' expected near 'return'" },
        .{ "for i = 1 do end", "',' expected near 'do'" },
        .{ "for i + 1 do end", "'=' or 'in' expected near '+'" },
        .{ "for k,v t do end", "'in' expected near 't'" },
        .{ "return 1 return 2", "<eof> expected near 'return'" },
        .{ "return 10 + 20)", "<eof> expected near ')'" },
        .{ "return +", "unexpected symbol near '+'" },
        .{ "1 + 2", "unexpected symbol near '1'" },
        .{ "local x 1", "unexpected symbol near '1'" },
        .{ "return $", "unexpected symbol near '$'" },
        .{ "x", "syntax error near 'x'" },
        .{ "break", "break outside loop near 'break'" },
        .{ "return function() return ... end", "cannot use '...' outside a vararg function near '...'" },
        .{ "global x  y = 1", "variable 'y' not declared" },
        .{ "for i=1,3 do i=9 end", "attempt to assign to const variable 'i'" },
    }) |case| {
        var diagnostic: ?loader.Diagnostic = null;
        try std.testing.expectError(error.Syntax, loader.prepare(&state, case[0], "=probe", &diagnostic));
        const message = try diagnostic_text.render(a, case[0], "=probe", diagnostic.?);
        defer a.free(message);
        try expect(std.mem.startsWith(u8, message, "probe:1:"));
        const words = std.mem.indexOf(u8, message, ": ").? + 2;
        try strings(case[1], message[words..]);
    }
}

test "load_diagnostic publishes owned syntax message and successful closure without executing" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    var diagnostic: ?loader.Diagnostic = null;
    try equal(loader.Result.syntax, try loader.load(&state, "local = 1", "@config.nilu", &diagnostic));
    try strings("config.nilu:1:7: <name> expected near '='", state.get(-1).?.unpack().string.bytes);
    try equal(loader.Result.syntax, try loader.load(&state, "return 10 +\n  * 2", "=probe", &diagnostic));
    try strings("probe:2:3: unexpected symbol near '*'", state.get(-1).?.unpack().string.bytes);
    try equal(loader.Result.loaded, try loader.load(&state, "global marker=7 return 9", "=chunk", &diagnostic));
    try expect(diagnostic == null);
    try expect(state.globals.getString("marker").is(.nil));
    try strings("chunk", state.get(-1).?.unpack().closure.prototype.displayName());
    try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
    state.collect();
    try strings("config.nilu:1:7: <name> expected near '='", state.get(2).?.unpack().string.bytes);
    var execution: ?@import("vm.zig").Diagnostic = null;
    try equal(@as(usize, 1), try @import("vm.zig").run(&state, state.get(-1).?.unpack().closure, &execution));
    try expect(state.globals.getString("marker").equal(.from(.{ .number = 7 })));
    try expect(state.get(-1).?.equal(.from(.{ .number = 9 })));
}

fn allocationCase(allocator: std.mem.Allocator, source: []const u8) !void {
    var state = try runtime.State.init(allocator);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    var diagnostic: ?loader.Diagnostic = null;
    _ = loader.load(&state, source, "=allocation", &diagnostic) catch |err| {
        try equal(@as(usize, 1), state.top());
        try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
        return err;
    };
    try equal(@as(usize, 2), state.top());
}
test "load_diagnostic every syntax and successful publication allocation failure preserves caller" {
    try allocation_failures.checkAll(a, allocationCase, .{"local = 1"});
    try allocation_failures.checkAll(a, allocationCase, .{"return 'held'"});
}

test "load_diagnostic pending diagnostics and full stack never add false syntax messages" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    var diagnostic: ?loader.Diagnostic = null;
    try std.testing.expectError(error.PendingDiagnostic, diagnostic_text.render(a, "", "=pending", .{ .compile = .{ .jumps = .{ .kind = .duplicate_label, .name = .{ .start = 0, .end = 0 }, .position = .{ .offset = 0, .line = 1, .column = 1 } } } }));
    try equal(@as(usize, 0), state.top());
    try equal(loader.Result.loaded, try loader.load(&state, "local t={} t.x=1", "=indexed", &diagnostic));
    try equal(@as(usize, 1), state.top());
    try state.setTop(runtime.State.max_stack);
    try std.testing.expectError(error.StackLimit, loader.load(&state, "return 1", "=full", &diagnostic));
    try expect(diagnostic == null);
    try equal(@as(usize, runtime.State.max_stack), state.top());
    try std.testing.expectError(error.InvalidSpan, diagnostic_text.render(a, "", "=invalid", .{ .compile = .{ .names = .{ .kind = .undeclared_global, .name = .{ .start = 0, .end = 99 }, .position = .{ .offset = 0, .line = 1, .column = 1 } } } }));
}

test "load_diagnostic limits retain the recorded words without inventing a function location" {
    const message = try diagnostic_text.render(a, "", "=limits", .{ .compile = .{ .limit = .{ .subject = .registers, .maximum = 200, .position = .{ .offset = 0, .line = 2, .column = 3 } } } });
    defer a.free(message);
    try strings("limits:2:3: too many registers (limit is 200)", message);
}

test "load_diagnostic lexical and escape messages match the recorded offending text" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    for ([_][2][]const u8{
        .{ "return 1e", "malformed number near '1e'" },
        .{ "return 1_0", "malformed number near '1_'" },
        .{ "return \"unfinished", "unfinished string near <eof>" },
        .{ "return \"abc\n", "unfinished string near '\"abc'" },
        .{ "x=1\nlocal s=[[abc", "unfinished long string (starting at line 2) near <eof>" },
        .{ "x=1\n--[==[ abc\n", "unfinished long comment (starting at line 2) near <eof>" },
        .{ "local s=[=x", "invalid long string delimiter near '[='" },
        .{ "return \"\\x\"", "hexadecimal digit expected near '\"\\x\"'" },
        .{ "return \"\\xg1\"", "hexadecimal digit expected near '\"\\xg'" },
        .{ "return \"\\u\"", "missing '{' near '\"\\u\"'" },
        .{ "return \"\\u{110000\"", "missing '}' near '\"\\u{110000\"'" },
        .{ "return \"\\u{80000000}\"", "UTF-8 value too large near '\"\\u{80000000'" },
        .{ "return \"\\256\"", "decimal escape too large near '\"\\256\"'" },
        .{ "return \"\\q\"", "invalid escape sequence near '\"\\q'" },
    }) |case| {
        try state.setTop(0);
        var diagnostic: ?loader.Diagnostic = null;
        try equal(loader.Result.syntax, try loader.load(&state, case[0], "=record", &diagnostic));
        const message = state.get(-1).?.unpack().string.bytes;
        try strings(case[1], message[std.mem.indexOf(u8, message, ": ").? + 2 ..]);
    }
}

test "load_diagnostic goto refusals use goto and duplicate label positions without near" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    for ([_][2][]const u8{
        .{ "goto nowhere\n\nreturn 1", "goto:1:1: no visible label 'nowhere' for <goto> at line 1" },
        .{ "::a::\n::a::", "goto:2:1: label 'a' already defined on line 1" },
        .{ "goto f\nlocal x=1\n::f::\nreturn x", "goto:1:1: <goto f> at line 1 jumps into the scope of 'x'" },
    }) |case| {
        try state.setTop(0);
        var diagnostic: ?loader.Diagnostic = null;
        var where: loader.ErrorLocation = .{ .line = 99, .column = 99 };
        try equal(loader.Result.syntax, try loader.loadLocated(&state, case[0], "=goto", &diagnostic, &where));
        try strings(case[1], state.get(-1).?.unpack().string.bytes);
        try equal(@as(c_int, if (diagnostic.?.compile.jumps.kind == .duplicate_label) 2 else 1), where.line);
        try equal(@as(c_int, 1), where.column);
    }
}

test "load_diagnostic C error coordinates clear on success pending stack and memory outcomes" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    var diagnostic: ?loader.Diagnostic = null;
    var where: loader.ErrorLocation = .{ .line = 99, .column = 99 };
    try equal(loader.Result.syntax, try loader.loadLocated(&state, "return 10 +\n  * 2", "=where", &diagnostic, &where));
    try equal(@as(c_int, 2), where.line);
    try equal(@as(c_int, 3), where.column);
    try equal(loader.Result.syntax, try loader.loadLocated(&state, "return 1e", "=where", &diagnostic, &where));
    try equal(@as(c_int, 1), where.line);
    try equal(@as(c_int, 8), where.column);
    try equal(loader.Result.syntax, try loader.loadLocated(&state, "return \"abc", "=where", &diagnostic, &where));
    try equal(@as(c_int, 1), where.line);
    try equal(@as(c_int, 12), where.column);
    try equal(loader.Result.syntax, try loader.loadLocated(&state, "x=1\n--[==[ abc\n", "=where", &diagnostic, &where));
    try equal(@as(c_int, 3), where.line);
    try equal(@as(c_int, 1), where.column);
    try equal(loader.Result.loaded, try loader.loadLocated(&state, "return 1", "=where", &diagnostic, &where));
    try equal(loader.ErrorLocation{}, where);
    where = .{ .line = 99, .column = 99 };
    try equal(loader.Result.loaded, try loader.loadLocated(&state, "local t={} t.x=1", "=indexed", &diagnostic, &where));
    try equal(loader.ErrorLocation{}, where);
    try state.setTop(0);
    // Force reservation to allocate, so failure occurs before parsing.
    state.stack.deinit(state.allocator);
    state.stack = .empty;
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    const original = state.allocator;
    state.allocator = failing.allocator();
    defer state.allocator = original;
    where = .{ .line = 99, .column = 99 };
    try std.testing.expectError(error.OutOfMemory, loader.loadLocated(&state, "local = 1", "=memory", &diagnostic, &where));
    try equal(loader.ErrorLocation{}, where);
    try equal(@as(usize, 0), state.top());
    state.allocator = original;
    try state.setTop(runtime.State.max_stack);
    where = .{ .line = 99, .column = 99 };
    try std.testing.expectError(error.StackLimit, loader.loadLocated(&state, "return 1", "=full", &diagnostic, &where));
    try equal(loader.ErrorLocation{}, where);
    const too_large: usize = @as(usize, std.math.maxInt(c_int)) + 1;
    try equal(loader.ErrorLocation{}, loader.ErrorLocation.from(.{ .offset = 0, .line = too_large, .column = 1 }));
    try equal(loader.ErrorLocation{}, loader.ErrorLocation.from(.{ .offset = 0, .line = 1, .column = too_large }));
}

fn locatedAllocationCase(allocator: std.mem.Allocator, source: []const u8) !void {
    var state = try runtime.State.init(allocator);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    var diagnostic: ?loader.Diagnostic = null;
    var where: loader.ErrorLocation = .{ .line = 99, .column = 99 };
    _ = loader.loadLocated(&state, source, "=allocation", &diagnostic, &where) catch |err| {
        try equal(loader.ErrorLocation{}, where);
        try equal(@as(usize, 1), state.top());
        try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
        return err;
    };
    try equal(@as(usize, 2), state.top());
    try expect(where.line > 0 and where.column > 0);
}
test "load_diagnostic all lexical escape and goto publication allocation failures clear coordinates" {
    try allocation_failures.checkAll(a, locatedAllocationCase, .{"return 1e"});
    try allocation_failures.checkAll(a, locatedAllocationCase, .{"return \"\\q\""});
    try allocation_failures.checkAll(a, locatedAllocationCase, .{"goto absent"});
}

test "load_diagnostic attributes global environment and nonprintable tokens use recorded sentences" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    for ([_][2][]const u8{
        .{ "local a <close>, b <close> = nil, nil", "multiple to-be-closed variables in local list" },
        .{ "local x <foo>", "unknown attribute 'foo'" },
        .{ "global x <foo>", "unknown attribute 'foo'" },
        .{ "global <close> *", "global variables cannot be to-be-closed" },
        .{ "global _ENV global x=1", "_ENV is global when accessing variable 'x'" },
        .{ "local あ=1", "unexpected symbol near '<\\227>'" },
        .{ "return \x01", "unexpected symbol near '<\\1>'" },
    }) |case| {
        try state.setTop(0);
        var diagnostic: ?loader.Diagnostic = null;
        try equal(loader.Result.syntax, try loader.load(&state, case[0], "=record", &diagnostic));
        const message = state.get(-1).?.unpack().string.bytes;
        try strings(case[1], message[std.mem.indexOf(u8, message, ": ").? + 2 ..]);
    }
}

test "load_diagnostic C coordinates preserve exact int boundary and reject unrepresentable pairs" {
    const maximum: u32 = std.math.maxInt(c_int);
    try equal(loader.ErrorLocation{ .line = std.math.maxInt(c_int), .column = std.math.maxInt(c_int) }, loader.ErrorLocation.from(.{ .offset = 0, .line = maximum, .column = maximum }));
    for ([_]u32{ maximum + 1, std.math.maxInt(u32) }) |overflow| {
        try equal(loader.ErrorLocation{}, loader.ErrorLocation.from(.{ .offset = 0, .line = overflow, .column = 7 }));
        try equal(loader.ErrorLocation{}, loader.ErrorLocation.from(.{ .offset = 0, .line = 7, .column = overflow }));
    }
}

test "load_diagnostic oversized output coordinates do not alter exact diagnostic text" {
    const line: usize = @as(usize, std.math.maxInt(c_int)) + 1;
    const diagnostic = loader.Diagnostic{ .compile = .{ .limit = .{ .subject = .registers, .maximum = 255, .position = .{ .offset = 0, .line = line, .column = 7 } } } };
    const rendered = try diagnostic_text.renderLocated(a, "", "=overflow", diagnostic);
    defer a.free(rendered.bytes);
    const wanted = try std.fmt.allocPrint(a, "overflow:{d}:7: too many registers (limit is 255)", .{line});
    defer a.free(wanted);
    try strings(wanted, rendered.bytes);
    try equal(loader.ErrorLocation{}, loader.ErrorLocation.from(rendered.position));
}

// Offsets, lines and columns are 32-bit, so a longer source is refused before
// a byte of it is read. The length is the slice's alone: nothing reads past
// its one real byte, which is what the test also shows.
test "load_diagnostic a source past the size limit is refused before it is read" {
    const Token = @import("Token.zig");
    const byte: u8 = 'x';
    const huge = @as([*]const u8, @ptrCast(&byte))[0 .. Token.max_source_bytes + 1];
    var parse_diagnostic: ?@import("parser.zig").Diagnostic = null;
    try std.testing.expectError(error.Syntax, @import("parser.zig").parseChunk(a, huge, &parse_diagnostic));
    try expect(parse_diagnostic.? == .chunk_too_large);
    const sentence = try diagnostic_text.render(a, "x", "=huge", .{ .parse = parse_diagnostic.? });
    defer a.free(sentence);
    try strings("huge:1:1: chunk is too large (limit is 4294967294 bytes)", sentence);
    // A source within the limit is read as before.
    var fits: ?@import("parser.zig").Diagnostic = null;
    var ast = try @import("parser.zig").parseChunk(a, "return 1", &fits);
    ast.deinit();
}
