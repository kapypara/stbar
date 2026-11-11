const std = @import("std");
const Io = std.Io;
const mem = std.mem;

const x11 = @import("Window.zig").c;

const c = @import("c");

const ticker_zig = @import("Ticker.zig");
const nanoTimestamp = ticker_zig.nanoTimestamp;
const monotonicNs = ticker_zig.monotonicNs;
const formats = @import("formats.zig");

// --- Data Structures ---

pub const IoStat = struct {
    read: u64 = 0,
    write: u64 = 0,

    /// Saturating delta prevents u64 wraparound spikes if a hot-plugged USB drive is removed.
    pub fn diff(self: IoStat, prev: IoStat) IoStat {
        return .{
            .read = self.read -| prev.read,
            .write = self.write -| prev.write,
        };
    }
};

pub const NetStat = struct {
    rx: u64 = 0,
    tx: u64 = 0,

    /// Saturating delta prevents u64 wraparound spikes if a USB NIC or tether is unplugged.
    pub fn diff(self: NetStat, prev: NetStat) NetStat {
        return .{
            .rx = self.rx -| prev.rx,
            .tx = self.tx -| prev.tx,
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
            .temp => write(&result, formats.temperature(value)),
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

        var buf: [256]u8 = undefined;
        const amt = try preadOnce(file, io, &buf);
        const first_line = mem.sliceTo(buf[0..amt], '\n');

        var it = mem.tokenizeAny(u8, first_line, " \t");
        _ = it.next(); // skip "cpu"

        var total: u64 = 0;
        var idle: u64 = 0;
        var i: usize = 0;
        // Sum fields 0..7 (user, nice, system, idle, iowait, irq, softirq, steal).
        // Fields 8..9 (guest, guest_nice) are already accounted inside user/nice by Linux.
        while (it.next()) |token| : (i += 1) {
            if (i >= 8) break;
            const val = std.fmt.parseInt(u64, token, 10) catch 0;
            total += val;
            if (i == 3 or i == 4) idle += val; // idle + iowait
        }

        if (!self.primed) {
            self.prev_idle = idle;
            self.prev_total = total;
            self.current_pct = 0;
            self.primed = true;
            return;
        }

        const diff_idle = idle -| self.prev_idle;
        const diff_total = total -| self.prev_total;
        self.prev_idle = idle;
        self.prev_total = total;

        self.current_pct = if (diff_total == 0 or diff_idle >= diff_total)
            0
        else
            (100 * (diff_total - diff_idle)) / diff_total;
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

        var found_avail = false;
        var found_dirty = false;

        var line_it = mem.tokenizeScalar(u8, buf[0..amt], '\n');
        while (line_it.next()) |line| {
            const colon = mem.indexOfScalar(u8, line, ':') orelse continue;
            const label = mem.trim(u8, line[0..colon], " \t");
            const val_str = mem.trim(u8, line[colon + 1 ..], " \tkBKB");
            const val = std.fmt.parseInt(u64, val_str, 10) catch 0;

            if (mem.eql(u8, label, "MemAvailable")) {
                self.free = val >> 10; // KiB -> MiB
                found_avail = true;
            } else if (mem.eql(u8, label, "Dirty")) {
                self.dirty = val << 10; // KiB -> bytes for generic formatter
                found_dirty = true;
            }

            if (found_avail and found_dirty)
                break;
        }
    }
};

pub const IoProbe = struct {
    file: ?Io.File = null,
    prev: IoStat = .{},
    prev_ns: i96 = 0,
    current: IoStat = .{},
    primed: bool = false,

    pub fn deinit(self: *IoProbe, io: Io) void {
        closeSlot(&self.file, io);
    }

    pub fn isWholeDisk(dev: []const u8) bool {
        if (mem.startsWith(u8, dev, "nvme")) {
            return dev.len > 4 and mem.indexOfScalar(u8, dev, 'p') == null;
        }
        if (mem.startsWith(u8, dev, "mmcblk")) {
            // Whole SD/eMMC device is mmcblk<digits> (excludes mmcblk0p1, mmcblk0boot0, mmcblk0rpmb)
            if (dev.len <= 6) return false;
            for (dev[6..]) |ch| {
                if (!std.ascii.isDigit(ch)) return false;
            }
            return true;
        }
        if (mem.startsWith(u8, dev, "sd") or mem.startsWith(u8, dev, "hd") or mem.startsWith(u8, dev, "vd")) {
            return dev.len > 2 and !std.ascii.isDigit(dev[dev.len - 1]);
        }
        if (mem.startsWith(u8, dev, "xvd")) {
            return dev.len > 3 and !std.ascii.isDigit(dev[dev.len - 1]);
        }
        return false;
    }

    pub fn sample(self: *IoProbe, io: Io) !void {
        const file = try ensureOpen(&self.file, io, "/proc/diskstats");
        const now_ns = monotonicNs(io);

        var buf: [8192]u8 = undefined;
        const amt = try preadOnce(file, io, &buf);

        var raw = IoStat{};

        var line_it = mem.tokenizeScalar(u8, buf[0..amt], '\n');
        while (line_it.next()) |line| {
            var it = mem.tokenizeAny(u8, line, " \t");
            _ = it.next(); // major
            _ = it.next(); // minor
            const dev = it.next() orelse continue;

            if (!isWholeDisk(dev)) continue;

            // Remaining fields (0-indexed):
            // 0: reads completed, 1: reads merged, 2: sectors read, 3: ms reading,
            // 4: writes completed, 5: writes merged, 6: sectors written
            var i: usize = 0;
            while (it.next()) |token| : (i += 1) {
                if (i == 2) raw.read += std.fmt.parseInt(u64, token, 10) catch 0;
                if (i == 6) {
                    raw.write += std.fmt.parseInt(u64, token, 10) catch 0;
                    break;
                }
            }
        }

        if (!self.primed) {
            self.prev = raw;
            self.prev_ns = now_ns;
            self.current = .{};
            self.primed = true;
            return;
        }

        const dt_ns: u64 = @intCast(@max(1, now_ns - self.prev_ns));
        self.prev_ns = now_ns;
        const delta = raw.diff(self.prev);
        self.prev = raw;

        // Sectors are 512 bytes (<< 9), normalized to exact bytes/second
        self.current.read = @intCast(((@as(u128, delta.read) << 9) * std.time.ns_per_s) / dt_ns);
        self.current.write = @intCast(((@as(u128, delta.write) << 9) * std.time.ns_per_s) / dt_ns);
    }
};

pub const NetProbe = struct {
    file: ?Io.File = null,
    prev: NetStat = .{},
    prev_ns: i96 = 0,
    current: NetStat = .{},
    primed: bool = false,

    pub fn deinit(self: *NetProbe, io: Io) void {
        closeSlot(&self.file, io);
    }

    pub fn isPhysicalNetIface(iface: []const u8) bool {
        // Match real NICs (Ethernet, Wi-Fi, WWAN LTE/5G, USB tethering, InfiniBand) while
        // excluding loopback (lo), VPN tunnels (wg*, tun*, tap*, tailscale*), and container
        // bridges (docker*, veth*, br-*, virbr*) whose traffic also traverses the physical NIC.
        return mem.startsWith(u8, iface, "en") or
            mem.startsWith(u8, iface, "eth") or
            mem.startsWith(u8, iface, "wl") or
            mem.startsWith(u8, iface, "ww") or
            mem.startsWith(u8, iface, "usb") or
            mem.startsWith(u8, iface, "ib");
    }

    pub fn sample(self: *NetProbe, io: Io) !void {
        const file = try ensureOpen(&self.file, io, "/proc/net/dev");
        const now_ns = monotonicNs(io);

        var buf: [4096]u8 = undefined;
        const amt = try preadOnce(file, io, &buf);

        var raw = NetStat{};
        var line_it = mem.tokenizeScalar(u8, buf[0..amt], '\n');
        while (line_it.next()) |line| {
            const colon = mem.indexOfScalar(u8, line, ':') orelse continue;
            const iface = mem.trim(u8, line[0..colon], " \t");
            if (!isPhysicalNetIface(iface)) continue;

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
            self.prev_ns = now_ns;
            self.current = .{};
            self.primed = true;
            return;
        }

        const dt_ns: u64 = @intCast(@max(1, now_ns - self.prev_ns));
        self.prev_ns = now_ns;
        const delta = raw.diff(self.prev);
        self.prev = raw;

        self.current.rx = @intCast((@as(u128, delta.rx) * std.time.ns_per_s) / dt_ns);
        self.current.tx = @intCast((@as(u128, delta.tx) * std.time.ns_per_s) / dt_ns);
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

    pub fn isRealStorageMount(fs_type: []const u8, source: []const u8) bool {
        if (mem.startsWith(u8, fs_type, "fuse") or
            mem.eql(u8, fs_type, "squashfs") or
            mem.eql(u8, fs_type, "erofs") or
            mem.eql(u8, fs_type, "iso9660") or
            mem.eql(u8, fs_type, "udf") or
            mem.eql(u8, fs_type, "tmpfs") or
            mem.eql(u8, fs_type, "devtmpfs") or
            mem.eql(u8, fs_type, "overlay"))
        {
            return false;
        }

        if (!mem.startsWith(u8, source, "/dev/")) return false;

        const excluded_devs = [_][]const u8{
            "/dev/loop",
            "/dev/ram",
            "/dev/zram",
            "/dev/sr",
            "/dev/cdrom",
            "/dev/fd",
            "/dev/shm",
            "/dev/pts",
            "/dev/mqueue",
            "/dev/hugepages",
            "/dev/fuse",
        };
        for (excluded_devs) |prefix| {
            if (mem.startsWith(u8, source, prefix)) return false;
        }
        return true;
    }

    fn parseDevId(dev_str: []const u8) ?u64 {
        const colon = mem.indexOfScalar(u8, dev_str, ':') orelse return null;
        const major = std.fmt.parseInt(u32, dev_str[0..colon], 10) catch return null;
        const minor = std.fmt.parseInt(u32, dev_str[colon + 1 ..], 10) catch return null;
        return (@as(u64, major) << 32) | @as(u64, minor);
    }

    /// Decodes Linux mountinfo octal escapes (e.g. "\040" -> ' ') into a NUL-terminated path.
    pub fn unescapeMountPath(raw: []const u8, out: []u8) ?usize {
        if (out.len == 0) return null;
        var r: usize = 0;
        var w: usize = 0;
        while (r < raw.len) {
            if (w >= out.len - 1) return null;
            if (raw[r] == '\\' and r + 3 < raw.len and
                raw[r + 1] >= '0' and raw[r + 1] <= '3' and
                raw[r + 2] >= '0' and raw[r + 2] <= '7' and
                raw[r + 3] >= '0' and raw[r + 3] <= '7')
            {
                const d1: u8 = raw[r + 1] - '0';
                const d2: u8 = raw[r + 2] - '0';
                const d3: u8 = raw[r + 3] - '0';
                out[w] = (d1 << 6) | (d2 << 3) | d3;
                r += 4;
            } else {
                out[w] = raw[r];
                r += 1;
            }
            w += 1;
        }
        out[w] = 0;
        return w;
    }

    pub fn sample(self: *StorageProbe, io: Io) !void {
        const now = monotonicNs(io);
        if (self.last_sample_ns != 0 and now - self.last_sample_ns < refresh_interval_ns) {
            return;
        }
        self.last_sample_ns = now;

        const file = try ensureOpen(&self.file, io, "/proc/self/mountinfo");

        // Deduplicate by kernel superblock major:minor so Btrfs subvolumes, multi-device pools,
        // bind mounts, and /dev/mapper vs /dev/dm-* aliases are counted once.
        var seen_sb: [64]u64 = undefined;
        var seen_count: usize = 0;

        var total_free: u64 = 0;
        var buf: [16384]u8 = undefined;
        const amt = try preadOnce(file, io, &buf);

        var line_it = mem.tokenizeScalar(u8, buf[0..amt], '\n');
        while (line_it.next()) |line| {
            const sep = mem.indexOf(u8, line, " - ") orelse continue;
            var left_it = mem.tokenizeScalar(u8, line[0..sep], ' ');
            _ = left_it.next() orelse continue; // mount_id
            _ = left_it.next() orelse continue; // parent_id
            const dev_id_str = left_it.next() orelse continue; // major:minor
            _ = left_it.next() orelse continue; // root
            const mnt_dir = left_it.next() orelse continue; // mount_point

            var right_it = mem.tokenizeScalar(u8, line[sep + 3 ..], ' ');
            const fs_type = right_it.next() orelse continue;
            const source = right_it.next() orelse continue;

            if (!isRealStorageMount(fs_type, source)) continue;

            const sb_id = parseDevId(dev_id_str) orelse continue;
            if (mem.indexOfScalar(u64, seen_sb[0..seen_count], sb_id) != null) continue;

            var path_buf: [512]u8 = undefined;
            if (unescapeMountPath(mnt_dir, &path_buf) == null) continue;

            var stat: c.struct_statvfs = undefined;
            if (c.statvfs(&path_buf, &stat) == 0 and stat.f_blocks > 0) {
                const block_size: u64 = if (stat.f_frsize != 0) stat.f_frsize else stat.f_bsize;
                total_free += stat.f_bavail * block_size;
                if (seen_count < seen_sb.len) {
                    seen_sb[seen_count] = sb_id;
                    seen_count += 1;
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
        if (display != null) {
            _ = x11.XSetErrorHandler(xErrorHandler);
        }
    }

    pub fn setExternalTitle(self: *WindowNameProbe, raw_title: []const u8) void {
        self.dirty = false;
        var next_buf: [256]u8 = @splat(0);
        const next_len = sanitizeName(raw_title, &next_buf);
        if (!mem.eql(u8, self.current_name[0..self.name_len], next_buf[0..next_len])) {
            self.current_name = next_buf;
            self.name_len = next_len;
            self.changed = true;
        }
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

    fn sanitizeName(src: []const u8, dest: *[256]u8) usize {
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

test "Device filters, mount path unescaping, and hot-unplug saturating diffs" {
    // Whole disks vs partitions & virtual block devices
    try std.testing.expect(IoProbe.isWholeDisk("nvme0n1"));
    try std.testing.expect(!IoProbe.isWholeDisk("nvme0n1p1"));
    try std.testing.expect(!IoProbe.isWholeDisk("nvme0n1p12"));
    try std.testing.expect(IoProbe.isWholeDisk("sda"));
    try std.testing.expect(IoProbe.isWholeDisk("sdaa"));
    try std.testing.expect(!IoProbe.isWholeDisk("sda1"));
    try std.testing.expect(!IoProbe.isWholeDisk("sda12"));
    try std.testing.expect(IoProbe.isWholeDisk("vda"));
    try std.testing.expect(IoProbe.isWholeDisk("xvda"));
    try std.testing.expect(IoProbe.isWholeDisk("mmcblk0"));
    try std.testing.expect(!IoProbe.isWholeDisk("mmcblk0p1"));
    try std.testing.expect(!IoProbe.isWholeDisk("mmcblk0boot0"));
    try std.testing.expect(!IoProbe.isWholeDisk("dm-0"));
    try std.testing.expect(!IoProbe.isWholeDisk("loop0"));
    try std.testing.expect(!IoProbe.isWholeDisk("zram0"));

    // Network interfaces: physical vs virtual/tunnels
    try std.testing.expect(NetProbe.isPhysicalNetIface("enp2s0"));
    try std.testing.expect(NetProbe.isPhysicalNetIface("eth0"));
    try std.testing.expect(NetProbe.isPhysicalNetIface("wlp3s0"));
    try std.testing.expect(NetProbe.isPhysicalNetIface("wwan0"));
    try std.testing.expect(NetProbe.isPhysicalNetIface("usb0"));
    try std.testing.expect(!NetProbe.isPhysicalNetIface("lo"));
    try std.testing.expect(!NetProbe.isPhysicalNetIface("wg0"));
    try std.testing.expect(!NetProbe.isPhysicalNetIface("tun0"));
    try std.testing.expect(!NetProbe.isPhysicalNetIface("docker0"));
    try std.testing.expect(!NetProbe.isPhysicalNetIface("veth1234"));

    // Storage mount filtering & octal escape decoding
    try std.testing.expect(StorageProbe.isRealStorageMount("btrfs", "/dev/nvme0n1p2"));
    try std.testing.expect(StorageProbe.isRealStorageMount("ext4", "/dev/mapper/cryptroot"));
    try std.testing.expect(StorageProbe.isRealStorageMount("xfs", "/dev/md0"));
    try std.testing.expect(!StorageProbe.isRealStorageMount("squashfs", "/dev/loop0"));
    try std.testing.expect(!StorageProbe.isRealStorageMount("fuse.AppImage", "OpenIDEA.AppImage"));
    try std.testing.expect(!StorageProbe.isRealStorageMount("ext4", "/dev/zram0"));

    var unescaped: [64]u8 = undefined;
    const len = StorageProbe.unescapeMountPath("/run/media/moon/My\\040USB\\040Drive", &unescaped).?;
    try std.testing.expectEqualStrings("/run/media/moon/My USB Drive", unescaped[0..len]);

    // Hot-unplugging a USB drive or NIC must clamp to 0 instead of wrapping u64
    const prev_io = IoStat{ .read = 50_000, .write = 80_000 };
    const after_unplug_io = (IoStat{ .read = 10_000, .write = 20_000 }).diff(prev_io);
    try std.testing.expectEqual(@as(u64, 0), after_unplug_io.read);
    try std.testing.expectEqual(@as(u64, 0), after_unplug_io.write);

    const prev_net = NetStat{ .rx = 1_000_000, .tx = 500_000 };
    const after_unplug_net = (NetStat{ .rx = 200_000, .tx = 100_000 }).diff(prev_net);
    try std.testing.expectEqual(@as(u64, 0), after_unplug_net.rx);
    try std.testing.expectEqual(@as(u64, 0), after_unplug_net.tx);
}
