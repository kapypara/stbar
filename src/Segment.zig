const std = @import("std");
const Allocator = std.mem.Allocator;

const Metric = @import("metrics.zig").Metric;
const MetricTag = @import("metrics.zig").MetricTag;

pub const SegmentType = enum {
    average,
    rate_of_change,
    message,
};

const ValueUnion = union {
    int: u64,
    message: []u8,
};

pub const MetricEntry = struct {
    metric: Metric,
    start_index: u16 = undefined, // index of first cell to use from Parent
    sample: []u64 = undefined, // fetched metric samples
    frames: []u64 = undefined, // frames to be rendered
};

pub const Segment = struct {
    // last_value: ValueUnion = .{ .int = 0 },
    // state_type: SegmentType = .average,
    // step_limit: u8 = 0,

    // ech segment have it's main color
    color: [4]f32 = undefined, // Assuming vec4 is 4 floats

    cells: []i16 = undefined,
    metrics: []MetricEntry,

    y_offset: f32 = undefined,
    // char_offset: u16 = undefined,
    // limit: u16 = undefined,
    // allocator: Allocator = undefined,

    // Equivalent to operator() setup
    // pub fn init(self: *Segment, allocator: Allocator, memory_size: u16, transition_size: u16, x_pos: []f32, y_pos: f32, offset: u16, color: [4]f32) !void {
    pub fn init(self: *Segment, allocator: Allocator, memory_size: u16, transition_size: u16) !void {
        self.ticks = try allocator.alloc(u64, memory_size);
        @memset(self.ticks, 0);

        self.transition_values = try allocator.alloc(u64, transition_size);
        @memset(self.transition_values, 0);

        // log2 for u32
        self.step_limit = @intCast(std.math.log2(@as(u32, transition_size)));

        // From Segment Draw
        // const slots = try allocator.alloc(f32, x_pos);
        // @memcpy(slots, x_pos);
        //
        // self.slots = slots;
        // self.y_offset = y_pos;
        // self.char_offset = offset;
        // self.limit = @intCast(slots.len);
        // self.color = color;
        // self.allocator = allocator;

        self.metric = Metric.init(self.metric_type);
    }

    pub fn deinit(self: *Segment) void {
        const allocator = self.allocator;
        allocator.free(self.ticks);
        allocator.free(self.transition_values);
        // TODO
        // self.draw.deinit();
    }

    pub fn update(self: *Segment, io: std.Io) void {
        // TODO
        // allocate value in sample array
        // compute frame array
        for (self.metrics) |*meteric_entry| {
            var m = &meteric_entry.metric;
            _ = m.sample(io) catch {};
            std.debug.print("{any}\n", .{m});
        }
    }

    pub fn setSlots(self: *Segment, x_positions: []const f32) !void {
        if (x_positions.len != self.slots.len) {
            self.slots = try self.allocator.realloc(self.slots, x_positions.len);
        }
        @memcpy(self.slots, x_positions);
        self.limit = @intCast(self.slots.len);
    }

    pub fn ticksSum(self: Segment) u64 {
        var sum: u64 = 0;
        for (self.ticks) |t| sum += t;
        return sum;
    }

    pub fn newTick(self: *Segment, tick_index: u16, value: u64) void {
        self.ticks[tick_index] = value;
        var target = self.ticksSum();

        if (self.state_type == .average) {
            target /= self.ticks.len;
        }

        self.setTransition(target);
    }

    pub fn setTransition(self: *Segment, goal: u64) void {
        var step: i64 = @as(i64, @intCast(goal)) - @as(i64, @intCast(self.last));

        if (step == 0) {
            @memset(self.transition_values, goal);
            return;
        }

        // Logic for bitwise-style step division
        var i: u8 = 0;
        while (i < self.step_limit) : (i += 1) {
            const div_step = @divTrunc(step, 2);
            step = if (div_step != 0) div_step else step;
        }

        var increment: i64 = @as(i64, @intCast(self.last));

        if (step > 0) {
            for (self.transition_values, 0..) |*val, idx| {
                increment += step;
                if (increment < @as(i64, @intCast(goal))) {
                    val.* = @as(u64, @intCast(increment));
                } else {
                    @memset(self.transition_values[idx..], goal);
                    break;
                }
            }
        } else {
            for (self.transition_values, 0..) |*val, idx| {
                increment += step;
                if (increment > @as(i64, @intCast(goal)) and increment > -1) {
                    val.* = @as(u64, @intCast(increment));
                } else {
                    @memset(self.transition_values[idx..], goal);
                    break;
                }
            }
        }
    }

    pub fn getTransitionStep(self: *Segment, i: u16) u64 {
        self.last = self.transition_values[i];
        return self.last;
    }
};
