# 高通 + MTK：Android 上跑 x86_64 Windows 游戏（双平台汇总）

> 本文是两份长文的**一页速查版**，不替代它们：
> - 完整技术报告 → [`x86-on-android-report.zh.md`](./x86-on-android-report.zh.md)（高通 §1–11 / MTK §12）
> - 显示与呈现踩坑 → [`qualcomm-mtk-pitfalls.md`](./qualcomm-mtk-pitfalls.md)
>
> 记录时间：2026-11。所有结论均来自实机验证，未验证项单列在第 5 节。

---

## 0. 一句话

**两个平台的 GPU 都能被 x86_64 程序真正驱动起来，但"怎么做"完全不同**：高通走 `kgsl` + Turnip，MTK 走 `kbase` + 自编 glibc PanVK；**唯二贯穿两平台的共性问题，是 box64 的 libc 包装层和 DXVK 的适配器筛选**。

---

## 1. 两平台对照

| 项 | 高通 | MTK |
| --- | --- | --- |
| 设备 | Redmi 平板 `2410CRP4CG`，`ro.board.platform=pineapple` | D9300 机型，`mt6989` |
| GPU（自报） | `Adreno 735`（deviceID `0x43030b00`）¹ | `PanVK-G720-Immortalis MC12` |
| Vulkan 版本 | 1.4.363 | 1.4.363 |
| 内核 GPU 接口 | `kgsl`（`/dev/kgsl-3d0`）+ `renderD128` | `kbase`（`/dev/mali0`，ioctl magic `0x80`） |
| 驱动来源 | **发行版 Turnip（kgsl 后端）**，原生 aarch64 | **自编 glibc PanVK**（`build-panvk-glibc.sh`，13 min / 24 MB） |
| 关键前置 | 设备必须醒着；必须以 uid 1000 运行 | 封存 hybris `libvulkan.so.1`；`sc_enabled: 0` |
| 容器 | droidspaces / Ubuntu 26.04 | droidspaces / Ubuntu（mtk 镜像） |
| 显示 | anland 6.x（宿主合成器 + rootless Xwayland） | 同左；MTK 额外需要 `vkms` + `mali_nsfix.ko` |
| x86_64 桥 | box64 0.4.x | box64 0.4.x |

¹ 报告头部按 `vulkaninfo` 自报写 `SM7675 / Adreno 735`，而机型 `ro.board.platform` 是 `pineapple`（SM8650 / Adreno 732）；两者不一致，**以 deviceID `0x43030b00` 为准**，平台名待复核。

---

## 2. 已验证的完整链路

### 高通

```
Windows PE
  ↓ box64
wine-10.0（x86_64，glibc 容器）
  ↓ winevulkan.so
宿主 aarch64 libvulkan            ← 入口 118/118 全通（22 instance + 96 device）
  ↓
Turnip（kgsl，原生 arm64）
  ↓
anland Wayland 合成器             ← vkcube 120 帧 rc=0，83 fps @ 640×360
```

### MTK

```
x86_64 程序
  ↓ box64（Using native(wrapped) libvulkan.so.1）
Khronos loader（glibc）
  ↓
PanVK（自编 glibc，ICD iface v5）
  ↓
kbase ioctl → /dev/mali0
```

MTK 实测探针：`P1 layers=5 → P3 实例 → P4 devices=3 → P5 选 PanVK → P6 设备+队列 → P7 submit rc=0 / fence rc=0`。

---

## 3. 各平台的核心结论（都推翻过一个"想当然"）

| 平台 | 曾经的错路 | 正确做法 | 为什么 |
| --- | --- | --- | --- |
| 高通 | 为 x86_64 **交叉编译 Turnip** | 不需要 x86_64 图形驱动：box64 直接包宿主 aarch64 `libvulkan` | 驱动是 GPU 的 ABI，不是应用的 ABI；翻译器只该翻译应用 |
| MTK | 直接用 **NDK 版 mali-panvk** | glibc 原生重编（两阶段 meson，`-Dplatforms=` 空） | NDK ICD 依赖 bionic，在 glibc 容器里 `vkCreateInstance` 就 abort |

高通这条结论的代价：symbol 缺失、TLSDESC、ABI 不匹配、present 崩溃——**所有曾被归咎于 box64 的问题，根源都是"试图翻译 GPU 驱动"这个决策本身**。放弃后只剩两个环境前提 + 一个打包问题。

---

## 4. 两平台共用的坑（跨平台，优先排查）

| 现象 | 真实原因 | 处置 |
| --- | --- | --- |
| 所有客户端卡在 `poll` | **设备休眠** | 保持屏幕唤醒 |
| `Authorization required` | 以 root 运行 | 改用会话用户 uid 1000 |
| `Library not found: /data/app/.../libc.so` | 容器内运行时跑进了 Android 应用域 | 用容器内路径 |
| `call_once not found` | box64 包装 libc 的符号表缺该项（0.3.8/0.4.3 都缺） | `callonce_shim.c` |
| `R_X86_64_TLSDESC not supported` | libstdc++ 的 `std::call_once` 状态变量 | 静态链接 libstdc++ |
| wine `could not load ntdll.so` | 缺 `libunwind.so.8` | 补包 |
| 包里缺库但日志说已 bundle | `cp -a` 保留符号链接，目标没拷 | 解引用拷贝 |
| **DXVK 起不来** | 见第 6 节（open item） | — |

**wine 打包**：CI 里构建（避免容器内装工具链），分层产出；Ubuntu 官方 `wine64:amd64` multiarch 包**不可用**——`libwine` repack 泄漏，PE 依赖 `zlib1.dll`/`libwinpthread` 未随包发布，`wineboot` 必崩。改用 **Kron4ek Wine-Builds**（box64 官方推荐）：`wine-10.0-amd64` + `wineboot -u` rc=0，prefix 786 文件。

---

## 5. 已验证 / 未验证

**已验证（有实机数据）**

| 项 | 高通 | MTK |
| --- | --- | --- |
| Vulkan 实例/设备枚举 | ✅ | ✅ |
| x86_64 GPU 命令真实执行 | ✅ vkcube 83 fps | ✅ submit/fence rc=0 |
| wine 启动 | ✅ wine-10.0 | ✅ `wineboot -u` rc=0（786 文件） |
| Vulkan 入口完整性 | ✅ 118/118 | ✅ ICD iface v5 |
| 容器 vs proot | ✅ 容器胜出 | ✅ 同 |

**未验证**

- 真实 Windows 程序/游戏执行（高通侧卡在 209 MB 完整包下载，MTK 侧未开始）
- DXVK 真游戏（依赖上一条）
- FEX 的 Vulkan thunk 成熟度（库存在，未实测）
- 真实游戏帧率、触摸→键鼠映射

---

## 6. 唯一 open item：DXVK 适配器筛选

**现象**：`system32/d3d9.dll` 确认是 DXVK PE（MZ 校验通过，wine 日志 `Loaded module ...d3d11.dll`），panvk 非一致性警告也出现了，但：

```
Direct3DCreate9     → NULL
D3D11CreateDevice   → 0x887a0004 (DXGI_ERROR_UNSUPPORTED)
```

**已排除**：DXVK 版本门槛（2.1 / 2.7.1 / 3.1.1 三代一致失败）、`DllOverrides` 语法、native `vulkan-1` stub、registry override。

**未排除**：wine10 对 mingw 编译 PE 的加载路径、box64 对 DXVK PE 的重定位 / SEH 行为。

> 注意：这**不是 panvk 独有问题**——高通侧此前只验证过 `wine --version` 和纯 C selftest，从没跑过 `wineboot + DXVK`。所以它是两平台共同的缺口。

**复现入口**：`tools/x86vk/d3d9t3.c`（文件头含完整部署命令）、prefix `/root/kwp`、全 trace 日志 `/root/full.log`。

---

## 7. 产出物索引

| 路径 | 内容 |
| --- | --- |
| `scripts/tui/build-panvk-glibc.sh` | MTK glibc PanVK 两阶段构建（13 min / 24 MB） |
| `build_rootfs-native.sh -G mediatek` | MTK 镜像入口；透传 `GPU_VENDOR_ARG` + `PANVK_GLIBC_ARG`（默认 `true`，失败回退 NDK zip） |
| `scripts/hybris/vulkan-icd-glibc.c` + `patch-vulkan-icd.sh` | hybris 三缺陷补丁（已封存，留档） |
| `tools/x86vk/probe6-glibc-panvk.c` / `probe7-x86vk.c` | MTK 端到端探针（aarch64 / x86_64） |
| `tools/x86vk/d3d9t3.c` | DXVK 适配器探针（当前排障主入口） |
| `tools/x86vk/callonce_shim.c` | box64 `call_once` 缺失垫片 |
| MTK 镜像构建 | `build_rootfs-native.sh -G mediatek`，`PANVK_GLIBC_ARG` 默认 `true` |

---

## 8. 下一步

1. **DXVK 专项**（两平台共用，收益最高）：对照 Winlator 在 Mali 上的配置，或换 wine-9.x 验证是否 wine10 特有。
2. **触发 MTK 镜像 CI 重建**，验证 `PANVK_GLIBC_ARG` 链路并发布带 glibc PanVK 的 rootfs。
3. **anland 6.x 上屏收尾**：MTK 装 `vkms` + `mali_nsfix.ko`，用 vkcube 窗口化验证呈现。
4. 补齐"完整包 → 真实程序"这一步，把帧率数据做实。

## 9. Factorio 实弹（2026-11-25 追加，MTK）

Steam depot 直下的 Factorio 2.1.24 win64 完整包（1.67GB）解压进容器后：

| 阶段 | 结果 |
|---|---|
| `factorio.exe --version`（box64+wine） | ✅ `2.1.24 (build 87808, win64, full)` rc=0 |
| GUI 启动链路 | ✅ 打通：Xwayland :1 + mini-wm + waylandbridge（修好 /etc/environment 后） |
| D3D 路径 | ❌ `vs_4_0` shader `ghost-shimmer` 撞 wined3d HLSL 翻译上限 E5017 |
| `--force-opengl` | ✅ 越过 shader 雷，**全部图集经 llvmpipe 建成（含 16384×16384）** |
| `Loading 3D bitmaps: 5` | ❌ 停滞：38 线程全 futex/ppoll，CPU 0%，wineserver 空闲；Xwayland 无恙（非 GL 死锁，GPU 无罪） |

停滞点归为 **box64 GL-wrapper/wine 交叉层的死锁族**（DXVK adapter gate 的同类，issue #3220 家族），修复属翻译器专项，非本镜像层能解。

### 9.1 平板对照实验（决定性，同日追加）

同一 Factorio.zip、同版 box64（v0.3.8 同 build）、同版 mesa（26.0.8-1ubuntu0.3）、同 Kron4ek wine、同 `--force-opengl + llvmpipe` 参数，在 pineapple 平板 Debian 容器：

- **主菜单完整显示**（截图为证：logo/登录框/虫群 3D 背景/`2.1.24 (build 87808, win64)` 角标），auth TLS check 成功后进入正常菜单态。
- 呈现次序铁律再验证：窗口 map 时屏幕必须已醒且 **Activity 在会话之前启动**——亮屏前 map 的窗口首帧丢失表现为黑屏（`xwininfo` 可见窗口存在但 screencap 全黑），重建"Activity→会话→游戏"次序即愈。
- 平板 host GL 三种 loader 覆写（kgsl/freedreno/llvmpipe）在 glxinfo 层面 `kgsl` 路径报 `failed to retrieve device information`：**交付路径实际靠 llvmpipe**，与 MTK 一致。

**归因更新**：MTK 的 "Loading 3D bitmaps" 0% 冻结是 **MTK 设备特有**问题（版本、栈组成、参数、auth 网络全部排除）。剩余嫌疑：MTK 容器 `/dev/dri`（vkms 节点探测行为）、复制式 prefix 的 DllOverrides 残留（`vulkan-1=native,builtin` 指向 ELF 伪 dll）。下一步在 MTK 用**全新 wineboot prefix** 复测即可一锤定音。

**镜像级修复（本轮落地）**：`configure-gpu.sh` MTK 分支重写——glibc PanVK 在场时**不再写任何 hybris 全局变量**（`LD_LIBRARY_PATH=/opt/hy/inst/lib` 会把所有 glibc 进程的 libvulkan/libEGL 拐进 bionic linker，实测拖死 Xwayland 与 wine 的 GL 初始化），交付环境固定 `swrast+llvmpipe+LIBGL_ALWAYS_SOFTWARE=1`；GL-over-hybris 仅作 `mali-gpu.env` 手动实验入口。

### 9.2 MTK 通关：根因是 llvmpipe 死锁 + 显存误报（2026-11-26 追加，推翻 9.1 的剩余嫌疑）

**MTK 已进 Factorio 主菜单**（加载画面、logo、精灵进度条截图为证）。§9.1 遗留的"prefix 残留 / box64 死锁族"归因不成立：全新 prefix 与完整 prefix 在同一位置冻结，wine/box64/mesa/游戏数据均字节一致（12456 文件 diff=0，icon PNG md5 相同，wine dll md5 相同）。

真正的两个独立因素：

| 因素 | 证据 | 处置 |
|---|---|---|
| **llvmpipe 在 MTK 上死锁** | `Loading 3D bitmaps: 5` 时主线程 CPU 0%，gdb 栈 `#0 syscall → libgallium-26.0.8` futex；`LP_NUM_THREADS=0`、移除 DXVK 均无效 | 换 `GALLIUM_DRIVER=softpipe`（softpipe 一次越过 3D bitmaps） |
| **DXVK 显存误报** | MTK 报 `Dedicated video memory size 4294726927 MB`（0xFFFFFFFF 按无符号解释），Factorio 按最高档建 `16384×16384` 等巨型图集；平板报 `0 MB` → `4096` 档 | 加 `--video-memory-usage=low`，图集降到 4096/虚拟图集档 |

**最终可复现启动参数**（容器 `/home/Gold/runfio_final.sh`）：

```bash
export DISPLAY=:0
export WINEPREFIX=/home/Gold/wp          # 必须用注册表完整的 prefix
export WINEDLLOVERRIDES="mscoree,msxml6=d"
export WINEESYNC=1
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=softpipe            # 关键：llvmpipe 在 MTK 死锁
export MESA_LOADER_DRIVER_OVERRIDE=swrast
export LP_NUM_THREADS=0
box64 /opt/wine-k/bin/wine64 /games/factorio/bin/x64/factorio.exe \
  --force-opengl --video-memory-usage=low
```

顺带澄清两个误导性支线：

- **GDI+/WIC PNG 解码失败**（`Failed to load sprite … InvalidParameter (2)`，`GdipLoadImageFromStream` 返回 NULL）只发生在**手工新建的 `wp2`**：wineboot 底层调用 32 位 `/opt/wine-k/bin/wine`（`Exec format error`）中途失败，注册表只写一半——PNG 解码器 CLSID `1b7cfaf4…` 条目 0 条、`InprocServer32` 595 个；完整 prefix 为 14 条 / 1190 个。用完整 prefix 即消失，与设备无关。
- **容器重启后 anland-session 陷入 auto-restart**：`Xwayland` 与 `mini-wm` 任一退出即拖垮整个会话（日志 `Xwayland or mini-wm exited (rc=1)`），systemd `Restart=on-failure` 每 5s 重拉，窗口映射时机与 Activity 错配导致黑帧。绕开办法：停掉用户服务后以 Gold 手动常驻启动（`nohup … anland-session`），确认 PID 稳定 20s 再启动游戏；呈现次序仍是 **亮屏 → Activity → 会话 → 窗口 map**。

### 9.3 PanVK 成功案例复核（2026-11-26，修正此前误判）

曾误判"缺 panfrost DRM 所以 PanVK 用不了"，查文档后确认**完全错误**：镜像里的 mali-panvk 是 Mesa PanVK 对手机 **kbase（`/dev/mali0`）** 的移植（`scripts/tui/install-panvk.sh`），根本不走 DRM/renderD；走的是 glibc 原生重编产物 + 标准 ICD。

**当前容器复核（成功复现 §报告 12.3）**：

```
/opt/panvk/libvulkan_panfrost_g.so        24MB glibc 重编产物，在场
/etc/vulkan/icd.d/panvk_g.json            api_version 1.4，指向上述 .so
VK_ICD_FILENAMES=/etc/vulkan/icd.d/panvk_g.json + tools/x86vk/probe6-glibc-panvk.c：
  neg rc=0 iface=5 / P3 rc=0 实例 / P4 rc=0 devices=1 /
  P5 name=PanVK-G720-Immortalis MC12 type=1 api=1.4 / P6b rc=0 dev / P7 后探针自身 segfault
WARNING: panvk is not a conformant Vulkan implementation
```

即 **glibc PanVK 硬件 Vulkan 在当前设备上确实可用**，GPU context 靠宿主 `mali_nsfix.ko` 在 PID namespace 内建立（`nshf_hits=94`、active）——这也说明 nsfix 不是"与 DRM 无关"，恰恰是这条硬件链的必要内核前提。

**此前探测为何全失败**（记录以免重蹈）：

- 用了 bionic 版 `/usr/local/lib/vulkan/panvk/libvulkan_panfrost.so`（NDK 构建）：标准 loader 下 `vkCreateInstance` 失败，走 libhybris `LIBVULKAN` 开关则 jemalloc TSD abort；正确产物是 `/opt/panvk/libvulkan_panfrost_g.so`（glibc）。
- 用 `/usr/share/vulkan/icd.d/panfrost_icd.json`（系统 Mesa 驱动）+ zink：`vkEnumeratePhysicalDevices` 失败——那是给 panfrost DRM 用的，不是 kbase 移植版。
- 容器 `vulkaninfo`/`vkcube` 是 x86-64 二进制（`Exec format error`），早期 glxinfo 超时是环境干扰；用 python ctypes / gcc 探针才拿到可信结果。

**仍未打通的环节**：zink 走 PanVK 时 `vkCreateInstance` 之前正常，但 Xwayland GLX 层报 `couldn't find RGB GLX visual`（`/etc/environment` 与 anland-session 都强制 `LIBGL_ALWAYS_SOFTWARE=1`/llvmpipe，zink 又被 `CPU device requested` 限制）。**DXVK 走 PanVK 的 D3D 直通**仍是 §报告 12.4 的 open item（`Direct3DCreate9` 返回 NULL，两平台共有）。所以 Factorio 当前仍用 softpipe + `--video-memory-usage=low` 通关，但"PanVK 在本机不可用"的结论作废。

**llvmpipe 死锁结论保留**：`LP_NUM_THREADS=0`（auto，非单线程）与 `=1` 均停在 `Loading 3D bitmaps: 5`、CPU 0%、栈在 libgallium futex；这是 GL 侧问题，与 Vulkan/PanVK 无关。

### 9.4 zink + PanVK 硬件路径实测：跑通但导致整机看门狗重启（2026-11-26）

继续攻硬件加速，找到让 zink 选中 PanVK 的正确配方（推翻上述"GLX visual 失败不可解"）：

```
VK_ICD_FILENAMES=/etc/vulkan/icd.d/panvk_g.json
GALLIUM_DRIVER=zink
不设 MESA_LOADER_DRIVER_OVERRIDE（设 zink 会强制 DRI loader 导致 fbconfig 失败）
不设 LIBGL_ALWAYS_SOFTWARE=1（否则 zink 被 CPU device requested 限制）
→ glxinfo -B: OpenGL renderer = zink Vulkan 1.4(PanVK-G720-Immortalis MC12 (MESA_PANVK))
→ eglinfo surfaceless: 三个 profile 全部 PanVK 硬件
```

Factorio 配置 `config/config.ini` 加 `max-texture-size=4096`（默认 0 会建 16384 图集，内存爆炸），把图集压到 4096 档，加载从 300s 降到 ~110s，`Factorio initialised` 正常达成。进程 `oom_score_adj=-1000`（box64/wine 自身设置，非脚本），不再被 lmk 杀（此前 `GAME_EXIT_CODE=137`=SIGKILL 是 lmk 干的）。

**但整机两次被打死**：硬件路径满载运行时，`adb` 卡死→offline，等 1-2 分钟恢复后发现 **`up 0 min`——看门狗强制重启**（uptime 归零，容器需手动 `droidspaces -n Ubuntu start`）。pstore / `/proc/last_kmsg` 均无记录（看门狗直接复位，未走 panic 路径）。

#### 9.4.1 细究根因：是驱动版本 bug，不是启动参数问题（对照同构案例，2026-11-27）

按 systematic-debugging 对照上游案例后，推翻"非一致性驱动笼统死锁/容器层无解"的初判：

- **同构案例 A**（[pocket-foundry#10](https://github.com/JulioFerrero/pocket-foundry/issues/10)）：Poco X6 Pro / Mali-G615（同为 CSF）+ Factorio 2.1.23 + Zink on PanVK，卡在 50%「Loading sprites」。日志链路与我们逐字一致：`PERF WARNING! > 100 copy boxes` → `kbase: CSF group 0 tiler heap OOM notification` → `timeout on subqueue` → `zink: DEVICE LOST!`。作者实测 `PANVK_KBASE_HEAP_CHUNKS=400,400`、renew interval、降画质 **全部无效**——**排除参数问题**。最终靠**换驱动版本**解决：panvk-kbase v26.3.1 加载稳定，再加 `DRIRC_CONFIGURATION=pan_enable_vertex_pipeline_stores_atomics=false` 解决读档冻结，最终稳定 60 FPS。
- **同构案例 B**（[JimVulkan/mali-panvk#13](https://github.com/JimVulkan/mali-panvk/issues/13)）：Mali G615 MC6 **整机 freeze + reboot**，与我们完全一致。作者确认是"作业提交过快无节制"（`vkWaitForFences` 处），并明确 **"Limiting fps seems to solve reboot/crash/freeze"**；维护者认同并推送修复。

**根因**：镜像内置的是 `mali-panvk v1.6.0 / 27.0.0-devel-r10`（≈案例的 RC3 老版）。Factorio 精灵加载时突发大批量 copy boxes（我们日志里 `<convert: 558ms, 1272ms>` 即佐证）在老版 kbase 上触发 tiler heap OOM；G615/G720 + CSF 下若未优雅恢复，直接拖死 GPU 看门狗→整机复位。**是驱动版本 bug + 提交速率失控，不是 `GALLIUM_DRIVER=zink` / `max-texture-size` 等启动参数配错**。

**解决（已在本机实施并端到端实测成功，2026-11-27）**：
1. 换 `panvk-kbase v26.3.1` glibc 预编译 `.so`（`libvulkan_panfrost-glibc-aarch64.so`，33.9 MB，SHA256 `063bcf0c…f5d0db6`），替换 `/opt/panvk/libvulkan_panfrost_g.so`；
   - 该库 NEEDED `libSPIRV-Tools.so`，发行版只提供静态 `.a`，用最小 no-op stub（`gcc -shared`）满足动态链接即可（SPIRV-Tools 仅 debug 反汇编用，正常渲染不调用）。
   - `build-panvk-glibc.sh` 已改为默认 `PANVK_PREBUILT=prefer` 下载该产物（1.7s，不再走 13 min 老源码编译），SHA256 校验 + stub + hybris ICD 封存 + drirc 一体化；`PANVK_PREBUILT=source` 可回退旧源码编译。
2. `configure-gpu.sh` 加 `DRIRC_CONFIGURATION=pan_enable_vertex_pipeline_stores_atomics=false`（案例证实的读档冻结修复）。
3. 设备侧新驱动 probe6：`iface=5`、实例/设备/队列 rc=0、`deviceName=Mali-G720-Immortalis MC12`（区别于老版 `PanVK-G720…`）。
4. **端到端实测**：zink+PanVK + v26.3.1 加载 Factorio，`> 100 copy boxes` 警告照常出现（旧版正是死在这里），但**无 tiler heap OOM / DEVICE LOST / 整机重启**；`Factorio initialised` 148s 达成，进程持续存活，load 峰值 97 后回落到 34，设备 up 连续未断。**新驱动彻底解决卡死**。

**CI 镜像重建**：`workflow_dispatch` run `45862681170`（commit `224b4a5`），`gpu_vendor=mediatek`/`language=zh`/`publish_release=false`（只出 artifact，不发 Release），20 个发行版×桌面变体全部构建成功。构建日志确认 `下载 panvk-kbase v26.3.1 预编译 glibc 驱动 → done (prebuilt v26.3.1)`，源码编译路径未触发。

**遗留**：
- 限帧（案例 B 证实可进一步缓解提交风暴）：Factorio `config.ini` 无现成 fps cap 项；当前未限帧但设备未重启，属可接受状态。
- `--force-vulkan` 参数在 Factorio 2.1 不存在（只有 `--force-opengl`），原生 Vulkan 渲染器路线作废。
- artifact 下载在本机网络下多次 `unexpected EOF`，未能拉到本地镜像文件；但驱动部署已由 CI 日志 + 设备实测双重验证，不影响结论。

#### 9.4.2 panic 日志实证：真正卡死根因是内存耗尽 + swap thrashing（2026-11-27）

应要求细读 panic/hang 转储，修正上述"驱动 bug 是唯一根因"的判断。`pstore`/`last_kmsg` 均空（MTK 看门狗直接硬件复位，不写 pstore），但 OPLUS AEE 保留了完整 hang 转储：

```
/data/aee_exp/pre_hang/SYS_MEMORY_INFO：
  MemTotal 15694544 kB / MemAvailable 仅 139568 kB（136 MB）/ SwapFree 11564176 kB（swap 已用 9GB）
/data/aee_exp/pre_hang/HANG_ANDROID_LOG（lmk 记录）：
  lowmemorykiller: Kill 'com.oplus.onetrace' ... reason: critical pressure and device is low on memory
  lowmemorykiller: Kill 'com.mi.health:device' ... reason: min watermark is breached and thrashing (1172%)
  ActivityManager: Killing ... (adj -10000): start timeout     ← 连系统进程都被杀，AMS 卡住
/data/aee_exp/pre_hang/SYS_CPU_INFO：
  PID 447 factorio.exe  VIRT 15G  RSS 10G  17.1% CPU  R 状态   ← 单进程吃掉 10GB RSS
  多个 winedevice.exe   VIRT 5.8G ×8                        ← 反复重启残留的 wine 进程堆积
dmesg: wdt_dump_cntcv（全 8 核 WDT 计数器转储）→ 硬件看门狗复位
```

**完整因果链**：zink+PanVK 持续渲染 → `factorio.exe` RSS 膨胀到 **10GB**（+ 残留 wine 进程）→ 15GB 物理内存耗尽、swap 用掉 9GB → **`thrashing 1172%`** → lmk 连 adj -10000 系统进程都杀、AMS `start timeout` → 整机无响应 → 看门狗复位。

**修正**：案例里的 tiler heap OOM → DEVICE LOST 是 G615（11GB）上的表现路径；本机 G720（15GB + 20GB swap）上，**驱动升级避免了 DEVICE LOST，但没避免内存爆炸**——内存才是本机卡死的直接原因。`GAME_EXIT_CODE=137`（SIGKILL）正是 lmk 杀游戏进程。

**防卡死要点（比驱动版本更关键）**：
1. 每次启动前**彻底清理残留 wine 进程**（`winedevice.exe` 堆积是放大器）；
2. `max-texture-size=4096` + `--video-memory-usage=low`（已做）；
3. 限帧减少 zink 转换缓冲堆积——仍是未解项。
4. **factorio.exe RSS 10GB 构成实测（2026-11-27，运行中抓 `/proc/<pid>/status` + `smaps`）**：

```
VmPeak 12716812 kB / VmSize 12292432 kB / VmRSS 8026568 kB / VmHWM 8158124 kB
RssAnon 995988 kB (≈1GB)  /  VmSwap 700524 kB  /  Threads 42
top VMA（全部 [anon] rw-p，按 RSS 降序，kB）：
   223484  8a040000-a0fb0000
   189188  ab5a0000-bc0c0000
   100592  82000000-89d60000
    51980  756e0000-7b740000
    34252  7bff0000-7f430000
  另有 rwxp [anon] 25920 kB + r-xp [anon] 10936 kB（box64 dynarec JIT 代码缓存）
```

**关键发现**：`VmRSS 8GB` 但 `RssAnon 仅 1GB` → 约 **7GB 是 `[anon] rw-p` 私有匿名 mmap**，不是文件映射、不是传统堆。这些 VMA 地址全落在 **32 位区间（0x65000000–0xbc0c0000）**，是 **box64 为 x86-64 客户程序模拟的 32 位地址空间 + wine 进程堆 + zink/GL 缓冲** 的混合体。单个 VMA 100–223MB，数量极多（`smaps` 全量遍历在 90s 内没跑完，说明有数千个映射）。

`winedevice.exe` 各行显示的 VIRT 5.8G 是 box64 给每个 wine 进程预留的 32 位地址空间基址（共享同一映射），**不是独立占用**；真正吃物理内存的是 `factorio.exe` 进程本身（RSS 10G）。

**结论**：10GB ≈ box64 32 位地址空间匿名映射（~7GB）+ RssAnon 真匿名页（~1GB）+ swap 计入及零碎（~2GB）。这是 **box64 + wine + zink 三层叠加的内存映射放大**，不是 Factorio 自身逻辑内存。此配置下 15GB 设备必然耗尽——**硬件路径（zink+PanVK）在这台设备上不具备长期运行条件**，softpipe 路径才是现实选择（其 VIRT/RSS 远低于此）。

### 9.5 容器内 Chrome 打不开：Wayland 环境变量缺失（2026-11-26）

**现象**：设备看门狗重启后，容器里 `google-chrome` 打不开，报
`Failed to connect to Wayland display: 没有那个文件或目录 (2)` → `Failed to initialize Wayland platform` → 退出。

**根因**：`/usr/local/bin/google-chrome` wrapper 用了 `--ozone-platform=wayland`，但：
- anland 的 Wayland socket 实际在 **`/run/anland/wayland-0`**，不在系统默认的 `/run/user/1000/`；
- 终端启动时 `XDG_RUNTIME_DIR=/run/user/1000`（错误）、`WAYLAND_DISPLAY` 为空。
Chrome 去错误路径找 socket 失败。

**修复**（`scripts/configure-chrome.sh` 的 wrapper 生成逻辑）：无条件 export
```
XDG_RUNTIME_DIR=/run/anland
WAYLAND_DISPLAY=wayland-0
```
注意用**无条件赋值**，不能用 `${VAR:=default}`——变量已被设成错误值时默认值不生效。实测修复后直接 `google-chrome about:blank` 无需任何前缀即出画面（首次启动显示服务条款页），`ERR=0`。从 anland 应用菜单启动时会话已注入正确变量，此修复主要覆盖终端/脚本启动场景。
