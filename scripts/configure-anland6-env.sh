#!/usr/bin/env bash
# 把 /etc/environment 里 5.x 专用的变量清掉，换成 6.x 该有的样子。
#
# 为什么需要这一步
# ----------------
# 每个桌面 profile 的 configure_environment（scripts/desktops/*.sh）是按
# anland **5.x** 写的，会往 /etc/environment 写：
#
#   ANLAND=1
#   ANLAND_SOCKET=/run/display.sock          ← 5.x 的显示协议 socket
#   ANLAND_DRM_DEVICE=/dev/dri/renderD128    ← 5.x 才读
#   ANLAND_SKIP_IMPLICIT_SYNC_WAIT=1
#   WAYLAND_DISPLAY=wayland-0                ← 6.x 会话发布的是 wayland-anland
#
# 6.x 里连接是 binder 传的 fd，**没有 socket 文件**，这几个变量要么被忽略、
# 要么有害：WAYLAND_DISPLAY=wayland-0 会让应用在会话还没写好 ~/.anlandx-env
# 之前就去连一个不存在的 socket。
#
# 6.x 的应用环境由会话自己在 ~/.anlandx-env 里发布：
#   XDG_RUNTIME_DIR=/run/user/<uid>
#   WAYLAND_DISPLAY=wayland-anland
#   DBUS_SESSION_BUS_ADDRESS=...
#
# 所以这里只保留与 anland 版本无关的（QT_QPA_PLATFORM=wayland 这类），
# 把 5.x 的整套删掉。

set -euo pipefail

ENVFILE="${ROOTFS_DIR:-}/etc/environment"
MARKER="${ROOTFS_DIR:-}/etc/droidspaces-anland-major"

log() { printf '%s\n' "--> [anland6-env] $*"; }

# 不是 6.x 就什么都不做，5.x 的配置原样保留
if [ "$(cat "$MARKER" 2>/dev/null)" != "6" ]; then
    log "不是 6.x，保持原样"
    exit 0
fi

if [ ! -f "$ENVFILE" ]; then
    log "$ENVFILE 不存在，跳过"
    exit 0
fi

# 5.x 专用变量，必须删
STRIP='^(ANLAND|ANLAND_SOCKET|ANLAND_DRM_DEVICE|ANLAND_SKIP_IMPLICIT_SYNC_WAIT|WAYLAND_DISPLAY|XWAYLAND_GBM_DEVICE)='

before=$(grep -cE "$STRIP" "$ENVFILE" 2>/dev/null || true)
sed -i -E "/$STRIP/d" "$ENVFILE"
after=$(grep -cE "$STRIP" "$ENVFILE" 2>/dev/null || true)

log "已删除 $(( ${before:-0} - ${after:-0} )) 条 5.x 变量"

# Qt 应用要靠这个走 wayland；会话会把真正的 socket 名放进 ~/.anlandx-env
grep -q '^QT_QPA_PLATFORM=' "$ENVFILE" || printf '%s\n' 'QT_QPA_PLATFORM=wayland' >> "$ENVFILE"

# 留个注释，免得以后有人以为是漏配
if ! grep -q '^# droidspaces: anland 6.x' "$ENVFILE" 2>/dev/null; then
    sed -i '1i # droidspaces: anland 6.x —— 应用环境由会话写进 ~/.anlandx-env，不在这里配' "$ENVFILE"
fi

log "完成"