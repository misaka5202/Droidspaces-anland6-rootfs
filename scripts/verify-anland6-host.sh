#!/system/bin/sh
# =============================================================================
# verify-anland6-host.sh — anland 6.x 显示链路诊断
# =============================================================================
#
#   su -c 'sh /data/local/tmp/verify-anland6-host.sh'
#
# 按「宿主 → 容器 → 应用」三层逐项检查，指出断在哪一层。
# 只读，不修改任何东西，可以随时在出问题时跑。
#
# 这一串检查是排查「anland 没有画面」时总结出来的，顺序按失败概率排：
# 绝大多数问题出在 socket 没起来 / 容器没挂上 / 应用没被订阅。
# =============================================================================

set -u

AWL_RT="/data/local/tmp/awl"
AWL_SOCK="$AWL_RT/wayland-0"
CONTAINERS_DIR="/data/local/Droidspaces/Containers"
PIDS_DIR="/data/local/Droidspaces/Pids"
MODULE_DIR="/data/adb/modules/anland-awl"

PASS=0; FAIL=0
# 文案目录：语言判定走 getprop / LANG，默认英文。
_i18n="$(dirname "$0")/i18n.sh"
[ -f "$_i18n" ] || _i18n=/data/local/tmp/i18n.sh
[ -f "$_i18n" ] && . "$_i18n"

ok()   { echo "  ✅ $*"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $*"; FAIL=$((FAIL+1)); }
note() { echo "     $*"; }

[ "$(id -u)" = "0" ] || { echo "需要 root：su -c 'sh $0'"; exit 1; }

echo "================================================================"
echo " $M_V_LAYER_HOST"
echo "================================================================"

# --- 1. 模块
if [ -d "$MODULE_DIR" ] && [ -x "$MODULE_DIR/waylandbridge" ]; then
    if [ -f "$MODULE_DIR/disable" ] || [ -f "$MODULE_DIR/skip_mount" ]; then
        bad "$M_V_MODULE_DISABLED"
        note "$(printf "$M_V_MODULE_DISABLED_FIX" "$MODULE_DIR" "$MODULE_DIR")"
    else
        ok "$M_V_MODULE_OK"
    fi
elif [ -d "/data/adb/modules_update/anland-awl" ]; then
    bad "$M_V_MODULE_PENDING"
    note "$M_V_MODULE_PENDING_FIX"
else
    bad "$M_V_MODULE_MISSING"
    note "$M_V_MODULE_MISSING_FIX"
fi

# --- 2. 守护进程
DPID=$(pidof waylandbridge 2>/dev/null)
if [ -n "$DPID" ]; then
    ok "$(printf "$M_V_DAEMON_UP" "$DPID")"
    DOMAIN=$(cat /proc/$DPID/attr/current 2>/dev/null | cut -d: -f3)
    case "$DOMAIN" in
        awl_daemon*) ok "SELinux 域：$DOMAIN" ;;
        *) note "SELinux 域是 $DOMAIN（预期 awl_daemon；permissive 也能跑）" ;;
    esac
else
    bad "$M_V_DAEMON_DOWN"
    note "$(printf "$M_V_DAEMON_DOWN_FIX" "$MODULE_DIR")"
    note "$M_V_DAEMON_BOOT_FIX"
fi

# --- 3. socket
if [ -S "$AWL_SOCK" ]; then
    ok "$(printf "$M_V_SOCKET_OK" "$AWL_SOCK")"
    LISTENER=$(ss -xl 2>/dev/null | grep -c "$AWL_SOCK")
    [ "${LISTENER:-0}" -gt 0 ] && ok "socket 在 LISTEN" || note "没看到 LISTEN 状态（可能 ss 不可用）"
else
    bad "$(printf "$M_V_SOCKET_MISSING" "$AWL_SOCK")"
    note "$M_V_SOCKET_MISSING_FIX"
fi

# --- 4. binder 服务
if service list 2>/dev/null | grep -q 'anland.host'; then
    ok "$M_V_BINDER_OK"
else
    bad "$M_V_BINDER_MISSING"
    note "$M_V_BINDER_MISSING_FIX"
fi

# --- 5. 宿主 APK
if pm list packages 2>/dev/null | grep -q 'com.anlandnext'; then
    ok "$M_V_NEXT_INSTALLED"
    if pidof com.anlandnext >/dev/null 2>&1; then
        ok "$M_V_NEXT_RUNNING"
    else
        note "$M_V_NEXT_NOT_RUNNING"
    fi
else
    bad "$M_V_NEXT_MISSING"
fi

# --- 6. 5.x 残留
if [ -d /data/adb/modules/anland-daemon ] || pm list packages 2>/dev/null | grep -q 'com.anland.consumer'; then
    note "$M_V_OLD_COMPONENTS"
fi

# --- 7. daemon 配置
if [ -f "$MODULE_DIR/config.json" ]; then
    ATT=$(grep -o '"auto_attach":[[:space:]]*[01]' "$MODULE_DIR/config.json" 2>/dev/null | grep -o '[01]$')
    SCM=$(grep -o '"scale_mode":[[:space:]]*[012]' "$MODULE_DIR/config.json" 2>/dev/null | grep -o '[012]$')
    [ "${ATT:-0}" = "1" ] && ok "auto_attach=1（窗口自动附着）" || bad "auto_attach=${ATT:-未设置} → 窗口不会自动弹"
    case "${SCM:-0}" in
        0) note "scale_mode=0（Stretch：两轴各自拉满，竖屏会严重变形）" ;;
        1) ok "scale_mode=1（Fit：等比缩放）" ;;
        2) ok "scale_mode=2（1:1 居中）" ;;
    esac
else
    note "$M_V_NO_CFG"
fi

echo
echo "================================================================"
echo " $M_V_LAYER_CTR"
echo "================================================================"

if [ ! -d "$CONTAINERS_DIR" ]; then
    bad "$(printf "$M_V_NO_CONTAINERS" "$CONTAINERS_DIR")"
else
    FOUND=0
    for d in "$CONTAINERS_DIR"/*; do
        [ -d "$d" ] || continue
        FOUND=1
        name=$(basename "$d")
        cfg="$d/container.config"
        echo "$(printf "$M_V_CTR_HEAD" "$name")"

        RUNPID=$(cat "$PIDS_DIR/$name.pid" 2>/dev/null)
        if [ -n "${RUNPID:-}" ] && [ -d "/proc/$RUNPID" ]; then
            ok "$(printf "$M_V_CTR_RUNNING" "$RUNPID")"
            RUNNING=1
        else
            note "$M_V_CTR_NOT_RUNNING"
            RUNNING=0
        fi

        # 绑定挂载（决定容器里能不能看到 wayland socket）
        if grep -q 'bind_mounts=.*/run/anland' "$cfg" 2>/dev/null; then
            ok "$M_V_BIND_OK"
        else
            bad "$M_V_BIND_MISSING"
            note "跑 setup-anland6-host.sh 补上，或启动时带 -B $AWL_RT:/run/anland"
        fi

        if [ "$RUNNING" = "1" ]; then
            if /data/local/Droidspaces/bin/droidspaces --name="$name" run -- \
                    test -S /run/anland/wayland-0 2>/dev/null; then
                ok "$M_V_SOCKET_IN_CTR"
            else
                bad "$M_V_SOCKET_NOT_IN_CTR"
                note "绑定没生效 —— 停掉容器后重跑一次 setup 脚本"
            fi

            if /data/local/Droidspaces/bin/droidspaces --name="$name" run -- \
                    test -x /home/*/.local/bin/anland-session 2>/dev/null; then
                ok "$M_V_SESSION_OK"
            else
                note "容器里没找到 anland-session —— 用的可能不是本仓库的镜像"
            fi

            SESS=$(/data/local/Droidspaces/bin/droidspaces --name="$name" run -- \
                    sh -c 'pgrep -f "[a]nland-session" | wc -l' 2>/dev/null | tr -d ' \r\n')
            [ "${SESS:-0}" -gt 0 ] && ok "anland-session 在跑" || \
                bad "anland-session 没跑（desktop-session 服务失败？）"
        fi
    done
    [ "$FOUND" = "0" ] && bad "没有定义的容器"
fi

echo
echo "================================================================"
echo " $M_V_LAYER_DISP"
echo "================================================================"

if dumpsys window 2>/dev/null | grep -q 'AwlWindowActivity'; then
    ok "$M_V_WINDOW_OK"
    dumpsys window 2>/dev/null | grep -o 'mCurrentFocus=.*' | head -1 | sed 's/^/     /'
    CNT=$(dumpsys SurfaceFlinger --list 2>/dev/null | grep -c 'AwlWindowActivity.*BLAST')
    [ "${CNT:-0}" -gt 0 ] && ok "有 $CNT 个 BLAST 层（真的在出画面）" || note "没看到 BLAST 层"
else
    note "当前没有 anland 窗口 —— 这是正常的，还没启动应用"
fi

echo
echo "================================================================"
printf " 结果：%d 项通过，%d 项失败\n" "$PASS" "$FAIL"
echo "================================================================"
echo

if [ "$FAIL" -gt 0 ]; then
    echo "$M_V_BREAKPOINTS"
    echo "    · socket 不存在      → daemon 没起：sh $MODULE_DIR/service.sh，或重启"
    echo "    · 容器内看不到 socket → 缺 -B 绑定：重跑 setup-anland6-host.sh"
    echo "    · anland-session 没跑 → desktop-session 失败："
    echo "        droidspaces --name=<名字> run -- systemctl status desktop-session"
    echo "    · 容器显示 stopped 却实际在跑 → anland-shell 版本不兼容 Droidspaces ≥7.2.0"
    echo "        （用 setup 脚本装的补丁版可解）"
    exit 1
fi

echo "  $M_V_CHAIN_OK"
echo
echo "$M_V_AFTER_LAUNCH"
echo "    logcat -d | grep 'anland-wl:' | tail -20"
echo "  关键行是 'surface N mapped'（客户端提交了首帧）和"
echo "  'window WxH attached'（Android 窗口已附着）。只看到 'surface N created'"
echo "  而没有 mapped，说明客户端没有提交缓冲区。"
echo
exit 0