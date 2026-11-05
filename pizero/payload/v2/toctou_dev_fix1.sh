#!/bin/sh
# v2 fix#1 — run via the USB dev-loader (copy to a FAT/exFAT stick ROOT as 'toctou_dev.sh').
# Proves the dev-loader works, diagnoses + attempts to fix Wi-Fi, repositions the Owner Tools
# menu button, (re)starts dropbear, and writes a report back to the stick. Owner's own car.
set +e
TS=$(date -u 2>/dev/null)

# --- find a writable place for the report: the stick dir, else a writable /media/*, else /tmp
SELF="$0"; DIR=$(dirname "$SELF")
REPORT=""
for cand in "$DIR" /media/usb /media/* /run/media/*/* /tmp; do
    [ -d "$cand" ] || continue
    if ( : > "$cand/.wtest" ) 2>/dev/null; then rm -f "$cand/.wtest"; REPORT="$cand/v2_report.txt"; break; fi
done
[ -n "$REPORT" ] || REPORT=/tmp/v2_report.txt
log(){ echo "$@" >> "$REPORT"; }
: > "$REPORT"
log "===== v2 fix#1 report  $TS  as $(id) ====="
log "dev-loader RAN -> writing to $REPORT"
log "uname: $(uname -a 2>/dev/null)"

sec(){ log ""; log "----- $1 -----"; }

sec "interfaces (before)"
log "$(ls /sys/class/net 2>/dev/null | tr '\n' ' ')"
log "$(ip -o link 2>/dev/null; ip -o addr 2>/dev/null)"

sec "wifi driver + firmware"
log "lsmod: $(lsmod 2>/dev/null | grep -Ei 'bcmdhd|cfg80211' | tr '\n' '|')"
log "wlan0 sysfs: $([ -e /sys/class/net/wlan0 ] && echo present || echo MISSING)"
log "fw dir: $(ls /lib/firmware/bcmdhd 2>/dev/null | tr '\n' ' ')"
log "dmesg wlan/bcmdhd (tail):"; log "$(dmesg 2>/dev/null | grep -iE 'bcmdhd|wlan|firmware|nvram' | tail -15)"

sec "connman / supplicantmanager / gates"
log "connman tech: $(connmanctl technologies 2>&1 | tr '\n' '|')"
log "/tmp/no_unece: $([ -e /tmp/no_unece ] && echo present || echo absent)"
log "/tmp/secure_console_disable: $([ -e /tmp/secure_console_disable ] && echo present || echo absent)"
log "supplicantmanager: $(systemctl is-active supplicantmanager.service 2>/dev/null)"
log "connman: $(systemctl is-active connman.service 2>/dev/null)"

sec "our v2 services + files"
log "owner-access: $(systemctl is-active owner-access.service 2>/dev/null) / $(systemctl is-enabled owner-access.service 2>/dev/null)"
log "devloader:    $(systemctl is-active toctou-devloader.service 2>/dev/null) / $(systemctl is-enabled toctou-devloader.service 2>/dev/null)"
log "dropbear bin: $(ls -l /usr/sbin/dropbear /usr/sbin/dropbearmulti 2>/dev/null | tr '\n' '|')"
log "owner dir: $(ls -la /etc/owner 2>/dev/null | tr '\n' '|')"
log "owner-access journal (tail):"; log "$(journalctl -u owner-access.service --no-pager -n 20 2>/dev/null)"

sec "processes / listeners (before)"
log "$(ps w 2>/dev/null | grep -Ei 'dropbear|wpa_supplicant|connmand|hostapd|supplicant' | grep -v grep)"
log "listen :22 -> $(ss -ltn 2>/dev/null | grep -c ':22')"

# ================= FIX ATTEMPTS =================
sec "FIX: wifi bring-up attempts"
modprobe cfg80211 2>>"$REPORT"
[ -e /sys/class/net/wlan0 ] || insmod /lib/modules/4.1.27-abl/kernel/drivers/net/wireless/bcmdhd/bcmdhd.ko 2>>"$REPORT"
command -v rfkill >/dev/null 2>&1 && rfkill unblock all 2>>"$REPORT"
touch /tmp/no_unece 2>/dev/null          # the supplicantmanager region/eng gate
ip link set wlan0 up 2>>"$REPORT"
log "after driver load, wlan0: $([ -e /sys/class/net/wlan0 ] && echo present || echo STILL-MISSING)"
# method 1: ConnMan tethering (stock AP path, has DHCP)
connmanctl enable wifi 2>>"$REPORT"
connmanctl tether wifi on IONIQ5-OWNER ChangeMe-OwnerPSK 2>>"$REPORT"
sleep 3
# method 2: static AP via stock wpa_supplicant if tether gave no IP
if ! ip addr show wlan0 2>/dev/null | grep -q 'inet '; then
    log "tether gave no IP; trying wpa_supplicant AP + static 10.42.0.1"
    [ -f /etc/wpa_supplicant/wpa_ap.conf ] && /usr/sbin/wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant/wpa_ap.conf 2>>"$REPORT"
    ip addr add 10.42.0.1/24 dev wlan0 2>>"$REPORT"
fi

sec "FIX: (re)start dropbear on all interfaces, port 22, key-only"
install -d -m700 /home/root/.ssh 2>/dev/null
cat /etc/dropbear/owner_authorized_keys >> /home/root/.ssh/authorized_keys 2>/dev/null
chmod 600 /home/root/.ssh/authorized_keys 2>/dev/null
pgrep -f 'dropbear -R' >/dev/null 2>&1 || /usr/sbin/dropbear -R -s -p 22 2>>"$REPORT"
log "listen :22 -> $(ss -ltn 2>/dev/null | grep -c ':22')"

sec "FIX: reposition Owner Tools menu button (x:80;y:470 -> x:540;y:380)"
QML=/app/share/AppEngineerMode/qml/AppEngineerMode_FullMain.qml
if [ -f "$QML" ]; then
    mount -o remount,rw / 2>/dev/null; mount -o remount,rw /app 2>/dev/null
    if grep -q 'x:80; y:470' "$QML" 2>/dev/null; then
        sed -i 's/x:80; y:470/x:540; y:380/' "$QML" 2>>"$REPORT" && log "button repositioned (effective after UI restart/reboot)"
    else
        log "pattern 'x:80; y:470' not found in live QML (grep OwnerTools: $(grep -c fullmainButtonOwnerTools "$QML" 2>/dev/null))"
    fi
    log "QML writable now? $([ -w "$QML" ] && echo yes || echo NO-still-ro)"
else
    log "live QML not found at $QML"
fi

sec "interfaces (after)"
log "$(ip -o addr 2>/dev/null | grep -E 'wlan0|inet ')"
log "connman tech (after): $(connmanctl technologies 2>&1 | grep -iE 'wifi|Powered|Tethering|Connected' | tr '\n' '|')"
log "ssid broadcasting? check your laptop for 'IONIQ5-OWNER'"

log ""; log "===== END report. If Wi-Fi is up: ssh -i ioniq_toctou_test root@<ip> (static fallback 10.42.0.1) ====="
# mirror to the HU log too
cp "$REPORT" /var/log/v2_report.txt 2>/dev/null
sync
exit 0
