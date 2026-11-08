# IONIQ 5 USB-update TOCTOU

> Lots of credit to https://github.com/JaredReabow/ioniq-5-Reverse-Engineering and the nice people on the Gen5W discord.

A time-of-check/time-of-use vulnerability in the IONIQ 5 (Gen5W_L) head-unit USB
firmware-update path, with a runnable demonstration and the real dynamic-USB hardware
rig that exploits it.

**The flaw in one line:** AppUpgrade **verifies** an update file and then **installs** it
in a *separate process that re-opens the same file*, while the file lives on
attacker-controlled removable media — so a device that returns different bytes on the
second read installs unsigned content after a signed check has already passed. The system
rootfs has no boot-time integrity (no dm-verity), so the swapped image simply runs at next
boot.

## Status

- **PoC (no car): confirmed.** `poc/run_poc.sh` runs the real check-then-install against a USB
  emulator: the signature/md5 check passes on benign bytes, the installer then consumes evil
  bytes. Verified A, installed B.
- **On the real head unit: confirmed.** The Pi dynamic-USB rig serves genuine bytes to the
  verify pass and the swapped image to the install pass; the attacker rootfs installs and boots
  on the owner's own car. No OEM private key is used.
- **Owner Tools image — USB dev-loader: confirmed.** After the one flash, the payload's service
  runs root-owned scripts off a plugged USB stick (the "standing door") — the whole
  post-install iteration path works with no reflash and no network.
- **Owner Tools image — Wi-Fi AP: confirmed.** The payload brings the built-in Wi-Fi up as an
  AP (`IONIQ5-OWNER`, `10.42.0.1`) and a watchdog holds `wlan0` against the OEM stack.
- **SSH-over-Wi-Fi: in progress (root-cause chain identified).** dropbear listens and completes
  the handshake; getting an authenticated shell requires handling several device constraints
  (see below), being finalized live via the dev-loader.
- **On-HU Engineering-Mode menu entry: fix built, pending flash.** The button renders at row 2
  slot 5; the dead-tap cause (wrong QML import paths) is fixed in the source and baked into the
  next image (`/app` is read-only at runtime, so this ships via a flash, not the dev-loader).

> **Scope & authorization.** This is right-to-repair / own-device security research on the
> author's **own, decommissioned, off-road** IONIQ 5 head unit (build 260128). The payload
> is a **benign** proof marker (a root service that writes a log file). No OEM private key
> is used or forged. See [`SECURITY.md`](SECURITY.md).

---

## Why it works (the four facts)

1. **Check and use are separate re-reads.** The check is `ionice -c3 md5sum %1 | awk`
   plus a `PKCS#1 sig. verify`; the install is `/app/share/AppUpgrade/DecryptToPIPE %1 |
   tar` — distinct `system()`/`popen()` calls, so `%1` is `open()`ed twice with the
   integrity decision made in between.
2. **The big image is read in place from the USB stick**, not copied to local storage
   (only the ~6 MB boot images go to `/tmp`). So both reads hit attacker media.
3. **No post-write verification of the system partition.** The post-install "verify" is
   source-side; "System Update Verify" measures **46 ms** — far too short to re-hash an
   879 MB partition.
4. **No rootfs integrity at boot.** The rootfs is plain ext4 (A/B on `mmcblk0p3`/`p5`),
   no dm-verity; the bootloader RSA covers only the boot image, which we leave genuine.

The attacker needs **no RSA private key** (the genuine signed image passes the check) and
already holds the TE2 AES content key, so the swapped-in blob is a valid-looking encrypted
envelope that decrypts to an attacker rootfs. Full detail: [`docs/01-vulnerability.md`](docs/01-vulnerability.md).

## The exploit rig

A Raspberry Pi Zero 2 W presents to the head unit as a USB mass-storage stick whose bytes
are **dynamic per read pass**:

```
   HU USB host  ──►  dwc2 UDC (gadget)  ──►  configfs f_mass_storage  lun.0 = /dev/nbd0
                                                                            │
                                            nbd-client ◄── nbdkit (Python plugin) ◄── usb.img (27 GB exfat)
                                                                            │
                                   nbdkit_toctou.py serves the rootfs byte-region GENUINE on
                                   read-pass #1 (the md5 check) and EVIL from read-pass #2
                                   (the install) — "verify A, install B".
```

The swap trigger, the offline-robust logging, and every bug found bringing this up on real
hardware are in [`docs/04-field-journal.md`](docs/04-field-journal.md). Deployment runbook:
[`pizero/DEPLOY.md`](pizero/DEPLOY.md).

---

## One race, then a standing door

The swap only has to win **once**. The rootfs it installs carries a tiny systemd service — the
USB dev-loader — that on every boot runs a root-owned script off any USB stick plugged into the
head unit. The whole escalation is three hops:

```
   TOCTOU swap (win once)  ─►  boot the swapped rootfs  ─►  its service runs your files from USB, as root
```

So one verify-then-install race converts into a **permanent, networkless root channel**: drop a
script on a stick, plug it in, it runs as root — no second exploit, no reflash. The same payload
also brings the built-in Wi-Fi up as an AP with an SSH server, so after that one flash the unit
is reachable without ever touching it again. A single swapped byte-region becomes a key to the
whole box.

---

## Repo map

| Path | What |
|---|---|
| [`REPRODUCE.md`](REPRODUCE.md) | **Rebuild from zero** — the from-nothing runbook (firmware + key + a Pi → running rig). |
| [`docs/01-vulnerability.md`](docs/01-vulnerability.md) | The TOCTOU flaw, why the bytes can differ, why it persists, and an honest evidence grading. |
| [`docs/02-attack-chain.md`](docs/02-attack-chain.md) | End-to-end attack chain + the Pi dynamic-USB gadget architecture and swap logic. |
| [`docs/03-evidence.md`](docs/03-evidence.md) | What's proven from the binary, the car's own DLT logs, and native/VM execution. |
| [`docs/04-field-journal.md`](docs/04-field-journal.md) | Chronological bring-up on real hardware: every bug and fix (swap trigger, watchdog reboot, offline logging, DLT timeline analysis). |
| [`docs/05-mitigations.md`](docs/05-mitigations.md) | The fix patterns (verify-and-use-the-same-bytes, dm-verity). |
| [`docs/06-owner-menu-v2.md`](docs/06-owner-menu-v2.md) | The Owner Tools image design: on-HU Engineering-Mode menu + built-in-Wi-Fi dropbear SSH, size budget, payload. |
| [`docs/07-build-and-flash-runbook.md`](docs/07-build-and-flash-runbook.md) | **Owner Tools image: build & flash** — the 1:1 reproduction (dropbear build, `build_v2.sh`, `arm.sh`, flash, verify, iterate) + device runtime constraints. |
| [`docs/08-handoff-ssh-wip.md`](docs/08-handoff-ssh-wip.md) | **Resume state** — SSH-over-Wi-Fi root-cause chain, current HU/Pi/stick state, and the exact next step to pick the work back up. |
| [`poc/`](poc/) | **No-car** runnable demo: reproduces the two-pass race with real `md5sum`/`openssl`/`dd`/`tar`. |
| [`pizero/`](pizero/) | The real dynamic-USB gadget: nbdkit swap plugin, build/deploy scripts, systemd unit, host config, and the vendored `gen5w_decrypt.py` / `te2_encrypt.py` crypto tools. |

## Quick start — the no-car PoC

Needs only `sh`, `openssl`, `python3`, `tar`, `dd` (no car, no hardware):

```sh
poc/run_poc.sh
```

It generates a throwaway OEM keypair locally (only so a real `openssl` verify can run end
to end), signs a benign image, then runs the check and the install against a USB emulator
that swaps benign→evil on the verify read-close. Expected: **CHECK passes on benign bytes,
installer consumes evil bytes** — verified A, installed B.

## Rebuild from zero

**[`REPRODUCE.md`](REPRODUCE.md) is the from-nothing runbook** — assumes only the genuine
firmware package (fetch elsewhere), the TE2 content key (you have it), and a Pi Zero 2 W.
Everything else needed is in this repo, including the decrypt tool (`pizero/gen5w_decrypt.py`).
In brief:

1. Put the TE2 key in `pizero/key.local` (see `pizero/key.local.example`) or
   `export TE2_CONTENT_KEY=…`.
2. `pizero/01_make_evil_rootfs.sh` → build the byte-exact evil `mango-rootfs` envelope.
3. `pizero/02_build_usb_image.sh` → stream the genuine package into a 27 GB exfat `usb.img`
   with the rootfs written first (one contiguous extent); emits `regions.json`.
4. `pizero/04_preflight.sh` → go/no-go gate (baseline md5, evil extent/shape, dry-run swap).
5. `pizero/03_deploy_gadget.sh` (or enable `toctou-gadget.service`) → present the gadget.
6. Insert into the HU, start the update, read the log for `served=EVIL` on the install pass.

Deployment detail (offline logging, re-arm): [`pizero/DEPLOY.md`](pizero/DEPLOY.md).
Live status: [`pizero/STATUS.md`](pizero/STATUS.md).

## The Owner Tools image (v2)

A richer payload on the same TOCTOU delivery: a browsable **Owner Tools** entry in Full
Engineering Mode, the **built-in Wi-Fi brought up as an AP** with a bundled static **dropbear**
SSH server, and a **USB dev-loader** for post-install iteration without reflashing.

1. `pizero/payload/bin/dropbearmulti` — static musl x86-64 dropbear (build recipe in `docs/07` §3).
2. `pizero/build_v2.sh menu <genuine_mango> build/evil_rootfs_menu_v2.te2` — decrypt → inject the
   Owner Tools button + stage the payload → `gzip -9` → assert the ceiling → pad → TE2-encrypt → verify.
3. `pizero/02_build_usb_image.sh` → `usb.img` + `regions.json`.
4. `sudo pizero/arm.sh menu2` → generate `regions_menu_v2.json` and present the gadget.
5. Flash, then iterate via a stick (`pizero/payload/v2/toctou_dev.sh`).

Full procedure: **[`docs/07-build-and-flash-runbook.md`](docs/07-build-and-flash-runbook.md)**. Design: [`docs/06-owner-menu-v2.md`](docs/06-owner-menu-v2.md).

## Secrets kept out of git

This repo is **publishable**: no key material is committed. The only secret is the **TE2
content key**, supplied at runtime via `pizero/key.local` or `$TE2_CONTENT_KEY` (gitignored).
The decrypt tool itself (`pizero/gen5w_decrypt.py`) is vendored and reads the key from there,
so the repo is self-contained given the firmware and the key.

## Status

- **Vulnerability:** well-evidenced from the real binary + the car's own DLT logs.
- **Mechanism:** proven winnable — the genuine x86-64 `DecryptToPIPE`/`md5sum` run natively
  against a swapped file verifies A and installs B (done on the bench; see docs/03).
- **On-car swap:** the dynamic-USB gadget has **switched on the real head unit** (install
  pass flipped to EVIL). Remaining work is purely operational: keeping the Pi stable for
  the full multi-minute check+install so the *entire* evil rootfs is delivered, then
  confirming the on-device marker. See [`docs/04-field-journal.md`](docs/04-field-journal.md).

## Disclaimer

No license is granted and no warranty is given. This repository is published **as is**, for
**educational and defensive security-research purposes only**. To the maximum extent permitted
by law, the author disclaims all warranties and accepts **no liability** for any damage, data
loss, bricked hardware, or other consequences arising from its use.

- **Use only on hardware you own or are explicitly authorized to test.** Modifying a vehicle
  head unit can brick it, void warranties, and — on a vehicle in service — affect safety.
- **You are solely responsible** for ensuring your use complies with all applicable laws and
  regulations in your jurisdiction. The author does not condone, and is not responsible for,
  any unauthorized or unlawful use by others.
- This work was carried out on the author's **own, decommissioned, off-road** unit with a
  **benign** proof-of-concept payload; it is not a turnkey attack against anyone else's
  vehicle. See [`SECURITY.md`](SECURITY.md) for the full scope and authorization statement.
- **No affiliation or endorsement.** Not affiliated with, authorized, or endorsed by Hyundai,
  Kia, HKMC, LG Electronics, or the credited projects and individuals. All trademarks belong
  to their respective owners.
