const std = @import("std");
const zigimg = @import("zigimg");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Texture = struct {

    allocator: Allocator = undefined,

    width: u16 = undefined,
    height: u16 = undefined,
    rgba: []u8 = undefined,

    pub fn init(io: Io, allocator: Allocator, image_path: []const u8) !Texture {

        var read_buffer: [zigimg.io.DEFAULT_BUFFER_SIZE]u8 = undefined;

        var image = try zigimg.Image.fromFilePath(
            allocator, 
            io,
            image_path, 
            &read_buffer
        );
        defer image.deinit(allocator);

        // 3. Force conversion to RGBA 32-bit (8 bits per channel)
        // This safely normalizes grayscale or RGB inputs into RGBA
        try image.convert(allocator, .rgba32);

        // 4. Access the raw byte data
        // Under the hood, image.pixels.rgba32 is a slice of zigimg.color.Rgba32
        // const pixel_count = image.width * image.height;
        const raw_pixels: []zigimg.color.Rgba32 = image.pixels.rgba32;
        const flat_bytes: []const u8 = std.mem.sliceAsBytes(raw_pixels);

        std.debug.print("Successfully loaded image!\n", .{});
        std.debug.print("Dimensions: {}x{}\n", .{image.width, image.height});
        std.debug.print("Total pixel structs: {}\n", .{raw_pixels.len});

        const owned_rgba = try allocator.alloc(u8, flat_bytes.len);
        @memmove(owned_rgba, flat_bytes);

        return .{
            .allocator = allocator,

            .height = @intCast(image.height),
            .width = @intCast(image.width),
            .rgba = owned_rgba,
        };

        // 5. Example: Read the top-left pixel
        // if (pixel_count > 0) {
        //     const first_pixel = raw_pixels[0];
        //     std.debug.print("Top-Left Pixel - R: {}, G: {}, B: {}, A: {}\n", .{
        //         first_pixel.r,
        //         first_pixel.g,
        //         first_pixel.b,
        //         first_pixel.a,
        //     });
        // }

        // 6. Need it as a flat []u8 array for WebGL / OpenGL / Vulkan?
        // You can safely cast the slice because Rgba32 is a tightly packed extern struct
        // const flat_bytes: []u8 = std.mem.sliceAsBytes(raw_pixels);
        // std.debug.print("Total raw byte array length: {}\n", .{flat_bytes.len});
        // return flat_bytes;
    }

    pub fn deinit(self: *Texture) void {
        self.allocator.free(self.rgba);
    }
};
