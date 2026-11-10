#!/usr/bin/env python3
# Apply the wireless-CarPlay gate patches to the genuine webOS /app binaries.
# Reproducible recipe for docs/11-wireless-carplay-patches.md. The firmware-derived
# binaries are NOT in this repo (gitignored); supply the owner's genuine files.
#
# Usage:
#   python3 -I apply_carplay_patches.py --in <genuine_app_dir> --out <patched_app_dir>
#     (reads <in>/app/bin/<name>, writes <out>/app/bin/<name>)
#   python3 -I apply_carplay_patches.py --file iAP2Service-2.0=/path/to/stock --out-file /path/to/patched
#   python3 -I apply_carplay_patches.py --verify-only --in <dir>   (check stock hashes, patch nothing)
#
# Each target is verified by whole-file stock sha256 BEFORE patching and by patched
# sha256 AFTER, with size unchanged -- so a wrong/updated firmware build is rejected,
# not silently mis-patched. Run under `python3 -I` (the inputs are untrusted firmware).
import argparse, hashlib, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))

def sha256(b): return hashlib.sha256(b).hexdigest()

def apply_target(t, data, verify_only=False):
    name = t["name"]
    if len(data) != t["size"]:
        raise SystemExit(f"[{name}] FAIL: size {len(data)} != expected {t['size']}")
    got = sha256(data)
    if got != t["stock_sha256"]:
        raise SystemExit(f"[{name}] FAIL: stock sha256 mismatch\n  expected {t['stock_sha256']}\n  got      {got}\n  (wrong file or a different firmware build)")
    print(f"[{name}] stock sha256 OK")
    if verify_only:
        return None
    buf = bytearray(data)
    for e in t["edits"]:
        off = int(e["file_offset"], 16)
        stock = bytes.fromhex(e["stock"]); new = bytes.fromhex(e["patched"])
        cur = bytes(buf[off:off+len(stock)])
        if cur != stock:
            raise SystemExit(f"[{name}] FAIL: at 0x{off:x} expected {stock.hex()} got {cur.hex()}")
        buf[off:off+len(new)] = new
        print(f"[{name}] 0x{off:x}: {stock.hex()} -> {new.hex()}  ({e['meaning']})")
    out = bytes(buf)
    if len(out) != t["size"]:
        raise SystemExit(f"[{name}] FAIL: size changed by patch")
    got = sha256(out)
    if got != t["patched_sha256"]:
        raise SystemExit(f"[{name}] FAIL: patched sha256 mismatch\n  expected {t['patched_sha256']}\n  got      {got}")
    print(f"[{name}] patched sha256 OK ({got[:16]}…)")
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", default=os.path.join(HERE, "manifest.json"))
    ap.add_argument("--in", dest="indir", help="genuine dir containing app/bin/<name>")
    ap.add_argument("--out", dest="outdir", help="output dir (mirrors app/bin/<name>)")
    ap.add_argument("--file", help="single target as NAME=/path/to/stock")
    ap.add_argument("--out-file", help="output path for --file")
    ap.add_argument("--verify-only", action="store_true")
    a = ap.parse_args()
    man = json.load(open(a.manifest))
    targets = {t["name"]: t for t in man["targets"]}

    if a.file:
        name, path = a.file.split("=", 1)
        t = targets[name]
        out = apply_target(t, open(path, "rb").read(), a.verify_only)
        if out is not None and a.out_file:
            open(a.out_file, "wb").write(out); print(f"[{name}] wrote {a.out_file}")
        return

    if not a.indir:
        ap.error("need --in <dir> (or --file NAME=path)")
    for t in man["targets"]:
        src = os.path.join(a.indir, t["rel_app_path"])
        out = apply_target(t, open(src, "rb").read(), a.verify_only)
        if out is not None and a.outdir:
            dst = os.path.join(a.outdir, t["rel_app_path"])
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            open(dst, "wb").write(out); print(f"[{t['name']}] wrote {dst}")
    print("\nDONE. Delivery: set SMACK64EXEC=Privileged on the patched binaries in the evil rootfs")
    print("(chsmack -e Privileged, preserved in tar xattrs) -- see docs/10-smack.md.")

if __name__ == "__main__":
    main()
