//! input.zig tests live in input.zig itself; this shim file exists so the
//! framework_shim can pull in future framework test files.
const std = @import("std");

test "shim placeholder" {
    try std.testing.expect(true);
}
