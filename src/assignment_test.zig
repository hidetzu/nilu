const std = @import("std");
const allocation_failures = @import("allocation_failures.zig");
const repeated = @import("repeated_text.zig").repeated;
const runtime = @import("runtime.zig");
const loader = @import("loader.zig");
const vm = @import("vm.zig");
const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const a = std.testing.allocator;
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
const Value = runtime.Value;
fn run(state: *runtime.State, source: []const u8, diagnostic: *?vm.Diagnostic) !usize {
    var compilation: ?loader.Diagnostic = null;
    return vm.run(state, try loader.prepare(state, source, "=assignment", &compilation), diagnostic);
}
fn check(source: []const u8, expected: []const Value) !void {
    var state = try runtime.State.init(a);
    defer state.deinit();
    var diagnostic: ?vm.Diagnostic = null;
    try equal(expected.len, try run(&state, source, &diagnostic));
    for (expected, state.stack.items) |wanted, actual| try expect(actual.equal(wanted));
    try equal(@as(usize, 0), state.frames.items.len);
}

test "assignment plans freeze aliases and environment and commit duplicate targets right to left" {
    try check("local i,t=1,{} i,t[i]=2,10 return i,t[1],t[2]", &.{ .from(.{ .number = 2 }), .from(.{ .number = 10 }), .nil });
    try check("local x=0 x,x=1,2 return x", &.{.from(.{ .number = 1 })});
    try check("local t={} t.x,t.x=1,2 return t.x", &.{.from(.{ .number = 1 })});
    try check("local t={} local old=t t,t.x={},7 return old.x,t.x", &.{ .from(.{ .number = 7 }), .nil });
    try check("local root=_ENV _ENV,x={x=7},2 return root.x,x", &.{ .from(.{ .number = 2 }), .from(.{ .number = 7 }) });
    try check("local root=_ENV x,_ENV=2,{x=7} return root.x,x", &.{ .from(.{ .number = 2 }), .from(.{ .number = 7 }) });
    try check("local root=_ENV local function f() _ENV,x={x=8},3 end f() return root.x,x", &.{ .from(.{ .number = 3 }), .from(.{ .number = 8 }) });
}

test "assignment a global's environment is the one read before the value, however it is stored" {
    // The value's evaluation assigns _ENV: the store goes to the table read first.
    try check("local root=_ENV local other={} local function swap() _ENV=other return 4 end y=swap() return root.y,other.y", &.{ .from(.{ .number = 4 }), .nil });
    try check("local root=_ENV local other={} y=(function() _ENV=other return 5 end)() return root.y,other.y", &.{ .from(.{ .number = 5 }), .nil });
    // Nothing assigns _ENV: the store reads it at the end, and the result is the same.
    try check("x=3 x=x+1 local function f() g=x*2 end f() return x,g", &.{ .from(.{ .number = 4 }), .from(.{ .number = 8 }) });
}

test "assignment constructor fields read locals and literals where they are" {
    try check("local a,k=5,\"kk\" local t={x=a,[k]=a,[2]=a,y=\"lit\",[a]=k} return t.x,t.kk,t[2],t[5]==k,t.y==\"lit\"", &.{ .from(.{ .number = 5 }), .from(.{ .number = 5 }), .from(.{ .number = 5 }), .from(.{ .boolean = true }), .from(.{ .boolean = true }) });
}

test "assignment plans stabilize every receiver and key before evaluating values" {
    try check("local n=0 local t={} local function receiver() n=n*10+1 return t end local function key() n=n*10+2 return n end local function value() n=n*10+3 return n end receiver()[key()],receiver()[key()]=value(),value() return n,t[12],t[1212]", &.{ .from(.{ .number = 121233 }), .from(.{ .number = 12123 }), .from(.{ .number = 121233 }) });
    try check("local t={} local k=1 local function rhs() k=2 t={} return 9 end local old=t t[k]=rhs() return old[1],old[2],t[1]", &.{ .from(.{ .number = 9 }), .nil, .nil });
    try check("local t={} local function many() return 4,5,6 end t.x,t.y=many() return t.x,t.y", &.{ .from(.{ .number = 4 }), .from(.{ .number = 5 }) });
    try check("local t={} t.x,t.y=4 return t.x,t.y", &.{ .from(.{ .number = 4 }), .nil });
    try check("local x=1 local function f() x,x=2,3 end f() return x", &.{.from(.{ .number = 2 })});
}

test "assignment indexed function definitions retain receiver and implicit self" {
    try check("local t={nested={v=5}} function t.nested:m(x) return self.v+x end function t.nested.f() return 9 end return t.nested:m(3),t.nested.f()", &.{ .from(.{ .number = 8 }), .from(.{ .number = 9 }) });
    try check("local t={v=4} function t.f() return t.v end return t.f()", &.{.from(.{ .number = 4 })});
}

test "assignment failures honor phase order and leave earlier commits observable" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    var diagnostic: ?vm.Diagnostic = null;
    try std.testing.expectError(error.Type, run(&state, "mark=0 local function key() mark=1 return 1+nil end local function rhs() mark=2 return 1 end local t={} t[key()]=rhs()", &diagnostic));
    try expect(state.globals.getString("mark").equal(.from(.{ .number = 1 })));
    try std.testing.expectError(error.Type, run(&state, "mark=0 local function rhs() mark=2 return 1+nil end local t=nil t.x=rhs()", &diagnostic));
    try expect(state.globals.getString("mark").equal(.from(.{ .number = 2 })));
    try std.testing.expectError(error.Type, run(&state, "left=0 right=0 local t=nil t.x,right=1,2", &diagnostic));
    try expect(state.globals.getString("right").equal(.from(.{ .number = 2 })));
    try std.testing.expectError(error.Type, run(&state, "left=0 local t=nil left,t.x=1,2", &diagnostic));
    try expect(state.globals.getString("left").equal(.from(.{ .number = 0 })));
    try std.testing.expectError(error.Type, run(&state, "local t=nil\n t.x=1", &diagnostic));
    try equal(@as(usize, 2), diagnostic.?.position.line);
    try equal(@as(usize, 2), diagnostic.?.position.column);
    try equal(@as(usize, 1), state.top());
    try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
    try equal(@as(usize, 0), state.frames.items.len);
}

fn allocationCase(allocator: std.mem.Allocator, ast: *const @import("Ast.zig")) !void {
    var state = try runtime.State.init(allocator);
    defer state.deinit();
    var diagnostic: ?compiler.Diagnostic = null;
    const closure = try state.newChunk(try compiler.compile(allocator, &state, ast, "=allocation", &diagnostic));
    try state.push(.from(.{ .number = 42 }));
    state.setCollectionThreshold(0);
    var failure: ?vm.Diagnostic = null;
    const count = vm.run(&state, closure, &failure) catch |err| {
        try equal(@as(usize, 1), state.top());
        try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
        try equal(@as(usize, 0), state.frames.items.len);
        return err;
    };
    try equal(@as(usize, 2), count);
    try expect(state.get(2).?.equal(.from(.{ .number = 7 })));
    try expect(state.get(3).?.equal(.from(.{ .number = 9 })));
}

test "assignment plans retain frozen tables and keys across GC and clean up all allocation failures" {
    var diagnostic: ?parser.Diagnostic = null;
    var ast = try parser.parseChunk(a, "local t={} local saved=t local function receiver() return t end local function key() return 'x'..'' end local function rhs() t={} local n=0 while n<40 do local garbage={} n=n+1 end return 7,9 end receiver()[key()],t.y=rhs() return saved.x,saved.y", &diagnostic);
    defer ast.deinit();
    try allocation_failures.checkAll(a, allocationCase, .{&ast});
}

test "assignment metamethod stores run right to left after all target and value evaluation" {
    var state = try runtime.State.init(a);
    defer state.deinit();
    var diagnostic: ?vm.Diagnostic = null;
    _ = try run(&state, "log=0 return {},function(self,k,v) log=log*10+v end", &diagnostic);
    const table = state.get(1).?.unpack().table;
    const handler = state.get(2).?;
    const meta = try state.newTable();
    state.barrier(&meta.header);
    try meta.set(a, .from(.{ .string = try state.newString("__newindex") }), handler);
    table.metatable = meta;
    state.barrier(&state.globals.header);
    try state.globals.set(a, .from(.{ .string = try state.newString("t") }), .from(.{ .table = table }));
    try state.setTop(0);
    state.setCollectionThreshold(0);
    try equal(@as(usize, 1), try run(&state, "t.x,t.y=1,2 return log", &diagnostic));
    try expect(state.get(1).?.equal(.from(.{ .number = 21 })));
    try expect(table.getString("x").is(.nil));
    try expect(table.getString("y").is(.nil));
}

test "assignment resolved identities preserve shadowed cells parameters and implicit self" {
    try check("local x=1 local old=function() return x end local x=2 local new=function() return x end x=3 return old(),new()", &.{ .from(.{ .number = 1 }), .from(.{ .number = 3 }) });
    try check("local x=4 local function f(x,x) local before=function() return x end local x=7 return before(),x end return f(5,6)", &.{ .from(.{ .number = 6 }), .from(.{ .number = 7 }) });
    try check("local self=9 local t={v=3} function t:m(self) return self end function t:n() return function() return self.v end end return t:m(8),t:n()(),self", &.{ .from(.{ .number = 8 }), .from(.{ .number = 3 }), .from(.{ .number = 9 }) });
    try check("local _ENV={x=1} local first=function() return x end local _ENV={x=2} local second=function() return x end x=3 return first(),second()", &.{ .from(.{ .number = 1 }), .from(.{ .number = 3 }) });
}

test "assignment plan register limits identify the first excess target and release temporaries" {
    const prefix = "local t={} " ++ repeated("local x=0 ", 199);
    var state = try runtime.State.init(a);
    defer state.deinit();
    var diagnostic: ?vm.Diagnostic = null;
    // An index target takes three registers (receiver, key, value): 18 fit in
    // the 55 the locals leave, and the 19th is the first past the limit.
    try equal(@as(usize, 0), try run(&state, prefix ++ repeated("t[1],", 17) ++ "t[1]=1 return", &diagnostic));
    var compilation: ?loader.Diagnostic = null;
    try std.testing.expectError(error.Syntax, loader.prepare(&state, prefix ++ repeated("t[1],", 18) ++ "t[1]=1", "=limit", &compilation));
    const failure = compilation.?.compile.limit;
    try equal(.registers, failure.subject);
    try equal(@as(usize, 255), failure.maximum);
    try equal(prefix.len + 5 * 16 + 1, failure.position.column);
    // A field name is a constant key, so a field target takes two: 27 fit.
    try equal(@as(usize, 0), try run(&state, prefix ++ repeated("t.x,", 26) ++ "t.x=1 return", &diagnostic));
    compilation = null;
    try std.testing.expectError(error.Syntax, loader.prepare(&state, prefix ++ repeated("t.x,", 27) ++ "t.x=1", "=limit", &compilation));
    const field_failure = compilation.?.compile.limit;
    try equal(.registers, field_failure.subject);
    try equal(prefix.len + 4 * 26 + 1, field_failure.position.column);
    try check("local t={} " ++ repeated("t.x,t.y=1,2 ", 100) ++ "return t.x,t.y", &.{ .from(.{ .number = 1 }), .from(.{ .number = 2 }) });
}
