# 08 — Handoff: SSH-over-Wi-Fi WIP + resume state

Snapshot for picking the work back up. As of 2026-11-08. Owner's own decommissioned, off-road
IONIQ 5 head unit (Gen5W_L, build 260128). Nothing here contains secrets — the TE2 key lives in
`pizero/key.local` (gitignored) and the Pi password / owner SSH key are supplied out of band.

## TL;DR — where we are

- TOCTOU flash, USB dev-loader, and the Wi-Fi AP all **work** (see `README.md` status).
- **Root cause of the SSH failure: FOUND** (2026-11-09, via offline rootfs analysis). The earlier
  "fix" that bind-mounted a tmpfs over `/home/root` is what *broke* it — see
  **[Root cause (found)](#root-cause-found)** below. Short version: the keyfile ended up with a
  SMACK label dropbear's process could not read, and because our dropbear has no `DEBUG_TRACE`
  the denial was logged nowhere → silent `Permission denied (publickey)`.
- **Next action:** run `toctou_dev_sshfix.sh` (drops the bind-mounts, floor-labels the key chain,
  runs dropbear `Privileged`); if the runtime path is blocked by the `onlycap=Privileged` gate,
  its diagnostics tell us exactly what to bake into **build #7**. See
  **[Build #7](#build-7--bake-ssh-in-the-oem-way)**.

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
| 3 | `authorized_keys` missing — write to `/home/root` failed (**actually a SMACK write denial**, not read-only: `/home -> rw_data/home` is rw) | tmpfs `/run/roothome`, bind-mount over `/home/root` ⚠️ **this caused the final failure** | ✗ see root cause |
| 4 | `/home/root` is `0775` (group-writable) → dropbear strict-perms rejects | bind-mounted home is `0700`, `.ssh` `0700`, `authorized_keys` `0600`, owned root | ✓ perms, ✗ label |
| 5 | root shell is `/usr/sbin/nologin` in `/etc/passwd` | bind-mount patched `/etc/passwd` → root shell `/bin/sh` | ✓ shell now `/bin/sh` |
| 6 | **still** `Permission denied (publickey)` after 1–5 together | *was* "capture dropbear stderr"; **now root-caused** → see below | ✓ cause found |

<a name="root-cause-found"></a>
## Root cause (found)

Offline analysis of the genuine rootfs (`etc/smack_setup.sh`, `lib/systemd/system/dropbear@.service`,
`etc/dropbear/*`, the fstab variants, and our own `dropbearmulti`) explains the silent failure and
shows the earlier workaround was self-inflicted:

1. **`/home` and `/var` are symlinks into `/rw_data`** (`/home -> rw_data/home`), and `/rw_data`
   (`mmcblk0p11`) mounts **read-write**. So `/home` was never an inherently read-only partition —
   our "read-only /home" (chain row 3) was actually a **SMACK write denial**.
2. **SMACK privilege model.** `smack_setup.sh` runs `echo "Privileged" > /sys/fs/smackfs/onlycap`.
   With `onlycap` set, **only a process whose SMACK label is `Privileged` may use capabilities**
   (incl. `CAP_MAC_OVERRIDE`). A root process that is *not* `Privileged` is still bound by SMACK —
   which is why our root dev-loader could not write `/home` or `chmod`/relabel freely.
3. **The fatal step.** Chain rows 3–4 bind-mounted a tmpfs (`/run/roothome`) over `/home/root` to
   get writable, `0700` perms. That tmpfs dir + its `authorized_keys` carried a tmpfs SMACK label,
   **not** one dropbear's (non-`Privileged`) process could read. dropbear's `open()` of
   `authorized_keys` returned `EACCES`; dropbear treats an unreadable keyfile as "no key" and sends
   `userauth_failure` → the client's correct key is offered and still rejected.
4. **Why nothing was in the log.** Our `dropbearmulti` is built without `DEBUG_TRACE` (confirmed:
   no trace strings; `-v` is client-only). The keyfile-open `EACCES` path is `TRACE`-only, so with
   trace compiled out the server logs **nothing** — only ownership/mode failures emit
   `"%s must be owned by user or root, and not writable by group or others"`. Hence a *silent*
   `Permission denied (publickey)` that no amount of perms/shell fixing could cure.

**In one line:** the key was unreadable to the server because of its SMACK label (a side effect of
our own bind-mount), and the no-`DEBUG_TRACE` build hid the denial.

### The fix (two forms)

- **Runtime (`toctou_dev_sshfix.sh`):** no bind-mounts. Redirect root's home via `/tmp/passwd`
  (a tmpfs symlink target — `/etc/passwd -> /tmp/passwd`) to `/run/sshroot`, write
  `authorized_keys` there, and **floor-label (`_`) the chain** (SMACK built-in: *any* subject may
  read a floor object). Run dropbear from a `/run` copy marked **`SMACK64EXEC=Privileged`** so it
  bypasses SMACK regardless of our own label. Open `:22`, generate an ed25519 host key in `/run`,
  log to `/run/db.log`. It also captures the on-device SMACK facts (self label, `onlycap`, path
  labels, writability) — needed to bake build #7 if the runtime path is privilege-blocked.
- **Permanent (build #7):** see below.

<a name="build-7--bake-ssh-in-the-oem-way"></a>
## Build #7 — bake SSH in, the OEM way

The OEM already ships the scaffolding (`dropbear@.service`, `/etc/default/dropbear`,
`/etc/dropbear/authorized_keys`, `dropbear_publickey_installer.sh`) but **not the binary**, and
gates it on `/tmp/secure_console_disable` + `passwd.legacy` — both decided in the **initramfs**,
which the TOCTOU attack leaves genuine, so on a secure unit SSH never comes up. Since we build the
evil rootfs, bake a self-contained, `Privileged` SSH bring-up that does not depend on the
initramfs:

1. Ship `dropbearmulti` at a known path and set **`SMACK64EXEC=Privileged`** on it at build time
   (`chsmack -e Privileged`, preserved in the tar xattrs) → dropbear runs `Privileged`,
   sidestepping every SMACK/label issue.
2. Put the **owner** ed25519 key in `authorized_keys` (replace the OEM `rsa-key-20181102`).
3. A tiny `Privileged` systemd unit (or fold into `wifi-up.sh`) at boot: open `:22` on `wlan0`;
   set root's shell to `/bin/sh` and home to a readable dir (edit `/tmp/passwd`, or bake
   `passwd.legacy` as the active `/tmp/passwd`); generate/host a key in `/var/dropbear` (writable);
   start `dropbear -r <hostkey> -p 22`.
4. **Label changes don't boot-loop:** `check_label_final` only logs "Relabel is required." on a
   mismatch (no halt). The boot-loop risk is from missing/broken *services*, not labels.

Roll this into the build that already carries the menu-import fix → one flash delivers **menu +
SSH** (supersedes build #6).

### Resume step (SSH)

1. Stage `toctou_dev_sshfix.sh` on the stick as `toctou_dev.sh` **and** copy `dropbearmulti` next
   to it (the script uses it if the on-HU path isn't found). Plug in ~20 s, pull.
2. Read `v2_sshfix.txt` (section **A** = the SMACK diagnosis; section **F** = whether dropbear came
   up `Privileged`).
3. Try: `ssh -i ~/.ssh/ioniq_toctou_test -o IdentitiesOnly=yes root@10.42.0.1`
   (AP `IONIQ5-OWNER` / `ChangeMe-OwnerPSK`). If you get a shell → done.
4. If not (and **do not reboot**): plug the `toctou_dev_dblog.sh` collector (different md5) to pull
   `/run/db.log` with the server-side reason for that attempt.
5. Either way, use section A's labels/`onlycap`/`Privileged`-elevation result to finalize build #7.

## When SSH is confirmed — fold into the image

Superseded by **[Build #7](#build-7--bake-ssh-in-the-oem-way)** above (the `Privileged`-dropbear
bake). Do **not** re-use the old bind-mount-a-0700-home approach — that is exactly what caused the
SMACK keyfile denial. Full constraint list: `docs/07-build-and-flash-runbook.md` §11.

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
| `toctou_dev_sshfix.sh` | **(use this)** root-caused fix: no bind-mounts; floor-labeled key chain in `/run/sshroot`; dropbear run `Privileged`; + full SMACK diagnosis |
| `toctou_dev_sshall.sh` | (superseded) all-in-one: firewall + host key + 0700 home + dropbear (env fix) |
| `toctou_dev_shell.sh` | (superseded) the above **+** patch root shell to `/bin/sh`; start logging dropbear |
| `toctou_dev_dblog.sh` | read `/run/db.log` — dropbear's auth decision (collect after an SSH attempt) |
| `toctou_dev_qmlpatch.sh` | (defunct) tried to patch `/app` QML — blocked by read-only `/app` |

Reproduction / build & flash: `docs/07`. Design: `docs/06`.
