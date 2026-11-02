const std = @import("std");

/// Lua's chunk-id convention, 60 bytes including the sentinel.
/// The input is a C-name payload (without its terminating zero). Truncation is
/// by bytes. An ordinary string stops at LF; literal/file names do not.
pub const capacity = 60;
pub fn format(buffer: *[capacity]u8, name: []const u8) [:0]const u8 {
    var length: usize = 0;
    if (name.len > 0 and name[0] == '=') {
        length = @min(name.len - 1, capacity - 1);
        @memcpy(buffer[0..length], name[1..][0..length]);
    } else if (name.len > 0 and name[0] == '@') {
        const path = name[1..];
        if (path.len < capacity) {
            length = path.len;
            @memcpy(buffer[0..length], path);
        } else {
            @memcpy(buffer[0..3], "...");
            @memcpy(buffer[3 .. capacity - 1], path[path.len - (capacity - 4) ..]);
            length = capacity - 1;
        }
    } else {
        const prefix = "[string \"";
        const suffix = "\"]";
        const payload_limit = capacity - prefix.len - suffix.len - 3 - 1;
        const newline = std.mem.indexOfScalar(u8, name, '\n');
        const end = newline orelse name.len;
        const shortened = newline != null or name.len >= payload_limit;
        const copied = if (shortened) @min(end, payload_limit) else end;
        @memcpy(buffer[0..prefix.len], prefix);
        @memcpy(buffer[prefix.len..][0..copied], name[0..copied]);
        length = prefix.len + copied;
        if (shortened) {
            @memcpy(buffer[length..][0..3], "...");
            length += 3;
        }
        @memcpy(buffer[length..][0..suffix.len], suffix);
        length += suffix.len;
    }
    buffer[length] = 0;
    return buffer[0..length :0];
}
