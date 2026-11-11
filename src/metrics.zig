const std = @import("std");
const Io = std.Io;
const mem = std.mem;

const x11 = @import("Window.zig").c;

const c = @import("c");

const nanoTimestamp = @import("Ticker.zig").nanoTimestamp;
const formats = @import("formats.zig");

// --- Data Structures ---

pub const IoStat = struct {
    read: u64 = 0,
    write: u64 = 0,

    pub fn diff(self: IoStat, prev: IoStat) IoStat {
        return .{
            .read = self.read -% prev.read,
            .write = self.write -% prev.write,
        };
    }
};

pub const NetStat = struct {
    rx: u64 = 0,
    tx: u64 = 0,

    pub fn diff(self: NetStat, prev: NetStat) NetStat {
        return .{
            .rx = self.rx -% prev.rx,
            .tx = self.tx -% prev.tx,
        };
    }
};

pub const MetricTag = enum {
    cpu,
    memory,
    io,
    net,
    temp,
    load,
    window,
    free_storage,
    time,
};

pub const Metric = union(MetricTag) {
    cpu: CpuProbe,
    memory: MemProbe,
    io: IoProbe,
    net: NetProbe,
    temp: TempProbe,
    load: LoadProbe,
    window: WindowNameProbe,
    free_storage: StorageProbe,
    time: TimeProbe,

    pub fn sample(self: *Metric, io: Io) !void {
        return switch (self.*) {
            .cpu => |*p| p.sample(io),
            .memory => |*p| p.sample(io),
            .io => |*p| p.sample(io),
            .net => |*p| p.sample(io),
            .temp => |*p| p.sample(io),
            .load => |*p| p.sample(),
            .window => |*p| p.sample(),
            .free_storage => |*p| p.sample(io),
            .time => |*p| p.sample(io),
        };
    }

    pub fn deinit(self: *Metric, io: Io) void {
        switch (self.*) {
            .cpu => |*p| p.deinit(io),
            .memory => |*p| p.deinit(io),
            .io => |*p| p.deinit(io),
            .net => |*p| p.deinit(io),
            .temp => |*p| p.deinit(io),
            .free_storage => |*p| p.deinit(io),
            .load, .window, .time => {},
        }
    }

    pub fn get(self: *Metric, idx: u8) u64 {
        return switch (self.*) {
            .cpu => |*p| p.current_pct,
            .temp => |*p| p.value,
            .load => |*p| p.value,
            .free_storage => |*p| p.free_bytes,

            .memory => |*p| if (idx == 0) p.free else p.dirty,
            .io => |*p| if (idx == 0) p.current.read else p.current.write,
            .net => |*p| if (idx == 0) p.current.rx else p.current.tx,

            .window => 0,
            .time => 0,
        };
    }

    pub fn print(self: *Metric, value: u64, idx: u8) MetricString {
        var result = MetricString{ .buf = undefined, .len = 0 };

        // A small helper to copy the fixed arrays into our return struct
        const write = struct {
            fn do(out: *MetricString, src: anytype) void {
                @memcpy(out.buf[0..src.len], src[0..]);
                out.len = src.len;
            }
        }.do;

        switch (self.*) {
            .cpu => write(&result, formats.cpuUsage(value)),
            .temp => {
                const x = formats.none(value);
                write(&result, x.buf[0..x.len]);
            },
            .load => write(&result, formats.systemLoad(value)),
            .free_storage => write(&result, formats.freeSpace(value)),

            .memory => if (idx == 0) {
                const m = formats.memory(value);
                write(&result, m.slice());
            } else write(&result, formats.generic(value)),
            .io => write(&result, formats.generic(value)),
            .net => write(&result, formats.generic(value)),

            else => unreachable,
        }

        return result;
    }
};

// Define a small container for the output
pub const MetricString = struct {
    buf: [24]u8, // Set this to your maximum possible metric string length
    len: usize,

    // Helper to easily view it as a standard slice
    pub fn slice(self: *const MetricString) []const u8 {
        return self.buf[0..self.len];
    }
};

// --- Implementation Probes ---

fn preadOnce(file: Io.File, io: Io, buf: []u8) !usize {
    const bufs: [1][]u8 = .{buf};
    return file.readPositional(io, &bufs, 0);
}

fn ensureOpen(slot: *?Io.File, io: Io, path: []const u8) !Io.File {
    if (slot.*) |f| return f;
    const f = try Io.Dir.openFileAbsolute(io, path, .{});
    slot.* = f;
    return f;
}

fn closeSlot(slot: *?Io.File, io: Io) void {
    if (slot.*) |f| {
        f.close(io);
        slot.* = null;
    }
}

pub const CpuProbe = struct {
    file: ?Io.File = null,
    prev_idle: u64 = 0,
    prev_total: u64 = 0,
    current_pct: u64 = 0,
    primed: bool = false,

    pub fn deinit(self: *CpuProbe, io: Io) void {
        closeSlot(&self.file, io);
    }

    pub fn sample(self: *CpuProbe, io: Io) !void {
        const file = try ensureOpen(&self.file, io, "/proc/stat");

        var buf: [128]u8 = undefined;
        const amt = try preadOnce(file, io, &buf);

        var it = mem.tokenizeAny(u8, buf[0..amt], " \n");
        _ = it.next(); // skip "cpu"

        var total: u64 = 0;
        var idle: u64 = 0;
        var i: usize = 0;
        while (it.next()) |token| : (i += 1) {
            if (i >= 10) break;
            const val = std.fmt.parseInt(u64, token, 10) catch 0;
            total += val;
            if (i == 3) idle = val;
        }

        if (!self.primed) {
            self.prev_idle = idle;
            self.prev_total = total;
            self.current_pct = 0;
            self.primed = true;
            return;
        }

        const diff_idle = idle -% self.prev_idle;
        const diff_total = total -% self.prev_total;
        self.prev_idle = idle;
        self.prev_total = total;

        self.current_pct = if (diff_total == 0) 0 else 100 - (100 * diff_idle / diff_total);
    }
};

pub const MemProbe = struct {
    file: ?Io.File = null,
    free: u64 = 0,
    dirty: u64 = 0,

    pub fn deinit(self: *MemProbe, io: Io) void {
        closeSlot(&self.file, io);
    }

    pub fn sample(self: *MemProbe, io: Io) !void {
        const file = try ensureOpen(&self.file, io, "/proc/meminfo");

        var buf: [2048]u8 = undefined;
        const amt = try preadOnce(file, io, &buf);

        var found_free = false;
        var found_dirty = false;

        var line_it = mem.tokenizeAny(u8, buf[0..amt], "\n");
        while (line_it.next()) |line| {
            var col_it = mem.tokenizeAny(u8, line, " :kbKB");
            const label = col_it.next() orelse continue;
            const val_str = col_it.next() orelse continue;
            const val = std.fmt.parseInt(u64, val_str, 10) catch 0;

            if (mem.eql(u8, label, "MemFree")) {
                self.free = val >> 10; // Convert KB to MB
                found_free = true;
            } else if (mem.eql(u8, label, "Dirty")) {
                self.dirty = val << 10; // Convert KB to bytes for generic formatter
                found_dirty = true;
            }

            if (found_free and found_dirty)
                break;
        }
    }
};

pub const IoProbe = struct {
    file: ?Io.File = null,
    prev: IoStat = .{},
    current: IoStat = .{},
    primed: bool = false,

    pub fn deinit(self: *IoProbe, io: Io) void {
        closeSlot(&self.file, io);
    }

    pub fn sample(self: *IoProbe, io: Io) !void {
        const file = try ensureOpen(&self.file, io, "/proc/diskstats");

        var buf: [4096]u8 = undefined;
        const amt = try preadOnce(file, io, &buf);

        var raw = IoStat{};

        var line_it = mem.tokenizeAny(u8, buf[0..amt], "\n");
        while (line_it.next()) |line| {
            var it = mem.tokenizeAny(u8, line, " ");
            _ = it.next(); // major
            _ = it.next(); // minor
            const dev = it.next() orelse "";

            const is_valid_dev =
                mem.startsWith(u8, dev, "nvme") // NVMe
                or mem.startsWith(u8, dev, "sd") // SATA/SCSI
                or mem.startsWith(u8, dev, "mmcblk") // SD Cards/eMMC
                // or mem.startsWith(u8, dev, "vd")  // VirtIO (VMs)
                or mem.startsWith(u8, dev, "sr") // CD/DVD
                or mem.startsWith(u8, dev, "fd") // Floppy
                or mem.startsWith(u8, dev, "hd"); // IDE Disks

            if (!is_valid_dev)
                continue;

            // Skip if it's an NVMe/MMC partition (contains 'p' before the end)
            if (dev.len > 2 and dev[dev.len - 2] == 'p')
                continue;

            // Skip if it's an SD/HD/VD partition (e.g., sda1 is len 4, sda is len 3)
            if ((mem.startsWith(u8, dev, "sd") or mem.startsWith(u8, dev, "hd")) and dev.len > 3)
                continue;

            var i: usize = 0;
            while (it.next()) |token| : (i += 1) {
                if (i == 3) raw.read += try std.fmt.parseInt(u64, token, 10);
                if (i == 7) {
                    raw.write += try std.fmt.parseInt(u64, token, 10);
                    break;
                }
            }
        }
        if (!self.primed) {
            self.prev = raw;
            self.current = .{};
            self.primed = true;
            return;
        }
        self.current = raw.diff(self.prev);
        // Apply 512 byte sector shift
        self.current.read <<= 9;
        self.current.write <<= 9;
        self.prev = raw;
    }
};

pub const NetProbe = struct {
    file: ?Io.File = null,
    prev: NetStat = .{},
    current: NetStat = .{},
    primed: bool = false,

    pub fn deinit(self: *NetProbe, io: Io) void {
        closeSlot(&self.file, io);
    }

    pub fn sample(self: *NetProbe, io: Io) !void {
        const file = try ensureOpen(&self.file, io, "/proc/net/dev");

        var buf: [2048]u8 = undefined;
        const amt = try preadOnce(file, io, &buf);

        var raw = NetStat{};
        var line_it = mem.tokenizeAny(u8, buf[0..amt], "\n");
        while (line_it.next()) |line| {
            const colon = mem.indexOfScalar(u8, line, ':') orelse continue;
            const iface = mem.trim(u8, line[0..colon], " \t");
            if (!(mem.startsWith(u8, iface, "en") or mem.startsWith(u8, iface, "eth") or mem.startsWith(u8, iface, "wl"))) {
                continue;
            }

            var fields = mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
            var col: usize = 0;
            while (fields.next()) |tok| : (col += 1) {
                if (col == 0) {
                    raw.rx += std.fmt.parseInt(u64, tok, 10) catch 0;
                } else if (col == 8) {
                    raw.tx += std.fmt.parseInt(u64, tok, 10) catch 0;
                    break;
                }
            }
        }

        if (!self.primed) {
            self.prev = raw;
            self.current = .{};
            self.primed = true;
            return;
        }
        self.current = raw.diff(self.prev);
        self.prev = raw;
    }
};

pub const TempProbe = struct {
    file: ?Io.File = null,
    searched: bool = false,
    value: u64 = 0,

    pub fn deinit(self: *TempProbe, io: Io) void {
        closeSlot(&self.file, io);
    }

    fn discoverSensor(self: *TempProbe, io: Io) !void {
        self.searched = true;
        var path_buf: [96]u8 = undefined;
        var name_buf: [64]u8 = undefined;

        var dir = try Io.Dir.openDirAbsolute(io, "/sys/class/hwmon", .{ .iterate = true });
        defer dir.close(io);

        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            const name_path = std.fmt.bufPrint(&path_buf, "/sys/class/hwmon/{s}/name", .{entry.name}) catch continue;
            const name_file = Io.Dir.openFileAbsolute(io, name_path, .{}) catch continue;
            defer name_file.close(io);

            const len = preadOnce(name_file, io, &name_buf) catch continue;
            const driver_name = mem.trim(u8, name_buf[0..len], " \n");

            // k10temp/zenpower is AMD, coretemp is Intel
            if (mem.eql(u8, driver_name, "k10temp") or mem.eql(u8, driver_name, "zenpower") or mem.eql(u8, driver_name, "coretemp")) {
                const temp_path = std.fmt.bufPrint(&path_buf, "/sys/class/hwmon/{s}/temp1_input", .{entry.name}) catch continue;
                self.file = Io.Dir.openFileAbsolute(io, temp_path, .{}) catch null;
                return;
            }
        }
    }

    pub fn sample(self: *TempProbe, io: Io) !void {
        if (!self.searched) {
            try self.discoverSensor(io);
        }
        const temp_file = self.file orelse return;

        var buf: [32]u8 = undefined;
        const amt = try preadOnce(temp_file, io, &buf);
        self.value = (std.fmt.parseInt(u64, mem.trim(u8, buf[0..amt], " \n"), 10) catch 0) / 1000;
    }
};

pub const LoadProbe = struct {
    value: u64 = 0,
    pub fn sample(self: *LoadProbe) !void {
        var info: std.os.linux.Sysinfo = undefined;
        if (std.os.linux.sysinfo(&info) == 0) {
            self.value = info.loads[0] / ((@as(u64, 1) << 16) / 100);
        }
    }
};

pub const StorageProbe = struct {
    file: ?Io.File = null,
    last_sample_ns: i96 = 0,
    free_bytes: u64 = 0,

    const refresh_interval_ns: i96 = 5 * std.time.ns_per_s;

    pub fn deinit(self: *StorageProbe, io: Io) void {
        closeSlot(&self.file, io);
    }

    pub fn sample(self: *StorageProbe, io: Io) !void {
        const now = nanoTimestamp(io);
        if (self.last_sample_ns != 0 and now - self.last_sample_ns < refresh_interval_ns) {
            return;
        }
        self.last_sample_ns = now;

        const file = try ensureOpen(&self.file, io, "/proc/mounts");

        // Fixed-size buffer to track seen devices without heap allocation
        var seen_storage: [16][64]u8 = undefined;
        var seen_count: usize = 0;

        var total_free: u64 = 0;
        var buf: [4096]u8 = undefined;
        const amt = try preadOnce(file, io, &buf);

        var line_it = mem.tokenizeAny(u8, buf[0..amt], "\n");
        while (line_it.next()) |line| {
            var col_it = mem.tokenizeAny(u8, line, " ");
            const dev_name = col_it.next() orelse continue;
            const mnt_dir = col_it.next() orelse continue;

            const is_storage = mem.startsWith(u8, dev_name, "/dev/sd") or
                mem.startsWith(u8, dev_name, "/dev/nvme") or
                mem.startsWith(u8, dev_name, "/dev/mmcblk");

            if (is_storage) {
                // Check if we've seen this device name before
                var already_seen = false;
                for (seen_storage[0..seen_count]) |seen_name| {
                    if (mem.eql(u8, dev_name, mem.sliceTo(&seen_name, 0))) {
                        already_seen = true;
                        break;
                    }
                }

                if (!already_seen and seen_count < seen_storage.len) {
                    var stat: c.struct_statvfs = undefined;

                    // statvfs needs a null-terminated string.
                    // We can use a small stack buffer for the path.
                    var path_buf: [256]u8 = undefined;
                    if (mnt_dir.len < path_buf.len - 1) {
                        @memcpy(path_buf[0..mnt_dir.len], mnt_dir);
                        path_buf[mnt_dir.len] = 0;

                        if (c.statvfs(&path_buf, &stat) == 0) {
                            total_free += stat.f_bavail * stat.f_bsize;

                            // Save device name to seen list
                            const name_len = @min(dev_name.len, 63);
                            @memcpy(seen_storage[seen_count][0..name_len], dev_name[0..name_len]);
                            seen_storage[seen_count][name_len] = 0;
                            seen_count += 1;
                        }
                    }
                }
            }
        }
        self.free_bytes = total_free;
    }
};

pub const TimeProbe = struct {
    value: [21]u8 = @splat(' '),
    last_sec: u64 = std.math.maxInt(u64),
    changed: bool = true,

    // UTC+3 for bahrain time :)
    const offset = 3 * std.time.ns_per_hour;
    const days = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

    /// Formats the date into the provided buffer: "Fri May08 02:48:01 PM"
    pub fn sample(self: *TimeProbe, io: std.Io) !void {
        const ts = nanoTimestamp(io) + offset;
        const seconds: u64 = @intCast(@divTrunc(ts, std.time.ns_per_s));
        if (seconds == self.last_sec) return;
        self.last_sec = seconds;

        const epoch = std.time.epoch.EpochSeconds{ .secs = seconds };
        const day_secs = epoch.getDaySeconds();
        const epoch_day = epoch.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();

        // Calculate 12-hour clock
        var hour = day_secs.getHoursIntoDay();
        const am_pm = if (hour >= 12) "PM" else "AM";
        hour = if (hour == 0) 12 else if (hour > 12) hour - 12 else hour;

        // Calculate Day of Week (EpochDay 0 = Thursday = index 4)
        const day_of_week_index = (epoch_day.day + 4) % 7;

        _ = try std.fmt.bufPrint(&self.value, "{s} {s}{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} {s}", .{
            days[day_of_week_index],
            months[@intCast(month_day.month.numeric() - 1)],
            month_day.day_index + 1,
            hour,
            day_secs.getMinutesIntoHour(),
            day_secs.getSecondsIntoMinute(),
            am_pm,
        });
        self.changed = true;
    }
};

pub const WindowNameProbe = struct {
    display: ?*x11.Display = null,
    root: x11.Window = 0,
    self_window: x11.Window = 0,
    tracked_window: x11.Window = 0,
    net_active_atom: x11.Atom = 0,
    net_name_atom: x11.Atom = 0,
    wm_name_atom: x11.Atom = 0,
    dirty: bool = true,
    current_name: [256]u8 = @splat(0),
    name_len: usize = 0,
    changed: bool = true,

    pub fn attach(
        self: *WindowNameProbe,
        display: ?*x11.Display,
        root: x11.Window,
        self_window: x11.Window,
        net_active_atom: x11.Atom,
        net_name_atom: x11.Atom,
        wm_name_atom: x11.Atom,
    ) void {
        self.display = display;
        self.root = root;
        self.self_window = self_window;
        self.net_active_atom = net_active_atom;
        self.net_name_atom = net_name_atom;
        self.wm_name_atom = wm_name_atom;
        self.dirty = true;
        _ = x11.XSetErrorHandler(xErrorHandler);
    }

    pub fn markDirty(self: *WindowNameProbe) void {
        self.dirty = true;
    }

    pub fn slice(self: *const WindowNameProbe) []const u8 {
        return self.current_name[0..self.name_len];
    }

    // Event-driven active window query: executes X11 roundtrips only when marked dirty via PropertyNotify
    pub fn sample(self: *WindowNameProbe) void {
        if (!self.dirty) return;
        const display = self.display orelse return;
        if (self.root == 0) return;
        self.dirty = false;

        var actual_type: x11.Atom = 0;
        var actual_format: i32 = 0;
        var nitems: u64 = 0;
        var bytes_after: u64 = 0;
        var prop: [*c]u8 = null;

        var next_buf: [256]u8 = @splat(0);
        var next_len: usize = 0;

        // 1. Get the Active Window ID
        if (x11.XGetWindowProperty(display, self.root, self.net_active_atom, 0, ~@as(i64, 0), x11.False, x11.AnyPropertyType, &actual_type, &actual_format, &nitems, &bytes_after, &prop) == x11.Success) {
            if (prop != null and nitems > 0) {
                const window_id = @as(*x11.Window, @ptrCast(@alignCast(prop))).*;
                _ = x11.XFree(prop);
                prop = null;

                if (window_id != self.tracked_window) {
                    if (self.tracked_window != 0 and self.tracked_window != self.self_window and self.tracked_window != self.root) {
                        _ = x11.XSelectInput(display, self.tracked_window, x11.NoEventMask);
                    }
                    self.tracked_window = window_id;
                    if (window_id != 0 and window_id != self.self_window and window_id != self.root) {
                        _ = x11.XSelectInput(display, window_id, x11.PropertyChangeMask);
                    }
                    _ = x11.XFlush(display);
                }

                if (window_id != 0) {
                    // 2. Get _NET_WM_NAME, falling back to WM_NAME
                    if (x11.XGetWindowProperty(display, window_id, self.net_name_atom, 0, ~@as(i64, 0), x11.False, x11.AnyPropertyType, &actual_type, &actual_format, &nitems, &bytes_after, &prop) == x11.Success and prop != null and nitems > 0) {
                        next_len = sanitizeName(prop[0..@min(nitems, 255)], &next_buf);
                        _ = x11.XFree(prop);
                    } else {
                        if (prop != null) _ = x11.XFree(prop);
                        prop = null;
                        if (x11.XGetWindowProperty(display, window_id, self.wm_name_atom, 0, ~@as(i64, 0), x11.False, x11.AnyPropertyType, &actual_type, &actual_format, &nitems, &bytes_after, &prop) == x11.Success and prop != null and nitems > 0) {
                            next_len = sanitizeName(prop[0..@min(nitems, 255)], &next_buf);
                            _ = x11.XFree(prop);
                        } else if (prop != null) {
                            _ = x11.XFree(prop);
                        }
                    }
                }
            } else if (prop != null) {
                _ = x11.XFree(prop);
            }
        }

        if (!mem.eql(u8, self.current_name[0..self.name_len], next_buf[0..next_len])) {
            self.current_name = next_buf;
            self.name_len = next_len;
            self.changed = true;
        }
    }

    fn xErrorHandler(_: ?*x11.Display, _: ?*x11.XErrorEvent) callconv(.c) i32 {
        return 0; // Equivalent to your ignoreErrors
    }

    fn sanitizeName(src: []u8, dest: *[256]u8) usize {
        var j: usize = 0;
        for (src) |char| {
            if (char != '\n' and char != '\r') { // From your sanitizeName logic
                dest[j] = char;
                j += 1;
            }
            if (j >= 255) break;
        }
        return j;
    }
};

test "System probes sample without errors" {
    var cpu: CpuProbe = .{};
    defer cpu.deinit(std.testing.io);
    try cpu.sample(std.testing.io);
    try cpu.sample(std.testing.io);
    try std.testing.expect(cpu.current_pct <= 100);

    var mem_probe: MemProbe = .{};
    defer mem_probe.deinit(std.testing.io);
    try mem_probe.sample(std.testing.io);
    try std.testing.expect(mem_probe.free > 0);

    var io_probe: IoProbe = .{};
    defer io_probe.deinit(std.testing.io);
    try io_probe.sample(std.testing.io);
    try io_probe.sample(std.testing.io);

    var net_probe: NetProbe = .{};
    defer net_probe.deinit(std.testing.io);
    try net_probe.sample(std.testing.io);
    try net_probe.sample(std.testing.io);

    var temp_probe: TempProbe = .{};
    defer temp_probe.deinit(std.testing.io);
    try temp_probe.sample(std.testing.io);

    var stor_probe: StorageProbe = .{};
    defer stor_probe.deinit(std.testing.io);
    try stor_probe.sample(std.testing.io);
    try std.testing.expect(stor_probe.free_bytes > 0);

    var load_probe: LoadProbe = .{};
    try load_probe.sample();

    var time_probe: TimeProbe = .{};
    try time_probe.sample(std.testing.io);
    try std.testing.expect(time_probe.changed);
    try std.testing.expectEqual(@as(usize, 21), time_probe.value.len);
}
