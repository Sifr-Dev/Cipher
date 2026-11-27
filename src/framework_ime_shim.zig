// Test shim at src/ level so the Wayland IME transport (which lives under
// os/linux/wayland/) can import the framework session model.
test {
    _ = @import("framework/text_input.zig");
    _ = @import("os/linux/wayland/text_input.zig");
    _ = @import("framework/input.zig");
    _ = @import("framework/text_field.zig");
}
