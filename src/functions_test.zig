const std = @import("std");
const allocation_failures = @import("allocation_failures.zig");
const repeated = @import("repeated_text.zig").repeated;
const runtime = @import("runtime.zig");
const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const vm = @import("vm.zig");
const a = std.testing.allocator;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const Value = runtime.Value;
const State = runtime.State;
fn compile(state: *State, source: []const u8) !*runtime.Prototype {
    var parsed: ?parser.Diagnostic = null;
    var ast = try parser.parseChunk(a, source, &parsed);
    defer ast.deinit();
    var diagnostic: ?compiler.Diagnostic = null;
    return compiler.compile(a, state, &ast, "<functions>", &diagnostic);
}
fn run(state: *State, source: []const u8) !usize {
    const closure = try state.newChunk(try compile(state, source));
    var diagnostic: ?vm.Diagnostic = null;
    return vm.run(state, closure, &diagnostic);
}
fn check(source: []const u8, expected: []const Value) !void {
    var state = try State.init(a);
    defer state.deinit();
    try equal(expected.len, try run(&state, source));
    try equal(expected.len, state.top());
    for (expected, state.stack.items) |wanted, actual| try expect(actual.equal(wanted));
    try equal(@as(usize, 0), state.frames.items.len);
}

test "functions fixed parameters nil padding discarded extras and nested varargs execute" {
    try check("local function f(a,b) return a,b end return f(1)", &.{ .from(.{ .number = 1 }), .nil });
    try check("local function f(a,b) return a,b end return f(1,2,3)", &.{ .from(.{ .number = 1 }), .from(.{ .number = 2 }) });
    try check("local function f(a,b,...) return a,b,... end return f(1)", &.{ .from(.{ .number = 1 }), .nil });
    try check("local function f(a,b,...) return a,b,... end return f(1,2,nil,4,nil)", &.{ .from(.{ .number = 1 }), .from(.{ .number = 2 }), .nil, .from(.{ .number = 4 }), .nil });
    try check("local f=function(a,b,...) local t={...} return a,b,t[1],t[2] end return f(1,2,3,4)", &.{ .from(.{ .number = 1 }), .from(.{ .number = 2 }), .from(.{ .number = 3 }), .from(.{ .number = 4 }) });
    try check("return (function() return 7 end)(1,2)", &.{.from(.{ .number = 7 })});
    try check("return (function(a,a) return a end)(1,2)", &.{.from(.{ .number = 2 })});
    try check("local t={v=2,m=function(self,x) return self.v+x end} return t:m(3)", &.{.from(.{ .number = 5 })});
    try check("local function invoke(f) return f() end local function outer(x) return invoke(function() return x end) end return outer(7)", &.{.from(.{ .number = 7 })});
}

test "functions local recursion ordinary definitions and global definitions bind correctly" {
    try check("local function fact(n) if n<2 then return 1 end return n*fact(n-1) end return fact(5)", &.{.from(.{ .number = 120 })});
    try check("local f function f() return 7 end return f()", &.{.from(.{ .number = 7 })});
    try check("function f() return 8 end return f()", &.{.from(.{ .number = 8 })});
    try check("local f=9 global function f(n) if n==0 then return 1 end return f(n-1) end return f(300)", &.{.from(.{ .number = 1 })});
    try check("local function f(n) if n==0 then return 7 end return f(n-1) end return f(1000)", &.{.from(.{ .number = 7 })});
}

test "functions sibling closures share cells while separate activations retain independent values" {
    try check("local function make(n) return function(d) n=n+d return n end end local a,b=make(0),make(10) return a(2),a(3),b(4)", &.{ .from(.{ .number = 2 }), .from(.{ .number = 5 }), .from(.{ .number = 14 }) });
    try check("local x=0 local function add() x=x+1 end local function get() return x end add() add() return get()", &.{.from(.{ .number = 2 })});
    try check("local x=1 local f=function() return x end x=9 return f()", &.{.from(.{ .number = 9 })});
    try check("local f do local x=7 f=function() return x end end local x=99 return f()", &.{.from(.{ .number = 7 })});
    try check("local x=1 local function middle() return function() x=x+1 return x end end local f=middle() return f(),f()", &.{ .from(.{ .number = 2 }), .from(.{ .number = 3 }) });
}

test "functions captures follow lexical definition environments and ENV cells" {
    try check("local x=1 local f=function() return x end local x=2 return f(),x", &.{ .from(.{ .number = 1 }), .from(.{ .number = 2 }) });
    try check("local _ENV={x=1} local f=function() return x end _ENV={x=9} return f()", &.{.from(.{ .number = 9 })});
    try check("local _ENV={x=2} local function middle() return function() return x end end local f=middle() return f()", &.{.from(.{ .number = 2 })});
    try check("local x=1 global x=7 local f=function() return x end return f()", &.{.from(.{ .number = 7 })});
    try check("local function f(_ENV) return x end return f({x=8})", &.{.from(.{ .number = 8 })});
    try check("local _ENV={} local function set() x=7 end set() return x", &.{.from(.{ .number = 7 })});
}

test "functions captured numeric controls while repeat and goto locals close each turn" {
    try check("local a,b,c for i=1,3 do if i==1 then a=function() return i end elseif i==2 then b=function() return i end else c=function() return i end end end return a(),b(),c()", &.{ .from(.{ .number = 1 }), .from(.{ .number = 2 }), .from(.{ .number = 3 }) });
    try check("local a,b local n=0 while n<2 do local x=n if n==0 then a=function() return x end else b=function() return x end end n=n+1 end return a(),b()", &.{ .from(.{ .number = 0 }), .from(.{ .number = 1 }) });
    try check("local a,b local n=0 repeat local x=n if n==0 then a=function() return x end else b=function() return x end end n=n+1 until n==2 return a(),b()", &.{ .from(.{ .number = 0 }), .from(.{ .number = 1 }) });
    try check("local a,b local n=0 ::again:: local x=n if n==0 then a=function() return x end else b=function() return x end end n=n+1 if n<2 then goto again end return a(),b()", &.{ .from(.{ .number = 0 }), .from(.{ .number = 1 }) });
    try check("local f for i=1,9 do local x=7 f=function() return i,x end break end return f()", &.{ .from(.{ .number = 1 }), .from(.{ .number = 7 }) });
}

test "functions GC retains escaped cells returned on tail calls and failures" {
    var state = try State.init(a);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    state.setCollectionThreshold(0);
    try equal(@as(usize, 2), try run(&state, "local function make(x) return function() return x end end local f=make({v=7}) local n=0 while n<300 do local t={{}} n=n+1 end return f().v,(function(...) return ... end)(9)"));
    try expect(state.get(2).?.equal(.from(.{ .number = 7 })));
    try expect(state.get(3).?.equal(.from(.{ .number = 9 })));
    try state.setTop(1);
    try std.testing.expectError(error.Type, run(&state, "local function f() local x={v=8} saved=function() return x end return 1+nil end f()"));
    try equal(@as(usize, 1), state.top());
    state.collect();
    try equal(@as(usize, 1), try run(&state, "return saved().v"));
    try expect(state.get(2).?.equal(.from(.{ .number = 8 })));
    try equal(@as(usize, 0), state.frames.items.len);
}

fn allocationCase(allocator: std.mem.Allocator, ast: *const @import("Ast.zig")) !void {
    var state = try State.init(allocator);
    defer state.deinit();
    var compilation: ?compiler.Diagnostic = null;
    const prototype = try compiler.compile(allocator, &state, ast, "<functions-allocation>", &compilation);
    const closure = try state.newChunk(prototype);
    try state.push(.from(.{ .number = 42 }));
    var diagnostic: ?vm.Diagnostic = null;
    const count = vm.run(&state, closure, &diagnostic) catch |err| {
        try equal(@as(usize, 1), state.top());
        try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
        try equal(@as(usize, 0), state.frames.items.len);
        return err;
    };
    try equal(@as(usize, 1), count);
    try expect(state.get(2).?.equal(.from(.{ .number = 7 })));
}

test "functions all allocation failures release nested programs captures and partial closures" {
    var diagnostic: ?parser.Diagnostic = null;
    var ast = try parser.parseChunk(a, "local function make(n) local function read() return n end local function write(v,...) n=v return ... end return read,write end local r,w=make(1) w(7,nil,9) return r()", &diagnostic);
    defer ast.deinit();
    try allocation_failures.checkAll(a, allocationCase, .{&ast});
}

test "functions static refusals and indexed definitions retain their existing boundaries" {
    for ([_][]const u8{
        "local x<const> = 1 local f=function() x=2 end",
        "local function f() return ... end",
        "local function f() goto outer end ::outer::",
        "for i=1,3 do local function f() i=8 end end",
    }) |source| {
        var state = try State.init(a);
        defer state.deinit();
        try std.testing.expectError(error.Syntax, compile(&state, source));
        try expect(state.prototypes == null);
    }
    var state = try State.init(a);
    defer state.deinit();
    try check("local t={} function t:m() return self end return t:m()==t", &.{.from(.{ .boolean = true })});
    try std.testing.expectError(error.Runtime, run(&state, "f=1 global function f() end"));
}

test "functions metadata remains inspectable and malformed capture descriptors are refused" {
    var state = try State.init(a);
    defer state.deinit();
    const root = try compile(&state, "local x=7 return function(a,...) return function() return x,a end end");
    try equal(@as(usize, 1), root.children.len);
    const child = root.children[0];
    try equal(@as(usize, 1), child.parameters);
    try expect(child.vararg);
    try equal(@as(usize, 1), child.captures.len);
    try equal(@as(usize, 2), child.children[0].captures.len);
    var writer = std.Io.Writer.Allocating.init(a);
    defer writer.deinit();
    try compiler.write(&writer.writer, child);
    try expect(std.mem.indexOf(u8, writer.written(), "parameters 1; captures 1; children 1") != null);
    try state.linkPrototype(child, &.{.{ .local = std.math.maxInt(usize) }}, child.children);
    try std.testing.expectError(error.InvalidBytecode, vm.validate(root));
    try state.linkPrototype(child, &.{.{ .upvalue = std.math.maxInt(usize) }}, child.children);
    try std.testing.expectError(error.InvalidBytecode, vm.validate(root));
    child.parameters = child.registers + 1;
    try std.testing.expectError(error.InvalidBytecode, vm.validate(child));
    // Expression-only roots also need an environment when only a descendant
    // refers to a global; they do not have the chunk's unconditional upvalue.
    state.barrier(&state.globals.header);
    try state.globals.set(a, .from(.{ .string = try state.newString("x") }), .from(.{ .number = 11 }));
    var parsed: ?parser.Diagnostic = null;
    var ast = try parser.parseExpression(a, "function() return x end", &parsed);
    defer ast.deinit();
    var compilation: ?compiler.Diagnostic = null;
    const expression = try compiler.compile(a, &state, &ast, "<function-expression>", &compilation);
    try equal(@as(usize, 1), expression.upvalue_count);
    var failure: ?vm.Diagnostic = null;
    try equal(@as(usize, 1), try vm.run(&state, try state.newChunk(expression), &failure));
    const function = state.get(-1).?.unpack().closure;
    try state.setTop(0);
    try equal(@as(usize, 1), try vm.run(&state, function, &failure));
    try expect(state.get(1).?.equal(.from(.{ .number = 11 })));
}

test "functions flat nested program creation restores register windows" {
    try check(repeated("do local f=function() return 1 end end ", 100) ++ "return 7", &.{.from(.{ .number = 7 })});
    try check("local f=function() return 1 end local g=function() return 1 end return f==f,f==g", &.{ .from(.{ .boolean = true }), .from(.{ .boolean = false }) });
}

test "functions captured Lua chunks agree through the compiler and VM" {
    var lines = std.mem.tokenizeScalar(u8, @embedFile("lua55-functions"), '\n');
    var checked: usize = 0;
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const encoded = fields.next().?;
        const count = try std.fmt.parseInt(usize, fields.next().?, 10);
        const expected = fields.next().?;
        try expect(fields.next() == null);
        var buffer: [4096]u8 = undefined;
        const source = try std.fmt.hexToBytes(&buffer, encoded);
        errdefer std.debug.print("function fixture failed: {s}\n", .{source});
        var state = try State.init(a);
        defer state.deinit();
        try equal(count, try run(&state, source));
        var values = std.mem.tokenizeScalar(u8, expected, ',');
        for (state.stack.items) |actual| {
            const value = values.next().?;
            const colon = std.mem.indexOfScalar(u8, value, ':').?;
            const kind = value[0..colon];
            const payload = value[colon + 1 ..];
            try std.testing.expectEqualStrings(kind, actual.typeName());
            if (actual.numberValue() != null) {
                if (std.mem.eql(u8, payload, "nan")) {
                    try expect(std.math.isNan(actual.numberValue().?));
                } else try equal(try std.fmt.parseInt(u64, payload, 16), @as(u64, @bitCast(actual.numberValue().?)));
            } else if (actual.is(.string)) {
                var bytes: [4096]u8 = undefined;
                const decoded = if (std.mem.eql(u8, payload, "-")) "" else try std.fmt.hexToBytes(&bytes, payload);
                try std.testing.expectEqualSlices(u8, decoded, actual.unpack().string.bytes);
            } else if (actual.is(.boolean)) try equal(std.mem.eql(u8, payload, "true"), actual.unpack().boolean) else try expect(actual.is(.nil));
        }
        if (count > 0) try expect(values.next() == null);
        checked += 1;
    }
    try expect(checked > 0);
    std.debug.print("function fixture: {d} Lua chunks executed through parser, compiler and VM\n", .{checked});
}

test "functions capture descriptors are deduplicated and uncertain budgets stay provisional" {
    var state = try State.init(a);
    defer state.deinit();
    const root = try compile(&state, "local x=1 return function() return (" ++ repeated("x" ++ repeated("+x", 49) ++ ")+(", 19) ++ "x" ++ repeated("+x", 49) ++ ") end");
    try equal(@as(usize, 1), root.children[0].captures.len);
    var source = std.Io.Writer.Allocating.init(a);
    defer source.deinit();
    for (0..200) |i| try source.writer.print("local x{d}=0 ", .{i});
    try source.writer.writeAll("return function() ");
    for (0..100) |i| try source.writer.print("local y{d}=0 ", .{i});
    try source.writer.writeAll("return function() return (0");
    for (0..200) |i| {
        try source.writer.print("+x{d}", .{i});
        if (i == 99 or i == 199) try source.writer.writeAll(")+(0");
    }
    for (0..100) |i| try source.writer.print("+y{d}", .{i});
    try source.writer.writeAll(") end end");
    var limited = try State.init(a);
    defer limited.deinit();
    try std.testing.expectError(error.Syntax, compile(&limited, source.written()));
    try expect(limited.prototypes == null);
}

test "functions a tail call in a chain closes the replaced frame's cells and leaves missing parameters nil" {
    // The answers are lua5.5's.
    try check(
        \\local function inner(x) return x end
        \\local function outer() local captured = 1 local get = function() return captured end captured = 2 return inner(get) end
        \\local function clobber(a, b, c, d) return a end
        \\local function wrap() local g = outer() clobber(9, 9, 9, 9) return g() end
        \\local function f(a, b, c) return a, b, c end
        \\local function g() local x, y, z = 7, 8, 9 return f(1) end
        \\local function h() return g() end
        \\-- Twice, the second time with every callee validated, which the fast
        \\-- way of a tail call needs.
        \\local r1, r2, r3, r4
        \\for i = 1, 2 do r1 = wrap() r2, r3, r4 = h() end
        \\return r1, r2, r3, r4
    , &.{ .from(.{ .number = 2 }), .from(.{ .number = 1 }), .nil, .nil });
}
