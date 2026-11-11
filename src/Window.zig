const std = @import("std");

pub const c = @import("c");

const USE_GLX_CREATE_WINDOW = 1;

pub const Window = struct {
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
    net_active_window_atom: c.Atom = 0,
    net_wm_name_atom: c.Atom = 0,
    wm_name_atom: c.Atom = 0,

    width: i32 = 800,
    height: i32 = 600,
    x: i32 = 100,
    y: i32 = 100,

    running: bool = true,
    docked: bool = false,
    clicked: bool = false,
    resized: bool = false,
    title_dirty: bool = true,
    last_click: Click = .{ .x = 0, .y = 0, .button = 0 },

    const Click = struct { x: i32, y: i32, button: u32 };

    pub fn init(self: *Window, x: i32, y: i32, width: i32, height: i32) !void {
        self.x = x;
        self.y = y;
        self.width = width;
        self.height = height;

        try self.createTheWindow();
        try self.createTheRenderContext();
    }

    pub fn deinit(self: *Window) void {
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

    pub fn createTheWindow(self: *Window) !void {
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
            c.GLX_DOUBLEBUFFER,  c.False,
            c.GLX_RED_SIZE,      8,
            c.GLX_GREEN_SIZE,    8,
            c.GLX_BLUE_SIZE,     8,
            c.GLX_ALPHA_SIZE,    8,
            c.GLX_DEPTH_SIZE,    16,
            c.None,
        };

        var num_configs: i32 = 0;
        const fbconfigs = c.glXChooseFBConfig(dpy, self.x_screen, &vis_attribs, &num_configs);
        if (fbconfigs == null or num_configs == 0) return error.NoFBConfigs;
        defer _ = c.XFree(@ptrCast(fbconfigs));

        // Find visual with Alpha
        var found = false;
        for (0..@intCast(num_configs)) |i| {
            const vis = c.glXGetVisualFromFBConfig(dpy, fbconfigs[i]);
            if (vis == null) continue;
            defer _ = c.XFree(vis);

            const pf = c.XRenderFindVisualFormat(dpy, vis.*.visual);
            if (pf != null and pf.*.direct.alphaMask > 0) {
                self.fbconfig = fbconfigs[i];
                // We must store a copy of VisualInfo if we need it later, 
                // but for XCreateWindow we just need the fields.
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
            dpy, self.root,
            self.x, self.y, @intCast(self.width), @intCast(self.height),
            0, self.visual.?.depth, c.InputOutput, self.visual.?.visual,
            c.CWColormap | c.CWBorderPixel | c.CWEventMask,
            &attr,
        );

        if (self.handle == 0) return error.CreateWindowFailed;

        // In your C++ code: glX_window_handle = window_handle (if USE_GLX_CREATE_WINDOW is 0)
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

        // Porting the Dock logic
        if (self.docked) {
            const window_type = c.XInternAtom(dpy, "_NET_WM_WINDOW_TYPE", 0);
            const dock_type = c.XInternAtom(dpy, "_NET_WM_WINDOW_TYPE_DOCK", 0);
            _ = c.XChangeProperty(dpy, self.handle, window_type, c.XA_ATOM, 32, c.PropModeReplace, @ptrCast(&dock_type), 1);

            const window_state = c.XInternAtom(dpy, "_NET_WM_STATE", 0);
            const states = [_]c.Atom{
                c.XInternAtom(dpy, "_NET_WM_STATE_STICKY", 0),
                c.XInternAtom(dpy, "_NET_WM_STATE_ABOVE", 0),
                c.XInternAtom(dpy, "_NET_WM_STATE_STAYS_ON_TOP", 0),
            };
            _ = c.XChangeProperty(dpy, self.handle, window_state, c.XA_ATOM, 32, c.PropModeAppend, @ptrCast(&states), 3);

            const wm_desktop = c.XInternAtom(dpy, "_NET_WM_DESKTOP", 0);
            const all_desktops: u32 = 0xFFFFFFFF;
            _ = c.XChangeProperty(dpy, self.handle, wm_desktop, c.XA_CARDINAL, 32, c.PropModeReplace, @ptrCast(&all_desktops), 1);

            // --- STRUT LOGIC FOR TOP DOCK ---
            const wm_strut = c.XInternAtom(dpy, "_NET_WM_STRUT", 0);
            const wm_strut_partial = c.XInternAtom(dpy, "_NET_WM_STRUT_PARTIAL", 0);

            var strut = std.mem.zeroes([12]c.u_long); 

            // 1. Tell the WM to reserve 'y + height' pixels from the TOP edge (index 2)
            strut[2] = @intCast(self.y + self.height); 

            // 2. Tell the WM the horizontal start/end of this top strut (indices 8 and 9)
            // This ensures it reserves space across the entire width of your screen.
            strut[8] = @intCast(self.x);                       // top_start_x
            strut[9] = @intCast(self.x + self.width - 1);       // top_end_x

            // _NET_WM_STRUT expects 4 values (left, right, top, bottom)
            _ = c.XChangeProperty(dpy, self.handle,
                wm_strut, c.XA_CARDINAL,
                32, c.PropModeReplace,
                @ptrCast(&strut), 4
            );

            // _NET_WM_STRUT_PARTIAL expects all 12 values
            _ = c.XChangeProperty(dpy, self.handle,
                wm_strut_partial, c.XA_CARDINAL,
                32, c.PropModeReplace,
                @ptrCast(&strut), 12
            );
        }

        _ = c.XMapWindow(dpy, self.handle);
        var ev: c.XEvent = undefined;
        _ = c.XIfEvent(dpy, &ev, waitForMapNotify, @ptrCast(&self.handle));

        self.del_atom = c.XInternAtom(dpy, "WM_DELETE_WINDOW", 0);
        _ = c.XSetWMProtocols(dpy, self.handle, &self.del_atom, 1);

        self.net_active_window_atom = c.XInternAtom(dpy, "_NET_ACTIVE_WINDOW", c.False);
        self.net_wm_name_atom = c.XInternAtom(dpy, "_NET_WM_NAME", c.False);
        self.wm_name_atom = c.XInternAtom(dpy, "WM_NAME", c.False);
        _ = c.XSelectInput(dpy, self.root, c.PropertyChangeMask);
    }

    pub fn createTheRenderContext(self: *Window) !void {
        const dpy = self.display orelse return error.NoDisplay;

        self.render_context = c.glXCreateNewContext(dpy, self.fbconfig, c.GLX_RGBA_TYPE, null, c.True);
        
        if (self.render_context == null) return error.ContextCreationFailed;

        if (c.glXMakeContextCurrent(dpy, self.glx_handle, self.glx_handle, self.render_context) == 0) {
            return error.MakeContextCurrentFailed;
        }

        if (USE_GLX_CREATE_WINDOW == 1) {
            c.glewExperimental = c.GL_TRUE;
            _ = c.glewInit();
        }
    }

    pub fn updateTheMessageQueue(self: *Window) void {
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
                        self.width = event.xconfigure.width;
                        self.height = event.xconfigure.height;
                        self.resized = true;
                    }
                },
                c.ButtonPress => {
                    self.last_click = .{
                        .x = event.xbutton.x,
                        .y = event.xbutton.y,
                        .button = event.xbutton.button,
                    };
                    self.clicked = true;
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

    fn waitForMapNotify(_: ?*c.Display, ev: [*c]c.XEvent, arg: [*c]u8) callconv(.c) i32 {
        const handle = @as(*c.Window, @ptrCast(@alignCast(arg))).*;
        return if (ev.*.type == c.MapNotify and ev.*.xmap.window == handle) 1 else 0;
    }

    pub fn updateViewport(self: *Window) void {
        c.glViewport(0, 0, self.width, self.height);
    }

    pub fn swapBuffers(self: *Window) void {
        c.glXSwapBuffers(self.display, self.glx_handle);
    }
};
