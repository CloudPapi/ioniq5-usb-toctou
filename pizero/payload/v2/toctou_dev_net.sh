#!/bin/sh
# v2 dev-loader: diagnose + open inbound SSH on the Wi-Fi AP. The HU firewalls inbound traffic on
# wlan0, so dropbear (listening) is unreachable from a client. Capture the ruleset, then insert
# ACCEPT at the top of INPUT for wlan0 (and :22), re-assert the AP IP + key, and report.
# Owner's own decommissioned, off-road car.
set +e
STICK_DIR=$(cd "$(dirname "$0")" && pwd)
OUT="$STICK_DIR/v2_net.txt"
KS=/run/owner_ssh
listen22(){ awk 'NR>1{split($2,a,":"); if(a[2]=="0016") print "  "$2" st="$4}' /proc/net/tcp /proc/net/tcp6 2>/dev/null; }
{
  echo "===== v2 network/firewall fix ====="
  echo "when: $(date -u 2>/dev/null)  uptime: $(cut -d. -f1 /proc/uptime 2>/dev/null)s"

  echo "--- wlan0 addr + routes ---"
  ip -o addr show wlan0 2>/dev/null | sed 's/^/  /'
  ip route 2>/dev/null | sed 's/^/  /'

  echo "--- dropbear listening? ---"; listen22 || echo "  (not listening)"

  echo "--- iptables BEFORE ---"
  if command -v iptables >/dev/null 2>&1; then
    echo "  [policy/rules]"; iptables -S 2>/dev/null | sed 's/^/    /'
    echo "  [INPUT counters]"; iptables -L INPUT -n -v 2>/dev/null | head -20 | sed 's/^/    /'
  else echo "  (no iptables binary)"; fi
  command -v nft >/dev/null 2>&1 && { echo "  [nft ruleset]"; nft list ruleset 2>/dev/null | head -40 | sed 's/^/    /'; }

  echo "--- OPEN inbound on wlan0 (insert ACCEPT at top) ---"
  if command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT 1 -i wlan0 -j ACCEPT 2>&1 | sed 's/^/    /'
    iptables -I INPUT 1 -p tcp --dport 22 -j ACCEPT 2>&1 | sed 's/^/    /'
    iptables -I INPUT 1 -p icmp -j ACCEPT 2>&1 | sed 's/^/    /'
    echo "    done"
  fi
  command -v ip6tables >/dev/null 2>&1 && ip6tables -I INPUT 1 -i wlan0 -j ACCEPT 2>/dev/null

  echo "--- re-assert AP IP + dropbear + key ---"
  ip addr show wlan0 2>/dev/null | grep -q '10\.42\.0\.1' || ip addr add 10.42.0.1/24 dev wlan0 2>/dev/null
  pgrep -f 'dropbear -R' >/dev/null 2>&1 || /usr/sbin/dropbear -R -s -p 22 2>/dev/null
  mkdir -p "$KS"; [ -s "$KS/authorized_keys" ] || cat /etc/dropbear/owner_authorized_keys > "$KS/authorized_keys" 2>/dev/null
  chmod 700 "$KS"; chmod 600 "$KS/authorized_keys"
  mount | grep -q '/home/root/.ssh' || mount --bind "$KS" /home/root/.ssh 2>/dev/null

  echo "--- iptables AFTER (INPUT top) ---"; iptables -L INPUT -n 2>/dev/null | head -8 | sed 's/^/    /'
  echo "--- who is associated to the AP (station dump) ---"
  command -v iw >/dev/null 2>&1 && iw dev wlan0 station dump 2>/dev/null | grep -E 'Station|signal|connected' | sed 's/^/    /'
  echo "--- arp (clients seen) ---"; ip neigh 2>/dev/null | sed 's/^/    /'
  echo
  echo ">>> Try now:  ssh -i ~/.ssh/ioniq_toctou_test -o IdentitiesOnly=yes root@10.42.0.1"
} > "$OUT" 2>&1
sync
cp "$OUT" /var/log/v2_net.txt 2>/dev/null
