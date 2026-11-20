#!/usr/bin/env bash
# steam-gaming.sh — Steam Gaming desktop profile.
#
# Installs Valve ARM64 Steam client + FEX + game-grade system deps.
# Session is still anland-session (each window = one Android window);
# Steam is launched via desktop file / anland-shell APP.
#
# Windows games run through Proton (Valve ARM64 Proton, auto-downloaded on first use)
# + Turnip (Vulkan, Adreno) or libhybris (Mali).

set -euo pipefail

source "${ROOTFS_DIR:-}/etc/os-release"

configure_environment() {
    local backend="${1:-}"
    local environment_file="${ROOTFS_DIR:-}/etc/environment"
    local assignment key

    [[ "$backend" == anland-wayland ]] || {
        echo "Steam Gaming 显示后端无效：$backend" >&2
        return 1
    }

    local -a assignments=(
        XDG_SESSION_CLASS=user
        XDG_SESSION_TYPE=wayland
        ANLAND_RUNTIME_DIR=/run/anland
        QT_QPA_PLATFORM=wayland
        # ---- Game performance ----
        WINEESYNC=1
        NTSYNC=1
        PROTON_NO_TIMELINE_SEMAPHORES=1  # DXVK >2.4.1 hits ~20% fps penalty on Turnip
        # ---- Vulkan ICD (Turnip for Adreno) ----
        VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/freedreno_icd.aarch64.json
    )

    # kgsl driver path (Qualcomm only; harmless on MTK)
    assignments+=(
        MESA_LOADER_DRIVER_OVERRIDE=kgsl
        GALLIUM_DRIVER=kgsl
        FD_FORCE_KGSL=1
    )

    touch "$environment_file"
    for assignment in "${assignments[@]}"; do
        key="${assignment%%=*}"
        if grep -q "^${key}=" "$environment_file"; then
            sed -i "s|^${key}=.*|${assignment}|" "$environment_file"
        else
            printf '%s\n' "$assignment" >> "$environment_file"
        fi
    done
}

# ---------- package install per distro ----------
# All package lists are game-grade deps required by Steam ARM64 client + Proton + FEX.

install_apt() {
    case "$ID:$VERSION_ID" in
        debian:13)
            apt-get install -y --no-install-recommends \
                dbus-x11 dbus-user-session xdg-user-dirs curl unzip python3 \
                pipewire pipewire-alsa pipewire-pulse wireplumber \
                vulkan-tools mesa-utils wayland-utils \
                libva2 libibus-1.0-0 libvpx7 libvpx-dev \
                libxcomposite1 libxcursor1 libxrandr2 libxi6 libx11-xcb1 \
                libxcb-dri3-0 libxcb-present0 libxcb-sync1 \
                libgl1 libglvnd0 libvulkan1 \
                fonts-noto-cjk fonts-noto-color-emoji fonts-noto-core \
                bash-completion ca-certificates
            ;;
        ubuntu:26.04)
            apt-get install -y --no-install-recommends \
                dbus-x11 dbus-user-session xdg-user-dirs curl unzip python3 \
                pipewire pipewire-alsa pipewire-pulse wireplumber \
                vulkan-tools mesa-utils wayland-utils \
                libva2 libibus-1.0-0 libvpx7 libvpx-dev \
                libxcomposite1 libxcursor1 libxrandr2 libxi6 libx11-xcb1 \
                libxcb-dri3-0 libxcb-present0 libxcb-sync1 \
                libgl1 libglvnd0 libvulkan1 \
                fonts-noto-cjk fonts-noto-color-emoji fonts-noto-core \
                bash-completion ca-certificates language-pack-zh-hans
            ;;
        *)
            echo "Steam Gaming 不支持当前系统：$ID $VERSION_ID" >&2
            return 1
            ;;
    esac
}

install_fedora() {
    case "$VERSION_ID" in
        43|44) ;;
        *) echo "Steam Gaming 不支持 Fedora $VERSION_ID" >&2; return 1 ;;
    esac

    dnf install -y --setopt=install_weak_deps=False \
        dbus-x11 dbus-user-session xdg-user-dirs curl unzip python3 \
        pipewire pipewire-alsa pipewire-pulseaudio wireplumber \
        vulkan-tools mesa-utils wayland-utils \
        libva libibus libvpx-devel libvpx7 \
        libXcomposite libXcursor libXrandr libXi libX11-xcb \
        libxcb-dri3 libxcb-present libxcb-sync \
        mesa-libGL libglvnd libvulkan \
        google-noto-cjk-fonts google-noto-emoji-color-fonts google-noto-sans-fonts \
        bash-completion ca-certificates
}

install_arch() {
    pacman -S --noconfirm --needed \
        dbus-x11 dbus-user-session xdg-user-dirs curl unzip python3 \
        pipewire pipewire-alsa pipewire-pulse wireplumber \
        vulkan-tools mesa-utils wayland-utils \
        libva libibus libvpx libvpx12 \
        libxcomposite libxcursor libxrandr libxi libx11-xcb \
        libxcb-dri3 libxcb-present libxcb-sync \
        mesa libglvnd vulkan-icd-loader vulkan-freedreno \
        noto-fonts-cjk noto-fonts-emoji noto-fonts \
        bash-completion ca-certificates
}

install_profile() {
    # 1. Game-grade system deps per distro
    case "$ID" in
        debian|ubuntu) install_apt ;;
        fedora) install_fedora ;;
        arch|archarm|archlinux) install_arch ;;
        *) echo "Steam Gaming 不支持当前发行版：$ID" >&2; return 1 ;;
    esac

    # 2. Steam ARM64 client + FEX + desktop launcher
    #    ROOTFS_DIR is inherited from the Docker build context (empty = current rootfs)
    if command -v install-steam >/dev/null 2>&1; then
        echo "--> 正在装配 Steam ARM64 client + FEX"
        install-steam --channel publicbeta
    else
        echo "!! install-steam 脚本未找到，跳过 Steam 装配" >&2
        echo "   请确认 Dockerfile 已 COPY scripts/tui/install-steam.sh 到 /usr/local/sbin/" >&2
    fi
}

case "${1:-install}" in
    install) install_profile ;;
    configure-environment) configure_environment "${2:-}" ;;
    *)
        echo "Steam Gaming profile 操作无效：$1" >&2
        exit 1
        ;;
esac
