# 08 — Handoff: SSH-over-Wi-Fi WIP + resume state

Snapshot for picking the work back up. As of 2026-11-08. Owner's own decommissioned, off-road
IONIQ 5 head unit (Gen5W_L, build 260128). Nothing here contains secrets — the TE2 key lives in
`pizero/key.local` (gitignored) and the Pi password / owner SSH key are supplied out of band.

## TL;DR — where we are

- TOCTOU flash, USB dev-loader, and the Wi-Fi AP all **work** (see `README.md` status).
- **Immediate open task:** get an authenticated SSH shell over the AP. The full root-cause chain
  is identified and fixed piecewise; one last reason is being captured from dropbear's own log.
- **Next action:** read `v2_dblog.txt` from the stick (collector already staged — see below).

## Environment state

| Thing | State |
|---|---|
| HU (head unit) | running **build #5** (`evil_rootfs_menu_v2.te2` md5 `5a367114…`): has the Wi-Fi watchdog, **not** the menu import fix, **not** the SSH runtime fixes |
| Pi gadget (`sjl@10.10.10.153`, password auth) | armed `menu2` serving **build #6** (`c751a218c7a6619f7a9efb21f4b0f0f2`); boot drop-in re-arms on reboot |
| build #6 | = build #5 + corrected `OwnerTools.qml` imports (the menu fix). On the Pi, **not yet flashed** to the HU |
| USB stick (`NEW VOLUME`, mounts on HU at `/media/usb/1/F851-D951/`) | `toctou_dev.sh` = **`v2_dblog.txt` collector** (md5 `5b7f2d3b…`) + `OwnerTools.qml` |
| Pi access from workstation | password-only; this session used a pty helper (`scratchpad/pssh.py`, not persisted). To resume: recreate it, install an SSH key, or type the password. |

## SSH-over-Wi-Fi: root-cause chain

Each row was found live via the dev-loader and fixed; the shell-fix run applied all of them in one
pass and login **still failed**, so dropbear's exact stderr for that attempt is being collected.

| # | Blocker | Fix applied (runtime, via dev-loader) | Status |
|---|---|---|---|
| 1 | `iptables` INPUT policy `DROP` (vendor `HARDEN`/`WL_STATIC_IN`) blocks inbound `:22` | `iptables -I INPUT 1 -i wlan0 -j ACCEPT` (+ `--dport 22`) | ✓ TCP now connects |
| 2 | dropbear `-R` writes host key to read-only `/etc/dropbear` → drops mid-KEX | pre-gen host key in `/run` (`dropbearkey`), bind-mount writable `/etc/dropbear` with it / start `-r` | ✓ KEX completes, host key offered |
| 3 | `authorized_keys` missing — `/home` read-only, runtime copy failed | tmpfs `/run/roothome`, bind-mount over `/home/root` | ✓ key present (matches client `SHA256:lAwf+2ZG…`) |
| 4 | `/home/root` is `0775` (group-writable) → dropbear strict-perms rejects | bind-mounted home is `0700`, `.ssh` `0700`, `authorized_keys` `0600`, owned root | ✓ perms correct |
| 5 | root shell is `/usr/sbin/nologin` in `/etc/passwd` | bind-mount patched `/etc/passwd` → root shell `/bin/sh` | ✓ shell now `/bin/sh` |
| 6 | **still** `Permission denied (publickey)` after 1–5 together | run dropbear `-F` (logs to stderr; build is `--disable-syslog`, **no `-E`**) to `/run/db.log` | ⏳ capture pending |

Last client log ended at `No more authentication methods to try. / Permission denied (publickey)`
with the correct key offered — so #6 is server-side. The staged collector reads `/run/db.log`,
where the `-F` dropbear (started in the shell-fix run) recorded the actual reason for that attempt.

### Resume step (SSH)

1. On the HU (build #5, **do not reboot** — tmpfs state from the shell-fix run must survive), plug
   the stick in ~20 s, pull it.
2. Read `v2_dblog.txt`. It contains `/run/db.log` — dropbear's stderr for the failed auth
   (expect something like `exit before auth`, `bad authorized_keys`, `pubkey no match`, or an
   exec/shell error). That names the remaining cause.
3. If the HU **was** rebooted (tmpfs cleared, `/run/db.log` gone), re-run the all-in-one fix
   `payload/v2/toctou_dev_sshall.sh` (or `toctou_dev_shell.sh`) first, attempt SSH, then collect.

SSH client: `ssh -i ~/.ssh/ioniq_toctou_test -o IdentitiesOnly=yes root@10.42.0.1`
(AP `IONIQ5-OWNER` / `ChangeMe-OwnerPSK`).

## When SSH is confirmed — fold into the image

Move the proven runtime fixes from the dev-loader scripts into `pizero/payload/v2/wifi-up.sh`
(and `build_v2.sh` where a baked file is better), then rebuild + reflash:

- open `:22` on `wlan0` (iptables ACCEPT) at bring-up;
- ship a pre-generated ed25519 host key and start dropbear with `-r` (no write to `/etc`);
- place `authorized_keys` so dropbear accepts it despite read-only `/home` and group-writable
  `/home/root` (bind-mount a `0700` home, or bake `/home/root` at `0700` with the key);
- give root a usable shell (patched `/etc/passwd` bind, or set at build time).

Full constraint list: `docs/07-build-and-flash-runbook.md` §11.

## Menu entry (separate open task)

`OwnerTools.qml` import paths were wrong for `qml/owner/` (`./Component` → `../Component`, missing
`../System`); fixed in source and baked into **build #6**. `/app` is read-only at runtime, so this
can only land via a **flash**. Build #6 is already on the Pi and armed — flashing it tests both the
menu fix and leaves the SSH work to the dev-loader. (Design: `docs/06`; reproduction: `docs/07`.)

## dev-loader scripts (in `pizero/payload/v2/`)

Stage any of these on the stick as `toctou_dev.sh`; the dev-loader runs it as root once per md5.

| Script | Purpose |
|---|---|
| `toctou_dev.sh` | benign read-only probe (writes `v2_hello.txt`) |
| `toctou_dev_diag.sh` | read-only: listen `:22` via `/proc/net/tcp`, wlan0, services |
| `toctou_dev_net.sh` | dump + open the firewall (INPUT) for `wlan0`/`:22` |
| `toctou_dev_sshall.sh` | all-in-one: firewall + host key + 0700 home + dropbear (env fix) |
| `toctou_dev_shell.sh` | the above **+** patch root shell to `/bin/sh`; start logging dropbear |
| `toctou_dev_dblog.sh` | **(staged now)** read `/run/db.log` — dropbear's auth decision |
| `toctou_dev_qmlpatch.sh` | (defunct) tried to patch `/app` QML — blocked by read-only `/app` |

Reproduction / build & flash: `docs/07`. Design: `docs/06`.
