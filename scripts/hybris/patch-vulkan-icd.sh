#!/bin/sh
# patch-vulkan-icd.sh —— 给 libhybris 的 vulkan/vulkan.c 换上报验证过的
# ICD/glibc 后端版本（vulkan-icd-glibc.c，同目录资产）
#
# 原版 vulkan.c 的三个死穴（2026-11-25 MTK mt6989 容器实测）：
#   1. vkGetInstanceProcAddr 解引用只在 vkCreateInstance 里初始化的指针——
#      loader 的第一步（EnumerateInstanceLayerProperties）就跳 NULL 段错误。
#   2. VULKAN_IDLOAD 生成的 ifunc 分发只查 android_dlsym(handle, 同名符号)，
#      对只导出 vk_icd* 的裸 ICD（mali-panvk）全部解析成 NULL → 跳 0。
#   3. LIBVULKAN 只能指向 bionic 库（android_dlopen）。NDK 版 panvk 在
#      glibc 进程里 jemalloc "Error setting TSD" abort；而 glibc 原生构建的
#      panvk 需要普通 dlopen——"glibc:" 前缀走这条路。
#
# 补丁后的行为：
#   - _init_androidvulkan: "glibc:" 前缀 → glibc dlopen(RTLD_NOW|RTLD_GLOBAL)，
#     否则 android_dlopen；两者都在找不到 vkGetInstanceProcAddr 时
#     negotiate vk_icdNegotiateLoaderICDInterfaceVersion 并采纳
#     vk_icdGetInstanceProcAddr 做全符号解析（IDLOAD 与 setup_gipa 同路径）。
#   - vkCreateInstance/vkGetInstanceProcAddr/vkEnumerateInstanceExtension 经
#     hybris_setup_gipa() 统一解析，失败返回 VK_ERROR_INITIALIZATION_FAILED
#     而不是崩。
#   - gdpa/dmabuf/swapchain hook 全部加 NULL 守护。
#
# 幂等：目标文件已含 _icd_gipa 标记时直接退出 0。

set -eu

HY=${HY:-/opt/hy}
SRC="$HY/dhy/hybris/vulkan"
TARGET="$SRC/vulkan.c"

[ -f "$TARGET" ] || { echo "patch-vulkan-icd: 找不到 $TARGET（先 clone libhybris）" >&2; exit 1; }
grep -q "_icd_gipa" "$TARGET" && { echo "patch-vulkan-icd: 已打过，跳过"; exit 0; }

# 资产查找：镜像内 /usr/local/share/mali-hybris → 脚本所在目录 → 当前目录
self=$(readlink -f "$0" 2>/dev/null || echo "$0")
for d in /usr/local/share/mali-hybris "$(dirname "$self")" .; do
    if [ -f "$d/vulkan-icd-glibc.c" ]; then ASSETS=$d; break; fi
done
[ -n "${ASSETS:-}" ] || { echo "patch-vulkan-icd: 缺 vulkan-icd-glibc.c 资产" >&2; exit 1; }

cp -f "$ASSETS/vulkan-icd-glibc.c" "$TARGET"
echo "patch-vulkan-icd: $TARGET 已替换（ICD fallback + glibc 后端）"

# 顺带产出 ndk_shim 路径供 CFLAGS 使用：若调用方导出 SHIM_INC 则填好
if [ -f "$ASSETS/ndk_shim.h" ]; then
    echo "patch-vulkan-icd: shim 头就位 $ASSETS/ndk_shim.h"
fi
