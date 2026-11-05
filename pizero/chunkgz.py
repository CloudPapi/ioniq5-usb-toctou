import sys, deflate
inp, outp, level, chunk = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
total_in = total_out = 0
with open(inp,'rb') as f, open(outp,'wb') as o:
    while True:
        b = f.read(chunk)
        if not b: break
        c = deflate.gzip_compress(b, level)   # independent gzip member; members concatenate
        o.write(c); total_in += len(b); total_out += len(c)
print(f"in={total_in} out={total_out} ratio={total_out/total_in:.4f}")
