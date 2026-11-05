#!/bin/sh
# BENIGN dev-loader test. Copy to a FAT/exFAT stick root as 'toctou_dev.sh', plug into the HU.
# Proves the dev-loader ran and can write back. READ-ONLY: starts nothing, changes no config,
# does not touch Wi-Fi/dropbear/QML or the rootfs. Owner's own car.
set +e
TS=$(date -u 2>/dev/null)

# pick a writable destination: the stick dir, else a writable mount, else /tmp
SELF="$0"; DIR=$(dirname "$SELF"); OUT=""
for c in "$DIR" /media/usb /media/* /run/media/*/* /mnt/* /tmp; do
    [ -d "$c" ] || continue
    if ( : > "$c/.wtest" ) 2>/dev/null; then rm -f "$c/.wtest"; OUT="$c/v2_hello.txt"; break; fi
done
[ -n "$OUT" ] || OUT=/tmp/v2_hello.txt

{
    echo "===== v2 dev-loader BENIGN test ====="
    echo "when:   $TS"
    echo "as:     $(id 2>/dev/null)"
    echo "uname:  $(uname -a 2>/dev/null)"
    echo "uptime: $(cut -d. -f1 /proc/uptime 2>/dev/null)s"
    echo "wrote:  $OUT"
    echo "--- harmless status (read-only) ---"
    echo "wlan0:          $([ -e /sys/class/net/wlan0 ] && echo present || echo absent)"
    echo "interfaces:     $(ls /sys/class/net 2>/dev/null | tr '\n' ' ')"
    echo "owner-access:   $(systemctl is-active owner-access.service 2>/dev/null)"
    echo "devloader:      $(systemctl is-active toctou-devloader.service 2>/dev/null)"
    echo "dropbear procs: $(pgrep -c dropbear 2>/dev/null)"
    echo "listen :22:     $(ss -ltn 2>/dev/null | grep -c ':22')"
} > "$OUT" 2>&1

cp "$OUT" /var/log/v2_hello.txt 2>/dev/null
sync
exit 0
