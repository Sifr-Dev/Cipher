const std = @import("std");
const c = @import("c");
const geometry = @import("geometry.zig");

const VOID: u32 = 0x04060b;
const LINE: u32 = 0x2d3038;
const TEXT: u32 = 0xf3f7fe;
const BRASS: u32 = 0xeab444;

pub fn main() !void {
    const conn = c.xcb_connect(null, null);
    if (conn == null or c.xcb_connection_has_error(conn) != 0) {
        std.debug.print("cipher: failed to connect to X11\n", .{});
        return error.X11ConnectionFailed;
    }
    defer _ = c.xcb_disconnect(conn);

    const setup = c.xcb_get_setup(conn);
    const roots = c.xcb_setup_roots_iterator(setup);
    const screen = roots.data;

    const window: c.xcb_window_t = c.xcb_generate_id(conn);
    _ = c.xcb_create_window(
        conn,
        screen.*.root_depth,
        window,
        screen.*.root,
        120,
        120,
        640,
        400,
        0,
        c.XCB_WINDOW_CLASS_INPUT_OUTPUT,
        screen.*.root_visual,
        c.XCB_CW_BACK_PIXEL | c.XCB_CW_EVENT_MASK,
        &[_]u32{ VOID, c.XCB_EVENT_MASK_EXPOSURE | c.XCB_EVENT_MASK_KEY_PRESS },
    );
    _ = c.xcb_map_window(conn, window);

    const gc = c.xcb_generate_id(conn);
    _ = c.xcb_create_gc(conn, gc, window, c.XCB_GC_FOREGROUND | c.XCB_GC_LINE_WIDTH, &[_]u32{ TEXT, 2 });

    _ = c.xcb_flush(conn);
    draw(conn, window, gc);
    _ = c.xcb_flush(conn);
    std.debug.print("cipher: window mapped (id {})\n", .{window});

    while (c.xcb_wait_for_event(conn)) |event| {
        const eventType = event.*.response_type & 0x7f;
        switch (eventType) {
            c.XCB_EXPOSE => {
                draw(conn, window, gc);
                _ = c.xcb_flush(conn);
            },
            c.XCB_KEY_PRESS => {
                _ = c.free(event);
                break;
            },
            else => {},
        }
        if (eventType != c.XCB_KEY_PRESS) _ = c.free(event);
    }
}

fn draw(conn: ?*c.xcb_connection_t, window: c.xcb_window_t, gc: c.xcb_gcontext_t) void {
    const cx: i16 = 320;
    const cy: i16 = 200;

    var ring: usize = 0;
    while (ring < 3) : (ring += 1) {
        const radius: i16 = @intCast(120 - ring * 36);
        setForeground(conn, gc, LINE);
        var arcs = [_]c.xcb_arc_t{
            .{
                .x = cx - radius,
                .y = cy - radius,
                .width = @intCast(radius * 2),
                .height = @intCast(radius * 2),
                .angle1 = 0,
                .angle2 = 360 * 64,
            },
        };
        _ = c.xcb_poly_arc(conn, window, gc, 1, &arcs);
    }

    var cell_index: usize = 0;
    while (cell_index < geometry.CELL_COUNT) : (cell_index += 1) {
        const cell = geometry.cellCenter(cell_index, 120.0);
        const is_index = cell_index == 0;
        setForeground(conn, gc, if (is_index) BRASS else TEXT);
        var points = [_]c.xcb_point_t{
            .{
                .x = @intFromFloat(cx + cell.x),
                .y = @intFromFloat(cy + cell.y),
            },
        };
        _ = c.xcb_poly_point(conn, c.XCB_COORD_MODE_ORIGIN, window, gc, 1, &points);
    }

    setForeground(conn, gc, BRASS);
    var center = [_]c.xcb_point_t{.{ .x = cx, .y = cy }};
    _ = c.xcb_poly_point(conn, c.XCB_COORD_MODE_ORIGIN, window, gc, 1, &center);
    _ = c.xcb_flush(conn);
}

fn setForeground(conn: ?*c.xcb_connection_t, gc: c.xcb_gcontext_t, pixel: u32) void {
    const values = [_]u32{pixel};
    _ = c.xcb_change_gc(conn, gc, c.XCB_GC_FOREGROUND, &values);
}
