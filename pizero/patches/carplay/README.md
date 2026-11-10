# Wireless CarPlay gate patches

Reproducible binary patches that flip the webOS (Gen5W_L) iAP2/CarPlay gates for wireless CarPlay.
Full analysis + static verification: [`docs/11-wireless-carplay-patches.md`](../../../docs/11-wireless-carplay-patches.md).

The firmware-derived `/app` binaries are **not** in this repo (gitignored). This directory ships the
**recipe**, not the binaries:

| file | what |
|---|---|
| `manifest.json` | per-target stock+patched sha256, size, exact edits (VA/offset, stock→patched bytes), anchor signature, caveats |
| `apply_carplay_patches.py` | verifies stock sha256 → applies edits by offset → asserts patched sha256 + unchanged size |

## Apply

```sh
# genuine /app tree -> patched /app tree (reads app/bin/<name>, writes the same path)
python3 -I apply_carplay_patches.py --in /path/to/genuine/app --out /path/to/patched/app

# or a single binary
python3 -I apply_carplay_patches.py --file iAP2Service-2.0=/path/to/stock --out-file /path/to/patched

# just check you have the right stock build (patches nothing)
python3 -I apply_carplay_patches.py --in /path/to/genuine/app --verify-only
```

Run under `python3 -I` — the inputs are untrusted firmware. The script refuses to patch anything whose
whole-file stock sha256 doesn't match the manifest (wrong file or a different firmware build).

## What the patches do (summary)

- **iAP2Service-2.0** — advertise the WirelessCarPlay transport (ComponentId `0x0100`) in iAP2
  `IdentificationInformation` (2 bytes). The one unresolved value is the transport **param ID** `0x18`
  (byte at `0x20e1f`); alternates `0x13`/`0x15` if a live iPhone rejects it.
- **BluetoothHMI** — force `isSupportWPP()` true so the BT bootstrap offers wireless (6 bytes,
  `mov eax,1; ret`).

## Delivery + limits

Ship the patched binaries in the TOCTOU evil rootfs with **`SMACK64EXEC=Privileged`**
(`chsmack -e Privileged`, preserved in the tar xattrs) — see
[`docs/10-smack.md`](../../../docs/10-smack.md). These two patches are **necessary but not sufficient**:
wireless CarPlay also needs the `-wpp:1` launch arg, a Wi-Fi credential generator, and a 5 GHz SoftAP
(docs/11 §3). End-to-end function is **not** verifiable without the car and an iPhone.
