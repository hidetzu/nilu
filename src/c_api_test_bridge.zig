//! Only the partial C test artifact uses this bridge. It is not the public API.
const api = @import("c_api.zig");
const runtime = @import("runtime.zig");

// This artifact's root is the test bridge, so explicitly retain the public
// boundary even when the bridge itself does not call a newly added entry.
comptime {
    const std = @import("std");
    for (@typeInfo(api).@"struct".decl_names) |name| {
        if (std.mem.startsWith(u8, name, "nilu_")) _ = &@field(api, name);
    }
}

// The C host drives the actual hook dispatcher without running a script, so the
// empty-window and pop-abort contracts are checked on their own. Not a nilu_* export.
pub export fn test_hook_dispatch(state: *runtime.State) c_int {
    _ = api.nilu_gettop(state);
    return @intFromBool(state.hookStep());
}
