const std = @import("std");
const allocation_failures = @import("allocation_failures.zig");
const bytecode = @import("bytecode.zig");
const names = @import("name_text.zig");
const api = @import("c_api.zig");
const runtime = @import("runtime.zig");
const a = std.testing.allocator;

test "name_text borrowed and static names need no allocation and retain binary bytes" {
    var refusing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    const source = [_]u8{ 'x', 'a', 0, 'b', 'y' };
    const text = try names.resolve(refusing.allocator(), &source, .{ .kind = .field, .text = .{ .span = .{ .start = 1, .end = 4 } } });
    defer text.deinit(refusing.allocator());
    try std.testing.expectEqualSlices(u8, "a\x00b", text.bytes);
    try std.testing.expect(text.bytes.ptr == source[1..].ptr);
    for ([_]bytecode.Name{
        .{ .kind = .local, .text = .environment },
        .{ .kind = .for_iterator, .text = .iterator },
    }) |name| {
        const static_text = try names.resolve(refusing.allocator(), "", name);
        defer static_text.deinit(refusing.allocator());
        try std.testing.expect(static_text.bytes.len != 0 and static_text.allocation == null);
    }
    try std.testing.expectEqual(@as(usize, 0), refusing.alloc_index);
}
fn decodedCase(allocator: std.mem.Allocator) !void {
    const source = "prefix a\\000\\u{1f600} suffix";
    const text = try names.resolve(allocator, source, .{ .kind = .field, .text = .{ .literal = .{ .contents = .{ .start = 7, .end = source.len - 7 }, .long_level = null } } });
    defer text.deinit(allocator);
    try std.testing.expectEqualSlices(u8, "a\x00\xf0\x9f\x98\x80", text.bytes);
    try std.testing.expect(text.allocation != null);
}
test "name_text decoding owns complete NUL UTF8 bytes and cleans each allocation failure" {
    try allocation_failures.checkAll(a, decodedCase, .{});
    const invalid = [_]bytecode.Name{
        .{ .kind = .field, .text = .{ .span = .{ .start = 2, .end = 1 } } },
        .{ .kind = .field, .text = .{ .span = .{ .start = 0, .end = 100 } } },
        .{ .kind = .field, .text = .{ .literal = .{ .contents = .{ .start = 0, .end = 2 }, .long_level = null } } },
    };
    for (invalid) |name| try std.testing.expectError(error.InvalidSpan, names.resolve(a, "\\q", name));
}
test "name_text public runtime failure prose still truncates decoded names at NUL" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    const cases = [_]struct { source: [*:0]const u8, tail: []const u8 }{
        .{ .source = "local t={} return t['a\\000b']()", .tail = "(field 'a')" },
        .{ .source = "local t={} return t['\\120']()", .tail = "(field 'x')" },
        .{ .source = "local t={} return t['']()", .tail = "(field '')" },
    };
    for (cases) |case| {
        try std.testing.expectEqual(api.Status.ok, api.nilu_settop(&state, 0));
        try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(&state, case.source, "=names", null));
        try std.testing.expectEqual(api.Status.type, api.nilu_call(&state, 0, 0));
        const words = state.get(-1).?.unpack().string.bytes;
        try std.testing.expect(std.mem.endsWith(u8, words, case.tail));
        state.collect();
    }
}
