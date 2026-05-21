const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const print = std.debug.print;

const x11 = @import("Window.zig").c;

const c = @cImport({
    // @cInclude("sys/stat.h");
    @cInclude("sys/statvfs.h");
});

const nanoTimestamp = @import("Ticker.zig").nanoTimestamp;

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
};

// --- Implementation Probes ---

pub const CpuProbe = struct {
    prev_idle: u64 = 0,
    prev_total: u64 = 0,
    current_pct: u64 = 0,

    pub fn sample(self: *CpuProbe, io: Io) !void {
        const file = try Io.Dir.openFileAbsolute(io, "/proc/stat", .{});
        defer file.close(io);

        var buf: [128]u8 = undefined;
        const amt = try file.readPositionalAll(io, &buf, 0);

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

        const diff_idle = idle -% self.prev_idle;
        const diff_total = total -% self.prev_total;
        self.prev_idle = idle;
        self.prev_total = total;

        self.current_pct = if (diff_total == 0) 0 else 100 - (100 * diff_idle / diff_total);
    }
};

pub const MemProbe = struct {
    free: u64 = 0,
    dirty: u64 = 0,

    pub fn sample(self: *MemProbe, io: Io) !void {
        const file = try Io.Dir.openFileAbsolute(io, "/proc/meminfo", .{});
        defer file.close(io);

        var buf: [2048]u8 = undefined;
        const amt = try file.readPositionalAll(io, &buf, 0);

        var line_it = mem.tokenizeAny(u8, buf[0..amt], "\n");
        while (line_it.next()) |line| {
            var col_it = mem.tokenizeAny(u8, line, " :kbKB");
            const label = col_it.next() orelse continue;
            const val_str = col_it.next() orelse continue;
            const val = std.fmt.parseInt(u64, val_str, 10) catch 0;

            if (mem.eql(u8, label, "MemFree")) {
                self.free = val >> 10; // Convert KB to MB
            } else if (mem.eql(u8, label, "Dirty")) {
                self.dirty = val >> 10;
            }

            if (self.free != 0 and self.dirty != 0)
                break;
        }
    }
};

pub const IoProbe = struct {
    prev: IoStat = .{},
    current: IoStat = .{},

    pub fn sample(self: *IoProbe, io: Io) !void {
        const file = try Io.Dir.openFileAbsolute(io, "/proc/diskstats", .{});
        defer file.close(io);

        var buf: [2048]u8 = undefined;
        const amt = try file.readPositionalAll(io, &buf, 0);

        var raw = IoStat{};

        var line_it = mem.tokenizeAny(u8, buf[0..amt], "\n");
        while (line_it.next()) |line| {

            // print("{s:<120} | {d} B\n", .{line,  line.len});

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
        self.current = raw.diff(self.prev);
        // Apply 512 byte sector shift from source[cite: 1]
        self.current.read <<= 9;
        self.current.write <<= 9;
        self.prev = raw;
    }
};

pub const NetProbe = struct {
    prev: NetStat = .{},
    current: NetStat = .{},

    const network_class = "/sys/class/net";

    pub fn sample(self: *NetProbe, io: Io) !void {
        var raw = NetStat{};

        const dir = try Io.Dir.openDirAbsolute(io, network_class, .{ .iterate = true });
        defer dir.close(io);

        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            if (entry.kind == .directory or entry.kind == .sym_link) {
                if (std.mem.startsWith(u8, entry.name, "enp") or std.mem.startsWith(u8, entry.name, "eth") or std.mem.startsWith(u8, entry.name, "wlan")) {
                    raw.rx += try readSysfsUint(io, entry.name, "rx_bytes");
                    raw.tx += try readSysfsUint(io, entry.name, "tx_bytes");
                }
            }
        }

        self.current = raw.diff(self.prev);
        self.prev = raw;
    }

    fn readSysfsUint(io: Io, network_name: []const u8, comptime stat_name: []const u8) !u64 {
        var buf: [64]u8 = undefined;

        // /sys/class/net/{name}/statistics/tx_bytes
        const path = std.fmt.bufPrint(&buf, "{s}/{s}/statistics/{s}", .{ network_class, network_name, stat_name }) catch |err| {
            std.log.warn("error: {any} Interface name '{s}' is too long for buffer", .{ err, network_name });
            return 0;
        };

        const file = Io.Dir.openFileAbsolute(io, path, .{}) catch return 0;
        defer file.close(io);
        const amt = try file.readPositionalAll(io, &buf, 0);
        return std.fmt.parseInt(u64, mem.trim(u8, buf[0..amt], " \n"), 10) catch 0;
    }
};

pub const TempProbe = struct {
    value: u64 = 0,
    pub fn sample(self: *TempProbe, io: Io) !void {
        var buf: [64]u8 = undefined;
        var dir = try Io.Dir.openDirAbsolute(io, "/sys/class/hwmon", .{ .iterate = true });
        defer dir.close(io);

        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            const path = try std.fmt.bufPrint(&buf, "/sys/class/hwmon/{s}/name", .{entry.name});

            const file = Io.Dir.openFileAbsolute(io, path, .{}) catch continue;
            defer file.close(io);
            const len = try file.readPositionalAll(io, &buf, 0);
            const driver_name = std.mem.trim(u8, buf[0..len], " \n");

            // k10temp is AMD, coretemp is Intel
            if (std.mem.eql(u8, driver_name, "k10temp") or std.mem.eql(u8, driver_name, "coretemp")) {
                // Use this hwmonX directory!
                const file_path = try std.fmt.bufPrint(&buf, "/sys/class/hwmon/{s}/temp1_input", .{entry.name});

                const temp_file = Io.Dir.openFileAbsolute(io, file_path, .{}) catch return;
                defer temp_file.close(io);
                const amt = try temp_file.readPositionalAll(io, &buf, 0);
                self.value = (std.fmt.parseInt(u64, mem.trim(u8, buf[0..amt], " \n"), 10) catch 0) / 1000;
            }
        }
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
    free_bytes: u64 = 0,

    pub fn sample(self: *StorageProbe, io: Io) !void {
        const file = try Io.Dir.openFileAbsolute(io, "/proc/mounts", .{});
        defer file.close(io);

        // Fixed-size buffer to track seen devices without heap allocation
        var seen_storage: [16][64]u8 = undefined;
        var seen_count: usize = 0;

        var total_free: u64 = 0;
        var buf: [4096]u8 = undefined;
        const amt = try file.readPositionalAll(io, &buf, 0);

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
                    var stat: c.struct_statvfs  = undefined;

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
    value: [21]u8 = undefined,

    // UTC+3 for bahrain time :)
    const offset = 60 * 60 * 3;
    const days = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

    /// Formats the date into the provided buffer: "Fri May08 02:48:01 PM"
    pub fn sample(self: *TimeProbe, io: std.Io) !void {
        const ts = nanoTimestamp(io) + offset;
        const seconds: u64 = @intCast(@divTrunc(ts, std.time.ns_per_day));

        const epoch = std.time.epoch.EpochSeconds{ .secs = seconds };
        const day_secs = epoch.getDaySeconds();
        const epoch_day = epoch.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();

        // Calculate 12-hour clock
        var hour = day_secs.getHoursIntoDay();
        const am_pm = if (hour >= 12) "PM" else "AM";
        hour = if (hour == 0) 12 else if (hour > 12) hour - 12 else hour;

        // Calculate Day of Week
        // EpochDay 0 was a Thursday.
        const day_of_week_index = epoch_day.day % 7;

        _ = try std.fmt.bufPrint(&self.value, "{s} {s}{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} {s}", .{
            days[day_of_week_index],
            months[@intCast(month_day.month.numeric() - 1)],
            month_day.day_index + 1,
            hour,
            day_secs.getMinutesIntoHour(),
            day_secs.getSecondsIntoMinute(),
            am_pm,
        });

        // print("{s}\n", .{self.value});
    }
};

pub const WindowNameProbe = struct {
    display: ?*x11.Display = null,
    root: x11.Window = 0,
    current_name: [256]u8 = [_]u8{0} ** 256,
    name_len: usize = 0,

    pub fn init(self: *WindowNameProbe) !void {
        self.display = x11.XOpenDisplay(null) orelse return error.XOpenDisplayFailed;
        const screen = x11.DefaultScreen(self.display);
        self.root = x11.XRootWindow(self.display, screen);
        _ = x11.XSetErrorHandler(xErrorHandler);
    }

    pub fn deinit(self: *WindowNameProbe) void {
        if (self.display) |d| _ = x11.XCloseDisplay(d);
    }

    // This replaces your getActiveWindow loop logic
    pub fn sample(self: *WindowNameProbe) void {
        const display = self.display orelse return;
        if (self.root == 0) return;

        var actual_type: x11.Atom = 0;
        var actual_format: i32 = 0;
        var nitems: u64 = 0;
        var bytes_after: u64 = 0;
        var prop: [*c]u8 = null;

        const net_active = x11.XInternAtom(display, "_NET_ACTIVE_WINDOW", x11.False);
        const net_name = x11.XInternAtom(display, "_NET_WM_NAME", x11.False);

        // 1. Get the Active Window ID
        if (x11.XGetWindowProperty(display, self.root, net_active, 0, ~@as(i64, 0), x11.False, x11.AnyPropertyType, &actual_type, &actual_format, &nitems, &bytes_after, &prop) == x11.Success) {
            if (prop != null and nitems > 0) {
                const window_id = @as(*x11.Window, @ptrCast(@alignCast(prop))).*;
                _ = x11.XFree(prop);

                // 2. Get the name of that Window
                if (x11.XGetWindowProperty(display, window_id, net_name, 0, ~@as(i64, 0), x11.False, x11.AnyPropertyType, &actual_type, &actual_format, &nitems, &bytes_after, &prop) == x11.Success) {
                    if (prop != null and nitems > 0) {
                        const name_slice = prop[0..@min(nitems, 255)];
                        self.name_len = sanitizeName(name_slice, &self.current_name);
                        _ = x11.XFree(prop);
                    }
                }
            }
        }
    }

    fn xErrorHandler(_: ?*x11.Display, _: ?*x11.XErrorEvent) callconv(.C) i32 {
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
