#!/bin/sh
# v2 dev-loader: DEFINITIVE read-only probe of the HU's Apple CarPlay state, to determine the
# safest way to enable WIRELESS CarPlay. Changes NOTHING. Owner's own decommissioned, off-road car.
#
# Captures: advertised iAP2 transports (IdentificationConfig), the wireless gate persistence key
# + its value + store format, the D-Bus persistence/profile interface (the supported setter),
# vehicle variant/country, MFi auth chip, Wi-Fi AP/5GHz capability, Bluetooth profiles, carplay
# services, and CarPlay/transport negotiation in the logs.
set +e
STICK_DIR=$(cd "$(dirname "$0")" && pwd)
OUT="$STICK_DIR/v2_carplay.txt"
D=/app/data/AppProjection/config
KEY=APP_BT_PP_WIRELESS_CONNECTION_ENABLE
PSTORES="/app/data /var /rw_data /persistency /persistence /app/data/persistency"
{
  echo "===== v2 CarPlay wireless-gate probe (READ-ONLY) ====="
  echo "when: $(date -u 2>/dev/null)  uptime: $(cut -d. -f1 /proc/uptime 2>/dev/null)s"

  echo; echo "########## 1. ADVERTISED TRANSPORTS (the gate's output) ##########"
  echo "--- /app writable? ---"; mount 2>/dev/null | grep -E ' /app| /app/data' | sed 's/^/  /'
  echo "  write-test $D:"; if touch "$D/.wtest" 2>/dev/null; then echo "    WRITABLE"; rm -f "$D/.wtest"; else echo "    read-only/missing"; fi
  echo "--- full /app/data/AppProjection tree ---"; ls -laR /app/data/AppProjection 2>/dev/null | sed 's/^/  /' | head -60
  for f in IdentificationConfig IdentificationConfig_IPOD; do
    echo "--- $f : transport markers ---"
    strings -n 3 "$D/$f" 2>/dev/null | grep -iE 'wireless|bluetooth|usbhost|usbdevice|usb|serial|transport|carplay|ncm' | sed 's/^/    /'
    echo "  (hexdump head)"; hexdump -C "$D/$f" 2>/dev/null | head -24 | sed 's/^/    /'
  done

  echo; echo "########## 2. THE WIRELESS GATE KEY ($KEY) ##########"
  echo "--- files containing the key (on writable storage) ---"
  grep -rilE "APP_BT_PP_(WIRELESS|USB)_CONNECTION_ENABLE" $PSTORES 2>/dev/null | head -20 | sed 's/^/  /'
  echo "--- value context around the key ---"
  for p in $PSTORES; do grep -raoE "APP_BT_PP_(WIRELESS|USB)_CONNECTION_ENABLE.{0,48}" "$p" 2>/dev/null | head -8 | sed 's/^/  /'; done
  echo "--- persistence store files (dump format+value) ---"
  for F in $(find $PSTORES 2>/dev/null -maxdepth 5 \( -iname '*persist*' -o -iname '*.pers' -o -iname '*kvs*' -o -iname '*.itz' -o -iname '*connectivit*' -o -iname '*projection*cfg*' \) 2>/dev/null | grep -ivE '\.png$|/images/' | head -12); do
    echo "  == $F ($(ls -l "$F" 2>/dev/null | awk '{print $5}') b) =="
    strings -n 3 "$F" 2>/dev/null | grep -iE 'APP_BT_PP|wireless|carplay|projection|usb_connection' | sed 's/^/    /' | head -10
  done

  echo; echo "########## 3. D-BUS persistence/profile interface (the supported SETTER) ##########"
  if command -v busctl >/dev/null 2>&1; then
    echo "--- services (profilemanager/persistence/projection) ---"
    busctl list 2>/dev/null | grep -iE 'profilemanager|persist|projection|connectivit|setting' | sed 's/^/  /'
    echo "--- introspect com.lge.car.profilemanager ---"
    busctl introspect com.lge.car.profilemanager / 2>/dev/null | grep -iE 'setting|connect|persist|method' | head -20 | sed 's/^/  /'
  elif command -v dbus-send >/dev/null 2>&1; then
    echo "  (busctl absent; dbus-send present) services:"
    dbus-send --system --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ListNames 2>/dev/null | grep -iE 'profilemanager|persist|projection|connect' | sed 's/^/  /'
  else echo "  (no busctl/dbus-send)"; fi

  echo; echo "########## 4. VEHICLE VARIANT / COUNTRY (CarPlay built off EVehicleVariants/ECountryVariant) ##########"
  for f in $(find /app/data /rw_data 2>/dev/null -maxdepth 3 \( -iname '*variant*' -o -iname '*spec*' -o -iname '*vehicle*' \) 2>/dev/null | grep -ivE '\.png|/images/' | head -10); do
    echo "  == $f =="; strings -n 3 "$f" 2>/dev/null | head -15 | sed 's/^/    /'
  done
  dmesg 2>/dev/null | grep -iE 'variant|GW_HU_PE|cDATC|country' | tail -10 | sed 's/^/  /'

  echo; echo "########## 5. CarPlay on at all? (profile carPlayOnOffSet) ##########"
  for d in 0 1 2; do F=/app/data/UserProfileManager/data/systemSetup_Driver${d}.json
    [ -f "$F" ] && { echo "  Driver$d:"; base64 -d "$F" 2>/dev/null | grep -iA6 phoneProjection | sed 's/^/    /'; }; done

  echo; echo "########## 6. MFi auth coprocessor ##########"
  ls -l /dev/i2c-* 2>/dev/null | sed 's/^/  /'
  command -v i2cdetect >/dev/null 2>&1 && { echo "  i2cdetect bus1:"; i2cdetect -y -r 1 2>/dev/null | sed 's/^/    /'; }

  echo; echo "########## 7. Wi-Fi: AP mode + 5GHz (wireless CarPlay needs HU to run a 5GHz AP) ##########"
  if command -v iw >/dev/null 2>&1; then
    echo "--- supported interface modes (need AP) ---"; iw phy 2>/dev/null | sed -n '/Supported interface modes/,/Band /p' | sed 's/^/  /' | head -20
    echo "--- 5GHz channels present? ---"; iw phy 2>/dev/null | grep -E '5[0-9]{3} MHz|Band 2' | head -8 | sed 's/^/  /'
    iw dev 2>/dev/null | sed 's/^/  /'
  else echo "  (no iw)"; fi

  echo; echo "########## 8. Bluetooth (iAP2-over-BT handshake carrier) ##########"
  ls /sys/class/bluetooth 2>/dev/null | sed 's/^/  /'
  command -v hciconfig >/dev/null 2>&1 && hciconfig -a 2>/dev/null | head -12 | sed 's/^/  /'
  command -v sdptool >/dev/null 2>&1 && { echo "  local SDP services:"; sdptool browse local 2>/dev/null | grep -iE 'Service Name|iAP|CarPlay|Apple' | head | sed 's/^/    /'; }

  echo; echo "########## 9. services + procs ##########"
  for s in carplay_iAP2 carplay_mdnsd; do echo "  $s: $(systemctl is-active $s 2>/dev/null)/$(systemctl is-enabled $s 2>/dev/null)"; done
  for d in /proc/[0-9]*; do c=$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null); case "$c" in *iAP2*|*mdnsd*|*Projection*|*profilemanager*|*persist*) echo "  ${d#/proc/}: $c";; esac; done

  echo; echo "########## 10. logs: carplay/iap2/wireless/transport negotiation + variant ##########"
  for L in /var/log/messages /var/log/appprojection* /var/log/*.log; do
    [ -f "$L" ] && grep -aiE 'carplay|iap2|wireless|WirelessCarPlay|transport|APP_BT_PP|variant' "$L" 2>/dev/null | tail -15 | sed "s#^#  [$L] #"; done
  dmesg 2>/dev/null | grep -iE 'iap2|carplay|ncm|i2c-1|mfi|extcon' | tail -15 | sed 's/^/  /'
} > "$OUT" 2>&1
sync
cp "$OUT" /var/log/v2_carplay.txt 2>/dev/null
