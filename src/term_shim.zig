// Test shim at src/ level for the terminal modules.
test {
    _ = @import("term/grid.zig");
    _ = @import("term/vt.zig");
    _ = @import("term/term_test.zig");
    _ = @import("term/pty.zig");
    _ = @import("term/server.zig");
}
