#!/usr/bin/env bash
# install-steam.sh — Install Valve ARM64 Steam client + FEX into a Droidspaces rootfs.
#
# Based on:
#   - fetch-steam-arm64.sh (Hi5808/steamos-mainline)  — Valve manifest assembly
#   - UbuntuAsahi/steam-arm64.sh                       — client install recipe
#   - Armbian steam module docs                         — FEX + Proton layout
#
# Usage:
#   install-steam.sh [--prefix ROOTFS_DIR] [--channel stable|publicbeta] [--fex-rootfs-url URL]
#
# Env vars (overridable):
#   ROOTFS_DIR           Prefix for all file writes (default: empty = host system)
#   STEAM_CHANNEL        stable | publicbeta (default: publicbeta)
#   FEX_ROOTFS_URL       URL to FEX Arch rootfs tarball (default: latest GitHub release)
#   STEAM_USER           User that owns Steam files (default: auto-detected)
#
# Notes:
#   - The client is started through /usr/local/bin/steam-anland instead of the
#     client binary, because two environment fixes are required on hardware: one
#     process-wide libpng (steamui.so exports its own png_* symbols while libSDL3
#     carries a hidden copy, and lazy binding across the two kills the client at
#     startup) and a GL fallback to llvmpipe when no KMS node is present.
#   - Do not pass -gamepadui. This ARM64 channel ships the desktop UI only: the
#     update manifest carries tenfoot_images_all (images, no web assets) and no
#     deckui package, so the flag loads an empty data:text/html page.

set -euo pipefail

readonly BASE_URL="https://client-update.fastly.steamstatic.com"
readonly DEPOT_URL="https://client-update.steamstatic.com"

# ---------- argument parsing ----------
ROOTFS_DIR="${ROOTFS_DIR:-}"
STEAM_CHANNEL="${STEAM_CHANNEL:-publicbeta}"
# The rootfs ships a single non-root account; the anland 6.x images call it
# "Gold" (uid 1000), but the upstream recipe assumed "user".  Resolve the
# real account so the desktop entry and the app menu land in the home
# directory the session actually uses.
if [[ -z "${STEAM_USER:-}" ]]; then
    if [[ -n "${SUDO_USER:-}" ]] && [[ -d "/home/${SUDO_USER}" ]]; then
        STEAM_USER="$SUDO_USER"
    elif id -u 1000 >/dev/null 2>&1 && getent passwd 1000 >/dev/null 2>&1; then
        STEAM_USER="$(getent passwd 1000 | cut -d: -f1)"
    else
        STEAM_USER="user"
    fi
fi
FEX_ROOTFS_URL="${FEX_ROOTFS_URL:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix)       ROOTFS_DIR="${2:-}"; shift 2 ;;
        --channel)      STEAM_CHANNEL="${2:-}"; shift 2 ;;
        --fex-rootfs-url) FEX_ROOTFS_URL="${2:-}"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

case "$STEAM_CHANNEL" in
    stable|publicbeta) ;;
    *) echo "STEAM_CHANNEL must be stable or publicbeta, got: $STEAM_CHANNEL" >&2; exit 2 ;;
esac

# ---------- paths resolved ----------
STEAM_ROOT="${ROOTFS_DIR:-}/home/${STEAM_USER}/.local/share/Steam"
STEAMRT_DIR="${STEAM_ROOT}/steamrtarm64"
STEAM_ROOT_DIR="${STEAM_ROOT}/linuxarm64"
FEX_DIR="${ROOTFS_DIR:-}/home/${STEAM_USER}/.local/share/fex-emu/RootFS/ArchLinux"
GUESTOS_DIR="${ROOTFS_DIR:-}/usr/share/guestos/fex-mesa"
DOT_STEAM_DIR="${ROOTFS_DIR:-}/home/${STEAM_USER}/.steam"
ICONS_DIR="${ROOTFS_DIR:-}/usr/local/share/icons/hicolor/scalable/apps"
DESKTOP_FILE="${ROOTFS_DIR:-}/home/${STEAM_USER}/.local/share/applications/steam.desktop"
BIN_DIR="${ROOTFS_DIR:-}/usr/local/bin"
STEAM_LAUNCHER="${BIN_DIR}/steam-anland"
STEAM_SETTINGS_HELPER="${BIN_DIR}/steam-open-settings"
# Path as the client sees it from inside the container: the launcher is written
# into the image, where ROOTFS_DIR is not part of the path.
STEAM_ROOT_RUNTIME="/home/${STEAM_USER}/.local/share/Steam"
TMP_CREATED=0
if [[ -n "${INSTALL_TMP_DIR:-}" ]]; then
    # Reuse a caller-provided directory so an aborted run keeps its partial
    # depot files; the client download is large enough that a full restart
    # from zero is not acceptable.
    TMP_DIR="$INSTALL_TMP_DIR"
    mkdir -p "$TMP_DIR"
else
    TMP_DIR="$(mktemp -d)"
    TMP_CREATED=1
fi
trap '[[ "$TMP_CREATED" -eq 1 ]] && rm -rf "$TMP_DIR"' EXIT

# ---------- helpers ----------
log() { printf '[install-steam] %s\n' "$*"; }
die() { printf '[install-steam] ERROR: %s\n' "$*" >&2; exit 1; }

download() {
    # Fetch one depot file.  The Valve CDN throttles and drops single-stream
    # transfers on many mobile links while parallel byte ranges still sum up,
    # so aria2c is preferred and a resuming curl is the fallback.
    local url="$1" output="$2" attempt=1 max_attempts="${DOWNLOAD_MAX_ATTEMPTS:-12}"
    local dir base
    dir="$(dirname "$output")"
    base="$(basename "$output")"
    while [ "$attempt" -le "$max_attempts" ]; do
        if command -v aria2c >/dev/null 2>&1; then
            if aria2c -x16 -s16 -k1M --min-split-size=1M \
                    --file-allocation=none --allow-overwrite=true \
                    --auto-file-renaming=false --continue=true \
                    --console-log-level=error --summary-interval=0 \
                    -d "$dir" -o "$base" "$url"; then
                return 0
            fi
        elif curl -fsSL -4 --connect-timeout 30 --max-time 900 \
                --speed-limit 1024 --speed-time 60 \
                -C - -o "$output" "$url"; then
            return 0
        fi
        log "    download interrupted (attempt ${attempt}/${max_attempts}), resuming: $base"
        sleep $(( attempt < 4 ? attempt * 3 : 10 ))
        attempt=$(( attempt + 1 ))
    done
    return 1
}

# ---------- 1. Download Valve ARM64 manifest + assemble client ----------
log "==> Step 1: Fetching Valve ${STEAM_CHANNEL} linuxarm64 manifest"

case "$STEAM_CHANNEL" in
    stable)    MANIFEST_NAME="steam_client_linuxarm64" ;;
    publicbeta) MANIFEST_NAME="steam_client_publicbeta_linuxarm64" ;;
esac

download "${BASE_URL}/${MANIFEST_NAME}" "$TMP_DIR/manifest.vdf"
VER="$(awk -F'"' '/"version"/{print $4; exit}' "$TMP_DIR/manifest.vdf")"
log "    client version: ${VER:-unknown}"

# Extract component files + SHAs (filter *_linuxarm64_linuxarm64 + *_all)
awk '
    /^\t"[a-z0-9_]+"$/ { name=$1; gsub(/"/,"",name) }
    /"file"/ { gsub(/"/,""); file=$2 }
    /"sha2"/ { gsub(/"/,""); sha=$2;
        if (name ~ /(_all|_linuxarm64_linuxarm64)$/) print file, sha
    }
' "$TMP_DIR/manifest.vdf" > "$TMP_DIR/comps.txt"

COMP_COUNT="$(wc -l < "$TMP_DIR/comps.txt" | tr -d ' ')"
log "    components to fetch: ${COMP_COUNT}"

FAILED_COMPONENTS=()
mkdir -p "$TMP_DIR/depot"
i=0
while read -r file sha; do
    i=$((i + 1))
    out="$TMP_DIR/depot/$file"
    if [[ ! -f "$out" ]] || [[ "$(sha256sum < "$out" | cut -d' ' -f1)" != "$sha" ]]; then
        log "    [${i}/${COMP_COUNT}] get ${file}"
        if ! download "${BASE_URL}/${file}" "$out"; then
            log "    WARNING: could not fetch ${file} after retries"
            FAILED_COMPONENTS+=("$file")
            continue
        fi
    fi
    if [[ "$(sha256sum < "$out" | cut -d' ' -f1)" != "$sha" ]]; then
        log "    WARNING: SHA mismatch for ${file}"
        FAILED_COMPONENTS+=("$file")
        continue
    fi
done < "$TMP_DIR/comps.txt"

if [ "${#FAILED_COMPONENTS[@]}" -gt 0 ]; then
    log "==> WARNING: ${#FAILED_COMPONENTS[@]} component(s) could not be fetched:"
    for c in "${FAILED_COMPONENTS[@]}"; do log "    - $c"; done
    die "client depot incomplete - rerun install-steam to resume the missing parts"
fi

# Extract: fix Windows '\\' path separator, chmod +x all ELF (depot zips carry no unix bits)
log "==> Step 2: Extracting depot zips to ${STEAM_ROOT}"
mkdir -p "$STEAM_ROOT"

python3 - "$TMP_DIR/depot" "$STEAM_ROOT" <<'PY'
import sys, os, glob, zipfile, stat

depot, root = sys.argv[1], sys.argv[2]
elf_count = 0
for z in sorted(glob.glob(os.path.join(depot, "*.zip.*"))):
    with zipfile.ZipFile(z) as zf:
        for m in zf.infolist():
            name = m.filename.replace("\\", "/")
            if name.endswith("/"):
                continue
            dst = os.path.join(root, name)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with zf.open(m) as src, open(dst, "wb") as out:
                out.write(src.read())

for dp, _, fs in os.walk(root):
    for f in fs:
        p = os.path.join(dp, f)
        try:
            with open(p, "rb") as fh:
                if fh.read(4) == b"\x7fELF":
                    os.chmod(p, 0o755)
                    elf_count += 1
        except Exception:
            pass
print(f"    extracted; chmod +x on {elf_count} ELF files")
PY

# ---------- 3. Layout + symlinks (user side) ----------
log "==> Step 3: Setting up ~/.steam symlinks"

mkdir -p "$DOT_STEAM_DIR"
ln -sfn "$STEAM_ROOT" "${DOT_STEAM_DIR}/steam"
ln -sfn "$STEAM_ROOT" "${DOT_STEAM_DIR}/root"
ln -sfn "${STEAM_ROOT}/linuxarm64" "${DOT_STEAM_DIR}/sdkarm64"

# Enable public beta if that's what we fetched
if [[ "$STEAM_CHANNEL" == "publicbeta" ]]; then
    mkdir -p "${STEAM_ROOT}/package"
    echo publicbeta > "${STEAM_ROOT}/package/beta"
fi

# libvpx compatibility shim (Steam needs libvpx.so.6, system may ship .10/.12)
log "==> Step 4: libvpx.so.6 compatibility shim"
LIBVPX_CANDIDATES=(
    "${ROOTFS_DIR:-}/usr/lib/aarch64-linux-gnu/libvpx.so."*
    "${ROOTFS_DIR:-}/usr/lib64/libvpx.so."*
    "${ROOTFS_DIR:-}/usr/lib/arm64-linux-gnu/libvpx.so."*
)
for candidate in "${LIBVPX_CANDIDATES[@]}"; do
    [[ -f "$candidate" || -L "$candidate" ]] || continue
    link_dir="$(dirname "$candidate")"
    link_path="${link_dir}/libvpx.so.6"
    target_basename="$(basename "$candidate")"
    if [[ ! -f "$link_path" && ! -L "$link_path" ]]; then
        ln -sfn "$target_basename" "$link_path"
        log "    linked ${link_path} -> ${target_basename}"
        break
    fi
done

# ---------- 5. FEX Arch rootfs ----------
log "==> Step 5: Installing FEX Arch rootfs"

# FEX rootfs is distributed by FEX as SquashFS/EroFS images via
# https://rootfs.fex-emu.gg/RootFS_links.json (the old GitHub FEXRootFSFetcher.tar.gz
# asset was removed and now returns HTTP 404).
# We use the ArchLinux SquashFS image and unpack it with unsquashfs so FEX gets a
# real directory tree at $FEX_DIR (Steam/FEX expects a rootfs directory).
if [[ -z "$FEX_ROOTFS_URL" ]]; then
    FEX_ROOTFS_URL="https://rootfs.fex-emu.gg/ArchLinux/2026-08-11/ArchLinux.sqsh"
fi

mkdir -p "$FEX_DIR"

# .sqsh (SquashFS) — unpack via unsquashfs (squashfs-tools)
if [[ "$FEX_ROOTFS_URL" == *.sqsh ]]; then
    if command -v unsquashfs >/dev/null 2>&1; then
        log "    unsquashfs: extracting $FEX_ROOTFS_URL -> $FEX_DIR"
        if download "$FEX_ROOTFS_URL" "$TMP_DIR/fex-rootfs.sqsh"; then
            # unsquashfs creates FEX_DIR itself; use -f to overwrite stale contents
            if ! unsquashfs -f -d "$FEX_DIR" "$TMP_DIR/fex-rootfs.sqsh"; then
                log "    unsquashfs failed; Steam will download the rootfs on first game launch"
            fi
        else
            log "    FEX rootfs download failed; Steam will download it on first game launch"
        fi
    else
        log "    unsquashfs not installed; skipping FEX rootfs (Steam will download on first game launch)"
    fi
# .ero (EroFS) — unsupported here; fall through to download-on-first-launch
elif [[ "$FEX_ROOTFS_URL" == *.ero ]]; then
    log "    EroFS rootfs not supported in-container; Steam will download on first game launch"
# Legacy tar.gz (FEXRootFSFetcher)
else
    if ! download "$FEX_ROOTFS_URL" "$TMP_DIR/fex-rootfs.tar.gz"; then
        log "    FEX rootfs download failed; Steam will download it on first game launch"
    elif tar -tzf "$TMP_DIR/fex-rootfs.tar.gz" >/dev/null 2>&1; then
        tar -xzf "$TMP_DIR/fex-rootfs.tar.gz" -C "$TMP_DIR/fex-extract" 2>/dev/null || true
        if [[ -d "$TMP_DIR/fex-extract/ArchLinux" ]]; then
            cp -a "$TMP_DIR/fex-extract/ArchLinux/"* "$FEX_DIR/" 2>/dev/null || cp -a "$TMP_DIR/fex-extract/ArchLinux" "$FEX_DIR/"
        elif [[ -d "$TMP_DIR/fex-extract/rootfs" ]]; then
            cp -a "$TMP_DIR/fex-extract/rootfs/"* "$FEX_DIR/" 2>/dev/null || cp -a "$TMP_DIR/fex-extract/rootfs" "$FEX_DIR/"
        else
            mkdir -p "$FEX_DIR"
            tar -xzf "$TMP_DIR/fex-rootfs.tar.gz" -C "$FEX_DIR" 2>/dev/null || true
        fi
    else
        log "    FEX rootfs tarball format unrecognized, skipping"
    fi
fi

# Symlink: Steam's FEX tool hardcodes /usr/share/guestos/fex-mesa
if [[ -d "$FEX_DIR" ]] && [[ -n "$(ls -A "$FEX_DIR" 2>/dev/null)" ]]; then
    mkdir -p "$(dirname "$GUESTOS_DIR")"
    ln -sfn "$FEX_DIR" "$GUESTOS_DIR"
    log "    FEX Arch rootfs -> ${GUESTOS_DIR}"
else
    log "    FEX rootfs not extracted; Steam will download on first game launch"
fi

# ---------- 5b. Client runtime libraries ----------
log "==> Step 5b: Client runtime libraries"
#
# The client links a desktop stack that a slim container image does not carry.
# Each missing piece fails differently: libgtk-x11-2.0 aborts steamui.so before
# any window exists, libopenal is a link-time dependency of vgui2_s.so so that
# module refuses to load even though no audio stream is open yet, libibus kills
# steamwebhelper and the UI stays on the loading spinner, and libSDL2 only
# breaks the GL capability probe.  Probe what the image lacks instead of
# shipping one fixed list, so the same script works on Debian 12 and 13.
_need_lib() { ldconfig -p 2>/dev/null | grep -q "$1"; }
_MISSING=""
_pick() { _need_lib "$1" || _MISSING="$_MISSING $2"; }
_pick libgtk-x11-2.0.so.0     libgtk2.0-0t64
_pick libnss3.so              libnss3
_pick libXss.so.1             libxss1
_pick libgbm.so.1             libgbm1
_pick libasound.so.2          libasound2t64
_pick libxkbcommon.so.0       libxkbcommon0
_pick libdrm.so.2             libdrm2
_pick libcups.so.2            libcups2t64
_pick libatk-1.0.so.0         libatk1.0-0t64
_pick libatk-bridge-2.0.so.0  libatk-bridge2.0-0t64
_pick libpango-1.0.so.0       libpango-1.0-0
_pick libcairo.so.2           libcairo2
_pick libXcomposite.so.1      libxcomposite1
_pick libXdamage.so.1         libxdamage1
_pick libXrandr.so.2          libxrandr2
_pick libXtst.so.6            libxtst6
_pick libXi.so.6              libxi6
_pick libXfixes.so.3          libxfixes3
_pick libopenal.so.1          libopenal1
_pick libibus-1.0.so.5        libibus-1.0-5
_pick libSDL2-2.0.so.0        libsdl2-2.0-0
unset -f _need_lib _pick 2>/dev/null || true
if [ -n "$_MISSING" ]; then
    if command -v apt-get >/dev/null 2>&1; then
        log "    installing:$_MISSING"
        apt-get update -qq >/dev/null 2>&1 || true
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $_MISSING >/dev/null 2>&1; then
            # Debian 13 renamed the time_t-sensitive packages with a t64 suffix;
            # older archives only know the plain names.
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
                $(echo "$_MISSING" | sed "s/t64//g") >/dev/null 2>&1 || true
        fi
        ldconfig 2>/dev/null || true
    else
        log "    apt-get unavailable; install these libraries manually:$_MISSING"
    fi
else
    log "    all runtime libraries already present"
fi
unset _MISSING

# ---------- 6. Desktop launcher + icon ----------
log "==> Step 6: Desktop launcher + icon"

mkdir -p "${ROOTFS_DIR:-}/home/${STEAM_USER}/.local/share/applications"
mkdir -p "$ICONS_DIR"
mkdir -p "$BIN_DIR"

# Runtime launcher.  The desktop entry used to exec the client binary directly,
# which loses two environment fixes that are required on real hardware:
#
#   1. libpng.  steamui.so statically links libpng and exports 391 png_* symbols
#      while libSDL3 carries its own hidden copy.  png_* binds lazily, so a
#      png_struct allocated by one implementation gets dereferenced by the other
#      and the client dies with SIGSEGV before the UI appears.  Preloading the
#      system libpng keeps one implementation for the whole process tree.
#   2. OpenGL.  The session environment selects the vendor path (kgsl on
#      Qualcomm, libhybris/Mali on MediaTek).  With no KMS node the client cannot
#      create a GBM device and eglInitialize fails, so fall back to llvmpipe
#      rather than aborting.  A DRM render node alone is not enough: it serves
#      Vulkan but still leaves GL without a GBM device.
cat > "$STEAM_LAUNCHER" <<'STEAM_LAUNCHER_EOF'
#!/bin/sh
# steam-anland - Steam ARM64 launcher for Droidspaces + anland containers.
#
# Preload a single libpng implementation.  Skipped when the library is absent so
# a rootfs without libpng16 still starts the client.
set -u

# The installation step runs before the desktop account exists, so the tree can
# end up under /home/user while the session runs as another user.  Resolve it at
# runtime instead of trusting the baked-in path.
S=""
for _c in "@STEAM_ROOT@" "${HOME:-}/.local/share/Steam" \
          /home/Gold/.local/share/Steam /home/user/.local/share/Steam; do
    if [ -n "$_c" ] && [ -x "$_c/steamrtarm64/steam" ]; then
        S="$_c"
        break
    fi
done
if [ -z "$S" ]; then
    echo "steam-anland: no Steam install found (looked in @STEAM_ROOT@, $HOME and the image defaults)" >&2
    exit 1
fi
unset _c

# Prefer the runtime copy: the client and libSDL3_image are built against the
# libpng shipped in pv-runtime, so preloading that exact build cannot drift.
# Fall back to the host library when a rootfs has no runtime (or Steam pruned
# it); either copy works as long as only one is loaded in the process tree.
PNG=""
for _r in "$S"/steamrtarm64/pv-runtime/steam-runtime-steamrt/*/files/lib/*-linux-gnu/libpng16.so.16.*; do
    if [ -e "$_r" ]; then PNG="$_r"; fi
done
if [ -z "$PNG" ]; then
    PNG="$(ldconfig -p 2>/dev/null | awk '/libpng16\.so\.16/ {print $NF; exit}')"
fi
if [ -n "${PNG:-}" ] && [ -e "$PNG" ]; then
    LD_PRELOAD="$PNG"
    export LD_PRELOAD
fi
unset _r

LD_LIBRARY_PATH="$S/steamrtarm64:$S/steamrtarm64/libs:$S/linuxarm64:$S/androidarm64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LD_LIBRARY_PATH
export STEAM_COMPAT_CLIENT_INSTALL_PATH="$S"

if [ -z "${XDG_RUNTIME_DIR:-}" ] || [ ! -d "${XDG_RUNTIME_DIR:-/nonexistent}" ]; then
    if [ -d "/run/user/$(id -u)" ]; then
        XDG_RUNTIME_DIR="/run/user/$(id -u)"
    elif [ -d /run/anland ]; then
        XDG_RUNTIME_DIR=/run/anland
    fi
    if [ -n "${XDG_RUNTIME_DIR:-}" ]; then export XDG_RUNTIME_DIR; fi
fi

# Only a KMS node proves that GL can create a GBM device.  A kgsl/mali 3D node
# or a DRM render node is not sufficient: with those present but no card node,
# eglInitialize still fails and the client aborts on startup.  Vulkan keeps using
# the vendor ICD, so Proton titles stay hardware accelerated either way.
if [ -z "${STEAM_GL_MODE:-}" ]; then
    _gpu=0
    for _d in /dev/dri/card0 /dev/dri/card1 /dev/dri/card2; do
        if [ -e "$_d" ]; then _gpu=1; break; fi
    done
    if [ "$_gpu" -eq 0 ]; then
        GALLIUM_DRIVER=llvmpipe
        LIBGL_ALWAYS_SOFTWARE=1
        export GALLIUM_DRIVER LIBGL_ALWAYS_SOFTWARE
    fi
    unset _gpu _d
fi

# Proton/Vulkan environment for game launches.  Validated on Adreno + Mali:
#
#   * DXVK cannot create a Vulkan instance in this container.  The only ICDs the
#     x86-64 Proton binaries can load live in the FEX rootfs and Unity titles
#     crash inside winevulkan, so route D3D through wined3d/OpenGL instead.
#   * steam-launch-wrapper injects VK_INSTANCE_LAYERS with two Valve layers that
#     no image ships; the loader then fails every instance creation.
#   * lsteamclient asserts (steamclient_main.c:573) because no 64-bit
#     steamclient.so exists, so disable the native Steam bridge.
export PROTON_USE_WINED3D=1
export VK_LOADER_LAYERS_DISABLE="~all~"
export WINEDLLOVERRIDES="lsteamclient=d;steamclient64=d;steamclient=d"
if [ -z "${VK_ICD_FILENAMES:-}" ]; then
    for _icd in /usr/share/guestos/fex-mesa/usr/share/vulkan/icd.d/freedreno_icd.x86_64.json \
                /usr/share/guestos/fex-mesa/usr/share/vulkan/icd.d/lvp_icd.x86_64.json; do
        if [ -f "$_icd" ]; then VK_ICD_FILENAMES="$_icd"; export VK_ICD_FILENAMES; break; fi
    done
    unset _icd
fi

cd "$S/steamrtarm64" 2>/dev/null || exit 1
# anland reports the panel physical density.  On a phone-class panel (560 dpi)
# the client lays out its logical surface at a fraction of the real size and
# paints the UI into one corner, so pin the scale and let STEAM_DPI override it.
exec ./steam -no-cef-sandbox -cef-disable-gpu -chromeosnopreallocate \
    -forcedpi "${STEAM_DPI:-96}" "$@"
STEAM_LAUNCHER_EOF

sed -i "s|@STEAM_ROOT@|${STEAM_ROOT_RUNTIME}|g" "$STEAM_LAUNCHER"
chmod 755 "$STEAM_LAUNCHER"
log "    launcher: ${STEAM_LAUNCHER}"

# Settings is reachable without the client menu: anland-miniwm implements no
# EWMH, so CEF dropdowns and modal dialogs are mapped at +0+0 under the main
# window and never raised, which makes the Steam menu look unresponsive.
cat > "$STEAM_SETTINGS_HELPER" <<'STEAM_SETTINGS_EOF'
#!/bin/sh
# Open Steam Settings through the URL handler instead of the in-client menu.
exec /usr/local/bin/steam-anland "steam://open/settings" "$@"
STEAM_SETTINGS_EOF

chmod 755 "$STEAM_SETTINGS_HELPER"
log "    settings helper: ${STEAM_SETTINGS_HELPER}"


# Icon (Steam logo SVG from Wikimedia)
download "https://upload.wikimedia.org/wikipedia/commons/8/83/Steam_icon_logo.svg" \
         "$TMP_DIR/steam.svg" 2>/dev/null || true
if [[ -f "$TMP_DIR/steam.svg" ]]; then
    cp -a "$TMP_DIR/steam.svg" "$ICONS_DIR/steam.svg"
    log "    steam.svg icon installed"
fi

# .desktop file
cat > "$DESKTOP_FILE" <<DESKTOP_EOF
[Desktop Entry]
Type=Application
Name=Steam
GenericName=Steam Gaming
Comment=Play Steam games via Valve ARM64 client + Proton
Exec=/usr/local/bin/steam-anland %U
Icon=steam
Terminal=false
Categories=Game;
StartupNotify=true
StartupWMClass=steam
DESKTOP_EOF

chmod +x "$DESKTOP_FILE"

# ---------- 6b. Game runtime support ----------
log "==> Step 6b: Game runtime support (CJK fonts, pressure-vessel bypass)"

# Proton ships a stub MS Gothic without CJK glyphs and fontconfig maps the
# Windows font names onto DejaVu, so Chinese/Japanese UI text renders as tofu.
# Point the common names at Noto CJK when the image provides it.
FONTCONF_DIR="${ROOTFS_DIR:-}/etc/fonts"
if [ -d "${ROOTFS_DIR:-}/usr/share/fonts/opentype/noto" ]; then
    mkdir -p "$FONTCONF_DIR"
    cat > "${FONTCONF_DIR}/local.conf" <<'FONTCONF_EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <alias binding="same"><family>MS Gothic</family>
    <prefer><family>Noto Sans CJK SC</family><family>Noto Sans CJK JP</family></prefer></alias>
  <alias binding="same"><family>MS UI Gothic</family>
    <prefer><family>Noto Sans CJK SC</family></prefer></alias>
  <alias binding="same"><family>MS Mincho</family>
    <prefer><family>Noto Serif CJK SC</family></prefer></alias>
  <alias binding="same"><family>Malgun Gothic</family>
    <prefer><family>Noto Sans CJK SC</family></prefer></alias>
  <alias binding="same"><family>Microsoft YaHei</family>
    <prefer><family>Noto Sans CJK SC</family></prefer></alias>
</fontconfig>
FONTCONF_EOF
    log "    fontconfig CJK aliases installed"
fi

# pressure-vessel cannot create user namespaces here (the Android kernel leaves
# unprivileged userns off), so bwrap aborts with
#     setting up uid map: No such file or directory
# and Proton never starts the game.  Replace the runtime entry point with a
# passthrough; the Collabora original is kept next to it as .pv.
SLR_ENTRY="${STEAM_ROOT}/steamapps/common/SteamLinuxRuntime_4/_v2-entry-point"
if [ -f "$SLR_ENTRY" ]; then
    if [ ! -f "${SLR_ENTRY}.pv" ]; then
        cp -a "$SLR_ENTRY" "${SLR_ENTRY}.pv"
    fi
    cat > "$SLR_ENTRY" <<'SLR_EOF'
#!/bin/sh
# passthrough: pressure-vessel/bwrap cannot create user namespaces in this
# container, so run the requested command directly instead of entering the
# Steam Runtime sandbox.
while [ $# -gt 0 ]; do
    case "$1" in
        --verb=*) shift ;;
        --) shift; break ;;
        *) break ;;
    esac
done
exec "$@"
SLR_EOF
    chmod 755 "$SLR_ENTRY"
    log "    SteamLinuxRuntime entry point -> passthrough"
fi

# ---------- 7. Fix ELF + ensure all binaries executable ----------
log "==> Step 7: Ensuring ELF binaries are executable"

# Already done during extraction, but be safe
python3 - "$STEAM_ROOT" <<'PY'
import os, stat, sys
root = sys.argv[1]
fixed = 0
for dp, _, fs in os.walk(root):
    for f in fs:
        p = os.path.join(dp, f)
        try:
            with open(p, "rb") as fh:
                hdr = fh.read(4)
            if hdr == b"\x7fELF":
                st = os.stat(p)
                if not (st.st_mode & stat.S_IXUSR):
                    os.chmod(p, st.st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
                    fixed += 1
        except Exception:
            pass
print(f"    fixed {fixed} non-executable ELF binaries")
PY

# ---------- 8. Ownership ----------
# The client refuses to run unless it can write its own tree: the pre-launch
# update writes package/ and aborts with
#     Fatal error: Directory <Steam>/package not writable.
# when the tree belongs to root.  Everything above is created by this script as
# root (the in-container run, and a root-owned --prefix run), while the desktop
# session runs as STEAM_USER, so hand the tree over.  A --prefix rootfs usually
# has no such account on the host, and these images put the desktop user at
# uid 1000, so fall back to that pair.
log "==> Step 8: Ownership -> ${STEAM_USER}"
if [[ "$(id -u)" -eq 0 ]]; then
    OWNER_UID="$(id -u "$STEAM_USER" 2>/dev/null || echo 1000)"
    OWNER_GID="$(id -g "$STEAM_USER" 2>/dev/null || echo 1000)"
    for p in "$STEAM_ROOT" "$DOT_STEAM_DIR" \
             "${ROOTFS_DIR:-}/home/${STEAM_USER}/.local/share/applications" \
             "$ICONS_DIR"; do
        if [[ -e "$p" ]]; then
            chown -R "${OWNER_UID}:${OWNER_GID}" "$p"
        fi
    done
    log "    chown -R ${OWNER_UID}:${OWNER_GID} (Steam, .steam, desktop entry, icon)"
else
    log "    not running as root; ownership left as $(id -un)"
fi

# ---------- 9. Autostart ----------
# anland 6 ships no desktop shell, no session autostart hook and nothing that
# reads XDG .desktop files, so the only way a shipped rootfs can put Steam on
# screen without a shell is a boot unit of its own.  It waits for the session's
# X socket instead of racing it: desktop-session.service owns Xwayland and a
# llvmpipe start takes seconds.  STEAM_AUTOSTART=0 keeps an image idle on boot.
if [[ "${STEAM_AUTOSTART:-1}" == 1 ]]; then
    log "==> Step 9: Autostart unit"
    R="${ROOTFS_DIR:-}"
    mkdir -p "${R}/usr/local/bin" "${R}/etc/systemd/system/multi-user.target.wants"
    cat > "${R}/usr/local/bin/steam-autostart" <<'STEAM_AUTOSTART_EOF'
#!/bin/sh
# Wait for the anland X server, then launch Steam as the session user.
set -u
USER_NAME="${STEAM_USER:-Gold}"
UID_N="$(id -u "$USER_NAME" 2>/dev/null || echo 1000)"
HOME_DIR="$(getent passwd "$UID_N" | cut -d: -f6)"
[ -n "$HOME_DIR" ] || HOME_DIR="/home/$USER_NAME"
i=0
while [ "$i" -lt 120 ]; do
    i=$((i+1))
    [ -S /tmp/.X11-unix/X0 ] && break
    sleep 1
done
[ -S /tmp/.X11-unix/X0 ] || { echo "steam-autostart: no X socket after ${i}s" >&2; exit 0; }
sleep 4
LAUNCHER="$HOME_DIR/.local/bin/steam-anland"
[ -x "$LAUNCHER" ] || LAUNCHER=/usr/local/bin/steam-anland
exec setpriv --reuid="$UID_N" --regid="$UID_N" --init-groups env -i \
    HOME="$HOME_DIR" USER="$USER_NAME" LOGNAME="$USER_NAME" \
    PATH="$HOME_DIR/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    DISPLAY=:0 WAYLAND_DISPLAY=wayland-anland \
    XDG_RUNTIME_DIR="/run/user/$UID_N" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_N/bus" \
    PULSE_SERVER=unix:/run/anland/pulse.sock LANG=en_US.UTF-8 \
    MESA_LOADER_DRIVER_OVERRIDE=swrast GALLIUM_DRIVER=llvmpipe LIBGL_ALWAYS_SOFTWARE=1 \
    "$LAUNCHER"
STEAM_AUTOSTART_EOF
    cat > "${R}/etc/systemd/system/steam-autostart.service" <<'STEAM_UNIT_EOF'
[Unit]
Description=Launch Steam on the anland desktop session
After=desktop-session.service
Requires=desktop-session.service

[Service]
Type=simple
ExecStart=/usr/local/bin/steam-autostart
Restart=no

[Install]
WantedBy=multi-user.target
STEAM_UNIT_EOF
    chmod 755 "${R}/usr/local/bin/steam-autostart"
    chmod 644 "${R}/etc/systemd/system/steam-autostart.service"
    ln -sf /etc/systemd/system/steam-autostart.service \
        "${R}/etc/systemd/system/multi-user.target.wants/steam-autostart.service"
    log "    steam-autostart.service enabled (STEAM_AUTOSTART=0 disables)"
fi

log "==> Done. Steam ARM64 client v${VER} installed to ${STEAM_ROOT}"
log "    First launch runs 'steam -deckard -exitsteam' once to bootstrap."
log "    Windows games will prompt Steam to download Steam Linux Runtime 4.0 for arm64 + Proton on first launch."
