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
#   STEAM_USER           User that owns Steam files (default: user)

set -euo pipefail

readonly BASE_URL="https://client-update.fastly.steamstatic.com"
readonly DEPOT_URL="https://client-update.steamstatic.com"

# ---------- argument parsing ----------
ROOTFS_DIR="${ROOTFS_DIR:-}"
STEAM_CHANNEL="${STEAM_CHANNEL:-publicbeta}"
STEAM_USER="${STEAM_USER:-user}"
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
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ---------- helpers ----------
log() { printf '[install-steam] %s\n' "$*"; }
die() { printf '[install-steam] ERROR: %s\n' "$*" >&2; exit 1; }

download() {
    local url="$1" output="$2"
    curl -fsSL --retry 3 --connect-timeout 30 -o "$output" "$url"
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

mkdir -p "$TMP_DIR/depot"
i=0
while read -r file sha; do
    i=$((i + 1))
    out="$TMP_DIR/depot/$file"
    if [[ ! -f "$out" ]] || [[ "$(sha256sum < "$out" | cut -d' ' -f1)" != "$sha" ]]; then
        log "    [${i}/${COMP_COUNT}] get ${file}"
        download "${BASE_URL}/${file}" "$out"
    fi
    [[ "$(sha256sum < "$out" | cut -d' ' -f1)" == "$sha" ]] || die "SHA mismatch: $file"
done < "$TMP_DIR/comps.txt"

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
        download "$FEX_ROOTFS_URL" "$TMP_DIR/fex-rootfs.sqsh"
        # unsquashfs creates FEX_DIR itself; use -f to overwrite stale contents
        if ! unsquashfs -f -d "$FEX_DIR" "$TMP_DIR/fex-rootfs.sqsh"; then
            log "    unsquashfs failed; Steam will download the rootfs on first game launch"
        fi
    else
        log "    unsquashfs not installed; skipping FEX rootfs (Steam will download on first game launch)"
    fi
# .ero (EroFS) — unsupported here; fall through to download-on-first-launch
elif [[ "$FEX_ROOTFS_URL" == *.ero ]]; then
    log "    EroFS rootfs not supported in-container; Steam will download on first game launch"
# Legacy tar.gz (FEXRootFSFetcher)
else
    download "$FEX_ROOTFS_URL" "$TMP_DIR/fex-rootfs.tar.gz"
    if tar -tzf "$TMP_DIR/fex-rootfs.tar.gz" >/dev/null 2>&1; then
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

# ---------- 6. Desktop launcher + icon ----------
log "==> Step 6: Desktop launcher + icon"

mkdir -p "${ROOTFS_DIR:-}/home/${STEAM_USER}/.local/share/applications"
mkdir -p "$ICONS_DIR"

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
Exec=${STEAM_ROOT}/steamrtarm64/steam %U
Icon=steam
Terminal=false
Categories=Game;
StartupNotify=true
StartupWMClass=steam
DESKTOP_EOF

chmod +x "$DESKTOP_FILE"

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

log "==> Done. Steam ARM64 client v${VER} installed to ${STEAM_ROOT}"
log "    First launch runs 'steam -deckard -exitsteam' once to bootstrap."
log "    Windows games will prompt Steam to download Steam Linux Runtime 4.0 for arm64 + Proton on first launch."
