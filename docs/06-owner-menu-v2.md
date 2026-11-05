# v2 — on-HU Owner Tools menu + built-in-Wi-Fi dropbear SSH

Status: **flashed to the car (field test #1, 2026-11-05).** TOCTOU swap worked and the v2 rootfs
booted. **Two issues found on-car:** (1) **no Wi-Fi** (AP `IONIQ5-OWNER` did not appear); (2) the
**Owner Tools menu button overlapped another icon** and could not be pressed. Root cause was `SmackProcessLabel=Privileged`
(rejected by the car's systemd, status 237) killing both services — see §11. **Fixed image rebuilt
and armed** (md5 `acd8ec75…`, no `SmackProcessLabel`, button at x:540 y:380, Wi-Fi gate added);
awaiting **reflash #2**. The dev-loader itself was dead, so this one reflash is required; after it,
iteration is via USB/SSH. Scope: owner's **own, decommissioned, off-road** IONIQ 5 head unit (Gen5W_L, build **260128**,
x86-64, kernel 4.1.27-abl, systemd + SMACK). Benign: owner-keyed SSH + log/firewall helpers; no OEM
private key is used. Delivered via the existing USB-update TOCTOU rig (`arm.sh menu`).

## 1. Goal (what we are building)

A payload rootfs that, once swapped in by the TOCTOU install, gives the owner:
1. **SSH (dropbear) reachable over the HU's built-in Wi-Fi**, and
2. a **menu the owner can browse on the HU touchscreen** to manage it (open firewall, extract logs,
   status), reached through the stock Engineering Mode.

## 2. Ground truth (verified against the decrypted 260128 rootfs)

Inspected `ioniq-5-Reverse-Engineering/work/vm/vendor-a/vendor-rootfs.img` with `debugfs`
(read-only; **no TE2 key needed for inspection**). Corrects two earlier inference errors.

| Fact | Finding | How verified |
|---|---|---|
| **dropbear installed?** | **NO.** No `dropbear`/`dropbearmulti`/`ssh`/`sshd`/`telnetd` in `/usr/sbin` or `/usr/bin`; opkg `status` doesn't list it. Only the `dropbear@.service` *template* + opkg *alternatives* metadata ship. | `debugfs ls`/`stat` |
| Consequence | The old `proof.sh` SSH line `[ -x /usr/sbin/dropbear ] && …` was a **silent no-op**. | code read |
| **Wi-Fi radio** | **On the HU** — Broadcom **BCM4359/CYW89359**, PCIe, driver `bcmdhd.ko` + fw in `/lib/firmware/bcmdhd/`, interface **`wlan0`**. Cellular/telematics is a *separate* USB modem. | driver strings, `nvram.txt` (`ccode=GB`), DLT logs |
| Wi-Fi userspace **present** | `/usr/sbin/wpa_supplicant`, `/usr/sbin/iw`, `wpa_cli`, Broadcom `wl`, `connmand`/`connmanctl`, `/app/bin/supplicantmanager`, `/usr/bin/adb` | `debugfs` |
| Wi-Fi userspace **absent** | `hostapd`, `dnsmasq` | `debugfs` |
| **On-HU menu** | Real **Engineering Mode**: gesture + PIN `19480717` → `checkPassWord` → `21`=full / `11`=dealer. Rich, read/write. | QML line 391 |
| QML→shell bridge | Native objects (`AppEngineerModeEngine`, `IPInfo`, `SystemControl`, `WiFiDebugScreenHandler`, …) run programs via `QProcess`/`posix_spawn`. Screens load **by literal path** → a new page needs **no native recompile**. | `readelf`/strings + callsites |
| rootfs integrity | **No dm-verity**; SMACK active but `/app` not relabeled by `smack_setup.sh`; `onlycap` empirically empty. | fstab, `smack_setup.sh`, bench logs |

See also memory: `dropbear-not-installed`.

## 3. The size budget — proven to fit

The genuine plaintext `mango-rootfs.tar.gz` body is **exactly 879,109,759 bytes = the hard ceiling**
(TE2 envelope body; evil plaintext must be ≤ this, then zero-padded to exactly it). The OEM ships at
~gzip-6 level, i.e. zero slack as-shipped.

**Lever: recompress at `gzip -9`.** Measured on the real decrypted tar:

| Build | gzip size | vs ceiling |
|---|---|---|
| OEM as-shipped | 879,109,759 | 0 (full) |
| recompress `gzip -6` | 879,406,724 | **−296,965 (over)** |
| recompress `gzip -9` | 876,622,112 | **+2,487,647 headroom** |
| `gzip -9` + worst-case additions (incompressible 350 KB binary stand-in + text) | **876,982,086** | **+2,127,673 (FITS)** |

So recompression alone reclaims ~2.49 MB — the additions cost ~360 KB compressed (and a *real*
dropbear compresses, leaving more). **No pruning required.** If a future payload ever exceeds the
ceiling, prune candidates: `/whatsnew`, `/manual`, `/voicememo`, unused `/navi` assets.

This is why the undocumented v1 `foothold`/`menu` images could exist at all, and why the one recorded
IMEI build *failed* (+114 KB) — it added to the full-size tar **without** recompressing.

## 4. v2 payload design

Injected into the swapped rootfs (all paths relative to rootfs root):

| Path | Purpose |
|---|---|
| `usr/sbin/dropbearmulti` (+ `dropbear` symlink) | **bundled** static SSH server (binary pending, §6) |
| `etc/systemd/system/owner-access.service` (+ `multi-user.target.wants/` symlink) | boot oneshot, `SmackProcessLabel=Privileged`, runs `wifi-up.sh` |
| `etc/owner/wifi-up.sh` | load `bcmdhd` → AP via **ConnMan tethering** (DHCP; stock path) w/ static-AP fallback → start `dropbear -R -s -p 22` |
| `etc/wpa_supplicant/wpa_ap.conf` | fallback static-AP config (only if tethering fails) |
| `etc/dropbear/owner_authorized_keys` | owner public key (key-only auth) |
| `app/share/AppEngineerMode/qml/owner/OwnerTools.qml` | the on-HU page (menu mode only) |
| `app/share/AppEngineerMode/qml/AppEngineerMode_FullMain.qml` (patched) | adds the **Owner Tools** button |
| `etc/owner/dev-loader.sh` + `etc/systemd/system/toctou-devloader.service` (+ enable symlink) | **USB dev-loader**: runs `toctou_dev.sh` from a plugged stick as root whenever it changes (md5-gated, ~8 s poll ≈ hot-plug). Fast iteration with no reflash and no network. Sample: `payload/v2/toctou_dev.sh.sample`. |

**Menu wiring.** The Owner Tools button uses the literal-path popup
`Global.popupQmlOpen("/app/share/AppEngineerMode/qml/owner/OwnerTools.qml","")` — no native map
entry, no recompile. The page calls **only natives proven present**: `IPInfo.setIPTableDebug(1)`
(→ `iptables -F; -P INPUT ACCEPT`), `SystemControl.setLogModeOn()`, and
`WiFiDebugScreenHandler.getWiFiDriverStatus()/getMac()` for status. Wi-Fi+SSH bring-up itself is done
reliably by the **boot service**; a menu-driven start/stop toggle needs a native→script hook confirmed
on-device (open item §7).

**Access.** Owner joins SSID `IONIQ5-OWNER` (change it) → `ssh root@<HU-wlan0-ip> -p 22` with the
owner key. Static-AP fallback: HU `10.42.0.1/24`, owner laptop static `10.42.0.2/24`.

## 5. Build + arm procedure

Artifacts live in `pizero/`:
- `payload/v2/` — the files above + `inject_fullmain.py` (button injector)
- `payload/bin/dropbearmulti` — **slot, must be filled (§6)**
- `payload/authorized_keys` — put the owner's real pubkey here
- `build_v2.sh` — reproducible builder

```bash
# 0) key (gitignored) — never commit
printf '%s\n' '<32hex TE2 key>' > pizero/key.local && chmod 600 pizero/key.local
# 1) owner key
cp ~/.ssh/id_ed25519.pub pizero/payload/authorized_keys
# 2) build (decrypt -> inject -> gzip -9 -> assert <= ceiling -> pad -> TE2 encrypt -> verify)
./pizero/build_v2.sh menu /path/to/genuine/mango-rootfs.tar.gz  pizero/build/evil_rootfs_menu.te2
# 3) arm it on the Pi (already wired)
sudo ./arm.sh menu            # serves regions_menu.json -> evil_rootfs_menu.te2
```

`build_v2.sh` **asserts the ≤ 879,109,759 ceiling before encrypting** and does a decrypt round-trip
check. Recommended build host is the **Pi** (23 GB free; the workstation sits at ~3.7 GB free — too
tight for the 1.78 GB intermediate tar). Building on the Pi also needs `gen5w_decrypt.py` pushed there
(currently absent) + `key.local`.

## 6. The dropbear binary — RESOLVED

The HU has **no** dropbear, so v2 bundles one: **static `musl` x86-64 `dropbearmulti`**
(self-contained → runs on the HU regardless of its glibc 2.25; bundles its own crypto). Built from
official source 2022.83 with `musl-gcc`, `--disable-harden` (so `-static` works — the hardened build
forces `-fPIE`/`-pie` which collides with `-static`) + `LDFLAGS=-static`. Result:
**`ELF 64-bit x86-64, statically linked, stripped, 425 KB` (gz 222 KB)** at
`payload/bin/dropbearmulti`. (The fetch+compile step was user-run via `!` — the auto-mode sandbox
blocks the model from compiling external source.) Do **not** use Debian `dropbear-bin` (glibc-dynamic,
newer glibc than the HU's 2.25 → won't run).

## 7. Open items (need the real device / runtime)

- **dropbear build approval** (§6) — the one hard blocker.
- **SMACK label** on new `/app` QML — stamp `security.SMACK64` to match sibling eng-mode QML at repack.
- **Menu start/stop toggle** — confirm a native→fixed-script hook (e.g. `IPInfo.handleExecuteScriptOn`)
  to let the menu (not just the boot service) start/stop Wi-Fi+SSH.
- **`/tmp/no_unece`** Wi-Fi gate (`supplicantmanager.path`) — may need touching.
- **FullMain button x/y** (`inject_fullmain.py` uses x:80 y:470) — verify it doesn't overlap on-screen.
- **ConnMan tethering** SSID/PSK behavior on this build — verify vs the static-AP fallback.
- Final **on-car E2E**: insert Pi → run HU update → reboot → join SSID → SSH in → browse Owner Tools.

## 8. What is DONE vs PENDING

- DONE: ground-truth rootfs analysis; **fit proof**; all payload artifacts; FullMain button injector;
  reproducible `build_v2.sh` (gzip -9, ceiling assert, FullMain dedup, round-trip verify under correct
  basename); **static dropbearmulti built**; **`build/evil_rootfs_menu_v2.te2` built on the workstation
  and verified** — fits (876,849,520 ≤ ceiling, margin 2,260,239), `integrity_valid: true`, decrypts to
  a valid tar containing all payload + the patched FullMain button.
  Build host note: workstation (~1 min), NOT the Pi — the Pi is only for *arming*; the build was a disk
  concern only (peak ~2.66 GB vs 3.7 GB free, and `build_v2.sh` frees intermediates as it goes).
- PENDING: owner's **real** SSH pubkey into `payload/authorized_keys` (currently a placeholder) + rebuild;
  move the `.te2` to the Pi and point `regions_menu.json` at it, then `arm.sh menu`; on-car E2E (§7).

> Not committed, per instruction. `key.local` is gitignored regardless.

## 9. Field test #1 (2026-11-05) — flashed, two issues, live-fix in progress

**Result:** the car accepted the v2 update, the TOCTOU swap fired, and the swapped rootfs booted
(so dropbear/menu/dev-loader payloads are on the unit). Two problems observed:

1. **No Wi-Fi.** AP `IONIQ5-OWNER` never appeared → no SSH path. Root cause not yet known (needs the
   on-unit diagnostic report). Candidates: `bcmdhd` not auto-loaded / `wlan0` absent; the
   `supplicantmanager` `/tmp/no_unece` gate; ConnMan not managing wifi or the vendor "ACC mode"
   owning `wlan0`; tether API differences on this build.
2. **Owner Tools button unpressable** — it was injected at `x:80 y:470`, which overlaps the row-2
   `Config` button. The Full Eng menu is a 5×2 grid: x ∈ {80,310,540,770,1000}, y ∈ {90,380};
   row 2 has Config@80, LogSystem@310, Variant@770 → **x:540 y:380 is free**.

**Fixes:**
- `payload/v2/inject_fullmain.py` updated to place the button at **x:540; y:380** (future builds).
- Recovery path without reflashing is the **USB dev-loader**: `payload/v2/toctou_dev_fix1.sh`
  (copy to a FAT/exFAT stick root as `toctou_dev.sh`, plug into HU, wait ~20 s). It:
  proves the dev-loader ran; dumps Wi-Fi diagnostics; attempts driver load + `/tmp/no_unece` +
  ConnMan tether + static-AP fallback; (re)starts dropbear on :22; repositions the live menu button
  (effective after UI restart/reboot); and writes **`v2_report.txt`** back to the stick (also
  `/var/log/v2_report.txt`).

**Triage from the stick result:**
- `v2_report.txt` present → dev-loader works; iterate via USB (no reflash). Use the report to fix Wi-Fi.
- `IONIQ5-OWNER` appears → `ssh -i ~/.ssh/ioniq_toctou_test root@<ip>` (static fallback `10.42.0.1`).
- Neither → dev-loader didn't run either → fix in image + one more reflash.

## 10. Current state / artifacts (as of field test #1)

- **Workstation** `pizero/`: `build_v2.sh`; `payload/bin/dropbearmulti` (static musl x86-64, 425 KB);
  `payload/v2/{OwnerTools.qml, owner-access.service, wifi-up.sh, wpa_ap.conf, inject_fullmain.py,
  dev-loader.sh, toctou-devloader.service, toctou_dev.sh.sample, toctou_dev_fix1.sh}`;
  `payload/authorized_keys` = **test key** (private: `~/.ssh/ioniq_toctou_test`).
  `build/evil_rootfs_menu_v2.te2` md5 `82cb7d630d57b7c89d02620a9092a43e`.
- **Pi** (`10.10.10.153`, user sjl): v2 image pushed (md5 matches); `regions_menu_v2.json` +
  `arm.sh menu2` case; `arm.sh` teardown bug fixed (always tears down + kills nbdkit; backup
  `arm.sh.bak-prefix`). **Boot auto-arms v2** via drop-in
  `/etc/systemd/system/toctou-gadget.service.d/override.conf` (points the enabled service at
  `regions_menu_v2.json`). Verified armed-on-v2 after a reboot. Revert: delete the drop-in +
  `systemctl daemon-reload`.
- **Access/creds in play** (bench only): Pi SSH via askpass helper in the session scratchpad; TE2 key
  in `pizero/key.local` (gitignored, workstation) and `~/toctou-usb-update/pizero/key.local` (Pi);
  HU test SSH key `~/.ssh/ioniq_toctou_test`; HU eng-mode PIN `19480717`.
- **Connection (expected after Wi-Fi works):** SSID `IONIQ5-OWNER` / PSK `ChangeMe-OwnerPSK`
  (placeholders), dropbear :22, static fallback HU `10.42.0.1` (laptop `10.42.0.2/24`).
- **No-flash shell paths ruled out:** adb (no `adbd`), serial console (gated, needs creds),
  eng-mode IP-shell (numeric-only input, not injectable). TOCTOU foothold remains the way in.

> Not committed. `key.local` and the test private key are gitignored / outside the repo.

## 11. Field test #1 — ROOT CAUSE (from HU DLT logs)

The on-car DLT export (`dltlog/`) showed **both** injected services failing at spawn:

```
owner-access.service:   Failed at step SMACK_PROCESS_LABEL spawning /etc/owner/wifi-up.sh: Operation not permitted
owner-access.service:   Main process exited, code=exited, status=237/SMACK_PROCESS_LABEL
toctou-devloader.service: Failed at step SMACK_PROCESS_LABEL ... status=237/SMACK_PROCESS_LABEL   (x173, Restart loop)
```

**Root cause:** `SmackProcessLabel=Privileged` is **rejected by the car's systemd** (status 237,
"Operation not permitted") — PID1 cannot assign the `Privileged` SMACK label on the real unit,
contrary to the bench's empty-`onlycap` observation. Because *both* v2 services set it, **neither
ran** → no `wifi-up.sh` (no Wi-Fi) and no dev-loader (couldn't self-fix). Latent since v1: the IMEI
"proof" was the baked QML label, not a service, so `wideopen.service`'s identical failure went unseen.

**Good news from the same logs:** the Wi-Fi driver is healthy — `bcmdhd` loaded, firmware
(`rtecdc.bin`, `nvram.txt`, `4359b1.clm_blob`) "open success", `dhd_bus_start` ran. So once the
service executes, AP bring-up is viable.

**Fix (v2 rebuild):**
- Removed `SmackProcessLabel=Privileged` from `owner-access.service` and `toctou-devloader.service`
  (inherit PID1's label, like stock connman/wpa_supplicant/dropbear). `RestartSec` 5→15 on the
  devloader to avoid a restart storm.
- Hardened `wifi-up.sh`: `touch /tmp/no_unece` (vendor Wi-Fi gate) + `rfkill unblock all` + logging
  to `/var/log/wifi-up.log`.
- Menu button already moved to `x:540 y:380` in `inject_fullmain.py`.

**Consequence:** one more reflash is required (the dev-loader itself was dead, so it can't self-fix).
After this reflash the dev-loader should run → all further iteration is via USB, no more reflashes.
If Wi-Fi still doesn't come up post-reflash, the dev-loader report (`v2_report.txt` / `wifi-up.log`)
will show why and we fix it over USB.

## 12. Field test #2 — SMACK fix worked; found bug #2 (EXEC) + menu polish

From the HU DLT export taken 11:03 (covering 10:46→11:03, the fixed image booted):
- **`237/SMACK_PROCESS_LABEL` count = 0** (was 1145). The `SmackProcessLabel` removal **worked** — the
  fixed image booted (button visible at slot 3 confirms it).
- **New failure:** `Failed at step EXEC spawning /bin/check-mount.sh: Permission denied` — a *vendor*
  script hitting an **EXEC permission-denied under SMACK**. Our `/etc/owner/*.sh` hit the same wall:
  the services start but SMACK blocks *executing* the shell scripts, so neither ran (no `v2_*.txt`,
  no `/var/log/wifi-up.log` anywhere in the export).

**Fix (build #4):** change both units to `ExecStart=/bin/sh /etc/owner/<script>` — exec the stock
`/bin/sh` (valid SMACK exec label) and have it *read* the script, sidestepping the exec block. (The
dev-loader already runs the USB script via `sh "$s"`, so stick scripts were never affected.)

**Also in build #4:** Owner Tools button moved to **slot 4 (x:770 y:380)** with a real **icon**
(`ico_engineering_config` n/p/f — `ico_home_wifi` lacks a focus variant). Text-only before (no
`bgImage`), which is why it was hard to spot.

**Timing lesson:** several field-test exports/stick-tests were taken *before* the newest reflash had
finished + rebooted, so they re-showed the old bug. Confirm the HU has rebooted onto the new image
(e.g. button at the new slot) before pulling logs / testing the stick.
