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

        // Access the raw byte data
        const raw_pixels: []zigimg.color.Rgba32 = image.pixels.rgba32;
        const flat_bytes: []const u8 = std.mem.sliceAsBytes(raw_pixels);

        const owned_rgba = try allocator.alloc(u8, flat_bytes.len);
        @memmove(owned_rgba, flat_bytes);

        return .{
            .allocator = allocator,
            .height = @intCast(image.height),
            .width = @intCast(image.width),
            .rgba = owned_rgba,
        };
    }

    pub fn deinit(self: *Texture) void {
        self.allocator.free(self.rgba);
    }
};
