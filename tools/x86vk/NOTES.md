# x86_64 Vulkan on Adreno — what actually works

Notes from getting an x86_64 Vulkan client onto this device's GPU inside a
droidspaces container. Read this before rebuilding anything in here; several
paths look reasonable and are dead ends.

## Do not build an x86_64 Turnip

The tempting approach is to cross-build Turnip for x86_64 with the kgsl backend
and let the translator run it. It works far enough to be convincing — the driver
enumerates the GPU, runs compute dispatches, creates a Wayland surface and
reports present modes — and then dies the moment a real frame is presented.

Three separate things have to be true for it, and the last one is unreachable for
a Vulkan-only build:

1. `-Dfreedreno-kmds=kgsl`. Without it the driver has no kgsl backend at all
   (`grep kgsl-3d0` = 0) and reports no physical device, because Android exposes
   the GPU through kgsl rather than desktop DRM.
2. `-Dplatforms=x11,wayland`. With this empty the instance offers only
   `VK_EXT_headless_surface`, which enumerates the GPU but cannot present.
3. GBM, for swapchain image allocation. `-Dgbm=enabled` is rejected with "GBM
   only supports DRM/KMS platforms"; adding a gallium driver gets further and
   then fails with `Unknown variable "inc_st_dri"`, because src/gbm's DRI backend
   needs the full GL state tracker. A Vulkan-only build cannot satisfy this.

Symptom of (3) when skipped: vkcube prints `Selected GPU 0` and dies — SIGABRT
with `x64pc=0x1` under box64, SIGSEGV under FEX. Identical under both
translators, which is what rules the translators out as the cause.

## What works: let the translator wrap the native driver

box64 prefers to wrap a host library over emulating the guest one. Let it wrap
`libvulkan.so.1` and do **not** point `VK_ICD_FILENAMES` at an x86_64 ICD:

```
[BOX64] Using native(wrapped) libvulkan.so.1
Selected GPU 0: Turnip Adreno (TM) 735
```

The aarch64 Turnip that ships in the image is already kgsl-capable, so none of
the above reconstruction is needed. The whole x86_64 driver subtask collapses:

- no kgsl cross-build
- no `-static-libstdc++` (that existed only to dodge box64's missing TLSDESC)
- no `call_once` shim
- no WSI/GBM build flags

This is also what GameNative/Winlator do in effect: translate the application and
the Windows layer, not the graphics driver.

## Presentation works — but only awake, and only as the session user

Two non-obvious prerequisites cost a lot of time. Both look like driver failures
and are neither:

1. **The screen must be awake.** With `mWakefulness=Asleep` the device composites
   nothing, so no `wl_surface.frame` callback is ever delivered and the client
   blocks in `poll` until it times out. box64, FEX and the aarch64 native binary
   all behaved identically, which is the clue that the driver is not involved.
   Once awake, all of them complete their frame loop.

2. **It must run as the session user (uid 1000).** anland starts Xwayland and the
   Wayland socket as that user, so a root-owned process gets `Authorization
   required` from X. Switching to the session user fixed the X path immediately
   (`Surface types: count = 2`).

Verified once those are met:

```
10 帧 320x240  rc=0
60 帧 480x320  rc=0
120 帧 640x360 rc=0    -> 1431 ms, ~83 fps
```

Note the X11 path is not usable for GPU presentation regardless: the rootless
Xwayland in this session has no DRI3 (`No DRI3 support detected - required for
presentation`), so a client falls back to llvmpipe and then dies on
`Illegal instruction` under emulation. Wayland is the only path that reaches the
GPU, because its dmabuf path can hand kgsl buffers straight through.

## Entry points all resolve under the wrapping layer

`procaddr.c` walks every Vulkan entry a loader-heavy consumer reaches through
`vkGetInstanceProcAddr` / `vkGetDeviceProcAddr` rather than by linking, because
that is how DXVK reaches Vulkan: a missing pointer there becomes a NULL
dereference deep inside Windows code.

```
summary instance 22/22 device 96/96     rc=0
```

All 118 resolve. The first run of this check reported surface and swapchain
entries as NULL and looked alarming; the cause was the harness not requesting
`VK_KHR_surface`/`VK_KHR_wayland_surface` and `VK_KHR_swapchain`, without which
the loader is *required* to return NULL. Requesting them makes the check valid.

## The Windows layer runs under box64

Built in CI (`build-wine-bundle.yml`) because pulling libwine:amd64 plus its
181-package tree onto the device never finishes — the link drops around 20 MB of a
205 MB download. The runner is x86_64, so it also *runs* the result before
shipping it: `wine-selftest.c` is compiled to a Windows PE with mingw and executed
under wine there.

On the device, from a 6.9 MB minimal bundle:

```
$ box64 /opt/wine/usr/lib/x86_64-linux-gnu/wine/wine --version
wine-10.0 (Ubuntu 10.0~repack-12ubuntu1)
```

Two artifacts are published on purpose:

| artifact | size | purpose |
|---|---|---|
| `wine-mini-x86_64` | 6.9 MB | launcher, x86_64-unix half, wineserver, dependencies — proves the chain starts |
| `wine-bundle-x86_64` | 209 MB | adds the builtin PE dlls, needed once a Windows program actually executes |

Things worth knowing before editing that workflow:

- Ubuntu's wine 10 ships **no** `/usr/bin/wine64` and **no** `libwine.so`. The real
  entry point is `/usr/lib/x86_64-linux-gnu/wine/wine`, and `wine64` on PATH comes
  from the alternatives system. Select payload files by path, not by package
  ownership.
- wine's `ntdll.so` needs `libunwind.so.8`, which apt does **not** install for
  `wine64`. Without it wine cannot dlopen ntdll at all.
- Bundled sonames are symlinks to versioned files. `cp -a` copies the link and
  leaves it dangling, and tar then drops it — the payload reports the library as
  bundled while the archive does not contain it. Use `cp -L`.
- Cache `/var/cache/apt/archives`: the wine download alone has taken both two
  minutes and over twenty depending on runner throughput.

## Historical note: the xdg-shell stall

Even with the driver side solved, vkcube selects the GPU and then stalls in
`do_sys_poll` waiting for `wl_surface.frame` callbacks. Six runs, with and without
the shim, all timed out; the aarch64 native binary behaves the same way.

anland's xdg-shell lifecycle explains it:

```
get_toplevel -> initial configure(0,0) -> client ack + first buffer commit
-> map -> window_created -> Android creates the Activity that composites it
```

A plain xdg-shell client gets no frame callbacks until an Android Activity exists
to composite its surface. The path anland is actually built around is X11:
Xwayland -> `AwlWindowActivity`, one Activity per toplevel, which has been
verified working end to end.

X11 presentation is therefore the route to take, and it currently fails on:

```
Authorization required, but no authorization protocol specified
XCB failed to connect to the X server
```

The rootless Xwayland started by anland-session asserts an xauth cookie that the
container does not hold. That, not the driver, is the next thing to fix.

## MTK (mt6989 / Immortalis-G715): the driver must be glibc-native

2026-11-25 run on Dimensity 9300. Three walls, one door:

1. **NDK mali-panvk cannot run inside a glibc container at all** — its static
   bionic jemalloc dies in `vkCreateInstance` with `Error setting TSD` + abort,
   whether the ICD is reached through hybris `android_dlopen` (probe5) or the
   bionic-warm path. No env knob fixes this.
2. **hybris vulkan.c needed three patches** (shipped as
   `scripts/hybris/vulkan-icd-glibc.c` + `patch-vulkan-icd.sh`): gipa lazy-init
   guard, `vk_icd*` fallback wired into `VULKAN_IDLOAD`, and a `glibc:` prefix
   for `LIBVULKAN`. Verified `layers=0` through the ICD path on-device.
3. **The door is building mali-panvk natively** (`probe6-glibc-panvk.c`,
   recipe = `scripts/tui/build-panvk-glibc.sh`): two-stage meson,
   `-Dplatforms=` (the fork deleted `src/loader`), `mesa-clc=system`. Result:
   stock Khronos loader enumerates `PanVK-G720-Immortalis MC12` Vulkan 1.4.363,
   device/queue/fence complete (`GLIBC-PANVK-CHAIN-OK` pending final run), and
   **box64 + the x86_64 probe reaches submit+fence rc=0** (`probe7-x86vk.c`:
   `X86-ON-MTK-GPU-CHAIN-OK`).

Deployment traps confirmed the hard way:

- `/etc/environment` carries the image's `LD_LIBRARY_PATH=/opt/hy/inst/lib`;
  any glibc-side Vulkan client then picks the hybris loader and every ICD
  dlopen hits the bionic linker (`namespace "(default)"` errors). Use
  `env -i` or seal the hybris libvulkan.so.1 (build script renames it to
  `.hybris-off`).
- Ubuntu `wine64:amd64` multiarch PEs import `zlib1.dll`/`libwinpthread` that
  `libwine:amd64` does not ship (repack build leak); `wineboot` dies at
  user32. Kron4ek Wine-Builds (`wine-10.0-amd64.tar.xz`) boots cleanly under
  box64 (`wineboot -u` rc=0, prefix 786 files).
- kbase on MTK answers `CSF_VERSION_CHECK(_IOWR(0x80,52,{u16,u16}))` with
  1.21 and `SET_FLAGS` fine from the container (see `malitest` recipe in
  docs/x86-on-android-report.zh.md §12).

Status at end of session: GPU chain x86_64→wine→DXVK verified up to VkInstance
through d3d9.dll (DXVK 2.7.1 loads from system32 as native, panvk warning
appears); `Direct3DCreate9` returns NULL — DXVK adapter probe vs panvk is the
open item; DXVK 3.1.1 is the next attempt (robustness2 is the known panvk
feature DXVK 2.x may reject without the newer feature set).
