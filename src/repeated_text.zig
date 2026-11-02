//! Source text for tests, built at compile time.

/// `text` written `count` times. The bytes are a container-level constant,
/// so they are computed once at compile time and live in the binary; a local
/// array would be built on the caller's stack and its address would outlive
/// it. One `@splat` and a reinterpretation, so a count in the hundreds of
/// thousands needs no loop at compile time. Inline, so that the result is
/// comptime-known and `++` with it joins at compile time too.
pub inline fn repeated(comptime text: []const u8, comptime count: usize) *const [text.len * count]u8 {
    return &Repeated(text, count).bytes;
}

fn Repeated(comptime text: []const u8, comptime count: usize) type {
    return struct {
        const rows: [count][text.len]u8 = @splat(text[0..text.len].*);
        const bytes: [text.len * count]u8 = @bitCast(rows);
    };
}
