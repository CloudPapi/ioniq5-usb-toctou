# 11 — Wireless CarPlay: binary patches

Concrete binary patches that flip the webOS (Gen5W_L) iAP2/CarPlay **gates** for wireless CarPlay,
with static verification. As of 2026-11-10. Owner's own decommissioned, off-road IONIQ 5 head unit
(build 260128, x86-64). Background and gate analysis: [`docs/09`](09-wireless-carplay.md). Delivery
(SMACK) context: [`docs/10`](10-smack.md).

> **Scope of this work.** "Patch the binaries necessary for wireless CarPlay, verify to the extent
> possible without the car." Two gates are clean, in-place binary patches (done + verified below).
> Three further items are **necessary but not binary-patchable** (a launch argument + two from-scratch
> modules) — documented in §3. End-to-end function (pairing → handoff → projection) **cannot** be
> verified without the car and an iPhone; everything here is static verification.

The firmware-derived binaries are **not** committed (gitignored). The reproducible recipe —
a manifest (full stock+patched sha256, exact edits, anchor signatures) and an apply script that
verifies before and after — ships in **[`pizero/patches/carplay/`](../pizero/patches/carplay/)**
(`manifest.json` + `apply_carplay_patches.py`). It regenerates the patched binaries byte-for-byte
from the owner's genuine `/app` files.

---

## 1. iAP2Service-2.0 — advertise the WirelessCarPlay transport

**Why:** the iPhone only initiates wireless CarPlay if the head unit advertises a WirelessCarPlay
transport component in its iAP2 `IdentificationInformation`. The builder exists
(`createWirelessCarPlayTransportComponentParamList` @`0x23a86`, ComponentId **0x0100**) but is **dead
code** — the dispatcher `sub_22f8e`'s jump table (`0x78568`) maps **selector 9 → WCP builder**, and
`createIdentificationInformationParamList` (@`0x207fa`) never passes selector 9.

**Patch:** repurpose the **USB-device else-branch** (fires when *not* in USB-host mode — i.e. the
wireless case; the USB-host/wired branch is left untouched) to emit the WCP transport instead of the
USB-device transport.

| File | stock sha256 | patched sha256 |
|---|---|---|
| `iAP2Service-2.0` | `38419131df82ec7e3c3b29a68ecc1a078c7f0b403051f137fe9f46f82b99f26e` | `2cccd6f2f393cf23f0538a491d061abe23e9d0e10371820902bbfa89b5a2458e` |

| VA | instruction | stock | patched | meaning |
|---|---|---|---|---|
| `0x20df0` | `mov edx, imm` (3rd arg to `sub_22f8e`) | `00` | `09` | build selector 0 (USB-device) → **9 (WirelessCarPlay)** |
| `0x20e1f` | `mov edx, imm` (3rd arg to `sub_1cf4a`) | `0f` | `18` | append as param 0xf (USB-device transport) → **0x18 (WirelessCarPlay transport)** |

Signature (unique in-file, patch at relative byte 9 and 56):
```
488d4dd8488b45c8 ba[00→09]000000 4889ce4889c7 e88f210000 8945d4 8b75d4 488b45d8 488b7da0 488b4da8 488b55b0 4989f9 4989c8 4889d1 ba[0f→18]000000 4889c7 e81fc1ffff 488b45d8
```

**Verification (static):** re-decompiling the patched `createIdentificationInformationParamList`
shows the else-branch now reads `sub_22f8e(state,&buf,0x9)` then `sub_1cf4a(buf,len,0x18,…)`, while
the USB-host branch is unchanged (`…,0x1`/`…,0x10`). Both edits are immediate operands of
`mov edx, imm32` (same length/encoding) → disassembly and all offsets are structurally preserved.
Exactly 2 bytes differ; ELF header/sections/entry intact; size unchanged.

> **One value needs a live phone.** The WirelessCarPlay transport's top-level param ID is **not
> recoverable statically** — it is dead in this firmware, absent from the `decodeIdentifiCationRejected`
> name table, and public sources disagree (firmware-inference `0x13`, public RE `0x18`, another RE
> `0x15`). We use **`0x18`** (best public-RE support; collides with no param this firmware actually
> emits — it uses 0xa,0xf,0x10,0x12,0x14,0x15,0x16,0x22). If the phone silently sends
> `IdentificationRejected`, change the single byte at `0x20e1f` to `0x13` or `0x15` and retry.

---

## 2. BluetoothHMI — force "wireless CarPlay supported" (WPP)

**Why:** the BT bootstrap only offers wireless CarPlay when `BluetoothManagerQML::isSupportWPP()`
is true. `isSupportWPP` (`sub_d4d26`) returns `sub_4fe72()`, which is
`(getWPP() != 0xffffffff) ? 1 : 0` — i.e. false unless a WPP value was provisioned. `sub_4fe72` is
WPP-specific (not a generic getter), so forcing it true is isolated and safe.

| File | stock sha256 | patched sha256 |
|---|---|---|
| `BluetoothHMI` | `37f10926af48265c2c6ee5910ebf1fa43aa08150c7dae8c7b8a3ab736d21bd9f` | `1ff002ae052d16719de683bfa95636a1ca4f0edb8450bad50841e11c71030a93` |

| VA | stock bytes | patched bytes | meaning |
|---|---|---|---|
| `0x4fe72` | `48 83 ec 18 64 48` (`sub rsp,0x18; mov rax,fs:0x28…`) | `b8 01 00 00 00 c3` (`mov eax,1; ret`) | `sub_4fe72()` → **always return 1** |

The 6-byte prologue is overwritten with `mov eax,1; ret`, which returns before any stack/canary
setup (safe — the stack is never modified).

**Verification (static):** the patched `sub_4fe72` re-decompiles to exactly `return 0x1;`, so
`isSupportWPP()` is now always true. Exactly 6 bytes differ; ELF header/sections/entry intact; size
unchanged.

---

## 3. Necessary, but NOT binary patches

These gates are required for wireless CarPlay to actually run, but cannot be delivered as safe
in-place byte patches:

1. **AppProjection wireless-projection mode — `-wpp:1` launch argument.** AppProjection reads its
   wpp capability from argv via the dedicated getter `sub_50e30` (hard-coded to the `-wpp:` key
   global `qword_4365b0`), which returns **0 when the arg is absent** — and `AppLauncher` emits no
   `-wpp`. The getter has no safe in-place return-override (its only always-taken return site is a
   2-byte `xor eax,eax` that can't cleanly set the full return register, and its true entry is
   obscured). **Correct fix: launch AppProjection with `-wpp:1`** (patch `AppLauncher`'s arg list or
   the launch config). This is the firmware's designed mechanism, not a binary hack.
2. **Wi-Fi credential generator (handoff msg `0x5703`).** The BT→Wi-Fi handoff reply
   `{SSID, passphrase, security, channel}` is live in `iAP2Service`, but its `WiFiInformation`
   delegate slot is **NULL** — nothing produces the credentials. This is net-new code, not a patch.
3. **5 GHz SoftAP bring-up.** No CarPlay hotspot ships in `/app` (station-only Wi-Fi, no
   hostapd/dnsmasq). Net-new code/config. (AP bring-up on this BCM4359 hardware is proven — the
   Owner Tools image already runs the built-in Wi-Fi as an AP — but a 5 GHz AP whose SSID/PSK match
   the `0x5703` handoff must be authored.)

Not a blocker (confirmed): **MFi** (the Android HMG sibling enables wireless with zero MFi work —
see `docs/09`), and the **AirPlay/CarPlay session layer** (`libAirPlay`/`libCarPlayAppFramework` are
transport-agnostic and already accept Wi-Fi — no "reject Wi-Fi" branch to flip, unlike the Android
unit's `libCarPlayCore`).

---

## 4. Verification summary

| Check | iAP2Service-2.0 | BluetoothHMI |
|---|---|---|
| Intended semantics (re-decompile of patched fn) | ✓ else-branch emits WCP transport (sel 9 / param 0x18) | ✓ `sub_4fe72` returns `0x1` |
| Bytes changed (exact) | 2 @ `0x20df0`, `0x20e1f` | 6 @ `0x4fe72`–`0x4fe77` |
| File size unchanged | ✓ 633216 | ✓ 9173496 |
| ELF header / sections / entry intact | ✓ | ✓ |
| Wired/USB path preserved | ✓ (USB-host branch untouched) | n/a |

**Cannot be verified without the car:** that the iPhone accepts the advertised WCP transport under
param `0x18` (the one contested byte), the full BT→Wi-Fi handoff, and on-screen projection. Those
need a live iPhone behind MFi auth, plus items §3.1–§3.3 in place. Each on-car trial also carries the
SMACK/boot-loop risk from `docs/10` — so these ship **`SMACK64EXEC=Privileged`** in the TOCTOU image
(docs/10), and only after the §3 items exist.

## 5. Reproduce

The committed recipe is **[`pizero/patches/carplay/`](../pizero/patches/carplay/)** — a manifest and an
apply script that verify the stock sha256, apply the exact edits, and assert the patched sha256:
```sh
cd pizero/patches/carplay
python3 -I apply_carplay_patches.py --in /path/to/genuine/app --out /path/to/patched/app
# or verify you have the right stock build without patching:
python3 -I apply_carplay_patches.py --in /path/to/genuine/app --verify-only
```
(VA == file offset holds for both binaries, verified; the script patches by offset guarded by the
whole-file stock sha256.) Firmware-derived binaries stay gitignored; the manifest+script regenerate them.
