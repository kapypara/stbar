const std = @import("std");
const c = @import("c");
const window_zig = @import("Window.zig");
const Window = window_zig.Window;
const BackendPreference = window_zig.BackendPreference;
const status_zig = @import("StatusMonitor.zig");
const StatusMonitor = status_zig.StatusMonitor;
const BarMode = status_zig.BarMode;

/// Default display server backend (`--backend=auto|wayland|wayland-egl|x11|x11-glx`):
/// - `.auto`: native Wayland `zwlr_layer_shell_v1` + `wl_shm` when `WAYLAND_DISPLAY` is set, else X11 `MIT-SHM`
const default_backend_mode: BackendPreference = .auto;

/// Default startup bar mode (`--mode=auto-hide|pinned|dock`):
/// - `.auto_hide`: overlay (`strut = OFF`), 1px top hover sensor (>1s reveal, 0 Hz sleep while hidden)
/// - `.pinned_overlay`: overlay (`strut = OFF`), always visible
/// - `.docked_strut`: reserved 17px top dock (`strut = ON`), always visible
const default_initial_mode: BarMode = .auto_hide;

/// Default metric sample frequency while visible (`--hz=1..60`; 0 Hz while hidden).
const default_visible_sample_hz: u8 = 8;

var stop_requested: std.atomic.Value(bool) = .init(false);
var sig_usr1_pending: std.atomic.Value(bool) = .init(false);
var sig_usr2_pending: std.atomic.Value(bool) = .init(false);
var sig_wake_write_fd: std.atomic.Value(c_int) = .init(-1);

fn onSignal(sig: c_int) callconv(.c) void {
    switch (sig) {
        c.SIGUSR1 => sig_usr1_pending.store(true, .release),
        c.SIGUSR2 => sig_usr2_pending.store(true, .release),
        else => stop_requested.store(true, .release),
    }
    const wfd = sig_wake_write_fd.load(.monotonic);
    if (wfd >= 0) {
        const wake_byte: [1]u8 = .{1};
        _ = c.write(wfd, &wake_byte, 1);
    }
}

const CliConfig = struct {
    mode: BarMode = default_initial_mode,
    backend: BackendPreference = default_backend_mode,
    sample_hz: u8 = default_visible_sample_hz,
    output: [64]u8 = @splat(0),
    output_len: u8 = 0,
    exit_early: bool = false,

    pub fn setOutput(self: *CliConfig, val: []const u8) bool {
        if (val.len == 0 or val.len > self.output.len) return false;
        @memcpy(self.output[0..val.len], val);
        self.output_len = @intCast(val.len);
        return true;
    }

    pub fn outputSlice(self: *const CliConfig) []const u8 {
        return self.output[0..self.output_len];
    }
};

const usage_text =
    \\Usage: zigbar [options]
    \\
    \\Options:
    \\  -m, --mode=<auto-hide|pinned|dock>                     Startup bar mode (default: auto-hide)
    \\  -b, --backend=<auto|wayland|wayland-egl|x11|x11-glx>   Display backend (default: auto)
    \\  -o, --output=<connector>                               Target Wayland output (e.g. eDP-1, DP-1; default: primary)
    \\      --hz=<1..60>                                       Metric sample rate while visible (default: 8)
    \\  -h, --help                                             Show this help message and exit
    \\
    \\Mouse & Signal Controls:
    \\  Hover top 1px (>1s)                            Reveal bar in auto-hide mode
    \\  Left-click segment                             Run segment action (copy time/power/title, open btop/dolphin)
    \\  Right-click / SIGUSR1                          Toggle pinned overlay (strut OFF) <-> auto-hide
    \\  Middle-click / SIGUSR2                         Toggle 17px docked strut (strut ON) <-> auto-hide
    \\
;

fn parseModeValue(val: []const u8) ?BarMode {
    if (std.mem.eql(u8, val, "auto-hide") or std.mem.eql(u8, val, "autohide") or std.mem.eql(u8, val, "auto_hide")) {
        return .auto_hide;
    }
    if (std.mem.eql(u8, val, "pinned") or std.mem.eql(u8, val, "pinned-overlay") or std.mem.eql(u8, val, "overlay")) {
        return .pinned_overlay;
    }
    if (std.mem.eql(u8, val, "dock") or std.mem.eql(u8, val, "docked") or std.mem.eql(u8, val, "strut")) {
        return .docked_strut;
    }
    return null;
}

fn parseBackendValue(val: []const u8) ?BackendPreference {
    if (std.mem.eql(u8, val, "auto")) return .auto;
    if (std.mem.eql(u8, val, "wayland") or std.mem.eql(u8, val, "wl") or std.mem.eql(u8, val, "shm") or std.mem.eql(u8, val, "wayland-shm")) return .wayland;
    if (std.mem.eql(u8, val, "wayland-egl") or std.mem.eql(u8, val, "wl-egl") or std.mem.eql(u8, val, "egl")) return .wayland_egl;
    if (std.mem.eql(u8, val, "x11") or std.mem.eql(u8, val, "xorg") or std.mem.eql(u8, val, "xshm") or std.mem.eql(u8, val, "x11-shm")) return .x11;
    if (std.mem.eql(u8, val, "x11-glx") or std.mem.eql(u8, val, "glx")) return .x11_glx;
    return null;
}

fn writeFd(fd: c_int, msg: []const u8) void {
    _ = c.write(fd, msg.ptr, msg.len);
}

fn parseCli(args: std.process.Args) !CliConfig {
    var cfg: CliConfig = .{};
    var it = std.process.Args.Iterator.init(args);
    _ = it.next(); // program name

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            writeFd(1, usage_text);
            cfg.exit_early = true;
            return cfg;
        } else if (std.mem.startsWith(u8, arg, "--mode=")) {
            cfg.mode = parseModeValue(arg["--mode=".len..]) orelse {
                writeFd(2, "zigbar: invalid --mode (expected auto-hide, pinned, or dock)\n");
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--mode")) {
            const val = it.next() orelse {
                writeFd(2, "zigbar: missing value for --mode\n");
                return error.InvalidArgument;
            };
            cfg.mode = parseModeValue(val) orelse {
                writeFd(2, "zigbar: invalid --mode (expected auto-hide, pinned, or dock)\n");
                return error.InvalidArgument;
            };
        } else if (std.mem.startsWith(u8, arg, "--backend=")) {
            cfg.backend = parseBackendValue(arg["--backend=".len..]) orelse {
                writeFd(2, "zigbar: invalid --backend (expected auto, wayland, wayland-egl, x11, or x11-glx)\n");
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--backend")) {
            const val = it.next() orelse {
                writeFd(2, "zigbar: missing value for --backend\n");
                return error.InvalidArgument;
            };
            cfg.backend = parseBackendValue(val) orelse {
                writeFd(2, "zigbar: invalid --backend (expected auto, wayland, wayland-egl, x11, or x11-glx)\n");
                return error.InvalidArgument;
            };
        } else if (std.mem.startsWith(u8, arg, "--output=")) {
            if (!cfg.setOutput(arg["--output=".len..])) {
                writeFd(2, "zigbar: invalid --output (expected non-empty connector name <= 64 chars)\n");
                return error.InvalidArgument;
            }
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            const val = it.next() orelse {
                writeFd(2, "zigbar: missing value for --output\n");
                return error.InvalidArgument;
            };
            if (!cfg.setOutput(val)) {
                writeFd(2, "zigbar: invalid --output (expected non-empty connector name <= 64 chars)\n");
                return error.InvalidArgument;
            }
        } else if (std.mem.startsWith(u8, arg, "--hz=")) {
            const hz = std.fmt.parseInt(u8, arg["--hz=".len..], 10) catch 0;
            if (hz < 1 or hz > StatusMonitor.max_sample_hz) {
                writeFd(2, "zigbar: invalid --hz (expected 1..60)\n");
                return error.InvalidArgument;
            }
            cfg.sample_hz = hz;
        } else {
            writeFd(2, "zigbar: unrecognized option (try --help)\n");
            return error.InvalidArgument;
        }
    }
    return cfg;
}

pub fn main(init: std.process.Init.Minimal) !void {
    const cli = try parseCli(init.args);
    if (cli.exit_early) return;

    var sig_pipe: [2]c_int = .{ -1, -1 };
    if (c.pipe2(&sig_pipe, c.O_CLOEXEC | c.O_NONBLOCK) == 0) {
        sig_wake_write_fd.store(sig_pipe[1], .release);
    }
    defer {
        sig_wake_write_fd.store(-1, .release);
        if (sig_pipe[0] >= 0) _ = c.close(sig_pipe[0]);
        if (sig_pipe[1] >= 0) _ = c.close(sig_pipe[1]);
    }

    var sa: c.struct_sigaction = std.mem.zeroes(c.struct_sigaction);
    sa.__sigaction_handler.sa_handler = onSignal;
    _ = c.sigaction(c.SIGINT, &sa, null);
    _ = c.sigaction(c.SIGTERM, &sa, null);
    _ = c.sigaction(c.SIGUSR1, &sa, null);
    _ = c.sigaction(c.SIGUSR2, &sa, null);

    // Automatically reap detached child apps spawned via left-click (`btop`, `dolphin`, etc.)
    var sa_chld: c.struct_sigaction = std.mem.zeroes(c.struct_sigaction);
    sa_chld.sa_flags = c.SA_NOCLDWAIT | c.SA_NOCLDSTOP;
    _ = c.sigaction(c.SIGCHLD, &sa_chld, null);

    var single_threaded_io: std.Io.Threaded = .init_single_threaded;
    const io = single_threaded_io.io();

    var window = Window{
        .backend_preference = cli.backend,
        .docked = true,
        .strut_enabled = (cli.mode == .docked_strut),
        .input_height = if (cli.mode == .auto_hide) 1 else 14 + 3,
        .wakeup_fd = sig_pipe[0],
    };
    window.setTargetOutput(cli.outputSlice());

    // width = 0 auto-detects the active output width; height = 14 + 3 = 17px
    try window.init(0, 0, 0, 14 + 3);
    defer window.deinit();

    var monitor: StatusMonitor = .{ .window = &window };
    try monitor.init(io, cli.sample_hz, cli.mode);
    defer monitor.deinit();

    while (window.running and !stop_requested.load(.acquire)) {
        if (sig_usr1_pending.swap(false, .acq_rel)) {
            monitor.togglePinnedOverlay();
        }
        if (sig_usr2_pending.swap(false, .acq_rel)) {
            monitor.toggleDockedStrut();
        }
        try monitor.step();
    }
}

test {
    _ = @import("formats.zig");
    _ = @import("Actions.zig");
    _ = @import("Segment.zig");
    _ = @import("FontAtlas.zig");
    _ = @import("ShmDraw.zig");
    _ = @import("metrics.zig");
    _ = @import("WaylandBackend.zig");
    _ = @import("X11Backend.zig");
}

test "CliConfig.setOutput validates bounds and non-empty connector names" {
    var cfg: CliConfig = .{};
    try std.testing.expectEqual(@as(usize, 0), cfg.outputSlice().len);
    try std.testing.expect(!cfg.setOutput(""));
    try std.testing.expect(cfg.setOutput("eDP-1"));
    try std.testing.expectEqualStrings("eDP-1", cfg.outputSlice());
    const too_long: [65]u8 = @splat('a');
    try std.testing.expect(!cfg.setOutput(&too_long));
    // Previous valid output remains intact on rejected overwrite
    try std.testing.expectEqualStrings("eDP-1", cfg.outputSlice());
    try std.testing.expectEqual(@as(?BackendPreference, .x11), parseBackendValue("x11"));
    try std.testing.expectEqual(@as(?BackendPreference, .x11), parseBackendValue("xshm"));
    try std.testing.expectEqual(@as(?BackendPreference, .x11_glx), parseBackendValue("x11-glx"));
    try std.testing.expectEqual(@as(?BackendPreference, .x11_glx), parseBackendValue("glx"));
}
