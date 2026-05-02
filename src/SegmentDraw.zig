const std = @import("std");
const Allocator = std.mem.Allocator;

pub const SegmentType = enum {
    average,
    rate_of_change,
};

pub const SegmentDraw = struct {
    slots: []f32,
    y_offset: f32,
    char_offset: u16,
    limit: u16,
    color: [4]f32, // Assuming vec4 is 4 floats
    allocator: Allocator,

    pub fn init(allocator: Allocator, x_positions: []const f32, y_pos: f32, offset: u16, color: [4]f32) !SegmentDraw {
        const slots = try allocator.alloc(f32, x_positions.len);
        @memcpy(slots, x_positions);
        return .{
            .slots = slots,
            .y_offset = y_pos,
            .char_offset = offset,
            .limit = @intCast(slots.len),
            .color = color,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SegmentDraw) void {
        self.allocator.free(self.slots);
    }

    pub fn setSlots(self: *SegmentDraw, x_positions: []const f32) !void {
        if (x_positions.len != self.slots.len) {
            self.slots = try self.allocator.realloc(self.slots, x_positions.len);
        }
        @memcpy(self.slots, x_positions);
        self.limit = @intCast(self.slots.len);
    }
};

pub const Segment = struct {
    draw: SegmentDraw, // Composition instead of inheritance
    last: u64 = 0,
    state_type: SegmentType = .average,
    step_limit: u8 = 0,
    ticks: []u64,
    transition_values: []u64,

    // Equivalent to operator() setup
    pub fn initData(self: *Segment, allocator: Allocator, memory_size: u16, transition_size: u16, use: SegmentType) !void {
        self.state_type = use;
        self.ticks = try allocator.alloc(u64, memory_size);
        @memset(self.ticks, 0);
        
        self.transition_values = try allocator.alloc(u64, transition_size);
        @memset(self.transition_values, 0);

        // log2 for u32
        self.step_limit = @intCast(std.math.log2(@as(u32, transition_size)));
    }

    pub fn deinit(self: *Segment) void {
        const allocator = self.draw.allocator;
        allocator.free(self.ticks);
        allocator.free(self.transition_values);
        self.draw.deinit();
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
