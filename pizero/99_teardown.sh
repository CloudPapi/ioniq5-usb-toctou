#!/bin/bash
# Unwind 03_deploy_gadget.sh in reverse. Safe to run repeatedly.
set +e
GADGET=/sys/kernel/config/usb_gadget/ioniq_toctou

echo "[*] unbinding UDC"
[ -f "$GADGET/UDC" ] && echo "" > "$GADGET/UDC"

echo "[*] removing gadget configfs tree"
if [ -d "$GADGET" ]; then
    rm -f  "$GADGET/configs/c.1/mass_storage.0"
    rmdir  "$GADGET/configs/c.1/strings/0x409" 2>/dev/null
    rmdir  "$GADGET/configs/c.1"               2>/dev/null
    rmdir  "$GADGET/functions/mass_storage.0"  2>/dev/null
    rmdir  "$GADGET/strings/0x409"             2>/dev/null
    rmdir  "$GADGET"                           2>/dev/null
fi

echo "[*] detaching /dev/nbd0"
nbd-client -d /dev/nbd0 2>/dev/null

echo "[*] stopping nbdkit"
[ -f /run/toctou-nbdkit.pid ] && kill "$(cat /run/toctou-nbdkit.pid)" 2>/dev/null
rm -f /run/toctou-nbdkit.pid

echo "[DONE] torn down."
