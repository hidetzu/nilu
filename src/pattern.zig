//! Lua patterns (manual 10.2): `find`, `match`, `gmatch` and `gsub`, with the
//! same notation, the same sentences for a malformed pattern, and the same
//! limits (32 captures, matching depth 200). The character classes are ASCII,
//! since the core has no locale (13.1). Matching borrows the subject and the
//! pattern from their stack slots and allocates nothing of its own.
const std = @import("std");
const api = @import("c_api.zig");
const stdlib = @import("stdlib.zig");
const string_library = @import("stdlib_string.zig");

const Call = stdlib.Call;
const Error = stdlib.Error;
const Buffer = stdlib.Buffer;

const max_captures = 32;
const max_depth = 200;
const specials = "^$*+?.([%-";

const Capture = union(enum) { unfinished: void, position: void, span: usize };

const Matcher = struct {
    call: Call,
    source: []const u8,
    pattern: []const u8,
    level: usize = 0,
    starts: [max_captures]usize = undefined,
    captures: [max_captures]Capture = undefined,
    depth: usize = max_depth,

    fn reset(self: *Matcher) void {
        self.level = 0;
        self.depth = max_depth;
    }

    fn classEnd(self: *Matcher, start: usize) Error!usize {
        var p = start;
        const c = self.pattern[p];
        p += 1;
        if (c == '%') {
            if (p >= self.pattern.len) return self.call.raise("malformed pattern (ends with '%')");
            return p + 1;
        }
        if (c == '[') {
            if (p < self.pattern.len and self.pattern[p] == '^') p += 1;
            while (true) {
                if (p >= self.pattern.len) return self.call.raise("malformed pattern (missing ']')");
                const inner = self.pattern[p];
                p += 1;
                if (inner == '%') {
                    if (p >= self.pattern.len) return self.call.raise("malformed pattern (missing ']')");
                    p += 1;
                }
                if (p < self.pattern.len and self.pattern[p] == ']') break;
                if (p >= self.pattern.len) return self.call.raise("malformed pattern (missing ']')");
            }
            return p + 1;
        }
        return p;
    }

    fn matchClass(c: u8, class: u8) bool {
        const answer = switch (std.ascii.toLower(class)) {
            'a' => std.ascii.isAlphabetic(c),
            'c' => std.ascii.isControl(c),
            'd' => std.ascii.isDigit(c),
            'g' => std.ascii.isPrint(c) and c != ' ',
            'l' => std.ascii.isLower(c),
            'p' => std.ascii.isPrint(c) and c != ' ' and !std.ascii.isAlphanumeric(c),
            's' => std.ascii.isWhitespace(c),
            'u' => std.ascii.isUpper(c),
            'w' => std.ascii.isAlphanumeric(c),
            'x' => std.ascii.isHex(c),
            else => return class == c,
        };
        return if (std.ascii.isUpper(class)) !answer else answer;
    }

    /// `p` is at the `[`, `ec` at the closing `]`.
    fn matchBracketClass(self: *Matcher, c: u8, start: usize, ec: usize) bool {
        var p = start;
        var sig = true;
        if (self.pattern[p + 1] == '^') {
            sig = false;
            p += 1;
        }
        p += 1;
        while (p < ec) : (p += 1) {
            if (self.pattern[p] == '%') {
                p += 1;
                if (matchClass(c, self.pattern[p])) return sig;
            } else if (self.pattern[p + 1] == '-' and p + 2 < ec) {
                p += 2;
                if (self.pattern[p - 2] <= c and c <= self.pattern[p]) return sig;
            } else if (self.pattern[p] == c) return sig;
        }
        return !sig;
    }

    fn singleMatch(self: *Matcher, s: usize, p: usize, ep: usize) bool {
        if (s >= self.source.len) return false;
        const c = self.source[s];
        return switch (self.pattern[p]) {
            '.' => true,
            '%' => matchClass(c, self.pattern[p + 1]),
            '[' => self.matchBracketClass(c, p, ep - 1),
            else => |byte| byte == c,
        };
    }

    fn matchBalance(self: *Matcher, start: usize, p: usize) Error!?usize {
        if (p + 1 >= self.pattern.len) return self.call.raise("malformed pattern (missing arguments to '%b')");
        var s = start;
        if (s >= self.source.len or self.source[s] != self.pattern[p]) return null;
        const open = self.pattern[p];
        const close = self.pattern[p + 1];
        var count: usize = 1;
        s += 1;
        while (s < self.source.len) : (s += 1) {
            if (self.source[s] == close) {
                count -= 1;
                if (count == 0) return s + 1;
            } else if (self.source[s] == open) count += 1;
        }
        return null;
    }

    fn maxExpand(self: *Matcher, s: usize, p: usize, ep: usize) Error!?usize {
        var count: usize = 0;
        while (self.singleMatch(s + count, p, ep)) count += 1;
        while (true) {
            if (try self.doMatch(s + count, ep + 1)) |result| return result;
            if (count == 0) return null;
            count -= 1;
        }
    }

    fn minExpand(self: *Matcher, start: usize, p: usize, ep: usize) Error!?usize {
        var s = start;
        while (true) {
            if (try self.doMatch(s, ep + 1)) |result| return result;
            if (self.singleMatch(s, p, ep)) s += 1 else return null;
        }
    }

    fn startCapture(self: *Matcher, s: usize, p: usize, what: Capture) Error!?usize {
        if (self.level >= max_captures) return self.call.raise("too many captures");
        self.starts[self.level] = s;
        self.captures[self.level] = what;
        self.level += 1;
        const result = try self.doMatch(s, p);
        if (result == null) self.level -= 1;
        return result;
    }

    fn endCapture(self: *Matcher, s: usize, p: usize) Error!?usize {
        const index = try self.captureToClose();
        self.captures[index] = .{ .span = s - self.starts[index] };
        const result = try self.doMatch(s, p);
        if (result == null) self.captures[index] = .unfinished;
        return result;
    }

    fn captureToClose(self: *Matcher) Error!usize {
        var level = self.level;
        while (level > 0) {
            level -= 1;
            if (self.captures[level] == .unfinished) return level;
        }
        return self.call.raise("invalid pattern capture");
    }

    fn checkCapture(self: *Matcher, digit: u8) Error!usize {
        const index: i64 = @as(i64, digit) - '1';
        if (index < 0 or index >= self.level or self.captures[@intCast(index)] == .unfinished) {
            var buffer: [48]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "invalid capture index %{d}", .{index + 1}) catch "invalid capture index";
            return self.call.raise(text);
        }
        return @intCast(index);
    }

    fn matchCapture(self: *Matcher, s: usize, digit: u8) Error!?usize {
        const index = try self.checkCapture(digit);
        const length = self.captures[index].span;
        const start = self.starts[index];
        if (self.source.len - s >= length and std.mem.eql(u8, self.source[start .. start + length], self.source[s .. s + length])) return s + length;
        return null;
    }

    /// Returns the end of the match of pattern[p..] at source[s..], or null.
    fn doMatch(self: *Matcher, start: usize, pattern_start: usize) Error!?usize {
        if (self.depth == 0) return self.call.raise("pattern too complex");
        self.depth -= 1;
        defer self.depth += 1;
        var s = start;
        var p = pattern_start;
        while (true) {
            if (p >= self.pattern.len) return s;
            switch (self.pattern[p]) {
                '(' => {
                    if (p + 1 < self.pattern.len and self.pattern[p + 1] == ')') return self.startCapture(s, p + 2, .position);
                    return self.startCapture(s, p + 1, .unfinished);
                },
                ')' => return self.endCapture(s, p + 1),
                '$' => {
                    if (p + 1 == self.pattern.len) return if (s == self.source.len) s else null;
                },
                '%' => {
                    if (p + 1 < self.pattern.len) switch (self.pattern[p + 1]) {
                        'b' => {
                            s = (try self.matchBalance(s, p + 2)) orelse return null;
                            p += 4;
                            continue;
                        },
                        'f' => {
                            p += 2;
                            if (p >= self.pattern.len or self.pattern[p] != '[') return self.call.raise("missing '[' after '%f' in pattern");
                            const ep = try self.classEnd(p);
                            const previous: u8 = if (s == 0) 0 else self.source[s - 1];
                            const current: u8 = if (s < self.source.len) self.source[s] else 0;
                            if (!self.matchBracketClass(previous, p, ep - 1) and self.matchBracketClass(current, p, ep - 1)) {
                                p = ep;
                                continue;
                            }
                            return null;
                        },
                        '0'...'9' => {
                            s = (try self.matchCapture(s, self.pattern[p + 1])) orelse return null;
                            p += 2;
                            continue;
                        },
                        else => {},
                    };
                },
                else => {},
            }
            const ep = try self.classEnd(p);
            const suffix: u8 = if (ep < self.pattern.len) self.pattern[ep] else 0;
            if (!self.singleMatch(s, p, ep)) {
                if (suffix == '*' or suffix == '?' or suffix == '-') {
                    p = ep + 1;
                    continue;
                }
                return null;
            }
            switch (suffix) {
                '?' => {
                    if (try self.doMatch(s + 1, ep + 1)) |result| return result;
                    p = ep + 1;
                    continue;
                },
                '+' => return self.maxExpand(s + 1, p, ep),
                '*' => return self.maxExpand(s, p, ep),
                '-' => return self.minExpand(s, p, ep),
                else => {
                    s += 1;
                    p = ep;
                },
            }
        }
    }

    /// Pushes capture `index`, or the whole match when there are no captures.
    fn pushCapture(self: *Matcher, index: usize, s: usize, e: usize) Error!void {
        if (index >= self.level) {
            if (index != 0) {
                var buffer: [48]u8 = undefined;
                const text = std.fmt.bufPrint(&buffer, "invalid capture index %{d}", .{index + 1}) catch "invalid capture index";
                return self.call.raise(text);
            }
            return self.call.push(self.source[s..e]);
        }
        const start = self.starts[index];
        switch (self.captures[index]) {
            .unfinished => return self.call.raise("unfinished capture"),
            .position => try self.call.pushInteger(@intCast(start + 1)),
            .span => |length| try self.call.push(self.source[start .. start + length]),
        }
    }

    fn pushCaptures(self: *Matcher, whole: ?usize, e: usize) Error!c_int {
        const count: usize = if (self.level == 0 and whole != null) 1 else self.level;
        var index: usize = 0;
        while (index < count) : (index += 1) try self.pushCapture(index, whole orelse 0, e);
        return @intCast(count);
    }
};

fn hasSpecials(text: []const u8) bool {
    for (text) |byte| if (std.mem.indexOfScalar(u8, specials, byte) != null) return true;
    return false;
}

fn findOrMatch(call: Call, finding: bool) Error!c_int {
    const source = try call.checkString(1);
    const pattern_text = try call.checkString(2);
    const init = string_library.startPosition(try call.optInteger(3, 1), source.len);
    if (init > source.len + 1) {
        try call.pushNil();
        return 1;
    }
    if (finding and (call.truthy(4) or !hasSpecials(pattern_text))) {
        if (std.mem.indexOf(u8, source[init - 1 ..], pattern_text)) |offset| {
            const start = init - 1 + offset;
            try call.pushInteger(@intCast(start + 1));
            try call.pushInteger(@intCast(start + pattern_text.len));
            return 2;
        }
        try call.pushNil();
        return 1;
    }
    var matcher = Matcher{ .call = call, .source = source, .pattern = pattern_text };
    const anchor = pattern_text.len > 0 and pattern_text[0] == '^';
    var s = init - 1;
    const p: usize = if (anchor) 1 else 0;
    while (true) {
        matcher.reset();
        if (try matcher.doMatch(s, p)) |e| {
            if (finding) {
                try call.pushInteger(@intCast(s + 1));
                try call.pushInteger(@intCast(e));
                return 2 + try matcher.pushCaptures(null, e);
            }
            return matcher.pushCaptures(s, e);
        }
        s += 1;
        if (anchor or s > source.len) break;
    }
    try call.pushNil();
    return 1;
}

pub fn find(call: Call) Error!c_int {
    return findOrMatch(call, true);
}
pub fn match(call: Call) Error!c_int {
    return findOrMatch(call, false);
}

/// The iterator's progress, kept in a userdata upvalue beside the two strings.
const Progress = extern struct { position: usize, last_match: usize };

fn gmatchStep(call: Call) Error!c_int {
    try call.check(api.nilu_getupvalue(call.state, 1));
    try call.check(api.nilu_getupvalue(call.state, 2));
    try call.check(api.nilu_getupvalue(call.state, 3));
    const source = call.bytesAt(-3);
    const pattern_text = call.bytesAt(-2);
    const progress: *Progress = @ptrCast(@alignCast(api.nilu_touserdata(call.state, -1) orelse return error.Stack));
    var matcher = Matcher{ .call = call, .source = source, .pattern = pattern_text };
    var s = progress.position;
    while (s <= source.len) : (s += 1) {
        matcher.reset();
        if (try matcher.doMatch(s, 0)) |e| {
            if (e == progress.last_match) continue;
            progress.position = e;
            progress.last_match = e;
            return matcher.pushCaptures(s, e);
        }
    }
    return 0;
}

pub fn gmatch(call: Call) Error!c_int {
    const source = try call.checkString(1);
    _ = try call.checkString(2);
    const init = string_library.startPosition(try call.optInteger(3, 1), source.len);
    try call.setTop(2);
    var block: ?*anyopaque = null;
    try call.check(api.nilu_newuserdata(call.state, @sizeOf(Progress), &block));
    const progress: *Progress = @ptrCast(@alignCast(block.?));
    progress.* = .{ .position = @min(init - 1, source.len + 1), .last_match = std.math.maxInt(usize) };
    try call.check(api.nilu_pushcclosure(call.state, stdlib.entry("gmatch", gmatchStep), 3));
    return 1;
}

fn addString(matcher: *Matcher, buffer: *Buffer, s: usize, e: usize) Error!void {
    const call = matcher.call;
    const replacement = call.bytesAt(3);
    var index: usize = 0;
    while (index < replacement.len) : (index += 1) {
        const byte = replacement[index];
        if (byte != '%') {
            try buffer.appendByte(byte);
            continue;
        }
        index += 1;
        if (index >= replacement.len) return call.raise("invalid use of '%' in replacement string");
        const next = replacement[index];
        if (next == '%') {
            try buffer.appendByte('%');
        } else if (std.ascii.isDigit(next)) {
            if (next == '0') {
                try buffer.append(matcher.source[s..e]);
            } else {
                try matcher.pushCapture(next - '1', s, e);
                if (call.typeAt(-1) == .number) {
                    try stdlib.pushToString(call, -1);
                    call.remove(-2);
                }
                try buffer.append(call.bytesAt(-1));
                call.pop(1);
            }
        } else return call.raise("invalid use of '%' in replacement string");
    }
}

fn addValue(matcher: *Matcher, buffer: *Buffer, s: usize, e: usize, kind: stdlib.Type) Error!void {
    const call = matcher.call;
    switch (kind) {
        .string => return addString(matcher, buffer, s, e),
        .function => {
            try call.pushValue(3);
            const count = try matcher.pushCaptures(s, e);
            try call.check(api.nilu_call(call.state, count, 1));
        },
        else => {
            try call.pushValue(3);
            try matcher.pushCapture(0, s, e);
            try call.check(api.nilu_gettable(call.state, -2));
            call.remove(-2);
        },
    }
    switch (call.typeAt(-1)) {
        .nil => {
            call.pop(1);
            try buffer.append(matcher.source[s..e]);
        },
        .boolean => {
            if (call.truthy(-1)) return call.raise("invalid replacement value (a boolean)");
            call.pop(1);
            try buffer.append(matcher.source[s..e]);
        },
        .string => {
            try buffer.append(call.bytesAt(-1));
            call.pop(1);
        },
        .number => {
            try stdlib.pushToString(call, -1);
            try buffer.append(call.bytesAt(-1));
            call.pop(2);
        },
        else => |other| {
            var sentence: [64]u8 = undefined;
            const text = std.fmt.bufPrint(&sentence, "invalid replacement value (a {s})", .{stdlib.typeName(other)}) catch "invalid replacement value";
            return call.raise(text);
        },
    }
}

pub fn gsub(call: Call) Error!c_int {
    const source = try call.checkString(1);
    const pattern_text = try call.checkString(2);
    const kind = call.typeAt(3);
    if (kind != .string and kind != .number and kind != .table and kind != .function) return call.typeError(3, "string/function/table");
    if (kind == .number) {
        // A number replacement has Nilu's spelling (13.1).
        try stdlib.pushToString(call, 3);
        api.nilu_copy(call.state, -1, 3);
        call.pop(1);
    }
    const limit = try call.optInteger(4, std.math.maxInt(i64));
    const anchor = pattern_text.len > 0 and pattern_text[0] == '^';
    var matcher = Matcher{ .call = call, .source = source, .pattern = if (anchor) pattern_text[1..] else pattern_text };
    var buffer = try Buffer.init(call, source.len);
    var s: usize = 0;
    var last_match: ?usize = null;
    var count: i64 = 0;
    const replacement_kind: stdlib.Type = if (kind == .number) .string else kind;
    while (count < limit) {
        matcher.reset();
        const matched = try matcher.doMatch(s, 0);
        if (matched != null and matched.? != last_match) {
            count += 1;
            try addValue(&matcher, &buffer, s, matched.?, replacement_kind);
            s = matched.?;
            last_match = matched;
        } else if (s < source.len) {
            try buffer.appendByte(source[s]);
            s += 1;
        } else break;
        if (anchor) break;
    }
    if (s < source.len) try buffer.append(source[s..]);
    try buffer.finish();
    try call.pushInteger(@intCast(count));
    return 2;
}
