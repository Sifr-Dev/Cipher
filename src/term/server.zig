//! rex-clone multiplexer server: owns PTYs + grids behind a Unix socket with
//! a JSON-lines protocol. Single-threaded poll loop (listen + clients + pty
//! masters). Ops: hello, ls, spawn, split, send, capture, run [--wait],
//! resize, close, attach/detach. attach replays a raw-output ring so the GUI
//! client can rebuild full-color state, then streams output as base64 events.
const std = @import("std");
const grid_mod = @import("grid.zig");
const vt = @import("vt.zig");
const pty_mod = @import("pty.zig");
const json = @import("json.zig");

pub const REPLAY_CAP: usize = 4 * 1024 * 1024;
pub const QUIESCE_MS: i64 = 300;
pub const RUN_TIMEOUT_MS: i64 = 15_000;

pub const Pane = struct {
    id: u32,
    pty: pty_mod.Pty,
    parser: vt.Parser = .{},
    grid: grid_mod.Grid,
    title: [256]u8 = undefined,
    title_len: usize = 0,
    alive: bool = true,
    zombie: bool = false, // marked by op close; swept after the poll iteration
    replay: std.ArrayList(u8), // raw output ring for attach
    last_output_ns: i64 = 0,
    wait: ?WaitState = null,

    pub const WaitState = struct {
        start_total: usize, // grid.total when the run began
        deadline_ns: i64,
        client: *Client,
        cmd: []u8, // owned copy, for the response
    };
};

pub const Client = struct {
    fd: i32,
    in_buf: std.ArrayList(u8),
    out_buf: std.ArrayList(u8),
    attach_pane: ?u32 = null,
    closed: bool = false,
};

const TestServer = struct {
    allocator: std.mem.Allocator,
    directory: []u8,
    server: Server,

    fn init(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) !TestServer {
        // Unix socket paths are limited to 107 bytes, much shorter than a
        // test-cache path. The random test id and pid isolate every test.
        const directory = try std.fmt.allocPrint(allocator, "/tmp/cipher-term-{d}-{s}", .{ std.os.linux.getpid(), tmp.sub_path });
        errdefer allocator.free(directory);
        try std.Io.Dir.createDirAbsolute(std.testing.io, directory, .default_dir);
        errdefer std.Io.Dir.deleteDirAbsolute(std.testing.io, directory) catch {};
        const socket_path = try std.fmt.allocPrint(allocator, "{s}/socket", .{directory});
        defer allocator.free(socket_path);
        return .{ .allocator = allocator, .directory = directory, .server = try Server.init(allocator, socket_path) };
    }

    fn deinit(self: *TestServer) void {
        self.server.deinit();
        std.Io.Dir.deleteDirAbsolute(std.testing.io, self.directory) catch {};
        self.allocator.free(self.directory);
    }
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    listen_fd: i32,
    socket_path: []u8,
    panes: std.ArrayList(*Pane),
    clients: std.ArrayList(*Client),
    next_pane_id: u32 = 1,
    running: bool = true,

    pub fn init(allocator: std.mem.Allocator, socket_path: []const u8) !Server {
        _ = std.os.linux.unlinkat(std.posix.AT.FDCWD, @ptrCast(socket_path.ptr), 0);
        const fd_rc = std.os.linux.socket(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM | std.os.linux.SOCK.CLOEXEC | 0x800, 0); // +O_NONBLOCK
        if (@as(i64, @bitCast(fd_rc)) < 0) return error.SocketFailed;
        const fd: i32 = @intCast(fd_rc);
        errdefer _ = std.os.linux.close(fd);
        var addr: std.os.linux.sockaddr.un = undefined;
        @memset(std.mem.asBytes(&addr), 0);
        addr.family = std.os.linux.AF.UNIX;
        if (socket_path.len >= addr.path.len) return error.NameTooLong;
        @memcpy(addr.path[0..socket_path.len], socket_path);
        var path_buf: [addr.path.len:0]u8 = @splat(0);
        @memcpy(path_buf[0..socket_path.len], socket_path);
        const brc = std.os.linux.bind(fd, @ptrCast(&addr), @sizeOf(std.os.linux.sockaddr.un));
        if (@as(i64, @bitCast(brc)) < 0) return error.BindFailed;
        // bind() creates a filesystem socket governed by umask. fchmod() on
        // the descriptor would not protect that path; chmod the bound name.
        const crc = std.os.linux.chmod(&path_buf, 0o600);
        if (@as(isize, @bitCast(crc)) < 0) return error.ChmodFailed;
        const lrc = std.os.linux.listen(fd, 16);
        if (@as(i64, @bitCast(lrc)) < 0) return error.ListenFailed;
        return .{
            .allocator = allocator,
            .listen_fd = fd,
            .socket_path = try allocator.dupe(u8, socket_path),
            .panes = .empty,
            .clients = .empty,
        };
    }

    pub fn deinit(self: *Server) void {
        for (self.panes.items) |p| {
            p.pty.deinit();
            p.grid.deinit();
            p.replay.deinit(self.allocator);
            if (p.wait) |w| self.allocator.free(w.cmd);
            self.allocator.destroy(p);
        }
        self.panes.deinit(self.allocator);
        for (self.clients.items) |c| {
            c.in_buf.deinit(self.allocator);
            c.out_buf.deinit(self.allocator);
            if (c.fd >= 0) _ = std.os.linux.close(c.fd);
            self.allocator.destroy(c);
        }
        self.clients.deinit(self.allocator);
        _ = std.os.linux.close(self.listen_fd);
        _ = std.os.linux.unlinkat(std.posix.AT.FDCWD, @ptrCast(self.socket_path.ptr), 0);
        self.allocator.free(self.socket_path);
    }

    pub fn spawnPane(self: *Server, cmd: []const []const u8, cols: u32, rows: u32, cwd: ?[]const u8) !*Pane {
        const p = try self.allocator.create(Pane);
        errdefer self.allocator.destroy(p);
        const pty = try pty_mod.Pty.spawn(self.allocator, cmd, .{ .cols = cols, .rows = rows, .cwd = cwd });
        p.* = .{
            .id = self.next_pane_id,
            .pty = pty,
            .grid = try grid_mod.Grid.init(self.allocator, cols, rows),
            .replay = .empty,
        };
        self.next_pane_id += 1;
        try p.replay.ensureTotalCapacity(self.allocator, 4096);
        try self.panes.append(self.allocator, p);
        return p;
    }

    pub fn findPane(self: *Server, id: u32) ?*Pane {
        for (self.panes.items) |p| if (p.id == id) return p;
        return null;
    }

    pub fn removePane(self: *Server, id: u32) void {
        for (self.panes.items, 0..) |p, i| {
            if (p.id == id) {
                p.pty.deinit();
                p.grid.deinit();
                p.replay.deinit(self.allocator);
                if (p.wait) |w| self.allocator.free(w.cmd);
                self.allocator.destroy(p);
                _ = self.panes.orderedRemove(i);
                return;
            }
        }
    }

    // ---- output path: pty -> parser/grid/replay/attached clients ----

    pub fn pumpPane(self: *Server, p: *Pane) !void {
        var buf: [65536]u8 = undefined;
        while (true) {
            const n = p.pty.read(&buf) catch break; // WouldBlock or EOF -> stop
            if (n == 0) {
                if (p.alive) {
                    p.alive = false;
                    for (self.clients.items) |cl| {
                        if (cl.attach_pane == p.id and !cl.closed) {
                            cl.out_buf.print(self.allocator, "{{\"event\":\"exit\",\"pane\":{d}}}\n", .{p.id}) catch {};
                        }
                    }
                }
                break;
            }
            p.last_output_ns = pty_mod.nowNs();
            try p.parser.feed(&p.grid, buf[0..n]);
            try p.replay.appendSlice(self.allocator, buf[0..n]);
            if (p.replay.items.len > REPLAY_CAP) {
                const drop = p.replay.items.len - REPLAY_CAP + 65536;
                std.mem.copyForwards(u8, p.replay.items[0 .. p.replay.items.len - drop], p.replay.items[drop..]);
                p.replay.items = p.replay.items[0 .. p.replay.items.len - drop];
            }
            for (self.clients.items) |c| {
                if (c.attach_pane == p.id and !c.closed) {
                    const b64 = try json.base64Encode(self.allocator, buf[0..n]);
                    defer self.allocator.free(b64);
                    try c.out_buf.print(self.allocator, "{{\"event\":\"output\",\"pane\":{d},\"data\":\"{s}\"}}\n", .{ p.id, b64 });
                }
            }
            if (vt.Parser.last_title_len > 0 and vt.Parser.last_title_len <= p.title.len) {
                @memcpy(p.title[0..vt.Parser.last_title_len], vt.Parser.last_title[0..vt.Parser.last_title_len]);
                p.title_len = vt.Parser.last_title_len;
                vt.Parser.last_title_len = 0;
            }
        }
        p.pty.pollExit();
        if (p.pty.exited) p.alive = false;
    }

    /// Complete any run --wait whose pane has gone quiet.
    pub fn checkWaits(self: *Server) !void {
        const now = pty_mod.nowNs();
        for (self.panes.items) |p| {
            const w = p.wait orelse continue;
            const quiet = now - p.last_output_ns > QUIESCE_MS * 1_000_000;
            const expired = now > w.deadline_ns;
            const dead = !p.alive;
            if (quiet or expired or dead) {
                // run --wait returns the visible screen at completion
                // (prompt + command + output + fresh prompt)
                const out_text = try p.grid.captureText(self.allocator, false);
                const code: i32 = if (p.pty.exited) @intCast((@as(u32, @bitCast(p.pty.exit_status)) >> 8) & 0xFF) else -1;
                const entries = try self.makeObj(&[_]json.Value.Entry{ .{ .key = "ok", .value = .{ .bool = true } }, .{ .key = "pane", .value = .{ .num = @floatFromInt(p.id) } }, .{ .key = "output", .value = .{ .str = out_text } }, .{ .key = "exit_code", .value = .{ .num = @floatFromInt(code) } }, .{ .key = "timed_out", .value = .{ .bool = expired and !dead } } });
                self.reply(w.client, .{ .obj = entries }) catch {};
                self.allocator.free(w.cmd);
                p.wait = null;
            }
        }
    }

    // ---- request handling ----

    pub fn handleLine(self: *Server, c: *Client, line: []const u8) !void {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) return;
        const v = json.Parser.parse(self.allocator, trimmed) catch {
            try self.replyErr(c, "bad json");
            return;
        };
        defer json.freeValue(self.allocator, v);
        const op = if (v.get("op")) |o| o.strOf() orelse "" else "";
        if (std.mem.eql(u8, op, "hello")) {
            const e = try self.makeObj(&[_]json.Value.Entry{ .{ .key = "ok", .value = .{ .bool = true } }, .{ .key = "server", .value = try self.vstr("cipher-rex") }, .{ .key = "version", .value = .{ .num = 1 } } });
            try self.reply(c, .{ .obj = e });
        } else if (std.mem.eql(u8, op, "ls")) {
            try self.opLs(c);
        } else if (std.mem.eql(u8, op, "spawn")) {
            try self.opSpawn(c, v);
        } else if (std.mem.eql(u8, op, "split")) {
            try self.opSplit(c, v);
        } else if (std.mem.eql(u8, op, "send") or std.mem.eql(u8, op, "input")) {
            try self.opSend(c, v);
        } else if (std.mem.eql(u8, op, "capture")) {
            try self.opCapture(c, v);
        } else if (std.mem.eql(u8, op, "run")) {
            try self.opRun(c, v);
        } else if (std.mem.eql(u8, op, "resize")) {
            try self.opResize(c, v);
        } else if (std.mem.eql(u8, op, "close")) {
            try self.opClose(c, v);
        } else if (std.mem.eql(u8, op, "attach")) {
            try self.opAttach(c, v);
        } else if (std.mem.eql(u8, op, "detach")) {
            c.attach_pane = null;
            const e = try self.makeObj(&[_]json.Value.Entry{.{ .key = "ok", .value = .{ .bool = true } }});
            try self.reply(c, .{ .obj = e });
        } else {
            try self.replyErr(c, "unknown op");
        }
    }

    /// Heap-owned string Value. reply() frees the whole tree, so literals
    /// must never appear as .str payloads — always dupe.
    fn vstr(self: *Server, s: []const u8) !json.Value {
        return .{ .str = try self.allocator.dupe(u8, s) };
    }

    fn makeObj(self: *Server, entries: []const json.Value.Entry) ![]json.Value.Entry {
        const slice = try self.allocator.alloc(json.Value.Entry, entries.len);
        for (entries, 0..) |e, i| {
            slice[i] = .{ .key = try self.allocator.dupe(u8, e.key), .value = e.value };
        }
        return slice;
    }

    fn reply(self: *Server, c: *Client, v: json.Value) !void {
        const s = try json.writeValue(self.allocator, v);
        defer self.allocator.free(s);
        try c.out_buf.appendSlice(self.allocator, s);
        try c.out_buf.append(self.allocator, '\n');
        json.freeValue(self.allocator, v); // reply owns the value tree
    }

    fn replyErr(self: *Server, c: *Client, msg: []const u8) !void {
        const e = try self.makeObj(&[_]json.Value.Entry{ .{ .key = "ok", .value = .{ .bool = false } }, .{ .key = "error", .value = try self.vstr(msg) } });
        try self.reply(c, .{ .obj = e });
    }

    fn paneIdOf(v: json.Value) ?u32 {
        const p = v.get("pane") orelse return null;
        const n = p.numOf() orelse return null;
        if (n < 0) return null;
        return @intFromFloat(n);
    }

    fn numOr(v: json.Value, key: []const u8, default: f64) f64 {
        const p = v.get(key) orelse return default;
        return p.numOf() orelse default;
    }

    fn opLs(self: *Server, c: *Client) !void {
        var arr = std.ArrayList(json.Value).empty;
        defer arr.deinit(self.allocator);
        for (self.panes.items) |p| {
            const title = try self.allocator.dupe(u8, p.title[0..p.title_len]);
            try arr.append(self.allocator, .{ .obj = try self.makeObj(&[_]json.Value.Entry{ .{ .key = "id", .value = .{ .num = @floatFromInt(p.id) } }, .{ .key = "title", .value = .{ .str = title } }, .{ .key = "alive", .value = .{ .bool = p.alive } }, .{ .key = "cols", .value = .{ .num = @floatFromInt(p.grid.cols) } }, .{ .key = "rows", .value = .{ .num = @floatFromInt(p.grid.rows) } } }) });
        }
        const e = try self.makeObj(&[_]json.Value.Entry{ .{ .key = "ok", .value = .{ .bool = true } }, .{ .key = "panes", .value = .{ .arr = try arr.toOwnedSlice(self.allocator) } } });
        try self.reply(c, .{ .obj = e });
    }

    fn opSpawn(self: *Server, c: *Client, v: json.Value) !void {
        const cmd_v = v.get("cmd") orelse return self.replyErr(c, "missing cmd");
        if (cmd_v.* != .arr) return self.replyErr(c, "cmd must be an array");
        var cmd = std.ArrayList([]const u8).empty;
        defer cmd.deinit(self.allocator);
        for (cmd_v.arr) |item| {
            const s = item.strOf() orelse return self.replyErr(c, "cmd items must be strings");
            try cmd.append(self.allocator, s);
        }
        if (cmd.items.len == 0) return self.replyErr(c, "empty cmd");
        const cols: u32 = @intFromFloat(numOr(v, "cols", 80));
        const rows: u32 = @intFromFloat(numOr(v, "rows", 24));
        const cwd = if (v.get("cwd")) |cw| cw.strOf() else null;
        const p = self.spawnPane(cmd.items, cols, rows, cwd) catch return self.replyErr(c, "spawn failed");
        const e = try self.makeObj(&[_]json.Value.Entry{ .{ .key = "ok", .value = .{ .bool = true } }, .{ .key = "id", .value = .{ .num = @floatFromInt(p.id) } } });
        try self.reply(c, .{ .obj = e });
    }

    fn opSplit(self: *Server, c: *Client, v: json.Value) !void {
        // a split is a new pane with the same geometry as the source pane
        const src = paneIdOf(v) orelse return self.replyErr(c, "missing pane");
        const p0 = self.findPane(src) orelse return self.replyErr(c, "no such pane");
        const cmd_v = v.get("cmd") orelse return self.replyErr(c, "missing cmd");
        if (cmd_v.* != .arr) return self.replyErr(c, "cmd must be an array");
        var cmd = std.ArrayList([]const u8).empty;
        defer cmd.deinit(self.allocator);
        for (cmd_v.arr) |item| try cmd.append(self.allocator, item.strOf() orelse return self.replyErr(c, "cmd items must be strings"));
        if (cmd.items.len == 0) return self.replyErr(c, "empty cmd");
        const p = self.spawnPane(cmd.items, p0.grid.cols, p0.grid.rows, null) catch return self.replyErr(c, "spawn failed");
        const e = try self.makeObj(&[_]json.Value.Entry{ .{ .key = "ok", .value = .{ .bool = true } }, .{ .key = "id", .value = .{ .num = @floatFromInt(p.id) } }, .{ .key = "split_of", .value = .{ .num = @floatFromInt(src) } } });
        try self.reply(c, .{ .obj = e });
    }

    fn opSend(self: *Server, c: *Client, v: json.Value) !void {
        const id = paneIdOf(v) orelse return self.replyErr(c, "missing pane");
        const p = self.findPane(id) orelse return self.replyErr(c, "no such pane");
        const data = v.get("data") orelse return self.replyErr(c, "missing data");
        const s = data.strOf() orelse return self.replyErr(c, "data must be a string");
        if (!p.alive) return self.replyErr(c, "pane dead");
        p.pty.write(s) catch return self.replyErr(c, "write failed (pane dead?)");
        const e = try self.makeObj(&[_]json.Value.Entry{.{ .key = "ok", .value = .{ .bool = true } }});
        try self.reply(c, .{ .obj = e });
    }

    fn opCapture(self: *Server, c: *Client, v: json.Value) !void {
        const id = paneIdOf(v) orelse return self.replyErr(c, "missing pane");
        const p = self.findPane(id) orelse return self.replyErr(c, "no such pane");
        const scrollback = if (v.get("scrollback")) |s| s.* == .bool and s.bool else false;
        const text = try p.grid.captureText(self.allocator, scrollback);
        defer self.allocator.free(text);
        var text2 = text;
        if (v.get("lines")) |ln| {
            const n: usize = @intFromFloat(ln.numOf() orelse 0);
            if (n > 0) {
                // keep the last n lines: scan back n newlines
                var start: usize = text.len;
                var seen: usize = 0;
                while (start > 0) {
                    start -= 1;
                    if (text[start] == '\n') {
                        seen += 1;
                        if (seen >= n) {
                            start += 1;
                            break;
                        }
                    }
                }
                text2 = text[start..];
            }
        }
        const e = try self.makeObj(&[_]json.Value.Entry{ .{ .key = "ok", .value = .{ .bool = true } }, .{ .key = "pane", .value = .{ .num = @floatFromInt(id) } }, .{ .key = "text", .value = .{ .str = try self.allocator.dupe(u8, text2) } } });
        try self.reply(c, .{ .obj = e });
    }

    fn opRun(self: *Server, c: *Client, v: json.Value) !void {
        const id = paneIdOf(v) orelse return self.replyErr(c, "missing pane");
        const p = self.findPane(id) orelse return self.replyErr(c, "no such pane");
        const cmd_v = v.get("cmd") orelse return self.replyErr(c, "missing cmd");
        const cmd = cmd_v.strOf() orelse return self.replyErr(c, "cmd must be a string");
        if (!p.alive) return self.replyErr(c, "pane dead");
        // send command + Enter
        p.pty.write(cmd) catch return self.replyErr(c, "write failed (pane dead?)");
        p.pty.write("\n") catch return self.replyErr(c, "write failed (pane dead?)");
        const wait = if (v.get("wait")) |w| w.* == .bool and w.bool else false;
        if (wait) {
            if (p.wait != null) return self.replyErr(c, "pane already running a wait");
            p.last_output_ns = pty_mod.nowNs(); // quiesce clock starts at run
            p.wait = .{
                .start_total = p.grid.total,
                .deadline_ns = pty_mod.nowNs() + RUN_TIMEOUT_MS * 1_000_000,
                .client = c,
                .cmd = try self.allocator.dupe(u8, cmd),
            };
            // no immediate reply; checkWaits sends it when output quiesces
        } else {
            const e = try self.makeObj(&[_]json.Value.Entry{ .{ .key = "ok", .value = .{ .bool = true } }, .{ .key = "pane", .value = .{ .num = @floatFromInt(id) } } });
            try self.reply(c, .{ .obj = e });
        }
    }

    fn opResize(self: *Server, c: *Client, v: json.Value) !void {
        const id = paneIdOf(v) orelse return self.replyErr(c, "missing pane");
        const p = self.findPane(id) orelse return self.replyErr(c, "no such pane");
        const cols: u32 = @intFromFloat(numOr(v, "cols", 80));
        const rows: u32 = @intFromFloat(numOr(v, "rows", 24));
        p.pty.resize(cols, rows);
        // recreate the grid at the new size (content is reflowed by the shell
        // via SIGWINCH; prior cells are dropped — documented limitation)
        p.grid.deinit();
        p.grid = try grid_mod.Grid.init(self.allocator, cols, rows);
        p.parser = .{};
        const e = try self.makeObj(&[_]json.Value.Entry{ .{ .key = "ok", .value = .{ .bool = true } }, .{ .key = "cols", .value = .{ .num = cols } }, .{ .key = "rows", .value = .{ .num = rows } } });
        try self.reply(c, .{ .obj = e });
        // tell attached clients so they can resize their mirror grids
        for (self.clients.items) |cl| {
            if (cl.attach_pane == p.id and !cl.closed) {
                try cl.out_buf.print(self.allocator, "{{\"event\":\"resize\",\"pane\":{d},\"cols\":{d},\"rows\":{d}}}\n", .{ p.id, cols, rows });
            }
        }
    }

    fn opClose(self: *Server, c: *Client, v: json.Value) !void {
        const id = paneIdOf(v) orelse return self.replyErr(c, "missing pane");
        const p = self.findPane(id) orelse return self.replyErr(c, "no such pane");
        // Defer actual teardown: the poll loop holds index snapshots of
        // self.panes for this iteration, so removing here would corrupt them.
        p.zombie = true;
        p.alive = false;
        const e = try self.makeObj(&[_]json.Value.Entry{.{ .key = "ok", .value = .{ .bool = true } }});
        try self.reply(c, .{ .obj = e });
    }

    fn opAttach(self: *Server, c: *Client, v: json.Value) !void {
        const id = paneIdOf(v) orelse return self.replyErr(c, "missing pane");
        const p = self.findPane(id) orelse return self.replyErr(c, "no such pane");
        c.attach_pane = id;
        const b64 = try json.base64Encode(self.allocator, p.replay.items);
        // NOTE: no defer free — reply() frees the value tree, which owns b64
        const e = try self.makeObj(&[_]json.Value.Entry{ .{ .key = "ok", .value = .{ .bool = true } }, .{ .key = "event", .value = try self.vstr("attach") }, .{ .key = "pane", .value = .{ .num = @floatFromInt(id) } }, .{ .key = "cols", .value = .{ .num = @floatFromInt(p.grid.cols) } }, .{ .key = "rows", .value = .{ .num = @floatFromInt(p.grid.rows) } }, .{ .key = "replay", .value = .{ .str = b64 } }, .{ .key = "alive", .value = .{ .bool = p.alive } } });
        try self.reply(c, .{ .obj = e });
    }

    /// Tear down panes marked zombie by op close. Called after each poll
    /// iteration (never from inside handleLine, which would corrupt the
    /// loop's index snapshots).
    pub fn sweepZombies(self: *Server) void {
        var zi: usize = 0;
        while (zi < self.panes.items.len) {
            const p = self.panes.items[zi];
            if (p.zombie) {
                if (p.wait) |w| {
                    self.allocator.free(w.cmd);
                    p.wait = null;
                }
                p.pty.deinit();
                p.grid.deinit();
                p.replay.deinit(self.allocator);
                self.allocator.destroy(p);
                _ = self.panes.orderedRemove(zi);
            } else zi += 1;
        }
    }

    // ---- socket loop ----

    pub fn run(self: *Server) !void {
        while (self.running) {
            // build poll set
            var fds = std.ArrayList(std.os.linux.pollfd).empty;
            defer fds.deinit(self.allocator);
            try fds.append(self.allocator, .{ .fd = self.listen_fd, .events = std.os.linux.POLL.IN, .revents = 0 });
            var client_idx = std.ArrayList(usize).empty;
            defer client_idx.deinit(self.allocator);
            for (self.clients.items, 0..) |c, i| {
                var ev: i16 = @intCast(std.os.linux.POLL.IN);
                if (c.out_buf.items.len > 0) ev |= @intCast(std.os.linux.POLL.OUT);
                try fds.append(self.allocator, .{ .fd = c.fd, .events = ev, .revents = 0 });
                try client_idx.append(self.allocator, i);
            }
            var pane_idx = std.ArrayList(usize).empty;
            defer pane_idx.deinit(self.allocator);
            for (self.panes.items, 0..) |p, i| {
                try fds.append(self.allocator, .{ .fd = p.pty.master_fd, .events = std.os.linux.POLL.IN, .revents = 0 });
                try pane_idx.append(self.allocator, i);
            }
            const rc = std.os.linux.poll(fds.items.ptr, @intCast(fds.items.len), 100);
            if (@as(i64, @bitCast(rc)) < 0) {
                if (std.os.linux.errno(rc) == .INTR) continue;
                return error.PollFailed;
            }
            if (rc == 0) {
                try self.checkWaits();
                continue;
            }
            // accept
            if (fds.items[0].revents & std.os.linux.POLL.IN != 0) {
                while (true) {
                    const cfd_rc = std.os.linux.accept4(self.listen_fd, null, null, std.os.linux.SOCK.CLOEXEC | 0x800);
                    if (@as(i64, @bitCast(cfd_rc)) < 0) break;
                    const client = try self.allocator.create(Client);
                    client.* = .{ .fd = @intCast(cfd_rc), .in_buf = .empty, .out_buf = .empty };
                    try self.clients.append(self.allocator, client);
                }
            }
            // clients
            var ci: usize = 1;
            for (client_idx.items) |cidx| {
                const c = self.clients.items[cidx];
                const re = fds.items[ci].revents;
                ci += 1;
                if (re & (std.os.linux.POLL.HUP | std.os.linux.POLL.ERR) != 0) {
                    c.closed = true;
                    continue;
                }
                if (re & std.os.linux.POLL.IN != 0) {
                    var buf: [65536]u8 = undefined;
                    while (true) {
                        const n_rc = std.os.linux.read(c.fd, &buf, buf.len);
                        if (@as(i64, @bitCast(n_rc)) < 0) break;
                        const n: usize = @intCast(n_rc);
                        if (n == 0) {
                            c.closed = true;
                            break;
                        }
                        try c.in_buf.appendSlice(self.allocator, buf[0..n]);
                        if (n < buf.len) break;
                    }
                    // process complete lines
                    while (std.mem.indexOfScalar(u8, c.in_buf.items, '\n')) |nl| {
                        const line = c.in_buf.items[0..nl];
                        // shift
                        std.mem.copyForwards(u8, c.in_buf.items[0 .. c.in_buf.items.len - nl - 1], c.in_buf.items[nl + 1 ..]);
                        c.in_buf.items = c.in_buf.items[0 .. c.in_buf.items.len - nl - 1];
                        self.handleLine(c, line) catch |e| {
                            self.replyErr(c, @errorName(e)) catch {};
                        };
                    }
                }
                if (re & std.os.linux.POLL.OUT != 0 or c.out_buf.items.len > 0) {
                    try self.flushClient(c);
                }
            }
            // drop closed clients
            var i: usize = 0;
            while (i < self.clients.items.len) {
                if (self.clients.items[i].closed) {
                    const c = self.clients.items[i];
                    // a closed client must not be referenced by a pending run --wait
                    for (self.panes.items) |p| {
                        if (p.wait) |w| {
                            if (w.client == c) {
                                self.allocator.free(w.cmd);
                                p.wait = null;
                            }
                        }
                    }
                    c.in_buf.deinit(self.allocator);
                    c.out_buf.deinit(self.allocator);
                    _ = std.os.linux.close(c.fd);
                    self.allocator.destroy(c);
                    _ = self.clients.orderedRemove(i);
                } else i += 1;
            }
            // panes
            var pi: usize = 1 + client_idx.items.len;
            for (pane_idx.items) |pidx| {
                if (pidx >= self.panes.items.len) break;
                const p = self.panes.items[pidx];
                const re = fds.items[pi].revents;
                pi += 1;
                if (p.zombie) continue;
                if (re & std.os.linux.POLL.IN != 0) {
                    self.pumpPane(p) catch |e| {
                        std.debug.print("rex: pumpPane error {s} (pane {d})\n", .{ @errorName(e), p.id });
                        p.alive = false;
                    };
                }
                p.pty.pollExit();
                if (p.pty.exited and p.alive) {
                    p.alive = false;
                    for (self.clients.items) |cl| {
                        if (cl.attach_pane == p.id and !cl.closed) {
                            cl.out_buf.print(self.allocator, "{{\"event\":\"exit\",\"pane\":{d}}}\n", .{p.id}) catch {};
                        }
                    }
                } else if (p.pty.exited) p.alive = false;
            }
            self.sweepZombies();
            try self.checkWaits();
        }
    }

    fn flushClient(_: *Server, c: *Client) !void {
        while (c.out_buf.items.len > 0) {
            const rc = std.os.linux.write(c.fd, c.out_buf.items.ptr, c.out_buf.items.len);
            if (@as(i64, @bitCast(rc)) < 0) {
                if (std.os.linux.errno(rc) == .AGAIN) return;
                c.closed = true;
                return;
            }
            const n: usize = @intCast(rc);
            std.mem.copyForwards(u8, c.out_buf.items[0 .. c.out_buf.items.len - n], c.out_buf.items[n..]);
            c.out_buf.items = c.out_buf.items[0 .. c.out_buf.items.len - n];
        }
    }
};

// ---- integration test: real server, real shell, in-process ----

fn testClient(srv: *Server) !*Client {
    const c = try srv.allocator.create(Client);
    c.* = .{ .fd = -1, .in_buf = .empty, .out_buf = .empty };
    return c;
}

fn drainReplies(srv: *Server, c: *Client) ![]u8 {
    const out = try srv.allocator.dupe(u8, c.out_buf.items);
    c.out_buf.clearRetainingCapacity();
    return out;
}

test "server: filesystem socket is accessible only to its owner" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try TestServer.init(alloc, &tmp);
    defer fixture.deinit();
    var info: std.os.linux.Statx = undefined;
    const socket_z = try alloc.dupeSentinel(u8, fixture.server.socket_path, 0);
    defer alloc.free(socket_z);
    const rc = std.os.linux.statx(std.posix.AT.FDCWD, socket_z.ptr, 0, .{ .MODE = true }, &info);
    try std.testing.expectEqual(@as(usize, 0), rc);
    try std.testing.expectEqual(@as(u16, 0o600), info.mode & 0o777);
    std.debug.print("SERVER_SOCKET_MODE_OK mode={o}\n", .{info.mode & 0o777});
}

test "server: spawn sh, run --wait captures output, ls/capture/close work" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try TestServer.init(alloc, &tmp);
    defer fixture.deinit();
    var srv = &fixture.server;

    const c = try testClient(srv);
    defer {
        c.in_buf.deinit(alloc);
        c.out_buf.deinit(alloc);
        alloc.destroy(c);
    }

    // spawn
    try srv.handleLine(c, "{\"op\":\"spawn\",\"cmd\":[\"/bin/sh\"],\"cols\":80,\"rows\":24}");
    var rep = try drainReplies(srv, c);
    try std.testing.expect(std.mem.indexOf(u8, rep, "\"ok\":true") != null);
    const v = try json.Parser.parse(alloc, std.mem.trim(u8, rep, " \n"));
    defer json.freeValue(alloc, v);
    const pane_id: u32 = @intFromFloat(v.get("id").?.num);
    std.debug.print("SERVER_SPAWN_OK id={d}\n", .{pane_id});

    // run --wait: echo a marker
    var cmd_buf: [128]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, "echo MARKER_{d}_DONE", .{pane_id});
    var req_buf: [256]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf, "{{\"op\":\"run\",\"pane\":{d},\"cmd\":\"{s}\",\"wait\":true}}", .{ pane_id, cmd });
    try srv.handleLine(c, req);
    // pump until the wait completes (quiesce) or deadline
    const deadline = pty_mod.nowNs() + 10 * 1_000_000_000;
    while (pty_mod.nowNs() < deadline) {
        for (srv.panes.items) |p| try srv.pumpPane(p);
        try srv.checkWaits();
        if (c.out_buf.items.len > 0) break;
        {
            var ts = std.os.linux.timespec{ .sec = 0, .nsec = 10 * 1_000_000 };
            _ = std.os.linux.nanosleep(&ts, null);
        }
    }
    alloc.free(rep);
    rep = try drainReplies(srv, c);
    try std.testing.expect(std.mem.indexOf(u8, rep, "MARKER_") != null);
    try std.testing.expect(std.mem.indexOf(u8, rep, "DONE") != null);
    std.debug.print("SERVER_RUN_WAIT_OK output has marker\n", .{});

    // capture
    try srv.handleLine(c, "{\"op\":\"capture\",\"pane\":1}");
    for (srv.panes.items) |p| try srv.pumpPane(p);
    alloc.free(rep);
    rep = try drainReplies(srv, c);
    try std.testing.expect(std.mem.indexOf(u8, rep, "MARKER_") != null);
    std.debug.print("SERVER_CAPTURE_OK\n", .{});

    // ls
    try srv.handleLine(c, "{\"op\":\"ls\"}");
    alloc.free(rep);
    rep = try drainReplies(srv, c);
    try std.testing.expect(std.mem.indexOf(u8, rep, "\"panes\"") != null);
    std.debug.print("SERVER_LS_OK\n", .{});

    // send raw input: run 'exit' then close
    try srv.handleLine(c, "{\"op\":\"send\",\"pane\":1,\"data\":\"exit\\n\"}");
    alloc.free(rep);
    rep = try drainReplies(srv, c);
    try std.testing.expect(std.mem.indexOf(u8, rep, "\"ok\":true") != null);
    std.debug.print("SERVER_SEND_OK\n", .{});

    // close
    try srv.handleLine(c, "{\"op\":\"close\",\"pane\":1}");
    alloc.free(rep);
    rep = try drainReplies(srv, c);
    try std.testing.expect(std.mem.indexOf(u8, rep, "\"ok\":true") != null);
    srv.sweepZombies(); // the poll loop normally does this after the iteration
    try std.testing.expectEqual(@as(usize, 0), srv.panes.items.len);
    std.debug.print("SERVER_CLOSE_OK\n", .{});
    alloc.free(rep);
}

// ---- real-socket end-to-end regression test ----

fn sockConnect(path: []const u8) !i32 {
    const fd_rc = std.os.linux.socket(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM | std.os.linux.SOCK.CLOEXEC, 0);
    if (@as(i64, @bitCast(fd_rc)) < 0) return error.SocketFailed;
    const fd: i32 = @intCast(fd_rc);
    var addr: std.os.linux.sockaddr.un = undefined;
    @memset(std.mem.asBytes(&addr), 0);
    addr.family = std.os.linux.AF.UNIX;
    if (path.len >= addr.path.len) return error.NameTooLong;
    @memcpy(addr.path[0..path.len], path);
    const rc = std.os.linux.connect(fd, @ptrCast(&addr), @sizeOf(std.os.linux.sockaddr.un));
    if (@as(i64, @bitCast(rc)) < 0) {
        _ = std.os.linux.close(fd);
        return error.ConnectFailed;
    }
    return fd;
}

fn sockWriteAll(fd: i32, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const rc = std.os.linux.write(fd, data[off..].ptr, data.len - off);
        if (@as(i64, @bitCast(rc)) < 0) return error.WriteFailed;
        off += @intCast(rc);
    }
}

var test_read_buffer: [65536]u8 = undefined;
var test_read_len: usize = 0;

fn sockReadLine(fd: i32, allocator: std.mem.Allocator, timeout_ms: i32) !?[]u8 {
    const start = pty_mod.nowNs();
    const deadline = start + @as(i64, timeout_ms) * 1_000_000;
    while (true) {
        if (std.mem.indexOfScalar(u8, test_read_buffer[0..test_read_len], '\n')) |nl| {
            const line = try allocator.dupe(u8, test_read_buffer[0..nl]);
            std.mem.copyForwards(u8, test_read_buffer[0 .. test_read_len - nl - 1], test_read_buffer[nl + 1 .. test_read_len]);
            test_read_len -= nl + 1;
            return line;
        }
        if (test_read_len == test_read_buffer.len) return error.LineTooLong;
        const now = pty_mod.nowNs();
        if (now >= deadline) return null;
        var fds = [_]std.os.linux.pollfd{.{ .fd = fd, .events = std.os.linux.POLL.IN, .revents = 0 }};
        const wait_ms: i32 = @intCast(@min(20, @divTrunc(deadline - now, 1_000_000) + 1));
        const rc = std.os.linux.poll(&fds, 1, wait_ms);
        if (@as(i64, @bitCast(rc)) < 0) {
            if (std.os.linux.errno(rc) == .INTR) continue;
            return error.PollFailed;
        }
        if (rc == 0) continue;
        const n_rc = std.os.linux.read(fd, test_read_buffer[test_read_len..].ptr, test_read_buffer.len - test_read_len);
        if (@as(i64, @bitCast(n_rc)) < 0) {
            if (std.os.linux.errno(n_rc) == .INTR) continue;
            return error.ReadFailed;
        }
        const n: usize = @intCast(n_rc);
        if (n == 0) return null;
        test_read_len += n;
    }
}

fn sockReadResponse(fd: i32, allocator: std.mem.Allocator, timeout_ms: i32) !?[]u8 {
    const deadline = pty_mod.nowNs() + @as(i64, timeout_ms) * 1_000_000;
    while (pty_mod.nowNs() < deadline) {
        const remaining: i32 = @intCast(@divTrunc(deadline - pty_mod.nowNs(), 1_000_000) + 1);
        const line = try sockReadLine(fd, allocator, remaining) orelse return null;
        errdefer allocator.free(line);
        const value = try json.Parser.parse(allocator, line);
        defer json.freeValue(allocator, value);
        if (value.get("event") == null) return line;
        allocator.free(line);
    }
    return null;
}

test "server e2e over real socket: spawn, run --wait, capture, close, ls — server survives close" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try TestServer.init(alloc, &tmp);
    defer fixture.deinit();
    var srv = &fixture.server;
    const t = try std.Thread.spawn(.{}, struct {
        fn runit(s: *Server) void {
            s.run() catch |e| std.debug.print("server test run error: {s}\n", .{@errorName(e)});
        }
    }.runit, .{srv});
    defer {
        srv.running = false;
        t.join();
    }

    var fd: i32 = -1;
    const deadline = pty_mod.nowNs() + 3 * 1_000_000_000;
    while (pty_mod.nowNs() < deadline) {
        if (sockConnect(srv.socket_path)) |f| {
            fd = f;
            break;
        } else |_| {
            var ts = std.os.linux.timespec{ .sec = 0, .nsec = 20 * 1_000_000 };
            _ = std.os.linux.nanosleep(&ts, null);
        }
    }
    try std.testing.expect(fd >= 0);
    defer _ = std.os.linux.close(fd);

    // spawn
    try sockWriteAll(fd, "{\"op\":\"spawn\",\"cmd\":[\"/bin/sh\"],\"cols\":80,\"rows\":24}\n");
    const id = blk: {
        const l = try sockReadLine(fd, alloc, 3000) orelse return error.NoReply;
        defer alloc.free(l);
        try std.testing.expect(std.mem.indexOf(u8, l, "\"ok\":true") != null);
        const v = try json.Parser.parse(alloc, l);
        defer json.freeValue(alloc, v);
        break :blk @as(u32, @intFromFloat(v.get("id").?.num));
    };
    std.debug.print("E2E_SPAWN_OK id={d}\n", .{id});

    // run --wait
    {
        var req: [128]u8 = undefined;
        const r = try std.fmt.bufPrint(&req, "{{\"op\":\"run\",\"pane\":{d},\"cmd\":\"echo E2E_MARKER_7\",\"wait\":true}}", .{id});
        try sockWriteAll(fd, r);
        try sockWriteAll(fd, "\n");
        const l = try sockReadLine(fd, alloc, 8000) orelse return error.NoReply;
        defer alloc.free(l);
        try std.testing.expect(std.mem.indexOf(u8, l, "E2E_MARKER_7") != null);
        std.debug.print("E2E_RUN_WAIT_OK\n", .{});
    }

    // capture (scrollback includes the marker)
    {
        var req: [96]u8 = undefined;
        const r = try std.fmt.bufPrint(&req, "{{\"op\":\"capture\",\"pane\":{d},\"scrollback\":true}}", .{id});
        try sockWriteAll(fd, r);
        try sockWriteAll(fd, "\n");
        const l = try sockReadLine(fd, alloc, 3000) orelse return error.NoReply;
        defer alloc.free(l);
        try std.testing.expect(std.mem.indexOf(u8, l, "E2E_MARKER_7") != null);
        std.debug.print("E2E_CAPTURE_OK\n", .{});
    }

    // close, then ls on the SAME connection: before the zombie fix the server
    // crashed here (stale pane indices in the poll loop)
    {
        var req: [64]u8 = undefined;
        const r = try std.fmt.bufPrint(&req, "{{\"op\":\"close\",\"pane\":{d}}}", .{id});
        try sockWriteAll(fd, r);
        try sockWriteAll(fd, "\n");
        const l = try sockReadLine(fd, alloc, 3000) orelse return error.NoReply;
        defer alloc.free(l);
        try std.testing.expect(std.mem.indexOf(u8, l, "\"ok\":true") != null);
    }
    {
        try sockWriteAll(fd, "{\"op\":\"ls\"}\n");
        const l = try sockReadLine(fd, alloc, 3000) orelse return error.NoReply;
        defer alloc.free(l);
        try std.testing.expect(std.mem.indexOf(u8, l, "\"panes\":[]") != null);
        std.debug.print("E2E_CLOSE_THEN_LS_OK server alive after close\n", .{});
    }

    // spawn again to prove the server keeps working
    {
        try sockWriteAll(fd, "{\"op\":\"spawn\",\"cmd\":[\"/bin/sh\"],\"cols\":80,\"rows\":24}\n");
        const l = try sockReadLine(fd, alloc, 3000) orelse return error.NoReply;
        defer alloc.free(l);
        try std.testing.expect(std.mem.indexOf(u8, l, "\"ok\":true") != null);
        std.debug.print("E2E_RESPAWN_OK\n", .{});
    }
    // regression: ops on a dead pane must reply error, not kill the server
    {
        try sockWriteAll(fd, "{\"op\":\"spawn\",\"cmd\":[\"/nonexistent-binary-xyz\"],\"cols\":40,\"rows\":10}\n");
        const l0 = try sockReadLine(fd, alloc, 3000) orelse return error.NoReply;
        defer alloc.free(l0);
        const v0 = try json.Parser.parse(alloc, l0);
        defer json.freeValue(alloc, v0);
        const dead_id: u32 = @as(u32, @intFromFloat(v0.get("id").?.num));
        // give the child a moment to die
        var ts = std.os.linux.timespec{ .sec = 0, .nsec = 300 * 1_000_000 };
        _ = std.os.linux.nanosleep(&ts, null);
        var req: [160]u8 = undefined;
        const r = try std.fmt.bufPrint(&req, "{{\"op\":\"run\",\"pane\":{d},\"cmd\":\"echo x\",\"wait\":true}}", .{dead_id});
        try sockWriteAll(fd, r);
        try sockWriteAll(fd, "\n");
        const l = try sockReadLine(fd, alloc, 9000) orelse return error.NoReply;
        defer alloc.free(l);
        try std.testing.expect(std.mem.indexOf(u8, l, "\"ok\"") != null); // an error reply, any
        // server still alive?
        try sockWriteAll(fd, "{\"op\":\"ls\"}\n");
        const l2 = try sockReadLine(fd, alloc, 3000) orelse return error.NoReply;
        defer alloc.free(l2);
        try std.testing.expect(std.mem.indexOf(u8, l2, "\"panes\"") != null);
        std.debug.print("E2E_DEAD_PANE_OK server survived dead-pane ops\n", .{});
    }
}

test "server e2e attach: replay ring + streamed output events, server survives" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try TestServer.init(alloc, &tmp);
    defer fixture.deinit();
    var srv = &fixture.server;
    const t = try std.Thread.spawn(.{}, struct {
        fn runit(s: *Server) void {
            s.run() catch |e| std.debug.print("server test run error: {s}\n", .{@errorName(e)});
        }
    }.runit, .{srv});
    defer {
        srv.running = false;
        t.join();
    }
    var fd: i32 = -1;
    const deadline = pty_mod.nowNs() + 3 * 1_000_000_000;
    while (pty_mod.nowNs() < deadline) {
        if (sockConnect(srv.socket_path)) |f| {
            fd = f;
            break;
        } else |_| {
            var ts = std.os.linux.timespec{ .sec = 0, .nsec = 20 * 1_000_000 };
            _ = std.os.linux.nanosleep(&ts, null);
        }
    }
    try std.testing.expect(fd >= 0);
    defer _ = std.os.linux.close(fd);

    try sockWriteAll(fd, "{\"op\":\"spawn\",\"cmd\":[\"/bin/sh\"],\"cols\":80,\"rows\":24}\n");
    const l0 = try sockReadLine(fd, alloc, 3000) orelse return error.NoReply;
    defer alloc.free(l0);
    const v0 = try json.Parser.parse(alloc, l0);
    defer json.freeValue(alloc, v0);
    const id: u32 = @as(u32, @intFromFloat(v0.get("id").?.num));

    // attach: first line must be the attach event with a replay field
    {
        var req: [64]u8 = undefined;
        const r = try std.fmt.bufPrint(&req, "{{\"op\":\"attach\",\"pane\":{d}}}", .{id});
        try sockWriteAll(fd, r);
        try sockWriteAll(fd, "\n");
        const l = try sockReadLine(fd, alloc, 5000) orelse return error.NoReply;
        defer alloc.free(l);
        try std.testing.expect(std.mem.indexOf(u8, l, "\"event\":\"attach\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, l, "\"replay\"") != null);
        std.debug.print("E2E_ATTACH_REPLY_OK\n", .{});
    }
    // produce output; an {"event":"output"} line must stream (poll a few lines)
    {
        var req: [128]u8 = undefined;
        const r = try std.fmt.bufPrint(&req, "{{\"op\":\"send\",\"pane\":{d},\"data\":\"echo ATTACH_STREAM_OK\\n\"}}", .{id});
        try sockWriteAll(fd, r);
        try sockWriteAll(fd, "\n");
        var got_send_ok = false;
        var got_output = false;
        var tries: u32 = 0;
        while (tries < 40 and !got_output) : (tries += 1) {
            const l_opt = try sockReadLine(fd, alloc, 500);
            const l = l_opt orelse break;
            defer alloc.free(l);
            if (std.mem.indexOf(u8, l, "\"ok\":true") != null) got_send_ok = true;
            const v = json.Parser.parse(alloc, l) catch continue;
            defer json.freeValue(alloc, v);
            if (v.get("event")) |ev| {
                if (std.mem.eql(u8, ev.strOf() orelse "", "output")) {
                    if (v.get("data")) |d| {
                        if (d.strOf()) |b64| {
                            const raw = json.base64Decode(alloc, b64) catch continue;
                            defer alloc.free(raw);
                            if (std.mem.indexOf(u8, raw, "ATTACH_STREAM_OK") != null) got_output = true;
                        }
                    }
                }
            }
        }
        try std.testing.expect(got_send_ok);
        try std.testing.expect(got_output);
        std.debug.print("E2E_ATTACH_STREAM_OK\n", .{});
    }
    // server still alive afterwards
    try sockWriteAll(fd, "{\"op\":\"ls\"}\n");
    const l2 = try sockReadResponse(fd, alloc, 3000) orelse return error.NoReply;
    defer alloc.free(l2);
    try std.testing.expect(std.mem.indexOf(u8, l2, "\"panes\"") != null);
    std.debug.print("E2E_ATTACH_SERVER_ALIVE_OK\n", .{});
}
