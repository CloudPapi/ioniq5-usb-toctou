# Scope, authorization, and responsible use

## Authorization
This research is conducted by the device owner on their **own, decommissioned,
off-road** Hyundai IONIQ 5 head unit (Gen5W_L, build 260128). It is right-to-repair /
own-device security research. No third-party vehicle, account, or network is involved.

## The payload is benign
The "malicious" rootfs carries only a **proof marker**: a root-run systemd unit
(`wideopen.service`) that writes a log file (e.g. `/var/log/TOCTOU_ROOT_PROOF`) and/or a
recognizable string. It performs no destructive, covert, or anti-forensic action. On-car
testing is expected to use a trivially-marked benign image to confirm the race before any
other payload.

## No key forgery
The attack uses **no OEM RSA private key** and signs nothing malicious. The signature/MD5
check passes on the **genuine, already-signed** benign image; only the *install* read is
swapped. The TE2 AES **content** key used to build a valid-looking encrypted envelope is
the OEM firmware content key, which the owner already holds and which is **not** included
in this repository.

## What is intentionally not shipped
- The TE2 content key (supply via `pizero/key.local` / `$TE2_CONTENT_KEY`).
- OEM firmware decrypt/boot tooling (`gen5w_decrypt.py`, `vm_boot.py`).
- Any genuine firmware image, the built `usb.img`, or the evil envelope (all gitignored;
  regenerable by the owner from their own package).

## Disclosure
The underlying fix is a standard verify-and-use-the-same-bytes pattern (see
`docs/05-mitigations.md`). Report of the class of issue to the vendor is appropriate;
this repository documents the mechanism and does not provide a turnkey attack against
any vehicle other than the owner's own bench unit.
