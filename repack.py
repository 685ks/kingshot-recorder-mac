"""Put new Python code into a PyInstaller 6 executable (the Mac Kingshot Recorder): its entry script and the app's own
modules in the embedded PYZ are replaced by the code objects in payload.zip; everything else stays byte for byte.

    python3.14 repack.py <executable> <payload.zip>      (the executable must be unsigned: codesign --remove first)

payload.zip: manifest.json {"script": name, "modules": [names], "python": "3.14"} and <name>.code (marshalled code
objects made by make_payload.py with the same Python minor version as the program's)."""
import json
import marshal
import struct
import sys
import zipfile
import zlib
from importlib.util import MAGIC_NUMBER

COOKIE = b"MEI\014\013\012\013\016"
COOKIE_FMT = "!8sIIII64s"
COOKIE_LEN = struct.calcsize(COOKIE_FMT)
ENTRY_FMT = "!IIIIBc"
ENTRY_LEN = struct.calcsize(ENTRY_FMT)


def read_archive(data):
    pos = data.rfind(COOKIE)
    if pos < 0:
        sys.exit("no PyInstaller archive in this executable")
    magic, length, toc_off, toc_len, pyvers, pylib = struct.unpack(COOKIE_FMT, data[pos:pos + COOKIE_LEN])
    end = pos + COOKIE_LEN
    tail = data[end:]
    if tail.strip(b"\0"):                                  # (codesign --remove may leave a little zero padding)
        sys.exit(f"{len(tail)} bytes after the archive (still signed? run codesign --remove first)")
    start = end - length
    toc, cur = [], start + toc_off
    while cur < start + toc_off + toc_len:
        elen, off, clen, ulen, comp, tc = struct.unpack(ENTRY_FMT, data[cur:cur + ENTRY_LEN])
        name = data[cur + ENTRY_LEN:cur + elen].rstrip(b"\0").decode("utf-8")
        blob = data[start + off:start + off + clen]
        toc.append(dict(name=name, tc=tc.decode("ascii"), comp=comp, ulen=ulen, blob=blob))
        cur += elen
    return start, pyvers, pylib, toc


def write_archive(entries, pyvers, pylib):
    out, toc = bytearray(), bytearray()
    for e in entries:
        off = len(out)
        out += e["blob"]
        name = e["name"].encode("utf-8")
        nlen = len(name) + 1
        if (ENTRY_LEN + nlen) % 16:
            nlen += 16 - (ENTRY_LEN + nlen) % 16
        toc += struct.pack(ENTRY_FMT + f"{nlen}s", ENTRY_LEN + nlen, off, len(e["blob"]), e["ulen"], e["comp"],
                           e["tc"].encode("ascii"), name)
    toc_off = len(out)
    out += toc
    out += struct.pack(COOKIE_FMT, COOKIE, toc_off + len(toc) + COOKIE_LEN, toc_off, len(toc), pyvers, pylib)
    return bytes(out)


def new_pyz(pyz, code):
    assert pyz[:4] == b"PYZ\0", "not a PYZ archive"
    if pyz[4:8] != MAGIC_NUMBER:
        sys.exit("the program's Python is not this Python (bytecode magic differs) - use the same minor version")
    (toc_off,) = struct.unpack("!i", pyz[8:12])
    toc = marshal.loads(pyz[toc_off:])
    entries = [(n, tc, pyz[o:o + ln]) for n, (tc, o, ln) in toc]
    have = {n for n, _, _ in entries}
    entries = [(n, tc, zlib.compress(code[n], 6) if n in code else blob) for n, tc, blob in entries]
    entries += [(n, 0, zlib.compress(c, 6)) for n, c in code.items() if n not in have]
    body, new_toc = bytearray(b"\0" * 17), []
    for n, tc, blob in entries:
        new_toc.append((n, (tc, len(body), len(blob))))
        body += blob
    off = len(body)
    body += marshal.dumps(new_toc)
    body[0:12] = b"PYZ\0" + MAGIC_NUMBER + struct.pack("!i", off)
    return bytes(body), sorted(code.keys() - have)


def main(exe, payload):
    with zipfile.ZipFile(payload) as z:
        man = json.loads(z.read("manifest.json"))
        code = {n: z.read(f"{n}.code") for n in [man["script"], *man["modules"]]}
    for n, c in code.items():
        marshal.loads(c)                                      # (a payload from another Python fails here, not at start)
    data = open(exe, "rb").read()
    start, pyvers, pylib, toc = read_archive(data)
    if f"{pyvers // 100}.{pyvers % 100}" != man["python"]:
        sys.exit(f"the program uses Python {pyvers}, the payload was made with {man['python']}")
    done = set()
    for e in toc:
        if e["tc"] == "s" and e["name"] == man["script"]:
            blob = code.pop(man["script"])
            e.update(blob=zlib.compress(blob, 9) if e["comp"] else blob, ulen=len(blob))
            done.add("script")
        elif e["tc"] == "z" and e["name"] == "PYZ.pyz":
            pyz = zlib.decompress(e["blob"]) if e["comp"] else e["blob"]
            pyz, added = new_pyz(pyz, {n: code[n] for n in man["modules"]})
            e.update(blob=zlib.compress(pyz, 9) if e["comp"] else pyz, ulen=len(pyz))
            done.add("pyz")
            if added:
                print("modules new in the PYZ:", ", ".join(added))
    if done != {"script", "pyz"}:
        sys.exit(f"the archive does not look as expected (found: {done})")
    archive = write_archive(toc, pyvers, pylib)
    open(exe, "wb").write(data[:start] + archive)
    print(f"repacked {exe}: script {man['script']} and {len(man['modules'])} modules replaced, "
          f"archive {len(data) - start} -> {len(archive)} bytes")


if __name__ == "__main__":
    main(*sys.argv[1:3])
