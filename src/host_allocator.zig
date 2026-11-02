//! A host's allocation function as the state's allocator (nilu_newstate,
//! the owner's answer), in Lua's lua_Alloc
//! shape: f(ud, ptr, osize, nsize) allocates when ptr is NULL, frees when
//! nsize is 0, and otherwise reallocates, answering NULL when it cannot.
//! The function must answer memory aligned as malloc's (max_align_t); a
//! request for more alignment than that fails as out of memory.
const std = @import("std");

pub const Function = *const fn (?*anyopaque, ?*anyopaque, usize, usize) callconv(.c) ?*anyopaque;

const max_alignment = @alignOf(std.c.max_align_t);

pub const HostAllocator = struct {
    function: Function,
    data: ?*anyopaque,

    pub const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    pub fn allocator(self: *HostAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        const self: *HostAllocator = @ptrCast(@alignCast(context));
        if (alignment.toByteUnits() > max_alignment) return null;
        return @ptrCast(self.function(self.data, null, 0, len));
    }

    /// In place is not something the function can promise; Zig moves it.
    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
        const self: *HostAllocator = @ptrCast(@alignCast(context));
        if (alignment.toByteUnits() > max_alignment) return null;
        return @ptrCast(self.function(self.data, memory.ptr, memory.len, new_len));
    }

    fn free(context: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
        const self: *HostAllocator = @ptrCast(@alignCast(context));
        _ = self.function(self.data, memory.ptr, memory.len, 0);
    }
};
