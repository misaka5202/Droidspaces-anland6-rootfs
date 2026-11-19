# Droidspaces Anland 6.x RootFS 构建器

[English](README.md) · [Documentation](docs/zh/README.md)

为 [Droidspaces](https://github.com/ravindu644/Droidspaces-OSS) 构建**面向 Anland 6.x** 的 Linux RootFS 镜像，高通 / MTK 双版本，中文界面。

## 快速开始

系统需求：root（KernelSU / APatch / Magisk）、Droidspaces、arm64。
MTK / Mali 设备另需 [droidspaces-lkm](https://github.com/misaka5202/droidspaces-lkm)：
它带 `mali_nsfix.ko`，在 Mali 平台上自动加载。

标准 MTK 镜像通过 libhybris 直接使用厂商 Mali 驱动（`/dev/mali0`），这就是硬件
加速的来源；`mali_nsfix` 是它的前提 —— 没有它时 `mali_kbase` 在 PID 命名空间里
建不了 GPU context（`dmesg` 报 `Failed to get pid pointer`，用户态是
`eglInitialize` 返回 `0x3001`）。详见
[桌面与 Anland 指南](docs/zh/桌面与Anland.md)。

```bash
# 1. 导入镜像（Droidspaces 导入 .tar.xz，或订阅 rootfs_zh.json）

# 2. 宿主侧配置：模块、APK、daemon 配置、容器绑定挂载
adb push scripts/setup-anland6-host.sh /data/local/tmp/
adb shell su -c 'sh /data/local/tmp/setup-anland6-host.sh'

# 3. 重启（模块需经 reboot 才由 root 管理器启用）
adb reboot

# 4. 链路校验
adb push scripts/verify-anland6-host.sh /data/local/tmp/
adb shell su -c 'sh /data/local/tmp/verify-anland6-host.sh'
```

启动应用走 `anland-shell`：容器 → `START` → `APPS` → 应用。每个应用对应一个
独立 Android 窗口（`AwlWindowActivity`），入最近任务、可分屏、独立 IME 状态。

宿主侧组件、职责与缺失表现见[宿主侧准备](#宿主侧准备)。

## 下载清单

| 文件 | 来源 | 说明 |
| --- | --- | --- |
| `module/anland-awl.zip` | **[misaka5202/anland 6.2-ds6](https://github.com/misaka5202/anland/releases/tag/6.2-ds6)** | `waylandbridge` 守护进程（含输入修复） |
| `anland-wayland.apk` | 同上 | `com.anlandnext`，窗口消费者（含额外按键栏） |
| `anland-shell.apk` | **[misaka5202/anland-shell v1.1-ds73](https://github.com/misaka5202/anland-shell/releases/tag/v1.1-ds73)** | 补丁版，见下 |
| `anlandx.tar.gz` | **[misaka5202/anland 6.2-ds6](https://github.com/misaka5202/anland/releases/tag/6.2-ds6)**（本仓库镜像也已内置） | 容器内 `anlandx` 会话 |

### 为什么必须用改版（misaka5202/anland）

不是可选，是必须。上游 6.2 有三个让桌面输入不可用的缺陷：

1. **软键盘文本到不了应用。** 不实现 `zwp_text_input_v3` 的应用（Konsole/XTerm
   这类终端）什么都收不到：`awl_ime_text()` 在「没有可用的 text_input」时直接
   丢弃 commit。改版把 ASCII 文本降级成 `wl_keyboard` 按键 —— 这条路已被实测
   可用（回车键就是走它）。
2. **中文输入不可能。** daemon 没有实现 `zwp_input_method_v2`，容器内的
   fcitx5 拿着字无处可送。改版实现了它。
3. **额外按键栏有一部分是死的。** 最左一列（ESC/TAB）落在系统返回手势区里，
   touch 被手势吃掉。改版用 `WindowInsets.Type.systemGestures()` 给底栏让边。

4. **应用窗口起不来**：xdg configure 的 serial 为 0，客户端丢弃后 surface 永不 map，
   anland-shell 点应用「没反应」。改版改用 `next_serial`。
5. **中文在终端里落不了地**：终端没有 `text_input`，改版把文本放进 Wayland
   选区，再发该终端的粘贴键（`config.json` 的 `paste_shortcut`，默认
   `ctrl+shift+v`）。
6. **X11 应用读不到剪贴板**：选区只声明了 `text/plain*`，而 Konsole 这类
   Xwayland 客户端要的是 `UTF8_STRING`。改版补上 `UTF8_STRING` / `TEXT` /
   `STRING`。
7. **重装模块会丢 `config.json`**：`runtime_dir` 退回编译默认值，和容器的
   `bind_mounts` 对不上。`customize.sh` 现在会按容器 bind 源目录重新生成。

此外还包含：5.x UI 移植（额外按键栏、可调透明度的沉浸式底栏）、新增文案的
i18n、以及 IME 合成按键的 evdev 码完整映射（它们恒为 `scanCode == 0`）。

全部由 `main` 构建，当前发布为 `6.2-ds6`。如果你只需要原生 6.2 的行为，请用
[SuperTurtleDev/anland 6.2](https://github.com/SuperTurtleDev/anland/releases/tag/6.2)
—— 但上面三个输入问题会复现。

### anland-shell 需用补丁版

上游 1.1（2026-09-17）调用 `droidspaces show --format`：

```java
RootExec.exec(bin + " show --format", 15_000);
```

Droidspaces 7.2.0（2026-11-07）移除该参数，改为 `show --json`。旧参数输出
`Unknown or incomplete option: --format` 到 stdout，退出码仍为 0，running 集合
解析为空，容器一律显示 `stopped`，`APPS` 入口被拦。

上游 PR [SuperTurtleDev/anland-shell#2](https://github.com/SuperTurtleDev/anland-shell/pull/2)
（2026-11-13）修复，未合并。

`v1.1-ds73` 改动：`show --json` 优先、`show --format` 回退、解析前剥离 ANSI
转义。验证环境 OPPO PHZ110 / MT6989 / Android 17 / Droidspaces 7.2.0。

判定是否需要补丁版：

```bash
su -c 'droidspaces show --json'    # 有输出
su -c 'droidspaces show --format'  # Unknown or incomplete option
```

`setup-anland6-host.sh` 读取 Droidspaces 版本，≥7.2.0 时自动取补丁版。

## 和 5.x 版本的区别

| | Anland 5.x（旧路线） | Anland 6.x（本仓库） |
|---|---|---|
| 显示协议 | 私有 Anland Display Protocol | **Wayland 本身** |
| 合成器 | 必须装**打过补丁的 KWin** | stock compositor 不用改 |
| 连接方式 | `/run/display.sock` + 绑定挂载 | binder 传 fd，**没有 socket 文件** |
| 窗口 | 整块屏幕投到一个 Android 窗口 | **每个窗口一个真正的 Android 窗口** |
| 容器内组件 | 无（靠 patched 合成器） | `anlandx` 会话（wayland 链接 + rootless Xwayland + mini-wm） |

5.x 的 patched KWin 并不在公开的 `anland-kde-packages` 里，装那批 deb 之后
`kwin_wayland` 二进制里一个 anland 字样都没有，结果是会话起来了但画面没有出口。
本仓库走 6.x 路线，绕开这个死胡同。

## 宿主侧准备

宿主侧四件，缺任一件无画面。

| # | 文件 | 装法 | 职责 | 缺失表现 |
| --- | --- | --- | --- | --- |
| 1 | `module/anland-awl.zip` | root 管理器刷入，**reboot** | `waylandbridge`：Wayland 服务端，接收客户端，首帧到达后触发建窗 | 无 socket，容器会话不启动 |
| 2 | `anland-wayland.apk` | `pm install` | `com.anlandnext`：每窗口一个 `AwlWindowActivity` | 应用可启动，无窗口 |
| 3 | `anland-shell.apk` | `pm install` + 授予 root | `com.anland.shell`：列容器 / 列应用 / 启动 | 无启动入口 |
| 4 | `anlandx.tar.gz` | 本仓库镜像已内置 | 容器内 `anlandx` 会话（wayland 链接 + rootless Xwayland + mini-wm） | 无 `anland-session` |

第 4 件对外部镜像需手动安装：

```bash
tar xzf anlandx.tar.gz && bash anlandx/setupanlandx.sh
```

### 自动配置

```bash
adb push scripts/setup-anland6-host.sh /data/local/tmp/
adb shell su -c 'sh /data/local/tmp/setup-anland6-host.sh'
```

幂等。执行内容：模块安装（`ksud module install` 或解压到 `/data/adb/modules/`）、
APK 安装、daemon 配置写入（`auto_attach=1`、`scale_mode=1`）、容器绑定挂载补写。

### 手动配置

**1. `anland-awl` 模块**

刷入后必须重启。模块滞留 `modules_update/` 时 `waylandbridge` 不运行，
`/data/local/tmp/awl/wayland-0` 不存在。重启后校验：

```bash
su -c 'pidof waylandbridge'
su -c 'ls -l /data/local/tmp/awl/wayland-0'   # srw-rw-rw-
su -c 'service list | grep anland.host'
```

**2. 宿主 APK**

```bash
pm install -r anland-wayland.apk
pm install -r anland-shell.apk
```

`com.anland.shell` 需 root 授权，否则读不到 `/data/local/Droidspaces/Containers`，
表现为 `no containers defined`。

**3. 容器绑定挂载**

daemon 发布点为 `/data/local/tmp/awl/wayland-0`（`config.json` 的 `runtime_dir`），
容器内 `anland-session` 硬编码 `/run/anland/wayland-0`。容器 `/run` 为独立 tmpfs，
两者不共享，必须显式绑定：

```bash
su -c 'droidspaces --name=<name> -B /data/local/tmp/awl:/run/anland start'
```

或写 `container.config`：

```ini
bind_mounts=/data/local/tmp/awl:/run/anland
```

Droidspaces 持久化该字段，无需每次带 `-B`。缺失时容器内报
`no wayland socket at /run/anland/wayland-0 (anland daemon down?)`，其中
`daemon down?` 不成立，daemon 正常运行。校验：

```bash
su -c 'droidspaces --name=<name> run -- ls -l /run/anland/wayland-0'
```

Droidspaces 二进制无 `/run/anland` 处理逻辑（`strings` 命中 0），仅识别 5.x 的
`/run/display.sock`，该挂载不会被自动添加。`socket_listen=0` 的 binder-fd 模式
要求客户端直接使用 Android binder，容器内 Linux 应用不适用。

**4. 容器配置**

启用硬件访问（`--hw-access` / `--gpu`）、特权模式，勾选 `nocaps`、`noseccomp`。

## 应用启动

经 `anland-shell` 启动，不在容器内手动拉起进程。宿主 daemon 需要客户端
携带完整会话环境：`anland-shell` 注入 `XDG_RUNTIME_DIR`、`WAYLAND_DISPLAY`、
`DBUS_SESSION_BUS_ADDRESS`，并经 **systemd 用户会话**（`systemd-run --user`）启动。

```text
anland-shell → 容器 → START → APPS → 应用
```

启动异常：

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 容器显示 `stopped`，实际在运行 | anland-shell 与 Droidspaces ≥7.2.0 不兼容 | 换 `v1.1-ds73` |
| `no containers defined` | `com.anland.shell` 无 root | 授权 |
| `APPS` 报 `Anlandx not installed` | 容器未运行 | 先 `START` |
| 点击无响应 | 见下节 | 查 daemon 日志 |

`com.anlandnext` 的 Window Settings 建议值：

| 项 | 值 | 依据 |
| --- | --- | --- |
| Window scaling | `Fit` | 默认 `Stretch` 为两轴独立填满；`init_w/h` 默认 800×600，竖屏 1264×2780 下纵向拉伸 4.6× |
| Auto attach new windows | 开 | 关闭时窗口等待 app 经 binder 提供 SURFACE |

两项生效即时并持久化（`config set scale_mode=N (applied + persisted)`）。

### 无画面定位

daemon 日志分界：

```bash
logcat -d | grep 'anland-wl:' | tail -20
```

| 日志 | 含义 |
| --- | --- |
| `surface N created` | 客户端已连接，仅建 surface |
| `surface N mapped (role=1)` | 首帧已提交，触发建窗 |
| `window WxH attached` | Android 窗口已附着 |

仅有 `created` 无 `mapped`：客户端未提交缓冲区，问题在应用侧。
有 `mapped` 无 `window attached`：`com.anlandnext` 侧。

## GPU 版本

同样是双版本，因为两家 GPU 的驱动配置相反：

| 文件名带 | 适用 | 渲染 |
|---|---|---|
| `-qualcomm-` | 骁龙 / Adreno | Mesa freedreno/kgsl + turnip 硬件加速 |
| `-mediatek-` | 联发科 / Mali | libhybris 驱动厂商 Mali（`/dev/mali0`，硬件加速） |

6.x 的容器会话本身是 GPU 中立的（`ANLAND_XWAYLAND=0`，用发行版自带的 Xwayland），
GPU 差异体现在用户态图形栈：高通走 Mesa + kgsl，MTK 走 libhybris + 厂商驱动，
由 `configure-gpu` 与 `setup-mali-hybris` 按厂商处理。

## 构建

Actions → “发布全桌面 Wayland RootFS（高通 + MTK 双版本）” → `gpu_vendor` 保持 `both`。

单个组合用单目标工作流并指定 `gpu_vendor`。

新增的输入：

| 输入 | 默认 | 说明 |
|---|---|---|
| `anland_major` | `6` | 6 = anlandx 会话；5 = 旧版 patched KWin 路线（保留以便对照） |
| `anland6_version` | `6.2` | anland release tag |

## 支持范围

- Anland 6.x：Debian 13、Ubuntu 26、Fedora 43/44、Arch Linux ARM
- Ubuntu 24 / 25 不支持 Anland（上游如此）
- **Android 14（API 34）或更高。** anland6 用户态守护进程调用
  `ANativeWindow_readFromParcel` —— API 34 才引入的符号，代码里没有回退。
  Android 13 上 daemon 加载失败：
  `CANNOT LINK EXECUTABLE ... cannot locate symbol "ANativeWindow_readFromParcel"`。
  上游没有支持 Android 13 的计划
  （[SuperTurtleDev/anland#112](https://github.com/SuperTurtleDev/anland/issues/112)）。
  注意这与 `droidspaces-lkm` 的 KMI 覆盖矩阵无关：那边的 Android 12/13
  说的是**内核模块**一侧。

## 目录

```
scripts/tui/install-anland6.sh       安装 anlandx 会话（本仓库核心改动）
scripts/configure-anland6-env.sh     清掉 5.x 的环境变量
scripts/start-desktop-session.sh     6.x 下改为拉起 anland-session
scripts/desktops/*.sh                各桌面的包清单与环境（6.x 下只用来装应用）
scripts/tui/configure-gpu.sh         高通/MTK 的 Mesa 与渲染配置
```

## 许可

继承上游（见 LICENSE）。

