#!/usr/bin/env bash
# build-panvk-glibc.sh —— 在 aarch64 Linux(glibc)上从源码构建 Mesa PanVK on kbase
#
# 为什么不用官方 zip：
#   mali-panvk 的 release 是 NDK/bionic 库。放进 glibc 主机（hybris 加载或
#   直接 dlopen）时，其静态 jemalloc 在 vkCreateInstance 处触发
#   "Error setting TSD" 并 abort —— bionic 的 TLS 假设在 glibc 进程里不成立
#   （Qualcomm 之外的 MTK 容器实测，2026-11-25）。
#   驱动本体（kbase_kmod.c）只用 ioctl/mmap，平台无关：glibc 原生构建即可。
#   实测 Immortalis-G720（mt6989）/dev/mali0：标准 Khronos loader + 本脚本
#   产物 → x86_64 wine/box64 全链 P1..P7 GPU 提交 OK。
#
# 用法（容器内 root，或任何 aarch64 glibc）：
#   scripts/tui/build-panvk-glibc.sh [源树目录，默认 /opt/mali-panvk-src]
# 环境变量：
#   PANVK_REF  源分支/tag（默认 main）
#   PANVK_ZIP  源码 zip 本地路径（默认从 GitHub codeload 下载）
#   产物：/opt/panvk/libvulkan_panfrost_g.so + /etc/vulkan/icd.d/panvk_g.json
set -euo pipefail

REF="${PANVK_REF:-main}"
SRC="${1:-/opt/mali-panvk-src}"
OUT=/opt/panvk
SO="$OUT/libvulkan_panfrost_g.so"

apt_get() { DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null 2>&1 || true; }

# --- 依赖（Ubuntu 24.04+/Debian 13 包名） -------------------------------------------------
apt-get update -qq >/dev/null 2>&1 || true
apt_get meson ninja-build pkg-config python3-mako python3-yaml python3-packaging \
  libdrm-dev libexpat1-dev libelf-dev libzstd-dev flex bison \
  glslang-tools libspirv-tools-dev spirv-tools-dev spirv-tools \
  libllvmspirvlib-dev llvm-dev libclang-dev clang
# libllvmspirvlib-dev 在部分发行版带版本号
if ! pkg-config --exists LLVMSPIRVLib 2>/dev/null; then
  apt_get "libllvmspirvlib-$(llvm-config --version 2>/dev/null | cut -d. -f1)-dev" || true
fi

# --- 源码 --------------------------------------------------------------------------------
if [ ! -f "$SRC/meson.build" ]; then
  ZIP="${PANVK_ZIP:-/tmp/mali-panvk.zip}"
  if [ ! -f "$ZIP" ]; then
    curl -fsSL --retry 3 -o "$ZIP" "https://codeload.github.com/JimVulkan/mali-panvk/zip/refs/heads/$REF"
  fi
  rm -rf /tmp/panvk-unpack && mkdir -p /tmp/panvk-unpack
  unzip -q "$ZIP" -d /tmp/panvk-unpack
  mv "/tmp/panvk-unpack/mali-panvk-$REF" "$SRC"
fi
cd "$SRC"

# --- stage 1：原生构建 mesa_clc / vtn_bindgen2 / panfrost_compile --------------------------
# （官方只给 NDK 交叉流程；本平台 host==target，直接产出本机工具）
if [ ! -x build-host/bin/mesa_clc ]; then
  rm -rf build-host
  meson setup build-host \
    -Dbuildtype=debugoptimized \
    -Dmesa-clc=enabled -Dprecomp-compiler=enabled \
    -Dvulkan-drivers=panfrost -Dgallium-drivers= -Dplatforms= -Dllvm=enabled \
    -Dgles1=disabled -Dgles2=disabled -Degl=disabled -Dglx=disabled -Dgbm=disabled \
    -Dtools= -Dvideo-codecs= \
    -Dallow-fallback-for=libdrm --force-fallback-for=libdrm,expat,zlib \
    -Dlibdrm:default_library=static
  ninja -C build-host \
    src/compiler/clc/mesa_clc src/compiler/spirv/vtn_bindgen2 src/panfrost/clc/panfrost_compile
  mkdir -p build-host/bin
  cp build-host/src/compiler/clc/mesa_clc \
     build-host/src/compiler/spirv/vtn_bindgen2 \
     build-host/src/panfrost/clc/panfrost_compile build-host/bin/
fi

# --- stage 2：glibc 驱动本体（platforms 为空，绕开 NDK 才需要的 loader/android 路径） ----------
if [ ! -f build-native/build.ninja ]; then
  meson setup build-native \
    -Dbuildtype=release -Db_ndebug=true \
    -Dplatforms= -Dvulkan-drivers=panfrost -Dgallium-drivers= -Dvulkan-layers= \
    -Dtools= -Dvideo-codecs= \
    -Dmesa-clc=system -Dprecomp-compiler=system \
    -Dllvm=disabled -Dzstd=disabled -Dlmsensors=disabled -Dperfetto=false \
    -Dglx=disabled -Dgbm=disabled -Degl=disabled -Dgles1=disabled -Dgles2=disabled
fi
ninja -C build-native src/panfrost/vulkan/libvulkan_panfrost.so

# --- 部署 + 系统 ICD 注册 -------------------------------------------------------------------
mkdir -p "$OUT" /etc/vulkan/icd.d
cp -f build-native/src/panfrost/vulkan/libvulkan_panfrost.so "$SO"
cat > /etc/vulkan/icd.d/panvk_g.json <<JSON
{
  "file_format_version": "1.0.1",
  "ICD": {
    "library_path": "$SO",
    "api_version": "1.4"
  }
}
JSON
# 镜像里可能自带指向 NDK 构建的旧 json（bionic 库在 glibc 进程里会崩）
[ -e /usr/share/vulkan/icd.d/panvk.json ] && mv /usr/share/vulkan/icd.d/panvk.json /usr/share/vulkan/icd.d/panvk.json.off
[ -e /etc/vulkan/icd.d/panvk.json ]      && mv /etc/vulkan/icd.d/panvk.json /etc/vulkan/icd.d/panvk.json.off

# 镜像自带 /opt/hy/inst/lib/libvulkan.so.1（hybris loader）。/etc/environment
# 的 LD_LIBRARY_PATH 让它抢在系统 loader 前，把 ICD dlopen 拐进 bionic
# linker（"namespace (default)" 报错）。glibc 路线以系统 loader 为正门，
# 把它改名封存（patched hybris loader 随时 .hybris-off→还原可用）。
if [ -d /opt/hy/inst/lib ]; then
  for f in /opt/hy/inst/lib/libvulkan.so.1*; do
    [ -e "$f" ] && mv -f "$f" "$f.hybris-off" 2>/dev/null || true
  done
fi

# 环境变量里残留的 HYBRIS_*（/etc/environment）会污染 glibc loader 的 dlopen：
# 出现 namespace "(default)" 报错即此因，客户端用 env -i 或清理 /etc/environment。
echo "== done: $SO =="
VK_ICD_FILENAMES=/etc/vulkan/icd.d/panvk_g.json command -v vulkaninfo >/dev/null \
  && env -i PATH=/usr/bin:/bin VK_ICD_FILENAMES=/etc/vulkan/icd.d/panvk_g.json vulkaninfo --summary | grep -m2 -E "deviceName|apiVersion" \
  || echo "(install vulkan-tools to verify: apt-get install -y vulkan-tools)"
