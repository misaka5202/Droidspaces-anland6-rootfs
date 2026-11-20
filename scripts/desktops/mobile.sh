#!/usr/bin/env bash
set -euo pipefail

source "${ROOTFS_DIR:-}/etc/os-release"

# mobile：发行版无关的移动端应用集。
#
# 6.x 下会话始终是 anland-session（每窗口一个 Android 窗口），profile 只决定装
# 哪些应用，所以这里不装任何移动 shell（Phosh/Lomiri）：那会与 mini-wm 争夺窗口
# 管理，也会和 Android 侧 IME 重复。
configure_environment() {
    local backend="${1:-}"
    local environment_file="${ROOTFS_DIR:-}/etc/environment"
    local assignment key
    # 只写 6.x 会话真正读取的变量。WAYLAND_DISPLAY / ANLAND_* 由 anland-session
    # 经 ~/.anlandx-env 发布（见 anland-next.sh 的说明），写死会弄坏会话。
    local -a assignments=(
        XDG_SESSION_CLASS=user
        XDG_SESSION_TYPE=wayland
        QT_QPA_PLATFORM=wayland
    )

    [[ "$backend" == anland-wayland ]] || {
        echo "mobile 显示后端无效：$backend" >&2
        return 1
    }

    touch "$environment_file"
    for assignment in "${assignments[@]}"; do
        key="${assignment%%=*}"
        grep -q "^${key}=" "$environment_file" || printf '%s\n' "$assignment" >> "$environment_file"
    done
}

# 移动端应用集（Debian 13 arm64 已核实包名）。
# gnome-calls 依赖调制解调器，容器内通常不可用，故不预装。
install_deb() {
    case "$ID:$VERSION_ID" in
        debian:13)
            apt-get install -y --no-install-recommends \
                dbus-x11 dbus-user-session \
                gnome-contacts gnome-calendar gnome-clocks gnome-weather gnome-maps \
                epiphany-browser gnome-console gnome-text-editor foliate \
                xdg-desktop-portal xdg-desktop-portal-gtk \
                pipewire pipewire-alsa pipewire-pulse wireplumber \
                fonts-noto-core fonts-noto-cjk fonts-noto-color-emoji \
                mesa-utils vulkan-tools wayland-utils xdg-user-dirs
            ;;
        ubuntu:26.04)
            apt-get install -y --no-install-recommends \
                dbus-x11 dbus-user-session \
                gnome-contacts gnome-calendar gnome-clocks gnome-weather gnome-maps \
                epiphany-browser gnome-console gnome-text-editor foliate \
                xdg-desktop-portal xdg-desktop-portal-gtk \
                pipewire pipewire-alsa pipewire-pulse wireplumber \
                fonts-noto-core fonts-noto-cjk fonts-noto-color-emoji \
                mesa-utils vulkan-tools wayland-utils xdg-user-dirs
            ;;
        *)
            echo "mobile 不支持当前系统：$ID $VERSION_ID" >&2
            return 1
            ;;
    esac
}

install_fedora() {
    case "$VERSION_ID" in
        43|44) ;;
        *) echo "mobile 不支持 Fedora $VERSION_ID" >&2; return 1 ;;
    esac

    dnf install -y --setopt=install_weak_deps=False \
        dbus-x11 gnome-contacts gnome-calendar gnome-clocks gnome-weather gnome-maps \
        epiphany gnome-console gnome-text-editor foliate \
        xdg-desktop-portal xdg-desktop-portal-gtk \
        pipewire pipewire-alsa pipewire-pulseaudio wireplumber \
        google-noto-sans-fonts google-noto-sans-cjk-fonts google-noto-color-emoji-fonts \
        glx-utils vulkan-tools wayland-utils xdg-user-dirs
}

install_arch() {
    pacman -S --noconfirm --needed \
        dbus gnome-contacts gnome-calendar gnome-clocks gnome-weather gnome-maps \
        epiphany gnome-console gnome-text-editor foliate \
        xdg-desktop-portal xdg-desktop-portal-gtk \
        pipewire pipewire-alsa pipewire-pulse wireplumber \
        noto-fonts noto-fonts-cjk noto-fonts-emoji \
        mesa-utils vulkan-tools wayland-utils xdg-user-dirs
}

install_profile() {
    case "$ID" in
        debian|ubuntu) install_deb ;;
        fedora) install_fedora ;;
        arch|archarm|archlinux) install_arch ;;
        *) echo "mobile 不支持当前发行版：$ID" >&2; return 1 ;;
    esac
}

case "${1:-install}" in
    install) install_profile ;;
    configure-environment) configure_environment "${2:-}" ;;
    *) echo "mobile profile 操作无效：$1" >&2; exit 1 ;;
esac
