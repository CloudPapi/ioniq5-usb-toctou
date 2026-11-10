#!/bin/sh
# v2 dev-loader: SSH root-cause FIX + full SMACK diagnosis. Owner's own decommissioned HU.
#
# ROOT CAUSE (from offline rootfs analysis, docs/08):
#   The earlier chain bind-mounted a tmpfs over /home/root. That gave authorized_keys a tmpfs
#   SMACK label the dropbear process could not read. With onlycap=Privileged, a root process that
#   is NOT labeled "Privileged" cannot use CAP_MAC_OVERRIDE, so SMACK denied dropbear's open() of
#   the keyfile. Our dropbear build has no DEBUG_TRACE, so that EACCES is logged NOWHERE ->
#   silent "Permission denied (publickey)". Perms/shell fixes were irrelevant: the key was
#   simply unreadable to the server.
#
# THIS SCRIPT (changes are runtime/tmpfs only; nothing on /app or /rw_data is disturbed):
#   - drops the bind-mounts entirely;
#   - redirects root's home (via /tmp/passwd, a writable tmpfs symlink target) to a dir we fully
#     own on /run, and floor-labels (_) the key chain so ANY subject can read it;
#   - runs dropbear from a /run copy marked SMACK64EXEC=Privileged (so it bypasses SMACK even if
#     we cannot self-elevate);
#   - captures the exact on-device SMACK facts (self label, onlycap, path labels, writability)
#     so build #7 can be baked correctly if the runtime path is blocked by privilege.
set +e
STICK=$(cd "$(dirname "$0")" && pwd)
OUT="$STICK/v2_sshfix.txt"
RH=/run/sshroot                 # our controlled root home (tmpfs, we own the labels)
DBIN=/run/db_dropbear           # our dropbear copy
HK=/run/db_hostkey              # host key
LOG=/run/db.log                 # dropbear stderr (the existing dblog collector reads this)
PUB='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOYQcDHxjT557d3h5wfnt2Izz0N/jtlvpNNlhpFHtdCD ioniq-toctou-test'
{
  echo "===== v2 SSH fix + SMACK diag  $(date -u 2>/dev/null)  up $(cut -d. -f1 /proc/uptime 2>/dev/null)s ====="

  echo; echo "########## A. SMACK ENVIRONMENT (the diagnosis) ##########"
  echo "  self attr/current : $(cat /proc/self/attr/current 2>/dev/null)"
  echo "  onlycap           : $(cat /sys/fs/smackfs/onlycap 2>/dev/null)"
  echo "  bringup-switch    : $(cat /sys/fs/smackfs/bringup-switch 2>/dev/null)"
  echo "  optUNECE          : $(cat /sys/module/micom/parameters/optUNECE 2>/dev/null)"
  echo "  uid=$(id -u 2>/dev/null)  $(grep -E 'CapEff|CapBnd' /proc/self/status 2>/dev/null | tr '\n' ' ')"
  echo "  chsmack           : $(command -v chsmack 2>/dev/null || echo MISSING)"
  echo "  -- SMACK labels of key paths --"
  for p in / /home /home/root /home/root/.ssh /home/root/.ssh/authorized_keys /tmp /tmp/passwd /run /var /etc/dropbear /media/usb; do
    printf '    %-34s ' "$p"; chsmack "$p" 2>/dev/null || echo "(missing)"
  done
  echo "  -- passwd resolution --"
  PW=$(readlink -f /etc/passwd 2>/dev/null); echo "    /etc/passwd -> $PW"
  echo "    root line   : $(grep '^root:' "$PW" 2>/dev/null)"
  echo "    getent root : $(getent passwd root 2>/dev/null)"
  echo "  -- writability probes --"
  ( touch /home/root/.wtest 2>/dev/null && echo "    /home/root  : WRITABLE" && rm -f /home/root/.wtest ) || echo "    /home/root  : denied (SMACK or ro)"
  ( touch "$PW.wtest" 2>/dev/null && echo "    $PW : WRITABLE" && rm -f "$PW.wtest" ) || echo "    $PW : denied"
  echo "  -- mounts (home/var/root) --"; mount 2>/dev/null | grep -E 'rw_data|/home | / |/var ' | sed 's/^/    /'

  echo; echo "########## B. try to self-elevate to Privileged ##########"
  if echo Privileged > /proc/self/attr/current 2>/dev/null; then
    PRIV=1; echo "  self -> Privileged: OK  (now $(cat /proc/self/attr/current 2>/dev/null))"
  else
    PRIV=0; echo "  self -> Privileged: FAILED (not Privileged + onlycap gate). Continuing with floor-label path."
  fi

  echo; echo "########## C. root shell + home via /tmp/passwd (tmpfs, NO bind-mount) ##########"
  if [ -n "$PW" ] && [ -w "$PW" ]; then
    cp "$PW" "$PW.bak" 2>/dev/null
    sed -i "s#^root:.*#root:x:0:0:root:$RH:/bin/sh#" "$PW" && echo "  rewrote root: home=$RH shell=/bin/sh" || echo "  sed failed"
    echo "    now: $(grep '^root:' "$PW")"
  else
    echo "  $PW not writable -> cannot set shell/home at runtime (must bake in build #7)"
  fi

  echo; echo "########## D. authorized_keys where dropbear can READ it ##########"
  mkdir -p "$RH/.ssh" 2>/dev/null
  printf '%s\n' "$PUB" > "$RH/.ssh/authorized_keys" 2>/dev/null && echo "  wrote $RH/.ssh/authorized_keys" || echo "  FAILED writing $RH/.ssh/authorized_keys"
  chmod 700 "$RH" "$RH/.ssh" 2>/dev/null; chmod 600 "$RH/.ssh/authorized_keys" 2>/dev/null; chown -R 0:0 "$RH" 2>/dev/null
  # floor (_) so ANY subject (incl. dropbear's label) may read it — SMACK built-in: all can read floor
  if chsmack -a _ "$RH" "$RH/.ssh" "$RH/.ssh/authorized_keys" 2>/dev/null; then echo "  floor-labeled the $RH key chain"; else echo "  chsmack on $RH FAILED (ak label = $(chsmack "$RH/.ssh/authorized_keys" 2>/dev/null))"; fi
  echo "  -- resulting key chain --"; ls -la "$RH/.ssh" 2>/dev/null | sed 's/^/    /'; printf '    label: '; chsmack "$RH/.ssh/authorized_keys" 2>/dev/null

  echo; echo "########## E. firewall: accept :22 on wlan0 ##########"
  iptables -I INPUT 1 -i wlan0 -j ACCEPT 2>/dev/null && echo "  INPUT accept wlan0" || echo "  iptables wlan0 failed"
  iptables -I INPUT 1 -p tcp --dport 22 -j ACCEPT 2>/dev/null

  echo; echo "########## F. dropbear: Privileged copy, our host key, logging ##########"
  SRC=""; for c in "$STICK/dropbearmulti" /usr/sbin/dropbearmulti /usr/sbin/dropbear /app/*/dropbearmulti /app/*/*/dropbearmulti; do [ -f "$c" ] && SRC="$c" && break; done
  if [ -n "$SRC" ]; then cp "$SRC" "$DBIN" 2>/dev/null && chmod 755 "$DBIN" && echo "  dropbear copied from $SRC"; else echo "  !! dropbearmulti NOT FOUND — put it on the stick next to this script"; fi
  if chsmack -e Privileged "$DBIN" 2>/dev/null; then echo "  SMACK64EXEC=Privileged set on $DBIN (will bypass SMACK)"; else echo "  could not set SMACK64EXEC (exec label stays $(chsmack "$DBIN" 2>/dev/null))"; fi
  "$DBIN" dropbearkey -t ed25519 -f "$HK" > /run/db_keygen.log 2>&1 && echo "  host key generated" || { echo "  keygen FAILED:"; sed 's/^/    /' /run/db_keygen.log 2>/dev/null; }
  for pid in $(pidof dropbear dropbearmulti db_dropbear 2>/dev/null); do kill "$pid" 2>/dev/null; done
  : > "$LOG"
  ( "$DBIN" dropbear -F -r "$HK" -p 22 ) >> "$LOG" 2>&1 &
  DBPID=$!
  sleep 2
  if kill -0 "$DBPID" 2>/dev/null; then
    echo "  dropbear RUNNING pid $DBPID (label $(cat /proc/$DBPID/attr/current 2>/dev/null))"
  else
    echo "  dropbear EXITED early — log:"; sed 's/^/    /' "$LOG" 2>/dev/null
  fi
  echo "  :22 listening? $(awk '$2 ~ /:0016$/ {print "YES"; exit}' /proc/net/tcp 2>/dev/null)"

  echo; echo "########## G. NEXT STEPS ##########"
  echo "  1) From the workstation (AP IONIQ5-OWNER / 10.42.0.1):"
  echo "       ssh -i ~/.ssh/ioniq_toctou_test -o IdentitiesOnly=yes root@10.42.0.1"
  echo "  2) If it drops you to a shell -> DONE."
  echo "  3) If not: do NOT reboot. Plug the dblog collector (toctou_dev_dblog.sh, different md5)"
  echo "     to pull $LOG — it holds dropbear's server-side reason for that attempt."
  echo
  echo "  -- current $LOG (pre-attempt) --"; sed 's/^/    /' "$LOG" 2>/dev/null
} > "$OUT" 2>&1
sync
cp "$OUT" /var/log/v2_sshfix.txt 2>/dev/null
cp "$LOG" "$STICK/v2_dblog.txt" 2>/dev/null
