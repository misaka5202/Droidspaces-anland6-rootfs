# 高通 / MTK 显示踩坑总表（Anland 6.x）

> 面向 Anland 6.x（`anland-awl` 模块 + `com.anlandnext` + `anland-shell` + `anlandx` 容器会话）。
> 本文把两平台所有"看起来像不同 bug、其实是同一个坑"的现象归位，并给出可复制命令。
> 记录环境：Xiaomi/Redmi 平板 `2410CRP4CG`，`ro.board.platform=pineapple`（SM8650 / Adreno 732），
> Android 16，kernel `6.1.138-android14-11`，adb `7420ea7`；MTK 部分来自仓库文档与 lkm 仓库。

---

## 0. 结论速览

| 平台 | 最常见的"黑屏/没窗口"根因 | 一句话修复 |
| --- | --- | --- |
| 高通 | `plat_service_contexts` 里 `anland.host` 排在通配符 `*` **之后** | 把 anland 行移到 `*` **之前**（`setup-anland6-host.sh` 已自动纠偏） |
| 高通 | `sc_enabled: 1`（SurfaceControl） | 改 `0` |
| 高通 | Chrome 默认 Vulkan/DRI3/sandbox | `--disable-gpu --no-sandbox` |
| MTK | 没有 `renderD128` | 装 `vkms` 模块（droidspaces-lkm） |
| MTK | `eglInitialize 0x3001` | 装 `mali_nsfix.ko` |
| MTK | SurfaceControl 不呈现 dma-buf | `sc_enabled: 0` |
| MTK | 每帧两次 `anland-rd` 报错 | 用 `AWL_NO_SCANOUT=1` 启动 daemon |

**先记住一句话**：6.x 里**合成器在宿主**（`waylandbridge`），容器只跑 `anland-session`
（wayland 链路 + rootless Xwayland + mini-wm），应用由 `anland-shell` 逐个启动。
凡是"容器里再装一个合成器"的思路（niri/hyprland/…）都是 5.x 遗留，6.x 单应用模式下没有意义。

---

## 1. 6.x 显示链路（坑都在这条链上）

```
容器应用 --wayland--> waylandbridge(宿主 root daemon) --binder--> com.anlandnext
                                                                    |
                                                            AwlWindowActivity（每窗口一个）
                                                                    |
                                                            SurfaceFlinger
```

| 组件 | 位置 | 职责 | 不负责 |
| --- | --- | --- | --- |
| `waylandbridge`（`anland-awl` 模块） | 宿主 | Wayland server：收容器客户端，首帧时发 `window_created` | 渲染 |
| `com.anlandnext` | 宿主 APK | 显示侧：一个窗口一个 `AwlWindowActivity`，持有 BLAST surface | 启动进程 |
| `com.anland.shell` | 宿主 APK | 启动器：列容器/应用、注入环境、经 systemd 用户会话启动应用 | 创建窗口 |
| `anland-session`（`anlandx`） | 容器 | 会话：wayland 链路、rootless Xwayland、mini-wm | — |

**关键日志标记**（`logcat -d | grep 'anland-wl:'`）：

```
surface N created          # 客户端连上，只有 surface
surface N mapped (role=1)  # 提交了首帧 —— 这一步才会去建窗口
window 1264x2780 attached  # Android 窗口已挂上
```

- `created` 没有 `mapped` → 应用侧从未提交 buffer（应用问题，不是 daemon）
- `mapped` 没有 `attached` → `com.anlandnext` 侧

---

## 2. 通用坑（两个平台都踩）

### 2.1 模块必须重启
模块装在 `/data/adb/modules_update/` 时 `waylandbridge` 不跑，`/data/local/tmp/awl/wayland-0` 不存在，
容器报 `anland-session: no wayland socket at /run/anland/wayland-0`。**刷完必须 reboot**。

### 2.2 绑定挂载（必做，不能跳）
daemon 发布在 `/data/local/tmp/awl/wayland-0`，容器内 `anland-session` **硬编码** `/run/anland/wayland-0`：

```bash
su -c 'droidspaces --name=<容器> -B /data/local/tmp/awl:/run/anland start'
```

或写进 `container.config`：

```ini
bind_mounts=/data/local/tmp/awl:/run/anland
```

验证（必须是 socket `srw-rw-rw-`）：

```bash
su -c 'droidspaces --name=<容器> run -- ls -l /run/anland/wayland-0'
```

> 报错里的 "anland daemon down?" 是误导 —— daemon 好好的，只是容器看不见它。

### 2.3 anland-shell 与 Droidspaces ≥7.2.0
上游 shell 1.1 调 `droidspaces show --format`，7.2.0 已删除该 flag → 容器永远显示 `stopped` → APPS 点不开。
用打过补丁的 [v1.1-ds73](https://github.com/misaka5202/anland-shell/releases/tag/v1.1-ds73)。

### 2.4 `com.anlandnext` 必须装
它是**唯一**的窗口创建者。只装 `anland-shell` → 应用网格能开但**不出窗口**。

### 2.5 给 `com.anland.shell` 授予 root
它要读 `/data/local/Droidspaces/Containers`，没授权就显示 `no containers defined`。

### 2.6 窗口缩放用 Fit
`scale_mode=0`（默认 Stretch）在竖屏上把 800×600 占位拉成 1264×2780（纵向 4.6×）。
改成 `1`（Fit，等比加黑边）。`com.anlandnext` 的 Window Settings 里改会即时生效并持久化。

### 2.7 判断成败的正确方法（血泪教训）
**不要**用 `mCurrentFocus` 或"进程还活着"判断成功 —— 都出现过假阳性。

- 用**两张截图像素分析**：客户端运行时一张、退出后再一张（只截一张会被上一个客户端的残留窗口骗到）。
  空窗口通常只有几百个唯一色，真实桌面是几十万。
- 用 `AwlWindowActivity` 是否出现 + daemon 日志的 `mapped (role=1)` / `attached` 交叉验证。
- 屏幕截图前先确认 `dumpsys power | grep mWakefulness` 是 `Awake` —— 息屏时截图全是纯色，
  会被误判成"渲染失败"（本次排查就被这个坑过一轮）。

### 2.8 `setenforce 0` 会污染 AVC 缓存
permissive 期间的放行会缓存下来，**重新 enforce 后仍然生效**，必须干净重启才能拿到可信基线。

### 2.9 grep 的内核 avc 行是双空格
内核打印 `avc:  denied`（两个空格）。用 `grep 'avc: denied'` 会什么都搜不到 → 误判"没有 denial"。

### 2.10 `pgrep -f waylandbridge` 会自我匹配
命令行的脚本内容里含 `waylandbridge` 字样时会匹配到自己。用 `pidof waylandbridge`（本次只有 1 个实例）。

---

## 3. 高通（SM8650 / Adreno / pineapple）专属坑

### 3.1 【根因】`plat_service_contexts` 通配符顺序 → 完全没窗口

**现象**：应用能启动，但**永远不出窗口**；`anland-shell` 里 daemon 显示 unreachable。

**根因**：`plat_service_contexts` 是**首个匹配生效**，通配符 `*` 必须最后一行。
模块 `customize.sh` 用 `cat ... >>` 把片段追加到文件末尾，在带通配符的平台文件上，
`anland.host` 落到了 `*` **之后**，成了死行：

```
*            u:object_r:default_android_service:s0
anland.host  u:object_r:anland_host_service:s0   ← 永不匹配
```

于是 servicemanager 给 `anland.host` 贴 `default_android_service`，
`untrusted_app_29` 的 `find` 被 SELinux 拒（permissive=0）：

```
avc:  denied { find } name=anland.host
  scontext=u:r:untrusted_app_29 tcontext=u:object_r:default_android_service
```

链路断在：`getService=null` → `subscribe rc=-1` → `daemon unreachable` → 不建 `AwlWindowActivity`。

**修复**：把 anland 片段**插到第一个 `*` 行之前**（无通配符时回退 append），保持幂等。
- 已在 `scripts/setup-anland6-host.sh` 里自动纠偏（装完模块后执行，改到就触发重启提示）。
- 上游根因见 [SuperTurtleDev/anland#130](https://github.com/SuperTurtleDev/anland/issues/130)；
  fork 修复：`misaka5202/anland` 的 `module/customize.sh`（commit `6c94535`，PR #1）。

**验证**：

```bash
adb shell "su -c 'grep -nE \"^anland.host|^\\\\*[[:space:]]\" /data/adb/modules/anland-awl/system/etc/selinux/plat_service_contexts'"
# anland.host 行号必须 < * 行号
adb shell "su -c 'logcat -d | grep \"avc:  denied\" | grep anland | tail -5'"   # 应为空
```

### 3.2 `sc_enabled` 必须为 0

`config.json` 里 `sc_enabled: 1` 会走 SurfaceControl 合成器（`awl_sc.cpp`），
在高通上在 `AHardwareBuffer_allocate` 直接 abort：

```
Failed to load matching allocator for mapper version 4
```

上游 [SuperTurtleDev/anland#84](https://github.com/SuperTurtleDev/anland/issues/84) 已确认：
**高通必须 `sc_enabled: 0`**，走 GL renderer（`awl_renderer.cpp`）直接导入 dma-buf。
`setup-anland6-host.sh` 已把该值恒写 0。

### 3.3 Chrome / Chromium 的三个坑（与"能不能显示"无关，但最容易被误判成显示问题）

实测高通上裸启动 Chrome 会崩，是三层独立原因：

| 层 | 报错 | 修复 |
| --- | --- | --- |
| setuid/namespace 沙箱 | `Failed to move to new namespace ... Operation not permitted`；`Zygote ... exit code 82 (setuid sandbox)` | `--no-sandbox` |
| ANGLE 选了 Vulkan | `'--ozone-platform=wayland' is not compatible with Vulkan` | `--disable-gpu`（走软件光栅） |
| X11 路径无 DRI3 | `eglCreateWindowSurface ... EGL_BAD_MATCH` / `vulkan: No DRI3 support detected` | 别用 `--ozone-platform=x11` |

**最终可用组合**（已写进 `scripts/configure-chrome.sh` 的 wrapper）：

```sh
exec /opt/google/chrome/google-chrome \
    --ozone-platform=wayland \
    --disable-gpu \
    --no-sandbox \
    "$@"
```

> 注意：只加 `--no-sandbox` 不够 —— ANGLE 仍会自动探测到高通的 Vulkan 并选中，
> Ozone-Wayland 明确拒绝 Vulkan 后端。必须 `--disable-gpu`。

**为什么 MTK 没这个问题**：MTK 镜像用 `swrast` 软件渲染（`MESA_LOADER_DRIVER_OVERRIDE=swrast`），
**没有可用的 Vulkan ICD**，ANGLE 探测不到就自动回退 GL，所以从来不会选中 Vulkan 后端。
高通有真实 freedreno/Turnip Vulkan，反而"太齐全"把 Chrome 引到了 ozone 不支持的路上。

### 3.4 daemon 运行域：`ksu` vs `awl_daemon`

`service.sh` 会用 `chcon u:object_r:awl_daemon_exec:s0` 给 `waylandbridge` 打标签，
但如果 daemon 在 contexts 就绪前被拉起来，运行域会是 `u:r:ksu` 而不是 `u:r:awl_daemon`。
上游 [SuperTurtleDev/anland#131](https://github.com/SuperTurtleDev/anland/issues/131) 记录了该域转换问题。
本次实测：`service.sh` 重启后域正确变成 `u:r:awl_daemon`。

### 3.5 dma-buf 导入 MISSING → 回退 shm 上传

daemon 日志会出现：

```
anland-gl: !! dmabuf import MISSING / image2d ok
```

含义：EGL 不支持该 dma-buf 的导入，改用 **shm 上传**渲染。**普通应用没问题**
（本次 konsole 等实测正常出画面），但重 GPU 应用（合成器/游戏）可能受影响 ——
上游 [#84](https://github.com/SuperTurtleDev/anland/issues/84) / [#135](https://github.com/SuperTurtleDev/anland/issues/135)（Snapdragon 8 Elite GPU 崩溃）与此相关。

### 3.6 容器参数（高通）

```bash
droidspaces -n <容器> -r <rootfs> -H --gpu --anland \
  --privileged=nocaps,noseccomp --net=host \
  -B /data/local/tmp/awl:/run/anland start
```

- `--gpu` / `--hw-access`：暴露 `/dev/dri/renderD128`（高通 = `msm_drm`）、`/dev/kgsl-3d0`
- `--privileged=nocaps,noseccomp`：容器内 root 没有 `CAP_SYS_ADMIN` → **这就是 Chrome 沙箱起不来的原因**
- `--net=host`
- `-B`：见 2.2

### 3.7 推荐 `config.json`

```json
{
  "zoom": 100,
  "init_w": 800,
  "init_h": 600,
  "scale_mode": 1,
  "xwayland_scale": 1,
  "auto_attach": 1,
  "sc_enabled": 0,
  "runtime_dir": "/data/local/tmp/awl",
  "socket_listen": 1
}
```

- `auto_attach: 1`：窗口创建时宿主自动开 Android 窗口（关掉的话窗口要等 binder SURFACE，自己不出现）
- `scale_mode: 1`：Fit
- `sc_enabled: 0`：见 3.2
- `runtime_dir`：必须和绑定挂载的宿主侧一致

---

## 4. MTK（Mali）专属坑

文档原话：MTK 需要**三样高通不需要的东西**，每一个失败起来都像另一个 bug。

| 条件 | 缺了会怎样 | 解决 |
| --- | --- | --- |
| `mali_nsfix.ko` 已加载 | `eglInitialize` 返回 `0x3001`；`dmesg` 有 `mali ...: Failed to get pid pointer for <comm>/<pid>` | 装 [droidspaces-lkm](https://github.com/misaka5202/droidspaces-lkm) 的 `mali_nsfix.ko` |
| daemon 用 `AWL_NO_SCANOUT=1` 启动 | 每帧重试 AHB forging，每帧刷两条 `anland-rd` 报错 | 启动时带该环境变量 |
| `config.json` 里 `sc_enabled: 0` | SurfaceControl 合成器拿走客户端 buffer 却不呈现 → 屏幕空 | 改 0 |

### 4.1 为什么 `mali_nsfix.ko` 必需
`kbase_create_context()` 调 `find_get_pid(current->tgid)`。`tgid` 永远是初始命名空间的值，
而 `find_get_pid()` 走调用者的活跃命名空间 → 对容器进程查找失败，
`kbase_create_context()` 返回 `NULL`，驱动报 `-ENOMEM`。`mali_nsfix.ko` 重定向该调用。

### 4.2 为什么 `sc_enabled: 0`
`awl_ahb.cpp` 用高通 snapalloc 的 **2-fd** `native_handle` 布局把客户端 dma-buf 伪造成 `AHardwareBuffer`。
MTK 的 `mtk_alloc` 报 **3 个 fd**，伪造被拒。
GL renderer（`awl_renderer.cpp`，即 `sc_enabled: 0`）改走 `EGL_EXT_image_dma_buf_import` 直接导入，可行；
SurfaceControl（`awl_sc.cpp`）做同样的导入却**不呈现**（原因未确定）。

### 4.3 没有 `renderD128`
厂商内核通常不带 `CONFIG_DRM_VKMS`，只有 `card0` 没有 `renderD128`，合成器拒绝启动。
装 droidspaces-lkm 的 `vkms` 模块（注意 KMI 覆盖范围）。

### 4.4 验证方式（两平台通用）
客户端运行时截一张、退出后再截一张。只截一张不够 —— 被 kill 的客户端留下的窗口会造成假阳性。

---

## 5. 对照速查表

| 现象 | 先看哪里 | 平台 |
| --- | --- | --- |
| 应用能起但完全没窗口 | `plat_service_contexts` 顺序 + `avc:  denied find` | 高通（MTK 同） |
| daemon unreachable / `subscribe rc=-1` | `getService` 是否 null（服务发现） | 两者 |
| 容器报 `no wayland socket at /run/anland/wayland-0` | 绑定挂载 | 两者 |
| 容器列表永远 `stopped` | anland-shell 版本 | 两者 |
| `no containers defined` | shell 是否有 root | 两者 |
| 画面严重变形 | `scale_mode` 改 1 | 两者 |
| 窗口开了但屏幕空 | `sc_enabled` 改 0 | 两者（MTK 尤甚） |
| `eglInitialize 0x3001` | `mali_nsfix.ko` | MTK |
| 没有 `renderD128` | `vkms` 模块 | MTK |
| 每帧两条 `anland-rd` 报错 | `AWL_NO_SCANOUT=1` | MTK |
| Chrome 崩溃 `exit code 82` | `--no-sandbox` | 两者（容器 allow_sandboxing=0） |
| Chrome `not compatible with Vulkan` | `--disable-gpu` | 高通（有 Vulkan） |
| `dma-buf import MISSING` | 正常回退 shm；重 GPU 应用才需深挖 | 高通 |

---

## 6. 一键脚本与验证清单

```bash
# 1) 宿主一键配置（装模块/APK、写 config、加绑定挂载、纠偏 service_contexts）
adb push scripts/setup-anland6-host.sh /data/local/tmp/
adb shell su -c 'sh /data/local/tmp/setup-anland6-host.sh'
# 若提示需要重启：su -c 'reboot'，重启后再跑一次应全 [OK]

# 2) 逐层验证
adb push scripts/verify-anland6-host.sh /data/local/tmp/
adb shell su -c 'sh /data/local/tmp/verify-anland6-host.sh'

# 3) 手动核对
adb shell "su -c 'pidof waylandbridge'"                       # 应恰有 1 个
adb shell "su -c 'ls -l /data/local/tmp/awl/wayland-0'"       # 应为 socket
adb shell "su -c 'logcat -d | grep \"avc:  denied\" | grep anland | tail'"
adb shell "dumpsys window | grep mCurrentFocus"               # 点应用后应出现 AwlWindowActivity
```

相关仓库：
- anland 模块/APK 源码 fork：`misaka5202/anland`，Release **`6.2-ds6`**（上游 6.2 输入不可用：窗口起不来、剪贴板 MIME 缺失等）
- anland-shell 兼容补丁：`misaka5202/anland-shell` `v1.1-ds73`
- 内核模块（vkms / mali_nsfix）：`misaka5202/droidspaces-lkm`
- 上游 issue：[#84](https://github.com/SuperTurtleDev/anland/issues/84) ·
  [#130](https://github.com/SuperTurtleDev/anland/issues/130) ·
  [#131](https://github.com/SuperTurtleDev/anland/issues/131) ·
  [#135](https://github.com/SuperTurtleDev/anland/issues/135)
