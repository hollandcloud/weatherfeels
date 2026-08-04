#!/usr/bin/env python3
"""Convert WOFF 1.0 fonts to plain SFNT (.ttf/.otf) so Core Text can load them.

WOFF 1.0 is just an SFNT whose tables are individually zlib-deflated, wrapped in a
44-byte header plus a 20-byte-per-table directory. Reversing it needs nothing but
zlib, which keeps this script dependency-free (no fontTools / fontforge required).

Spec: https://www.w3.org/TR/WOFF/

Usage: woff2ttf.py <out_dir> <font.woff> [font.woff ...]
"""

import os
import struct
import sys
import zlib

# signature, flavor, length, numTables, reserved, totalSfntSize, majorVersion,
# minorVersion, metaOffset, metaLength, metaOrigLength, privOffset, privLength
WOFF_HEADER = ">IIIHHIHHIIIII"  # 44 bytes
WOFF_HEADER_SIZE = struct.calcsize(WOFF_HEADER)
WOFF_ENTRY = ">IIIII"  # 20 bytes
WOFF_ENTRY_SIZE = struct.calcsize(WOFF_ENTRY)

# Tables whose presence tells us the font carries outlines rather than bitmaps.
OUTLINE_TABLES = {b"glyf", b"CFF ", b"CFF2"}
BITMAP_TABLES = {b"EBDT", b"EBLC", b"CBDT", b"CBLC", b"bdat", b"bloc", b"sbix"}


def pad4(n):
    return (n + 3) & ~3


def checksum(data):
    """SFNT table checksum: sum of big-endian uint32s over zero-padded data."""
    data = data + b"\0" * (-len(data) % 4)
    total = 0
    for (word,) in struct.iter_unpack(">I", data):
        total += word
    return total & 0xFFFFFFFF


def table_offset(tables, tag):
    """Byte offset of a table in the rebuilt SFNT, or None."""
    for table in tables:
        if table["tag"] == tag:
            return table["offset"]
    return None


def fix_vertical_metrics(sfnt, tables):
    """Raise the declared ascent to cover the glyphs' actual ink.

    Star4000 Large reports an ascent well below where its outlines actually draw —
    about 0.18 em short. Text layout everywhere (SwiftUI, UIKit, the browser) sizes a
    line box from ascent+descent, so the top of every capital and the degree sign gets
    sliced off. A browser happened to hide this because CSS lets ink overflow the line
    box; UIKit and SwiftUI clip it.

    Fixing it in the font rather than padding each view means every framework and
    platform measures the face correctly, with no per-view workarounds.

    Returns the number of font units the ascent was raised by, or 0.
    """
    head = table_offset(tables, b"head")
    hhea = table_offset(tables, b"hhea")
    if head is None or hhea is None:
        return 0

    # head: yMax lives at offset 42 (after version, revision, checksumAdjustment,
    # magic, flags, unitsPerEm, created, modified, xMin, yMin, xMax).
    (y_max,) = struct.unpack_from(">h", sfnt, head + 42)
    # hhea: ascender at 4, descender at 6, lineGap at 8.
    (ascender,) = struct.unpack_from(">h", sfnt, hhea + 4)

    if y_max <= ascender:
        return 0

    struct.pack_into(">h", sfnt, hhea + 4, y_max)

    # OS/2 carries its own ascent fields; keep them consistent so platforms that
    # prefer those metrics agree with hhea.
    os2 = table_offset(tables, b"OS/2")
    if os2 is not None:
        (version,) = struct.unpack_from(">H", sfnt, os2)
        # usWinAscent sits at offset 74; sTypoAscender at 68. Both exist from v0.
        if version >= 0:
            struct.pack_into(">h", sfnt, os2 + 68, y_max)   # sTypoAscender
            struct.pack_into(">H", sfnt, os2 + 74, y_max)   # usWinAscent

    return y_max - ascender


def convert(woff_path, out_dir):
    with open(woff_path, "rb") as fh:
        woff = fh.read()

    fields = struct.unpack_from(WOFF_HEADER, woff, 0)
    signature, flavor, _length, num_tables = fields[0], fields[1], fields[2], fields[3]

    if signature != 0x774F4646:  # 'wOFF'
        raise ValueError(f"{woff_path}: not a WOFF 1.0 file (bad signature)")

    # Decode the table directory, then decompress each table's payload.
    tables = []
    for i in range(num_tables):
        offset = WOFF_HEADER_SIZE + i * WOFF_ENTRY_SIZE
        tag, tbl_off, comp_len, orig_len, orig_sum = struct.unpack_from(
            WOFF_ENTRY, woff, offset
        )
        raw = woff[tbl_off : tbl_off + comp_len]
        # compLength == origLength means the table was stored uncompressed.
        data = raw if comp_len == orig_len else zlib.decompress(raw)
        if len(data) != orig_len:
            raise ValueError(
                f"{woff_path}: table {tag!r} decompressed to {len(data)}, "
                f"expected {orig_len}"
            )
        tables.append(
            {"tag": struct.pack(">I", tag), "data": data, "checksum": orig_sum}
        )

    # The SFNT table directory must be sorted by tag.
    tables.sort(key=lambda t: t["tag"])

    # Rebuild the 12-byte SFNT header. searchRange/entrySelector/rangeShift are
    # derived from the largest power of two <= numTables.
    entry_selector = max(num_tables.bit_length() - 1, 0)
    search_range = (1 << entry_selector) * 16
    range_shift = num_tables * 16 - search_range
    header = struct.pack(
        ">IHHHH", flavor, num_tables, search_range, entry_selector, range_shift
    )

    # Lay tables out on 4-byte boundaries after the directory.
    directory_size = num_tables * 16
    cursor = len(header) + directory_size
    for table in tables:
        table["offset"] = cursor
        cursor = pad4(cursor + len(table["data"]))

    directory = b"".join(
        struct.pack(
            ">4sIII",
            t["tag"],
            t["checksum"],
            t["offset"],
            len(t["data"]),
        )
        for t in tables
    )

    body = bytearray(cursor - len(header) - directory_size)
    for table in tables:
        start = table["offset"] - len(header) - directory_size
        body[start : start + len(table["data"])] = table["data"]

    sfnt = bytearray(header + directory + bytes(body))

    ascent_raised = fix_vertical_metrics(sfnt, tables)

    # head.checksumAdjustment must equal 0xB1B0AFBA minus the whole-file checksum,
    # computed with the field itself zeroed. Done last, after any metric edits.
    head = next((t for t in tables if t["tag"] == b"head"), None)
    if head is not None:
        adj_at = head["offset"] + 8
        struct.pack_into(">I", sfnt, adj_at, 0)
        total = checksum(bytes(sfnt))
        struct.pack_into(">I", sfnt, adj_at, (0xB1B0AFBA - total) & 0xFFFFFFFF)

    present = {t["tag"] for t in tables}
    outlines = sorted(t.decode() for t in present & OUTLINE_TABLES)
    bitmaps = sorted(t.decode() for t in present & BITMAP_TABLES)
    suffix = ".otf" if b"CFF " in present or b"CFF2" in present else ".ttf"

    base = os.path.splitext(os.path.basename(woff_path))[0]
    out_path = os.path.join(out_dir, base + suffix)
    with open(out_path, "wb") as fh:
        fh.write(sfnt)

    return {
        "out": out_path,
        "tables": num_tables,
        "outlines": outlines,
        "bitmaps": bitmaps,
        "size": len(sfnt),
        "ascent_raised": ascent_raised,
    }


def main(argv):
    if len(argv) < 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    out_dir, inputs = argv[1], argv[2:]
    os.makedirs(out_dir, exist_ok=True)

    for path in inputs:
        info = convert(path, out_dir)
        print(
            f"{os.path.basename(path)} -> {os.path.basename(info['out'])}  "
            f"({info['size']:,} bytes, {info['tables']} tables, "
            f"outlines={info['outlines'] or 'NONE'}, "
            f"bitmaps={info['bitmaps'] or 'none'}"
            + (f", ascent +{info['ascent_raised']} units" if info["ascent_raised"] else "")
            + ")"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
