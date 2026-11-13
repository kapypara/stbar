const std = @import("std");
const c = @import("c");
const Window = @import("Window.zig").Window;
const ticker_zig = @import("Ticker.zig");
const PowerFlow = @import("formats.zig").PowerFlow;

/// Declarative left-click action attached to each `Segment`.
pub const ClickAction = union(enum) {
    none,
    /// Spawns a detached process directly via `fork` + `setsid` + `execvp` (zero shell overhead).
    spawn: []const [*:0]const u8,
    /// Spawns `argv` if `bin` exists in `$PATH`, otherwise falls back to `fallback`.
    spawn_if_installed: struct {
        bin: []const u8,
        argv: []const [*:0]const u8,
        fallback: []const [*:0]const u8,
    },
    /// Formats current Unix epoch seconds (`1794507...`) and copies natively to Wayland/X11 clipboard.
    copy_unix_timestamp,
    /// Copies the current sanitized active window title natively to Wayland/X11 clipboard.
    copy_window_title,
    /// Copies live battery `%` + total system wattage (+ charging wattage if charging) to clipboard.
    copy_power_summary,
};

pub const PowerSnapshot = struct {
    has_battery: bool = false,
    has_power_sensor: bool = false,
    flow_state: PowerFlow = .maintaining,
    capacity_pct: u64 = 0,
    effective_tenths_w: u64 = 0,
};

pub fn formatPowerSummary(snap: PowerSnapshot, out: *[48]u8) []const u8 {
    const whole_w = snap.effective_tenths_w / 10;
    const frac_w = snap.effective_tenths_w % 10;
    if (!snap.has_battery) {
        if (!snap.has_power_sensor) return "";
        return std.fmt.bufPrint(out, "{d}.{d}W", .{ whole_w, frac_w }) catch "";
    }
    if (!snap.has_power_sensor) {
        return std.fmt.bufPrint(out, "{d}%", .{snap.capacity_pct}) catch "";
    }
    const sign: []const u8 = switch (snap.flow_state) {
        .maintaining => "",
        .discharging => "-",
        .charging => "+",
    };
    return std.fmt.bufPrint(
        out,
        "{d}% {s}{d}.{d}W",
        .{ snap.capacity_pct, sign, whole_w, frac_w },
    ) catch "";
}

pub const max_spawn_args = 15;

/// Checks whether `bin` resolves to an executable file directly or along `path_env`.
pub fn isExecutableInPath(bin: []const u8, path_env: []const u8) bool {
    if (bin.len == 0 or bin.len >= 256) return false;

    var candidate: [512]u8 = undefined;
    if (std.mem.indexOfScalar(u8, bin, '/') != null) {
        @memcpy(candidate[0..bin.len], bin);
        candidate[bin.len] = 0;
        return c.access(&candidate, c.X_OK) == 0;
    }

    var it = std.mem.tokenizeScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0 or dir.len + 1 + bin.len >= candidate.len) continue;
        @memcpy(candidate[0..dir.len], dir);
        candidate[dir.len] = '/';
        @memcpy(candidate[dir.len + 1 .. dir.len + 1 + bin.len], bin);
        candidate[dir.len + 1 + bin.len] = 0;
        if (c.access(&candidate, c.X_OK) == 0) return true;
    }
    return false;
}

fn execInChild(argv: []const [*:0]const u8) noreturn {
    var c_argv: [max_spawn_args + 1:null]?[*:0]const u8 = @splat(null);
    for (argv, 0..) |arg, idx| {
        c_argv[idx] = arg;
    }
    _ = c.execvp(argv[0], @ptrCast(&c_argv));
    c._exit(127);
}

fn prepareChild() void {
    var dflt: c.struct_sigaction = std.mem.zeroes(c.struct_sigaction);
    _ = c.sigaction(c.SIGCHLD, &dflt, null);
    _ = c.sigaction(c.SIGINT, &dflt, null);
    _ = c.sigaction(c.SIGTERM, &dflt, null);

    _ = c.setsid();

    const devnull = c.open("/dev/null", c.O_RDWR);
    if (devnull >= 0) {
        _ = c.dup2(devnull, 0);
        _ = c.dup2(devnull, 1);
        _ = c.dup2(devnull, 2);
        if (devnull > 2) _ = c.close(devnull);
    }
}

/// Forks and execs `argv` in a new session (`setsid`) with stdio attached to `/dev/null`
/// and default signal dispositions restored so child processes behave identically to desktop launch.
pub fn spawnDetached(argv: []const [*:0]const u8) void {
    if (argv.len == 0 or argv.len > max_spawn_args) return;

    const pid = c.fork();
    if (pid != 0) return; // Parent returns immediately; kernel reaps via SA_NOCLDWAIT

    prepareChild();
    execInChild(argv);
}

pub fn spawnPreferred(
    bin: []const u8,
    primary: []const [*:0]const u8,
    fallback: []const [*:0]const u8,
) void {
    if (primary.len == 0 or primary.len > max_spawn_args) return;
    if (fallback.len == 0 or fallback.len > max_spawn_args) return;

    const pid = c.fork();
    if (pid != 0) return; // Parent returns immediately; PATH probe runs off-thread in child

    prepareChild();
    const path_raw = std.c.getenv("PATH");
    const path_slice = if (path_raw) |p| std.mem.span(p) else "/usr/local/bin:/usr/bin:/bin";
    const chosen = if (isExecutableInPath(bin, path_slice)) primary else fallback;
    execInChild(chosen);
}

pub fn execute(
    action: ClickAction,
    io: std.Io,
    window: *Window,
    active_window_title: []const u8,
    power_snap: PowerSnapshot,
) void {
    switch (action) {
        .none => {},
        .spawn => |argv| spawnDetached(argv),
        .spawn_if_installed => |spec| spawnPreferred(spec.bin, spec.argv, spec.fallback),
        .copy_unix_timestamp => {
            const ts = ticker_zig.nanoTimestamp(io);
            const unix_secs: i64 = @intCast(@divFloor(ts, std.time.ns_per_s));
            var buf: [32]u8 = undefined;
            const formatted = std.fmt.bufPrint(&buf, "{d}", .{unix_secs}) catch return;
            window.setClipboard(formatted);
        },
        .copy_window_title => {
            if (active_window_title.len > 0) {
                window.setClipboard(active_window_title);
            }
        },
        .copy_power_summary => {
            var buf: [48]u8 = undefined;
            const summary = formatPowerSummary(power_snap, &buf);
            if (summary.len > 0) {
                window.setClipboard(summary);
            }
        },
    }
}

test "isExecutableInPath and formatPowerSummary operate without allocations" {
    try std.testing.expect(isExecutableInPath("sh", "/nonexistent:/usr/bin:/bin"));
    try std.testing.expect(!isExecutableInPath("zigbar_definitely_missing_bin_xyz", "/usr/bin:/bin"));
    try std.testing.expect(isExecutableInPath("/bin/sh", ""));

    var buf: [48]u8 = undefined;
    try std.testing.expectEqualStrings(
        "18.4W",
        formatPowerSummary(.{ .has_battery = false, .has_power_sensor = true, .effective_tenths_w = 184 }, &buf),
    );
    try std.testing.expectEqualStrings(
        "98% 10.0W",
        formatPowerSummary(.{ .has_battery = true, .has_power_sensor = true, .flow_state = .maintaining, .capacity_pct = 98, .effective_tenths_w = 100 }, &buf),
    );
    try std.testing.expectEqualStrings(
        "98% -4.9W",
        formatPowerSummary(.{ .has_battery = true, .has_power_sensor = true, .flow_state = .discharging, .capacity_pct = 98, .effective_tenths_w = 49 }, &buf),
    );
    try std.testing.expectEqualStrings(
        "64% +38.5W",
        formatPowerSummary(.{ .has_battery = true, .has_power_sensor = true, .flow_state = .charging, .capacity_pct = 64, .effective_tenths_w = 385 }, &buf),
    );
}
