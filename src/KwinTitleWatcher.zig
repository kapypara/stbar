const std = @import("std");
const c = @import("c");

/// Event-driven active-window title listener for KDE Plasma Wayland (`kwin_wayland`).
/// Registers a tiny 18-line KWin script bound to `workspace.windowActivated` and
/// `window.captionChanged` that pushes title changes directly to this process's unique
/// session D-Bus connection (`sd-bus` fd multiplexed into the main `poll()` loop — zero polling).
pub const KwinTitleWatcher = struct {
    const plugin_name = "zigbar_title";

    bus: ?*c.sd_bus = null,
    slot: ?*c.sd_bus_slot = null,
    active: bool = false,
    changed: bool = false,
    title: [256]u8 = @splat(0),
    title_len: usize = 0,

    /// Note: `self` must reside at a stable address before calling `init` because `sd_bus_add_object`
    /// stores `self` as its callback userdata pointer.
    pub fn init(self: *KwinTitleWatcher) bool {
        var bus: ?*c.sd_bus = null;
        if (c.sd_bus_open_user(&bus) < 0 or bus == null) return false;
        self.bus = bus;

        var unique_ptr: [*c]const u8 = null;
        if (c.sd_bus_get_unique_name(bus, &unique_ptr) < 0 or unique_ptr == null) {
            self.deinit();
            return false;
        }
        const unique_name = std.mem.span(unique_ptr);

        if (c.sd_bus_add_object(bus, &self.slot, "/io/zigbar/Title", onTitleMessage, self) < 0) {
            self.deinit();
            return false;
        }

        // Clean up any leftover script instance from an unclean exit before loading fresh
        self.unloadKwinScript();

        var path_buf: [256]u8 = undefined;
        const runtime_dir_ptr = std.c.getenv("XDG_RUNTIME_DIR");
        const runtime_dir = if (runtime_dir_ptr) |p| std.mem.span(p) else "/tmp";
        const pid: i64 = @intCast(c.getpid());
        const js_slice = std.fmt.bufPrint(&path_buf, "{s}/zigbar-kwin-{d}.js\x00", .{ runtime_dir, pid }) catch {
            self.deinit();
            return false;
        };
        const js_path: [*:0]const u8 = @ptrCast(js_slice.ptr);

        var script_buf: [1024]u8 = undefined;
        const script_src = std.fmt.bufPrint(
            &script_buf,
            \\const DEST = "{s}";
            \\let tracked = null;
            \\function sendCurrent() {{
            \\    const w = workspace.activeWindow;
            \\    callDBus(DEST, "/io/zigbar/Title", "io.zigbar.Title", "Set", w ? String(w.caption) : "");
            \\}}
            \\function bindActive(w) {{
            \\    if (tracked) {{
            \\        try {{ tracked.captionChanged.disconnect(sendCurrent); }} catch (e) {{}}
            \\    }}
            \\    tracked = w || null;
            \\    if (tracked) {{
            \\        try {{ tracked.captionChanged.connect(sendCurrent); }} catch (e) {{}}
            \\    }}
            \\    sendCurrent();
            \\}}
            \\if (workspace.windowActivated) {{
            \\    workspace.windowActivated.connect(bindActive);
            \\}} else if (workspace.clientActivated) {{
            \\    workspace.clientActivated.connect(bindActive);
            \\}}
            \\bindActive(workspace.activeWindow);
            \\
        ,
            .{unique_name},
        ) catch {
            self.deinit();
            return false;
        };

        if (!writeTempFile(js_path, script_src)) {
            self.deinit();
            return false;
        }
        defer _ = c.unlink(js_path);

        var err: c.sd_bus_error = std.mem.zeroes(c.sd_bus_error);
        defer c.sd_bus_error_free(&err);
        var reply: ?*c.sd_bus_message = null;
        defer if (reply != null) {
            _ = c.sd_bus_message_unref(reply);
        };

        const load_rc = c.sd_bus_call_method(
            bus,
            "org.kde.KWin",
            "/Scripting",
            "org.kde.kwin.Scripting",
            "loadScript",
            &err,
            &reply,
            "ss",
            js_path,
            plugin_name,
        );
        if (load_rc < 0 or reply == null) {
            self.deinit();
            return false;
        }

        var script_id: i32 = -1;
        if (c.sd_bus_message_read_basic(reply, 'i', @ptrCast(&script_id)) < 0 or script_id < 0) {
            self.unloadKwinScript();
            self.deinit();
            return false;
        }

        var obj_buf: [64]u8 = undefined;
        const obj_v6_slice = std.fmt.bufPrint(&obj_buf, "/Scripting/Script{d}\x00", .{script_id}) catch {
            self.unloadKwinScript();
            self.deinit();
            return false;
        };
        const obj_v6: [*:0]const u8 = @ptrCast(obj_v6_slice.ptr);

        var run_err: c.sd_bus_error = std.mem.zeroes(c.sd_bus_error);
        defer c.sd_bus_error_free(&run_err);
        var run_rc = c.sd_bus_call_method(
            bus,
            "org.kde.KWin",
            obj_v6,
            "org.kde.kwin.Script",
            "run",
            &run_err,
            null,
            "",
        );
        if (run_rc < 0) {
            c.sd_bus_error_free(&run_err);
            const obj_v5_slice = std.fmt.bufPrint(&obj_buf, "/{d}\x00", .{script_id}) catch {
                self.unloadKwinScript();
                self.deinit();
                return false;
            };
            const obj_v5: [*:0]const u8 = @ptrCast(obj_v5_slice.ptr);
            run_rc = c.sd_bus_call_method(
                bus,
                "org.kde.KWin",
                obj_v5,
                "org.kde.kwin.Script",
                "run",
                &run_err,
                null,
                "",
            );
        }
        if (run_rc < 0) {
            self.unloadKwinScript();
            self.deinit();
            return false;
        }

        self.active = true;
        _ = self.pump();
        return true;
    }

    pub fn deinit(self: *KwinTitleWatcher) void {
        if (self.active) {
            self.unloadKwinScript();
            self.active = false;
        }
        if (self.slot) |s| {
            _ = c.sd_bus_slot_unref(s);
            self.slot = null;
        }
        if (self.bus) |b| {
            _ = c.sd_bus_flush_close_unref(b);
            self.bus = null;
        }
    }

    fn unloadKwinScript(self: *KwinTitleWatcher) void {
        const bus = self.bus orelse return;
        var err: c.sd_bus_error = std.mem.zeroes(c.sd_bus_error);
        defer c.sd_bus_error_free(&err);
        _ = c.sd_bus_call_method(
            bus,
            "org.kde.KWin",
            "/Scripting",
            "org.kde.kwin.Scripting",
            "unloadScript",
            &err,
            null,
            "s",
            plugin_name,
        );
    }

    pub fn fd(self: *const KwinTitleWatcher) c_int {
        if (!self.active) return -1;
        const bus = self.bus orelse return -1;
        return c.sd_bus_get_fd(bus);
    }

    /// Drains all pending D-Bus messages without blocking; returns `true` if the active title changed.
    pub fn pump(self: *KwinTitleWatcher) bool {
        const bus = self.bus orelse return false;
        while (true) {
            const rc = c.sd_bus_process(bus, null);
            if (rc <= 0) break;
        }
        if (self.changed) {
            self.changed = false;
            return true;
        }
        return false;
    }

    pub fn slice(self: *const KwinTitleWatcher) []const u8 {
        return self.title[0..self.title_len];
    }

    fn writeTempFile(path: [*:0]const u8, data: []const u8) bool {
        const file_fd = c.open(path, c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_CLOEXEC, @as(c_uint, 0o600));
        if (file_fd < 0) return false;
        defer _ = c.close(file_fd);

        var written: usize = 0;
        while (written < data.len) {
            const n = c.write(file_fd, data[written..].ptr, data.len - written);
            if (n <= 0) return false;
            written += @intCast(n);
        }
        return true;
    }

    fn onTitleMessage(
        msg: ?*c.sd_bus_message,
        userdata: ?*anyopaque,
        _: ?*c.sd_bus_error,
    ) callconv(.c) c_int {
        const m = msg orelse return 0;
        if (c.sd_bus_message_is_method_call(m, "io.zigbar.Title", "Set") <= 0) {
            return 0;
        }
        const self: *KwinTitleWatcher = @ptrCast(@alignCast(userdata.?));
        var raw_str: [*c]const u8 = null;
        if (c.sd_bus_message_read_basic(m, 's', @ptrCast(&raw_str)) >= 0) {
            const span = if (raw_str != null) std.mem.span(raw_str) else "";
            const n = @min(span.len, 255);
            if (!std.mem.eql(u8, self.title[0..self.title_len], span[0..n])) {
                @memcpy(self.title[0..n], span[0..n]);
                self.title_len = n;
                self.changed = true;
            }
        }
        _ = c.sd_bus_reply_method_return(m, "");
        return 1;
    }
};
