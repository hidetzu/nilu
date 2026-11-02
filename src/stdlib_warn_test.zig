//! `warn`, `string.format`'s `%p` and `table.create`.
const std = @import("std");
const api = @import("c_api.zig");
const runtime = @import("runtime.zig");
const a = std.testing.allocator;

var written: std.ArrayListUnmanaged(u8) = .empty;

/// Keeps each call as `kind:text|`, the kind being the second argument or `-`.
fn keep(state: *runtime.State) callconv(.c) c_int {
    var length: usize = 0;
    const text = api.nilu_tolstring(state, 1, &length) orelse return api.fail;
    const kind: []const u8 = if (api.nilu_type(state, 2) == @backingInt(api.Type.string)) std.mem.span(api.nilu_tolstring(state, 2, null).?) else "-";
    written.appendSlice(a, kind) catch return api.fail;
    written.append(a, ':') catch return api.fail;
    written.appendSlice(a, text[0..length]) catch return api.fail;
    written.append(a, '|') catch return api.fail;
    return 0;
}

fn opened(with_writer: bool) !*runtime.State {
    written.clearRetainingCapacity();
    const state = try api.create(a);
    errdefer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_openlibs(state));
    if (with_writer) {
        try std.testing.expectEqual(api.Status.ok, api.nilu_pushcfunction(state, keep));
        try std.testing.expectEqual(api.Status.ok, api.nilu_setwriter(state));
    }
    return state;
}

fn answer(state: *runtime.State, source: [:0]const u8) ![]const u8 {
    _ = api.nilu_settop(state, 0);
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state, source, "=t", null));
    _ = api.nilu_pcall(state, 0, 1, 0);
    return std.mem.span(api.nilu_tolstring(state, -1, null) orelse "(none)");
}

test "stdlib_warn a warning reaches the writer marked as one, only while warnings are on" {
    defer {
        written.deinit(a);
        written = .empty;
    }
    const state = try opened(true);
    defer api.nilu_close(state);
    _ = try answer(state, "warn('off by default') warn('@on') warn('a', 'b') warn('@unknown') warn('@off') warn('gone') warn('@on') print('p') warn('c') return ''");
    try std.testing.expectEqualStrings("warning:Nilu warning: ab\n|-:p\n|warning:Nilu warning: c\n|", written.items);
    try std.testing.expectEqualStrings("t:1: bad argument #2 to 'warn' (string expected, got number)", try answer(state, "warn('x', 1)"));
    try std.testing.expectEqualStrings("t:1: bad argument #1 to 'warn' (string expected, got no value)", try answer(state, "warn()"));
}

test "stdlib_warn without a writer a warning does nothing" {
    const state = try opened(false);
    defer api.nilu_close(state);
    try std.testing.expectEqualStrings("done", try answer(state, "warn('@on') warn('nowhere') return 'done'"));
}

test "stdlib_warn %p writes an object's address and (null) for any other value" {
    const state = try opened(false);
    defer api.nilu_close(state);
    try std.testing.expectEqualStrings("true true (null) [(null)      ] 16", try answer(state,
        \\local t = {}
        \\local same = string.format("%p", t) == tostring(t):match("0x%x+")
        \\return table.concat({tostring(same), tostring(string.format("%p", "s"):match("^0x%x+$") ~= nil),
        \\  string.format("%p", nil), string.format("[%-12p]", 1), tostring(#string.format("[%10p]", {}))}, " ")
    ));
    try std.testing.expectEqualStrings("t:1: invalid conversion specification: '%.3p'", try answer(state, "return string.format('%.3p', {})"));
}

test "stdlib_warn table.create makes an empty table and refuses sizes out of range" {
    const state = try opened(false);
    defer api.nilu_close(state);
    try std.testing.expectEqualStrings("0 nil 2", try answer(state, "local t = table.create(8, 4) local n = #t t[1], t.x = 1, 2 return n .. ' ' .. tostring(next(table.create(3))) .. ' ' .. t.x"));
    try std.testing.expectEqualStrings("t:1: bad argument #1 to 'create' (out of range)", try answer(state, "return table.create(-1)"));
    try std.testing.expectEqualStrings("t:1: bad argument #2 to 'create' (out of range)", try answer(state, "return table.create(1, 2^31)"));
}
