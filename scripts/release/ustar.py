"""Deterministic POSIX ustar writer and strict reader for component archives (SCHEMAS.md §8). Stdlib only.

The writer emits exactly what it is given (including unsafe entries, for negative test vectors): fixed mtime 0,
uid/gid 0, empty owner names, no padding beyond the two zero end blocks. The reader parses headers without
interpreting them as safe; archive rules live in reference_verify.py.
"""

BLOCK = 512


class ArchiveError(ValueError):
    def __init__(self, reason, detail=""):
        super().__init__(f"{reason}: {detail}" if detail else reason)
        self.reason = reason


def _octal(value, width):
    text = format(value, "o").encode("ascii")
    if len(text) > width - 1:
        raise ValueError(f"value {value} does not fit a {width}-byte field")
    return text.rjust(width - 1, b"0") + b"\0"


def _split_name(name):
    raw = name.encode("utf-8")
    if len(raw) <= 100:
        return raw, b""
    cut = raw.rfind(b"/", 0, 156)
    while cut > 0 and len(raw) - cut - 1 > 100:
        cut = raw.rfind(b"/", 0, cut)
    if cut <= 0:
        raise ValueError(f"name too long for ustar: {name}")
    return raw[cut + 1:], raw[:cut]


def header(name, mode, size, typeflag, linkname="", devmajor=0, devminor=0):
    short, prefix = _split_name(name)
    fields = [
        short.ljust(100, b"\0"),
        _octal(mode, 8),
        _octal(0, 8),
        _octal(0, 8),
        _octal(size, 12),
        _octal(0, 12),
        b" " * 8,
        typeflag.encode("ascii"),
        linkname.encode("utf-8").ljust(100, b"\0"),
        b"ustar\0",
        b"00",
        b"\0" * 32,
        b"\0" * 32,
        _octal(devmajor, 8),
        _octal(devminor, 8),
        prefix.ljust(155, b"\0"),
        b"\0" * 12,
    ]
    block = bytearray(b"".join(fields))
    assert len(block) == BLOCK
    block[148:156] = format(sum(block), "06o").encode("ascii") + b"\0 "
    return bytes(block)


def build(entries):
    """entries: dicts {name, type: file|dir|symlink|hardlink|char|block|fifo, mode, data?, linkname?}."""
    flags = {"file": "0", "dir": "5", "hardlink": "1", "symlink": "2", "char": "3", "block": "4", "fifo": "6"}
    out = bytearray()
    for entry in entries:
        data = entry.get("data", b"") if entry["type"] == "file" else b""
        out += header(entry["name"], entry["mode"], len(data), flags[entry["type"]],
                      entry.get("linkname", ""), entry.get("devmajor", 0), entry.get("devminor", 0))
        out += data
        if len(data) % BLOCK:
            out += b"\0" * (BLOCK - len(data) % BLOCK)
    out += b"\0" * (2 * BLOCK)
    return bytes(out)


def _field(block, start, length):
    return block[start:start + length].split(b"\0", 1)[0]


def _number(block, start, length):
    text = _field(block, start, length).strip(b" ")
    if not text or any(c not in b"01234567" for c in text):
        raise ArchiveError("archive_malformed", "bad numeric field")
    return int(text, 8)


def read(data):
    """Parse an archive into a list of {name, typeflag, mode, size, linkname, data}. Raises ArchiveError."""
    entries, offset = [], 0
    while True:
        if offset + BLOCK > len(data):
            raise ArchiveError("archive_malformed", "missing end-of-archive blocks")
        block = data[offset:offset + BLOCK]
        if block == b"\0" * BLOCK:
            if data[offset + BLOCK:offset + 2 * BLOCK] != b"\0" * BLOCK or data[offset + 2 * BLOCK:].strip(b"\0"):
                raise ArchiveError("archive_malformed", "bad end of archive")
            return entries
        if block[257:263] != b"ustar\0" or block[263:265] != b"00":
            raise ArchiveError("archive_malformed", "not a ustar header")
        stored = _number(block, 148, 8)
        if stored != sum(block[:148]) + 8 * 32 + sum(block[156:]):
            raise ArchiveError("archive_malformed", "header checksum")
        name, prefix = _field(block, 0, 100), _field(block, 345, 155)
        try:
            full = (prefix + b"/" + name if prefix else name).decode("utf-8")
            linkname = _field(block, 157, 100).decode("utf-8")
        except UnicodeDecodeError as error:
            raise ArchiveError("archive_unsafe_path", "name is not UTF-8") from error
        typeflag = chr(block[156]) if block[156] else "0"
        size = _number(block, 124, 12)
        mode = _number(block, 100, 8)
        offset += BLOCK
        body = 0 if typeflag in "123456" else size  # links, devices, fifos and dirs carry no data
        if offset + body > len(data):
            raise ArchiveError("archive_malformed", "truncated entry")
        entries.append({"name": full, "typeflag": typeflag, "mode": mode, "size": size,
                        "linkname": linkname, "data": data[offset:offset + body]})
        offset += (body + BLOCK - 1) // BLOCK * BLOCK
