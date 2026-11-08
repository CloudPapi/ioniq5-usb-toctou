#!/bin/sh
# v2 dev-loader: make SSH-over-Wi-Fi work by fixing the ENVIRONMENT so the baked watchdog's own
# `dropbear -R` succeeds (instead of fighting it). Idempotent; effects last until reboot.
#   1) open inbound :22 on wlan0 (vendor INPUT policy DROP)
#   2) bind-mount a writable /etc/dropbear (tmpfs) holding a pre-generated ed25519 host key, so
#      dropbear -R finds a key instead of failing to write one to read-only /etc
#   3) bind-mount a clean 700 /home/root with authorized_keys 600 (dropbear rejects key auth if
#      ~ or ~/.ssh is group/other-writable; image /home/root is 775)
#   4) (re)start dropbear -R with -E logging so any auth rejection reason is captured
# FIX runs first (applies even if the stick is pulled before the report writes).
set +e
STICK_DIR=$(cd "$(dirname "$0")" && pwd)
OUT="$STICK_DIR/v2_sshall.txt"
DBM=/usr/sbin/dropbearmulti; [ -x "$DBM" ] || DBM=/usr/sbin/dropbear
ED=/run/etcdb; RH=/run/roothome; LOG=/run/dropbear.log
PUB='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOYQcDHxjT557d3h5wfnt2Izz0N/jtlvpNNlhpFHtdCD owner-test'

# ---------- FIX FIRST ----------
# 1) firewall
iptables -C INPUT -i wlan0 -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -i wlan0 -j ACCEPT 2>/dev/null
iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p tcp --dport 22 -j ACCEPT 2>/dev/null

# 2) writable /etc/dropbear with a real host key
mkdir -p "$ED"
cp -a /etc/dropbear/. "$ED/" 2>/dev/null
[ -s "$ED/dropbear_ed25519_host_key" ] || "$DBM" dropbearkey -t ed25519 -f "$ED/dropbear_ed25519_host_key" >/dev/null 2>&1
chmod 600 "$ED/dropbear_ed25519_host_key" 2>/dev/null
mountpoint -q /etc/dropbear 2>/dev/null || mount --bind "$ED" /etc/dropbear 2>/dev/null

# 3) clean 700 root home with authorized_keys (key only, no comments)
mkdir -p "$RH/.ssh"
grep -h '^ssh-' /etc/dropbear/owner_authorized_keys 2>/dev/null > "$RH/.ssh/authorized_keys"
[ -s "$RH/.ssh/authorized_keys" ] || printf '%s\n' "$PUB" > "$RH/.ssh/authorized_keys"
chown -R 0:0 "$RH" 2>/dev/null; chmod 700 "$RH" "$RH/.ssh"; chmod 600 "$RH/.ssh/authorized_keys"
umount /home/root/.ssh 2>/dev/null
mountpoint -q /home/root 2>/dev/null || mount --bind "$RH" /home/root 2>/dev/null

# 4) wlan0 + dropbear -R with -E logging (matches watchdog's 'dropbear -R' so it won't start a rival)
ip addr show wlan0 2>/dev/null | grep -q '10\.42\.0\.1' || ip addr add 10.42.0.1/24 dev wlan0 2>/dev/null
pkill -f dropbear 2>/dev/null; sleep 1
setsid "$DBM" dropbear -R -s -p 22 -E -F >"$LOG" 2>&1 &
sleep 2
sync

# ---------- REPORT ----------
{
  echo "===== v2 SSH all-in-one (env fix) ====="
  echo "when: $(date -u 2>/dev/null)  uptime: $(cut -d. -f1 /proc/uptime 2>/dev/null)s"
  echo "--- /etc/dropbear (bind) ---"; mount | grep -F /etc/dropbear | sed 's/^/  /'; ls -l /etc/dropbear 2>/dev/null | sed 's/^/  /'
  echo "--- /home/root (bind, want 700) ---"; ls -ld /home/root /home/root/.ssh 2>/dev/null | sed 's/^/  /'
  echo "  authorized_keys: $(ls -l /home/root/.ssh/authorized_keys 2>/dev/null)"
  echo "  key: $(cat /home/root/.ssh/authorized_keys 2>/dev/null | cut -c1-48)..."
  echo "--- firewall INPUT top ---"; iptables -L INPUT -n 2>/dev/null | head -4 | sed 's/^/  /'
  echo "--- dropbear procs ---"; for d in /proc/[0-9]*; do c=$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null); case "$c" in *dropbear*) echo "  ${d#/proc/}: $c";; esac; done
  echo "--- listening :22 ---"; awk 'NR>1{split($2,a,":"); if(a[2]=="0016") print "  "$2" st="$4}' /proc/net/tcp /proc/net/tcp6 2>/dev/null
  echo "--- dropbear.log (auth attempts so far) ---"; tail -n 20 "$LOG" 2>/dev/null | sed 's/^/  /'
  echo
  echo ">>> ssh -i ~/.ssh/ioniq_toctou_test -o IdentitiesOnly=yes root@10.42.0.1"
} > "$OUT" 2>&1
sync
cp "$OUT" /var/log/v2_sshall.txt 2>/dev/null
