#!/bin/sh
# v2 dev-loader: root's shell is /usr/sbin/nologin -> dropbear denies login. Bind-mount a patched
# /etc/passwd giving root /bin/sh, (re)assert the host key, 700 home+key, firewall, and start a
# foreground dropbear logging to /run/db.log (dropbear has no syslog -> logs to stderr) so any
# remaining auth reason is captured. Owner's own decommissioned, off-road car.
set +e
STICK_DIR=$(cd "$(dirname "$0")" && pwd)
OUT="$STICK_DIR/v2_shell.txt"
DBM=/usr/sbin/dropbearmulti; [ -x "$DBM" ] || DBM=/usr/sbin/dropbear
ED=/run/etcdb; RH=/run/roothome; PW=/run/passwd; LOG=/run/db.log
PUB='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOYQcDHxjT557d3h5wfnt2Izz0N/jtlvpNNlhpFHtdCD owner-test'

# ---- FIX FIRST ----
# 1) patched /etc/passwd: root shell -> /bin/sh (replace the last field of the root line)
sed 's#^\(root:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:\)[^:]*$#\1/bin/sh#' /etc/passwd > "$PW" 2>/dev/null
chmod 644 "$PW"; chown 0:0 "$PW" 2>/dev/null
grep -q '^root:.*:/bin/sh$' "$PW" && mount --bind "$PW" /etc/passwd 2>/dev/null

# 2) firewall
iptables -C INPUT -i wlan0 -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -i wlan0 -j ACCEPT 2>/dev/null
iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p tcp --dport 22 -j ACCEPT 2>/dev/null

# 3) writable /etc/dropbear with a host key
mkdir -p "$ED"; cp -a /etc/dropbear/. "$ED/" 2>/dev/null
[ -s "$ED/dropbear_ed25519_host_key" ] || "$DBM" dropbearkey -t ed25519 -f "$ED/dropbear_ed25519_host_key" >/dev/null 2>&1
chmod 600 "$ED/dropbear_ed25519_host_key" 2>/dev/null
mountpoint -q /etc/dropbear 2>/dev/null || mount --bind "$ED" /etc/dropbear 2>/dev/null

# 4) 700 root home + key
mkdir -p "$RH/.ssh"; grep -h '^ssh-' /etc/dropbear/owner_authorized_keys 2>/dev/null > "$RH/.ssh/authorized_keys"
[ -s "$RH/.ssh/authorized_keys" ] || printf '%s\n' "$PUB" > "$RH/.ssh/authorized_keys"
chown -R 0:0 "$RH" 2>/dev/null; chmod 700 "$RH" "$RH/.ssh"; chmod 600 "$RH/.ssh/authorized_keys"
mountpoint -q /home/root 2>/dev/null || mount --bind "$RH" /home/root 2>/dev/null

# 5) wlan0 + logging dropbear (-F keeps stderr open to the log; matches watchdog 'dropbear -R')
ip addr show wlan0 2>/dev/null | grep -q '10\.42\.0\.1' || ip addr add 10.42.0.1/24 dev wlan0 2>/dev/null
pkill -f dropbear 2>/dev/null; sleep 1
setsid "$DBM" dropbear -R -s -p 22 -F >"$LOG" 2>&1 &
sleep 2
sync

# ---- REPORT ----
{
  echo "===== v2 shell/auth fix ====="
  echo "when: $(date -u 2>/dev/null)  uptime: $(cut -d. -f1 /proc/uptime 2>/dev/null)s"
  echo "root passwd now: $(grep '^root:' /etc/passwd)"
  echo "mounts: "; mount | grep -E '/etc/passwd|/etc/dropbear|/home/root' | sed 's/^/  /'
  echo "home: $(ls -ld /home/root/.ssh 2>/dev/null); ak $(ls -l /home/root/.ssh/authorized_keys 2>/dev/null | awk '{print $1,$3,$4}')"
  echo "listening :22:"; awk 'NR>1{split($2,a,":"); if(a[2]=="0016") print "  "$2" st="$4}' /proc/net/tcp /proc/net/tcp6 2>/dev/null
  echo "dropbear procs:"; for d in /proc/[0-9]*; do c=$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null); case "$c" in *dropbear*) echo "  ${d#/proc/}: $c";; esac; done
  echo "--- /run/db.log (auth attempts captured here after you try ssh) ---"; tail -n 25 "$LOG" 2>/dev/null | sed 's/^/  /'
  echo
  echo ">>> ssh -i ~/.ssh/ioniq_toctou_test -o IdentitiesOnly=yes root@10.42.0.1"
} > "$OUT" 2>&1
sync
cp "$OUT" /var/log/v2_shell.txt 2>/dev/null
