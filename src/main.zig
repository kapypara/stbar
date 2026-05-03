const std = @import("std");
const Window = @import("Window.zig").Window;
const Ticker = @import("Ticker.zig").Ticker;

pub fn main() !void {
    // Prints to stderr, ignoring potential errors.
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    // 1. Initialize Renderer
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // 1. Initialize the struct
    var window = Window{
        .docked = true,
    };

    // 3. Call Init
    try window.init(0, 0, 1920, 30);
    defer window.deinit(); // Clean up X11/GL resources

    var ticker = try Ticker(60, 10).init();
    var isWorkTick = true;

    // 4. Main Loop
    while (window.running) {
        window.updateTheMessageQueue();
        
        if (isWorkTick) {
            std.debug.print("Work Time !!\n", .{});
            window.updateViewport();

            // TODO add render code
            // renderer.render();
        }

        // optional swap code
        // window.swapBuffers();
        isWorkTick = ticker.tick();
    }
    
    // 2. Setup Static Rect
    // var dp: c.static_rect = undefined;
    // c.static_rect_build(&dp);
    
    // if (!c.static_rect_is_ready(&dp)) {
    //     return error.StaticRectNotReady;
    // }

    // background: vec4 is likely a struct {x, y, z, w}
    // c.static_rect_setBackgroundColor(&dp, .{ .x = 0.0, .y = 0.0, .z = 0.0, .w = 0.4666 });

    // 3. Texture and Font
    // var font_texture: c.GL_texture = undefined;
    // c.texture_create(&font_texture);
    // c.texture_load(&font_texture, "assets/font/tamzen.png");

    // c.static_rect_setTexture(&dp, &font_texture);
    // c.static_rect_bindTexture(&dp);

    // var font_glyphs: c.font = undefined;
    // c.font_load(&font_glyphs, "assets/font/tamzen.json");

    // const tex_char_size = c.vec2{
    //     .x = c.font_getRelativeWidth(&font_glyphs),
    //     .y = c.font_getRelativeHeight(&font_glyphs),
    // };

    // c.static_rect_setTextureSize(&dp, tex_char_size);

    // 4. Output
    // var bar: c.output_line = undefined;
    // c.output_line_init(&bar, &ren, &dp, &font_glyphs, 8, 60);
    // c.output_line_output(&bar);

    std.debug.print("Bar initialized successfully.\n", .{});
}
