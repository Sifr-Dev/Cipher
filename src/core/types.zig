//! Core types: generational handles, resource identity, and the
//! dependency contract for the sifr framework.
//!
//! Zero third-party dependencies. All types are plain Zig.
const std = @import("std");

/// A stable, generational resource handle.
/// Index + generation prevents stale-handle aliasing after pool reuse.
pub const Handle = struct {
    index: u32,
    generation: u32,

    pub fn nullHandle() Handle {
        return .{ .index = 0xFFFF_FFFF, .generation = 0 };
    }

    pub fn isNull(self: Handle) bool {
        return self.index == 0xFFFF_FFFF;
    }

    pub fn eq(a: Handle, b: Handle) bool {
        return a.index == b.index and a.generation == b.generation;
    }
};

/// Resource kinds tracked by the framework.
pub const ResourceKind = enum {
    image,
    buffer,
    glyph_atlas,
    render_target,
    shader_module,
    pipeline,
    surface,
    presentation_slot,
};

/// Lifecycle state of a framework resource.
pub const ResourceState = enum {
    free,
    allocated,
    gpu_writing,
    ready_to_commit,
    compositor_owned,
    released,
    retired,
};

/// A resource record with explicit ownership across three domains:
/// application (CPU), GPU execution, and external presentation.
pub const ResourceRecord = struct {
    handle: Handle,
    kind: ResourceKind,
    state: ResourceState = .free,
    content_version: u64 = 0,
    last_gpu_use: u64 = 0,
    external_lease_count: u32 = 0,
    application_claims: u32 = 0,
    size_bytes: usize = 0,
};

/// Result of an operation that may fail due to resource exhaustion or
/// protocol error.
pub const Error = error{
    OutOfMemory,
    ProtocolError,
    DeviceLost,
    SurfaceDestroyed,
    UnsupportedFormat,
    ImportRejected,
    HandleInvalid,
    NotInitialized,
};

/// Allocator domain for bounded memory tracking.
pub const AllocatorDomain = enum {
    process,
    scene_pool,
    frame_scratch,
    worker_scratch,
    resource_cache,
    gpu_upload_ring,
    device_allocation,
};

pub const AllocatorTag = struct {
    domain: AllocatorDomain,
    name: []const u8,
};

pub const TraceEvent = struct {
    timestamp_ns: u64,
    kind: []const u8,
    detail: []const u8,
};

pub const Diagnostics = struct {
    events: [1024]TraceEvent = undefined,
    event_count: usize = 0,
    allocator: std.mem.Allocator = undefined,

    pub fn init(allocator: std.mem.Allocator) Diagnostics {
        return .{
            .events = undefined,
            .event_count = 0,
            .allocator = allocator,
        };
    }

    pub fn record(self: *Diagnostics, kind: []const u8, detail: []const u8) void {
        if (self.event_count >= self.events.len) return;
        self.events[self.event_count] = TraceEvent{
            .timestamp_ns = 0,
            .kind = kind,
            .detail = detail,
        };
        self.event_count += 1;
    }
};

pub fn initDiagnostics(allocator: std.mem.Allocator) Diagnostics {
    return Diagnostics.init(allocator);
}

test "handle null and equality" {
    const a = Handle{ .index = 5, .generation = 1 };
    const b = Handle{ .index = 5, .generation = 1 };
    const c = Handle{ .index = 5, .generation = 2 };
    const n = Handle.nullHandle();
    try std.testing.expect(Handle.eq(a, b));
    try std.testing.expect(!Handle.eq(a, c));
    try std.testing.expect(n.isNull());
    try std.testing.expect(!a.isNull());
}

test "resource record default is free" {
    const rec = ResourceRecord{
        .handle = Handle{ .index = 0, .generation = 1 },
        .kind = .image,
    };
    try std.testing.expectEqual(.free, rec.state);
    try std.testing.expectEqual(0, rec.external_lease_count);
}
