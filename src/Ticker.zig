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

pub fn sleepNs(io: std.Io, ns: i96) void {
    if (ns <= 0) return;
    const duration = std.Io.Duration.fromNanoseconds(ns);
    std.Io.sleep(io, duration, awake) catch {};
}
