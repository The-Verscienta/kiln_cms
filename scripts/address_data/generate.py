#!/usr/bin/env python3
"""Regenerates priv/address/*.json from a checkout of commerceguys/addressing.

    git clone --depth 1 https://github.com/commerceguys/addressing.git /some/empty/dir
    python3 -I scripts/address_data/generate.py /some/empty/dir

The data is MIT-licensed (commerceguys/addressing, itself generated from
Google's libaddressinput data, CC BY 4.0). See priv/address/NOTICE.md and
docs/extending-content.md ("Address fields"). Output is deterministic: run it, diff it, review it.
"""
import json
import os
import re
import sys

PHP = "src/AddressFormat/AddressFormatRepository.php"

# The six parts Kiln stores, by the dataset's names.
PART = {
    "addressLine1": "address_line1",
    "locality": "locality",
    "administrativeArea": "administrative_area",
    "postalCode": "postal_code",
}


def tokens(src):
    pos = 0
    while pos < len(src):
        c = src[pos]
        if c.isspace():
            pos += 1
        elif src.startswith("//", pos) or c == "#":
            pos = src.index("\n", pos)
        elif src.startswith("/*", pos):
            pos = src.index("*/", pos) + 2
        elif c == "'":
            m = re.compile(r"'((?:[^'\\]|\\.)*)'", re.S).match(src, pos)
            yield ("s", re.sub(r"\\(['\\])", r"\1", m.group(1)))
            pos = m.end()
        elif c == '"':
            m = re.compile(r'"((?:[^"\\]|\\.)*)"', re.S).match(src, pos)
            yield ("s", m.group(1).replace("\\n", "\n"))
            pos = m.end()
        elif src.startswith("=>", pos):
            yield ("=>", None)
            pos += 2
        elif c in "[],":
            yield (c, None)
            pos += 1
        else:
            raise SystemExit("unexpected %r at %d" % (src[pos : pos + 20], pos))


def parse(toks):
    toks = list(toks)
    i = 0

    def value():
        nonlocal i
        kind, val = toks[i]
        i += 1
        if kind == "s":
            return val
        assert kind == "[", (kind, val)
        items, assoc = [], {}
        while toks[i][0] != "]":
            first = value()
            if toks[i][0] == "=>":
                i += 1
                assoc[first] = value()
            else:
                items.append(first)
            if toks[i][0] == ",":
                i += 1
        i += 1
        return assoc if assoc else items

    return value()


def main(root):
    src = open(os.path.join(root, PHP), encoding="utf-8").read()
    body = src[src.index("// @codingStandardsIgnoreEnd") :]
    body = body[body.index("return [") + len("return ") :]
    body = body[: body.rindex("];") + 1]
    defs = parse(tokens(body))

    out = {}
    for country in sorted(defs):
        d = defs[country]
        fmt = d.get("format", "")
        # A country without its own format uses the generic one, which has a
        # locality but no administrative area or postal code.
        if not fmt:
            fmt = "%locality"
        required = d.get("required_fields", ["addressLine1", "locality"])
        unused = sorted(
            PART[f]
            for f in ("locality", "administrativeArea", "postalCode")
            if "%" + f not in fmt
        )
        entry = {
            # What the country's own format never shows cannot be required.
            "required": [PART[f] for f in required if f in PART and PART[f] not in unused],
            "unused": unused,
            "administrative_area": d.get("administrative_area_type", "province"),
            "locality": d.get("locality_type", "city"),
            "postal_code": d.get("postal_code_type", "postal"),
        }
        out[country] = entry

    dest = os.path.join(os.path.dirname(__file__), "..", "..", "priv", "address")
    with open(os.path.join(dest, "formats.json"), "w", encoding="utf-8") as f:
        json.dump(out, f, indent=1, sort_keys=True, ensure_ascii=False)
        f.write("\n")
    print("formats: %d countries" % len(out))


if __name__ == "__main__":
    main(sys.argv[1])
