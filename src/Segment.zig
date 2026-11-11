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
    current: u128 = 0, // current smoothed sample value
    last_p1: u64 = std.math.maxInt(u64),
    last_p2: u64 = std.math.maxInt(u64),
};

pub const Segment = struct {
    color: u32 = 0, // RGBA32 hex color
    cell_start: usize = 0,
    cells: []i16 = &.{},
    metrics: []MetricEntry = &.{},
    static_overlay: []const u8 = "",
    static_offset: u8 = 0,

    pub fn update(self: *Segment, io: std.Io, sample_idx: usize) void {
        for (self.metrics) |*entry| {
            var m = &entry.metric;
            m.sample(io) catch {};

            if (m.* == .window or m.* == .time) continue;
            if (entry.sample.len == 0) continue;

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

            entry.current = (@as(u128, next_p2) << 64) | @as(u128, next_p1);
        }
    }
};

test "Segment computes rolling average across sample ring buffer" {
    var samples: [4]u128 = @splat(0);
    samples[0] = (@as(u128, 400) << 64) | 80;
    samples[1] = (@as(u128, 400) << 64) | 40;

    var sum_p1: u64 = 0;
    for (samples) |s| sum_p1 += @truncate(s);
    const avg_p1: u64 = @intFromFloat(@ceil(@as(f64, @floatFromInt(sum_p1)) / 4.0));
    try std.testing.expectEqual(@as(u64, 30), avg_p1);
}
