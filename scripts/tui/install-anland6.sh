#!/usr/bin/env bash
# 安装 Anland 6.x 的容器内会话（anlandx）。
#
# 为什么 6.x 和 5.x 完全不是一回事
# --------------------------------
# 5.x：宿主跑一个私有显示协议（Anland Display Protocol），容器里要装**打过补丁的
#      合成器**（patched KWin），整块屏幕投到一个 Android 窗口里。
#      我们的 rootfs 之前就是按这套配的：ANLAND_SOCKET=/run/display.sock +
#      display_daemon.sock 绑定挂载。问题是那个 patched KWin 并不在公开的
#      anland-kde-packages 里，装了那批 deb 之后 kwin 二进制里一个 anland
#      字样都没有 —— 结果就是会话起来了但画面没有出口，黑屏。
#
# 6.x：把「Wayland 本身就是帧交换协议」做实。宿主侧 waylandbridge 守护进程
#      （KernelSU 模块 anland-awl）通过 binder 把**每个 xdg_toplevel 变成一个
#      真正的 Android 窗口**，所以：
#        - 不需要 patched 合成器，stock compositor 不用改
#        - 没有 socket 文件（连接是 binder 传的 fd）
#        - 容器里只需要会话管路：wayland 链接 + rootless Xwayland + mini-wm
#      这一套就是 anlandx。
#
# 所以这个脚本装的是 anlandx，**并且绝不能装 5.x 的 patched KWin** ——
# 那玩意儿会接管显示路径，把 6.x 的路由顶掉。
#
# 参数
# ----
#   install-anland6.sh <桌面用户> [版本]
#
# 环境变量
#   ANLAND_VERSION        anland release tag，默认 latest（跟随最新发布）
#   ANLAND_RELEASE_REPO   发布仓库，默认 misaka5202/anland（改版）
#   ANLAND_XWAYLAND       1=编译 patched Xwayland，默认 0（见下）
#
# 关于 ANLAND_XWAYLAND=0
# ----------------------
# anlandx 自带的 patched Xwayland 打的是 **Mesa kgsl/turnip** 那条路径的 GL 修复，
# 那是高通 Adreno 专用。MTK/Mali 用不上，而且编译它要在容器里跑 meson/ninja，
# 构建时间和失败面都变大。实测（univers629 的集成）用发行版自带的 Xwayland 就够。
# 默认关掉，两个 GPU 厂商走同一套。

set -euo pipefail

USERNAME_IN="${1:-}"
RELEASE_REPO="${ANLAND_RELEASE_REPO:-misaka5202/anland}"
# 改版从 6.2-ds6 起发独立文件（不再是 anland-build.2.zip 整包）
BUILD_ZIP_NAME="${ANLAND_BUILD_ZIP:-anlandx.tar.gz}"
WANT_XWAYLAND="${ANLAND_XWAYLAND:-0}"
MARKER=/etc/droidspaces-anland-major

log() { printf '%s\n' "--> [anland6] $*"; }
warn() { printf '%s\n' "--> [anland6] 警告: $*" >&2; }

if [ -z "$USERNAME_IN" ]; then
    echo "用法: $0 <桌面用户> [版本]" >&2
    exit 1
fi
USERNAME_OUT="$USERNAME_IN"

if ! id "$USERNAME_OUT" >/dev/null 2>&1; then
    echo "找不到用户 $USERNAME_OUT" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 1) 构建依赖
#
# anlandx 会在容器内**从源码编译** mini-wm 和 bwrap（bwrap 必须换掉：发行版
# 自带的那个在 KernelSU+SuSFS 的假 mount id 下会「Out of memory」—— glycin
# 的 RLIMIT_AS 撞上 16GB 的 id 索引挂载表，SVG 图标加载失败导致 GTK 直接 abort）。
# ---------------------------------------------------------------------------
install_deps_apt() {
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential pkg-config curl unzip ca-certificates \
        libx11-dev libxext-dev libxfixes-dev libxrandr-dev libxi-dev \
        libxtst-dev libxrender-dev libxcomposite-dev libxkbfile-dev \
        libwayland-dev wayland-protocols \
        libcap-dev libpam-systemd xwayland meson ninja-build \
        libegl-mesa0 libglx-mesa0 libgbm1 libgl1-mesa-dri mesa-vulkan-drivers mesa-utils \
        dbus-x11 xdg-user-dirs
}

install_deps_dnf() {
    dnf install -y --setopt=install_weak_deps=False \
        gcc gcc-c++ make pkgconf-pkg-config curl unzip ca-certificates \
        libX11-devel libXext-devel libXfixes-devel libXrandr-devel libXi-devel \
        libXtst-devel libXrender-devel libXcomposite-devel libxkbfile-devel \
        wayland-devel wayland-protocols-devel \
        libcap-devel pam systemd xorg-x11-server-Xwayland meson ninja-build \
        mesa-libEGL mesa-libGL mesa-libgbm mesa-dri-drivers mesa-vulkan-drivers glx-utils \
        dbus-x11 xdg-user-dirs
}

install_deps_pacman() {
    pacman -S --noconfirm --needed \
        base-devel pkgconf curl unzip ca-certificates \
        libx11 libxext libxfixes libxrandr libxi libxtst libxrender libxcomposite libxkbfile \
        wayland wayland-protocols \
        libcap pam systemd xorg-xwayland meson ninja \
        mesa-utils libpulse xdg-user-dirs
}

# 注意：/etc/os-release 里有 VERSION= 字段（例如 "13 (trixie)"），
# 谁先把 os-release source 进来，谁就会覆盖同名的局部变量。所以这里
# 自己的 tag 变量叫 ANLAND_TAG，不用 VERSION。
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
fi
ANLAND_TAG="${ANLAND_VERSION:-latest}"
case "${ID:-}" in
    debian|ubuntu) install_deps_apt ;;
    fedora|rhel|centos) install_deps_dnf ;;
    arch|archarm|archlinux) install_deps_pacman ;;
    *) log "未知发行版 ${ID:-?}，跳过依赖安装（失败请手工装 build-essential/meson/ninja）" ;;
esac

# ---------------------------------------------------------------------------
# 2) 取 anlandx
#
# 改版的发布包是三个独立文件（上游 6.2 才是 anland-build.2.zip 整包）：
#   anland-wayland.apk        宿主 APK
#   anland-awl.zip            KernelSU 模块（waylandbridge 守护进程）
#   anlandx.tar.gz            容器内会话 ← 只要这个
# ---------------------------------------------------------------------------
TMP=/opt/anland6-src
rm -rf "$TMP"
install -d -m 0755 "$TMP"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

if [ "$ANLAND_TAG" = latest ]; then
    URL="https://github.com/${RELEASE_REPO}/releases/latest/download/${BUILD_ZIP_NAME}"
else
    URL="https://github.com/${RELEASE_REPO}/releases/download/${ANLAND_TAG}/${BUILD_ZIP_NAME}"
fi
log "下载 $URL"
if ! curl -fsSL --retry 3 --max-time 300 -o "$TMP/anlandx.tar.gz" "$URL"; then
    echo "下载失败：$URL" >&2
    exit 1
fi
tar xzf "$TMP/anlandx.tar.gz" -C "$TMP"

# 安装器会降权到桌面用户执行，那个用户要能读到解压出来的树，
# 所以放在全局可读目录而不是 mktemp 的私有目录
if [ ! -d "$TMP/anlandx" ]; then
    echo "anlandx.tar.gz 解出来的目录名不是 anlandx，实际内容：" >&2
    ls -1 "$TMP" >&2
    exit 1
fi
chmod -R a+rX "$TMP"

# ---------------------------------------------------------------------------
# 3) 会话装到桌面用户家目录
#
# 构建期没有 logind 会话，所以 /run/user/1000 不存在。installer 需要它，
# 手工建出来并给对属主。
# ---------------------------------------------------------------------------
install -d -m 0700 -o "$USERNAME_OUT" -g "$USERNAME_OUT" /run/user/1000 2>/dev/null || {
    UID_N=$(id -u "$USERNAME_OUT")
    install -d -m 0700 -o "$UID_N" -g "$UID_N" /run/user/1000
}

log "以 $USERNAME_OUT 身份运行 setupanlandx.sh（ANLAND_XWAYLAND=$WANT_XWAYLAND）"
if ! su - "$USERNAME_OUT" -c \
    "XDG_RUNTIME_DIR=/run/user/1000 ANLAND_XWAYLAND=$WANT_XWAYLAND bash '$TMP/anlandx/setupanlandx.sh'"; then
    # 安装器最后会尝试 enable 一个 systemd **user** 单元；构建期没有用户会话，
    # 那一步必然失败。只要会话本体装出来了就算成功，system 单元由下面第 5 步补。
    if [ -x "/home/$USERNAME_OUT/.local/bin/anland-session" ]; then
        log "会话已安装，用户级单元那一步按预期失败（构建期没有 logind），继续"
    else
        echo "setupanlandx.sh 失败，且没有产出 anland-session" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# 3.5) 清掉只用于编译的依赖
#
# anlandx 会在容器内从源码编 mini-wm 和 bwrap，为此装了一批 build-essential /
# meson / ninja / 各种 -dev 头文件。这些**运行期一个都用不到**，但它们会让镜像
# 大几百 MB —— 而打包耗时和体积成正比（实测整个构建 87% 的时间在 xz 上）。
#
# 只 purge 明确由本脚本装进去的编译型包，不动运行期依赖：
#   libx11-dev 删掉不影响 libx11-6（.so 在后者里）
#   不用 --auto-remove，避免把运行期库当成"无用的依赖"一起带走
# ---------------------------------------------------------------------------
purge_build_deps() {
    case "${ID:-}" in
        debian|ubuntu)
            local pkgs="build-essential pkg-config meson ninja-build                 libx11-dev libxext-dev libxfixes-dev libxrandr-dev libxi-dev                 libxtst-dev libxrender-dev libxcomposite-dev libxkbfile-dev                 libwayland-dev wayland-protocols libcap-dev"
            # 逐个删，某个包名在发行版里不存在时不要整条失败
            for p in $pkgs; do
                DEBIAN_FRONTEND=noninteractive apt-get purge -y "$p" >/dev/null 2>&1 || true
            done
            apt-get autoremove -y >/dev/null 2>&1 || true
            apt-get clean
            rm -rf /var/lib/apt/lists/*
            ;;
        fedora|rhel|centos)
            local pkgs="gcc gcc-c++ make pkgconf-pkg-config meson ninja-build                 libX11-devel libXext-devel libXfixes-devel libXrandr-devel libXi-devel                 libXtst-devel libXrender-devel libXcomposite-devel libxkbfile-devel                 wayland-devel wayland-protocols-devel libcap-devel"
            for p in $pkgs; do
                dnf remove -y "$p" >/dev/null 2>&1 || true
            done
            dnf clean all >/dev/null 2>&1 || true
            ;;
        arch|archarm|archlinux)
            local pkgs="base-devel pkgconf meson ninja                 libx11 libxext libxfixes libxrandr libxi libxtst libxrender libxcomposite libxkbfile                 wayland wayland-protocols libcap"
            # pacman 删这些可能连带需要它们的包，用 --assume-installed 不现实，
            # 所以只删确定安全的编译器，其余留着（Arch 用户量小，收益不值得冒险）
            for p in base-devel meson ninja; do
                pacman -Rns --noconfirm "$p" >/dev/null 2>&1 || true
            done
            rm -rf /var/cache/pacman/pkg/*
            ;;
    esac
}
purge_build_deps
log "已清理编译依赖"

# ---------------------------------------------------------------------------
# 4) 修一个竞态：会话退出时会删掉 wayland-anland 链接
#
# 而替换它的下一个会话会重新发布同一个链接。构建期的安装/重启会把两者撞在
# 一起，链接被删掉之后客户端就连不上了。保留链接，由启动器每次重新发布。
# ---------------------------------------------------------------------------
SESSION="/home/$USERNAME_OUT/.local/bin/anland-session"
if [ -f "$SESSION" ]; then
    sed -i 's|rm -f "\$STATE" "\$ENVF" "\$WL_LINK"|rm -f "$STATE" "$ENVF"|' "$SESSION" || true
fi

# ---------------------------------------------------------------------------
# 5) 不额外装 system 单元
#
# 一开始我在这里又装了一个 anland-session.service，但那是重复的：
# configure-desktop 会装 desktop-session.service，而 start-desktop-session.sh
# 在读到 /etc/droidspaces-anland-major=6 时就直接 exec anland-session 了。
# 两个单元跑同一个会话会互相抢 wayland 链接，所以这里什么都不装，
# 统一由 desktop-session.service 管。
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 6) 标记：告知会话脚本和启动器这是 6.x
#
# start-desktop-session.sh 读到这个文件就直接跑 anland-session，
# 而不是 startplasma-wayland / gnome-session 之类（6.x 没有全屏合成器）。
# ---------------------------------------------------------------------------
printf '6\n' > "$MARKER"

log "完成：版本 ${ANLAND_TAG}，用户 ${USERNAME_OUT}，Xwayland=$([ "$WANT_XWAYLAND" = 1 ] && echo patched || echo 发行版自带)"
log "会话状态文件：~/.anlandx（DISPLAY）、~/.anlandx-env（应用环境）"
log "宿主侧还需要：刷 module/anland-awl.zip + 装 anland-wayland.apk"