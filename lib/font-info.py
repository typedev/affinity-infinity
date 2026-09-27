#!/usr/bin/env python3
"""Print the names of TrueType/OpenType fonts (stdlib only).

    font-info.py FILE...

One tab-separated line per face (collections have several):

    path  face-index  postscript-name  family  style  named-instances

named-instances is the number of named instances of a variable font (fvar),
0 for a static font. Unreadable files are reported on stderr and skipped.
Only the headers and the name table are read, so large libraries scan fast.
"""
import struct
import sys


# Preferred records: Windows English (US), then any Windows, then Unicode, then Mac.
def rank(platform: int, lang: int) -> int:
    if platform == 3 and lang == 0x409:
        return 0
    if platform == 3:
        return 1
    if platform == 0:
        return 2
    return 3


def decode(platform: int, raw: bytes) -> str:
    return raw.decode("utf-16-be", "replace") if platform in (0, 3) else raw.decode("latin-1")


def read(f, offset: int, size: int) -> bytes:
    f.seek(offset)
    data = f.read(size)
    if len(data) != size:
        raise ValueError("truncated font file")
    return data


def names(table: bytes) -> dict:
    count, strings = struct.unpack_from(">2xHH", table, 0)
    best = {}
    for i in range(count):
        platform, _enc, lang, name_id, length, start = struct.unpack_from(">6H", table, 6 + 12 * i)
        if name_id not in (1, 2, 6, 16, 17):
            continue
        r = rank(platform, lang)
        if name_id in best and best[name_id][0] <= r:
            continue
        pos = strings + start
        best[name_id] = (r, decode(platform, table[pos:pos + length]))
    return {k: v[1] for k, v in best.items()}


def face(f, offset: int) -> tuple:
    num_tables = struct.unpack(">H", read(f, offset + 4, 2))[0]
    directory = read(f, offset + 12, 16 * num_tables)
    tables = {}
    for i in range(num_tables):
        tag, _checksum, start, length = struct.unpack_from(">4sLLL", directory, 16 * i)
        tables[tag] = (start, length)
    if b"name" not in tables:
        raise ValueError("no name table")
    n = names(read(f, *tables[b"name"]))
    instances = 0
    if b"fvar" in tables:
        instances = struct.unpack(">H", read(f, tables[b"fvar"][0] + 12, 2))[0]
    family = n.get(16) or n.get(1, "")
    style = n.get(17) or n.get(2, "")
    return n.get(6, ""), family, style, instances


def faces(f) -> list:
    tag = read(f, 0, 4)
    if tag == b"ttcf":
        count = struct.unpack(">L", read(f, 8, 4))[0]
        return list(struct.unpack(f">{count}L", read(f, 12, 4 * count)))
    if tag in (b"\x00\x01\x00\x00", b"OTTO", b"true"):
        return [0]
    raise ValueError("not a TrueType/OpenType font")


def clean(text: str) -> str:
    return " ".join(text.split())


def main() -> int:
    status = 0
    for path in sys.argv[1:]:
        try:
            with open(path, "rb") as f:
                rows = [face(f, offset) for offset in faces(f)]
        except (OSError, ValueError, struct.error) as e:
            print(f"{path}: {e}", file=sys.stderr)
            status = 1
            continue
        for index, (ps, family, style, instances) in enumerate(rows):
            print("\t".join([path, str(index), clean(ps), clean(family), clean(style), str(instances)]))
    return status


if __name__ == "__main__":
    sys.exit(main())
