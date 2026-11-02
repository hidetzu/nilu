//! `print` and the host's writer (ADR 0003), through the C API.
const std = @import("std");
const api = @import("c_api.zig");
const runtime = @import("runtime.zig");
const a = std.testing.allocator;

var lines: std.ArrayListUnmanaged(u8) = .empty;
var calls: usize = 0;

/// Keeps every line, with a '|' after each call, so the calls can be counted.
fn keep(state: *runtime.State) callconv(.c) c_int {
    var length: usize = 0;
    const text = api.nilu_tolstring(state, 1, &length) orelse return api.fail;
    lines.appendSlice(a, text[0..length]) catch return api.fail;
    lines.append(a, '|') catch return api.fail;
    calls += 1;
    return 0;
}

fn release() void {
    lines.deinit(a);
    lines = .empty;
}

fn opened() !*runtime.State {
    lines.clearRetainingCapacity();
    calls = 0;
    const state = try api.create(a);
    errdefer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_openlibs(state));
    return state;
}

fn run(state: *runtime.State, source: [:0]const u8) api.Status {
    _ = api.nilu_settop(state, 0);
    if (api.nilu_loadnamed(state, source, "=t", null) != .ok) return .syntax;
    return api.nilu_call(state, 0, 0);
}

test "stdlib_print each print is one writer call with the whole line" {
    defer release();
    const state = try opened();
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushcfunction(state, keep));
    try std.testing.expectEqual(api.Status.ok, api.nilu_setwriter(state));
    try std.testing.expectEqual(api.Status.ok, run(state, "print('a', 1, nil, true) print() print({} == nil)"));
    try std.testing.expectEqualStrings("a\t1\tnil\ttrue\n|\n|false\n|", lines.items);
    try std.testing.expectEqual(@as(usize, 3), calls);
}

test "stdlib_print a refusal from tostring writes nothing" {
    defer release();
    const state = try opened();
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushcfunction(state, keep));
    try std.testing.expectEqual(api.Status.ok, api.nilu_setwriter(state));
    try std.testing.expectEqual(api.Status.runtime, run(state, "local n = 0 tostring = function(v) n = n + 1 if n == 2 then return {} end return 'x' end print(1, 2, 3)"));
    try std.testing.expectEqualStrings("t:1: 'tostring' must return a string to 'print'", std.mem.span(api.nilu_tolstring(state, -1, null).?));
    try std.testing.expectEqual(@as(usize, 0), calls);
}

test "stdlib_print without a writer it fails, and a writer's failure is passed on" {
    defer release();
    const state = try opened();
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.runtime, run(state, "print('lost')"));
    try std.testing.expectEqualStrings("t:1: cannot print: no writer was given to this state", std.mem.span(api.nilu_tolstring(state, -1, null).?));
    _ = api.nilu_settop(state, 0);
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state, "return function(line) error('full: ' .. line, 0) end", "=w", null));
    try std.testing.expectEqual(api.Status.ok, api.nilu_call(state, 0, 1));
    try std.testing.expectEqual(api.Status.ok, api.nilu_setwriter(state));
    try std.testing.expectEqual(api.Status.runtime, run(state, "print('x')"));
    try std.testing.expectEqualStrings("full: x\n", std.mem.span(api.nilu_tolstring(state, -1, null).?));
}

test "stdlib_print nilu_setwriter refuses a value that is not a function and the writer is a collector root" {
    defer release();
    const state = try opened();
    defer api.nilu_close(state);
    try std.testing.expectEqual(api.Status.ok, api.nilu_pushnumber(state, 1));
    try std.testing.expectEqual(api.Status.type, api.nilu_setwriter(state));
    try std.testing.expectEqual(@as(c_int, 1), api.nilu_gettop(state));
    _ = api.nilu_settop(state, 0);
    // A script writer held by nothing but the state survives a collection.
    try std.testing.expectEqual(api.Status.ok, api.nilu_loadnamed(state, "local kept = {} return function(line) kept[#kept + 1] = line written = #kept end", "=w", null));
    try std.testing.expectEqual(api.Status.ok, api.nilu_call(state, 0, 1));
    try std.testing.expectEqual(api.Status.ok, api.nilu_setwriter(state));
    state.collect();
    try std.testing.expectEqual(api.Status.ok, run(state, "print('one') print('two')"));
    try std.testing.expectEqual(api.Status.ok, api.nilu_getglobal(state, "written"));
    try std.testing.expectEqual(@as(f64, 2), api.nilu_tonumberx(state, -1, null));
    try std.testing.expectEqual(api.Status.ok, api.nilu_getwriter(state));
    try std.testing.expectEqual(@as(c_int, @backingInt(api.Type.function)), api.nilu_type(state, -1));
}
