#!/bin/sh
# install-panvk.sh —— 把 Mesa PanVK (mali-panvk) 装进镜像，给 MTK Mali 提供 Vulkan
#
# 为什么是它：
#   libhybris 那条路（setup-mali-hybris.sh）只给了 EGL/GLES——厂商 blob 没有
#   可用的桌面 Vulkan，DXVK（Wine 游戏的 D3D9/10/11 路径）用不上，Steam 游戏性
#   能封死在 WineD3D。mali-panvk 是 Mesa PanVK 对手机自带 kbase（/dev/mali0）
#   的移植：Vulkan 1.4、DXVK 需要的 VK_EXT_robustness2（null descriptor）、
#   vkd3d-proton 的 D3D12、Zink 的 GL，官方实测设备含 Tab S10+（Immortalis-G720，
#   天玑 9300+）与 Tab S11（G925）。MIT 开源，遇 bug 可自修。
#
#   驱动是 NDK/bionic 构建（liblog/libnativewindow/libhardware/libsync），glibc
#   的 Vulkan loader 直接 dlopen 会失败——加载走 libhybris：hybris 的 libvulkan
#   经 android_dlopen 打开 LIBVULKAN 环境变量指定的库（默认 "libvulkan.so"，
#   即厂商 blob loader）。本脚本把 LIBVULKAN 指到 panvk，configure-gpu.sh 的
#   mediatek 分支负责写这个环境变量；Wayland 上屏由 hybris 的
#   vulkanplatform_wayland 把 VK_KHR_wayland_surface 转成 vkCreateAndroidSurfaceKHR，
#   缓冲经 zwp_linux_dmabuf_v1 交给 anland 6.x 的 waylandbridge。
#
#   内核前提与 GLES 路线完全相同：/dev/mali0 + mali_nsfix.ko（droidspaces-lkm）。
#   （上游 README 的 "免 root" 只对启动器架构成立——那是普通 Android 应用进程，
#   没有 PID namespace；放进容器同样需要 mali_nsfix。）
#
# 版本与来源（可用环境变量覆盖）：
#   PANVK_VERSION=v1.6.0        GitHub release tag
#   PANVK_ZIP=mali-panvk-27.0.0-devel-r10.zip   该 tag 的附件名
#   PANVK_BASE_URL=https://github.com/JimVulkan/mali-panvk/releases/download
#
# 运行方式：
#   构建期（Dockerfile 调用，环境变量 DSHY_BUILD=1，x86 构建机）：
#     下载 zip、解出 libvulkan_panfrost.so 落盘，不做任何设备探测。
#   容器内（/usr/local/sbin/install-panvk）：
#     同上；已存在时跳过（幂等）。

set -eu

PANVK_VERSION="${PANVK_VERSION:-v1.6.0}"
PANVK_ZIP="${PANVK_ZIP:-mali-panvk-27.0.0-devel-r10.zip}"
PANVK_BASE_URL="${PANVK_BASE_URL:-https://github.com/JimVulkan/mali-panvk/releases/download}"

DEST_DIR="/usr/local/lib/vulkan/panvk"
SHARE_DIR="/usr/local/share/panvk"

say()  { echo "==> $*"; }
ok()   { echo "  [OK] $*"; }
warn() { echo "  [!!] $*"; }

# 解 zip 要 unzip（构建期基础包里普遍没有），缺了按发行版自装。
ensure_unzip() {
    command -v unzip >/dev/null 2>&1 && return 0
    say "安装 unzip"
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unzip >/dev/null 2>&1 \
            || apt-get update -qq >/dev/null 2>&1 \
            && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unzip >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q unzip >/dev/null 2>&1
    elif command -v pacman >/dev/null 2>&1; then
        pacman -S --noconfirm --needed unzip >/dev/null 2>&1
    fi
    command -v unzip >/dev/null 2>&1 || warn "unzip 不可用，将尝试 python3"
}

# 已装则幂等跳过（版本升级时删 $DEST_DIR 重跑）
if [ -f "$DEST_DIR/libvulkan_panfrost.so" ]; then
    ok "panvk 已就绪: $DEST_DIR/libvulkan_panfrost.so"
    exit 0
fi

ensure_unzip

say "安装 Mesa PanVK ($PANVK_VERSION)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

URL="$PANVK_BASE_URL/$PANVK_VERSION/$PANVK_ZIP"
say "下载 $URL"
attempt=1
while [ "$attempt" -le 3 ]; do
    if curl -fsSL --connect-timeout 30 --max-time 600 \
            --speed-limit 1024 --speed-time 60 -o "$TMP/panvk.zip" "$URL"; then
        break
    fi
    warn "下载中断 (attempt ${attempt}/3)，重试: $PANVK_ZIP"
    attempt=$(( attempt + 1 ))
done
[ -f "$TMP/panvk.zip" ] || { echo "panvk 下载失败: $URL" >&2; exit 1; }

unzip -o -q "$TMP/panvk.zip" -d "$TMP/panvk" 2>/dev/null \
    || python3 -c "import zipfile,sys; zipfile.ZipFile('$TMP/panvk.zip').extractall('$TMP/panvk')"

SO="$TMP/panvk/libvulkan_panfrost.so"
[ -f "$SO" ] || { echo "zip 内无 libvulkan_panfrost.so" >&2; exit 1; }

install -D -m 0644 "$SO" "$DEST_DIR/libvulkan_panfrost.so"
[ -f "$TMP/panvk/NOTICE.txt" ] \
    && install -D -m 0644 "$TMP/panvk/NOTICE.txt" "$DEST_DIR/NOTICE.txt" || true

# 探测标记：configure-gpu.sh mediatek 分支看到它才写 LIBVULKAN，
# 没装时维持默认（厂商 blob 的 Android Vulkan loader）。
mkdir -p "$SHARE_DIR"
printf 'PANVK_VERSION=%s\nLIBVULKAN=%s/libvulkan_panfrost.so\n' \
    "$PANVK_VERSION" "$DEST_DIR" > "$SHARE_DIR/panvk.env"

ok "$DEST_DIR/libvulkan_panfrost.so"
ok "$SHARE_DIR/panvk.env"
echo "==> 完成。运行期由 configure-gpu mediatek 分支接管 LIBVULKAN。"
