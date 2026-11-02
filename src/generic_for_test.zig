const std = @import("std");
const allocation_failures = @import("allocation_failures.zig");
const repeated = @import("repeated_text.zig").repeated;
const runtime = @import("runtime.zig");
const parser = @import("parser.zig");
const compiler = @import("compiler.zig");
const vm = @import("vm.zig");
const a = std.testing.allocator;
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
const State = runtime.State;
const Value = runtime.Value;
fn compile(state: *State, source: []const u8) !*runtime.Prototype {
    var parsed: ?parser.Diagnostic = null;
    var ast = try parser.parseChunk(a, source, &parsed);
    defer ast.deinit();
    var diagnostic: ?compiler.Diagnostic = null;
    return compiler.compile(a, state, &ast, "<generic-for>", &diagnostic);
}
fn run(state: *State, source: []const u8, diagnostic: *?vm.Diagnostic) !usize {
    return vm.run(state, try state.newChunk(try compile(state, source)), diagnostic);
}
fn check(source: []const u8, expected: []const Value) !void {
    var state = try State.init(a);
    defer state.deinit();
    var diagnostic: ?vm.Diagnostic = null;
    try equal(expected.len, try run(&state, source, &diagnostic));
    try equal(expected.len, state.top());
    for (expected, state.stack.items) |wanted, actual| try expect(actual.equal(wanted));
    try equal(@as(usize, 0), state.frames.items.len);
}
const iterator = "local function step(s,k) if k==nil then k=0 end if k>=s then return nil end return k+1,(k+1)*10 end ";

test "generic_for passes state and prior control and adjusts iterator results" {
    try check(iterator ++ "local n,sum=0,0 for k,v in step,3 do n=n+1 sum=sum+k+v end return n,sum", &.{ .from(.{ .number = 3 }), .from(.{ .number = 66 }) });
    try check(iterator ++ "local n=0 for k in step,3,1 do n=n+k end return n", &.{.from(.{ .number = 5 })});
    try check(iterator ++ "local n=0 for k,v,x in step,2 do if x~=nil then return 99 end n=n+k+v end return n", &.{.from(.{ .number = 33 })});
    try check("local function f() return nil,7 end local n=0 for k,v in f do n=n+1 end return n", &.{.from(.{ .number = 0 })});
    try check("local function f() end local n=0 for k in f do n=n+1 end return n", &.{.from(.{ .number = 0 })});
}

test "generic_for continues for false and zero but stops only on nil" {
    try check("local function f(s,k) if k==nil then return false elseif k==false then return 0 end end local n=0 for k in f do n=n+1 if n>3 then break end end return n", &.{.from(.{ .number = 2 })});
}

test "generic_for evaluates initializer lists once outside the variable scope" {
    try check(iterator ++ "local n=0 local function factory() n=n+1 return step,3,nil end local sum=0 for k in factory() do sum=sum+k end return n,sum", &.{ .from(.{ .number = 1 }), .from(.{ .number = 6 }) });
    try check(iterator ++ "local k=2 local sum=0 for k in step,k do sum=sum+k end return k,sum", &.{ .from(.{ .number = 2 }), .from(.{ .number = 3 }) });
    try check(iterator ++ "local f,s=step,3 local n=0 for k in f,s do f=nil s=0 n=n+1 end return n", &.{.from(.{ .number = 3 })});
    // The fourth value is the one the loop closes (the owner's answer);
    // nil needs no closing. Closing itself is in
    // to_be_closed_test.zig, which has the library.
    try check(iterator ++ "local n=0 local function extra() n=n+1 return nil end local sum=0 for k in step,2,nil,extra() do sum=sum+k end return n,sum", &.{ .from(.{ .number = 1 }), .from(.{ .number = 3 }) });
}

test "generic_for controls are readonly while later variables and shadowing remain mutable" {
    try check(iterator ++ "local sum=0 for k,v in step,2 do v=v+1 sum=sum+v end return sum", &.{.from(.{ .number = 32 })});
    try check(iterator ++ "local sum=0 for k in step,2 do local k=9 sum=sum+k end return sum", &.{.from(.{ .number = 18 })});
    try check(iterator ++ "local sum=0 for x,x in step,2 do x=x+1 sum=sum+x end return sum", &.{.from(.{ .number = 32 })});
    for ([_][]const u8{
        iterator ++ "for k in step,2 do k=9 end",
        iterator ++ "for k in step,2 do local f=function() k=9 end end",
    }) |source| {
        var state = try State.init(a);
        defer state.deinit();
        try std.testing.expectError(error.Syntax, compile(&state, source));
        try expect(state.prototypes == null);
    }
}

test "generic_for declared variables have distinct cells each turn including transitive captures" {
    try check(iterator ++ "local a,b for k,v in step,2 do v=v+1 if k==1 then a=function() return k,v end else b=function() return k,v end end end local x,y=a() local z,w=b() return x,y,z,w", &.{ .from(.{ .number = 1 }), .from(.{ .number = 11 }), .from(.{ .number = 2 }), .from(.{ .number = 21 }) });
    try check(iterator ++ "local a,b for k,v in step,2 do local function outer() return function() return k,v end end if k==1 then a=outer() else b=outer() end end local x,y=a() local z,w=b() return x,y,z,w", &.{ .from(.{ .number = 1 }), .from(.{ .number = 10 }), .from(.{ .number = 2 }), .from(.{ .number = 20 }) });
    try check(iterator ++ "local a,b for k,v in step,2 do local x=v if k==1 then a=function() return x end else b=function() return x end end end return a(),b()", &.{ .from(.{ .number = 10 }), .from(.{ .number = 20 }) });
}

test "generic_for break return goto and nested loops use their owning scopes" {
    try check(iterator ++ "local f for k,v in step,9 do f=function() return k,v end break end return f()", &.{ .from(.{ .number = 1 }), .from(.{ .number = 10 }) });
    try check(iterator ++ "for k,v in step,3 do if k==2 then return v end end", &.{.from(.{ .number = 20 })});
    try check(iterator ++ "local sum=0 for k in step,3 do if k==2 then goto continue end local x=k sum=sum+x ::continue:: end return sum", &.{.from(.{ .number = 4 })});
    try check(iterator ++ "local f for k,v in step,3 do f=function() return k,v end goto done end ::done:: return f()", &.{ .from(.{ .number = 1 }), .from(.{ .number = 10 }) });
    try check(iterator ++ "local n=0 for k in step,3 do for j in step,2 do n=n+1 break end end return n", &.{.from(.{ .number = 3 })});
    try check(iterator ++ "local n=0 for k in step,2 do for i=1,2 do n=n+1 end end return n", &.{.from(.{ .number = 4 })});
    try check(iterator ++ "local n=0 repeat for k in step,3 do n=n+1 break end until n==2 return n", &.{.from(.{ .number = 2 })});
}

test "generic_for iterator failure points at for and nested errors keep their actual origin" {
    var state = try State.init(a);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    var diagnostic: ?vm.Diagnostic = null;
    try std.testing.expectError(error.Type, run(&state, "\nfor k in\n7\ndo\nend", &diagnostic));
    try equal(@as(usize, 2), diagnostic.?.position.line);
    try equal(.generic_call, diagnostic.?.operation);
    try equal(@as(usize, 1), state.top());
    try std.testing.expectError(error.Type, run(&state, "local function f()\nreturn 1+nil\nend\nfor k in f do end", &diagnostic));
    try equal(@as(usize, 2), diagnostic.?.position.line);
    try equal(.binary, diagnostic.?.operation);
    try equal(@as(usize, 0), state.frames.items.len);
}

test "generic_for hidden iterator state and escaped result cells survive collections" {
    var state = try State.init(a);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    state.setCollectionThreshold(0);
    var diagnostic: ?vm.Diagnostic = null;
    const source = "local function make() local function step(s,k) if k==nil then k=0 end local j=0 while j<200 do local garbage={} j=j+1 end if k>=s.limit then return nil end return k+1,{v=k+1} end return step,{limit=3} end local f,s=make() local total=0 local saved for k,v in f,s do f=nil s=nil total=total+v.v saved=function() return k,v.v end end return total,saved";
    try equal(@as(usize, 2), try run(&state, source, &diagnostic));
    try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
    try expect(state.get(2).?.equal(.from(.{ .number = 6 })));
    try expect(state.object_count < 200);
    state.collect();
    const escaped = state.get(3).?.unpack().closure;
    try equal(@as(usize, 2), try vm.run(&state, escaped, &diagnostic));
    try expect(state.get(4).?.equal(.from(.{ .number = 3 })));
    try expect(state.get(5).?.equal(.from(.{ .number = 3 })));
    try equal(@as(usize, 0), state.frames.items.len);
}

fn allocationCase(allocator: std.mem.Allocator, ast: *const @import("Ast.zig")) !void {
    var state = try State.init(allocator);
    defer state.deinit();
    var compilation: ?compiler.Diagnostic = null;
    const closure = try state.newChunk(try compiler.compile(allocator, &state, ast, "<generic-allocation>", &compilation));
    try state.push(.from(.{ .number = 42 }));
    var diagnostic: ?vm.Diagnostic = null;
    const count = vm.run(&state, closure, &diagnostic) catch |err| {
        try equal(@as(usize, 1), state.top());
        try expect(state.get(1).?.equal(.from(.{ .number = 42 })));
        try equal(@as(usize, 0), state.frames.items.len);
        return err;
    };
    try equal(@as(usize, 2), count);
    try expect(state.get(2).?.equal(.from(.{ .number = 3 })));
    try expect(state.get(3).?.equal(.from(.{ .number = 3 })));
}

test "generic_for all allocation failures clean iterator calls and captured variables" {
    var parsed: ?parser.Diagnostic = null;
    var ast = try parser.parseChunk(a, "local function make() local n=0 return function() n=n+1 if n>3 then return nil end return n,{v=n} end end local saved for k,v in make() do saved=function() return k,v.v end end return saved()", &parsed);
    defer ast.deinit();
    try allocation_failures.checkAll(a, allocationCase, .{&ast});
}

test "generic_for invalid operands and targets are refused" {
    const bytecode = @import("bytecode.zig");
    var state = try State.init(a);
    defer state.deinit();
    for ([_]bytecode.Instruction.Operation{
        .{ .generic_call = .{ .base = std.math.maxInt(usize), .count = 1 } },
        .{ .generic_call = .{ .base = 0, .count = 0 } },
        .{ .generic_call = .{ .base = 0, .count = std.math.maxInt(usize) } },
        .{ .generic_call = .{ .base = 1, .count = 1 } },
        .{ .generic_loop = .{ .base = std.math.maxInt(usize), .target = 0 } },
        .{ .generic_loop = .{ .base = 0, .target = 1 } },
    }) |operation| {
        const p = try state.newProgram(&.{}, &.{.{ .position = .{ .offset = 0, .line = 1, .column = 1 }, .operation = operation }}, 5, "", "invalid");
        try std.testing.expectError(error.InvalidBytecode, vm.validate(p));
    }
}

test "generic_for flat loops restore registers and count hidden slots toward the local limit" {
    try check(repeated("for k in function() return nil end do end ", 100) ++ "return 7", &.{.from(.{ .number = 7 })});
    var state = try State.init(a);
    defer state.deinit();
    const p = try compile(&state, repeated("for k in function() return nil end do end ", 100));
    try expect(p.registers <= 6);
    try std.testing.expectError(error.Syntax, compile(&state, repeated("local x=1 ", 198) ++ "for k in function() return nil end do end"));
}

test "generic_for captured Lua chunks agree through the compiler and VM" {
    var lines = std.mem.tokenizeScalar(u8, @embedFile("lua55-generic-for"), '\n');
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
        errdefer std.debug.print("generic-for fixture failed: {s}\n", .{source});
        var state = try State.init(a);
        defer state.deinit();
        var diagnostic: ?vm.Diagnostic = null;
        try equal(count, try run(&state, source, &diagnostic));
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
    std.debug.print("generic-for fixture: {d} Lua chunks executed through parser, compiler and VM\n", .{checked});
}

test "generic_for terminating nil results preserve earlier mutated captured values" {
    try check("local function step(s,k) if k==nil then return 1,10 end if k==1 then return 2,20 end return nil,99 end local a,b for k,v in step do v=v+1 if k==1 then a=function() return k,v end else b=function() return k,v end end end local x,y=a() local z,w=b() return x,y,z,w", &.{ .from(.{ .number = 1 }), .from(.{ .number = 11 }), .from(.{ .number = 2 }), .from(.{ .number = 21 }) });
    try check(iterator ++ "local a,b for k,v in step,2 do local function get() return k,v end if k==1 then a=get else b=get end goto continue ::continue:: end local x,y=a() local z,w=b() return x,y,z,w", &.{ .from(.{ .number = 1 }), .from(.{ .number = 10 }), .from(.{ .number = 2 }), .from(.{ .number = 20 }) });
    try check(iterator ++ "local function make() for k,v in step,3 do return function() return k,v end end end return make()()", &.{ .from(.{ .number = 1 }), .from(.{ .number = 10 }) });
}

test "generic_for failures close escaped declaration cells before unwinding body or iterator" {
    for ([_][]const u8{
        iterator ++ "for k,v in step,2 do saved=function() return k,v end if k==2 then v=23 local x=1+nil end end",
        "local function step(s,k) if k==nil then return 1,10 end if k==1 then return 2,20 end return 1+nil end for k,v in step do v=v+3 saved=function() return k,v end end",
    }) |source| {
        var state = try State.init(a);
        defer state.deinit();
        try state.push(.from(.{ .number = 42 }));
        var diagnostic: ?vm.Diagnostic = null;
        try std.testing.expectError(error.Type, run(&state, source, &diagnostic));
        try equal(@as(usize, 1), state.top());
        try equal(@as(usize, 0), state.frames.items.len);
        state.collect();
        const saved = state.globals.getString("saved").unpack().closure;
        try equal(@as(usize, 2), try vm.run(&state, saved, &diagnostic));
        try expect(state.get(2).?.equal(.from(.{ .number = 2 })));
        try expect(state.get(3).?.equal(.from(.{ .number = 23 })));
    }
}

fn stopAfterEscape(state: *State) callconv(.c) c_int {
    return if (state.globals.getString("saved").isFunction()) 1 else 0;
}
test "generic_for hook interruption closes escaped declaration cells" {
    var state = try State.init(a);
    defer state.deinit();
    try state.push(.from(.{ .number = 42 }));
    state.setHook(stopAfterEscape, 1);
    var diagnostic: ?vm.Diagnostic = null;
    try std.testing.expectError(error.Interrupted, run(&state, iterator ++ "for k,v in step,3 do saved=function() return k,v end end", &diagnostic));
    state.setHook(null, 0);
    try equal(@as(usize, 1), state.top());
    state.collect();
    const saved = state.globals.getString("saved").unpack().closure;
    try equal(@as(usize, 2), try vm.run(&state, saved, &diagnostic));
    try expect(state.get(2).?.equal(.from(.{ .number = 1 })));
    try expect(state.get(3).?.equal(.from(.{ .number = 10 })));
    try equal(@as(usize, 0), state.frames.items.len);
}
