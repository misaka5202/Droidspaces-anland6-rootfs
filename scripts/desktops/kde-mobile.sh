#!/usr/bin/env bash
set -euo pipefail

source "${ROOTFS_DIR:-}/etc/os-release"

# 6.x 语义：会话本体是 anland-session（每个 X/Wayland 顶层窗口是一个独立的
# Android 窗口），本档位只剩「装哪些应用」。Plasma Mobile shell（plasma-nano /
# plasma-mobile / kwin）在 6.x 里不会被启动——start-desktop-session 直接 exec
# anland-session，根本轮不到 startplasmamobile；maliit 软键盘则与 Android IME
# 桥重复（见 mobile.sh 头部注释）。所以 shell 与 maliit 只在 5.x 构建时装：
# 门控用 Dockerfile 注入的 ANLAND_MAJOR_ARG（默认 6）——本脚本运行时
# /etc/droidspaces-anland-major 还没写（install-desktop 先于 install-anland6）。
# Kirigami 应用集（angelfish、plasma-settings、kclock、konsole、dolphin 等）
# 是普通 Wayland 客户端，6.x 下照常工作，两种构建都装。

configure_environment() {
    local backend="${1:-}"
    local environment_file="${ROOTFS_DIR:-}/etc/environment"
    local assignment key
    local -a assignments=(
        XDG_SESSION_CLASS=user
        XCURSOR_SIZE=48
        QT_QPA_PLATFORM=wayland
    )

    [[ "$backend" == anland-wayland ]] || {
        echo "KDE mobile 显示后端无效：$backend" >&2
        return 1
    }

    touch "$environment_file"
    for assignment in "${assignments[@]}"; do
        key="${assignment%%=*}"
        grep -q "^${key}=" "$environment_file" || printf '%s\n' "$assignment" >> "$environment_file"
    done
}

install_apt() {
    case "$ID:$VERSION_ID" in
        debian:13)
            # 5.x 构建才装 shell + maliit（见文件头注释）
            local shell_pkgs=""
            [ "${ANLAND_MAJOR_ARG:-6}" = "6" ] || \
                shell_pkgs="plasma-nano plasma-mobile plasma-mobile-phone maliit-keyboard maliit-framework kwin-wayland"
            apt-get install -y --no-install-recommends \
                dbus-x11 x11-xserver-utils fonts-noto-cjk fonts-noto-color-emoji wayland-utils xserver-xorg dbus-user-session \
                pipewire pipewire-alsa pipewire-pulse wireplumber powerdevil plasma-pa upower pulseaudio-utils \
                konsole dolphin kate kinfocenter mesa-utils vulkan-tools \
                systemsettings plasma-systemmonitor kde-config-screenlocker kio-extras xdg-user-dirs \
                dolphin-plugins ffmpegthumbs kdegraphics-thumbnailers kimageformat6-plugins plasma-settings angelfish \
                gstreamer1.0-plugins-base gstreamer1.0-plugins-good sound-theme-freedesktop libcanberra-pulse \
                polkit-kde-agent-1 libpam-systemd libpam-modules libpam-kwallet5 \
                breeze-icon-theme plasma-desktoptheme libqt6svg6 qt6-svg-plugins \
                qml6-module-org-kde-kirigami qml6-module-qtquick-controls qml6-module-qtquick-layouts qml6-module-qtquick-templates \
                $shell_pkgs
            apt-get purge -y --auto-remove modemmanager || true
            ;;
        ubuntu:26.04)
            local shell_pkgs=""
            [ "${ANLAND_MAJOR_ARG:-6}" = "6" ] || \
                shell_pkgs="plasma-nano plasma-mobile plasma-mobile-phone maliit-keyboard maliit-framework maliit-server-qt6 kwin-wayland"
            apt-get install -y --no-install-recommends \
                dbus-x11 x11-xserver-utils fonts-noto-cjk fonts-noto-color-emoji wayland-utils xserver-xorg dbus-user-session \
                pipewire pipewire-alsa pipewire-pulse wireplumber powerdevil plasma-pa upower pulseaudio-utils \
                konsole dolphin kate kinfocenter mesa-utils vulkan-tools \
                systemsettings plasma-systemmonitor kde-config-screenlocker kio-extras xdg-user-dirs \
                dolphin-plugins ffmpegthumbs kdegraphics-thumbnailers kimageformat6-plugins plasma-settings angelfish \
                gstreamer1.0-plugins-base gstreamer1.0-plugins-good sound-theme-freedesktop libcanberra-pulse \
                polkit-kde-agent-1 libpam-systemd libpam-modules libpam-kwallet5 qml6-module-org-kde-kirigami qml6-module-qtquick-controls \
                qml6-module-qtquick-layouts qml6-module-qtquick-templates language-pack-kde-zh-hans language-pack-zh-hans qt6-translations-l10n \
                $shell_pkgs
            apt-get purge -y --auto-remove modemmanager || true
            ;;
        *)
            echo "KDE mobile 不支持当前系统：$ID $VERSION_ID" >&2
            return 1
            ;;
    esac
}

install_fedora() {
    case "$VERSION_ID" in
        43|44) ;;
        *) echo "KDE mobile 不支持 Fedora $VERSION_ID" >&2; return 1 ;;
    esac

    # 5.x 构建才装 shell + maliit（见文件头注释）
    local shell_pkgs=""
    [ "${ANLAND_MAJOR_ARG:-6}" = "6" ] || \
        shell_pkgs="plasma-nano plasma-mobile maliit-keyboard maliit-framework kwin"
    dnf install -y --setopt=install_weak_deps=False \
        dbus-x11 xrandr xset xrdb xhost google-noto-cjk-fonts google-noto-emoji-color-fonts xorg-x11-server-Xorg wayland-utils \
        pipewire pipewire-alsa pipewire-pulseaudio wireplumber powerdevil plasma-pa upower pulseaudio-utils \
        konsole dolphin kate kinfocenter glx-utils vulkan-tools \
        systemsettings plasma-systemmonitor kscreenlocker kio-extras xdg-user-dirs \
        dolphin-plugins ffmpegthumbs kdegraphics-thumbnailers kf6-kimageformats plasma-settings angelfish \
        gstreamer1-plugins-base gstreamer1-plugins-good sound-theme-freedesktop libcanberra-gtk3 \
        polkit-kde-agent-1 plasma-workspace breeze-icon-theme plasma-breeze qt6-qtsvg \
        kf6-kirigami qt6-qtquickcontrols2 qt6-qtdeclarative glibc-langpack-zh $shell_pkgs
    dnf remove -y ModemManager || true
}

install_arch() {
    # 5.x 构建才装 shell + maliit（见文件头注释）
    local shell_pkgs=""
    [ "${ANLAND_MAJOR_ARG:-6}" = "6" ] || \
        shell_pkgs="plasma-mobile plasma-keyboard plasma-nano kwin"
    pacman -S --noconfirm --needed \
        xorg-xrandr noto-fonts-cjk noto-fonts-emoji plasma-desktop plasma-workspace \
        plasma-settings plasma-camera \
        qt6-wayland qt6-svg qt6-virtualkeyboard wayland-utils xorg-server \
        pipewire pipewire-alsa pipewire-pulse wireplumber powerdevil plasma-pa upower \
        kscreen ark konsole qmlkonsole dolphin kate kinfocenter mesa-utils libpulse vulkan-tools \
        aha clinfo dmidecode kfind plasma-systemmonitor filelight glmark2 vkmark \
        systemsettings kscreenlocker kio-extras xdg-user-dirs \
        dolphin-plugins ffmpegthumbs kdegraphics-thumbnailers kimageformats \
        plasma-browser-integration angelfish kclock libcanberra \
        gstreamer gst-plugins-base gst-plugins-good sound-theme-freedesktop polkit-kde-agent $shell_pkgs
}

install_profile() {
    case "$ID" in
        debian|ubuntu) install_apt ;;
        fedora) install_fedora ;;
        arch|archarm|archlinux) install_arch ;;
        *) echo "KDE mobile 不支持当前发行版：$ID" >&2; return 1 ;;
    esac
}

case "${1:-install}" in
    install) install_profile ;;
    configure-environment) configure_environment "${2:-}" ;;
    *) echo "KDE mobile profile 操作无效：$1" >&2; exit 1 ;;
esac
