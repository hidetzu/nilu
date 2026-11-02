const std = @import("std");
const runtime = @import("runtime.zig");
const loader = @import("loader.zig");
const vm = @import("vm.zig");
const api = @import("c_api.zig");
const transport = @import("failure_transport.zig");
const a = std.testing.allocator;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
var observed: ?runtime.CallSite = null;
var arguments: usize = 0;
var public_kind_absent: bool = false;
fn probe(state: *runtime.State) callconv(.c) c_int {
    observed = state.nativeCallSite();
    arguments = state.top();
    public_kind_absent = api.nilu_namewhat(state) == null;
    state.collect();
    return 0;
}
fn install(state: *runtime.State, name: []const u8, value: runtime.Value) !void {
    state.barrier(&state.globals.header);
    try state.globals.set(a, .from(.{ .string = try state.newString(name) }), value);
}
fn prepare(state: *runtime.State, source: []const u8, name: []const u8) !*runtime.Closure {
    const temporary = try a.dupe(u8, source);
    defer a.free(temporary);
    var diagnostic: ?loader.Diagnostic = null;
    return loader.prepare(state, temporary, name, &diagnostic);
}
fn run(state: *runtime.State, source: []const u8) !void {
    const chunk = try prepare(state, source, "=site");
    observed = null;
    var diagnostic: ?vm.Diagnostic = null;
    _ = try vm.run(state, chunk, &diagnostic);
}
fn rawName(site: runtime.CallSite) ?[]const u8 {
    const name = site.name() orelse return null;
    const span = switch (name.text) {
        .span => |span| span,
        .literal => |literal| literal.contents,
        .environment, .iterator, .fixed => return null,
    };
    return site.prototype.source[span.start..span.end];
}
fn attach(state: *runtime.State, value: runtime.Value, method: runtime.Value) !void {
    const meta = try state.newTable();
    state.barrier(&meta.header);
    try meta.set(a, .from(.{ .string = try state.newString("__call") }), method);
    try state.setMetatable(value, meta);
}

test "call_site caller metadata owns source after input release and GC through each name category" {
    for ([_]struct { source: []const u8, kind: ?runtime.CallKind, spelling: ?[]const u8 }{
        .{ .source = "probe()", .kind = .global, .spelling = "probe" },
        .{ .source = "local p=probe p()", .kind = .local, .spelling = "p" },
        .{ .source = "local t={x=probe} t.x()", .kind = .field, .spelling = "x" },
        .{ .source = "local t={x=probe} t['\\120']()", .kind = .field, .spelling = "\\120" },
        .{ .source = "local t={m=probe} t:m()", .kind = .method, .spelling = "m" },
        .{ .source = "local p=probe local function f() p() end f()", .kind = .upvalue, .spelling = "p" },
        .{ .source = "for k in probe do break end", .kind = .for_iterator, .spelling = null },
        .{ .source = "local function f() return probe end local v=f()()", .kind = null, .spelling = null },
    }) |case| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        try install(&state, "probe", .fromFunction(.{ .native = probe }));
        try run(&state, case.source);
        const site = observed.?;
        try expect(!site.through_call);
        try equal(case.kind, site.classification());
        try std.testing.expectEqualStrings(case.source, site.prototype.source);
        if (case.spelling) |name| try std.testing.expectEqualStrings(name, rawName(site).?) else try expect(rawName(site) == null);
        try expect(state.nativeCallSite() == null);
    }
}

test "call_site ordinary and tail callable chains retain the written name but no public classification" {
    for ([_]struct { source: []const u8, kind: runtime.CallKind, spelling: []const u8, count: usize }{
        .{ .source = "local v=t(9) return v", .kind = .global, .spelling = "t", .count = 3 },
        .{ .source = "return t(9)", .kind = .global, .spelling = "t", .count = 3 },
        .{ .source = "local o={m=t} return o:m(9)", .kind = .method, .spelling = "m", .count = 4 },
    }) |case| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        const function = try state.newCClosure(probe, &.{.from(.{ .number = 13 })});
        const inner = runtime.Value.from(.{ .userdata = try state.newUserdata(0) });
        const outer = runtime.Value.from(.{ .table = try state.newTable() });
        try attach(&state, inner, .fromFunction(function));
        try attach(&state, outer, inner);
        try install(&state, "t", outer);
        try run(&state, case.source);
        const site = observed.?;
        try expect(site.through_call and public_kind_absent);
        try equal(case.kind, site.name().?.kind);
        try equal(@as(?runtime.CallKind, null), site.classification());
        try std.testing.expectEqualStrings(case.spelling, rawName(site).?);
        try equal(case.count, arguments);
    }
}

var restored: bool = false;
fn wrapper(state: *runtime.State) callconv(.c) c_int {
    const before = state.nativeCallSite() orelse return -1;
    state.push(.fromFunction(.{ .native = probe })) catch return -1;
    var diagnostic: ?vm.Diagnostic = null;
    _ = transport.call(state, 0, true, &diagnostic) catch return -1;
    restored = std.meta.eql(before, state.nativeCallSite().?) and observed == null;
    return 0;
}
test "call_site host reentry has no bytecode site and restores the original native metadata" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try install(&state, "wrapper", .fromFunction(.{ .native = wrapper }));
    restored = false;
    try run(&state, "wrapper()");
    try expect(restored and public_kind_absent);
}

test "call_site operator and failure-handler dispatch do not inherit a bytecode function call name" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    const table = try state.newTable();
    const meta = try state.newTable();
    state.barrier(&meta.header);
    try meta.set(a, .from(.{ .string = try state.newString("__add") }), .fromFunction(.{ .native = probe }));
    try state.setMetatable(.from(.{ .table = table }), meta);
    try install(&state, "t", .from(.{ .table = table }));
    try run(&state, "return t+1");
    try expect(observed == null and public_kind_absent);
    try equal(@as(usize, 2), arguments);
    try state.setTop(0);
    const chunk = try prepare(&state, "return 1+nil", "=failure");
    try state.push(.fromFunction(.{ .closure = chunk }));
    var diagnostic: ?vm.Diagnostic = null;
    _ = try transport.callWithHandler(&state, 0, true, .fromFunction(.{ .native = probe }), &diagnostic);
    try expect(observed == null and public_kind_absent);
    try equal(@as(usize, 1), arguments);
}

test "call_site script tail replacement reports the new script's own native call site" {
    for ([_][]const u8{ "return g()", "return t()" }) |source| {
        var state = try runtime.State.init(a);
        defer state.deinit();
        try install(&state, "probe", .fromFunction(.{ .native = probe }));
        const target = runtime.Value.fromFunction(.{ .closure = try prepare(&state, "return probe()", "=callee") });
        try install(&state, "g", target);
        const table = runtime.Value.from(.{ .table = try state.newTable() });
        try attach(&state, table, target);
        try install(&state, "t", table);
        try run(&state, source);
        const site = observed.?;
        try std.testing.expectEqualStrings("callee", site.prototype.displayName());
        try std.testing.expectEqualStrings("probe", rawName(site).?);
        try expect(!site.through_call);
    }
}
