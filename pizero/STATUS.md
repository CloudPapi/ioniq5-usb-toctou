# Pi Zero TOCTOU toolkit — status

Scope: owner's **decommissioned, off-public-road IONIQ 5** (build 260128). Right-to-repair /
own-device jailbreak research. Benign proof payload only.

## Result: the size blocker is solved, and exploitability is proven with a REAL image

The earlier blocker — the patched `mango-rootfs.tar.gz` came out **114 KB larger** than the
genuine body, so it wouldn't fit the same filesystem extent the TOCTOU swap depends on — is
resolved.

Root cause: the OEM did **not** compress with the `gzip` CLI. The genuine gzip header has
`XFL=0` (a zlib/optimized encoder), and it packs tighter than `gzip -9`, so a `gzip -9`
recompress overshoots by ~0.013%. **libdeflate level 10** packs ~1.2% tighter than `gzip -9`
on this data, clearing it with **~18.7 MiB to spare**. Compression is done in **concatenated
gzip members** (64 MB each) so it needs ~110 MB RAM instead of ~2.7 GB.

Verified end to end (`build/evil_rootfs.te2`):

| property | genuine `mango-rootfs.tar.gz` | built `evil_rootfs.te2` |
|---|---|---|
| envelope size | 879,126,179 | **879,126,179** (identical) |
| body size | 879,109,759 | **879,109,759** (identical) |
| IV (basename `mango-rootfs.tar.gz`) | `5412d68d…715326` | **`5412d68d…715326`** (identical) |
| TE2 metadata integrity | valid | **valid** |
| decrypts to | genuine rootfs (66,836 members) | patched rootfs (66,839 members) |
| payload present | — | `etc/systemd/system/wideopen.service` (+ enable symlink, `wideopen_authorized_keys`) |

So the "malicious image" the swap serves at install time is now a **real, byte-exact,
IV-identical, integrity-valid TE2 envelope** that decrypts to a working patched rootfs — not the
stand-in `tar.gz` the original mechanism PoC used. This is the research conclusion: **the
verify-then-install TOCTOU is exploitable with a genuine-looking encrypted image, no OEM private
key needed** (the genuine signed image passes the check; the swapped image installs).

## Toolkit files

| file | role | state |
|---|---|---|
| `nbdkit_toctou.py` | dynamic backing store: serves benign bytes for the rootfs region during the verify pass(es), evil bytes during the install pass | selftest OK |
| `te2_encrypt.py` | encrypt a plaintext into a size/IV-identical TE2 envelope (IV from target basename) | round-trip OK |
| `chunkgz.py` | low-memory libdeflate compressor (concatenated gzip members) | used by `01` |
| `01_make_evil_rootfs.sh` | genuine → inject benign payload → fit → pad → TE2-encrypt → verify | **works** (produces `build/evil_rootfs.te2`) |
| `02_build_usb_image.sh` | lay the genuine update package on exFAT/ext4 (rootfs first = contiguous), compute its extent, emit `regions.json` | needs root/loop; run on the bench |
| `04_preflight.sh` + `preflight.py` | **go/no-go gate** (VM Path-1 ground truth): baseline md5 = signed value, evil extent/shape, real x86-64 `DecryptToPIPE`(evil)==`f83bdd`, and a live plugin dry-run on the real `usb.img`+`regions.json` (pass#1 genuine, pass#2 evil) | **A/B/C/D pass on bench** |
| `payload/wideopen.service` | benign proof-of-root marker: writes `/var/log/TOCTOU_ROOT_PROOF` (`id`), appends owner's key, optional dropbear on :2222 | — |
| `build/evil_rootfs.te2` | the fitted, verified patched envelope | built |

## Deployment — Pi bring-up (see DEPLOY.md)

The last mile — bring the Pi up as a dynamic USB mass-storage device the HU reads, and drive the
genuine→evil swap per read-pass — is `03_deploy_gadget.sh` (+ `99_teardown.sh`), with the full
step-by-step in **`DEPLOY.md`**. It is standard, publicly-documented Linux:

- **nbdkit** (Python plugin) serving `build/usb.img` with `nbdkit_toctou.py` + `regions.json`,
  on `127.0.0.1:10809`.
- **nbd-client** attaching that export to `/dev/nbd0` (readahead 0 so the swap isn't masked).
- **configfs USB gadget** (`libcomposite` + `f_mass_storage`, `lun.0/file=/dev/nbd0`) bound to the
  Pi's **dwc2** UDC.
- The rootfs (879 MB) exceeds the Pi Zero 2 W's RAM (512 MB), so neither the Pi nor the HU can
  cache it — every read pass reaches the plugin, which is what makes the per-pass swap reliable.

`toctou.log` shows 1-based physical read passes: `pass #1` (`md5sum` check → genuine) then `pass #2`
+ `*** SWITCH ***` (`DecryptToPIPE` install → evil). VM Path-1 proved the rootfs is opened exactly
twice (the RSA verify is over `md5sum.txt`, not a rootfs re-read), so `switch_after_pass=2` is
correct; the log is authoritative — bump it only if your unit's install lands on a later pass.
Proof-of-execution: the 4 channels below.

## Mitigation (for disclosure)
Verify-and-use-the-same-bytes: copy to trusted local storage then verify+install the local copy;
or hash-while-installing in one pass vs the signed digest; or dm-verity the rootfs. None present.

---

## Proof-of-execution: how the diagnostic export works, and 4 independent channels

**How the owner's diagnostic export captures data** (from `app/bin/AppLogExtractor` in the HU
rootfs): it is a plain copier — for each category it runs `cp -r /log_data/<cat>/ <dest>`, tars the
result to USB, then `rm -rf`'s the originals. It does **not** run `dmesg`/read the ring buffer at
export time. So whatever sits as a file in a `/log_data/*` category at export time is captured
verbatim. Categories copied include: `log, AppUpgrade, audit, dltlog, kernel, fs_log, ramoops,
telematics, vcrm, mof, backtrace, navi_log, BT, idtc, CaptureImage`.

**False-negative analysis:** `/dev/kmsg` is **not** reliable — it routes through the kernel→DLT
adapter into rotating files in `/log_data/kernel/` (`Log::dlt`), which can drop by loglevel or
rotation. Treat it as last-resort only. The deterministic channel is a plain file dropped directly
into a copied `/log_data/*` dir.

**SMACK:** the unit runs SMACK enforcing with `onlycap=Privileged`; `/log_data/log` is
`Log::engineermode`, `/log_data/kernel` is `Log::dlt`. But the TOCTOU installs **our** rootfs, so we
own the SMACK policy and run the proof service with `SmackProcessLabel=Privileged`, and label the
proof files `Log::engineermode` (the label the real exports prove the extractor reads). So the write
is self-granted, not subject to the stock policy.

**The 4 channels (independent failure modes):**
1. **T1 — export file drop (deterministic):** `proof.sh` writes `TOCTOU_PROOF.txt` (id, uname, date)
   into `/log_data/{log,AppUpgrade,audit,dltlog}`, each labeled `Log::engineermode`. Observe: pull a
   diagnostic export, `grep -r TOCTOU_PROOF`. (Fails only if: no export taken, or SMACK write blocked.)
2. **T2 — visible menu text (no export, no tools):** a deep, purely-cosmetic label is patched in
   **Settings > General > System Information > Modem Information** — the hardcoded `text: "IMEI: "`
   becomes `"IMEI [TOCTOU-PoC]: "` (plain-text QML, all trim variants: eco3.0/new2.0/genesis).
   Observe: read the screen. Chosen over the version string because it touches **no** functional
   field and **no** version/update-compare logic. (Fails only if that screen/variant isn't the one
   the car renders — hence all variants patched.)
3. **T3 — live root shell (no export, no logs):** `proof.sh` installs the owner key and starts
   `dropbear` on the `dbg0` ethernet `192.168.1.100:2222`. Observe: `ssh root@192.168.1.100 -p 2222`
   from the bench laptop and run anything. (Fails only if no network to the dbg0 NIC.)
4. **T4 — kmsg/ramoops (free, lossy):** marker to `/dev/kmsg`; may persist via pstore. Last resort.

T2 and T3 are fully independent of `/log_data`+SMACK; T1 is independent of the UI and network. A
successful swap is therefore observable by at least one channel under any single failure. A *true*
negative (failed swap → old rootfs) shows none of them, which is the desired behaviour.

Payload files: `payload/proof.sh`, `payload/wideopen.service` (Privileged oneshot), `payload/
authorized_keys` (replace with owner key). Baked by `01_make_evil_rootfs.sh`.

## LIVE PI — DEPLOYED, ARMED, AUTO-START (2026-11-04)
Brought up on the real Pi Zero 2 W (`10.10.10.153`, host `toctou`, Debian 13, kernel 6.18).
Prereqs green: deps present (nbdkit 1.42.3 + python plugin, nbd-client 3.26.1, exfatprogs),
genuine `mango-rootfs.tar.gz` staged (md5 `7f510002…`), **preflight A/B/D PASS** (C skips on ARM).
Gadget is **bound and armed**: UDC `3f980000.usb` (dwc2 peripheral), `/dev/nbd0` = 27 GB, nbdkit
serving, host sees VID:PID `0781:5591` "USB DISK". `toctou-gadget.service` (copy kept here) is
**enabled** and verified to auto-present the gadget across reboots. Swap counter starts clean
(`grep -c 'pass #' /var/log/toctou.log` = 0).

Five bugs found+fixed on the live Pi (full detail in `DEPLOY.md` → "Fixes applied …"):
(1) dwc2 overlay was under `[cm5]` so no UDC ever appeared → moved to `[all]`;
(2) `03`: `test -S /dev/null` aborted under `set -e` → `test -c`;
(3) `03`: LUN `file` written before `ro` → "resource busy" → `file` written last;
(4) `nbdkit_toctou.py`: declared API v2 but used the v1 `pread` (int / return-bytes) → every real
    nbdkit read threw `int + memoryview` → `pread` now fills the buffer (preflight D never caught
    this: it calls the plugin directly with an int, bypassing the real nbdkit API);
(5) boot race: `nbd-client` getaddrinfo on 127.0.0.1 failed before `::1` existed → retry loop in
    `03` + unit ordered `After=network-online.target`.

Still bench/car-only: C (x86-64 `DecryptToPIPE`) on the bench, and physical insertion into the HU.
