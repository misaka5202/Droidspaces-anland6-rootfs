#!/usr/bin/env bash
set -euo pipefail

desktop="${1:-}"
display_backend="${2:-}"
rootfs="${ROOTFS_DIR:-}"
chrome_binary="${rootfs}/opt/google/chrome/google-chrome"
wrapper_dir="${rootfs}/usr/local/bin"
wrapper="${wrapper_dir}/google-chrome"

[[ -n "$desktop" ]] || {
    echo "必须指定桌面配置" >&2
    exit 1
}

case "$display_backend" in
    x11|anland-wayland) ;;
    *)
        echo "无效的 Chrome 显示后端：$display_backend" >&2
        exit 1
        ;;
esac

[[ "$desktop" == none ]] && exit 0

install_debian_chrome() {
    install -d -m 0755 /etc/apt/keyrings /etc/apt/sources.list.d
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
        -o /etc/apt/keyrings/google-chrome.asc
    grep -q 'BEGIN PGP PUBLIC KEY BLOCK' /etc/apt/keyrings/google-chrome.asc
    printf 'deb [arch=arm64 signed-by=/etc/apt/keyrings/google-chrome.asc] https://dl.google.com/linux/chrome/deb/ stable main\n' \
        > /etc/apt/sources.list.d/google-chrome.list
    apt-get update
    apt-get install -y --no-install-recommends google-chrome-stable
}

install_fedora_chrome() {
    install -d -m 0755 /etc/pki/rpm-gpg /etc/yum.repos.d
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
        -o /etc/pki/rpm-gpg/RPM-GPG-KEY-google-chrome
    grep -q 'BEGIN PGP PUBLIC KEY BLOCK' /etc/pki/rpm-gpg/RPM-GPG-KEY-google-chrome
    printf '%s\n' \
        '[google-chrome]' \
        'name=Google Chrome' \
        'baseurl=https://dl.google.com/linux/chrome/rpm/stable/$basearch' \
        'enabled=1' \
        'gpgcheck=1' \
        'repo_gpgcheck=0' \
        'gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-google-chrome' \
        > /etc/yum.repos.d/google-chrome.repo
    dnf install -y --setopt=install_weak_deps=False google-chrome-stable
}

install_arch_chrome() {
    : > /tmp/chrome-build-packages
    for package in $(pacman -Sgq base-devel); do
        if ! pacman -Qq "$package" >/dev/null 2>&1; then
            printf '%s\n' "$package" >> /tmp/chrome-build-packages
        fi
    done
    pacman -S --noconfirm --needed base-devel git
    useradd --system --create-home --home-dir /tmp/chrome-build --shell /bin/bash chrome-build
    runuser -u chrome-build -- git clone --depth=1 \
        https://aur.archlinux.org/google-chrome.git /tmp/chrome-build/google-chrome
    grep -Eq '^[[:space:]]*arch = aarch64$' /tmp/chrome-build/google-chrome/.SRCINFO
    grep -Eq '^[[:space:]]*source_aarch64 = https://dl\.google\.com/linux/chrome/deb/.+_arm64\.deb$' \
        /tmp/chrome-build/google-chrome/.SRCINFO
    grep -Eq '^[[:space:]]*sha512sums_aarch64 = [0-9a-fA-F]{128}$' \
        /tmp/chrome-build/google-chrome/.SRCINFO
    CHROME_DEPENDENCIES="$(sed -n 's/^[[:space:]]*depends = //p' \
        /tmp/chrome-build/google-chrome/.SRCINFO | sed 's/[<>=].*$//' | sort -u)"
    [ -n "$CHROME_DEPENDENCIES" ]
    if printf '%s\n' "$CHROME_DEPENDENCIES" | grep -Eqv '^[A-Za-z0-9@._+][A-Za-z0-9@._+:-]*$'; then
        echo "AUR 配方包含无效的 Chrome 依赖" >&2
        exit 1
    fi
    pacman -S --noconfirm --needed --asdeps $CHROME_DEPENDENCIES
    runuser -u chrome-build -- bash -c \
        'cd "$1" && makepkg --cleanbuild --clean --noconfirm' _ \
        /tmp/chrome-build/google-chrome
    CHROME_PACKAGE="$(find /tmp/chrome-build/google-chrome -maxdepth 1 \
        -type f -name 'google-chrome-*.pkg.tar.*' ! -name '*.sig' -print -quit)"
    [ -n "$CHROME_PACKAGE" ]
    [ "$(find /tmp/chrome-build/google-chrome -maxdepth 1 \
        -type f -name 'google-chrome-*.pkg.tar.*' ! -name '*.sig' -print | wc -l)" -eq 1 ]
    sed -e '/^[[:space:]]*LocalFileSigLevel[[:space:]]*=/d' \
        -e '/^\[options\][[:space:]]*$/a LocalFileSigLevel = Optional' \
        /etc/pacman.conf > /tmp/pacman-chrome.conf
    [ "$(pacman --config /tmp/pacman-chrome.conf -Qqp "$CHROME_PACKAGE")" = "google-chrome" ]
    LC_ALL=C pacman --config /tmp/pacman-chrome.conf -Qip "$CHROME_PACKAGE" | \
        grep -Eq '^Architecture[[:space:]]*: aarch64$'
    pacman --config /tmp/pacman-chrome.conf -U --noconfirm "$CHROME_PACKAGE"
    userdel -r chrome-build
    if [ -s /tmp/chrome-build-packages ]; then
        pacman -Rns --noconfirm $(cat /tmp/chrome-build-packages)
    fi
    rm -f /tmp/chrome-build-packages /tmp/pacman-chrome.conf
}

install_chrome() {
    # ROOTFS_DIR 用于隔离测试；实际 RootFS 构建时为空。
    [[ -n "$rootfs" ]] && return 0

    # shellcheck disable=SC1091
    source /etc/os-release
    case "${ID:-}" in
        debian|ubuntu) install_debian_chrome ;;
        fedora) install_fedora_chrome ;;
        arch|archarm|archlinux) install_arch_chrome ;;
        *)
            echo "不支持的 Chrome 发行版：${ID:-unknown}" >&2
            exit 1
            ;;
    esac
}

install_chrome
[[ -x "$chrome_binary" ]] || {
    echo "Chrome 安装完成后未找到：$chrome_binary" >&2
    exit 1
}

[[ "$display_backend" == anland-wayland ]] || exit 0

install -d -m 0755 "$wrapper_dir"
# 三个 flag 的由来（高通 Anland 6.x 实测，见仓库 issue / SELinux 讨论）：
#   --ozone-platform=wayland  走 Anland 的 Wayland 合成器，而非 X11。
#   --disable-gpu             Chrome 的 ANGLE 会优先探测 Vulkan；而 Ozone-Wayland
#                             明确拒绝 Vulkan 后端（"not compatible with Vulkan"），
#                             X11 路径又因无 DRI3 报 eglCreateWindowSurface
#                             EGL_BAD_MATCH，两头堵死。禁用 GPU 走软件光栅，是实测
#                             唯一能建窗出画面的组合。MTK 无此问题，因为其软件栈本就
#                             没有 Vulkan，ANGLE 自动回退。
#   --no-sandbox              Droidspaces 容器 allow_sandboxing=0，进程拿不到
#                             CAP_SYS_ADMIN，setuid/namespace 沙箱 unshare 失败，
#                             zygote 以 exit 82 FATAL。关掉沙箱才能起。
# XDG_RUNTIME_DIR / WAYLAND_DISPLAY：anland 的 Wayland socket 在 /run/anland/wayland-0，
# 而系统默认 XDG_RUNTIME_DIR=/run/user/1000 下没有该 socket；终端启动时缺这两个变量
# 会让 Ozone-Wayland 报 "Failed to connect to Wayland display" 后直接退出。必须无条件
# 覆盖（不能用 ${VAR:=default}，因为变量已被设成错误值），见仓库文档 x86 总结 §9.5。
cat > "$wrapper" <<'EOF'
#!/bin/sh
set -eu

XDG_RUNTIME_DIR=/run/anland
WAYLAND_DISPLAY=wayland-0
export XDG_RUNTIME_DIR WAYLAND_DISPLAY

exec /opt/google/chrome/google-chrome \
    --ozone-platform=wayland \
    --disable-gpu \
    --no-sandbox \
    "$@"
EOF
chmod 0755 "$wrapper"
ln -sfn -- google-chrome "${wrapper_dir}/google-chrome-stable"

for desktop_file in \
    "${rootfs}/usr/share/applications/google-chrome.desktop" \
    "${rootfs}/usr/share/applications/com.google.Chrome.desktop"; do
    [[ -f "$desktop_file" ]] || continue

    temporary_file="$(mktemp "${desktop_file}.tmp.XXXXXXXX")"
    awk -v launcher="/usr/local/bin/google-chrome" '
        /^Exec=\/usr\/bin\/google-chrome(-stable)?([[:space:]]|$)/ {
            sub(/^Exec=\/usr\/bin\/google-chrome(-stable)?/, "Exec=" launcher)
        }
        /^TryExec=\/usr\/bin\/google-chrome(-stable)?([[:space:]]|$)/ {
            sub(/^TryExec=\/usr\/bin\/google-chrome(-stable)?/, "TryExec=" launcher)
        }
        { print }
    ' "$desktop_file" > "$temporary_file"
    chmod 0644 "$temporary_file"
    mv -f -- "$temporary_file" "$desktop_file"
done
