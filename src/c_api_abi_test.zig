const std = @import("std");
const api = @import("c_api.zig");
const runtime = @import("runtime.zig");
// The header as the C compiler reads it, translated by the build (build.zig).
const c = @import("nilu-header");

fn PointerType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |optional| if (@typeInfo(optional.child) == .pointer) optional.child else T,
        else => T,
    };
}

// C pointers permit NULL; Zig represents that with optional pointers. Sentinels
// and pointee alignment are internal guarantees, not extra C ABI arguments.
fn sameAbi(comptime Actual: type, comptime Declared: type) bool {
    if (comptime Actual == api.Status) return Declared == c.NiluStatus and @sizeOf(Actual) == @sizeOf(Declared) and @alignOf(Actual) == @alignOf(Declared);
    if (comptime Actual == api.Debug) return Declared == c.NiluDebug and @sizeOf(Actual) == @sizeOf(Declared) and @alignOf(Actual) == @alignOf(Declared) and @offsetOf(Actual, "short_src") == @offsetOf(Declared, "short_src") and @offsetOf(Actual, "extraargs") == @offsetOf(Declared, "extraargs") and @offsetOf(Actual, "istailcall") == @offsetOf(Declared, "istailcall");
    if (comptime Actual == api.ErrorLocation) return Declared == c.NiluError and @sizeOf(Actual) == @sizeOf(Declared) and @alignOf(Actual) == @alignOf(Declared) and @offsetOf(Actual, "line") == @offsetOf(Declared, "line") and @offsetOf(Actual, "column") == @offsetOf(Declared, "column") and @FieldType(Declared, "line") == c_int and @FieldType(Declared, "column") == c_int;
    if (comptime Actual == runtime.State) return Declared == c.NiluState;
    const A = PointerType(Actual);
    const D = PointerType(Declared);
    const actual = @typeInfo(A);
    const declared = @typeInfo(D);
    if (comptime std.meta.activeTag(actual) != std.meta.activeTag(declared)) return false;
    return switch (actual) {
        .int => |integer| integer.bits == declared.int.bits and integer.signedness == declared.int.signedness,
        .float => |float| float.bits == declared.float.bits,
        .void => true,
        .pointer => |pointer| pointer.size != .slice and declared.pointer.size != .slice and pointer.attrs.@"const" == declared.pointer.attrs.@"const" and pointer.attrs.@"volatile" == declared.pointer.attrs.@"volatile" and sameAbi(pointer.child, declared.pointer.child),
        .@"fn" => |function| blk: {
            const other = declared.@"fn";
            if (comptime function.param_types.len != other.param_types.len or function.attrs.varargs != other.attrs.varargs or !std.meta.eql(function.attrs.@"callconv", other.attrs.@"callconv")) break :blk false;
            if (!sameAbi(function.return_type.?, other.return_type.?)) break :blk false;
            inline for (function.param_types, other.param_types) |parameter, other_parameter| {
                if (parameter == null or other_parameter == null or !sameAbi(parameter.?, other_parameter.?)) break :blk false;
            }
            break :blk true;
        },
        else => A == D,
    };
}

test "c_api_abi every public boundary function matches the compiled C declaration" {
    @setEvalBranchQuota(20000);
    var checked: usize = 0;
    inline for (comptime @typeInfo(api).@"struct".decl_names) |name| {
        if (comptime std.mem.startsWith(u8, name, "nilu_")) {
            if (!@hasDecl(c, name)) @compileError("C header lacks " ++ name);
            const Actual = @TypeOf(@field(api, name));
            const Declared = @TypeOf(@field(c, name));
            if (comptime !sameAbi(Actual, Declared)) @compileError("C ABI mismatch: " ++ name ++ ": " ++ @typeName(Actual) ++ " versus " ++ @typeName(Declared));
            checked += 1;
        }
    }
    try std.testing.expect(checked > 0);
    std.debug.print("C ABI: {d} function declarations checked by the compiler\n", .{checked});
}

test "c_api_abi status values and representation match the C enum" {
    const status = @typeInfo(api.Status).@"enum";
    inline for (status.field_names, status.field_values) |field_name, field_value| {
        const name = comptime blk: {
            if (std.mem.eql(u8, field_name, "ok")) break :blk "NILU_OK";
            // A suspension, not a failure (ADR 0013).
            if (std.mem.eql(u8, field_name, "yielded")) break :blk "NILU_YIELD";
            var upper: [field_name.len]u8 = undefined;
            for (field_name, 0..) |byte, i| upper[i] = std.ascii.toUpper(byte);
            break :blk "NILU_ERR_" ++ upper;
        };
        try std.testing.expectEqual(@as(i128, field_value), @as(i128, @field(c, name)));
    }
    try std.testing.expect(sameAbi(api.Status, c.NiluStatus));
    try std.testing.expectEqual(api.fail, @as(c_int, c.NILU_FAIL));
    try std.testing.expectEqual(@as(c_int, -1), @as(c_int, c.NILU_MULTRET));
    try std.testing.expectEqual(@as(c_int, 0), @as(c_int, c.NILU_OPEQ));
    try std.testing.expectEqual(@as(c_int, 1), @as(c_int, c.NILU_OPLT));
    try std.testing.expectEqual(@as(c_int, 2), @as(c_int, c.NILU_OPLE));
    try std.testing.expectEqual(@as(c_int, runtime.State.max_stack), @as(c_int, c.NILU_MAXDEPTH));
    try std.testing.expectEqual(@as(c_int, runtime.State.max_upvalues), @as(c_int, c.NILU_MAXUPVALUES));
}

test "c_api_abi normalizer rejects pointer qualifier integer and signature drift" {
    try std.testing.expect(sameAbi(?[*:0]const u8, [*c]const u8));
    try std.testing.expect(sameAbi(?*runtime.State, ?*c.NiluState));
    try std.testing.expect(sameAbi(?*api.ErrorLocation, [*c]c.NiluError));
    try std.testing.expect(!sameAbi(?*api.ErrorLocation, [*c]const c.NiluError));
    try std.testing.expect(!sameAbi(*const u8, [*c]u8));
    try std.testing.expect(!sameAbi(c_int, c_uint));
    try std.testing.expect(!sameAbi(usize, f64));
    try std.testing.expect(!sameAbi(fn (c_int) callconv(.c) void, fn (f64) callconv(.c) void));
    try std.testing.expect(!sameAbi(fn (c_int) callconv(.c) void, fn (c_int, c_int) callconv(.c) void));
}

test "c_api_abi load error coordinates match the recorded C struct" {
    try std.testing.expectEqual(@sizeOf(c.NiluError), @sizeOf(api.ErrorLocation));
    try std.testing.expectEqual(@alignOf(c.NiluError), @alignOf(api.ErrorLocation));
    inline for (.{ "line", "column" }) |field| {
        try std.testing.expectEqual(@offsetOf(c.NiluError, field), @offsetOf(api.ErrorLocation, field));
        try std.testing.expect(@FieldType(c.NiluError, field) == c_int);
        try std.testing.expect(@FieldType(api.ErrorLocation, field) == c_int);
    }
}

test "c_api_abi stable type tags match C int and owner assignments" {
    try std.testing.expect(c.NiluType == c_int);
    inline for (.{ "NONE", "NIL", "NUMBER", "FUNCTION", "BOOLEAN", "STRING", "TABLE", "USERDATA" }, .{ "none", "nil", "number", "function", "boolean", "string", "table", "userdata" }, .{ -1, 0, 1, 2, 3, 4, 5, 6 }) |upper, lower, number| {
        try std.testing.expectEqual(@as(c_int, number), @as(c_int, @field(c, "NILU_T" ++ upper)));
        try std.testing.expectEqual(@as(c_int, number), @backingInt(@field(api.Type, lower)));
    }
}
