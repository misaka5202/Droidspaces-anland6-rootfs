[文档目录](README.md) · [项目主页](../../README.md)

# 桌面启动与 Anland Wayland

## 组件职责

显示链路为宿主侧三进程 + 容器内一会话。

| 组件 | 位置 | 职责 | 不负责 |
| --- | --- | --- | --- |
| `waylandbridge`（`anland-awl` 模块） | 宿主，root 守护进程 | Wayland 服务端：接收容器客户端，首帧到达后回调 `window_created` | 不渲染 |
| `com.anlandnext` | 宿主，app | 显示端：每窗口一个 `AwlWindowActivity`，持有 BLAST surface | 不启动进程 |
| `com.anland.shell` | 宿主，app | 启动器：枚举容器与应用，注入环境并启动 | 不创建窗口 |
| `anland-session`（`anlandx`） | 容器内 | 会话：wayland 链接、rootless Xwayland、mini-wm | — |

```text
容器应用 ──wayland──> waylandbridge ──binder──> com.anlandnext
                                                      │
                                              AwlWindowActivity
                                                      │
                                              SurfaceFlinger
```

`com.anlandnext` 是窗口的唯一创建者。仅装 `anland-shell` 时应用列表可用但无窗口；
仅装 `com.anlandnext` 时无启动入口。

### 日志分界

```bash
logcat -d | grep 'anland-wl:' | tail -20
```

| 日志 | 含义 |
| --- | --- |
| `client connected` / `surface N created` | 客户端已接入 |
| `surface N mapped (role=1)` | 首帧已提交 |
| `window WxH attached` | Android 窗口已附着 |

`created` 无 `mapped` → 客户端未提交缓冲区，问题在应用侧。
`mapped` 无 `window attached` → `com.anlandnext` 侧。

## 桌面自动启动

启用 `desktop_autostart` 后，RootFS 会安装 `desktop-session.service`。它以 UID 1000 的普通用户运行，并读取 `/etc/droidspaces-desktop.conf` 选择会话。

| 桌面与后端 | 手动启动命令 |
| --- | --- |
| KDE + X11（Arch 不支持） | `DISPLAY=:5 startplasma-x11` |
| KDE + Anland Wayland | `startplasma-wayland` |
| KDE Mobile + Anland Wayland | `startplasmamobile` |
| GNOME + Anland Wayland | `gnome-session --session=gnome` |
| Anland Next | `/usr/bin/anland-session` |
| Niri | `/usr/bin/niri-anland` |
| Hyprland | `/usr/bin/hyprland-anland` |
| Mango | `/usr/bin/mango-anland` |
| Denial | `/usr/bin/denial-anland` |

服务在桌面异常退出后等待 2 秒重启；60 秒内连续失败超过 5 次会暂停重试。正常退出不会触发重启。

### X11

X11 桌面使用 `DISPLAY=:5`，需要在 Android 端安装并启动 Termux:X11。若关闭自动启动，可在容器内运行：

```bash
startplasma-x11
```

### Wayland 和 Anland 宿主端配置

Anland Wayland 支持 Debian 13、Ubuntu 26、Fedora 43/44 和 Arch。Arch KDE 仅使用 Anland Wayland；KDE 使用 patched KWin/Xwayland，GNOME 使用 patched Mutter。GNOME 在这些发行版上安装完整桌面和基础应用。Niri、Hyprland、Mango、Denial 提供轻量会话、终端、XDG portal、音频和字体，用户可自行添加桌面应用。它们的 ARM64 包由 [`droidspaces-package`](https://github.com/Goldzxcbug/droidspaces-package) 发布，RootFS 构建时从对应 Release 安装。

轻量 compositor 各自使用独立的 `desktops/<slug>.sh` profile；profile 会将会话与 Anland/Mesa 环境写入 `/etc/environment`。统一桌面启动入口直接运行包提供的 compositor 命令，不使用 `--session`。

> **注意：以下只适用于 Anland 6.x。**
> 如果照别的教程装了 `virtual-drm-daemon.zip` / `app-debug.apk`（5.x 那一套），
> 或者容器配置里有 `/data/local/tmp/display_daemon.sock -> /run/display.sock`
> 这条绑定，**请全部移除**。5.x 靠私有显示协议 + 打过补丁的合成器，
> 6.x 用 Wayland 本身做帧交换，两套路由同时存在会互相打断，表现为能连上但没画面。

### 自动配置

```bash
adb push scripts/setup-anland6-host.sh /data/local/tmp/
adb shell su -c 'sh /data/local/tmp/setup-anland6-host.sh'

adb push scripts/verify-anland6-host.sh /data/local/tmp/
adb shell su -c 'sh /data/local/tmp/verify-anland6-host.sh'
```

`setup` 幂等，执行：模块安装、APK 安装、daemon 配置写入（`auto_attach=1`、
`scale_mode=1`）、容器绑定挂载补写。
`verify` 按宿主 / 容器 / 显示三层逐项校验，只读。

### 手动配置

宿主侧四件，缺任一件无画面。

| # | 文件 | 装法 | 职责 | 缺失表现 |
| --- | --- | --- | --- | --- |
| 1 | `module/anland-awl.zip` | root 管理器刷入，reboot | `waylandbridge`：Wayland 服务端 | 无 socket，会话不启动 |
| 2 | `anland-wayland.apk` | `pm install` | `com.anlandnext`：每窗口一个 `AwlWindowActivity` | 应用可启动，无窗口 |
| 3 | `anland-shell.apk` | `pm install` + 授予 root | `com.anland.shell`：列容器 / 列应用 / 启动 | 无启动入口 |
| 4 | `anlandx.tar.gz` | 本仓库镜像已内置 | 容器内 `anlandx` 会话 | 无 `anland-session` |

外部镜像需手动安装第 4 件：

```bash
tar xzf anlandx.tar.gz && bash anlandx/setupanlandx.sh
```

### 下载清单

**四件里只有 `anland-shell.apk` 要用补丁版**（上游还没更新）。

| 文件 | 从哪下 | 直链 |
| --- | --- | --- |
| `module/anland-awl.zip` | **改版，非上游**（上游 6.2 输入不可用） | [misaka5202/anland](https://github.com/misaka5202/anland/releases/latest)（最新发布） |
| `anland-wayland.apk` | 同一个压缩包里 | 同上 |
| **`anland-shell.apk`** | **补丁版，不要用上游 1.1** | **[misaka5202/anland-shell v1.1.3](https://github.com/misaka5202/anland-shell/releases/tag/v1.1.3)** |
| `anlandx.tar.gz` | 本仓库镜像已内置 | — |


**为什么第 1、2、4 项必须用改版**

上游 6.2 有三个让桌面输入不可用的缺陷：

1. **软键盘文本到不了应用。** 不实现 `zwp_text_input_v3` 的应用（Konsole/XTerm
   这类终端）什么都收不到：`awl_ime_text()` 在「没有可用的 text_input」时直接
   丢弃 commit。改版把 ASCII 文本降级成 `wl_keyboard` 按键 —— 回车键走的就是
   这条路，已实测可用。
2. **中文输入不可能。** daemon 没实现 `zwp_input_method_v2`，容器内的 fcitx5
   拿着字无处可送。改版实现了它。
3. **额外按键栏有一部分是死的。** 最左一列（ESC/TAB）落在系统返回手势区里，
   touch 被手势吃掉。改版用 `WindowInsets.Type.systemGestures()` 给底栏让边。

4. **应用窗口起不来**：xdg configure 的 serial 为 0，客户端丢弃后 surface 永不 map。
   改版改用 `next_serial`。
5. **中文在终端里落不了地**：终端没有 `text_input`，改版把文本放进 Wayland
   选区，再发该终端的粘贴键（`config.json` 的 `paste_shortcut`，默认
   `ctrl+shift+v`）。
6. **X11 应用读不到剪贴板**：选区只声明了 `text/plain*`，而 Konsole 这类
   Xwayland 客户端要的是 `UTF8_STRING`。改版补上 `UTF8_STRING` / `TEXT` /
   `STRING`。
7. **重装模块会丢 `config.json`**：`runtime_dir` 退回编译默认值，和容器的
   `bind_mounts` 对不上，socket 在容器里看不见。`customize.sh` 现在会按容器
   bind 源目录重新生成。

此外还包含：5.x UI 移植（额外按键栏、可调透明度的沉浸式底栏）、新增文案的
i18n、以及 IME 合成按键的 evdev 码完整映射（它们恒为 `scanCode == 0`）。
**为什么 anland-shell 要用补丁版**

上游最新发布是 **1.1（2026-09-17）**，它调 `droidspaces show --format`；
而 **Droidspaces 7.2.0（2026-11-07）删掉了这个参数**，改用 `show --json`。
旧参数会把 `Unknown or incomplete option: --format` 打到 **stdout**，却仍然
**返回 0** —— anland-shell 因此解析出空的 running 集合：

```
所有容器显示 stopped → 点 APPS 被拦 → 应用启动不了 → 没有画面
```

修复 PR [SuperTurtleDev/anland-shell#2](https://github.com/SuperTurtleDev/anland-shell/pull/2)
**2026-11-13 就提了，至今未合并**，所以官方 release 里没有修好的包。

补丁版 `v1.1.3` 有两处修复：

- 先请求 `show --json`，失败再回退 `show --format`，解析前剥离 ANSI 转义
  （即上面那个上游 PR，至今未合并）；
- **给每条 `droidspaces run` 片段前置容器 `PATH`**。`run` 继承的是**宿主**
  PATH（里面没有 `/usr/bin`），容器里的 `getent` 等命令全部不可见，用户探测
  静默失败，于是点任何应用都报 `user Gold not found in container`。

已在 OPPO PHZ110（MT6989 / Android 17）和小米 2410CRP4CG（Android 16）上
验证端到端可用，两者都是 Droidspaces 7.2.0。**上游合并后可换回官方包。**

自己判断需不需要补丁版：

```bash
su -c 'droidspaces show --json'    # 有输出
su -c 'droidspaces show --format'  # 报 Unknown or incomplete option
# 两条同时成立 → 你需要补丁版
```

> `setup-anland6-host.sh` 会读 Droidspaces 版本，≥7.2.0 时自动从
> anland-shell 的最新发布下载补丁版，不用手动挑。

下面按顺序做。**任何一步没做对都没有画面**，而且失败现象往往很相似
（黑屏 / 列表为空 / 窗口不出现），所以做完建议用诊断脚本验一次。

**① 刷 `anland-awl` 模块并重启**

从 **[misaka5202/anland](https://github.com/misaka5202/anland/releases/latest)** 下载 `anland-awl.zip`（上游 6.2 有下面说的输入缺陷），用 KernelSU/APatch 刷入。

**刷完必须重启。** 模块在 `modules_update/` 里躺着的时候，`waylandbridge`
不会运行，`/data/local/tmp/awl/wayland-0` 也就不存在 —— 这是最常见的失败原因。

重启后确认：

```bash
su -c 'pidof waylandbridge'                  # 应该有 pid
su -c 'ls -l /data/local/tmp/awl/wayland-0'  # 应该是 srw-rw-rw-
su -c 'service list | grep anland.host'      # 应该有一行
```

**② 装宿主 APK**

```bash
pm install -r anland-wayland.apk      # com.anlandnext：每个窗口一个 Android Activity
pm install -r anland-shell.apk        # com.anland.shell：容器/应用启动器
```

`com.anlandnext` 是真正画窗口的消费者，**不装它就没有任何画面**。

> **`anland-shell` 有一个已知兼容问题**：官方 1.1 调 `droidspaces show --format`，
> 而 Droidspaces **7.2.0 起改用 `show --json`**，旧参数会报错但仍返回 0，
> 导致所有容器显示成 `stopped`、应用网格点不开。
>
> 用 [`misaka5202/anland-shell v1.1.3`](https://github.com/misaka5202/anland-shell/releases/tag/v1.1.3)
> 的补丁版（先试 `--json` 再回退）。上游修复见
> [PR #2](https://github.com/SuperTurtleDev/anland-shell/pull/2)，合并后可换回官方包。
>
> 判断方法：`droidspaces show --json` 有输出、`droidspaces show --format` 报
> `Unknown or incomplete option` → 你就需要补丁版。

装完还要在 root 管理器里**给 `com.anland.shell` 授予 root**。它靠 `su` 读
`/data/local/Droidspaces/Containers`，没授权会显示 `no containers defined`。

**③ 容器绑定挂载**

daemon 发布点 `/data/local/tmp/awl/wayland-0`（`runtime_dir`），容器内
`anland-session` 硬编码 `/run/anland/wayland-0`。容器 `/run` 为独立 tmpfs，
与宿主不共享，需显式绑定：

```text
/data/local/tmp/awl  ->  /run/anland
```

```bash
su -c 'droidspaces --name=<name> -B /data/local/tmp/awl:/run/anland start'
```

或写入 `container.config`：

```ini
bind_mounts=/data/local/tmp/awl:/run/anland
```

Droidspaces 持久化该字段，无需每次启动带 `-B`。缺失时容器内报：

```text
anland-session: no wayland socket at /run/anland/wayland-0 (anland daemon down?)
```

`daemon down?` 不成立 —— daemon 正常运行，容器无法访问该路径。

校验：

```bash
su -c 'droidspaces --name=<name> run -- ls -l /run/anland/wayland-0'
# srw-rw-rw- 1 root root 0 ...
```

非 socket 或 `No such file` 即未生效。

路径不可改：`anland-session` 硬编码 `/run/anland/wayland-0`，daemon 侧由
`config.json` 的 `runtime_dir` 决定，容器侧未暴露对应配置项。
`socket_listen=0` 的 binder-fd 模式要求客户端直接使用 Android binder，
容器内 Linux 应用不支持。

Droidspaces 二进制仅含 5.x `/run/display.sock` 路径，`/run/anland` 命中 0 次，
该挂载不会被自动添加。

**④ 容器设置**

在 Droidspaces 里给这个容器开启：硬件访问（`--hw-access` / `--gpu`）、
特权模式并勾选 `nocaps` 和 `noseccomp`。

**MTK / Mali 设备需要 `mali_nsfix`**：镜像里的用户态图形栈走 libhybris，直接
使用厂商 `libGLES_mali.so`（`/dev/mali0`），这是硬件加速的来源。但 `mali_kbase`
的 `find_get_pid` 在 PID 命名空间内解析失败，没有这个模块时容器进程建不了
GPU context —— `dmesg` 报 `Failed to get pid pointer`，用户态是 `eglInitialize`
返回 `0x3001`。装 [droidspaces-lkm](https://github.com/misaka5202/droidspaces-lkm)
即可，它在 Mali 平台上自动加载，详见
[KMI 覆盖矩阵](https://github.com/misaka5202/droidspaces-lkm/blob/master/docs/KMI-COVERAGE.md)。

不需要 `vkms`：anland 6.x 的 `waylandbridge` 直接使用 `/dev/mali0`，实测卸掉
`vkms` 后渲染与上屏都正常。

### 启动应用

经 `anland-shell` 启动，不在容器内手动拉起进程。daemon 要求客户端携带完整会话
环境：`anland-shell` 注入 `XDG_RUNTIME_DIR`、`WAYLAND_DISPLAY`、
`DBUS_SESSION_BUS_ADDRESS`，并经 systemd 用户会话（`systemd-run --user`）启动。

```text
anland-shell → 容器 → START → APPS → 应用
```

每个应用对应一个独立 Android 窗口（`AwlWindowActivity`），入最近任务、可分屏、
独立 IME 状态。

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 容器显示 `stopped`，实际在运行 | anland-shell 与 Droidspaces ≥7.2.0 不兼容 | 换 `v1.1.3` |
| `no containers defined` | `com.anland.shell` 无 root | 授权 |
| `APPS` 报 `Anlandx not installed` | 容器未运行 | 先 `START` |
| 点击无响应 | 见「无画面定位」 | 查 daemon 日志 |

第一次建议在 `com.anlandnext` 的 **Window Settings** 里确认两项：

| 设置 | 建议值 | 原因 |
| --- | --- | --- |
| Window scaling | `Fit`（等比，黑边不变形） | 默认 `Stretch` 是两轴各自拉满；竖屏手机上 800×600 的占位会被拉成 1264×2780，纵向差 4.6 倍，严重变形 |
| Auto attach new windows | 开 | 关掉后窗口要等 app 通过 binder 提供 SURFACE 才显示 |

这两项**在界面里点完立刻生效并自动持久化**（daemon 会打
`config set scale_mode=N (applied + persisted)`），不需要重启 daemon。

### 故障对照

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `no wayland socket at /run/anland/wayland-0` | 容器无法访问 socket | 补 ③ 绑定挂载 |
| 容器显示 `stopped`，实际在运行 | anland-shell 与 Droidspaces ≥7.2.0 不兼容 | 换 `v1.1.3` |
| `no containers defined` | `com.anland.shell` 无 root | 授权 |
| 窗口列表为 0，daemon 正常 | 客户端未提交首帧 | 查日志分界 |
| 画面变形 | `scale_mode=0`（Stretch） | 改 `Fit` |
| MTK / Mali：窗口打开、客户端渲染成功，屏幕空白 | SurfaceControl 合成器在 MediaTek 上无法呈现 dma-buf 内容 | 设 `sc_enabled: 0` |
| MTK 上 `eglInitialize` 返回 `0x3001` | `mali_kbase` 拒绝 PID 命名空间内的 pid 查找 | 加载 `mali_nsfix.ko` |

### MediaTek / Mali 设备

在 MediaTek 上，厂商 `mali_kbase` 驱动与合成器需要三件事，高通上不需要。
三者缺一，表现各不相同，看起来像三个不相关的问题。

| 条件 | 缺失时的表现 |
| --- | --- |
| 加载 `mali_nsfix.ko` | `eglInitialize` 返回 `0x3001`；`dmesg` 出现 `mali 13000000.mali: Failed to get pid pointer for <comm>/<pid>` |
| daemon 带 `AWL_NO_SCANOUT=1` 启动 | 每帧重试 AHB 伪造，每帧两条 `anland-rd` 错误 |
| `config.json` 里 `"sc_enabled": 0` | SurfaceControl 合成器取走客户端缓冲区，但不呈现任何内容 |

第一件事的原因：`kbase_create_context()` 调用
`find_get_pid(current->tgid)`。`tgid` 永远是初始命名空间的值，而
`find_get_pid()` 经由调用者的活动命名空间解析，容器进程的查找因此失败，
`kbase_create_context()` 返回 `NULL`，驱动将其报成 `-ENOMEM`。
[droidspaces-lkm](https://github.com/misaka5202/droidspaces-lkm) 的
`mali_nsfix.ko` 重定向这次调用。

第三件事的原因：`awl_ahb.cpp` 把客户端 dma-buf 伪造成 `AHardwareBuffer`，
依据是高通 snapalloc 产生的 2-fd `native_handle` 布局；MediaTek 的
`mtk_alloc` 报三个 fd，伪造被拒。此时 GL renderer（`awl_renderer.cpp`，
由 `sc_enabled: 0` 选中）改用 `EGL_EXT_image_dma_buf_import` 直接导入
dma-buf，这条路径有效。SurfaceControl 合成器（`awl_sc.cpp`）调用的是同一份
导入代码，却不呈现结果，原因尚未确定。

### MTK 的 Vulkan：Mesa PanVK on kbase

GLES 之外，MTK 变体的镜像还带一份 [mali-panvk](https://github.com/JimVulkan/mali-panvk)——
Mesa PanVK 对手机自带 kbase 驱动（`/dev/mali0`）的移植，官方实测设备含
Tab S10+（Immortalis-G720，天玑 9300+）。它给 DXVK（Wine 的 D3D9/10/11）
与 Zink（GL）提供 Vulkan 1.4 真硬件路径，`VK_EXT_robustness2` 的 null
descriptor 已支持（DXVK/zink 的硬需求）。

加载链与 GLES 完全对称：

```text
glibc 应用 → libhybris libvulkan → LIBVULKAN 开关 → panvk（bionic 构建，
只能经 android_dlopen 加载）→ /dev/mali0（kbase）
```

Wayland 上屏由 hybris 的 `vulkanplatform_wayland` 完成：把
`VK_KHR_wayland_surface` 转成 `vkCreateAndroidSurfaceKHR`，交换链缓冲经
`zwp_linux_dmabuf_v1` 交给 waylandbridge。内核前提与 GLES 路线相同：
`mali_nsfix.ko` 缺了同样建不了 GPU context（上游 README 的「免 root」只对
启动器架构成立——那是普通应用进程，没有 PID namespace）。

未装 panvk 时 `LIBVULKAN` 保持默认（厂商 blob 的 Android Vulkan loader）。
当前镜像里 Steam 游戏仍走 wined3d/OpenGL（DXVK 在容器内的 x86 Proton 下
建不了 Vulkan 实例）；panvk 的直接受益者先是 Zink/vulkaninfo 这类 glibc
Vulkan 客户端，DXVK 直通是后续按真机验证推进的课题。

验证方式：截两次屏 —— 客户端运行时一次，退出后一次。只截一次不够：先前被
强杀的客户端留下的窗口会产生假阳性。

### 安装或更新 Anland 桌面组件

构建时会自动获取匹配包。若要在已运行的 ARM64 RootFS 中单独安装，可从仓库根目录执行：

```bash
sudo ./scripts/tui/install-anland-kde.sh
```

GNOME 安装器可在 Debian 13、Ubuntu 26、Fedora 43/44 与 Arch Linux ARM 上使用：

```bash
sudo ./scripts/tui/install-anland-gnome.sh
```

GNOME 安装器已支持 Debian、Ubuntu、Fedora 和 Arch 的包格式，并从 `anland-gnome-packages` Release 清单读取匹配目标。

安装器选项、下载源和校验方式见[脚本说明](../../scripts/README.md#anland-kde-安装器)。

