const std = @import("std");

pub fn encode(buffer: *[6]u8, value: u32) error{ValueTooLarge}![]const u8 {
    if (value > 0x7fffffff) return error.ValueTooLarge;
    const length: usize = if (value <= 0x7f) 1 else if (value <= 0x7ff) 2 else if (value <= 0xffff) 3 else if (value <= 0x1fffff) 4 else if (value <= 0x3ffffff) 5 else 6;
    var remaining = value;
    var index = length;
    while (index > 1) {
        index -= 1;
        buffer[index] = 0x80 | @as(u8, @intCast(remaining & 0x3f));
        remaining >>= 6;
    }
    buffer[0] = @as(u8, @intCast(remaining)) | (if (length == 1) @as(u8, 0) else @as(u8, 0xff) << @as(u3, @intCast(8 - length)));
    return buffer[0..length];
}

test "extended UTF-8 boundaries preserve the recorded non-Unicode range" {
    const cases = .{
        .{ @as(u32, 0), "\x00" },                              .{ @as(u32, 0x7f), "\x7f" },
        .{ @as(u32, 0x80), "\xc2\x80" },                       .{ @as(u32, 0x7ff), "\xdf\xbf" },
        .{ @as(u32, 0x800), "\xe0\xa0\x80" },                  .{ @as(u32, 0xd800), "\xed\xa0\x80" },
        .{ @as(u32, 0xffff), "\xef\xbf\xbf" },                 .{ @as(u32, 0x10000), "\xf0\x90\x80\x80" },
        .{ @as(u32, 0x1fffff), "\xf7\xbf\xbf\xbf" },           .{ @as(u32, 0x200000), "\xf8\x88\x80\x80\x80" },
        .{ @as(u32, 0x3ffffff), "\xfb\xbf\xbf\xbf\xbf" },      .{ @as(u32, 0x4000000), "\xfc\x84\x80\x80\x80\x80" },
        .{ @as(u32, 0x7fffffff), "\xfd\xbf\xbf\xbf\xbf\xbf" },
    };
    var buffer: [6]u8 = undefined;
    inline for (cases) |case| try std.testing.expectEqualStrings(case[1], try encode(&buffer, case[0]));
    try std.testing.expectError(error.ValueTooLarge, encode(&buffer, 0x80000000));
}
