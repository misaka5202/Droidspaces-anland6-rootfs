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
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ---------- helpers ----------
log() { printf '[install-steam] %s\n' "$*"; }
die() { printf '[install-steam] ERROR: %s\n' "$*" >&2; exit 1; }

download() {
    # Resumable download with retries.  The Valve CDN drops long-lived TLS
    # connections mid-transfer, so a single curl invocation cannot be trusted
    # for the multi-hundred-MB client depot: resume (-C -) from what already
    # landed and retry until the file is complete.
    local url="$1" output="$2" attempt=1 max_attempts="${DOWNLOAD_MAX_ATTEMPTS:-12}"
    while [ "$attempt" -le "$max_attempts" ]; do
        if curl -fsSL --connect-timeout 30 --max-time 900 \
                --speed-limit 1024 --speed-time 60 \
                -C - -o "$output" "$url"; then
            return 0
        fi
        log "    download interrupted (attempt ${attempt}/${max_attempts}), resuming: $(basename "$output")"
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

log "==> Done. Steam ARM64 client v${VER} installed to ${STEAM_ROOT}"
log "    First launch runs 'steam -deckard -exitsteam' once to bootstrap."
log "    Windows games will prompt Steam to download Steam Linux Runtime 4.0 for arm64 + Proton on first launch."
