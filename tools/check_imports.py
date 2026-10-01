#!/usr/bin/env python3
"""Check that every undefined symbol of a PS5 core is resolvable by the
title's generated import table (ps5_core_import inside eboot.bin).

The import table stores symbol names as plain strings in the embedded ELF,
so extracting printable strings from eboot.bin is sufficient to test
coverage. Pass either the raw eboot.bin or a JSON list of names.

Usage:
  check_imports.py <core.so> <eboot.bin | imports.json>
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from readelf import parse

SELF_ELF_OFFSET = 0x1A0  # embedded ELF inside the fSELF container


def eboot_symbols(path):
    data = open(path, "rb").read()
    # The import table lives in the embedded ELF; scanning the whole file is
    # fine because the names are distinctive C identifiers.
    names = set()
    for m in re.finditer(rb"[A-Za-z_][A-Za-z0-9_$.-]{2,}", data):
        names.add(m.group().decode("ascii", "replace"))
    return names


def undefined_symbols(path):
    r = parse(path)
    return {name for _, _, _, _, _, _, ndx, name in r["syms"]
            if ndx == "UND" and name}


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    core_path, ref_path = sys.argv[1], sys.argv[2]

    if ref_path.lower().endswith(".json"):
        provided = set(json.load(open(ref_path)))
    else:
        provided = eboot_symbols(ref_path)

    undef = undefined_symbols(core_path)
    missing = sorted(undef - provided)
    print(f"{len(undef)} undefined symbols; {len(missing)} not resolvable "
          f"by {os.path.basename(ref_path)}")
    for s in missing:
        print(f"  MISSING: {s}")
    sys.exit(1 if missing else 0)


if __name__ == "__main__":
    main()
