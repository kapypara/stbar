const std = @import("std");
const Metric = @import("metrics.zig").Metric;
const ClickAction = @import("Actions.zig").ClickAction;

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
    prev: u128 = 0, // value at sample_start_ns
    target: u128 = 0, // target smoothed value at next_sample_ns
    last_p1: u64 = std.math.maxInt(u64),
    last_p2: u64 = std.math.maxInt(u64),

    pub fn interpolateAt(self: *const MetricEntry, progress: f64) u128 {
        const t = std.math.clamp(progress, 0.0, 1.0);
        const p1 = lerpChannel(@truncate(self.prev), @truncate(self.target), t);
        const p2 = lerpChannel(@truncate(self.prev >> 64), @truncate(self.target >> 64), t);
        return (@as(u128, p2) << 64) | @as(u128, p1);
    }

    pub fn lerpChannel(start: u64, end: u64, t: f64) u64 {
        if (start == end or t >= 1.0) return end;
        if (t <= 0.0) return start;
        const s = @as(f64, @floatFromInt(start));
        const e = @as(f64, @floatFromInt(end));
        return @intFromFloat(@max(0.0, @round(s + t * (e - s))));
    }
};

pub const Segment = struct {
    color: u32 = 0, // RGBA32 hex color
    cell_start: usize = 0,
    cells: []i16 = &.{},
    metrics: []MetricEntry = &.{},
    static_overlay: []const u8 = "",
    static_offset: u8 = 0,
    on_click: ClickAction = .none,

    pub fn update(self: *Segment, io: std.Io, sample_idx: usize, prior_progress: f64) void {
        for (self.metrics) |*entry| {
            var m = &entry.metric;
            m.sample(io) catch {};

            if (m.* == .window or m.* == .time) continue;
            if (entry.sample.len == 0) continue;

            // Anchor start of new interpolation window at the currently displayed interpolated value
            entry.prev = entry.interpolateAt(prior_progress);

            const p1 = m.get(0);
            const p2 = if (m.* == .memory or m.* == .io or m.* == .net) m.get(1) else 0;
            entry.sample[sample_idx % entry.sample.len] = (@as(u128, p2) << 64) | @as(u128, p1);

            var sum_p1: u64 = 0;
            var sum_p2: u64 = 0;
            for (entry.sample) |s_val| {
                sum_p1 +%= @truncate(s_val);
                sum_p2 +%= @truncate(s_val >> 64);
            }

            const sample_len_f = @as(f64, @floatFromInt(entry.sample.len));
            const next_p1: u64 = switch (entry.mode) {
                .average, .rate_of_change => @intFromFloat(@ceil(@as(f64, @floatFromInt(sum_p1)) / sample_len_f)),
                .message => sum_p1,
            };
            const next_p2: u64 = switch (entry.mode) {
                .average, .rate_of_change => @intFromFloat(@ceil(@as(f64, @floatFromInt(sum_p2)) / sample_len_f)),
                .message => sum_p2,
            };

            entry.target = (@as(u128, next_p2) << 64) | @as(u128, next_p1);
        }
    }
};

test "Segment interpolates smoothly across monotonic progress [0.0, 1.0]" {
    const entry = MetricEntry{
        .metric = .{ .cpu = .{} },
        .prev = (@as(u128, 1000) << 64) | 10,
        .target = (@as(u128, 2000) << 64) | 30,
    };
    try std.testing.expectEqual(@as(u64, 10), @as(u64, @truncate(entry.interpolateAt(0.0))));
    try std.testing.expectEqual(@as(u64, 20), @as(u64, @truncate(entry.interpolateAt(0.5))));
    try std.testing.expectEqual(@as(u64, 30), @as(u64, @truncate(entry.interpolateAt(1.0))));
    try std.testing.expectEqual(@as(u64, 1500), @as(u64, @truncate(entry.interpolateAt(0.5) >> 64)));
}
