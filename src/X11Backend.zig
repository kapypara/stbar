const std = @import("std");
const c = @import("c");
const ProcLoader = @import("GlProcs.zig").ProcLoader;

const USE_GLX_CREATE_WINDOW = 1;

pub const Click = struct {
    x: i32 = 0,
    y: i32 = 0,
    button: u32 = 0,
};

pub const X11Backend = struct {
    display: ?*c.Display = null,
    x_screen: i32 = 0,
    root: c.Window = 0,
    handle: c.Window = 0,
    glx_handle: c.GLXWindow = 0,
    render_context: c.GLXContext = null,

    visual: ?*c.XVisualInfo = null,
    fbconfig: c.GLXFBConfig = null,
    cmap: c.Colormap = 0,
    del_atom: c.Atom = 0,
    wm_strut_atom: c.Atom = 0,
    wm_strut_partial_atom: c.Atom = 0,
    net_active_window_atom: c.Atom = 0,
    net_wm_name_atom: c.Atom = 0,
    wm_name_atom: c.Atom = 0,

    // Native in-process X11 ICCCM `CLIPBOARD` selection atoms & buffer
    clipboard_atom: c.Atom = 0,
    targets_atom: c.Atom = 0,
    utf8_string_atom: c.Atom = 0,
    text_atom: c.Atom = 0,
    text_plain_atom: c.Atom = 0,
    text_plain_utf8_atom: c.Atom = 0,
    last_event_time: c.Time = c.CurrentTime,
    clipboard_buf: [512]u8 = @splat(0),
    clipboard_len: usize = 0,

    width: i32 = 800,
    height: i32 = 17,
    x: i32 = 0,
    y: i32 = 0,
    input_height: i32 = 0,

    running: bool = true,
    docked: bool = true,
    strut_enabled: bool = false,
    pointer_inside: bool = false,
    clicked: bool = false,
    resized: bool = false,
    exposed: bool = false,
    title_dirty: bool = true,
    last_click: Click = .{},

    pub fn init(self: *X11Backend, x: i32, y: i32, width: i32, height: i32) !void {
        self.x = x;
        self.y = y;
        self.width = width;
        self.height = height;

        try self.createTheWindow();
        errdefer self.deinit();
        try self.createTheRenderContext();
    }

    pub fn deinit(self: *X11Backend) void {
        if (self.display) |dpy| {
            _ = c.glXMakeCurrent(dpy, 0, null);
            if (self.render_context != null) c.glXDestroyContext(dpy, self.render_context);
            if (USE_GLX_CREATE_WINDOW == 1 and self.glx_handle != 0) c.glXDestroyWindow(dpy, self.glx_handle);
            if (self.handle != 0) _ = c.XDestroyWindow(dpy, self.handle);
            if (self.cmap != 0) _ = c.XFreeColormap(dpy, self.cmap);
            if (self.visual) |vis| _ = c.XFree(vis);
            _ = c.XCloseDisplay(dpy);
            self.display = null;
        }
    }

    pub fn getProcLoader(_: *const X11Backend) ProcLoader {
        return glxLoadProc;
    }

    fn glxLoadProc(name: [*:0]const u8) callconv(.c) ?*const anyopaque {
        return @ptrCast(c.glXGetProcAddressARB(@ptrCast(name)));
    }

    fn createTheWindow(self: *X11Backend) !void {
        self.display = c.XOpenDisplay(null) orelse return error.XOpenDisplayFailed;
        const dpy = self.display.?;

        self.x_screen = c.DefaultScreen(dpy);
        self.root = c.RootWindow(dpy, self.x_screen);
        if (self.width <= 0) {
            self.width = c.DisplayWidth(dpy, self.x_screen);
        }

        const vis_attribs = [_]i32{
            c.GLX_RENDER_TYPE,   c.GLX_RGBA_BIT,
            c.GLX_DRAWABLE_TYPE, c.GLX_WINDOW_BIT,
            c.GLX_DOUBLEBUFFER,  c.True,
            c.GLX_RED_SIZE,      8,
            c.GLX_GREEN_SIZE,    8,
            c.GLX_BLUE_SIZE,     8,
            c.GLX_ALPHA_SIZE,    8,
            c.GLX_DEPTH_SIZE,    0,
            c.None,
        };

        var num_configs: i32 = 0;
        const fbconfigs = c.glXChooseFBConfig(dpy, self.x_screen, &vis_attribs, &num_configs);
        if (fbconfigs == null or num_configs == 0) return error.NoFBConfigs;
        defer _ = c.XFree(@ptrCast(fbconfigs));

        var found = false;
        for (0..@intCast(num_configs)) |i| {
            const vis = c.glXGetVisualFromFBConfig(dpy, fbconfigs[i]);
            if (vis == null) continue;
            defer _ = c.XFree(vis);

            const pf = c.XRenderFindVisualFormat(dpy, vis.*.visual);
            if (pf != null and pf.*.direct.alphaMask > 0) {
                self.fbconfig = fbconfigs[i];
                self.visual = c.glXGetVisualFromFBConfig(dpy, fbconfigs[i]);
                found = true;
                break;
            }
        }
        if (!found) return error.NoMatchingFBConfig;

        self.cmap = c.XCreateColormap(dpy, self.root, self.visual.?.visual, c.AllocNone);

        var attr: c.XSetWindowAttributes = std.mem.zeroes(c.XSetWindowAttributes);
        attr.colormap = self.cmap;
        attr.background_pixmap = c.None;
        attr.border_pixel = 0;
        attr.event_mask = c.StructureNotifyMask | c.EnterWindowMask | c.LeaveWindowMask |
            c.ExposureMask | c.ButtonPressMask | c.ButtonReleaseMask |
            c.OwnerGrabButtonMask | c.KeyPressMask | c.KeyReleaseMask;

        self.handle = c.XCreateWindow(
            dpy,
            self.root,
            self.x,
            self.y,
            @intCast(self.width),
            @intCast(self.height),
            0,
            self.visual.?.depth,
            c.InputOutput,
            self.visual.?.visual,
            c.CWColormap | c.CWBorderPixel | c.CWEventMask,
            &attr,
        );
        if (self.handle == 0) return error.CreateWindowFailed;

        if (USE_GLX_CREATE_WINDOW == 0) {
            self.glx_handle = self.handle;
        } else {
            const glx_attr = [_]i32{c.None};
            self.glx_handle = c.glXCreateWindow(dpy, self.fbconfig, self.handle, &glx_attr);
        }
        if (self.glx_handle == 0) return error.GlxCreateWindowFailed;

        var hints = std.mem.zeroes(c.XSizeHints);
        hints.flags = c.USPosition | c.PPosition | c.USSize | c.PSize;
        hints.x = self.x;
        hints.y = self.y;
        hints.width = self.width;
        hints.height = self.height;
        c.XSetWMNormalHints(dpy, self.handle, &hints);

        self.wm_strut_atom = c.XInternAtom(dpy, "_NET_WM_STRUT", c.False);
        self.wm_strut_partial_atom = c.XInternAtom(dpy, "_NET_WM_STRUT_PARTIAL", c.False);

        if (self.docked) {
            const window_type = c.XInternAtom(dpy, "_NET_WM_WINDOW_TYPE", c.False);
            const dock_type = c.XInternAtom(dpy, "_NET_WM_WINDOW_TYPE_DOCK", c.False);
            _ = c.XChangeProperty(dpy, self.handle, window_type, c.XA_ATOM, 32, c.PropModeReplace, @ptrCast(&dock_type), 1);

            const window_state = c.XInternAtom(dpy, "_NET_WM_STATE", c.False);
            const states = [_]c.Atom{
                c.XInternAtom(dpy, "_NET_WM_STATE_STICKY", c.False),
                c.XInternAtom(dpy, "_NET_WM_STATE_ABOVE", c.False),
                c.XInternAtom(dpy, "_NET_WM_STATE_STAYS_ON_TOP", c.False),
            };
            _ = c.XChangeProperty(dpy, self.handle, window_state, c.XA_ATOM, 32, c.PropModeAppend, @ptrCast(&states), 3);

            const wm_desktop = c.XInternAtom(dpy, "_NET_WM_DESKTOP", c.False);
            const all_desktops: c.u_long = 0xFFFFFFFF;
            _ = c.XChangeProperty(dpy, self.handle, wm_desktop, c.XA_CARDINAL, 32, c.PropModeReplace, @ptrCast(&all_desktops), 1);

            if (self.strut_enabled) {
                self.applyStrut(true);
            }
        }

        const initial_input_h = if (self.input_height > 0) self.input_height else self.height;
        self.applyInputHeight(initial_input_h);

        _ = c.XMapWindow(dpy, self.handle);
        var ev: c.XEvent = undefined;
        _ = c.XIfEvent(dpy, &ev, waitForMapNotify, @ptrCast(&self.handle));

        self.del_atom = c.XInternAtom(dpy, "WM_DELETE_WINDOW", c.False);
        _ = c.XSetWMProtocols(dpy, self.handle, &self.del_atom, 1);

        self.net_active_window_atom = c.XInternAtom(dpy, "_NET_ACTIVE_WINDOW", c.False);
        self.net_wm_name_atom = c.XInternAtom(dpy, "_NET_WM_NAME", c.False);
        self.wm_name_atom = c.XInternAtom(dpy, "WM_NAME", c.False);
        self.clipboard_atom = c.XInternAtom(dpy, "CLIPBOARD", c.False);
        self.targets_atom = c.XInternAtom(dpy, "TARGETS", c.False);
        self.utf8_string_atom = c.XInternAtom(dpy, "UTF8_STRING", c.False);
        self.text_atom = c.XInternAtom(dpy, "TEXT", c.False);
        self.text_plain_atom = c.XInternAtom(dpy, "text/plain", c.False);
        self.text_plain_utf8_atom = c.XInternAtom(dpy, "text/plain;charset=utf-8", c.False);
        _ = c.XSelectInput(dpy, self.root, c.PropertyChangeMask);

        var root_ret: c.Window = 0;
        var child_ret: c.Window = 0;
        var root_x: c_int = 0;
        var root_y: c_int = 0;
        var win_x: c_int = 0;
        var win_y: c_int = 0;
        var mask_ret: c_uint = 0;
        if (c.XQueryPointer(dpy, self.handle, &root_ret, &child_ret, &root_x, &root_y, &win_x, &win_y, &mask_ret) != 0) {
            self.pointer_inside = (win_x >= 0 and win_x < self.width and win_y >= 0 and win_y < self.input_height);
        }
    }

    pub fn setStrut(self: *X11Backend, enabled: bool) void {
        if (self.strut_enabled == enabled) return;
        self.strut_enabled = enabled;
        self.applyStrut(enabled);
    }

    fn applyStrut(self: *X11Backend, enabled: bool) void {
        const dpy = self.display orelse return;
        if (self.handle == 0) return;

        var strut = std.mem.zeroes([12]c.u_long);
        if (enabled) {
            strut[2] = @intCast(@max(0, self.y + self.height));
            strut[8] = @intCast(@max(0, self.x));
            strut[9] = @intCast(@max(0, self.x + self.width - 1));

            _ = c.XChangeProperty(dpy, self.handle, self.wm_strut_atom, c.XA_CARDINAL, 32, c.PropModeReplace, @ptrCast(&strut), 4);
            _ = c.XChangeProperty(dpy, self.handle, self.wm_strut_partial_atom, c.XA_CARDINAL, 32, c.PropModeReplace, @ptrCast(&strut), 12);
        } else {
            _ = c.XChangeProperty(dpy, self.handle, self.wm_strut_atom, c.XA_CARDINAL, 32, c.PropModeReplace, @ptrCast(&strut), 4);
            _ = c.XChangeProperty(dpy, self.handle, self.wm_strut_partial_atom, c.XA_CARDINAL, 32, c.PropModeReplace, @ptrCast(&strut), 12);
            _ = c.XDeleteProperty(dpy, self.handle, self.wm_strut_atom);
            _ = c.XDeleteProperty(dpy, self.handle, self.wm_strut_partial_atom);
        }
        _ = c.XFlush(dpy);
    }

    pub fn setInputHeight(self: *X11Backend, h: i32) void {
        const target = if (h <= 1) @as(i32, 1) else self.height;
        if (self.input_height == target) return;
        self.applyInputHeight(target);
    }

    fn applyInputHeight(self: *X11Backend, target: i32) void {
        const dpy = self.display orelse return;
        if (self.handle == 0) return;
        self.input_height = target;

        if (target <= 1) {
            var rect = c.XRectangle{
                .x = 0,
                .y = 0,
                .width = @intCast(@max(1, self.width)),
                .height = 1,
            };
            c.XShapeCombineRectangles(dpy, self.handle, c.ShapeInput, 0, 0, &rect, 1, c.ShapeSet, c.YXBanded);
        } else {
            c.XShapeCombineMask(dpy, self.handle, c.ShapeInput, 0, 0, c.None, c.ShapeSet);
        }
        _ = c.XFlush(dpy);
    }

    fn createTheRenderContext(self: *X11Backend) !void {
        const dpy = self.display orelse return error.NoDisplay;

        const CreateCtxAttribsFn = *const fn (?*c.Display, c.GLXFBConfig, c.GLXContext, c_int, [*c]const c_int) callconv(.c) c.GLXContext;
        if (c.glXGetProcAddressARB("glXCreateContextAttribsARB")) |ptr| {
            const createAttribs: CreateCtxAttribsFn = @ptrCast(ptr);
            const ctx_attribs = [_]c_int{
                c.GLX_CONTEXT_MAJOR_VERSION_ARB, 3,
                c.GLX_CONTEXT_MINOR_VERSION_ARB, 2,
                c.GLX_CONTEXT_PROFILE_MASK_ARB,  c.GLX_CONTEXT_CORE_PROFILE_BIT_ARB,
                c.None,
            };
            self.render_context = createAttribs(dpy, self.fbconfig, null, c.True, &ctx_attribs);
        }
        if (self.render_context == null) {
            self.render_context = c.glXCreateNewContext(dpy, self.fbconfig, c.GLX_RGBA_TYPE, null, c.True);
        }
        if (self.render_context == null) return error.ContextCreationFailed;

        if (c.glXMakeContextCurrent(dpy, self.glx_handle, self.glx_handle, self.render_context) == 0) {
            return error.MakeContextCurrentFailed;
        }

        const SwapExtFn = *const fn (?*c.Display, c.GLXDrawable, c_int) callconv(.c) void;
        const SwapMesaFn = *const fn (c_uint) callconv(.c) c_int;
        if (c.glXGetProcAddressARB("glXSwapIntervalEXT")) |ptr| {
            const setSwapExt: SwapExtFn = @ptrCast(ptr);
            setSwapExt(dpy, self.glx_handle, 1);
        } else if (c.glXGetProcAddressARB("glXSwapIntervalMESA")) |ptr| {
            const setSwapMesa: SwapMesaFn = @ptrCast(ptr);
            _ = setSwapMesa(1);
        }

        c.glClearColor(0.0, 0.0, 0.0, 0.0);
        self.updateViewport();
        self.clearTransparent();
    }

    pub fn clearTransparent(self: *X11Backend) void {
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        self.swapBuffers();
    }

    pub fn updateTheMessageQueue(self: *X11Backend) void {
        const dpy = self.display orelse return;
        var event: c.XEvent = undefined;
        var pending = c.XEventsQueued(dpy, c.QueuedAfterReading);
        while (pending > 0) : (pending = c.XEventsQueued(dpy, c.QueuedAlready)) {
            _ = c.XNextEvent(dpy, &event);
            switch (event.type) {
                c.ClientMessage => {
                    if (event.xclient.data.l[0] == @as(i64, @intCast(self.del_atom))) {
                        self.running = false;
                    }
                },
                c.ConfigureNotify => {
                    if (event.xconfigure.width != self.width or event.xconfigure.height != self.height) {
                        const width_changed = event.xconfigure.width != self.width;
                        self.width = event.xconfigure.width;
                        self.height = event.xconfigure.height;
                        self.resized = true;
                        if (width_changed) {
                            if (self.input_height == 1) self.applyInputHeight(1);
                            if (self.strut_enabled) self.applyStrut(true);
                        }
                    }
                },
                c.Expose => {
                    if (event.xexpose.count == 0) {
                        self.exposed = true;
                    }
                },
                c.EnterNotify => {
                    if (event.xcrossing.detail != c.NotifyInferior) {
                        self.pointer_inside = true;
                    }
                },
                c.LeaveNotify => {
                    if (event.xcrossing.detail != c.NotifyInferior and
                        event.xcrossing.mode != c.NotifyGrab)
                    {
                        self.pointer_inside = false;
                    }
                },
                c.ButtonPress => {
                    self.last_event_time = event.xbutton.time;
                    self.last_click = .{
                        .x = event.xbutton.x,
                        .y = event.xbutton.y,
                        .button = event.xbutton.button,
                    };
                    self.clicked = true;
                },
                c.SelectionRequest => {
                    self.handleSelectionRequest(&event.xselectionrequest);
                },
                c.PropertyNotify => {
                    const atom = event.xproperty.atom;
                    if (atom == self.net_active_window_atom or
                        atom == self.net_wm_name_atom or
                        atom == self.wm_name_atom)
                    {
                        self.title_dirty = true;
                    }
                },
                else => {},
            }
        }
    }

    /// `timeout_ms < 0` sleeps indefinitely in kernel `poll()` until an X11 event arrives.
    pub fn waitForEventsOrTimeout(self: *X11Backend, timeout_ms: i32) void {
        const dpy = self.display orelse return;
        if (timeout_ms == 0) {
            _ = c.XFlush(dpy);
            return;
        }
        if (c.XPending(dpy) > 0) return;

        var pfd = c.struct_pollfd{
            .fd = c.ConnectionNumber(dpy),
            .events = c.POLLIN,
            .revents = 0,
        };
        _ = c.poll(&pfd, 1, timeout_ms);
    }

    fn waitForMapNotify(_: ?*c.Display, ev: [*c]c.XEvent, arg: [*c]u8) callconv(.c) i32 {
        const handle = @as(*c.Window, @ptrCast(@alignCast(arg))).*;
        return if (ev.*.type == c.MapNotify and ev.*.xmap.window == handle) 1 else 0;
    }

    pub fn updateViewport(self: *const X11Backend) void {
        c.glViewport(0, 0, self.width, self.height);
    }

    pub fn swapBuffers(self: *const X11Backend) void {
        c.glXSwapBuffers(self.display, self.glx_handle);
    }

    pub fn setClipboard(self: *X11Backend, text: []const u8) void {
        if (text.len == 0) return;
        const dpy = self.display orelse return;
        if (self.handle == 0 or self.clipboard_atom == 0) return;

        const copy_len = @min(text.len, self.clipboard_buf.len);
        @memcpy(self.clipboard_buf[0..copy_len], text[0..copy_len]);
        self.clipboard_len = copy_len;

        _ = c.XSetSelectionOwner(dpy, self.clipboard_atom, self.handle, self.last_event_time);
        _ = c.XFlush(dpy);
    }

    fn handleSelectionRequest(self: *X11Backend, req: *const c.XSelectionRequestEvent) void {
        const dpy = self.display orelse return;
        const prop: c.Atom = if (req.property != c.None) req.property else req.target;

        var reply = std.mem.zeroes(c.XSelectionEvent);
        reply.type = c.SelectionNotify;
        reply.display = req.display;
        reply.requestor = req.requestor;
        reply.selection = req.selection;
        reply.target = req.target;
        reply.property = c.None;
        reply.time = req.time;

        if (req.selection == self.clipboard_atom and self.clipboard_len > 0) {
            if (req.target == self.targets_atom) {
                const targets = [_]c.Atom{
                    self.targets_atom,
                    self.utf8_string_atom,
                    c.XA_STRING,
                    self.text_atom,
                    self.text_plain_atom,
                    self.text_plain_utf8_atom,
                };
                _ = c.XChangeProperty(
                    dpy,
                    req.requestor,
                    prop,
                    c.XA_ATOM,
                    32,
                    c.PropModeReplace,
                    @ptrCast(&targets),
                    targets.len,
                );
                reply.property = prop;
            } else if (req.target == self.utf8_string_atom or
                req.target == c.XA_STRING or
                req.target == self.text_atom or
                req.target == self.text_plain_atom or
                req.target == self.text_plain_utf8_atom)
            {
                _ = c.XChangeProperty(
                    dpy,
                    req.requestor,
                    prop,
                    req.target,
                    8,
                    c.PropModeReplace,
                    &self.clipboard_buf,
                    @intCast(self.clipboard_len),
                );
                reply.property = prop;
            }
        }

        _ = c.XSendEvent(dpy, req.requestor, c.False, 0, @ptrCast(&reply));
        _ = c.XFlush(dpy);
    }
};
