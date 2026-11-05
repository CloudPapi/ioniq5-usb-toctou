#!/bin/sh
# USB dev-loader (v2): after the one TOCTOU flash, run an owner dev script named 'toctou_dev.sh'
# from a plugged USB stick, as root, each time its contents CHANGE (md5-gated so a left-in stick
# doesn't re-run). ~8s poll => effectively hot-plug; no reboot, no network needed.
# Owner's own decommissioned, off-road car; benign dev convenience.
STATE=/run/toctou_dev.lastmd5
LOG=/var/log/toctou_dev.log
TMPMNT=/run/toctou_usb

run_if_new() {
    s="$1"; [ -f "$s" ] || return 1
    m=$(md5sum "$s" 2>/dev/null | cut -d' ' -f1); [ -n "$m" ] || return 1
    [ "$m" = "$(cat "$STATE" 2>/dev/null)" ] && return 1    # unchanged -> skip
    echo "=== $(date -u 2>/dev/null) run $s md5=$m ===" >> "$LOG"
    sh "$s" >> "$LOG" 2>&1
    echo "$m" > "$STATE"
    return 0
}

scan_mounts() {    # the HU auto-mounts USB; check the usual mount roots
    # the HU auto-mounts USB at /media/usb/<N>/<VOLID>/ (e.g. /media/usb/1/F851-D951/) — two
    # levels deep. Cover that plus the shallower/alternate roots.
    for s in /media/usb/*/*/toctou_dev.sh /media/usb/*/toctou_dev.sh \
             /media/usb/toctou_dev.sh /media/*/toctou_dev.sh \
             /run/media/*/toctou_dev.sh /run/media/*/*/toctou_dev.sh /mnt/*/toctou_dev.sh; do
        run_if_new "$s" && return 0
    done
    return 1
}

scan_raw() {       # fallback: mount an unmounted USB partition read-only and check
    for d in /dev/sd?1 /dev/sd?; do
        [ -b "$d" ] || continue
        grep -q "^$d " /proc/mounts && continue
        mkdir -p "$TMPMNT" 2>/dev/null
        mount -o ro "$d" "$TMPMNT" 2>/dev/null || continue
        run_if_new "$TMPMNT/toctou_dev.sh"; r=$?
        umount "$TMPMNT" 2>/dev/null
        [ "$r" = 0 ] && return 0
    done
    return 1
}

while true; do
    scan_mounts || scan_raw
    sleep 8
done
