# Android 上的 x86_64 游戏运行：阶段性技术报告

> 设备：Qualcomm SM7675 + Adreno 735（`vulkaninfo` 自报，deviceID `0x43030b00`），
> Android 16，KernelSU，8 核三丛集（2×1900 / 4×2611 / 1×2803 MHz）
> 容器：droidspaces，Ubuntu 26.04，无 PID namespace 共享能力
> 显示：anland 6.x（Wayland 合成器 + rootless Xwayland）

---

## 1. 摘要

这几天的工作可以归结为一句话：**打通了从 Windows 游戏到 Android GPU 的完整链路，并且否掉了一条走了很久的错路。**

最终验证通过的链路：

```
Windows PE
  ↓ box64 翻译
wine-10.0（x86_64，glibc 容器内运行）      ✅ 已验证启动
  ↓ winevulkan.so
宿主 aarch64 libvulkan                     ✅ 已验证 118/118 入口
  ↓
Turnip（kgsl 后端，原生 arm64）             ✅ 已验证枚举 + 83 fps 呈现
  ↓
anland Wayland 合成器                       ✅ 已验证 surface + present mode
```

关键数字：

| 指标 | 结果 |
|---|---|
| x86_64 Vulkan 呈现帧率 | **83 fps @ 640×360**（120 帧 / 1431 ms） |
| Vulkan 入口可解析性 | **118 / 118**（22 instance + 96 device） |
| wine 启动 | **wine-10.0**，从 6.9 MB 最小包启动成功 |
| 需要 x86_64 图形驱动吗 | **不需要**（这是本报告最重要的结论） |

---

## 2. 最重要的结论：不要为 x86_64 交叉编译 Turnip

这是整个过程中代价最大的一条弯路，值得写在最前面。

### 2.1 曾经的做法

直觉上，Proton/wine 是 x86_64 的，所以它加载的 Vulkan ICD 也必须是 x86_64 的。于是投入大量精力构建一个 x86_64 的 Turnip。

它确实工作了一部分：

```
GPU0:
	apiVersion   = 1.4.363
	deviceName   = Turnip Adreno (TM) 735
	driverID     = DRIVER_ID_MESA_TURNIP
	driverInfo   = Mesa 26.3.1 (git-fec8830e9c)
```

设备枚举、compute dispatch（2000 次，checksum 一致）都通过了。但**一旦真正尝试呈现一帧就崩溃**。

### 2.2 三个必须同时满足的构建条件

| 条件 | 缺失后果 |
|---|---|
| `-Dfreedreno-kmds=kgsl` | 驱动无 kgsl 后端（`grep kgsl-3d0` = 0），完全看不到 GPU。Android 通过 kgsl 而非桌面 DRM 暴露 GPU，发行版构建默认为 msm |
| `-Dplatforms=x11,wayland` | 实例只有 `VK_EXT_headless_surface`，能枚举不能呈现 |
| **GBM** | swapchain 图像分配失败，`Selected GPU` 之后立刻 SIGABRT（`x64pc=0x1`）/ SIGSEGV |

第三条是不可逾越的：

```
meson.build:562: ERROR: Feature gbm cannot be enabled: GBM only supports DRM/KMS platforms
```

加上 gallium 驱动后：

```
src/gbm/backends/dri/meson.build:18: ERROR: Unknown variable "inc_st_dri"
```

**Mesa 的 `src/gbm` 是 gallium 的消费者，靠 pipe driver 分配 buffer，其 DRI 后端还需要完整的 GL state tracker。纯 Vulkan 构建在物理上不可能满足这一条。**

### 2.3 正确做法

让 box64 包装**宿主的** libvulkan：

```
[BOX64] Using native(wrapped) libvulkan.so.1
Selected GPU 0: Turnip Adreno (TM) 735
```

镜像里那个 aarch64 Turnip 本身就是 kgsl 版。于是整条子任务崩塌：

- 不需要 kgsl 交叉编译
- 不需要 `-static-libstdc++`（那只是为了绕 box64 缺 TLSDESC）
- 不需要 `call_once` shim
- 不需要 WSI / GBM 构建参数

**这也正是 GameNative / Winlator 的实际做法：翻译应用和 Windows 层，不翻译图形驱动。**

---

## 3. 呈现链路：两个伪装成驱动故障的前提

这两个问题让所有客户端看起来像"驱动挂死"，实际都不是。

### 3.1 设备必须醒着

`mWakefulness=Asleep` 时合成器不合成任何窗口，`wl_surface.frame` 回调永不到达，客户端在 `poll` 里死等到超时。

判据很关键：**box64、FEX、aarch64 原生二进制三者行为完全一致**。三个运行时同时以同样方式失败，说明问题不在运行时选择。

唤醒后的对照：

```
box64 + 原生 wrapped libvulkan:  rc=0
aarch64 原生:                    rc=0
```

### 3.2 必须以会话用户（uid 1000）运行

anland 的 Xwayland 和 Wayland socket 都属于会话用户。root 进程访问 X 会得到：

```
Authorization required, but no authorization protocol specified
XCB failed to connect to the X server
```

切换到会话用户后立即正常：

```
Surface types: count = 2
Present Modes: count = 4
```

### 3.3 X11 路径不能用于 GPU 呈现

即使授权修好，X11 也不是可行路径：

```
MESA: info: vulkan: No DRI3 support detected - required for presentation
Selected GPU 2: llvmpipe (LLVM 21.1.8, 128 bits), type: Cpu
Illegal instruction
```

`rootless Xwayland` 没有 DRI3（它走标准 DRM，而 Android 只有 kgsl），客户端退到 llvmpipe 软件渲染，然后在 box64 下执行 `Illegal instruction`。

**Wayland 的 dmabuf 是唯一能直通 kgsl 的路。**

---

## 4. 性能对比：box64 vs FEX

全部绑核到 cpu7（2803 MHz，capacity 1024），5–7 轮取中位数，checksum 一致确保计算正确。

### 4.1 纯计算

| 负载 | box64 | FEX | 结果 |
|---|---|---|---|
| 整数 ALU（40M 迭代） | 102 ms | 86 ms | FEX 快 1.18× |
| 双精度浮点（30M 迭代） | 153 ms | 40 ms | **FEX 快 3.80×** |
| 内存顺序访问 | 2.79 ms | 2.69 ms | 持平 |
| 分支密集（20M） | 25.9 ms | 29.5 ms | box64 快 1.14× |

浮点那 3.8 倍**调不掉**——尝试过的所有配置都纹丝不动：

```
box64 default      153.2 ms
box64 FASTMEM=1    153.2 ms
box64 STRONGMEM=0  153.3 ms
box64 SAFEFLAGS=0  153.3 ms
FEX                 40.3 ms
```

### 4.2 syscall 与内存管理

| 负载 | box64 | FEX | 结果 |
|---|---|---|---|
| getpid ×200k | 25.6 ms | 32.7 ms | box64 快 1.27× |
| clock_gettime ×200k | 36.6 ms | 40.7 ms | box64 快 1.11× |
| mmap/munmap ×20k | 2.85 ms | 1.31 ms | **FEX 快 2.17×** |

### 4.3 GPU 负载（同一份 x86_64 Turnip，2000 次 dispatch）

| 阶段 | box64 | FEX | 结果 |
|---|---|---|---|
| init（instance + device） | 205.6 ms | 230.7 ms | box64 快 1.12× |
| upload 8 MB | 1.81 ms | 1.79 ms | 持平 |
| dispatch（每次 fence） | 1940 ms | 2149 ms | box64 快 1.11× |
| dispatch（批量录制） | 79.7 ms | 91.0 ms | box64 快 1.14× |
| readback 8 MB | 1.26 ms | 1.09 ms | FEX 快 1.16× |

### 4.4 解读

**GPU 驱动路径上两者几乎打平**，与纯计算浮点 3.8 倍的差距形成鲜明对比。

原因：`vkCmdDispatch` 这类调用的 CPU 侧工作主要是往命令缓冲写字节，不是浮点密集；init 阶段是 ioctl 密集，box64 的 syscall 转发确实更快。

**对真实游戏的含义**（推断，未实测）：游戏逻辑（物理/音频/AI）是浮点密集的，FEX 在那部分明显领先；GPU 提交部分两者差不多。所以整体上 FEX 可能更快。

**FEX 另有架构性优势**：`/usr/share/fex-emu/GuestThunks/` 里有 `libvulkan-guest.so`、`libdrm-guest.so`、`libwayland-client-guest.so`。这意味着 FEX 能把 x86_64 的 Vulkan 调用 thunk 到 aarch64 原生驱动，驱动零翻译开销。这一条**尚未实测**。

---

## 5. wine 层

### 5.1 为什么在 CI 构建

设备侧拉 `libwine:amd64`（205 MB）+ 181 个依赖包跑不完：链路在约 20 MB 处断开。runner 是 x86_64，下载解包都是数据中心速度，而且**能原生运行结果**——打包前用 mingw 把 `wine-selftest.c` 编成 Windows PE 并在 wine 下执行，确认这一层真的能跑才发出去。

### 5.2 分层产出

| artifact | 大小 | 用途 |
|---|---|---|
| `wine-mini-x86_64` | 6.9 MB | launcher + x86_64-unix + wineserver + 依赖，验证链路可启动 |
| `wine-bundle-x86_64` | 209 MB | 加内置 PE dll（589 MB 解压后），执行 Windows 程序时需要 |

设备侧验证：

```
$ box64 /opt/wine/usr/lib/x86_64-linux-gnu/wine/wine --version
wine-10.0 (Ubuntu 10.0~repack-12ubuntu1)
```

### 5.3 打包时的四个陷阱

| 陷阱 | 说明 |
|---|---|
| wine 10 不提供 `/usr/bin/wine64` 和 `libwine.so` | 真正入口是 `/usr/lib/x86_64-linux-gnu/wine/wine`，`wine64` 由 alternatives 机制创建。必须按路径而非包归属选文件 |
| `ntdll.so` 需要 `libunwind.so.8` | apt 装 `wine64` 不会带它，缺了 wine 连 ntdll 都 dlopen 不了 |
| 依赖 soname 是符号链接 | `cp -a` 只拷链接不拷目标，tar 会丢弃断链。日志报 `bundled libunwind.so.8` 但包里实际没有。必须 `cp -L` |
| apt 下载耗时不稳定 | 同样一步在 runner 上既跑过 2 分钟也跑过 20 分钟以上，需要缓存 `/var/cache/apt/archives` |

---

## 6. 容器 vs proot：另一个结论

`droidspaces` v7.0.0 的 PID namespace **无法关闭**：

- CLI 无相关参数（`--privileged` 只支持 nomask/nocaps/noseccomp/shared/full）
- `container.config` 无对应字段
- 上游 `config.h` 有 `DS_NET_*`（含共享宿主网络的选项）但**没有 `DS_PID_*`**
- `boot/init.c:124` 的注释确认 PID namespace 在 init 运行前已由父进程创建

而且即使能关也不该关：**systemd 必须是 PID 1**，而 anland 的整个会话体系（`anland-session`、`systemctl --user`、`systemd-run --user`）都建立在 systemd 用户服务上。关掉 PID namespace = 没有 systemd = 会话起不来。

不过这不构成性能问题。容器相比 proot 的优势是真实的：没有 ptrace 的每次 syscall 两次陷入。GameNative 用 proot 是因为它让整个运行时跑在 Android bionic 上，能复用现成的 bionic 构建；换到 glibc 容器等于重做它的运行时层。

---

## 7. 已验证 / 未验证

### 已验证（有实机数据）

| 项目 | 证据 |
|---|---|
| anland Wayland 协议完整性 | `xdg_wm_base` v3、`zwp_linux_dmabuf_v1` v3、`viewporter`、`fractional_scale`、`xwayland_shell_v1` 全有 |
| Turnip kgsl 后端工作 | `Turnip Adreno (TM) 735`，apiVersion 1.4.363 |
| x86_64 Vulkan 呈现 | vkcube 10/60/120 帧全部 `rc=0`，83 fps @ 640×360 |
| Vulkan 入口完整性 | 118/118 |
| wine 启动 | `wine-10.0` |
| GPU 设备节点可访问 | `open("/dev/kgsl-3d0")` 和 `/dev/dri/renderD128` 成功；`DRM_IOCTL_VERSION` 返回真实版本 |

### 未验证

| 项目 | 阻塞 |
|---|---|
| 真实 Windows 程序执行 | 需要 209 MB 完整包，当前网络下不来 |
| DXVK 真游戏 | 依赖上一条 |
| FEX 的 Vulkan thunk | thunk 库存在但未实测其成熟度 |
| 真实游戏帧率 | 未测 |
| 触摸→键鼠映射 | 未开始 |

---

## 8. 踩过的坑速查

| 现象 | 真实原因 |
|---|---|
| `Library not found: /data/app/.../libc.so` | 容器内运行时（Android 应用域） |
| vkcube `Selected GPU` 后 SIGABRT `x64pc=0x1` | GBM 未编译（swapchain 分配器为空） |
| 所有客户端卡在 `poll` | 设备休眠 |
| `Authorization required` | 以 root 运行而非会话用户 |
| Turnip 报 "no physical device" | 发行版构建无 kgsl 后端 |
| `call_once not found` | box64 包装 libc 的符号表缺该项（0.3.8/0.4.3 都缺） |
| `R_X86_64_TLSDESC not supported` | libstdc++ 的 `std::call_once` 状态变量，只能靠静态链接 libstdc++ 规避 |
| `wl_display_create_queue_with_name not found` | box64 包装了旧版宿主 libwayland |
| wine `could not load ntdll.so` | 缺 `libunwind.so.8` |
| 包里缺库但日志说已 bundle | `cp -a` 保留符号链接，目标未拷 |

---

## 9. 后续路线

### 短期

1. **裁剪 full 包**：589 MB 的 PE dll 里，跑 D3D 测试用不到打印机、扫描仪、TWAIN、ODBC、多媒体等。只保留 `d3d9/d3d11/dxgi/d3d10core` + `ntdll/kernel32/user32/gdi32/ole32` 等核心，目标压到 40–60 MB。这既解决下载问题，也是"开箱即用"的体积要求。
2. **跑通 Windows PE 执行**：用裁剪后的包跑 `wine-selftest.exe`，确认 wine 能真正执行程序。
3. **DXVK 验证**：装上 DXVK v3.1.1（已获取），跑一个 D3D9 测试。

### 中期

4. **改用 FEX**：架构更干净（不需要 shim、不需要静态链接、不需要隐藏原生库），且可能通过 thunk 让驱动零翻译。需要实测其 Vulkan thunk 成熟度。
5. **GameNative 调用方式改造**：把 `fork + proot -r rootfs wine ...` 换成向 anland daemon 发 `APP_LAUNCH` 请求（binder 协议已实现并验证）。
6. **触摸→键鼠映射**：可复用 GameNative 的实现。

### 体积与交付

7. 参照 GameNative 的 `.tzst` 按需下载模式，把运行时分层发布。

---

## 10. 产出物

### 仓库 `Droidspaces-anland6-rootfs`

**CI workflows**

| 文件 | 作用 |
|---|---|
| `.github/workflows/build-turnip-kgsl-x86_64.yml` | 从 Mesa 源码构建带 kgsl 的 Turnip。带三道硬门禁：`kgsl-3d0` 字符串、三个 surface 扩展、`gbm_bo_create`，任何一项缺失都不上传 |
| `.github/workflows/build-wine-bundle.yml` | 构建 wine + DXVK 包，在 runner 上原生执行 Windows PE 自测 |
| `.github/workflows/build-probe-x86vk.yml` | 早期探针镜像（已被正确路径取代，保留作参考） |

**工具（`tools/x86vk/`）**

| 文件 | 作用 |
|---|---|
| `NOTES.md` | 技术笔记：哪些路能走、哪些是死路、为什么 |
| `xvk-run` | 一键运行脚本。自动唤醒屏幕、切换会话用户、恢复残留的 `.hidden` 库、故意不设 `VK_ICD_FILENAMES` |
| `procaddr.c` | 遍历 118 个 Vulkan 入口，检查包装层是否有缺口 |
| `callonce_shim.c` | `call_once` 的 x86_64 shim（走错路时的产物，正确路径下已不需要） |
| `wine-selftest.c` | 给 CI 用的 Windows PE 自测程序 |
| `elf-needed.py` | DT_NEEDED 解析（CI 依赖校验用） |
| `Dockerfile` / `xvk-test` | 早期探针镜像（同已废弃） |

**其他改动**

- `scripts/tui/install-steam.sh`：DXVK 改为 `STEAM_DXVK=1` 显式开关（默认仍 wined3d，避免无驱动时黑屏）；修正 ICD 文件名查找（Arch 用 `freedreno_icd.json`，此前只找 `.x86_64.json` 从未命中）
- `docs/qualcomm-mtk-pitfalls.md`：高通/MTK 平台坑位

### 仓库 `anland`

- v6.2.14、`anland-shell` v1.1.4 已发布
- 透明 `AppLaunchActivity`（daemon `APP_LAUNCH` + binder `T_APP_LAUNCH = 19`），一个 X toplevel 一个 `AwlWindowActivity`，任务卡片显示应用自身图标
- `.github/workflows/build.yml` 拆分独立的 release job，keystore 缓存

---

## 11. 一句话总结

**x86_64 游戏在 Android 上运行的核心不在翻译器选择，而在于让图形驱动保持原生。**

所有曾被归咎于 box64 的问题——符号缺失、TLSDESC、ABI 不匹配、present 崩溃——根源都是"试图翻译 GPU 驱动"这一决策本身。放弃这个决策后，剩下的只是两个环境前提（屏幕唤醒、会话用户）和一个 Windows 层的打包问题。

---

## 12. MTK 路线复刻成功（2026-11-25，mt6989 / Immortalis-G715）

高通平板的结论（box64 包 host aarch64 libvulkan）在 MTK 上撞了新的墙，最终换道打通：

### 12.1 三堵墙与最终通道

| 墙 | 现象 | 结局 |
|---|---|---|
| NDK 版 mali-panvk 在 glibc 容器加载 | `vkCreateInstance` 里 bionic jemalloc `Error setting TSD` abort；hybris `android_dlopen` 与 bionic 预热都救不了 | **绕开**：驱动只依赖 `/dev/mali0` ioctl/mmap，glibc 原生重编 |
| hybris libvulkan 补丁链 | vulkan.c 三缺陷（gipa NULL 解引用 / IDLOAD 不认 ICD / LIBVULKAN 只吃 bionic）逐一打补丁后 aarch64 P1–P2 通过 | **封存**：glibc 构建出现后不再需要（补丁仍入库） |
| Ubuntu wine64:amd64 multiarch | 真 PE 依赖 zlib1.dll/libwinpthread，libwine 包不发，wineboot 半途崩 | **换 Kron4ek Wine-Builds**（box64 官方推荐） |

### 12.2 glibc PanVK 构建配方（`scripts/tui/build-panvk-glibc.sh`）

- stage1 原生构建 mesa_clc / vtn_bindgen2 / panfrost_compile；stage2 `-Dplatforms=`（空，绕开被 fork 删除的 src/loader）+ `-Dmesa-clc=system`。
- 容器实测全程 13 分钟（D9300 大核），产物 24MB。
- 部署要点：`/etc/vulkan/icd.d/panvk_g.json` + **封存 hybris 的 libvulkan.so.1**（`.hybris-off`，否则 `/etc/environment` 的 LD_LIBRARY_PATH 把 ICD 拐进 bionic linker 报 namespace 错）。
- kbase 协议备忘：ioctl magic `0x80`；CSF 握手 `CSF_VERSION_CHECK(_IOWR,52,{u16,u16})` 先行（nr=0 对 CSF 是拒答的 dummy），`SET_FLAGS` 必须在 tracking page mmap 之前。

### 12.3 实测结果

```
aarch64: vulkaninfo → PanVK-G720-Immortalis MC12, Vulkan 1.4.363, ICD iface v5
x86_64(box64): P1 layers=5 P3 实例 P4 devices=3 P5 PanVK P6b 设备 P7 submit/fence 全 rc=0
               [BOX64] Using native(wrapped) libvulkan.so.1
```

wine 层：Kron4ek wine-10.0 amd64 + DXVK 2.7.1 部署中，见工具 `tools/x86vk/` 的 d3d9 探针（`Direct3DCreate9` 触发 DXVK→Vulkan 全链）。

### 12.4 wine/DXVK 现状（本次会话结束时）

- **Kron4ek wine-10.0-amd64 在 box64 下 `wineboot -u` rc=0**，prefix 完整（786 文件）。Ubuntu 官方 `wine64:amd64` 不可用（PE 链缺 zlib1/libwinpthread 依赖，repack 泄漏）。
- **DXVK 2.1 / 2.7.1 / 3.1.1 三代一致**：`system32/d3d9.dll`（MZ 确认被 wine 加载，日志 `Loaded module ...d3d11.dll at 7fffa f0000`）、panvk 非一致性警告出现，但 `Direct3DCreate9` 返回 NULL、`D3D11CreateDevice` 返回 `0x887a0004 (DXGI_ERROR_UNSUPPORTED)`。
- 已排除：DllOverrides 语法、native vulkan-1 stub、DXVK 版本 gate（2.1 无 EDS 要求同样失败）、registry override。未排除：wine10 对 mingw 编译 PE 的加载路径、box64 对 DXVK PE 的重定位/SEH 行为。**这是高通/MTK 共有的 open item，非 panvk 独有**——高通侧此前只验证过 wine --version + 纯 C selftest，从未跑过 wineboot+DXVK。
- 排查入口：`tools/x86vk/d3d9t3.c`（含部署命令注释）、prefix `/root/kwp`、日志 `/root/n_*.log`、`/root/full.log`（WINEDEBUG=+all 全 trace 在手）。

---

*报告基于 2026-11 期间的实机验证。所有数据来自设备实测，未验证项已在第 7 节明确标注。*
