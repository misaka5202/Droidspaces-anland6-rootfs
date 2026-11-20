#!/system/bin/sh
# =============================================================================
# setup-anland6-host.sh — anland 6.x 宿主侧一键配置
# =============================================================================
#
# 在 Android 设备上用 root 执行（放到 /data/local/tmp 或 /sdcard 均可）：
#
#   su -c 'sh /data/local/tmp/setup-anland6-host.sh'
#
# 它做四件事，每一步都可重复执行（幂等）：
#
#   1. 检查环境：root、root 管理器、Droidspaces、Anland 6.x 模块
#   2. 装或修宿主三件套：anland-awl 模块 / anland-wayland.apk / anland-shell.apk
#   3. 写守护进程配置：auto_attach=1、scale_mode=1（Fit，竖屏不变形）
#   4. 给现有容器补上 /run/anland 绑定挂载
#
# 参数：
#   --apk-dir DIR    从本地目录取 apk（默认从网上下载）
#   --no-download    只用本地文件，缺什么报什么
#   --dry-run        只检查不修改
#   --skip-shell     不装 anland-shell（你自己装）
#
# 为什么需要这个脚本：anland 6.x 的宿主侧有四个坑，任何一个没踩对都没有画面：
#   ① 模块没重启 → waylandbridge 不跑 → 没有 /data/local/tmp/awl/wayland-0
#   ② 装了 5.x 的 anland-daemon → 两套路由打架
#   ③ anland-shell 1.1 调 `droidspaces show --format`，而 Droidspaces ≥7.2.0
#      已改用 `show --json` → 容器永远显示 stopped → 应用网格点不开
#   ④ 容器没有 -B /data/local/tmp/awl:/run/anland → 容器内找不到 wayland socket
#
# 本脚本把 ①③④ 自动化，②只警告不自动删（5.x 组件可能是你别的用途要留的）。
# =============================================================================

set -u

# ---------------------------------------------------------------- 常量

AWL_MODULE_ID="anland-awl"
CONTAINERS_DIR="/data/local/Droidspaces/Containers"
PIDS_DIR="/data/local/Droidspaces/Pids"
AWL_RT="/data/local/tmp/awl"
AWL_SOCK="$AWL_RT/wayland-0"
MODULE_DIR="/data/adb/modules/$AWL_MODULE_ID"
CONFIG_JSON="$MODULE_DIR/config.json"

# sc_enabled=0：waylandbridge 用 GL renderer 直接导入 dma-buf，而非 SurfaceControl
# 合成器。高通（本 fork 的目标）上 sc_enabled=1 会在 AHardwareBuffer_allocate
# abort（"Failed to load matching allocator for mapper version 4"，见 SuperTurtleDev/anland
# issue #84）；MTK 文档同样要求 0（SurfaceControl 无法呈现 dma-buf）。所以恒 0。
SC_ENABLED=0

# 打过 Droidspaces 7.2.0 兼容补丁的 anland-shell。
# 官方的 1.1 在 7.2.0 上容器列表失效；这个包先试 --json 再回退 --format。
SHELL_APK_URL="https://github.com/misaka5202/anland-shell/releases/download/v1.1-ds73/anland-shell.apk"

# 宿主模块 / APK 的来源：改版（misaka5202/anland）。
# 上游 6.2 的整包叫 anland-build.2.zip（module/anland-awl.zip 在里面）；
# 改版从 6.2-ds6 起直接发独立文件，所以这里按独立文件下载。
# 默认跟随最新发布（releases/latest 会 302 到最新 tag 的同一个文件）；
# 需要复现旧版本时显式固定，例如 AWL_RELEASE_TAG=6.2-ds6。
AWL_RELEASE_REPO="${AWL_RELEASE_REPO:-misaka5202/anland}"
AWL_RELEASE_TAG="${AWL_RELEASE_TAG:-}"
if [ -n "$AWL_RELEASE_TAG" ]; then
    AWL_RELEASE_URL="https://github.com/${AWL_RELEASE_REPO}/releases/download/${AWL_RELEASE_TAG}"
else
    AWL_RELEASE_URL="https://github.com/${AWL_RELEASE_REPO}/releases/latest/download"
fi

WORK=""
DRY_RUN=0
SKIP_SHELL=0
NO_DOWNLOAD=0
APK_DIR=""

# ---------------------------------------------------------------- 输出

# 文案目录。语言判定走 getprop / LANG，默认英文。
# 文案是 printf 格式串，变量在调用点替换。
_i18n="$(dirname "$0")/i18n.sh"
[ -f "$_i18n" ] || _i18n=/data/local/tmp/i18n.sh
[ -f "$_i18n" ] && . "$_i18n"

say()  { echo "  $*"; }
step() { echo; echo "==> $*"; }
ok()   { echo "  [OK]   $*"; }
warn() { echo "  [WARN] $*"; }
err()  { echo "  [FAIL] $*"; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------- 参数

while [ $# -gt 0 ]; do
    case "$1" in
        --apk-dir)    APK_DIR="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=1; shift ;;
        --skip-shell) SKIP_SHELL=1; shift ;;
        --no-download) NO_DOWNLOAD=1; shift ;;
        -h|--help)    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "$(printf "$M_UNKNOWN_ARG" "$1")" ;;
    esac
done

need_root() {
    [ "$(id -u)" = "0" ] || die "$(printf "$M_NEED_ROOT" "$0")"
}
need_root

WORK="/data/local/tmp/anland6-setup.$$"
mkdir -p "$WORK" || die "$(printf "$M_NO_TMPDIR" "$WORK")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# =============================================================================
step "$(printf "$M_STEP" "1/6" "$M_ST1")"
# =============================================================================

# --- root 管理器
RM=""
[ -d /data/adb/ksu ]      && RM="KernelSU"
[ -d /data/adb/ksunext ]  && RM="KernelSU-Next"
[ -d /data/adb/ap ]       && RM="APatch"
[ -d /data/adb/magisk ]   && RM="${RM:-Magisk}"
[ -n "$RM" ] && ok "$(printf "$M_ROOT_MANAGER" "$RM")" || warn "$M_NO_ROOT_MANAGER"

# --- droidspaces 二进制
DS=""
for c in /system/bin/droidspaces /data/local/Droidspaces/bin/droidspaces; do
    [ -x "$c" ] && { DS="$c"; break; }
done
[ -n "$DS" ] && ok "droidspaces：$DS" || die "找不到 droidspaces，先装 Droidspaces"
DS_VER=$(timeout 5 "$DS" help 2>/dev/null | grep -o 'v[0-9][0-9.]*' | head -1 | tr -d v)
[ -n "$DS_VER" ] && ok "Droidspaces 版本：$DS_VER" || warn "读不出版本号"

# --- 判断是否需要 anland-shell 补丁（>= 7.2.0 才需要）
NEED_SHELL_PATCH=0
if [ -n "$DS_VER" ]; then
    major=$(echo "$DS_VER" | cut -d. -f1)
    minor=$(echo "$DS_VER" | cut -d. -f2)
    if [ "${major:-0}" -gt 7 ] || { [ "${major:-0}" -eq 7 ] && [ "${minor:-0}" -ge 2 ]; }; then
        NEED_SHELL_PATCH=1
        say "$(printf "$M_NEED_PATCH" "7.2.0")"
    fi
fi

# --- 有没有装 5.x 的组件（会打架）
if [ -d /data/adb/modules/anland-daemon ]; then
    warn "$M_OLD_DAEMON"
    warn "$M_OLD_DAEMON_FIX"
fi
if pm list packages 2>/dev/null | grep -q 'com.anland.consumer'; then
    warn "$M_OLD_CONSUMER"
fi

# =============================================================================
step "$(printf "$M_STEP" "2/6" "$M_ST2")"
# =============================================================================

module_ready() {
    [ -x "$MODULE_DIR/waylandbridge" ] && [ -f "$MODULE_DIR/service.sh" ]
}

MODULE_CHANGED=0
if module_ready; then
    ok "$(printf "$M_MODULE_OK" "$MODULE_DIR")"
else
    # 两种情况：没装 / 装了但停在 modules_update（刷完没重启）
    if [ -d "/data/adb/modules_update/$AWL_MODULE_ID" ]; then
        warn "$M_MODULE_PENDING"
        MODULE_CHANGED=1
    else
        # 找现成的 zip
        ZIP=""
        [ -n "$APK_DIR" ] && [ -f "$APK_DIR/$AWL_MODULE_ID.zip" ] && ZIP="$APK_DIR/$AWL_MODULE_ID.zip"
        for c in "/sdcard/Download/$AWL_MODULE_ID.zip" "/data/local/tmp/$AWL_MODULE_ID.zip"; do
            [ -n "$ZIP" ] && break
            [ -f "$c" ] && ZIP="$c"
        done

        if [ -z "$ZIP" ] && [ "$NO_DOWNLOAD" -eq 0 ]; then
            say "$(printf "$M_NO_LOCAL_ZIP" "$AWL_MODULE_ID")"
            if command -v curl >/dev/null 2>&1; then
                curl -fsSL --max-time 180 -o "$WORK/$AWL_MODULE_ID.zip" \
                    "$AWL_RELEASE_URL/anland-awl.zip" >/dev/null 2>&1 || true
                [ -s "$WORK/$AWL_MODULE_ID.zip" ] && ZIP="$WORK/$AWL_MODULE_ID.zip"
            fi
        fi

        if [ -z "$ZIP" ]; then
            warn "$M_GET_ZIP_FAIL"
            say "$M_GET_ZIP_MANUAL"
            say "$M_GET_ZIP_WHERE"
            say "  https://github.com/SuperTurtleDev/anland/releases/tag/6.2"
        else
            ok "$(printf "$M_FOUND_ZIP" "$ZIP")"
            if [ "$DRY_RUN" -eq 1 ]; then
                say "$M_DRYRUN_SKIP_INSTALL"
            elif command -v ksud >/dev/null 2>&1; then
                KS=/data/adb/ksud; [ -x "$KS" ] || KS=ksud
                if "$KS" module install "$ZIP" >/dev/null 2>&1; then
                    ok "$M_KSUS_OK"
                    MODULE_CHANGED=1
                else
                    warn "$M_KSUS_FAIL"
                fi
            fi

            if [ "$MODULE_CHANGED" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
                mkdir -p "$MODULE_DIR" || die "无法创建 $MODULE_DIR"
                if command -v unzip >/dev/null 2>&1; then
                    unzip -o -q "$ZIP" -d "$MODULE_DIR" && \
                        chmod 755 "$MODULE_DIR/waylandbridge" "$MODULE_DIR/service.sh" 2>/dev/null
                    touch "$MODULE_DIR/update"
                    ok "$(printf "$M_MANUAL_OK" "$MODULE_DIR")"
                    MODULE_CHANGED=1
                else
                    die "没有 unzip，请用 KernelSU 管理器手动刷 $ZIP"
                fi
            fi
        fi
    fi
fi

# =============================================================================
step "$(printf "$M_STEP" "3/6" "$M_ST3")"
# =============================================================================

# --- anland-wayland.apk (com.anlandnext：每个窗口一个 Android Activity)
if pm list packages 2>/dev/null | grep -q 'com.anlandnext'; then
    ok "$M_NEXT_OK"
else
    APK=""
    [ -n "$APK_DIR" ] && [ -f "$APK_DIR/anland-wayland.apk" ] && APK="$APK_DIR/anland-wayland.apk"
    [ -z "$APK" ] && [ -f /sdcard/Download/anland-wayland.apk ] && APK=/sdcard/Download/anland-wayland.apk

    if [ -z "$APK" ] && [ "$NO_DOWNLOAD" -eq 0 ] && command -v curl >/dev/null 2>&1; then
        say "$M_DL_WAYLAND"
        curl -fsSL --max-time 180 -o "$WORK/anland-wayland.apk" \
            "$AWL_RELEASE_URL/anland-wayland.apk" >/dev/null 2>&1 || true
        [ -s "$WORK/anland-wayland.apk" ] && APK="$WORK/anland-wayland.apk"
    fi

    if [ -n "$APK" ]; then
        [ "$DRY_RUN" -eq 1 ] && say "$M_DRYRUN 会装 $APK" || { pm install -r "$APK" >/dev/null 2>&1 && ok "已安装 anland-wayland.apk" || warn "安装失败"; }
    else
        warn "$M_GET_WAYLAND_FAIL"
    fi
fi

# --- anland-shell.apk (启动器：管理容器、启动应用)
if [ "$SKIP_SHELL" -eq 1 ]; then
    say "$M_SHELL_SKIPPED"
elif pm list packages 2>/dev/null | grep -q 'com.anland.shell'; then
    if [ "$NEED_SHELL_PATCH" -eq 1 ]; then
        warn "$M_SHELL_STOCK_WARN"
        say "$M_SHELL_STOCK_HINT"
        say "$M_SHELL_STOCK_CMD"
    else
        ok "$M_SHELL_OK"
    fi
else
    APK=""
    [ -n "$APK_DIR" ] && [ -f "$APK_DIR/anland-shell.apk" ] && APK="$APK_DIR/anland-shell.apk"
    if [ -z "$APK" ] && [ "$NEED_SHELL_PATCH" -eq 1 ] && [ "$NO_DOWNLOAD" -eq 0 ] && command -v curl >/dev/null 2>&1; then
        say "$M_DL_SHELL"
        curl -sSL --max-time 120 -o "$WORK/anland-shell.apk" "$SHELL_APK_URL" >/dev/null 2>&1 || true
        [ -s "$WORK/anland-shell.apk" ] && APK="$WORK/anland-shell.apk"
    fi
    if [ -n "$APK" ]; then
        [ "$DRY_RUN" -eq 1 ] && say "$M_DRYRUN 会装 $APK" || { pm install -r -d "$APK" >/dev/null 2>&1 && ok "已安装 anland-shell.apk" || warn "安装失败"; }
    else
        warn "$M_GET_SHELL_FAIL"
    fi
fi

# --- 给 app 提权提醒（anland-shell 要 root 才看得到容器目录）
UID_SHELL=$(pm list packages -U 2>/dev/null | grep 'com.anland.shell' | sed 's/.*uid://' | head -1)
if [ -n "$UID_SHELL" ]; then
    say "$(printf "$M_SHELL_UID" "$UID_SHELL")"
    say "$(printf "$M_SHELL_UID2" "$CONTAINERS_DIR")"
fi

# =============================================================================
step "$(printf "$M_STEP" "4/6" "$M_ST4")"
# =============================================================================

# 只在模块在位时写配置（模块没到位写了也会被覆盖）
if [ -d "$MODULE_DIR" ] && [ "$DRY_RUN" -eq 0 ]; then
    if [ -f "$CONFIG_JSON" ]; then
        cp -f "$CONFIG_JSON" "$CONFIG_JSON.bak"
        # auto_attach=1：窗口创建时宿主自动开 Android 窗口
        # scale_mode=1 ：等比缩放（Fit）。默认 0 是两轴各自拉满，竖屏手机上
        #                800x600 的占位会被拉成 1264x2780，变形到不可用。
        sed -i 's/"auto_attach":[[:space:]]*[01]/"auto_attach": 1/' "$CONFIG_JSON" 2>/dev/null
        sed -i 's/"scale_mode":[[:space:]]*[012]/"scale_mode": 1/' "$CONFIG_JSON" 2>/dev/null
        sed -i "s/\"sc_enabled\":[[:space:]]*[01]/\"sc_enabled\": $SC_ENABLED/" "$CONFIG_JSON" 2>/dev/null
        ok "$M_CFG_UPDATED"
    else
        cat > "$CONFIG_JSON" <<JSON
{
  "zoom": 100,
  "init_w": 800,
  "init_h": 600,
  "scale_mode": 1,
  "xwayland_scale": 1,
  "auto_attach": 1,
  "sc_enabled": $SC_ENABLED,
  "runtime_dir": "/data/local/tmp/awl",
  "socket_listen": 1
}
JSON
        ok "$M_CFG_WRITTEN"
    fi
else
    say "$M_CFG_SKIP"
fi

# -----------------------------------------------------------------------------
# service_contexts 纠偏：把 anland.host 行插到通配符 '*' 之前
# 通配符必须是最后一行；否则 servicemanager 命中 '*' 给 anland.host 贴
# default_android_service，anlandnext find 被拒 → getService=null → 无窗口。
# 这是本 fork 多轮排查坐实的高通显示黑屏根因。
# -----------------------------------------------------------------------------
if [ "$DRY_RUN" -eq 0 ] && [ -d "$MODULE_DIR" ]; then
    PSC="$MODULE_DIR/system/etc/selinux/plat_service_contexts"
    if [ -f "$PSC" ]; then
        if grep -q '^anland\.host[[:space:]]' "$PSC" 2>/dev/null; then
            ANLINE=$(grep -m1 '^anland\.host[[:space:]]' "$PSC")
            STARN=$(grep -nE '^\*[[:space:]]' "$PSC" | head -1 | cut -d: -f1)
            ANLN=$(grep -nE '^anland\.host[[:space:]]' "$PSC" | head -1 | cut -d: -f1)
            # 通配符存在且 anland 行在它之后 → 乱序，需要修
            if [ -n "$STARN" ] && [ -n "$ANLN" ] && [ "$ANLN" -gt "$STARN" ]; then
                if [ "$DRY_RUN" -eq 1 ]; then
                    say "  would reorder: move anland.host before '*' in $PSC"
                else
                    cp -f "$PSC" "$PSC.setupbak"
                    grep -v '^anland\.host[[:space:]]' "$PSC" > "$PSC.new" || true
                    awk -v line="$ANLINE" '
                        BEGIN{done=0}
                        /^\*[[:space:]]/ && !done { print line; done=1 }
                        { print }
                    ' "$PSC.new" > "$PSC"
                    rm -f "$PSC.new"
                    ok "已修正 service_contexts：anland.host 移到通配符前"
                    say "     （需重启，servicemanager 才会重新加载标签）"
                    MODULE_CHANGED=1
                fi
            else
                ok "service_contexts 顺序正确"
            fi
        fi
    fi
fi

# =============================================================================
step "$(printf "$M_STEP" "5/6" "$M_ST5")"
# =============================================================================

# anland 6.x 的 socket 在宿主 /data/local/tmp/awl/wayland-0，
# 容器里的 anland-session 找 /run/anland/wayland-0 —— 靠 -B 对上。
# Droidspaces 会把 -B 持久化进 container.config，所以加一次就够。

if [ ! -d "$CONTAINERS_DIR" ]; then
    warn "$(printf "$M_NO_CONTAINERS" "$CONTAINERS_DIR")"
else
    for d in "$CONTAINERS_DIR"/*; do
        [ -d "$d" ] || continue
        name=$(basename "$d")
        cfg="$d/container.config"
        [ -f "$cfg" ] || continue

        if grep -q 'bind_mounts=.*/run/anland' "$cfg" 2>/dev/null; then
            ok "$(printf "$M_BIND_PRESENT" "$name")"
            continue
        fi

        if busy=$(cat "$PIDS_DIR/$name.pid" 2>/dev/null); [ -n "${busy:-}" ] && [ -d "/proc/$busy" ]; then
            warn "$(printf "$M_BIND_RUNNING" "$name")"
            say "     su -c 'droidspaces --name=$name -B $AWL_RT:/run/anland start'"
            continue
        fi

        if [ "$DRY_RUN" -eq 1 ]; then
            say "$(printf "$M_BIND_DRYRUN" "$name" "$AWL_RT")"
            continue
        fi

        if grep -q '^bind_mounts=' "$cfg" 2>/dev/null; then
            sed -i "s|^bind_mounts=\(.*\)$|bind_mounts=\1,$AWL_RT:/run/anland|" "$cfg"
        else
            echo "bind_mounts=$AWL_RT:/run/anland" >> "$cfg"
        fi
        ok "$(printf "$M_BIND_ADDED" "$name" "$AWL_RT")"
    done
fi

# =============================================================================
step "$(printf "$M_STEP" "6/6" "$M_ST6")"
# =============================================================================

if pidof waylandbridge >/dev/null 2>&1; then
    ok "$(printf "$M_DAEMON_UP" "$(pidof waylandbridge)")"
else
    warn "$M_DAEMON_DOWN"
fi
[ -S "$AWL_SOCK" ] && ok "socket 就绪：$AWL_SOCK" || warn "socket 不存在：$AWL_SOCK"
service list 2>/dev/null | grep -q 'anland.host' && ok "binder 服务 anland.host 已注册" || warn "anland.host 未注册"

echo
if [ "$MODULE_CHANGED" -eq 1 ]; then
    echo "  ┌──────────────────────────────────────────────────────┐"
    echo "  │  需要重启：模块要过重启才会被 KernelSU 启用          │"
    echo "  └──────────────────────────────────────────────────────┘"
    echo
    echo "    su -c 'reboot'"
    echo
    echo "  重启后跑验证："
    echo "    su -c 'sh $0'          # 再跑一次，全部应显示 [OK]"
else
    echo "  ┌──────────────────────────────────────────────────────┐"
    echo "  │  从 anland-shell 开始用，不要在容器里手敲命令        │"
    echo "  └──────────────────────────────────────────────────────┘"
    echo
    echo "    打开 anland-shell"
    echo "      → 选容器，点 START（已跑着就跳过）"
    echo "      → 点 APPS，等应用列表出来"
    echo "      → 点任意应用，它会变成一个真正的 Android 窗口"
    echo
    echo "  anland-shell 是唯一会把启动环境准备正确的入口："
    echo "  它注入 XDG_RUNTIME_DIR / WAYLAND_DISPLAY / DBUS 并通过 systemd"
    echo "  用户会话启动，手动 droidspaces run 拿不到完整会话。"
    echo
    echo "  这一步常见的四个异常："
    echo "    · 容器显示 stopped 但实际在跑 → anland-shell 不兼容 Droidspaces ≥7.2.0"
    echo "    · 显示 no containers defined     → 没给 com.anland.shell root 权限"
    echo "    · APPS 报 Anlandx not installed  → 容器没在跑，先 START"
    echo "    · 应用点了没反应                 → 跑 verify-anland6-host.sh 定位"
    echo
    echo "  第一次用建议在 com.anlandnext 的 Window Settings 里确认："
    echo "    Window scaling = Fit（默认 Stretch 在竖屏上会拉成 4.6 倍变形）"
    echo "    Auto attach new windows = 开"
fi
echo