#!/usr/bin/env python3
# Encrypt a plaintext into a Gen5W TE2 envelope that is byte-size-identical to a template
# envelope, with the IV derived from a chosen target basename. Used to build the EVIL
# mango-rootfs.tar.gz so it matches the genuine envelope's size and IV (same FS extent,
# same decryption on the unit) while carrying attacker plaintext.
#
#   te2_encrypt.py <plaintext_in> <template_envelope> <out_envelope> <target_basename>
#
# Requires plaintext_in length == (template size - 0x4024). Pad the plaintext upstream.
#
# The TE2 AES content key is NOT shipped in this repo. Supply it out-of-band:
#   export TE2_CONTENT_KEY=<32 hex chars>        # or put it in pizero/key.local (gitignored)
# The key is the OEM firmware content-encryption key, which the device owner already
# holds; it is kept out of version control so this repo is publishable.
import os, sys, hashlib
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

# TE2 envelope geometry (constants, not secret): 0x4024-byte trailer, 16-byte AES-CBC blocks.
META = int(os.environ.get("TE2_META_SIZE", "0x4024"), 0)
BS   = 16

def _load_key():
    k = os.environ.get("TE2_CONTENT_KEY")
    if not k:
        kf = os.path.join(os.path.dirname(os.path.abspath(__file__)), "key.local")
        if os.path.exists(kf):
            k = open(kf).read().strip()
    if not k:
        sys.exit("ERROR: TE2 content key not set. `export TE2_CONTENT_KEY=<32hex>` "
                 "or create pizero/key.local (gitignored). See README / pizero/key.local.example.")
    return bytes.fromhex(k)

KEY = _load_key()
plain_in, template, out, target_basename = sys.argv[1:5]
P = open(plain_in, "rb").read()
tmpl = open(template, "rb").read()
want_body = len(tmpl) - META
if len(P) != want_body:
    sys.exit(f"ERROR plaintext={len(P)} but template body={want_body}; pad plaintext to match")
body_size = len(P); pad_len = (BS - body_size % BS) % BS
# IV uses the TARGET basename the unit will see (e.g. mango-rootfs.tar.gz), not the out path
# signed 32-bit wrap of the body size (matches the OEM's basename+int32 IV derivation)
_si32 = body_size - (1 << 32) if body_size >= (1 << 31) else body_size
iv = hashlib.sha256(f"{target_basename}{_si32}".encode()).digest()[:BS]
enc = Cipher(algorithms.AES(KEY), modes.CBC(iv)).encryptor()
CT = enc.update(P + b"\x00" * pad_len) + enc.finalize()
body = CT[:body_size]; pad = CT[body_size:body_size + pad_len]
md = bytearray(tmpl[-META:])            # reuse the genuine opaque sig_store/key_store
md[0:3] = b"TE2"
if pad_len: md[36:36 + pad_len] = pad
md[4:36] = hashlib.sha256(iv + bytes(md[36:])).digest()
open(out, "wb").write(body + bytes(md))
assert os.path.getsize(out) == len(tmpl), "size mismatch!"
print(f"OK {out}: size={os.path.getsize(out)} (==template) body={body_size} iv={iv.hex()} basename={target_basename}")
