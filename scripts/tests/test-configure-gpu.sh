#!/usr/bin/env bash
# =============================================================================
# test-configure-gpu.sh — configure-gpu.sh 的组合矩阵回归测试
# =============================================================================
#
#   bash scripts/tests/test-configure-gpu.sh
#
# 为什么要这个测试：configure-gpu.sh 在 Dockerfile 里被调用时，参数曾经因为
# 续行符丢失而全部走默认值（ENABLE_MESA 永远 false），导致 MTK 的软件渲染变量
# 从未写入、高通 X11 路径的 kgsl/TU_DEBUG 也从未写入，而构建一直是绿的。
# 纯 shell 的参数传递错误编译期查不出来，只能靠断言 /etc/environment 的最终内容。
#
# 测试方式：为每个组合建立假 ROOTFS_DIR，拦截包管理器（apt-get/dnf/pacman），
# 跑 configure-gpu.sh，断言写入的环境变量集合完全匹配。
# =============================================================================

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/tui/configure-gpu.sh"
WORK="$(mktemp -d)"
FAKEBIN="$WORK/bin"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

mkdir -p "$FAKEBIN"
for pm in apt-get dnf pacman; do
    printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/$pm"
    chmod +x "$FAKEBIN/$pm"
done

PASS=0
FAIL=0

# run_case <说明> <distro> <version> <vendor> <backend> <mesa> <期望的环境行，换行分隔>
run_case() {
    local desc="$1" distro="$2" ver="$3" vendor="$4" backend="$5" mesa="$6"
    local want="$7"

    local rootfs="$WORK/rootfs"
    rm -rf "$rootfs"; mkdir -p "$rootfs/etc"
    if [ -n "$ver" ]; then
        printf 'ID=%s\nVERSION_ID="%s"\n' "$distro" "$ver" > "$rootfs/etc/os-release"
    else
        printf 'ID=%s\n' "$distro" > "$rootfs/etc/os-release"
    fi
    : > "$rootfs/etc/environment"

    ROOTFS_DIR="$rootfs" PATH="$FAKEBIN:$PATH" \
        bash "$SCRIPT" "$vendor" "$backend" "$mesa" > "$WORK/out.log" 2>&1
    local rc=$?

    if [ "$rc" -ne 0 ]; then
        printf '  ✗ %s\n    configure-gpu 退出码 %s\n' "$desc" "$rc"
        sed 's/^/      /' "$WORK/out.log" | head -5
        FAIL=$((FAIL+1))
        return
    fi

    # 实际写入的赋值行（排序后比较）
    local got
    got=$(grep -E '^[A-Z_]+=' "$rootfs/etc/environment" 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//')
    local expected
    expected=$(printf '%s\n' "$want" | grep -E '^[A-Z_]+=' | sort | tr '\n' ' ' | sed 's/ $//')

    if [ "$got" = "$expected" ]; then
        printf '  ✓ %s\n      %s\n' "$desc" "${got:-（空）}"
        PASS=$((PASS+1))
    else
        printf '  ✗ %s\n      期望: %s\n      实际: %s\n' "$desc" "${expected:-（空）}" "${got:-（空）}"
        FAIL=$((FAIL+1))
    fi
}

echo "== MTK：必须剥掉 kgsl，且带 swrast 加载器覆盖 =="
run_case "mediatek + Debian13 + wayland + mesa" debian 13 mediatek anland-wayland true \
'MESA_LOADER_DRIVER_OVERRIDE=swrast
LIBGL_ALWAYS_SOFTWARE=1
GALLIUM_DRIVER=llvmpipe'

run_case "mediatek + Fedora43 + wayland + mesa" fedora 43 mediatek anland-wayland true \
'MESA_LOADER_DRIVER_OVERRIDE=swrast
LIBGL_ALWAYS_SOFTWARE=1
GALLIUM_DRIVER=llvmpipe'


echo
echo "== 高通 Wayland：kgsl 三件套 =="
run_case "qualcomm + Debian13 + wayland" debian 13 qualcomm anland-wayland true \
'MESA_LOADER_DRIVER_OVERRIDE=kgsl
GALLIUM_DRIVER=kgsl
FD_FORCE_KGSL=1'

run_case "qualcomm + Ubuntu26 + wayland" ubuntu 26.04 qualcomm anland-wayland true \
'MESA_LOADER_DRIVER_OVERRIDE=kgsl
GALLIUM_DRIVER=kgsl
FD_FORCE_KGSL=1'

echo
echo "== 高通 X11：kgsl + TU_DEBUG（这条以前完全没写）=="
run_case "qualcomm + Debian13 + X11" debian 13 qualcomm x11 true \
'MESA_LOADER_DRIVER_OVERRIDE=kgsl
TU_DEBUG=noconform'

run_case "qualcomm + Ubuntu26 + X11" ubuntu 26.04 qualcomm x11 true \
'MESA_LOADER_DRIVER_OVERRIDE=kgsl
TU_DEBUG=noconform'

run_case "qualcomm + Fedora43 + X11" fedora 43 qualcomm x11 true \
'MESA_LOADER_DRIVER_OVERRIDE=kgsl
TU_DEBUG=noconform'

echo
echo "== 高通 Ubuntu 24/25：单块配置，不区分后端（以前完全没有）=="
run_case "qualcomm + Ubuntu24 + wayland" ubuntu 24.04 qualcomm anland-wayland true \
'MESA_LOADER_DRIVER_OVERRIDE=kgsl
TU_DEBUG=noconform'

run_case "qualcomm + Ubuntu24 + X11" ubuntu 24.04 qualcomm x11 true \
'MESA_LOADER_DRIVER_OVERRIDE=kgsl
TU_DEBUG=noconform'

run_case "qualcomm + Ubuntu25 + wayland" ubuntu 25.10 qualcomm anland-wayland true \
'MESA_LOADER_DRIVER_OVERRIDE=kgsl
TU_DEBUG=noconform'

echo
echo "== 未开启 Mesa：不应写入任何 GPU 变量 =="
run_case "qualcomm + Debian13 + wayland + 无 mesa" debian 13 qualcomm anland-wayland false ''
run_case "mediatek + Debian13 + wayland + 无 mesa" debian 13 mediatek anland-wayland false ''

echo
echo "----------------------------------------"
printf " 通过 %d / 失败 %d\n" "$PASS" "$FAIL"
echo "----------------------------------------"
[ "$FAIL" -eq 0 ]