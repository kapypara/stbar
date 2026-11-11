# zigbar

Ultra-low-overhead Linux status bar written in **Zig 0.17.1**, supporting native **Wayland (`zwlr_layer_shell_v1` + `EGL`)** and **X11 (`EWMH` + `GLX`)** in a single standalone executable with zero external runtime files.

## Highlights

- **Standalone Single Binary:** `assets/font/tamzen.json` and `assets/font/tamzen.png` are baked into `.rodata` at build time (`tools/bake_font.zig`), requiring zero external assets or Zig package dependencies at runtime.
- **Zero Polling While Hidden:** In `auto-hide` mode, `zigbar` shrinks its input region to a `1px` top-edge strip and suspends indefinitely inside kernel `poll(..., -1)` (`0 Hz` timers, `0` `/proc` reads, `0` GPU draws). Last-viewed metric state is preserved across sleep so revealing the bar glimpses its previous state and smoothly catches up at VSync.
- **Framerate-Free Hardware VSync Interpolation:** Samples live Linux metrics (`/proc/stat`, `/proc/meminfo`, `/proc/diskstats`, `/proc/net/dev`, `/proc/self/mountinfo`, `/sys/class/hwmon`, `sysinfo`, `localtime_r`) at `8 Hz` while visible and interpolates `prev -> target` smoothly locked to your monitor's native VSync refresh rate when values change — sleeping in `poll()` whenever steady.
- **Native Wayland & X11 Window Titles + Struts:**
  - **Wayland Layer-Shell:** Real `17px` exclusive-zone top struts on KDE Plasma 6 Wayland, Sway, Hyprland, River, Niri, and Labwc.
  - **Event-Driven Window Titles:** Uses `zwlr_foreign_toplevel_management_v1` on wlroots compositors, event-driven `org.kde.kwin.Scripting` (`sd-bus`) on KDE Plasma Wayland (covering both native Wayland and Xwayland apps), and `PropertyChangeMask` (`_NET_ACTIVE_WINDOW`) on X11.

## Build & Install

### System Dependencies (Arch Linux)

```bash
sudo pacman -S wayland wayland-protocols libglvnd libx11 libxrender libxext systemd-libs
```

### Compile Standalone Binary

```bash
zig build -Doptimize=ReleaseFast
install -Dm755 zig-out/bin/zigbar ~/.local/bin/zigbar
```

Run unit tests:

```bash
zig build test --summary all
```

## CLI Usage & Controls

```text
Usage: zigbar [options]

Options:
  -m, --mode=<auto-hide|pinned|dock>   Startup bar mode (default: auto-hide)
  -b, --backend=<auto|wayland|x11>     Display backend (default: auto)
      --hz=<1..60>                     Metric sample rate while visible (default: 8)
  -h, --help                           Show help message and exit
```

### Mouse Controls

| Action | Behavior |
| :--- | :--- |
| **Hover top `1px` (`> 1.0s`)** | Smoothly fades in the bar (`auto-hide` mode); fades out `120ms` after pointer leaves |
| **Right-click** | Toggles **`pinned`** overlay (`strut = OFF`, always visible) <-> **`auto-hide`** |
| **Middle-click** | Toggles **`dock`** mode (`17px` top `exclusive_zone` / `_NET_WM_STRUT_PARTIAL` `strut = ON`) <-> **`auto-hide`** |

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
