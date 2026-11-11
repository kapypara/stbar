const std = @import("std");

const real = std.Io.Clock.real;
const awake = std.Io.Clock.awake;

pub fn nanoTimestamp(io: std.Io) i96 {
    const ts = std.Io.Clock.now(real, io);
    return ts.nanoseconds;
}

pub fn monotonicNs(io: std.Io) i96 {
    const ts = std.Io.Clock.now(awake, io);
    return ts.nanoseconds;
}

pub const Ticker = struct {
    io: std.Io = undefined,

    next_tick_ns: u64,
    tick_count: u64,

    period_ns: u64,
    work_interval: u64,

    pub fn init(io: std.Io, sleep_freq: u64, work_freq: u64) Ticker {
        const period_ns = std.time.ns_per_s / sleep_freq;
        const work_interval = sleep_freq / work_freq;

        return .{
            .io = io,
            .next_tick_ns = @intCast(nanoTimestamp(io)),
            .tick_count = 0,
            .period_ns = period_ns,
            .work_interval = work_interval,
        };
    }

    pub fn tick(self: *Ticker) void {
        const now = nanoTimestamp(self.io);

        if (now < self.next_tick_ns) {
            const duration = std.Io.Duration.fromNanoseconds(self.next_tick_ns - now);
            std.Io.sleep(self.io, duration, real) catch {};
        }

        // Advance deadline from intended time to prevent cumulative drift
        self.next_tick_ns += self.period_ns;
    }
};
