//! Public re-exports of the term modules. Module root lives at src/ level so
//! term files can relatively import ../ui, ../gpu, ../framework.
pub const json = @import("term/json.zig");
pub const server = @import("term/server.zig");
pub const pty = @import("term/pty.zig");
pub const grid = @import("term/grid.zig");
pub const vt = @import("term/vt.zig");
pub const render = @import("term/render.zig");
// framework re-exports so apps can import everything from "term" alone
// (a file may only belong to one module; render.zig already pulls these in)
pub const runtime = @import("framework/runtime.zig");
pub const input = @import("framework/input.zig");
pub const gpu_text = @import("gpu/vulkan/text.zig");
pub const atlas = @import("ui/text/atlas.zig");
pub const ui = @import("ui/ui.zig");
pub const widgets = @import("ui/widgets.zig");
pub const layout = @import("ui/layout.zig");
pub const kitty = @import("term/kitty.zig");
