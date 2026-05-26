const std = @import("std");
const c = std.c;

const real = std.Io.Clock.real;

io: std.Io,

pub fn nanoTimestamp(io: std.Io) i96 {
    // var ts: c.timespec = undefined;
    
    // Uses CLOCK.REALTIME for calendar/wall-clock time
    // const c_res = c.clock_gettime(c.CLOCK.REALTIME, &ts);   
    // if (c_res != 0) @panic("Can't get realtime from c");

    const ts = std.Io.Clock.now(real, io);
    return ts.nanoseconds;
}

pub const Ticker = struct {
    io: std.Io = undefined,

    next_tick_ns: u64,
    tick_count: u64,

    period_ns: u64,
    work_interval: u64,

    // if (sleep_freq % work_freq != 0) {
    //     @compileError("For stable intervals, sleep_freq must be divisible by work_freq.");
    // }

    pub fn init(io: std.Io, sleep_freq: u64, work_freq: u64) Ticker {

        const period_ns = std.time.ns_per_s / sleep_freq;
        const work_interval = sleep_freq / work_freq;

        return .{
            .io = io,

            // Initialize starting point to "now"
            .next_tick_ns = @intCast(nanoTimestamp(io)),
            .tick_count = 0,
            .period_ns = period_ns,
            .work_interval = work_interval,
        };
    }

    // sleep current thread and return true if work need to be done

    pub fn tick(self: *Ticker) void {
        const now = nanoTimestamp(self.io);

        // 1. Calculate Sleep
        if (now < self.next_tick_ns) {
            const duration = std.Io.Duration.fromNanoseconds(self.next_tick_ns - now);
            std.Io.sleep(self.io, duration, real) catch {};
            std.debug.print("selpt for {}ms\n", .{duration.toMilliseconds()});
        }

        // 2. Update the absolute deadline for the NEXT tick
        // This prevents drift because the period is added to the 
        // intended time, not the actual wake time.
        self.next_tick_ns += self.period_ns;
    }
};
