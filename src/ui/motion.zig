//! Motion — spring-based animation for immediate-mode widgets.
//!
//! A spring is stepped at 480 Hz inside each host frame; the value converges
//! toward `target` with physical damping. Widget code calls
//! `motionSpring(id, target, spring)` once per frame; entries persist across
//! frames keyed by a caller-chosen id (typically the widget's stable id).
//!
//! Physics: mass = 1, stiffness k = (2π/natural_period)², damping c = 2·ζ·√k.
//! Semi-implicit Euler at h = 1/480 s with a fractional step accumulator so
//! the integration stays stable at any host frame rate.
//!
//! When Reduce Motion is set (system or `Ui.motion.reduce_motion`), every
//! spring returns its target immediately and entries are discarded.

const std = @import("std");

fn nowNs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return ts.sec * 1_000_000_000 + ts.nsec;
}

pub const Spring = struct {
    /// Natural period: time for one free oscillation, seconds. Smaller = tighter.
    natural_period: f32,
    /// Damping ratio. 1.0 = critically damped, <1 underdamped (overshoots), >1 overdamped.
    zeta: f32,

    pub const zen = Spring{ .natural_period = 0.55, .zeta = 1.0 };
    pub const smooth = Spring{ .natural_period = 0.35, .zeta = 0.9 };
    pub const snappy = Spring{ .natural_period = 0.22, .zeta = 0.85 };
    pub const bouncy = Spring{ .natural_period = 0.38, .zeta = 0.55 };
    pub const gentle = Spring{ .natural_period = 0.7, .zeta = 0.75 };
};

const Entry = struct {
    value: f32,
    velocity: f32 = 0,
    target: f32,
    /// Spring: sub-step accumulator in seconds. Tween: elapsed seconds.
    acc: f32 = 0,
    /// Tween origin: value when the current tween started.
    from: f32 = 0,
    /// Last frame this entry was requested (for pruning).
    used: u64 = 0,
};

pub const Motion = struct {
    entries: std.AutoHashMapUnmanaged(u64, Entry) = .empty,
    gpa: std.mem.Allocator,
    frame: u64 = 0,
    /// Seconds since the previous host frame. Captured by beginFrame().
    dt: f32 = 1.0 / 60.0,
    reduce_motion: bool = false,
    last_ns: i64 = 0,

    pub fn init(gpa: std.mem.Allocator) Motion {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Motion) void {
        self.entries.deinit(self.gpa);
    }

    /// Called once per host frame (from Ui.begin). Captures the wall-clock
    /// delta so widget code doesn't need to thread dt through call sites.
    pub fn beginFrame(self: *Motion) void {
        const now = nowNs();
        if (self.last_ns == 0) {
            self.last_ns = now;
        } else {
            const raw = @as(f32, @floatFromInt(now - self.last_ns)) / 1e9;
            self.dt = @max(0.0, @min(raw, 0.25)); // clamp pathological stalls
            self.last_ns = now;
        }
        self.frame +%= 1;
        self.prune();
    }

    /// Forget entries untouched for 240 frames (~4 s at 60 fps).
    fn prune(self: *Motion) void {
        var stale: [256]u64 = undefined;
        var n: usize = 0;
        var it = self.entries.iterator();
        while (it.next()) |item| {
            if (self.frame -% item.value_ptr.used > 240) {
                if (n >= stale.len) break;
                stale[n] = item.key_ptr.*;
                n += 1;
            }
        }
        for (stale[0..n]) |k| _ = self.entries.remove(k);
    }

    fn entryFor(self: *Motion, id: u64, target: f32, start: f32) *Entry {
        const gop = self.entries.getOrPut(self.gpa, id) catch unreachable; // OOM in animation is not recoverable mid-frame
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .value = start, .target = target, .used = self.frame };
        }
        gop.value_ptr.used = self.frame;
        return gop.value_ptr;
    }

    /// Current value of spring `id` approaching `target`. First call snaps to
    /// `target`; later calls integrate the spring toward `target` over time.
    pub fn spring(self: *Motion, id: u64, target: f32, s: Spring) f32 {
        if (self.reduce_motion) return target;
        const e = self.entryFor(id, target, target);
        if (e.target != target) {
            e.target = target; // retarget: keep current value and velocity
        }
        const k = std.math.pow(f32, 2.0 * std.math.pi / s.natural_period, 2);
        const c = 2.0 * s.zeta * @sqrt(k);
        const h: f32 = 1.0 / 480.0;
        const owed = e.acc + self.dt;
        const steps: u32 = @intFromFloat(@floor(owed * 480.0));
        e.acc = owed - @as(f32, @floatFromInt(steps)) * h;
        var step: u32 = 0;
        while (step < steps) : (step += 1) {
            // Semi-implicit Euler: update velocity from force, then position.
            const a = -k * (e.value - target) - c * e.velocity;
            e.velocity += a * h;
            e.value += e.velocity * h;
        }
        return e.value;
    }

    /// Value moving from wherever it is now to `target` over exactly
    /// `duration` seconds, eased with a cubic Bézier curve. Retargeting
    /// mid-tween starts a fresh tween from the current value.
    /// Mostly useful for opacity / fades where a physical spring is wrong.
    pub fn tween(self: *Motion, id: u64, target: f32, duration: f32, curve: CubicBezier) f32 {
        if (self.reduce_motion) return target;
        if (duration <= 0) return target;
        const e = self.entryFor(id, target, target);
        if (e.target != target) {
            e.target = target;
            e.from = e.value;
            e.acc = 0;
        } else {
            e.acc += self.dt;
        }
        const t = @min(1.0, e.acc / duration);
        return std.math.lerp(e.from, target, curve.solve(t));
    }
};

/// Cubic Bézier with the two control points (P1, P2). Axis P0=(0,0), P3=(1,1).
pub const CubicBezier = struct {
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,

    pub const ease_out = CubicBezier{ .x1 = 0.0, .y1 = 0.0, .x2 = 0.58, .y2 = 1.0 };
    pub const ease_in_out = CubicBezier{ .x1 = 0.42, .y1 = 0.0, .x2 = 0.58, .y2 = 1.0 };
    pub const linear = CubicBezier{ .x1 = 0.0, .y1 = 0.0, .x2 = 1.0, .y2 = 1.0 };

    pub fn solve(self: CubicBezier, x: f32) f32 {
        const x_ = std.math.clamp(x, 0.0, 1.0);
        // Bisect for the t whose bezier-x equals x_ (monotonic when x1,x2 ∈ [0,1]).
        var lo: f32 = 0;
        var hi: f32 = 1;
        var t: f32 = x_;
        var i: u32 = 0;
        while (i < 24) : (i += 1) {
            const bx = cubic(1.0 - t, t, self.x1, self.x2);
            if (bx < x_) lo = t else hi = t;
            t = (lo + hi) * 0.5;
        }
        return cubic(1.0 - t, t, self.y1, self.y2);
    }

    fn cubic(u: f32, b: f32, p1: f32, p2: f32) f32 {
        // Bernstein form with P0=0, P3=1: 3·u²·b·P1 + 3·u·b²·P2 + b³·1
        return 3.0 * u * u * b * p1 + 3.0 * u * b * b * p2 + b * b * b;
    }
};

test "spring converges to target" {
    var m = Motion.init(std.testing.allocator);
    defer m.deinit();
    var v: f32 = 0;
    // Simulate 2 seconds at 120 fps frames.
    var frame: u32 = 0;
    while (frame < 240) : (frame += 1) {
        m.dt = 1.0 / 120.0;
        m.frame +%= 1;
        v = m.spring(777, 100.0, Spring{ .natural_period = 0.35, .zeta = 0.9 });
    }
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), v, 0.5);
}

test "underdamped spring overshoots when retargeted" {
    var m = Motion.init(std.testing.allocator);
    defer m.deinit();
    // Start at 0 (first call snaps), then retarget to 100: a bouncy spring must overshoot past 100.
    const s = Spring{ .natural_period = 0.4, .zeta = 0.4 };
    _ = m.spring(778, 0.0, s);
    var peak: f32 = 0;
    var frame: u32 = 0;
    while (frame < 240) : (frame += 1) {
        m.dt = 1.0 / 120.0;
        m.frame +%= 1;
        const v = m.spring(778, 100.0, s);
        if (v > peak) peak = v;
    }
    try std.testing.expect(peak > 100.0); // overshoot happened
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), peak, 40.0); // but settles near target
}

test "reduce motion snaps instantly" {
    var m = Motion.init(std.testing.allocator);
    defer m.deinit();
    m.reduce_motion = true;
    const v = m.spring(779, 42.0, Spring.snappy);
    try std.testing.expectEqual(@as(f32, 42.0), v);
}

test "prune drops stale entries" {
    var m = Motion.init(std.testing.allocator);
    defer m.deinit();
    _ = m.spring(1, 1.0, Spring.zen);
    _ = m.spring(2, 1.0, Spring.zen);
    m.frame = 500;
    m.beginFrame(); // prune runs at 500 - used(1) > 240
    try std.testing.expect(m.entries.count() == 0);
}

test "tween reaches target" {
    var m = Motion.init(std.testing.allocator);
    defer m.deinit();
    var v: f32 = 0;
    var frame: u32 = 0;
    while (frame < 120) : (frame += 1) {
        m.dt = 1.0 / 60.0;
        m.frame +%= 1;
        v = m.tween(880, 1.0, 1.0, CubicBezier.ease_out);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), v, 0.001);
}
