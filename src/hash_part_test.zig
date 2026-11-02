//! A table's hash part on its own: keys found past the marks of keys taken
//! out and across growth, the zeros one key, equal strings that are
//! different objects one key, and traversal visiting each key once.
const std = @import("std");
const runtime = @import("runtime.zig");
const HashPart = @import("HashPart.zig");
const Value = runtime.Value;
const a = std.testing.allocator;

fn number(n: f64) Value {
    return .from(.{ .number = n });
}

test "hash_part finds keys past removed ones and after growth" {
    var part: HashPart = .{};
    defer part.deinit(a);
    for (1..200) |i| _ = try part.insert(a, number(@floatFromInt(i)), number(@floatFromInt(i * 10)));
    try std.testing.expectEqual(@as(u32, 199), part.count);
    // Take out every other key; the rest are still reached past the marks.
    for (1..200) |i| if (i % 2 == 0) part.remove(part.find(number(@floatFromInt(i))).?);
    for (1..200) |i| {
        const found = part.get(number(@floatFromInt(i)));
        if (i % 2 == 0) try std.testing.expect(found == null) else try std.testing.expectEqual(@as(f64, @floatFromInt(i * 10)), found.?.numberValue().?);
    }
    try std.testing.expectEqual(@as(u32, 100), part.count);
    var visited: usize = 0;
    var index: usize = 0;
    while (part.nextKey(index)) |at| : (index = at + 1) visited += 1;
    try std.testing.expectEqual(@as(usize, 100), visited);
    // Inserting again fills marks and grows without losing a key.
    for (200..400) |i| _ = try part.insert(a, number(@floatFromInt(i)), number(1));
    for (1..400) |i| try std.testing.expectEqual(i % 2 == 1 or i >= 200, part.find(number(@floatFromInt(i))) != null);
}

test "hash_part a stated size takes the fewest slots and fills them without moving" {
    for (1..70) |total| {
        var part: HashPart = .{};
        defer part.deinit(a);
        try part.reserve(a, total);
        // The smallest power of two, at least 4, holding `total` at 75%;
        // none when the first key's slots hold them anyway.
        var least: usize = 4;
        while (total * 4 > least * 3) least *= 2;
        try std.testing.expectEqual(if (total <= 3) 0 else least, part.slots.len);
        if (total <= 3) continue;
        for (0..total) |i| try std.testing.expect(!try part.insert(a, number(@floatFromInt(i)), number(1)));
        // One more key regrows them.
        if (part.slots.len == least and (total + 1) * 4 > least * 3) try std.testing.expect(try part.insert(a, number(-1), number(1)));
    }
    var none: HashPart = .{};
    try none.reserve(a, 0);
    try std.testing.expectEqual(@as(usize, 0), none.slots.len);
}

test "hash_part the zeros are one key and equal strings are one key" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    var part: HashPart = .{};
    defer part.deinit(a);
    _ = try part.insert(a, number(-0.0), number(1));
    try std.testing.expectEqual(@as(f64, 1), part.get(number(0)).?.numberValue().?);
    const first = try state.newString("field");
    const second = try state.newString("field");
    try std.testing.expect(first != second);
    _ = try part.insert(a, .from(.{ .string = first }), number(2));
    try std.testing.expectEqual(@as(f64, 2), part.get(.from(.{ .string = second })).?.numberValue().?);
    try std.testing.expect(part.findString("field", second.hash) != null);
    try std.testing.expect(part.findString("other", 0) == null);
}
