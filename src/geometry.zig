const std = @import("std");

pub const CELL_COUNT = 24;

/// Geometry of the SIFR cipher ring: 24 cells evenly spaced around a circle,
/// indexed from the brass index at 12 o'clock, clockwise.
pub fn cellAngle(index: usize) f64 {
    const step = std.math.tau / @as(f64, CELL_COUNT);
    return @as(f64, @floatFromInt(index)) * step - std.math.pi / 2.0;
}

pub fn cellCenter(index: usize, radius: f64) struct { x: f64, y: f64 } {
    const angle = cellAngle(index);
    return .{
        .x = @cos(angle) * radius,
        .y = @sin(angle) * radius,
    };
}

test "24 cells close an exact ring" {
    try std.testing.expectEqual(CELL_COUNT, 24);
    var sum: f64 = 0;
    var i: usize = 0;
    while (i < CELL_COUNT) : (i += 1) {
        sum += 1.0 / @as(f64, CELL_COUNT);
    }
    try std.testing.expectApproxEqAbs(sum, 1.0, 1e-9);
}

test "cell 0 sits at 12 o'clock" {
    const cell = cellCenter(0, 100.0);
    try std.testing.expectApproxEqAbs(cell.y, -100.0, 1e-9);
    try std.testing.expectApproxEqAbs(cell.x, 0.0, 1e-9);
}
