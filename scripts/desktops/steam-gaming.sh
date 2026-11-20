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
        debian:13|ubuntu:26.04)
            apt-get install -y --no-install-recommends                 curl unzip python3 dbus-x11 dbus-user-session xdg-user-dirs
            ;;
        *)
            echo "Steam Gaming apt unsupported: $ID $VERSION_ID" >&2
            return 1
            ;;
    esac
}

install_fedora() {
    case "$VERSION_ID" in 43|44) ;; *) return 1 ;; esac
    dnf install -y --setopt=install_weak_deps=False         curl unzip python3 dbus-x11 dbus-user-session xdg-user-dirs
}

install_arch() {
    pacman -S --noconfirm --needed         curl unzip python3 dbus-x11 dbus-user-session xdg-user-dirs
}

install_profile() {
    case "$ID" in
        debian|ubuntu) install_apt ;;
        fedora) install_fedora ;;
        arch|archarm|archlinux) install_arch ;;
        *) echo "Steam Gaming 不支持当前发行版：$ID" >&2; return 1 ;;
    esac

    if command -v install-steam >/dev/null 2>&1; then
        echo "--> 正在装配 Steam ARM64 client + FEX"
        install-steam --channel publicbeta
    else
        echo "!! install-steam 脚本未找到" >&2
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
