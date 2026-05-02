const std = @import("std");
const Window = @import("Window.zig");

// Import your C headers
const c = @cImport({
    @cInclude("GL/glew.h");
    @cInclude("GL/glx.h");
});

pub const Renderer = struct {
    window: Window.Window, // Composition instead of inheritance
    initialized: bool = false,

    pub fn init(self: *Renderer, x: i32, y: i32, width: i32, height: i32) void {
        self.window.setWindow(x, y, width, height);

        self.window.createTheWindow();
        self.window.createTheRenderContext();

        c.glewExperimental = c.GL_TRUE;
        _ = c.glewInit();
        
        self.initialized = true;
    }

    pub fn update(self: *Renderer) void {
        c.glViewport(0, 0, self.window.width, self.window.height);
    }

    pub fn swap(self: *Renderer) void {
        c.glXSwapBuffers(self.window.Xdisplay, self.window.glX_window_handle);
    }
};
