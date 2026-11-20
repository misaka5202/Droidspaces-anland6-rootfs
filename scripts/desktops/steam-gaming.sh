#!/usr/bin/env bash
set -euo pipefail
source "${ROOTFS_DIR:-}/etc/os-release"
echo "=== steam-gaming TRIVIAL: ID=${ID:-unknown} VERSION_ID=${VERSION_ID:-unknown} ==="
case "$ID" in
    debian|ubuntu) apt-get install -y --no-install-recommends curl ca-certificates ;;
    fedora) dnf install -y curl ca-certificates ;;
    arch|archarm|archlinux) pacman -S --noconfirm --needed curl ca-certificates ;;
    *) echo "unsupported: $ID" >&2; exit 1 ;;
esac
echo "=== pkg install ok ==="
if command -v install-steam >/dev/null 2>&1; then
    echo "=== install-steam exists ==="
    install-steam --channel publicbeta || echo "=== install-steam failed ==="
else
    echo "=== install-steam NOT FOUND ==="
fi
echo "=== steam-gaming DONE ==="
