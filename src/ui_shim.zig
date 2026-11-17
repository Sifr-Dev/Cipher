// Test shim at src/ level so ui modules can import ../framework/* (module
// path = src/). Add ui test files here.
test {
    _ = @import("ui/ui.zig");
    _ = @import("ui/layout.zig");
    _ = @import("ui/ui_test.zig");
    _ = @import("ui/widgets_test.zig");
}
