#!/bin/sh
# v2 dev-loader: find how /app is mounted, remount it rw, install OwnerTools.qml, retry.
# Owner's own decommissioned, off-road car.
set +e
STICK_DIR=$(cd "$(dirname "$0")" && pwd)
SRC="$STICK_DIR/OwnerTools.qml"
DST=/app/share/AppEngineerMode/qml/owner/OwnerTools.qml
OUT="$STICK_DIR/v2_qmlpatch.txt"
{
  echo "===== v2 OwnerTools.qml live-patch (v2) ====="
  echo "when: $(date -u 2>/dev/null)"
  echo "src:  $SRC ($( [ -f "$SRC" ] && wc -c < "$SRC" || echo MISSING ) bytes)"
  [ -f "$SRC" ] || { echo "ABORT: no OwnerTools.qml next to script"; exit 0; }

  echo "--- mounts of interest ---"
  grep -E ' / |/app|mmcblk0p|ext4|squash|overlay| ro,| ro ' /proc/mounts | sed 's/^/  /'

  # longest-prefix mountpoint that contains /app
  MP=$(awk '{print $2}' /proc/mounts | awk '{print length, $0}' | sort -rn | cut -d" " -f2- | \
       while read m; do case "/app/share" in "$m"*) echo "$m"; break;; esac; done)
  [ -n "$MP" ] || MP=/
  SRCDEV=$(awk -v m="$MP" '$2==m{print $1" "$3" "$4}' /proc/mounts | head -1)
  echo "--- /app lives on mountpoint: $MP   (dev fstype opts: $SRCDEV) ---"
  echo "statfs: $(stat -f -c 'fstype=%T bsize=%s' /app 2>/dev/null)"

  echo "--- remount rw $MP ---"
  mount -o remount,rw "$MP" 2>&1 | sed 's/^/  /'
  echo "  after: $(awk -v m="$MP" '$2==m{print $4}' /proc/mounts | head -1)"

  echo "old DST md5: $(md5sum "$DST" 2>/dev/null | cut -d' ' -f1)"
  cp "$SRC" "$DST" 2>&1 | sed 's/^/  cp: /'
  echo "new DST md5: $(md5sum "$DST" 2>/dev/null | cut -d' ' -f1)"

  # if still read-only, try remounting / as well (in case /app is a bind/sub of root)
  if [ "$(md5sum "$DST" 2>/dev/null | cut -d' ' -f1)" != "$(md5sum "$SRC" | cut -d' ' -f1)" ]; then
    echo "--- retry via / remount ---"
    mount -o remount,rw / 2>&1 | sed 's/^/  /'
    cp "$SRC" "$DST" 2>&1 | sed 's/^/  cp2: /'
    echo "new DST md5 (2): $(md5sum "$DST" 2>/dev/null | cut -d' ' -f1)"
  fi

  if command -v chsmack >/dev/null 2>&1; then
    chsmack -a _ "$DST" 2>/dev/null; echo "label: $(chsmack "$DST" 2>/dev/null)"
  fi
  sync
  echo "src md5 (target): $(md5sum "$SRC" | cut -d' ' -f1)"
  echo "--- if DST md5 now == src md5: re-open Owner Tools (reboot if it was already cached). ---"
} > "$OUT" 2>&1
sync
cp "$OUT" /var/log/v2_qmlpatch.txt 2>/dev/null
