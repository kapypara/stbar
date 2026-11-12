# zigbar

Ultra-low-overhead Linux status bar written in **Zig 0.17.1**, supporting native **Wayland `wl_shm` (`zwlr_layer_shell_v1`)**, **X11 `MIT-SHM` (`EWMH` + `XShmPutImage`)**, **Wayland `EGL`**, and **X11 `GLX`** in a single standalone executable with zero external runtime files.

## Highlights

- **Single-Threaded Native `wl_shm` & `MIT-SHM` Renderers (`<1 MB` Private RSS, `1` Thread):** Default Wayland (`wl_shm`) and X11 (`XShmPutImage`) backends render glyphs directly from L1-cached 2-bit `.rodata` into shared memory without loading Mesa/GPU drivers, submitting cell-level damage rectangles (`wl_surface_damage_buffer` / `XShmPutImage`) — while preserving `wayland-egl` and `x11-glx` OpenGL 3.2 backends in the same binary.
- **Standalone Single Binary:** `assets/font/tamzen.json` and `assets/font/tamzen.png` are baked into `.rodata` at build time (`tools/bake_font.zig`), requiring zero external assets or Zig package dependencies at runtime.
- **Zero Polling While Hidden:** In `auto-hide` mode, `zigbar` shrinks its input region to a `1px` top-edge strip and suspends indefinitely inside kernel `poll(..., -1)` (`0 Hz` timers, `0` `/proc` reads, `0` GPU draws). Last-viewed metric state is preserved across sleep so revealing the bar glimpses its previous state and smoothly catches up at VSync.
- **Framerate-Free Hardware VSync Interpolation:** Samples live Linux metrics (`/proc/stat`, `/proc/meminfo`, `/proc/diskstats`, `/proc/net/dev`, `/proc/self/mountinfo`, `/sys/class/hwmon`, `sysinfo`, `localtime_r`) at `8 Hz` while visible and interpolates `prev -> target` smoothly locked to your monitor's native VSync refresh rate when values change — sleeping in `poll()` whenever steady.
- **Native Wayland & X11 Window Titles, HiDPI, + Struts:**
  - **Fractional & Integer Wayland HiDPI:** Native `wp_fractional_scale_v1` + `wp_viewporter` + `wl_compositor` v6 (`preferred_buffer_scale` / `wl_output.scale`) buffer scaling with bit-exact `2x`/`3x` integer blocks and sub-texel box-coverage antialiasing at fractional scales (`125%`, `150%`, `175%`).
  - **Wayland Layer-Shell:** Real `17px` exclusive-zone top struts on KDE Plasma 6 Wayland, Sway, Hyprland, River, Niri, and Labwc, with seamless DPMS sleep & monitor hotplug recovery.
  - **Event-Driven Window Titles:** Uses `zwlr_foreign_toplevel_management_v1` on wlroots compositors, event-driven `org.kde.kwin.Scripting` (`sd-bus`) on KDE Plasma Wayland (covering both native Wayland and Xwayland apps), and `PropertyChangeMask` (`_NET_ACTIVE_WINDOW`) on X11.

## Build & Install

### System Dependencies (Arch Linux)

```bash
sudo pacman -S wayland wayland-protocols libglvnd libx11 libxrender libxext systemd-libs
```

### Compile Standalone Binary

```bash
zig build
install -Dm755 zig-out/bin/zigbar ~/.local/bin/zigbar
```

> `zig build` defaults to native `ReleaseFast` (`-O3` + fast-math + native host SIMD + full LTO + frame-pointer omission + stripped symbols). Pass `-Doptimize=Debug` for debug builds.

Run unit tests:

```bash
zig build test -Doptimize=Debug --summary all
```

## CLI Usage & Controls

```text
Usage: zigbar [options]

Options:
  -m, --mode=<auto-hide|pinned|dock>                     Startup bar mode (default: auto-hide)
  -b, --backend=<auto|wayland|wayland-egl|x11|x11-glx>   Display backend (default: auto)
  -o, --output=<connector>                               Target Wayland output (e.g. eDP-1, DP-1; default: primary)
      --hz=<1..60>                                       Metric sample rate while visible (default: 8)
  -h, --help                                             Show help message and exit
```

### Mouse & Signal Controls

| Action / Signal | Behavior |
| :--- | :--- |
| **Hover top `1px` (`> 1.0s`)** | Smoothly fades in the bar (`auto-hide` mode); fades out `120ms` after pointer leaves |
| **Left-click segment** | Runs declarative segment action (copy Unix time / power summary / window title, launch `btop` / `dolphin`) |
| **Right-click** / `pkill -USR1 -x zigbar` | Toggles **`pinned`** overlay (`strut = OFF`, always visible) <-> **`auto-hide`** |
| **Middle-click** / `pkill -USR2 -x zigbar` | Toggles **`dock`** mode (`17px` top `exclusive_zone` / `_NET_WM_STRUT_PARTIAL` `strut = ON`) <-> **`auto-hide`** |

## Autostart with `systemd --user`

Install and enable the bundled user service (`systemd/zigbar.service`) so `zigbar` starts automatically with your graphical Wayland/X11 session:

```bash
install -Dm755 zig-out/bin/zigbar ~/.local/bin/zigbar
install -Dm644 systemd/zigbar.service ~/.config/systemd/user/zigbar.service
systemctl --user daemon-reload
systemctl --user enable --now zigbar.service
```

Check status or switch startup flags:

```bash
systemctl --user status zigbar.service
systemctl --user restart zigbar.service
```
