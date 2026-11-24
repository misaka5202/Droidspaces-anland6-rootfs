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
