pub const uv_solid: [2]u16 = .{ 65535, 65535 };
pub const uv_empty: [2]u16 = .{ 0, 65535 };

pub const QuadVertex = extern struct {
    size: [2]f32,
    pos: [2]i16,
    uv: [2]u16,
    color: [4]u8,
};

pub const Click = struct {
    x: i32 = 0,
    y: i32 = 0,
    button: u32 = 0,
};

pub const BarPosition = enum {
    top,
    bottom,
};

pub const MarqueeMode = enum {
    smooth,
    snap,
};

pub const TitleClip = struct {
    quad_start: usize = 0,
    quad_end: usize = 0,
    min_ndc_x: i16 = -32768,
    max_ndc_x: i16 = 32767,
    clear_min_ndc_x: i16 = -32768,
    clear_max_ndc_x: i16 = 32767,
    bg_color: [4]u8 = .{ 0, 0, 0, 0 },
};
