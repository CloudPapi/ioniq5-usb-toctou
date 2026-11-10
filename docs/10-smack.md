# 10 — SMACK: can it be removed or neutered?

Feasibility study of defeating the SMACK LSM on the IONIQ 5 (Gen5W_L) head unit, given our control
model: the **TOCTOU exploit gives us a fully attacker-controlled rootfs**, but the **bootloader,
kernel, and initramfs are left genuine and are RSA-signed**. As of 2026-11-10. Owner's own
decommissioned, off-road unit (build 260128, Linux 4.1.27-abl, x86-64).

## TL;DR

| Goal | Feasible? | How |
|---|---|---|
| **Truly remove SMACK** (kernel layer) | **No** | compiled-in sole LSM; signed+encrypted boot image; no cmdline lever. Needs the RSA key or a bench boot-partition rewrite. |
| **Neuter it for *our own* code** | **Yes — low risk** | bake `SMACK64EXEC=Privileged` on our binaries → they get `CAP_MAC_OVERRIDE` and bypass all MAC. **This is the recommended path** (and it is the build #7 SSH approach). |
| **Neuter it system-wide** (free code we don't launch) | **Yes — higher risk / louder** | rewrite `smack_setup.sh` (skip `onlycap` lock + permissive) + star-label object trees. One lever (`bringup-switch`) is vendor-custom and needs a bench check. |

**Recommendation:** don't chase a general SMACK defeat. Run our code `Privileged`. It removes the
label-fighting from SSH, the dev-loader, `/app` writes, and the CarPlay patches **simultaneously**,
never flips global enforcement state (so no boot-loop hazard), is the stealthiest option, and
survives a genuine OTA re-running `smack_setup.sh`.

---

## Why true removal is infeasible

Confirmed from the extracted kernel config (`scratchpad/smackwf_kernel/kernel.config`):

- `CONFIG_SECURITY_SMACK=y`, `CONFIG_DEFAULT_SECURITY_SMACK=y`, `CONFIG_DEFAULT_SECURITY="smack"`;
  `SELINUX`/`APPARMOR`/`TOMOYO`/`YAMA` all **not set** → SMACK is the **default and sole** major LSM,
  and there is no alternative LSM to switch to.
- **Linux 4.1.27** predates the unified-LSM `lsm=` parameter, and there is no `smack=off`. The only
  below-userspace off-switch is the legacy `security=<name>` cmdline parameter.
- That parameter is **unreachable from the rootfs**: `CONFIG_CMDLINE_BOOL` is not set (no built-in or
  rootfs-appendable cmdline); the boot container `IONIQ5_EU/HU/images/iasImage` is **RSA-signed *and*
  encrypted** (full-entropy header, no readable `cmdline`/`root=` strings); and there is **no
  bootloader config** (`grub.cfg`, `extlinux.conf`, `uEnv.txt`, `boot.scr`) anywhere in the rootfs.

So setting `CONFIG_SECURITY_SMACK=n` or `security=none` would require re-signing the boot image with
the enforced key, or a bench eMMC/SPI rewrite that defeats the signature — both key/hardware-dependent
and outside rootfs scope. Consistent with [`memory: update-rsa-chain-enforced`].

> **Caveat (kernel identity):** the extracted `/boot/bzImage` config has `CONFIG_BLK_DEV_INITRD` **not
> set**, which conflicts with the genuine initramfs that generates `/tmp/passwd` etc. The kernel
> actually booting from the encrypted `iasImage` may differ slightly and cannot be verified
> statically. It does not change the removal verdict, but it is why the runtime levers below are
> stated with a bench-confirmation hedge.

---

## Why neutering *is* feasible: we own the control plane

SMACK enforcement is set up entirely in userspace, by files we control in the evil rootfs:

- **`/etc/smack_setup.sh` is the sole userspace writer of both kill-switch nodes** —
  `/sys/fs/smackfs/onlycap` (lines 48, 98) and `/sys/fs/smackfs/bringup-switch` (lines 45, 90).
  `update_start_5w.sh` only *reads* `onlycap` (line 189).
- It runs via `smack-setup.service` as a **root oneshot with no `SmackProcessLabel=`** — i.e.
  floor-labeled (`_`) with a full capability set — and **`onlycap` is still unset at that moment**
  (the genuine script writes `onlycap`/`bringup`/`chsmack` itself, which is only possible while
  unlocked). So our rewrite of this script runs with the same label, caps, and timing.
- `optUNECE` (the vendor's "non-UNECE → permissive" conditional) is a **built-in `micom` kernel
  cmdline parameter** we cannot flip from the rootfs; an EU unit is UNECE, so we must edit the script
  directly rather than rely on that path.

### SMACK rule reference (kernel built-ins)

| Construct | Effect |
|---|---|
| subject `*` | **denied everything** (never label *our* process `*`) |
| subject `^` (hat) | read/exec permitted on any object |
| object `_` (floor) | **read/exec permitted to all subjects** (use for read-only files, e.g. `authorized_keys`) |
| object `*` (star) | **any access permitted to all subjects**, even in enforcing mode (use where write is needed) |
| same label | permitted |
| `CAP_MAC_OVERRIDE` | **bypasses access rules entirely**; stays effective for the `Privileged` label under `onlycap=Privileged` |

---

## Approaches, ranked

Both an adversarial "will it brick" and an adversarial "does the mechanism actually work" review were
run. The key correction: **SMACK has no upstream global permissive mode** (the maintainer rejected
one); the BRINGUP `b` mode only *reports* granted accesses and does **not** convert denials to grants;
`bringup-switch` is a **vendor-custom node of unverified semantics**. So the docs-confirmed mechanisms
are the ones to lean on.

1. **Bake `SMACK64EXEC=Privileged` on our own binaries — PRIMARY** · feasibility high · risk low
   Set the `SMACK64EXEC="Privileged"` xattr (via `chsmack -e Privileged`, preserved in the tar) on our
   launchers / dropbear / dev-loader / CarPlay patches in the rootfs image. They execute as
   `Privileged`, keep `CAP_MAC_OVERRIDE` even after `onlycap` locks, and bypass all MAC. Never flips
   global state → zero boot-loop/MICOM hazard. OTA-durable. **Mechanism docs-confirmed.**

2. **Rewrite `smack_setup.sh` to never lock `onlycap`** · high · low (root only)
   With `onlycap` empty, `CAP_MAC_OVERRIDE` is effective for *any* label, so any **root** process
   bypasses MAC. Frees our root tooling broadly, but does **nothing** for non-root/app-labeled code.

3. **Star-(`*`)-label the object trees we write** · high · medium
   `chsmack -r -a '*'` (or baked `SMACK64='*'` xattrs) on `/app /var /home /rw_data` and data dirs. A
   star object is accessible to every subject even in enforcing mode — frees non-root consumers too.
   **Must exclude `/proc /sys /dev /run /tmp`** (relabeling `/dev/ttyS1` breaks the MICOM heartbeat).
   Mount options `smackfsroot`/`smackfsdef` do **not** retro-apply to the already-mounted rootfs → use
   baked xattrs there.

4. **Per-label `unconfined`** · high · low
   `echo <our-label> > /sys/fs/smackfs/unconfined` before `onlycap` locks → that one label bypasses
   checks as subject and object. Confirmed mechanism (`CONFIG_SECURITY_SMACK_BRINGUP=y`). Narrower
   than #1–3; always logged.

5. **Rewrite `smack_setup.sh` to global permissive (`bringup-switch=1`)** · speculative · needs bench
   The *only* lever that would free code we don't launch via a single switch — but `bringup-switch`
   is vendor-custom and may be log-only, not allow-all. Confirm by `dmesg`/behavior on the bench before
   trusting it. Positive sign: the OEM's own `AppUpgrade` writes `bringup-switch` and handles
   Enforce/Permissive during OTA, so permissive is an OEM-supported state in which the heartbeat
   survives.

### Do **not**

- ❌ **Mask the smackfs units** (`smack.mount` / `smack-setup*.service`) · risk high · brick. The kernel
  keeps enforcing with on-disk `App::`/`System::` xattrs while no rules load → cross-label denials
  system-wide → MICOM reset → boot loop. Masking the control plane does **not** disable enforcement.
- ❌ **`touch /etc/smackhi`** (the "nosmack" flag) · a **trap** on this UNECE/EU unit.
- ❌ **Recursive `chsmack` over `/`** · relabels `/dev` nodes → heartbeat break → boot loop.

---

## The one real brick path + recovery

There is **no SMACK attestation** anywhere in `ApplicationManager` / `micommanager_userspace` /
`watchdogd` (strings-scanned). The **only** brick mechanism is the **external MICOM watchdog**: if the
heartbeat chain (`ApplicationManager → micommanager → /dev/ttyS1 System::micominterface → MICOM`) is
**denied in enforcing mode**, MICOM hardware-resets the SoC → boot loop. This is triggered by a
**bad/half-done neuter** (masking smackfs, mis-relabeling `/dev`, a failed relabel in an enforcing
window), **not** by running `Privileged` or by a clean permissive-first change.

**Recovery:** re-flash a known-good rootfs via the same TOCTOU USB path (or, worst case, bench
eMMC/SPI rewrite). To stay recoverable:
1. go **permissive-first** so no denial occurs during any relabel;
2. keep `/etc/update_start_5w.sh.ori` labeled `SMACK64EXEC=Privileged`, or mask
   `smack-setup-recovery.service` — it has `Restart=on-failure`/`RestartSec=1s` and blanket-floor-
   relabels `/`, so it churns a whole-FS relabel every second and fights you otherwise (it is
   self-healing for app exec labels, but the churn can starve the heartbeat during a vulnerable
   window);
3. on first bench boot, read `/proc/self/attr/current` + `cat /sys/fs/smackfs/onlycap` at the top of
   our `smack_setup.sh` to confirm `onlycap` is unset and our label/caps are as expected before
   relying on any lever;
4. `bringup-switch=1` is a **non-persistent sysfs node** (cleared every reboot) — our script must
   re-assert it early on **every** boot, and we must confirm allow-all vs log-only by `dmesg`.

---

## Bottom line for this project

Neutering SMACK "in general" is possible but is the higher-risk, louder option, reserved for freeing
code we don't control. For everything we actually run, the clean move is **run `Privileged`** (bake
`SMACK64EXEC=Privileged`) — see the build #7 plan in [`docs/08`](08-handoff-ssh-wip.md). It is the same
mechanism that fixes SSH and it generalizes to the dev-loader, `/app` writes, and the CarPlay patches.

See also: [`docs/09`](09-wireless-carplay.md) (wireless CarPlay background) and
[`docs/11`](11-wireless-carplay-patches.md) (the CarPlay binary patches these labels are applied to).
