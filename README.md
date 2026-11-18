# Droidspaces Anland 6.x RootFS Builder

[中文](README.zh-CN.md) · [Documentation](docs/en/README.md)

Builds ARM64 Linux RootFS images for [Droidspaces](https://github.com/ravindu644/Droidspaces-OSS)
targeting **Anland 6.x**, as separate Qualcomm and MediaTek variants.

## Quick start

Requirements: root (KernelSU / APatch / Magisk), Droidspaces, arm64.

MediaTek / Mali devices additionally need
[droidspaces-lkm](https://github.com/misaka5202/droidspaces-lkm), which ships
`mali_nsfix.ko` and loads it automatically on Mali platforms.

The stock MediaTek image renders through libhybris on the vendor Mali driver,
which is what gives hardware acceleration. `mali_nsfix` is required because
`mali_kbase` otherwise fails the pid lookup inside a PID namespace and
`eglInitialize` returns `0x3001`. See the
[desktop and Anland guide](docs/en/desktop-and-anland.md).

```bash
# 1. Import an image (Droidspaces imports .tar.xz, or subscribe to rootfs_en.json)

# 2. Host-side setup: module, APKs, daemon config, container bind mount
adb push scripts/setup-anland6-host.sh /data/local/tmp/
adb shell su -c 'sh /data/local/tmp/setup-anland6-host.sh'

# 3. Reboot — root managers only activate a module after a reboot
adb reboot

# 4. Verify the chain
adb push scripts/verify-anland6-host.sh /data/local/tmp/
adb shell su -c 'sh /data/local/tmp/verify-anland6-host.sh'
```

Applications are launched through `anland-shell`: container → `START` → `APPS` →
application. Each application gets its own Android window (`AwlWindowActivity`),
appears in Recents, supports split screen, and keeps its own IME state.

Host-side components, their roles and how they fail are covered in
[Host-side setup](#host-side-setup).

## Download list

| File | Source | Purpose |
| --- | --- | --- |
| `module/anland-awl.zip` | **[misaka5202/anland 6.2-ds2](https://github.com/misaka5202/anland/releases/tag/6.2-ds2)** | the `waylandbridge` daemon, with the IME fixes |
| `anland-wayland.apk` | same | `com.anlandnext`, the window consumer, with the extra-keys bar |
| `anland-shell.apk` | **[misaka5202/anland-shell v1.1-ds72](https://github.com/misaka5202/anland-shell/releases/tag/v1.1-ds72)** | patched build, see below |
| `anlandx.tar.gz` | **[misaka5202/anland 6.2-ds2](https://github.com/misaka5202/anland/releases/tag/6.2-ds2)** (also already inside the images built here) | the `anlandx` session inside the container |

### Why the modified build (misaka5202/anland)

The fork is required, not optional. Upstream 6.2 has three defects that make
desktop input unusable:

1. **Soft-keyboard text never reaches apps.** Apps that do not implement
   `zwp_text_input_v3` (terminals such as Konsole/XTerm) receive nothing:
   `awl_ime_text()` drops the commit when no text-input object is enabled.
   The fork degrades ASCII text to `wl_keyboard` key events, a path that was
   already proven to work (the Enter key uses it).
2. **Chinese input is impossible.** The daemon implements no
   `zwp_input_method_v2`, so a container IME (fcitx5) has no way to deliver
   composed text. The fork implements it.
3. **The extra-keys bar is partly dead.** Its leftmost column (ESC/TAB) sits
   inside the system back-gesture region, so the gesture swallows the touch.
   The fork insets the bar by `WindowInsets.Type.systemGestures()`.

Also included: the 5.x UI port (extra-keys bar, immersive mode with adjustable
opacity), i18n for the added strings, and a complete evdev scan-code mapping
for IME-synthesised key events (they always carry `scanCode == 0`).

Built from `main`; `6.2-ds2` is the current release. If you only need the
stock 6.2 behaviour, use
[SuperTurtleDev/anland 6.2](https://github.com/SuperTurtleDev/anland/releases/tag/6.2)
instead — but expect the input problems above.

### anland-shell needs the patched build

Upstream 1.1 (2026-09-17) calls `droidspaces show --format`:

```java
RootExec.exec(bin + " show --format", 15_000);
```

Droidspaces 7.2.0 (2026-11-07) removed that option in favour of `show --json`.
The old flag writes `Unknown or incomplete option: --format` to stdout while
still exiting 0, so the running set parses as empty, every container shows
`stopped`, and the `APPS` entry point is blocked.

Upstream PR [SuperTurtleDev/anland-shell#2](https://github.com/SuperTurtleDev/anland-shell/pull/2)
(2026-11-13) fixes it; it is not merged.

`v1.1-ds72` changes: prefer `show --json`, fall back to `show --format`, strip
ANSI escapes before parsing. Verified on OPPO PHZ110 / MT6989 / Android 17 /
Droidspaces 7.2.0.

To decide whether the patched build is needed:

```bash
su -c 'droidspaces show --json'    # produces output
su -c 'droidspaces show --format'  # Unknown or incomplete option
```

`setup-anland6-host.sh` reads the Droidspaces version and picks the patched
build at ≥7.2.0 automatically.

## Differences from 5.x

| | Anland 5.x (old line) | Anland 6.x (this repository) |
|---|---|---|
| Display protocol | private Anland Display Protocol | **Wayland itself** |
| Compositor | requires a **patched KWin** | stock compositor, unmodified |
| Connection | `/run/display.sock` plus a bind mount | fd over binder, **no socket file** |
| Windows | the whole screen mapped to one Android window | **one real Android window per window** |
| Container side | none (relies on the patched compositor) | `anlandx` session (wayland link + rootless Xwayland + mini-wm) |

The 5.x patched KWin is not in the public `anland-kde-packages`. After
installing those debs, the `kwin_wayland` binary contains no anland string at
all — the session starts but has no output path. This repository takes the 6.x
line and avoids that dead end.

## Host-side setup

Four components on the host. Missing any one of them means no picture.

| # | File | Install | Role | Without it |
| --- | --- | --- | --- | --- |
| 1 | `module/anland-awl.zip` | flash in the root manager, **reboot** | `waylandbridge`: the Wayland server, accepts clients, creates a window when the first frame arrives | no socket, the container session never starts |
| 2 | `anland-wayland.apk` | `pm install` | `com.anlandnext`: one `AwlWindowActivity` per window | applications start, no window appears |
| 3 | `anland-shell.apk` | `pm install` plus root grant | `com.anland.shell`: list containers / list applications / launch | no launch entry point |
| 4 | `anlandx.tar.gz` | already inside the images built here | the `anlandx` session inside the container (wayland link + rootless Xwayland + mini-wm) | no `anland-session` |

For external images, component 4 must be installed by hand:

```bash
tar xzf anlandx.tar.gz && bash anlandx/setupanlandx.sh
```

### Automated setup

```bash
adb push scripts/setup-anland6-host.sh /data/local/tmp/
adb shell su -c 'sh /data/local/tmp/setup-anland6-host.sh'
```

Idempotent. It installs the module (`ksud module install`, or extract into
`/data/adb/modules/`), installs the APKs, writes daemon configuration
(`auto_attach=1`, `scale_mode=1`), and adds the container bind mount.

### Manual setup

**1. The `anland-awl` module**

A reboot is required after flashing. While the module sits in `modules_update/`,
`waylandbridge` does not run and `/data/local/tmp/awl/wayland-0` does not exist.
After rebooting:

```bash
su -c 'pidof waylandbridge'
su -c 'ls -l /data/local/tmp/awl/wayland-0'   # srw-rw-rw-
su -c 'service list | grep anland.host'
```

**2. Host APKs**

```bash
pm install -r anland-wayland.apk
pm install -r anland-shell.apk
```

`com.anland.shell` needs a root grant; without it `/data/local/Droidspaces/Containers`
is unreadable and the app reports `no containers defined`.

**3. Container bind mount**

The daemon publishes at `/data/local/tmp/awl/wayland-0` (the `runtime_dir` in
`config.json`), while `anland-session` inside the container hardcodes
`/run/anland/wayland-0`. The container's `/run` is a private tmpfs, so the two
are not shared and the mount has to be explicit:

```bash
su -c 'droidspaces --name=<name> -B /data/local/tmp/awl:/run/anland start'
```

Or persist it in `container.config`:

```ini
bind_mounts=/data/local/tmp/awl:/run/anland
```

Droidspaces persists that field, so `-B` is not needed on later starts. Without
it the container reports
`no wayland socket at /run/anland/wayland-0 (anland daemon down?)` — the
`daemon down?` part is wrong, the daemon is running fine. To check:

```bash
su -c 'droidspaces --name=<name> run -- ls -l /run/anland/wayland-0'
```

The Droidspaces binary has no `/run/anland` handling (`strings` finds zero
occurrences); it only knows the 5.x `/run/display.sock`, so this mount is never
added automatically. The `socket_listen=0` binder-fd mode requires the client to
speak Android binder directly, which Linux applications in a container do not.

**4. Container configuration**

Enable hardware access (`--hw-access` / `--gpu`) and privileged mode, and tick
`nocaps` and `noseccomp`.

## Launching applications

Launch through `anland-shell`, not by starting processes inside the container
directly. The host daemon needs the client to carry the full session
environment: `anland-shell` injects `XDG_RUNTIME_DIR`, `WAYLAND_DISPLAY` and
`DBUS_SESSION_BUS_ADDRESS`, and starts through the **systemd user session**
(`systemd-run --user`).

```text
anland-shell → container → START → APPS → application
```

Launch problems:

| Symptom | Cause | Fix |
| --- | --- | --- |
| container shows `stopped` while it runs | anland-shell incompatible with Droidspaces ≥7.2.0 | use `v1.1-ds72` |
| `no containers defined` | `com.anland.shell` has no root | grant root |
| `APPS` reports `Anlandx not installed` | container not running | `START` first |
| clicks do nothing | see the next section | read the daemon log |

Suggested Window Settings for `com.anlandnext`:

| Setting | Value | Why |
| --- | --- | --- |
| Window scaling | `Fit` | the default `Stretch` fills both axes independently; `init_w/h` defaults to 800×600, which on a 1264×2780 portrait screen stretches vertically by 4.6× |
| Auto attach new windows | on | when off, a window waits for the app to supply a SURFACE over binder |

Both apply immediately and persist (`config set scale_mode=N (applied + persisted)`).

### When there is no picture

Daemon log landmarks:

```bash
logcat -d | grep 'anland-wl:' | tail -20
```

| Log line | Meaning |
| --- | --- |
| `surface N created` | client connected; only a surface exists |
| `surface N mapped (role=1)` | first frame committed; this triggers window creation |
| `window WxH attached` | the Android window is attached |

`created` without `mapped`: the client never committed a buffer, so the problem
is on the application side. `mapped` without `window attached`: the
`com.anlandnext` side.

MediaTek / Mali devices have three additional requirements (the `mali_nsfix`
module, `AWL_NO_SCANOUT`, and `sc_enabled`); see the
[desktop and Anland guide](docs/en/desktop-and-anland.md#mediatek--mali-devices).

## GPU variants

Two variants, because the two GPU vendors need opposite driver setups:

| Filename contains | For | Rendering |
|---|---|---|
| `-qualcomm-` | Snapdragon / Adreno | Mesa freedreno/kgsl plus turnip, hardware accelerated |
| `-mediatek-` | MediaTek / Mali | libhybris driving the vendor Mali driver on `/dev/mali0` (hardware) |

The 6.x container session is itself GPU-neutral (`ANLAND_XWAYLAND=0`, using the
distribution's own Xwayland); the GPU difference lives only in the Mesa layer,
handled by `configure-gpu`. The host-side compositor is a separate matter — it
uses the vendor GPU driver on both platforms.

## Building

Actions → “发布全桌面 Wayland RootFS（高通 + MTK 双版本）” → leave `gpu_vendor` on `both`.

For a single combination, use the single-target workflow and set `gpu_vendor`.

Inputs added for 6.x:

| Input | Default | Meaning |
|---|---|---|
| `anland_major` | `6` | 6 = anlandx session; 5 = the old patched-KWin line (kept for comparison) |
| `anland6_version` | `6.2` | anland release tag |

## Support matrix

- Anland 6.x: Debian 13, Ubuntu 26, Fedora 43/44, Arch Linux ARM
- Ubuntu 24 / 25 do not support Anland (upstream limitation)
- **Android 14 (API 34) or newer.** anland6's user-space daemon calls
  `ANativeWindow_readFromParcel`, an API 34 symbol, with no fallback. On
  Android 13 it fails to load:
  `CANNOT LINK EXECUTABLE ... cannot locate symbol "ANativeWindow_readFromParcel"`.
  Upstream has no plan to support Android 13
  ([SuperTurtleDev/anland#112](https://github.com/SuperTurtleDev/anland/issues/112)).
  Note this is unrelated to `droidspaces-lkm`'s KMI matrix: those Android
  12/13 entries are **kernel-module** side only.

## Layout

```
scripts/tui/install-anland6.sh       installs the anlanx session — the core change here
scripts/configure-anland6-env.sh     clears the 5.x environment variables
scripts/start-desktop-session.sh     launches anland-session under 6.x
scripts/desktops/*.sh                per-desktop package lists and environment (6.x: applications only)
scripts/tui/configure-gpu.sh         Mesa and rendering setup per GPU vendor
```

## License

Inherited from upstream; see LICENSE.
