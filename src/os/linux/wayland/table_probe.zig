const std = @import("std");
const wt = @import("wayland_tables.zig");

const all = [_]*const wt.wl_interface{
    &wt.wl_display_interface, &wt.wl_registry_interface, &wt.wl_callback_interface,
    &wt.wl_compositor_interface, &wt.wl_region_interface, &wt.wl_surface_interface,
    &wt.wl_shm_interface, &wt.wl_shm_pool_interface, &wt.wl_buffer_interface,
    &wt.wl_seat_interface, &wt.wl_keyboard_interface, &wt.wl_pointer_interface,
    &wt.wl_output_interface, &wt.wl_subcompositor_interface, &wt.wl_subsurface_interface,
    &wt.wl_data_device_manager_interface, &wt.wl_data_device_interface,
    &wt.wl_data_offer_interface, &wt.wl_data_source_interface,
    &wt.xdg_wm_base_interface, &wt.xdg_positioner_interface, &wt.xdg_popup_interface,
    &wt.xdg_surface_interface, &wt.xdg_toplevel_interface,
};

pub fn main() !void {
    for (all) |iface| {
        const name = std.mem.span(iface.name);
        std.debug.print("iface {s}\n", .{name});
        if (iface.methods) |msgs| {
            for (msgs[0..iface.method_count]) |*m| {
                _ = std.mem.span(m.name);
                _ = std.mem.span(m.signature);
                if (m.types) |ts| {
                    for (ts[0..std.mem.len(m.signature)]) |tp| {
                        if (tp) |t| {
                            _ = std.mem.span(t.name);
                        }
                    }
                }
            }
        }
        if (iface.events) |evs| {
            for (evs[0..iface.event_count]) |*m| {
                _ = std.mem.span(m.name);
                _ = std.mem.span(m.signature);
                if (m.types) |ts| {
                    for (ts[0..std.mem.len(m.signature)]) |tp| {
                        if (tp) |t| {
                            _ = std.mem.span(t.name);
                        }
                    }
                }
            }
        }
    }
    std.debug.print("TABLE_PROBE_OK\n", .{});
}
