const std = @import("std");
const stbar_v4 = @import("stbar_v4");
const Renderer = @import("Renderer.zig").Renderer;

// Import the C/C++ headers
// const c = @cImport({
//     @cInclude("font.h");
//     @cInclude("gl/texture.h");
//     @cInclude("output.h");
//     @cInclude("static_rect.h");
//     @cInclude("types.h");
//     @cInclude("GL/glew.h"); // For GL_COLOR_BUFFER_BIT etc.
// });

pub fn main() !void {
    // Prints to stderr, ignoring potential errors.
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});
    try stbar_v4.bufferedPrint();

    // 1. Initialize Renderer
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // 1. Initialize the struct
    var renderer = Renderer{
        .window = .{}, // Default Window values
    };
    
    // 2. Setup your mode
    renderer.window.docked = true;
    
    // 3. Call Init
    try renderer.init(0, 0, 1920, 30);
    defer renderer.window.deinit(); // Clean up X11/GL resources

    // 4. Main Loop
    while (renderer.window.running) {
        renderer.handleEvents(); // Internally calls window.updateTheMessageQueue
        
        renderer.update();
        renderer.render();
        renderer.swap();
        
        // Optional: slow down loop
        std.time.sleep(16 * std.time.ns_per_ms); 
    }
    
    // Zig calls to C++ methods require a wrapper (see Step 2 below)
    // c.renderer_setWindow(&ren, 0, 0, 1920, 14 + 3);
    // c.renderer_setDockMode(&ren);
    // c.renderer_init(&ren);

    // c.glClearColor(0, 0, 0, 0);
    // c.glClear(c.GL_COLOR_BUFFER_BIT);

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

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
