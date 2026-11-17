// Test shim at src/ level for framework modules (they import across src/).
test {
    _ = @import("framework/input.zig");
    _ = @import("framework/input_test.zig");
    _ = @import("framework/runtime.zig");
}
