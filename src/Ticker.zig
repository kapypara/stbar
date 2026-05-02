const std = @import("std");
const nanoTimestamp = @import("std").time.nanoTimestamp;

pub fn Ticker(comptime sleep_freq: u64, comptime work_freq: u64) type {
    if (sleep_freq % work_freq != 0) {
        @compileError("For stable intervals, sleep_freq must be divisible by work_freq.");
    }

    return struct {
        next_tick_ns: u64,
        tick_count: u64 = 0,

        const period_ns = std.time.ns_per_s / sleep_freq;
        const work_interval = sleep_freq / work_freq;

        pub fn init() !@This() {
            return .{
                // Initialize starting point to "now"
                .next_tick_ns = @intCast(nanoTimestamp()),
            };
        }

        // sleep current thread and return true if work need to be done
        pub fn tick(self: *@This()) bool {
            const now: u64 = @intCast(nanoTimestamp());

            // 1. Calculate Sleep
            if (now < self.next_tick_ns) {
                std.Thread.sleep(self.next_tick_ns - now);
            }

            // 2. Update the absolute deadline for the NEXT tick
            // This prevents drift because the period is added to the 
            // intended time, not the actual wake time.
            self.next_tick_ns += period_ns;

            // 3. Determine if this is a work tick
            const is_work_tick = (self.tick_count % work_interval == 0);
            
            // 4. Increment counter
            self.tick_count = (self.tick_count + 1) % sleep_freq;

            return is_work_tick;
        }
    };
}
