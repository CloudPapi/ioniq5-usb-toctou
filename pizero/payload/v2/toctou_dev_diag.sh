#!/bin/sh
# v2 dev-loader DIAGNOSTIC (read-only): settle the "listen :22: 0" question without depending on
# ss/netstat (parse /proc/net/tcp directly), and dump the live AP/dropbear/wifi-up state.
# Benign: reads only; starts/changes nothing. Owner's own decommissioned, off-road car.
set +e
STICK_DIR=$(cd "$(dirname "$0")" && pwd)
OUT="$STICK_DIR/v2_diag.txt"
{
  echo "===== v2 dev-loader DIAGNOSTIC ====="
  echo "when:   $(date -u 2>/dev/null)"
  echo "uptime: $(cut -d. -f1 /proc/uptime 2>/dev/null)s"
  echo

  echo "--- tools present? ---"
  for t in ss netstat ip dropbear wpa_supplicant connmanctl pgrep; do
    p=$(command -v "$t" 2>/dev/null); echo "  $t: ${p:-MISSING}"
  done
  echo

  echo "--- dropbear processes (full cmdline) ---"
  for d in /proc/[0-9]*; do
    c=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)
    case "$c" in *dropbear*) echo "  pid ${d#/proc/}: $c";; esac
  done
  echo

  echo "--- LISTENers on :22 via /proc/net/tcp (port 22 = hex 0016, state 0A=LISTEN) ---"
  # columns: sl local_address rem_address st ...  ; local_address = HEXIP:HEXPORT
  awk 'NR>1{split($2,a,":"); if(a[2]=="0016") print "  tcp  "$2"  state="$4" (0A=LISTEN)"}' /proc/net/tcp  2>/dev/null
  awk 'NR>1{split($2,a,":"); if(a[2]=="0016") print "  tcp6 "$2"  state="$4" (0A=LISTEN)"}' /proc/net/tcp6 2>/dev/null
  echo "  (no line above = nothing bound to :22)"
  echo

  echo "--- wlan0 address ---"
  if command -v ip >/dev/null 2>&1; then ip addr show wlan0 2>/dev/null | sed 's/^/  /'
  else cat /proc/net/fib_trie 2>/dev/null | grep -A1 '10.42.0' | sed 's/^/  /'; fi
  echo

  echo "--- our AP wpa_supplicant running? ---"
  for d in /proc/[0-9]*; do c=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null); case "$c" in *wpa_ap.conf*) echo "  pid ${d#/proc/}: $c";; esac; done
  echo

  echo "--- OEM wifi stack still alive (watchdog should be killing these)? ---"
  for d in /proc/[0-9]*; do c=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null); case "$c" in *supplicantmanager*|*"wpa_supplicant -u"*) echo "  pid ${d#/proc/}: $c";; esac; done
  echo

  echo "--- /var/log/wifi-up.log (tail 40) ---"
  tail -n 40 /var/log/wifi-up.log 2>/dev/null | sed 's/^/  /' || echo "  (none)"
  echo
  echo "--- authorized_keys installed? ---"
  wc -l /home/root/.ssh/authorized_keys 2>/dev/null | sed 's/^/  /'
  head -c 80 /home/root/.ssh/authorized_keys 2>/dev/null | sed 's/^/  /'; echo
} > "$OUT" 2>&1
sync
cp "$OUT" /var/log/v2_diag.txt 2>/dev/null
