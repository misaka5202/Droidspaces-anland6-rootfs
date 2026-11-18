#!/system/bin/sh
# i18n.sh - 脚本文案目录
#
# 由 setup-anland6-host.sh / verify-anland6-host.sh 等 source。
# 设计与 droidspaces-lkm 的 i18n.sh 一致：
#
#   * 语言判定  设备上读 getprop；构建机/PC 上读 LANG。都取不到用英文。
#   * 英文是默认层，zh/ja 分支只覆盖自己翻译过的键，漏翻回退英文。
#   * 文案是 **printf 格式串**，不是成品句子 —— source 时那些变量还不存在。
#   * **标记不翻译**：[OK] [WARN] [FAIL] [SKIP] ⚠ ❌ ✅
#     路径、包名、容器名、daemon 日志里的英文短语也不翻译。
#
# 用法：
#   [ -f "$(dirname "$0")/i18n.sh" ] && . "$(dirname "$0")/i18n.sh"
#   say "$(printf "$M_SETUP_NEED_PATCH" "7.2.0")"

# ---------------------------------------------------------------------------
# 语言判定
# ---------------------------------------------------------------------------
if [ -z "${LKM4CTR_LANG:-}" ]; then
    _loc=$(getprop persist.sys.locale 2>/dev/null)
    [ -z "$_loc" ] && _loc=$(getprop ro.product.locale 2>/dev/null)
    [ -z "$_loc" ] && _loc="${LC_ALL:-${LANG:-}}"
    case "$_loc" in
        zh*|*CN*|*Hans*|*Hant*|*TW*|*HK*) LANG_CODE=zh ;;
        ja*|*JP*)                          LANG_CODE=ja ;;
        *)                                 LANG_CODE=en ;;
    esac
else
    LANG_CODE="$LKM4CTR_LANG"
fi

# ---------------------------------------------------------------------------
# 英文默认层
# ---------------------------------------------------------------------------
# --- 通用 ---
M_YES='yes'
M_NO='no'
M_DRYRUN='[dry-run]'

# --- setup-anland6-host.sh ---
M_NEED_ROOT="root is required: su -c 'sh %s'"
M_UNKNOWN_ARG='unknown argument: %s (see --help)'
M_NO_TMPDIR='cannot create temporary directory %s'
M_ROOT_MANAGER='root manager: %s'
M_NO_ROOT_MANAGER='could not identify the root manager (KernelSU/Magisk/APatch)'
M_NEED_PATCH='Droidspaces >= %s: the stock anland-shell 1.1 container list breaks, the patched build is required'
M_OLD_DAEMON='found the 5.x anland-daemon module; it conflicts with the 6.x routing'
M_OLD_DAEMON_FIX='if you do not need 5.x: su -c '"'"'rm -rf /data/adb/modules/anland-daemon'"'"' then reboot'
M_OLD_CONSUMER='found the 5.x com.anland.consumer; consider removing it: pm uninstall com.anland.consumer'
M_MODULE_OK='module installed and complete (%s)'
M_MODULE_PENDING='module is in modules_update — already flashed but not rebooted; it takes effect after a reboot'
M_NO_LOCAL_ZIP='no local %s.zip, trying to download'
M_GET_ZIP_FAIL='could not fetch anland-awl.zip'
M_GET_ZIP_MANUAL='download it by hand, put it in /sdcard/Download/, then run this script again:'
M_GET_ZIP_WHERE='  module/anland-awl.zip from the anland 6.2 release'
M_FOUND_ZIP='found module package: %s'
M_DRYRUN_SKIP_INSTALL='[dry-run] skipping install'
M_KSUS_OK='installed through ksud; takes effect after a reboot'
M_KSUS_FAIL='ksud install failed, falling back to manual extraction'
M_MANUAL_OK='extracted into %s manually (takes effect after a reboot)'
M_NEXT_OK='com.anlandnext installed (window consumer)'
M_DL_WAYLAND='downloading anland-wayland.apk'
M_GET_WAYLAND_FAIL='could not fetch anland-wayland.apk — get it from the anland 6.2 release'
M_SHELL_SKIPPED='skipped per --skip-shell'
M_SHELL_STOCK_WARN='com.anland.shell is installed, but Droidspaces >= 7.2.0 needs the patched build (otherwise containers always show stopped)'
M_SHELL_STOCK_HINT='if the container list works, ignore this; if not, reinstall with --apk-dir pointing at the patched build:'
M_SHELL_STOCK_CMD='  bash setup-anland6-host.sh --apk-dir <directory containing anland-shell.apk>'
M_SHELL_OK='com.anland.shell installed'
M_DL_SHELL='downloading the patched anland-shell'
M_GET_SHELL_FAIL='could not fetch anland-shell.apk — the stock one works, but the container list breaks on Droidspaces >= 7.2.0'
M_SHELL_UID='anland-shell uid=%s — you must grant it root in the root manager,'
M_SHELL_UID2='otherwise it cannot read %s (the symptom is "no containers defined")'
M_CFG_UPDATED='updated config.json (auto_attach=1, scale_mode=1), backup at config.json.bak'
M_CFG_WRITTEN='wrote a default config.json'
M_CFG_SKIP='[skip] module not in place, or dry-run'
M_NO_CONTAINERS='no container directory %s; create a container first'
M_BIND_PRESENT='[%s] already has the /run/anland bind mount'
M_BIND_RUNNING='[%s] is running, skipped (stop it first, or restart with -B)'
M_BIND_DRYRUN='[dry-run] would add bind_mounts=%s:/run/anland to [%s]'
M_BIND_ADDED='[%s] added bind_mounts=%s:/run/anland'
M_DAEMON_UP='waylandbridge is running (pid %s)'
M_DAEMON_DOWN='waylandbridge is not running — a reboot is needed if the module was just installed'
M_STEP='%s  %s'
M_ST1='environment check'
M_ST2='anland-awl module'
M_ST3='host APKs'
M_ST4='daemon configuration'
M_ST5='container bind mounts'
M_ST6='current state'


# --- verify: bad / note ---
M_V_MODULE_DISABLED='anland-awl module is disabled (disable/skip_mount marker present)'
M_V_MODULE_DISABLED_FIX='remove the marker and reboot: rm -f %s/disable %s/skip_mount'
M_V_MODULE_PENDING='module is in modules_update — flashed but not rebooted'
M_V_MODULE_PENDING_FIX='reboot: su -c reboot'
M_V_MODULE_MISSING='anland-awl module not installed'
M_V_MODULE_MISSING_FIX='run setup-anland6-host.sh, or flash anland-awl.zip in KernelSU'
M_V_DAEMON_DOWN='waylandbridge is not running'
M_V_DAEMON_DOWN_FIX="start it by hand: su -c 'sh %s/service.sh'"
M_V_DAEMON_BOOT_FIX='if it starts by hand but not at boot, check /data/local/tmp/awl_daemon.log'
M_V_SOCKET_MISSING='socket does not exist: %s'
M_V_SOCKET_MISSING_FIX='the daemon creates it once it runs; if it is missing, the daemon failed to start'
M_V_BINDER_MISSING='binder service anland.host is not registered'
M_V_BINDER_MISSING_FIX='the host APK (com.anlandnext) relies on it to find the daemon'
M_V_NEXT_NOT_RUNNING='com.anlandnext is not running — its window list shows already-connected windows'
M_V_NEXT_MISSING='com.anlandnext is not installed (without it there are no Android windows)'
M_V_OLD_COMPONENTS='5.x components found (anland-daemon / com.anland.consumer); they conflict with 6.x routing, consider removing them'
M_V_NO_CFG='no config.json; the daemon uses its compiled defaults (auto_attach=1, scale_mode=0)'
M_V_NO_CONTAINERS='no container directory %s'
M_V_CTR_NOT_RUNNING='not running'
M_V_BIND_MISSING='container.config has no /run/anland bind mount'
M_V_BIND_MISSING_FIX='re-run setup-anland6-host.sh, or start with -B %s:/run/anland'
M_V_SOCKET_NOT_IN_CTR='/run/anland/wayland-0 is not visible inside the container'
M_V_SESSION_MISSING='no anlandx session inside the container (anland-session)'
M_V_SESSION_MISSING_FIX='check the session: droidspaces --name=%s run -- systemctl status desktop-session'
M_V_WINDOW_MISSING='no AwlWindowActivity window yet'
M_V_WINDOW_MISSING_FIX='launch an application through anland-shell, then run this again'
M_V_BREAKPOINTS='  Common breakpoints:'
M_V_BP_SOCKET='    * socket missing         -> daemon not started: sh %s/service.sh, or reboot'
M_V_BP_BIND='    * no socket in container -> missing -B bind: re-run setup-anland6-host.sh'
M_V_BP_SESSION='    * anland-session absent  -> desktop-session failed:'
M_V_BP_SESSION_CMD='        droidspaces --name=<name> run -- systemctl status desktop-session'
M_V_BP_STOPPED='    * container shows stopped while running -> anland-shell is incompatible with Droidspaces >= 7.2.0'
M_V_BP_STOPPED_FIX='        (the patched build installed by the setup script fixes this)'
M_V_AFTER_LAUNCH='  If the window does not appear after launching an application, read the daemon log:'
M_V_KEY_LINES="  The key lines are 'surface N mapped' (the client committed its first frame) and"
M_V_KEY_LINES2="  'window WxH attached' (the Android window is attached). Seeing only 'surface N created'"
M_V_KEY_LINES3='  without mapped means the client never committed a buffer.'

# --- verify-anland6-host.sh ---
M_V_LAYER_HOST='Layer 1: host'
M_V_LAYER_CTR='Layer 2: container'
M_V_LAYER_DISP='Layer 3: display'
M_V_CTR_HEAD='  --- container: %s ---'
M_V_MODULE_OK='anland-awl module enabled'
M_V_DAEMON_UP='waylandbridge is running (pid %s)'
M_V_SOCKET_OK='socket exists: %s'
M_V_BINDER_OK='binder service anland.host registered'
M_V_NEXT_INSTALLED='com.anlandnext installed (window consumer)'
M_V_NEXT_RUNNING='com.anlandnext is running'
M_V_CTR_RUNNING='running (pid %s)'
M_V_BIND_OK='container.config has the /run/anland bind mount'
M_V_SOCKET_IN_CTR='/run/anland/wayland-0 is visible inside the container'
M_V_SESSION_OK='anlandx session present inside the container (anland-session)'
M_V_WINDOW_OK='an AwlWindowActivity window exists'
M_V_CHAIN_OK='chain complete. Open anland-shell -> pick the container -> APPS -> tap an application.'

# ---------------------------------------------------------------------------
# 语言覆盖
# ---------------------------------------------------------------------------
case "$LANG_CODE" in
zh)
    M_YES='是'
    M_NO='否'

    M_NEED_ROOT="需要 root：su -c 'sh %s'"
    M_UNKNOWN_ARG='未知参数：%s（用 --help 看用法）'
    M_NO_TMPDIR='无法创建临时目录 %s'
    M_ROOT_MANAGER='root 管理器：%s'
    M_NO_ROOT_MANAGER='没认出 root 管理器（KernelSU/Magisk/APatch）'
    M_NEED_PATCH='Droidspaces ≥ %s：官方 anland-shell 1.1 的容器列表会失效，需要补丁版'
    M_OLD_DAEMON='检测到 5.x 的 anland-daemon 模块，它和 6.x 路由冲突'
    M_OLD_DAEMON_FIX='确认不用 5.x 的话：su -c '"'"'rm -rf /data/adb/modules/anland-daemon'"'"' 然后重启'
    M_OLD_CONSUMER='检测到 5.x 的 com.anland.consumer，建议卸载：pm uninstall com.anland.consumer'
    M_MODULE_OK='模块已安装且完整（%s）'
    M_MODULE_PENDING='模块在 modules_update 里 —— 已经刷过但还没重启，重启后才会生效'
    M_NO_LOCAL_ZIP='本地没有 %s.zip，尝试下载…'
    M_GET_ZIP_FAIL='拿不到 anland-awl.zip'
    M_GET_ZIP_MANUAL='手动下载后放到 /sdcard/Download/ 再跑一次本脚本：'
    M_GET_ZIP_WHERE='  anland 6.2 release 里的 module/anland-awl.zip'
    M_FOUND_ZIP='找到模块包：%s'
    M_DRYRUN_SKIP_INSTALL='[dry-run] 跳过安装'
    M_KSUS_OK='已通过 ksud 安装，重启后生效'
    M_KSUS_FAIL='ksud 安装失败，改用手动解压'
    M_MANUAL_OK='已手动解压到 %s（重启后生效）'
    M_NEXT_OK='com.anlandnext 已安装（窗口消费者）'
    M_DL_WAYLAND='下载 anland-wayland.apk…'
    M_GET_WAYLAND_FAIL='拿不到 anland-wayland.apk —— 从 anland 6.2 release 取'
    M_SHELL_SKIPPED='已按 --skip-shell 跳过'
    M_SHELL_STOCK_WARN='已装 com.anland.shell，但 Droidspaces ≥7.2.0 需要补丁版（否则容器永远显示 stopped）'
    M_SHELL_STOCK_HINT='如果容器列表正常就不用管；不正常的话用 --apk-dir 指定补丁版重装：'
    M_SHELL_STOCK_CMD='  bash setup-anland6-host.sh --apk-dir <含 anland-shell.apk 的目录>'
    M_SHELL_OK='com.anland.shell 已安装'
    M_DL_SHELL='下载补丁版 anland-shell…'
    M_GET_SHELL_FAIL='拿不到 anland-shell.apk —— 装官方的也行，但 Droidspaces ≥7.2.0 上容器列表会失效'
    M_SHELL_UID='anland-shell 的 uid=%s —— 必须在 root 管理器里给它 root 权限，'
    M_SHELL_UID2='否则它读不到 %s（表现是「no containers defined」）'
    M_CFG_UPDATED='已更新 config.json（auto_attach=1, scale_mode=1），备份在 config.json.bak'
    M_CFG_WRITTEN='已写入默认 config.json'
    M_CFG_SKIP='[跳过] 模块不在位或 dry-run'
    M_NO_CONTAINERS='没有容器目录 %s，先建一个容器'
    M_BIND_PRESENT='[%s] 已有 /run/anland 绑定'
    M_BIND_RUNNING='[%s] 正在运行，跳过（先 stop 再跑本脚本，或用 -B 重启）'
    M_BIND_DRYRUN='[dry-run] 会给 [%s] 加 bind_mounts=%s:/run/anland'
    M_BIND_ADDED='[%s] 已加 bind_mounts=%s:/run/anland'
    M_DAEMON_UP='waylandbridge 在跑（pid %s）'
    M_DAEMON_DOWN='waylandbridge 没跑 —— 模块刚装的话需要重启'
    M_STEP='%s  %s'
    M_ST1='环境检查'
    M_ST2='anland-awl 模块'
    M_ST3='宿主 APK'
    M_ST4='守护进程配置'
    M_ST5='给容器补绑定挂载'
    M_ST6='当前状态'


    M_V_MODULE_DISABLED='anland-awl 模块被禁用（有 disable/skip_mount 标记）'
    M_V_MODULE_DISABLED_FIX='删掉标记后重启：rm -f %s/disable %s/skip_mount'
    M_V_MODULE_PENDING='模块在 modules_update 里 —— 刷过但没重启'
    M_V_MODULE_PENDING_FIX='重启即可：su -c reboot'
    M_V_MODULE_MISSING='anland-awl 模块没装'
    M_V_MODULE_MISSING_FIX='跑 setup-anland6-host.sh，或用 KernelSU 刷 anland-awl.zip'
    M_V_DAEMON_DOWN='waylandbridge 没跑'
    M_V_DAEMON_DOWN_FIX="手动拉起：su -c 'sh %s/service.sh'"
    M_V_DAEMON_BOOT_FIX='如果手动能起、开机不起，看 /data/local/tmp/awl_daemon.log'
    M_V_SOCKET_MISSING='socket 不存在：%s'
    M_V_SOCKET_MISSING_FIX='daemon 起来后会自动建；没建说明 daemon 启动失败'
    M_V_BINDER_MISSING='binder 服务 anland.host 未注册'
    M_V_BINDER_MISSING_FIX='宿主 APK(com.anlandnext) 靠它找 daemon'
    M_V_NEXT_NOT_RUNNING='com.anlandnext 没在运行 —— 打开它的窗口列表能看到已连接的窗口'
    M_V_NEXT_MISSING='com.anlandnext 没装（没有它就没有 Android 窗口）'
    M_V_OLD_COMPONENTS='检测到 5.x 组件（anland-daemon / com.anland.consumer），和 6.x 路由冲突，建议移除'
    M_V_NO_CFG='没有 config.json，daemon 用源码默认值（auto_attach=1, scale_mode=0）'
    M_V_NO_CONTAINERS='没有容器目录 %s'
    M_V_CTR_NOT_RUNNING='未运行'
    M_V_BIND_MISSING='container.config 里没有 /run/anland 绑定'
    M_V_BIND_MISSING_FIX='重跑 setup-anland6-host.sh，或用 -B %s:/run/anland 启动'
    M_V_SOCKET_NOT_IN_CTR='容器内看不到 /run/anland/wayland-0'
    M_V_SESSION_MISSING='容器内没有 anlandx 会话（anland-session）'
    M_V_SESSION_MISSING_FIX='检查会话：droidspaces --name=%s run -- systemctl status desktop-session'
    M_V_WINDOW_MISSING='还没有 AwlWindowActivity 窗口'
    M_V_WINDOW_MISSING_FIX='通过 anland-shell 启动一个应用，再跑一次本脚本'
    M_V_BREAKPOINTS='  常见断点对照：'
    M_V_BP_SOCKET='    · socket 不存在      → daemon 没起：sh %s/service.sh，或重启'
    M_V_BP_BIND='    · 容器内看不到 socket → 缺 -B 绑定：重跑 setup-anland6-host.sh'
    M_V_BP_SESSION='    · anland-session 没跑 → desktop-session 失败：'
    M_V_BP_SESSION_CMD='        droidspaces --name=<名字> run -- systemctl status desktop-session'
    M_V_BP_STOPPED='    · 容器显示 stopped 却实际在跑 → anland-shell 版本不兼容 Droidspaces ≥7.2.0'
    M_V_BP_STOPPED_FIX='        （用 setup 脚本装的补丁版可解）'
    M_V_AFTER_LAUNCH='  应用启动后如果窗口没出现，看 daemon 日志：'
    M_V_KEY_LINES="  关键行是 'surface N mapped'（客户端提交了首帧）和"
    M_V_KEY_LINES2="  'window WxH attached'（Android 窗口已附着）。只看到 'surface N created'"
    M_V_KEY_LINES3='  而没有 mapped，说明客户端没有提交缓冲区。'

    M_V_LAYER_HOST='第一层：宿主'
    M_V_LAYER_CTR='第二层：容器'
    M_V_LAYER_DISP='第三层：显示'
    M_V_CTR_HEAD='  --- 容器：%s ---'
    M_V_MODULE_OK='anland-awl 模块已启用'
    M_V_DAEMON_UP='waylandbridge 在跑（pid %s）'
    M_V_SOCKET_OK='socket 存在：%s'
    M_V_BINDER_OK='binder 服务 anland.host 已注册'
    M_V_NEXT_INSTALLED='com.anlandnext 已安装（窗口消费者）'
    M_V_NEXT_RUNNING='com.anlandnext 在运行'
    M_V_CTR_RUNNING='在运行（pid %s）'
    M_V_BIND_OK='container.config 里有 /run/anland 绑定'
    M_V_SOCKET_IN_CTR='容器内能看到 /run/anland/wayland-0'
    M_V_SESSION_OK='容器内有 anlandx 会话（anland-session）'
    M_V_WINDOW_OK='已有 AwlWindowActivity 窗口'
    M_V_CHAIN_OK='链路完整。打开 anland-shell → 选容器 → APPS → 点一个应用即可。'
    ;;

ja)
    M_NEED_PATCH='Droidspaces %s 以降: 公式 anland-shell 1.1 のコンテナ一覧が壊れます。パッチ版が必要です'
    M_OLD_DAEMON='5.x の anland-daemon モジュールを検出しました。6.x のルーティングと競合します'
    M_MODULE_OK='モジュールは導入済みで完全です（%s）'
    M_MODULE_PENDING='モジュールは modules_update にあります —— 書き込み済みですが未再起動です。再起動後に有効になります'
    M_KSUS_OK='ksud で導入しました。再起動後に有効になります'
    M_MANUAL_OK='手動で %s に展開しました（再起動後に有効になります）'
    M_NEXT_OK='com.anlandnext 導入済み（ウィンドウコンシューマ）'
    M_SHELL_OK='com.anland.shell 導入済み'
    M_CFG_UPDATED='config.json を更新しました（auto_attach=1, scale_mode=1）。バックアップは config.json.bak'
    M_BIND_PRESENT='[%s] は既に /run/anland バインドがあります'
    M_BIND_ADDED='[%s] に bind_mounts=%s:/run/anland を追加しました'
    M_DAEMON_UP='waylandbridge は動作中です（pid %s）'
    M_DAEMON_DOWN='waylandbridge が動作していません —— モジュールを入れた直後なら再起動が必要です'

    M_V_LAYER_HOST='第 1 層: ホスト'
    M_V_LAYER_CTR='第 2 層: コンテナ'
    M_V_LAYER_DISP='第 3 層: 表示'
    M_V_CTR_HEAD='  --- コンテナ: %s ---'
    M_V_MODULE_OK='anland-awl モジュールは有効です'
    M_V_DAEMON_UP='waylandbridge は動作中です（pid %s）'
    M_V_SOCKET_OK='ソケットが存在します: %s'
    M_V_BINDER_OK='binder サービス anland.host は登録済みです'
    M_V_NEXT_INSTALLED='com.anlandnext 導入済み（ウィンドウコンシューマ）'
    M_V_CTR_RUNNING='動作中（pid %s）'
    M_V_CHAIN_OK='経路は完全です。anland-shell を開く → コンテナを選ぶ → APPS → アプリをタップ。'
    ;;
esac