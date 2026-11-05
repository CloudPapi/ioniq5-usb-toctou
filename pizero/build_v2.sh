#!/bin/bash
# build_v2.sh — build a v2 evil mango-rootfs TE2 envelope for the owner's OWN decommissioned
# IONIQ 5, with a browsable on-HU Owner Tools menu + built-in-Wi-Fi AP + bundled dropbear SSH.
# Benign (owner-keyed SSH + log/firewall helpers). No OEM private key used.
#
#   ./build_v2.sh menu|foothold  <genuine_mango.(te2|tar.gz)>  [out_te2]
#
# Needs: TE2_CONTENT_KEY or pizero/key.local; gen5w_decrypt.py + te2_encrypt.py (this dir);
#        payload/bin/dropbearmulti (static x86-64 — see v2 README "dropbear binary");
#        payload/v2/* ; payload/authorized_keys (owner pubkey).
# Proven: recompressing at gzip -9 yields ~2.0-2.5 MB headroom under the 879,109,759 ceiling,
# which absorbs the additions (see v2 README "fit proof"). We assert the ceiling before encrypt.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CEIL=879109759                                   # genuine plaintext body = hard ceiling
MODE="${1:?usage: build_v2.sh menu|foothold <genuine> [out]}"
GEN="${2:?need genuine mango (.te2 or .tar.gz)}"
OUT="${3:-$HERE/build/evil_rootfs_${MODE}.te2}"
P="$HERE/payload"; V="$P/v2"; DB="$P/bin/dropbearmulti"
GEN5W="$HERE/gen5w_decrypt.py"; TE2="$HERE/te2_encrypt.py"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
say(){ echo "[v2] $*"; }

[ "$MODE" = menu ] || [ "$MODE" = foothold ] || { echo "mode must be menu|foothold"; exit 2; }
[ -s "$DB" ] || { echo "MISSING $DB — build the static dropbearmulti first (see v2 README)"; exit 1; }
[ -s "$P/authorized_keys" ] || { echo "MISSING $P/authorized_keys (owner pubkey)"; exit 1; }

# 1) obtain genuine plaintext tar.gz (decrypt if it's a TE2 envelope)
if gzip -t "$GEN" 2>/dev/null; then say "genuine is already plaintext tar.gz"; cp "$GEN" "$W/plain.tar.gz"
else say "decrypting genuine envelope"; python3 "$GEN5W" decrypt "$GEN" "$W/plain.tar.gz" --force >/dev/null; fi
TEMPLATE="$GEN"                                   # te2_encrypt reuses the genuine envelope trailer
# if genuine was plaintext, we still need an encrypted template; require the .te2 alongside
if ! [ "$(stat -c%s "$GEN")" = 879126179 ]; then
  say "NOTE: template envelope must be the 879126179-byte genuine .te2; pass it as arg 2 for encrypt"
fi

# 2) decompress to an appendable tar
say "decompressing"; gunzip -c "$W/plain.tar.gz" > "$W/rootfs.tar"; rm -f "$W/plain.tar.gz"

# 3) stage additions (root-owned), then append
A="$W/add"; mkdir -p "$A"/{usr/sbin,etc/systemd/system/multi-user.target.wants,etc/owner,etc/dropbear,home/root/.ssh,etc/wpa_supplicant}
install -m755 "$DB" "$A/usr/sbin/dropbearmulti"
ln -sf dropbearmulti "$A/usr/sbin/dropbear"
install -m755 "$V/wifi-up.sh" "$A/etc/owner/wifi-up.sh"
install -m644 "$V/wpa_ap.conf" "$A/etc/wpa_supplicant/wpa_ap.conf"
install -m644 "$V/owner-access.service" "$A/etc/systemd/system/owner-access.service"
ln -sf ../owner-access.service "$A/etc/systemd/system/multi-user.target.wants/owner-access.service"
install -m600 "$P/authorized_keys" "$A/etc/dropbear/owner_authorized_keys"
# USB dev-loader: run toctou_dev.sh from a plugged stick as root (fast iteration, no reflash)
install -m755 "$V/dev-loader.sh" "$A/etc/owner/dev-loader.sh"
install -m644 "$V/toctou-devloader.service" "$A/etc/systemd/system/toctou-devloader.service"
ln -sf ../toctou-devloader.service "$A/etc/systemd/system/multi-user.target.wants/toctou-devloader.service"

if [ "$MODE" = menu ]; then
  # OwnerTools QML page + patched FullMain with the Owner Tools button
  mkdir -p "$A/app/share/AppEngineerMode/qml/owner"
  install -m644 "$V/OwnerTools.qml" "$A/app/share/AppEngineerMode/qml/owner/OwnerTools.qml"
  say "extracting + patching AppEngineerMode_FullMain.qml"
  tar -xf "$W/rootfs.tar" -C "$W" ./app/share/AppEngineerMode/qml/AppEngineerMode_FullMain.qml
  python3 "$V/inject_fullmain.py" \
     "$W/app/share/AppEngineerMode/qml/AppEngineerMode_FullMain.qml" \
     "$A/app/share/AppEngineerMode/qml/AppEngineerMode_FullMain.qml"
  # drop the original FullMain so the appended patched copy is the only one (not a dup)
  tar --delete -f "$W/rootfs.tar" ./app/share/AppEngineerMode/qml/AppEngineerMode_FullMain.qml 2>/dev/null || true
  # TODO(on-HU): stamp security.SMACK64 on new /app QML to match sibling eng-mode QML (repack hygiene)
fi

say "appending payload to tar"
tar --append -f "$W/rootfs.tar" --format=ustar --numeric-owner --owner=0 --group=0 -C "$A" .

# 4) recompress at -9 and assert the ceiling
say "recompressing (gzip -9)"
gzip -9 -c "$W/rootfs.tar" > "$W/evil.tar.gz"; rm -f "$W/rootfs.tar"
SZ=$(stat -c%s "$W/evil.tar.gz")
say "evil.tar.gz = $SZ  ceiling = $CEIL  margin = $((CEIL-SZ))"
if [ "$SZ" -gt "$CEIL" ]; then
  echo "[v2] OVER CEILING by $((SZ-CEIL)) bytes — prune unused trees (/whatsnew /manual /voicememo) and retry"; exit 3
fi

# 5) pad to exact body size and TE2-encrypt (basename fixes the IV => mango-rootfs.tar.gz)
say "padding to $CEIL and encrypting"
cp "$W/evil.tar.gz" "$W/evil_padded"; truncate -s "$CEIL" "$W/evil_padded"
mkdir -p "$(dirname "$OUT")"
python3 "$TE2" "$W/evil_padded" "$TEMPLATE" "$OUT" "mango-rootfs.tar.gz"
say "round-trip verify (under correct basename — the HU sees the file as mango-rootfs.tar.gz)"
OUTABS="$(readlink -f "$OUT")"; VR="$W/vr"; mkdir -p "$VR"; ln -sf "$OUTABS" "$VR/mango-rootfs.tar.gz"
python3 "$GEN5W" inspect "$VR/mango-rootfs.tar.gz" 2>/dev/null | grep -E '"iv"|integrity_valid' || true
echo "[v2] DONE -> $OUT  ($(stat -c%s "$OUT") bytes)"
