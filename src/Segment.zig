const std = @import("std");
const Metric = @import("metrics.zig").Metric;

pub const SegmentType = enum {
    average,
    rate_of_change,
    message,
};

pub const MetricEntry = struct {
    metric: Metric,
    mode: SegmentType = .average,
    start_index: u8 = 0, // cell offset for primary value (low 64 bits)
    secondary_index: ?u8 = null, // optional cell offset for secondary value (high 64 bits)
    secondary_segment: ?*Segment = null, // optional target segment if secondary renders elsewhere
    sample: []u128 = &.{}, // ring buffer of raw samples
    frames: []u128 = &.{}, // interpolated per-frame values between samples
    last_p1: u64 = std.math.maxInt(u64),
    last_p2: u64 = std.math.maxInt(u64),
};

pub const Segment = struct {
    color: u32 = 0, // RGBA32 hex color
    cells: []i16 = &.{},
    metrics: []MetricEntry = &.{},
    static_overlay: []const u8 = "",
    static_offset: u8 = 0,

    pub fn update(self: *Segment, io: std.Io, sample_idx: u8) void {
        for (self.metrics) |*entry| {
            var m = &entry.metric;
            m.sample(io) catch {};

            if (m.* == .window or m.* == .time) continue;
            if (entry.sample.len == 0 or entry.frames.len == 0) continue;

            const p1 = m.get(0);
            const p2 = if (m.* == .memory or m.* == .io or m.* == .net) m.get(1) else 0;
            entry.sample[sample_idx] = (@as(u128, p2) << 64) | @as(u128, p1);

            var sum_p1: u64 = 0;
            var sum_p2: u64 = 0;
            for (entry.sample) |s_val| {
                sum_p1 +%= @truncate(s_val);
                sum_p2 +%= @truncate(s_val >> 64);
            }

            const target_p1: f64 = switch (entry.mode) {
                .average => @as(f64, @floatFromInt(sum_p1)) / @as(f64, @floatFromInt(entry.sample.len)),
                .rate_of_change, .message => @as(f64, @floatFromInt(sum_p1)),
            };
            const target_p2: f64 = switch (entry.mode) {
                .average => @as(f64, @floatFromInt(sum_p2)) / @as(f64, @floatFromInt(entry.sample.len)),
                .rate_of_change, .message => @as(f64, @floatFromInt(sum_p2)),
            };

            const total_frames = @as(f64, @floatFromInt(entry.frames.len));
            const last_frame = entry.frames[entry.frames.len - 1];
            const start_f1 = @as(f64, @floatFromInt(@as(u64, @truncate(last_frame))));
            const start_f2 = @as(f64, @floatFromInt(@as(u64, @truncate(last_frame >> 64))));

            for (entry.frames, 0..) |*frame_val, i| {
                const pct = @as(f64, @floatFromInt(i + 1)) / total_frames;

                const next_f1 = @as(u64, @intFromFloat(@max(0.0, @ceil(start_f1 + pct * (target_p1 - start_f1)))));
                const next_f2 = @as(u64, @intFromFloat(@max(0.0, @ceil(start_f2 + pct * (target_p2 - start_f2)))));

                frame_val.* = (@as(u128, next_f2) << 64) | @as(u128, next_f1);
            }
        }
    }
};

test "Segment interpolates average and rate_of_change monotonically" {
    var samples: [4]u128 = @splat(0);
    var frames: [5]u128 = @splat(0);

    samples[0] = (@as(u128, 400) << 64) | 80;
    const sum_p1: u64 = 80;
    const avg_p1: f64 = @as(f64, @floatFromInt(sum_p1)) / 4.0; // 20.0
    for (&frames, 0..) |*f, i| {
        const pct = @as(f64, @floatFromInt(i + 1)) / 5.0;
        const v1 = @as(u64, @intFromFloat(@ceil(pct * avg_p1)));
        f.* = v1;
    }
    try std.testing.expectEqual(@as(u128, 4), frames[0]);
    try std.testing.expectEqual(@as(u128, 20), frames[4]);
}
