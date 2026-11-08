#!/bin/sh
# v2 dev-loader: collect dropbear's own stderr log (/run/db.log) which now contains the auth
# decision from the last ssh attempt. Read-only. Owner's own decommissioned, off-road car.
set +e
STICK_DIR=$(cd "$(dirname "$0")" && pwd)
OUT="$STICK_DIR/v2_dblog.txt"
{
  echo "===== v2 dropbear log collect ====="
  echo "when: $(date -u 2>/dev/null)  uptime: $(cut -d. -f1 /proc/uptime 2>/dev/null)s"
  echo "--- dropbear procs (is the -F logging one still up?) ---"
  for d in /proc/[0-9]*; do c=$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null); case "$c" in *dropbear*) echo "  ${d#/proc/}: $c";; esac; done
  echo "--- root passwd (shell) ---"; grep '^root:' /etc/passwd 2>/dev/null | sed 's/^/  /'
  echo "--- /home/root/.ssh ---"; ls -ld /home/root/.ssh 2>/dev/null | sed 's/^/  /'; ls -l /home/root/.ssh/authorized_keys 2>/dev/null | sed 's/^/  /'
  echo
  echo "===== /run/db.log (FULL — dropbear stderr incl. your ssh attempt) ====="
  cat /run/db.log 2>/dev/null | sed 's/^/  /' || echo "  (no /run/db.log — HU may have rebooted since the fix)"
  echo
  echo "===== /var/log/wifi-up.log : dropbear-related lines ====="
  grep -aiE 'dropbear|auth|pubkey|public key|permission|bad owner|exit before|login|shell' /var/log/wifi-up.log 2>/dev/null | tail -n 40 | sed 's/^/  /'
} > "$OUT" 2>&1
sync
cp "$OUT" /var/log/v2_dblog.txt 2>/dev/null
