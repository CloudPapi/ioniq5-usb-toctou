# 09 — Wireless Apple CarPlay: current state

Research + resume state for enabling **wireless** Apple CarPlay **in the current firmware**
(no dongle, no firmware-version swap). As of 2026-11-09. Owner's own decommissioned, off-road
IONIQ 5 head unit (Gen5W_L, Linux/webOS, build 260128, x86-64).

This firmware ships wired CarPlay. Wireless CarPlay is **confirmed off** (owner-verified) and,
per the analysis below, is **not a setting or a persistence-key flip** — it is a binary
integration + from-scratch authoring job delivered through the TOCTOU image.

---

## TL;DR — the decision-relevant verdict

**Is it well documented how such a binary should work? — Yes, substantially, at the protocol
level.** Three independent sources agree:

1. **The firmware is its own reference.** The Bluetooth and WirelessCarPlay transport builders
   are *present and structurally complete* in `iAP2Service-2.0` — we recovered their exact byte
   encoding. The BT→Wi-Fi handoff is not even dormant: it is **live-dispatched**.
2. **The leaked Apple Accessory Interface Spec** (AIS R22/R29) catalogs these exact messages.
3. **~12 working open-source accessory-side receivers exist**, several on Linux
   (`wiomoc/iap2` — a runnable iAP2 stack; `riazosama/headunit-carplay`;
   `harrylepotter/carplay-receiver`). They independently agree with the firmware — e.g.
   Bluetooth transport top-level param = `0x11` is confirmed by firmware **and** public RE
   **and** the spec.

**But "documented" ≠ "ready."** It is an **integration + authoring project against a
non-cooperative black-box oracle (the iPhone behind MFi auth)**:

- two dead jump-table cases to wire (BT `0x0022`, WCP `0x0100`),
- two subsystems to write from scratch (a Wi-Fi credential generator + a 5 GHz SoftAP),
- one protocol value that documentation **cannot** settle (the WCP wrap param ID: firmware
  `0x13` vs public RE `0x18`), resolvable only by live-phone trial,
- a **hardware precondition we cannot confirm statically**: a reachable, *wireless-entitled*
  MFi auth coprocessor,
- no error channel (wrong framing → silent `IdentificationRejected`), and per-trial SMACK
  boot-loop risk.

**Overall static recoverability: "mostly."** The documentation is not the blocker. The blockers
are the MFi entitlement (hardware, unverifiable without trying) and the author-it-yourself
SoftAP + credential path plus a blind param-ID trial.

---

## How wireless CarPlay connects (the target flow)

```
  iPhone ──BT──► HU: iAP2-over-Bluetooth session (bootstrap transport)
       │
       ├─ MFi authentication: HU proves a genuine Apple auth coprocessor
       │     (I2C, /dev/i2c-1 @ 0x10) — cert + RSA challenge/response
       │
       ├─ BT→Wi-Fi handoff: HU sends {SSID, passphrase, security, channel} over BT
       │     (iAP2 msgs 0x5701/0x5702 → reply 0x5703)
       │
       ├─ iPhone joins the HU's own 5 GHz SoftAP
       │
       ├─ iAP2 WirelessCarPlay transport re-established over Wi-Fi + Bonjour/mDNS
       │
       └─ AirPlay-derived screen + audio (H.264, gstreamer mfxdecode)
```

The HU must **advertise** that it can do wireless (the transport components in its iAP2
`IdentificationInformation`), **run a 5 GHz access point**, and **hand the phone credentials for
it** — all gated behind MFi auth. The firmware has the protocol machinery for the first and
third; it lacks the second, does not populate the credentials, and never turns the first on.

---

## What the firmware already contains

### `iAP2Service-2.0`
sha256 `38419131df82ec7e3c3b29a68ecc1a078c7f0b403051f137fe9f46f82b99f26e`

| Element | Address | State | Detail |
|---|---|---|---|
| `createIdentificationInformationParamList` | `0x207fa` | live | dispatches `sub_22f8e` with selector set **`{0xb,1,0,2,7,6,5}`** — note: **no BT/WCP transport selectors** |
| transport builder dispatcher | `0x22f8e` | live | the jump table the two emitters below hang off |
| **Bluetooth transport builder** | `0x2394a` | **dead code** (one caller) | ComponentId **`0x0022`**, default name `"DH"`, default MAC `"000E34020F2F"` |
| **WirelessCarPlay transport builder** | `0x23a86` | **dead code** (one caller) | ComponentId **`0x0100`**, default name `"WirelessCarPlayTransPortComponent"` |
| BT→Wi-Fi handoff | msgs `0x5701`/`0x5702`, IPC event `0x567e`, reply `0x5703` | **live** | reply payload = **{SSID str, passphrase str, SecurityType uint 0..2, Channel uint8}**, no BSSID |

- BT transport **top-level param ID = `0x11`** — triple-confirmed (firmware + public RE + AIS).
- WirelessCarPlay **top-level wrap param ID = CONTESTED**: firmware gap-inference says `0x13`;
  public RE says `0x18`. The firmware's own numbering diverges from the public scheme (it uses
  `0x12` for HID where the public table is blank), so **neither inference is reliable** —
  settle only via AIS R29 §20.2.4 or a live-phone trial.

The transport builders are the "advertise wireless" half, and they are essentially complete —
they are simply **never reached** because the live dispatcher's selector set omits them.

### `AppProjection`
sha256 `8f0096bc…`

- iAP2 config is **identity-only** (`sub_36d60`): it does not itself emit transport components.
- Reads capability from **launch argv** in `main()`/`sub_192f0`:
  - `"-wpp:"` (`@0x1aa595`) = **wireless phone projection**; **default 0 when the arg is absent**.
  - `"-p2s2:"` present alongside.
- `APP_BT_PP_WIRELESS_CONNECTION_ENABLE` (`@0x1aaff0`) is **only `registerKey`-subscribed** —
  it is **never consumed to toggle a transport**. (This is why "just flip the persistence key"
  does nothing: nothing reads it to turn wireless on.)

### `BluetoothHMI`
sha256 `37f10926…`

- `m_nWPP = this[0x2c4]`; `isSupportWPP() = sub_d4d26 = (getWPP() != 0xffffffff)`.

### `AppLauncher` / variant spec
- Emits **no `-wpp`** for any variant → `AppProjection` always sees wpp default 0.
- `CarOption.csv` spec table has **no wireless column**.
- EU = `COUNTRY_EUROPE (0x05)` is **permitted, not denylisted** — the region is *not* the lock
  (an earlier hypothesis, refuted).

---

## Why it is off (the gate chain)

1. **`-wpp` is never provisioned.** `AppLauncher` emits no `-wpp`; `AppProjection` defaults wpp
   to 0.
2. **The transport emitters are dead code.** `createIdentificationInformationParamList`'s
   selector set never dispatches the BT (`0x0022`) or WCP (`0x0100`) builders, so the HU never
   advertises a wireless transport in `IdentificationInformation`.
3. **The Wi-Fi credential source is empty.** The `WiFiInformation_f` delegate slot that would
   populate the `0x5703` handoff reply is **NULL** — nothing generates SSID/PSK/channel.
4. **There is no access point.** No `hostapd`, no `dnsmasq`; `supplicantmanager` is
   **station-mode only**; BCM4359/`wlan0` AP-mode capability on this build is **unverified**.
5. **MFi gate.** The phone demands a genuine Apple auth coprocessor (cert + RSA challenge)
   **before** the handoff; a wired-only entitlement may be rejected for wireless.

The persistence key is a red herring: it is subscribed but never actuates a transport.

---

## What enabling it actually requires

This is **not** a config change. It is, in rough effort order:

**A. Binary patches to `iAP2Service-2.0` / `AppProjection`** (ship via TOCTOU image; `/app/bin`
is read-only at runtime):
- extend the `createIdentificationInformationParamList` dispatch selector set so the BT
  (`0x2394a`) and WCP (`0x23a86`) transport builders are actually reached;
- force WPP true (patch the `-wpp` default / `getWPP()`), or inject `-wpp:1` at launch;
- set the persistence key for completeness (necessary-looking, not sufficient on its own).

**B. Author a Wi-Fi credential generator** to fill the NULL `WiFiInformation_f` delegate slot:
produce {SSID, passphrase, SecurityType, Channel} for the `0x5703` handoff reply. Standard code,
but net-new — nothing in the firmware does this.

**C. Author a 5 GHz SoftAP bring-up** on `wlan0`/BCM4359: there is no AP stack shipped. Needs
either a working AP-mode path in the shipped `bcmdhd` driver (**unverified**) or a bundled
`hostapd`/equivalent, plus DHCP. Standard, well-documented Linux — but from scratch here.

**D. Live-phone trials** to pin the WCP wrap param ID (`0x13` vs `0x18` vs AIS value) and to
clear MFi auth. No static oracle exists.

---

## Open unknowns documentation cannot settle

| Unknown | Why static analysis can't close it | How to close it |
|---|---|---|
| WCP top-level wrap param ID (`0x13` vs `0x18`) | the WCP path is dead; firmware's own numbering diverges from the public scheme | AIS R29 §20.2.4, or brute-force live-phone trial |
| MFi coprocessor present / reachable / **wireless-entitled** | runtime-only; a cert cannot be forged | on-device probe for the chip; a live handshake for the entitlement |
| BCM4359 AP-mode on this driver build | no AP userland ships to exercise it | `iw phy` on-device; attempt AP bring-up |
| iOS version drift | specs predate iOS 18/26 | test against the target phone |
| Failure mode | wrong framing → **silent `IdentificationRejected` (0x1D03)**, no error text | instrument iAP2Service / capture iAP2 over BT |

Each trial also risks a **SMACK boot-loop** (recovery via bench eMMC/SPI, per
[`memory: update-rsa-chain-enforced`]).

---

## Cheapest next step: the MFi go/no-go, then the probe

**MFi is the kill switch.** If the coprocessor is absent or its cert is not wireless-entitled,
the whole project is dead regardless of code — so check it **first and cheaply**.

### The read-only probe — `pizero/payload/v2/toctou_dev_carplay.sh`

Written, **not yet staged** (USB stick is off the workstation). Changes nothing; runs as root
via the dev-loader; writes `v2_carplay.txt` to the stick and `/var/log/`. Ten sections:

| # | Section | Confirms |
|---|---|---|
| 1 | advertised transports (`IdentificationConfig`) | which transports the HU emits; `/app/data` writability |
| 2 | the wireless gate key + value + store format | the persistence key's actual stored value |
| 3 | D-Bus persistence/profile setter interface | the supported setter surface |
| 4 | vehicle variant / country | variant is not the lock (sanity) |
| 5 | CarPlay on at all (`phoneProjection` per profile) | wired baseline state |
| 6 | **MFi auth coprocessor** (`/dev/i2c-*`, `i2cdetect` bus1) | **chip present + reachable @ 0x10** — the go/no-go |
| 7 | Wi-Fi AP mode + 5 GHz (`iw phy`) | whether BCM4359 advertises AP + 5 GHz channels |
| 8 | Bluetooth profiles (iAP2 carrier) | BT/SDP carrier for the bootstrap |
| 9 | carplay services + procs | what's running |
| 10 | logs: carplay/iap2/wireless/transport negotiation | runtime evidence |

**Gap to add before staging:** §6 confirms the coprocessor is *reachable* but not that its cert
is *wireless-entitled* — that needs a live handshake. The probe answers "is the chip there?",
which gates whether the rest is worth building.

Stage it on the stick as `toctou_dev.sh` (the dev-loader runs it once per md5), plug in ~20 s,
pull, read `v2_carplay.txt`. See [`docs/07`](07-build-and-flash-runbook.md) for the dev-loader
mechanics and [`docs/08`](08-handoff-ssh-wip.md) for current HU/Pi/stick state.

---

## Decrypted-firmware working set (off-repo)

Extracted genuine binaries used for this analysis live in the session scratchpad (not in the
repo; they are firmware-derived):
`app/bin/{AppProjection,iAP2Service-2.0,BluetoothHMI,UserProfileManager}`,
`app/lib/lib{AirPlay,CarPlayAppFramework,CarPlayMediaFramework,iAP2AppFramework-2.0}.so`.
Re-extract from the genuine `mango-rootfs.tar.gz` with `pizero/gen5w_decrypt.py` (see
[`REPRODUCE.md`](../REPRODUCE.md)).

## Public references (the "it's documented" evidence)

- `wiomoc/iap2` — near-complete iAP2 stack (Python), runnable accessory side.
- `riazosama/headunit-carplay`, `harrylepotter/carplay-receiver` — Linux accessory receivers.
- Leaked Apple **Accessory Interface Specification** R22 / R29 (iAP2 message catalog).
- WWDC 2017 "What's New in Wireless CarPlay" (handoff overview).
- Corroboration point: BT transport param `0x11` agrees across firmware + RE + AIS.
