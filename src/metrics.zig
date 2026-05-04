const std = @import("std");
const fs = std.fs;
const io = std.io;
const mem = std.mem;

const x11 = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xutil.h");
});

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
};

pub const Metric = union(MetricTag) {
    cpu: CpuProbe,
    memory: MemProbe,
    io: IoProbe,
    net: NetProbe,
    temp: TempProbe,
    load: LoadProbe,
    window: WindowNameProbe, 

    pub fn sample(self: *Metric) !void {
        return switch (self.*) {
            .cpu => |*p| p.sample(),
            .memory => |*p| p.sample(),
            .io => |*p| p.sample(),
            .net => |*p| p.sample(),
            .temp => |*p| p.sample(),
            .load => |*p| p.sample(),
            .window => |*p| p.sample(),
        };
    }
};

// --- Implementation Probes ---

pub const CpuProbe = struct {
    prev_idle: u64 = 0,
    prev_total: u64 = 0,
    current_pct: u64 = 0,

    pub fn sample(self: *CpuProbe) !void {
        const file = try fs.openFileAbsolute("/proc/stat", .{});
        defer file.close();
        var buf: [1024]u8 = undefined;
        const amt = try file.readAll(&buf);

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

    pub fn sample(self: *MemProbe) !void {
        const file = try fs.openFileAbsolute("/proc/meminfo", .{});
        defer file.close();
        var reader = io.bufferedReader(file.reader());
        var buf: [512]u8 = undefined;

        while (try reader.reader().readUntilDelimiterOrEof(&buf, '\n')) |line| {
            var it = mem.tokenizeAny(u8, line, " :kbKB");
            const label = it.next() orelse continue;
            const val_str = it.next() orelse continue;
            const val = try std.fmt.parseInt(u64, val_str, 10);

            if (mem.eql(u8, label, "MemFree")) {
                self.free = val >> 10; // Convert KB to MB
            } else if (mem.eql(u8, label, "Dirty")) {
                self.dirty = val >> 10;
            }
        }
    }
};

pub const IoProbe = struct {
    prev: IoStat = .{},
    current: IoStat = .{},

    pub fn sample(self: *IoProbe) !void {
        const file = try fs.openFileAbsolute("/proc/diskstats", .{});
        defer file.close();
        var reader = io.bufferedReader(file.reader());
        var buf: [1024]u8 = undefined;

        var raw = IoStat{};
        while (try reader.reader().readUntilDelimiterOrEof(&buf, '\n')) |line| {
            var it = mem.tokenizeAny(u8, line, " ");
            _ = it.next(); // major
            _ = it.next(); // minor
            const dev = it.next() orelse "";
            
            // Logic from source: target sd* and mmcblk* but skip partitions
            if (mem.startsWith(u8, dev, "sd") or mem.startsWith(u8, dev, "mmcblk")) {
                if (dev[dev.len-1] >= '0' and dev[dev.len-1] <= '9') continue; 

                var i: usize = 0;
                while (it.next()) |token| : (i += 1) {
                    if (i == 3) raw.read += try std.fmt.parseInt(u64, token, 10);
                    if (i == 7) raw.write += try std.fmt.parseInt(u64, token, 10);
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

    pub fn sample(self: *NetProbe) !void {
        // In a real loop, we would iterate /sys/class/net/ entries[cite: 1]
        // This version uses fixed buffers to avoid runtime allocation
        var raw = NetStat{};
        
        // Simplified example for 'eth0' or similar
        raw.rx = try readSysfsUint("/sys/class/net/enp0s3/statistics/rx_bytes");
        raw.tx = try readSysfsUint("/sys/class/net/enp0s3/statistics/tx_bytes");

        self.current = raw.diff(self.prev);
        self.prev = raw;
    }

    fn readSysfsUint(path: []const u8) !u64 {
        const file = fs.openFileAbsolute(path, .{}) catch return 0;
        defer file.close();
        var buf: [32]u8 = undefined;
        const amt = try file.readAll(&buf);
        return std.fmt.parseInt(u64, mem.trim(u8, buf[0..amt], " \n"), 10) catch 0;
    }
};

pub const TempProbe = struct {
    value: u64 = 0,
    pub fn sample(self: *TempProbe) !void {
        const file = fs.openFileAbsolute("/sys/class/hwmon/hwmon2/temp1_input", .{}) catch return;
        defer file.close();
        var buf: [16]u8 = undefined;
        const amt = try file.readAll(&buf);
        self.value = (std.fmt.parseInt(u64, mem.trim(u8, buf[0..amt], " \n"), 10) catch 0) / 1000;
    }
};

pub const LoadProbe = struct {
    value: u64 = 0,
    pub fn sample(self: *LoadProbe) !void {
        var info: std.os.linux.sysinfo = undefined;
        if (std.os.linux.sysinfo(&info) == 0) {
            self.value = info.loads[0] / ((@as(u64, 1) << 16) / 100);
        }
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
        
        var actual_type: x11.Atom = 0;
        var actual_format: i32 = 0;
        var nitems: u64 = 0;
        var bytes_after: u64 = 0;
        var prop: [*c]u8 = null;

        const net_active = x11.XInternAtom(display, "_NET_ACTIVE_WINDOW", x11.False);
        const net_name = x11.XInternAtom(display, "_NET_WM_NAME", x11.False);

        // 1. Get the Active Window ID
        if (x11.XGetWindowProperty(display, self.root, net_active, 0, ~@as(i64, 0), x11.False, x11.AnyPropertyType, &actual_type, &actual_format, &nitems, &bytes_after, &prop) == 0) {
            if (prop != null and nitems > 0) {
                const window_id = @as(*x11.Window, @ptrCast(@alignCast(prop))).*;
                x11.XFree(prop);

                // 2. Get the name of that Window
                if (x11.XGetWindowProperty(display, window_id, net_name, 0, ~@as(i64, 0), x11.False, x11.AnyPropertyType, &actual_type, &actual_format, &nitems, &bytes_after, &prop) == 0) {
                    if (prop != null and nitems > 0) {
                        const name_slice = prop[0..@min(nitems, 255)];
                        self.name_len = sanitizeName(name_slice, &self.current_name);
                        x11.XFree(prop);
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
