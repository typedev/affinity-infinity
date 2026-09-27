#!/usr/bin/env python3
"""Save the largest PNG icon of a Windows executable (stdlib only).

    extract-icon.py APP.exe OUT.png

Used to take Affinity's own icon from the Affinity.exe installed on the
user's machine for the menu entry; the logo is never shipped by this project.
Exits 1 if the executable has no PNG-encoded icon.
"""
import struct
import sys

RT_ICON, RT_GROUP_ICON = 3, 14
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


def main() -> int:
    exe, out = sys.argv[1:3]
    d = open(exe, "rb").read()
    pe = struct.unpack_from("<I", d, 0x3C)[0]
    nsec = struct.unpack_from("<H", d, pe + 6)[0]
    optsz = struct.unpack_from("<H", d, pe + 20)[0]
    opt = pe + 24
    datadir = opt + (112 if struct.unpack_from("<H", d, opt)[0] == 0x20B else 96)
    rsrc_rva = struct.unpack_from("<I", d, datadir + 2 * 8)[0]
    sections = []
    for i in range(nsec):
        vsize, va, rsize, rptr = struct.unpack_from("<IIII", d, opt + optsz + 40 * i + 8)
        sections.append((va, max(vsize, rsize), rptr))

    def offset(rva):
        for va, size, ptr in sections:
            if va <= rva < va + size:
                return rva - va + ptr
        raise ValueError("RVA outside sections")

    base = offset(rsrc_rva)

    def entries(o):
        named, ids = struct.unpack_from("<HH", d, o + 12)
        for i in range(named + ids):
            yield struct.unpack_from("<II", d, o + 16 + 8 * i)

    def leaf(target):
        while target & 0x80000000:
            target = next(entries(base + (target & 0x7FFFFFFF)))[1]
        rva, size = struct.unpack_from("<II", d, base + target)
        return offset(rva), size

    icons, groups = {}, []
    for rtype, t in entries(base):
        if rtype not in (RT_ICON, RT_GROUP_ICON):
            continue
        for name, t2 in entries(base + (t & 0x7FFFFFFF)):
            o, size = leaf(t2)
            if rtype == RT_ICON:
                icons[name] = (o, size)
            else:
                groups.append(o)
    if not groups:
        return 1

    best = None
    group = groups[0]
    for i in range(struct.unpack_from("<H", d, group + 4)[0]):
        w, _h, _cc, _r, _planes, _bpp, _size, icon_id = struct.unpack_from("<BBBBHHIH", d, group + 6 + 14 * i)
        o, size = icons.get(icon_id, (0, 0))
        if d[o:o + 8] == PNG_MAGIC and (best is None or (w or 256) > best[0]):
            best = (w or 256, o, size)
    if best is None:
        return 1
    open(out, "wb").write(d[best[1]:best[1] + best[2]])
    return 0


if __name__ == "__main__":
    sys.exit(main())
