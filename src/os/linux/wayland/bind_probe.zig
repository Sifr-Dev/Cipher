const std = @import("std");
const wayland = @import("wayland_client.zig");

pub fn main() !void {
    var conn = try wayland.Connection.connect(std.heap.page_allocator);
    defer conn.disconnect();

    const comp = try conn.bindGlobal("wl_compositor", &wayland.wl_compositor_interface, 4);
    std.debug.print("compositor token={d}\n", .{comp});
    const base = try conn.bindGlobal("xdg_wm_base", &wayland.xdg_wm_base_interface, 6);
    std.debug.print("wm_base token={d}\n", .{base});
    const surf = try wayland.compositorCreateSurface(&conn, comp);
    std.debug.print("surface token={d}\n", .{surf});
    const xs = try wayland.wmBaseCreateXdgSurface(&conn, base, surf);
    std.debug.print("xdg_surface token={d}\n", .{xs});
    const tl = try wayland.xdgSurfaceGetToplevel(&conn, xs);
    std.debug.print("toplevel token={d}\n", .{tl});
    std.debug.print("BIND_PROBE_OK\n", .{});
}
