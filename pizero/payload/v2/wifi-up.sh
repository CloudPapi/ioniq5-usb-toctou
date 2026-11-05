#!/bin/sh
# v2 owner access: bring up the HU's built-in Broadcom Wi-Fi (wlan0) as a static AP and a
# bundled dropbear SSH server (key-only). Benign; owner's own decommissioned, off-road car.
#
# Field test #3 finding: the first bring-up SUCCEEDS (wlan0 -> 10.42.0.1, dropbear listening),
# but ~90s later the OEM stack (connmand + /app/bin/supplicantmanager + the entropy
# wpa_supplicant) reclaims wlan0 and flips it to STATION mode (DHCP DISCOVER storm in DLT),
# tearing down the AP and the 10.42.0.1 address -> "ssh: connection refused".
#
# Fix: dedicate wlan0 to our AP. Evict the OEM wifi managers from wlan0 and hold it with a
# watchdog that re-asserts the AP + dropbear every 10s. This service is Type=simple and this
# script never exits (the watchdog IS the service). Only the OEM *wifi* path is disturbed.
set +e
exec >>/var/log/wifi-up.log 2>&1
echo "=== wifi-up start $(date -u 2>/dev/null) as $(id) ==="

AP_IP=10.42.0.1
AP_CIDR=10.42.0.1/24

# 0) vendor Wi-Fi gate + rfkill
touch /tmp/no_unece 2>/dev/null
command -v rfkill >/dev/null 2>&1 && rfkill unblock all 2>/dev/null

# 1) driver (BCM4359/CYW89359 via bcmdhd; fw in /lib/firmware/bcmdhd)
modprobe cfg80211 2>/dev/null
[ -e /sys/class/net/wlan0 ] || \
  insmod /lib/modules/4.1.27-abl/kernel/drivers/net/wireless/bcmdhd/bcmdhd.ko 2>/dev/null

# 2) owner public key (key-only; dropbear built with -s = no passwords)
install -d -m 700 /home/root/.ssh 2>/dev/null
cat /etc/dropbear/owner_authorized_keys >> /home/root/.ssh/authorized_keys 2>/dev/null
sort -u /home/root/.ssh/authorized_keys -o /home/root/.ssh/authorized_keys 2>/dev/null
chmod 600 /home/root/.ssh/authorized_keys 2>/dev/null
[ -x /usr/sbin/dropbear ] || ln -sf dropbearmulti /usr/sbin/dropbear 2>/dev/null

# --- helpers -----------------------------------------------------------------
evict_oem_wifi() {
  # stop ConnMan from driving wlan0 as a station; turn off any tether it holds.
  connmanctl tether wifi off  >/dev/null 2>&1
  # kill the OEM station supplicant (entropy build) + the app that drives it.
  # NB: our AP supplicant is matched by 'wpa_ap.conf' and is NOT touched by these patterns.
  pkill -f '/app/bin/supplicantmanager'           2>/dev/null
  pkill -f 'wpa_supplicant -u'                     2>/dev/null
  pkill -f 'wpa_supplicant .* -e /rw_data/wifi'    2>/dev/null
}

ap_up() {
  ip link set wlan0 up 2>/dev/null
  pgrep -f 'wpa_supplicant.*wpa_ap.conf' >/dev/null 2>&1 || \
    /usr/sbin/wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant/wpa_ap.conf 2>/dev/null
  ip addr show wlan0 2>/dev/null | grep -q "${AP_IP}" || \
    ip addr add "${AP_CIDR}" dev wlan0 2>/dev/null
  pgrep -f 'dropbear -R' >/dev/null 2>&1 || \
    /usr/sbin/dropbear -R -s -p 22 2>/dev/null
}

# 3) initial bring-up
evict_oem_wifi
ap_up
echo "=== wifi-up initial bring-up done; entering watchdog ==="
ip addr show wlan0 2>/dev/null | sed -n 's/^/    /p' | head -8

# 4) watchdog: hold wlan0 as our AP (the OEM managers respawn; we re-evict + re-assert)
while true; do
  sleep 10
  evict_oem_wifi
  ap_up
done
