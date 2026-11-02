//! Every-allocation-failure checks whose allocation count is the same on
//! every run.

const std = @import("std");

/// `std.testing.checkAllAllocationFailures` over a backing allocator that
/// never resizes in place. Whether the testing allocator can grow a block in
/// place depends on where earlier blocks landed, so the first run in a
/// process could make one allocation more than the next, and the check then
/// reports nondeterministic memory use. Refusing every resize sends each
/// growth through a new allocation, which the check also makes fail; leaks
/// still reach the testing allocator underneath.
pub fn checkAll(
    backing: std.mem.Allocator,
    comptime test_fn: anytype,
    extra_args: anytype,
) !void {
    var fixed = std.testing.FailingAllocator.init(backing, .{ .resize_fail_index = 0 });
    return std.testing.checkAllAllocationFailures(fixed.allocator(), test_fn, extra_args);
}
