#!/bin/sh
# v2 dev-loader: live-patch OwnerTools.qml on the running rootfs (no reflash).
# Installs the OwnerTools.qml that sits next to this script to the app path, matching a sibling
# QML's SMACK label, then reports. Owner's own decommissioned, off-road car.
set +e
STICK_DIR=$(cd "$(dirname "$0")" && pwd)
SRC="$STICK_DIR/OwnerTools.qml"
DST=/app/share/AppEngineerMode/qml/owner/OwnerTools.qml
SIB=/app/share/AppEngineerMode/qml/AppEngineerMode_FullMain.qml
OUT="$STICK_DIR/v2_qmlpatch.txt"
{
  echo "===== v2 OwnerTools.qml live-patch ====="
  echo "when:   $(date -u 2>/dev/null)"
  echo "src:    $SRC ($( [ -f "$SRC" ] && wc -c < "$SRC" || echo MISSING ) bytes)"
  [ -f "$SRC" ] || { echo "ABORT: OwnerTools.qml not found next to the script"; exit 0; }

  # mount holding /app
  MP=$(awk '$2=="/app"{print $2} END{}' /proc/mounts); [ -n "$MP" ] || MP=/
  echo "remount rw: $MP"; mount -o remount,rw "$MP" 2>&1 | sed 's/^/  /'

  mkdir -p "$(dirname "$DST")" 2>/dev/null
  [ -f "$DST" ] && cp "$DST" /var/log/OwnerTools.qml.bak 2>/dev/null
  echo "old DST md5: $(md5sum "$DST" 2>/dev/null | cut -d' ' -f1)"
  cp "$SRC" "$DST" && echo "copied -> $DST" || echo "COPY FAILED (path read-only?)"
  echo "new DST md5: $(md5sum "$DST" 2>/dev/null | cut -d' ' -f1)"

  echo "--- SMACK labels ---"
  if command -v chsmack >/dev/null 2>&1; then
    echo "sibling: $(chsmack "$SIB" 2>/dev/null)"
    LBL=$(chsmack "$SIB" 2>/dev/null | sed -n 's/.*access="\([^"]*\)".*/\1/p')
    [ -n "$LBL" ] && chsmack -a "$LBL" "$DST" 2>/dev/null
    echo "patched: $(chsmack "$DST" 2>/dev/null)"
  elif command -v getfattr >/dev/null 2>&1; then
    LBL=$(getfattr -n security.SMACK64 --only-values "$SIB" 2>/dev/null)
    echo "sibling SMACK64: $LBL"
    [ -n "$LBL" ] && setfattr -n security.SMACK64 -v "$LBL" "$DST" 2>/dev/null
    echo "patched SMACK64: $(getfattr -n security.SMACK64 --only-values "$DST" 2>/dev/null)"
  else
    echo "no chsmack/getfattr — label unchanged (sibling FullMain loads unlabeled, so likely OK)"
  fi

  sync
  echo "--- done. Re-open Owner Tools (Loader re-reads the file). If still blank, reboot once. ---"
} > "$OUT" 2>&1
sync
cp "$OUT" /var/log/v2_qmlpatch.txt 2>/dev/null
