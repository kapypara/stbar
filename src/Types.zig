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

pub const BarMode = enum {
    /// Overlay (`strut = OFF`): hides to 1px edge strip (`0 Hz` `poll(-1)` sleep) and fades in after hover delay.
    auto_hide,
    /// Overlay (`strut = OFF`): stays visible without auto-hiding (toggled via right-click / `SIGUSR1`).
    pinned_overlay,
    /// Dock (`strut = ON`): reserves exclusive zone / strut and stays visible (toggled via middle-click / `SIGUSR2`).
    docked_strut,
};

pub const BackendPreference = enum {
    /// Prefer native Wayland `zwlr_layer_shell_v1` + `wl_shm` when `WAYLAND_DISPLAY` is active,
    /// falling back to `wayland-egl`, `x11` (`MIT-SHM`), or `x11-glx` automatically.
    auto,
    /// Native Wayland `zwlr_layer_shell_v1` + `wl_shm` (single-threaded, <1 MB private RSS, zero Mesa load).
    wayland,
    /// Native Wayland `zwlr_layer_shell_v1` + `EGL` / OpenGL 3.2 Core (`-Dgpu=true`).
    wayland_egl,
    /// Native X11 / Xwayland + `MIT-SHM` (`XShmPutImage`, single-threaded, <1 MB private RSS, zero Mesa load).
    x11,
    /// Force X11 / Xwayland + `GLX` / OpenGL 3.2 Core (`-Dgpu=true`).
    x11_glx,
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
