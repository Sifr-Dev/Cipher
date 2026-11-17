//! Public re-exports of the term modules. Module root lives at src/ level so
//! term files can relatively import ../ui, ../gpu, ../framework.
pub const json = @import("term/json.zig");
pub const server = @import("term/server.zig");
pub const pty = @import("term/pty.zig");
pub const grid = @import("term/grid.zig");
pub const vt = @import("term/vt.zig");
pub const render = @import("term/render.zig");
