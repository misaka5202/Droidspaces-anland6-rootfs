#!/usr/bin/env bash

write_rootfs_config() {
    local output="${1:?}" desktop="${2:?}" backend="${3:?}"
    local audio="${4:?}" docker_enabled="${5:?}" gpu_enabled="${6:?}"
    local zh_tz_enabled="${7:-false}"
    local anland=0 x11=0 pulse=0 userns=0 gpu=0

    case "$desktop" in none|kde|kde-mobile|mobile|gnome|anland-next|niri|hyprland|mango|denial|steam-gaming) ;; *) return 1 ;; esac
    case "$backend" in
        anland-wayland) anland=1 ;;
        x11) x11=1 ;;
        *) return 1 ;;
    esac
    case "$audio" in socket|tcp|none) ;; *) return 1 ;; esac
    case "$docker_enabled:$gpu_enabled" in true:true|true:false|false:true|false:false) ;; *) return 1 ;; esac
    case "$zh_tz_enabled" in true|false) ;; *) return 1 ;; esac
    [[ "$backend" == x11 && "$audio" == socket ]] && pulse=1
    [[ "$desktop" == kde || "$desktop" == kde-mobile || "$desktop" == mobile ]] && userns=1
    [[ "$gpu_enabled" == true ]] && gpu=1

    {
        printf '%s\n' '# Droidspaces 推荐配置'
        printf 'enable_anland=%s\nenable_termux_x11=%s\nenable_pulseaudio=%s\n' "$anland" "$x11" "$pulse"
        printf 'allow_userns=%s\nenable_gpu_mode=%s\n' "$userns" "$gpu"
        if [[ "$zh_tz_enabled" == true ]]; then
            printf '%s\n' 'dns_servers=114.114.114.114'
        fi
        if [[ "$docker_enabled" == true ]]; then
            printf '%s\n' 'net_mode=nat'
        fi
        if [[ "$desktop" == anland-next ]]; then
            printf '%s\n' 'bind_mounts=/data/local/tmp/awl:/run/anland'
        fi
    } > "$output"
}

package_rootfs_with_config() (
    set -euo pipefail
    local archive="${1:?}" output="${2:?}"
    shift 2
    local config_dir pending_output config_size config_blocks member
    local -a old_config=()
    config_dir=$(mktemp -d)
    pending_output=""
    trap 'rm -rf "$config_dir"; if [[ -n "$pending_output" ]]; then rm -f "$pending_output"; fi' EXIT
    write_rootfs_config "$config_dir/container.config" "$@"

    # 重建后的基础镜像可能已包含推荐配置；仅保留本次构建的设置。
    tar -tf "$archive" > "$config_dir/members"
    for member in container.config ./container.config container.config/ ./container.config/; do
        if grep -Fxq -- "$member" "$config_dir/members"; then
            old_config+=("$member")
        fi
    done
    if ((${#old_config[@]})); then
        tar --delete -f "$archive" -- "${old_config[@]}"
    fi

    # USTAR 可将配置放在第一个物理文件头中，避免前置 PAX 文件头。
    tar --format=ustar --owner=0 --group=0 --numeric-owner \
        -cf "$config_dir/config.tar" -C "$config_dir" container.config
    config_size=$(stat -c %s "$config_dir/container.config")
    config_blocks=$((1 + (config_size + 511) / 512))
    # 压缩 + 校验，最多试三次。
    #
    # 为什么要校验：GitHub runner 上实测出现过压缩产物**带空洞**的情况——
    # 930MB 的包里嵌入 296MB 全零段（偏移 296MB/42MB、374MB/49MB、592MB/205MB）。
    # xz 页脚完整，所以不是截断；构建日志里没有 ENOSPC，构建和上传都报成功，
    # 但用户解压直接失败：xz: Compressed data is corrupt。
    # 这种包发出去就是坏镜像，必须在这里挡住。
    #
    # 第一次用多线程（快），失败退到单线程重压（慢但写入路径更简单）。
    _xz_pack() {
        local threads="$1" out="$2"
        {
            dd if="$config_dir/config.tar" bs=512 count="$config_blocks" status=none &&
            cat "$archive"
        # 压缩是整个构建里最慢的一步：实测 Debian-13 单镜像 docker build 132 秒，
        # 而 xz -9 要 380 秒（占该步骤 73%）。-9 换 -6 约快一倍，产物只大 5% 左右；
        # 需要更小体积可设 XZ_PRESET=9。
        } | xz $threads "-${XZ_PRESET:-6}" -c > "$out"
    }

    # 速度优先：先用多线程（-T0）。实测 Docker 构建只占 2.5 分钟，
    # 单线程 xz 要 21 分钟 —— 压缩是整个构建 87% 的耗时。
    # 用 xz -t 兜底：坏了就重压，绝不输出坏包（上次就是坏包发出去，
    # 用户解压直接失败）。
    local _try _ok=0
    for _try in 1 2 3; do
        [ "$_try" -gt 1 ] && echo "  压缩产物校验失败，第 ${_try} 次重试..." >&2
        pending_output=$(mktemp "${output}.tmp.XXXXXX") || exit 1
        case "$_try" in
            1) _xz_pack "-T0" "$pending_output" ;;
            2) _xz_pack ""    "$pending_output" ;;
            *) XZ_PRESET=3 _xz_pack "-T0" "$pending_output" ;;
        esac
        if xz -t "$pending_output" 2>/dev/null; then
            _ok=1
            break
        fi
        echo "  第 ${_try} 次压缩产物损坏（xz -t 失败）" >&2
        rm -f "$pending_output"
        pending_output=""
    done
    if [ "$_ok" -ne 1 ]; then
        echo "压缩产物连续三次校验失败，拒绝输出损坏的镜像" >&2
        exit 1
    fi
    mv -f "$pending_output" "$output"
    pending_output=""
    rm -f "$archive"
)
