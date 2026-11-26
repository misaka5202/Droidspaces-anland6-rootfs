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

### 9.3 为何不能用 PanVK / GPU 加速（三层排除，2026-11-26）

用户期望用 PanVK 跑 Mali-G720 硬件加速，逐层验证后确认此设备上**无可用硬件 GL/Vulkan 路径**，属内核/驱动层限制而非容器配置：

1. **PanVK（Mesa）缺内核侧 panfrost DRM**：容器里有 glibc 版 `libvulkan_panfrost.so`（`/usr/lib/aarch64-linux-gnu/`，可正常链接 glibc），`panfrost_icd.json` 注册也正确；但宿主 `lsmod` 只有 vendor `mali_kbase_mt6989_r44` + `/dev/mali0`，**没有 panfrost.ko / renderD 节点**。zink 走该 ICD 报 `Failed to detect any valid GPUs`（`vkEnumeratePhysicalDevices` 失败）。手工 mknod 的 `card0/renderD128` 指向 mediatek_drm 显示驱动（226,0），不是 GPU，无效。
2. **Android vendor Vulkan 经 libhybris 会挂死**：宿主有 `/vendor/lib64/hw/vulkan.mali.so`，容器有 `/opt/hy/inst/lib/libvulkan.so.1.2.183` 桥（配 `HYBRIS_LD_LIBRARY_PATH`）。但 Vulkan loader 1.4.341 拒绝其旧接口（`loader interface version 0`，要求 ≥5），`glxinfo -B` 实测超时（`RC=124`），与既有"`LD_LIBRARY_PATH=/opt/hy/inst/lib` 拖死 Xwayland/wine"记录一致。
3. **llvmpipe 在该 MTK 上无条件死锁**：`LP_NUM_THREADS=0`（auto）与 `=1` 均停在 `Loading 3D bitmaps: 5`、CPU 0%、栈在 libgallium futex；与 DXVK 是否存在无关。注意 `LP_NUM_THREADS=0` 是自动全核而非单线程，此前理解有误。

**结论**：`GALLIUM_DRIVER=softpipe` + `--video-memory-usage=low` 仍是目前唯一通关组合。加载条停在 50% 的 `Parallel sprite loader` 阶段是 softpipe 单线程软件光栅化 + BCn 纹理压缩在 CPU 上跑，进程 100% CPU、RSS 2.4GB，属缓慢而非死锁（平板 44s 完成，MTK 需数分钟）。要硬件加速需内核提供 panfrost DRM 或更换支持 Mali kbase 的 Vulkan 实现，容器层无解。
