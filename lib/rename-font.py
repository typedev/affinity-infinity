#!/usr/bin/env python3
"""Rename a TrueType font's family in its 'name' table (stdlib only).

    rename-font.py IN.ttf OUT.ttf OLD NEW

Replaces OLD with NEW in the family/full/unique/typographic names, and with
NEW minus spaces in the PostScript name. Copyright, trademark and licence
records are left untouched. Table checksums and head.checkSumAdjustment are
recomputed.
"""
import struct
import sys

RENAMED_IDS = {1, 3, 4, 16, 17, 18, 21, 22}
POSTSCRIPT_ID = 6


def checksum(data: bytes) -> int:
    data += b"\0" * (-len(data) % 4)
    return sum(struct.unpack(f">{len(data) // 4}L", data)) & 0xFFFFFFFF


def decode(platform: int, raw: bytes) -> str:
    return raw.decode("utf-16-be") if platform in (0, 3) else raw.decode("latin-1")


def encode(platform: int, text: str) -> bytes:
    return text.encode("utf-16-be") if platform in (0, 3) else text.encode("latin-1")


def rename_table(name: bytes, old: str, new: str) -> bytes:
    fmt, count, string_offset = struct.unpack(">HHH", name[:6])
    if fmt not in (0, 1):
        raise SystemExit(f"unsupported name table format {fmt}")
    records = [struct.unpack(">6H", name[6 + 12 * i : 18 + 12 * i]) for i in range(count)]
    lang_tags = b""
    if fmt == 1:
        # Language-tag records follow the name records; keep them verbatim.
        end = 6 + 12 * count
        (tag_count,) = struct.unpack(">H", name[end : end + 2])
        lang_tags = name[end : end + 2 + 4 * tag_count]

    strings = b""
    out_records = []
    for platform, encoding, language, name_id, length, offset in records:
        start = string_offset + offset
        raw = name[start : start + length]
        if name_id in RENAMED_IDS or name_id == POSTSCRIPT_ID:
            replacement = new if name_id in RENAMED_IDS else new.replace(" ", "")
            raw = encode(platform, decode(platform, raw).replace(old, replacement))
        out_records.append((platform, encoding, language, name_id, len(raw), len(strings)))
        strings += raw

    header_len = 6 + 12 * count + (len(lang_tags) if fmt == 1 else 0)
    if fmt == 1:
        # Lang-tag string offsets are relative to the (moved) storage area; this
        # font family has none, so refuse rather than silently corrupt them.
        if struct.unpack(">H", lang_tags[:2])[0]:
            raise SystemExit("name table language tags are not supported")
    out = struct.pack(">HHH", fmt, count, header_len)
    out += b"".join(struct.pack(">6H", *r) for r in out_records)
    out += lang_tags
    return out + strings


def main() -> None:
    src, dst, old, new = sys.argv[1:5]
    font = open(src, "rb").read()
    sfnt_version, num_tables = struct.unpack(">LH", font[:6])
    directory = font[:12]
    tables = []
    for i in range(num_tables):
        tag, _, offset, length = struct.unpack(">4sLLL", font[12 + 16 * i : 28 + 16 * i])
        tables.append([tag, font[offset : offset + length]])

    for t in tables:
        if t[0] == b"name":
            t[1] = rename_table(t[1], old, new)
        elif t[0] == b"head":
            t[1] = t[1][:8] + b"\0\0\0\0" + t[1][12:]  # checkSumAdjustment, set below

    offset = 12 + 16 * num_tables
    records, body = b"", b""
    for tag, data in tables:
        records += struct.pack(">4sLLL", tag, checksum(data), offset + len(body), len(data))
        body += data + b"\0" * (-len(data) % 4)
    out = bytearray(directory + records + body)

    head_offset = next(o for (tag, _, o, _) in
                       (struct.unpack(">4sLLL", records[16 * i : 16 * i + 16]) for i in range(num_tables))
                       if tag == b"head")
    struct.pack_into(">L", out, head_offset + 8, (0xB1B0AFBA - checksum(bytes(out))) & 0xFFFFFFFF)
    open(dst, "wb").write(out)


if __name__ == "__main__":
    main()
