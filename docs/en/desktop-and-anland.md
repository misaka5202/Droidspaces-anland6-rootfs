[Documentation index](README.md) · [Project home](../../README_english.md)

# Desktop Startup and Anland Wayland

## Desktop auto-start

When `desktop_autostart` is enabled, the RootFS installs `desktop-session.service`. It runs the session as UID 1000 and reads `/etc/droidspaces-desktop.conf` to select the desktop.

| Desktop and backend | Manual command |
| --- | --- |
| KDE + X11 (unsupported on Arch) | `DISPLAY=:5 startplasma-x11` |
| KDE + Anland Wayland | `startplasma-wayland` |
| KDE Mobile + Anland Wayland | `startplasmamobile` |
| GNOME + Anland Wayland | `gnome-session --session=gnome` |
| Anland Next | `/usr/bin/anland-session` |
| Niri | `/usr/bin/niri-anland` |
| Hyprland | `/usr/bin/hyprland-anland` |
| Mango | `/usr/bin/mango-anland` |
| Denial | `/usr/bin/denial-anland` |

After an unexpected exit, systemd retries after 2 seconds. More than 5 failures within 60 seconds pauses retries. A normal exit does not restart the session.

### X11

X11 uses `DISPLAY=:5`; install and start Termux:X11 on Android. If auto-start is disabled, run this in the container:

```bash
startplasma-x11
```

### Anland Wayland host setup

> **This section covers Anland 6.x only.** If you followed a guide that installs
> `virtual-drm-daemon.zip` / `app-debug.apk` (the 5.x path), or your container
> config has a `/data/local/tmp/display_daemon.sock -> /run/display.sock` bind
> mount, **remove all of it**. 5.x exchanges frames over a private display
> protocol with patched compositors; 6.x makes Wayland itself the protocol.
> Having both routes active makes the client connect but never show a window.

**Component responsibilities.** The display path is three host processes plus one
container session.

| Component | Location | Responsibility | Not responsible for |
| --- | --- | --- | --- |
| `waylandbridge` (`anland-awl` module) | host, root daemon | Wayland server: accepts container clients, fires `window_created` on the first buffer | rendering |
| `com.anlandnext` | host, app | display side: one `AwlWindowActivity` per window, owns the BLAST surface | starting processes |
| `com.anland.shell` | host, app | launcher: enumerates containers and apps, injects env, starts them | creating windows |
| `anland-session` (`anlandx`) | container | session: wayland link, rootless Xwayland, mini-wm | — |

```text
container app --wayland--> waylandbridge --binder--> com.anlandnext
                                                            |
                                                    AwlWindowActivity
                                                            |
                                                    SurfaceFlinger
```

`com.anlandnext` is the only window creator. With `anland-shell` alone the app grid
works but produces no window; with `com.anlandnext` alone there is no launch entry.

### Log markers

```bash
logcat -d | grep 'anland-wl:' | tail -20
```

| Line | Meaning |
| --- | --- |
| `client connected` / `surface N created` | client attached |
| `surface N mapped (role=1)` | first buffer committed |
| `window WxH attached` | Android window attached |

`created` without `mapped` -> client never committed a buffer, application side.
`mapped` without `window attached` -> `com.anlandnext` side.

**One-click setup (recommended)**

```bash
adb push scripts/setup-anland6-host.sh /data/local/tmp/
adb shell su -c 'sh /data/local/tmp/setup-anland6-host.sh'

# then verify the whole chain layer by layer
adb push scripts/verify-anland6-host.sh /data/local/tmp/
adb shell su -c 'sh /data/local/tmp/verify-anland6-host.sh'
```

The script is idempotent: it installs the `anland-awl` module, installs the host
APKs, writes the daemon config (`auto_attach=1`, `scale_mode=1`) and adds the
container bind mount, then tells you whether a reboot is needed.

**Manual setup**

Anland 6.x needs **four** host-side pieces. Missing any one means no picture:

| # | File | How | Responsibility | If missing |
| --- | --- | --- | --- | --- |
| 1 | `module/anland-awl.zip` | flash via KernelSU/APatch + **reboot** | `waylandbridge` daemon (the Wayland server) | no socket, the session never starts |
| 2 | `anland-wayland.apk` | `pm install` | `com.anlandnext`: display side, one Activity per window | apps launch but **never show a window** |
| 3 | `anland-shell.apk` | `pm install` + **grant root** | `com.anland.shell`: launcher, lists containers/apps and starts them | no entry point to launch apps |
| 4 | `anlandx.tar.gz` | **already baked into this image** | the container-side `anlandx` session | no `anland-session` in the container |

Items 1–3 come from the **[misaka5202/anland 6.2-ds2
release](https://github.com/misaka5202/anland/releases/tag/6.2-ds2)** — the fork,
not upstream, because upstream 6.2 cannot type (see below). Item 4 is installed
during the image build; only foreign images need
`tar xzf anlandx.tar.gz && bash anlandx/setupanlandx.sh`.

### Download list

**Items 1, 2 and 4 must come from the fork** — upstream 6.2 has input defects
that make the desktop unusable (next section). `anland-shell.apk` also needs a
patched build for a different reason.

| File | Where | Direct link |
| --- | --- | --- |
| `module/anland-awl.zip` | **fork, not upstream** | [misaka5202/anland 6.2-ds2](https://github.com/misaka5202/anland/releases/tag/6.2-ds2) |
| `anland-wayland.apk` | **fork, not upstream** | same |
| **`anland-shell.apk`** | **patched build, not upstream 1.1** | **[misaka5202/anland-shell v1.1-ds72](https://github.com/misaka5202/anland-shell/releases/tag/v1.1-ds72)** |
| `anlandx.tar.gz` | **fork** (also baked into this image) | [misaka5202/anland 6.2-ds2](https://github.com/misaka5202/anland/releases/tag/6.2-ds2) |

**Why items 1, 2 and 4 must come from the fork**

Upstream 6.2 has three defects that make desktop input unusable:

1. **Soft-keyboard text never reaches apps.** Apps that do not implement
   `zwp_text_input_v3` (terminals such as Konsole/XTerm) receive nothing:
   `awl_ime_text()` drops the commit when no text-input object is enabled.
   The fork degrades ASCII text to `wl_keyboard` key events — the same path the
   Enter key already uses.
2. **Chinese input is impossible.** No `zwp_input_method_v2`, so a container
   IME (fcitx5) has no way to deliver composed text. The fork implements it.
3. **The extra-keys bar is partly dead.** Its leftmost column (ESC/TAB) sits in
   the system back-gesture region and the touch is swallowed. The fork insets
   the bar by `WindowInsets.Type.systemGestures()`.

Also included: the 5.x UI port (extra-keys bar, immersive mode with adjustable
opacity), i18n for the added strings, and a complete evdev scan-code mapping
for IME-synthesised key events (they always carry `scanCode == 0`).

**Why anland-shell needs the patched build**

Upstream's latest release is **1.1 (2026-09-17)** and it runs
`droidspaces show --format`. **Droidspaces 7.2.0 (2026-11-07) removed that flag**
in favour of `show --json`. The old flag prints
`Unknown or incomplete option: --format` to **stdout** while still **exiting 0**,
so anland-shell parses an empty running set:

```
every container shows stopped -> APPS is blocked -> apps never start -> no picture
```

The fix, [SuperTurtleDev/anland-shell#2](https://github.com/SuperTurtleDev/anland-shell/pull/2),
was opened on **2026-11-13 and is still unmerged**, so no official release carries it.

The `v1.1-ds72` build does exactly that one thing: ask for `show --json` first,
fall back to `show --format`, and strip ANSI escapes before parsing. Verified
end-to-end on an OPPO PHZ110 (MT6989 / Android 17 / Droidspaces 7.2.0).
**Switch back to the official build once upstream merges.**

Check whether you need it:

```bash
su -c 'droidspaces show --json'    # produces output
su -c 'droidspaces show --format'  # "Unknown or incomplete option"
# both true -> you need the patched build
```

> `setup-anland6-host.sh` reads the Droidspaces version and downloads `v1.1-ds72`
> automatically when it is ≥ 7.2.0, so you do not have to pick.

**① Flash `anland-awl` and reboot.** Download
[`anland-awl.zip`](https://github.com/misaka5202/anland/releases/tag/6.2-ds2)
from the fork release (upstream 6.2 has the input defects described above),
flash it with KernelSU/APatch.

**The reboot is mandatory.** While the module sits in `modules_update/`,
`waylandbridge` never runs and `/data/local/tmp/awl/wayland-0` does not exist —
the container then reports
`anland-session: no wayland socket at /run/anland/wayland-0`.

**② Install the host APKs.** `com.anlandnext` draws the windows; `com.anland.shell`
launches apps. Then **grant `com.anland.shell` root** in your root manager — it
reads `/data/local/Droidspaces/Containers` through `su`, and without the grant it
shows `no containers defined`.

> `anland-shell` 1.1 calls `droidspaces show --format`, which **Droidspaces 7.2.0
> removed** in favour of `show --json`. The old flag prints
> `Unknown or incomplete option` on stdout while still exiting 0, so every
> container renders as `stopped` and the app grid refuses to open. Use the
> patched [v1.1-ds72 build](https://github.com/misaka5202/anland-shell/releases/tag/v1.1-ds72);
> the upstream fix is [PR #2](https://github.com/SuperTurtleDev/anland-shell/pull/2).

**③ Add the bind mount (required, do not skip).** The daemon publishes its socket
at **`/data/local/tmp/awl/wayland-0`** while `anland-session` inside the container
hardcodes **`/run/anland/wayland-0`**. These are different filesystems by default —
a container's `/run` is its own tmpfs — so the host directory has to be mapped in
explicitly:

```text
/data/local/tmp/awl  ->  /run/anland
```

Droidspaces persists it into `container.config`, so once is enough:

```bash
su -c 'droidspaces --name=<container> -B /data/local/tmp/awl:/run/anland start'
```

Or write it into `container.config` directly:

```ini
bind_mounts=/data/local/tmp/awl:/run/anland
```

**Without it** the session never starts and reports

```text
anland-session: no wayland socket at /run/anland/wayland-0 (anland daemon down?)
```

The "daemon down?" in that message is misleading — the daemon runs fine, the
container simply cannot see it. `anland-shell` still lists apps (that part is
self-contained), but tapping one does nothing.

**Confirm it is mounted:**

```bash
su -c 'droidspaces --name=<container> run -- ls -l /run/anland/wayland-0'
# expect: srw-rw-rw- 1 root root 0 ... /run/anland/wayland-0
```

Only `srw-rw-rw-` (a socket) is correct. `No such file` or a regular file means
the mount did not apply.

**Why the path cannot be changed to avoid this:** `anland-session` hardcodes
`/run/anland/wayland-0`, and the daemon's publish point comes from `config.json`'s
`runtime_dir` (default `/data/local/tmp/awl`). Changing the convention means
changing both sides, and the container side exposes no such setting — so mounting
the default pair is the supported path.

`socket_listen=0` makes the daemon skip the socket file entirely ("pure binder-fd
mode"), but that requires the client to speak Android binder directly, which a
Linux application inside the container cannot do. It is not an option for the
desktop case.

Droidspaces itself has no `/run/anland` handling at all (the string appears zero
times in its binary; it only knows the 5.x `/run/display.sock`), so nothing will
add this mount for you.

**④ Container settings.** Enable hardware access (`--hw-access` / `--gpu`) and
privileged mode with `nocaps` and `noseccomp`.

MTK / Mali devices additionally need `mali_nsfix`: the image renders through
libhybris against the vendor `libGLES_mali.so` on `/dev/mali0`, which is what
provides hardware acceleration. `mali_kbase`'s `find_get_pid` fails inside a PID
namespace, so without this module the container cannot create a GPU context —
`dmesg` shows `Failed to get pid pointer` and userspace sees `eglInitialize`
return `0x3001`. Installing [droidspaces-lkm](https://github.com/misaka5202/droidspaces-lkm)
is enough; it loads automatically on Mali platforms. See the
[KMI coverage matrix](https://github.com/misaka5202/droidspaces-lkm/blob/master/docs/KMI-COVERAGE.en.md).

`vkms` is not needed: anland 6.x's `waylandbridge` drives `/dev/mali0` directly,
and rendering and presentation still work with `vkms` removed.

**If you installed the Anland 5.x set instead** (`com.anland.consumer` +
`anland-daemon` + `/run/display.sock`, with a self-composited KDE/GNOME/
Hyprland/Niri/Mango/Denial inside the container), that route renders via
`ANLAND_DRM_DEVICE=/dev/dri/renderD128`. Mali has no DRM render node, so it
**must enable `vkms`**; `mali_nsfix` does nothing for it. Do not run the 5.x and
6.x routes at the same time.

### Starting apps

**Use `anland-shell`; do not start applications by hand inside the container.**
It is the only entry point that prepares the launch environment correctly — it
injects `XDG_RUNTIME_DIR` / `WAYLAND_DISPLAY` / `DBUS_SESSION_BUS_ADDRESS` and
starts the app through the **systemd user session**, which is what gives it a
complete desktop session.

```text
open anland-shell
  -> pick the container, tap START (skip if already running; "running · pid NNNN" is correct)
  -> tap APPS and wait for the app grid (a few seconds the first time)
  -> tap any app
```

The app becomes a **real Android window**: it shows up in recents, supports
split-screen, and keeps its own IME state.

Four things can go wrong at this step:

| Symptom | Cause | Fix |
| --- | --- | --- |
| container shows `stopped` while it actually runs | anland-shell incompatible with Droidspaces ≥7.2.0 | use the [patched build](https://github.com/misaka5202/anland-shell/releases/tag/v1.1-ds72) |
| shows `no containers defined` | app has no root | grant root in your root manager |
| `APPS` reports `Anlandx not installed` | the container is not running | start it first |
| tapping an app does nothing | see "When there is no picture" | read the daemon log |

On first use, check two settings in `com.anlandnext`'s **Window Settings**:

| Setting | Value | Why |
| --- | --- | --- |
| Window scaling | `Fit` (uniform, letterboxed) | the default `Stretch` fills each axis independently; on a portrait phone the 800×600 placeholder is stretched to 1264×2780 — 4.6× vertically |
| Auto attach new windows | on | when off, a window waits for a binder SURFACE from its app and never appears on its own |

Both apply live and persist automatically (`config set scale_mode=N (applied +
persisted)`), no daemon restart needed.

### When there is no picture

| Symptom | Cause | Fix |
| --- | --- | --- |
| `no wayland socket at /run/anland/wayland-0` | the container cannot see the socket | bind mount from step ③ |
| `anland-shell` shows `stopped` while the container runs | `show --format` incompatibility | patched anland-shell |
| `anland-shell` shows `no containers defined` | app has no root | grant root |
| window list is 0 but `daemon running` | the app never committed a frame | see the daemon log below |
| picture present but badly distorted | `scale_mode=0` | switch to `Fit` |
| MTK / Mali: window opens, client renders, screen stays empty | SurfaceControl compositor cannot present dma-buf content on MediaTek | set `sc_enabled: 0` |
| `eglInitialize` returns `0x3001` on MTK | `mali_kbase` refuses a PID-namespaced pid lookup | load `mali_nsfix.ko` |

Read the daemon log to see which hop breaks:

```bash
logcat -d | grep 'anland-wl:' | tail -20
#  surface N created            <- client connected, surface only
#  surface N mapped (role=1)    <- first buffer committed; only now is a window made
#  window 1264x2780 attached    <- the Android window is attached
```

`created` without `mapped` means the client never committed a buffer — that is an
application-side problem, not the daemon.

### MediaTek / Mali devices

The vendor `mali_kbase` driver and the compositors need three things on MediaTek
that they do not need on Qualcomm. Each one fails in a way that looks like a
different bug.

| Condition | Without it |
| --- | --- |
| `mali_nsfix.ko` loaded | `eglInitialize` returns `0x3001`; `dmesg` shows `mali 13000000.mali: Failed to get pid pointer for <comm>/<pid>` |
| daemon started with `AWL_NO_SCANOUT=1` | the AHB forging is retried every frame, logging two `anland-rd` errors per frame |
| `"sc_enabled": 0` in `config.json` | the SurfaceControl compositor takes the client buffer and presents nothing |

Why the first is needed: `kbase_create_context()` calls
`find_get_pid(current->tgid)`. `tgid` is always an initial-namespace value while
`find_get_pid()` resolves through the caller's active namespace, so the lookup
fails for a container process and `kbase_create_context()` returns `NULL`, which
the driver reports as `-ENOMEM`. `mali_nsfix.ko` from
[droidspaces-lkm](https://github.com/misaka5202/droidspaces-lkm) redirects that
call.

Why the third is needed: `awl_ahb.cpp` forges a client dma-buf into an
`AHardwareBuffer` using the 2-fd `native_handle` layout that Qualcomm snapalloc
produces. MediaTek's `mtk_alloc` reports three file descriptors, so the forge is
refused. The GL renderer (`awl_renderer.cpp`, selected by `sc_enabled: 0`) then
imports the dma-buf directly through `EGL_EXT_image_dma_buf_import`, which
works. The SurfaceControl compositor (`awl_sc.cpp`) runs the same import but
does not present the result; the reason is not established.

Verify by capturing the screen twice — while the client is running and again
after it exits. Capturing once is not enough: a window left behind by a
previously killed client produces a false positive.

Start the container and log in as the normal user. For KDE run `startplasma-wayland`; KDE Mobile uses `startplasmamobile`; GNOME uses `gnome-session --session=gnome`.

### Install or update Anland desktop packages

The build fetches matching packages automatically. To install them separately in a running ARM64 RootFS, run from the repository root:

```bash
sudo ./scripts/tui/install-anland-kde.sh
```

The GNOME installer runs on Debian 13, Ubuntu 26, Fedora 43/44, and Arch Linux ARM:

```bash
sudo ./scripts/tui/install-anland-gnome.sh
```

The in-container installer supports Debian, Ubuntu, Fedora, and Arch packages and reads the matching target from the `anland-gnome-packages` Release manifest.

See the [script guide](../../scripts/README_english.md#anland-kde-installer) for installer options, download sources, and verification.

