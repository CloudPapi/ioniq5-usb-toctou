#!/bin/bash
# PREFLIGHT wrapper — run the go/no-go gate BEFORE plugging the Pi into the head unit.
# On an x86-64 bench it ensures the real DecryptToPIPE + loader are extracted (check C);
# then runs preflight.py (checks A..D). On the ARM Pi, check C auto-skips (x86-64 binary) —
# run the full gate on the bench, then run `preflight.py` on the Pi for the gadget dry-run (D).
#
#   ./04_preflight.sh [package_dir]
# package_dir (optional) = genuine IONIQ5 update tree; used only to extract DecryptToPIPE for C.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
PKG="${1:-${IONIQ_PKG:-$HOME/ioniq/IONIQ5_EU}}"
GEN="$PKG/HU/images/mango-rootfs.tar.gz"
BINROOT="$HERE/build/binroot"
DEC="$HERE/gen5w_decrypt.py"

ARCH="$(uname -m)"
# Check C needs the real x86-64 DecryptToPIPE + its loader/libs. Extract once, on the bench only.
if [ "$ARCH" = "x86_64" ] || [ "$ARCH" = "amd64" ]; then
  if [ ! -x "$BINROOT/app/share/AppUpgrade/DecryptToPIPE" ] || [ ! -f "$BINROOT/lib/ld-2.25.so" ]; then
    if [ -f "$GEN" ] && [ -f "$DEC" ]; then
      echo "[*] extracting real DecryptToPIPE + loader/libs into build/binroot (one-time, ~decrypts genuine rootfs)"
      mkdir -p "$BINROOT"
      TMP="$(mktemp -d)"
      python3 "$DEC" decrypt "$GEN" "$TMP/plain.tar.gz" --force
      zcat "$TMP/plain.tar.gz" | tar -x -C "$BINROOT" \
        ./app/share/AppUpgrade/DecryptToPIPE ./lib ./usr/lib 2>/dev/null || true
      rm -rf "$TMP"
      chmod +x "$BINROOT/app/share/AppUpgrade/DecryptToPIPE" 2>/dev/null || true
    else
      echo "[!] no genuine package at $GEN (or missing $DEC) — check C will SKIP."
    fi
  fi
else
  echo "[*] host arch=$ARCH (not x86-64): DecryptToPIPE check C will auto-skip; running A/B/D."
fi

exec python3 "$HERE/preflight.py" --binroot "$BINROOT" "${@:2}"
