"""Parse connection strings with libpq's own PQconninfoParse (#2831, #2833).

Used by test/kiln_cms/backups/pg_url_libpq_test.exs, run as `python3 -I`.
Reads a JSON list of hex-encoded strings on stdin; writes a JSON list, one
entry per string: {"ok": {keyword: hex value}} with the options libpq set
(no defaults, no environment), or {"error": message}.

pg_dump, pg_restore and psql hand their connection argument to libpq as
`dbname` with expand_dbname, which parses it as a connection string only when
it starts with postgres:// or postgresql:// or holds an `=`
(recognized_connection_string in fe-connect.c); anything else is a database
name. That rule is applied here, so a bare string comes back as its dbname.

argv[1], when given, is the directory `pg_config --libdir` names.
"""

import ctypes
import ctypes.util
import json
import os
import sys


class Option(ctypes.Structure):
    _fields_ = [
        ("keyword", ctypes.c_char_p),
        ("envvar", ctypes.c_char_p),
        ("compiled", ctypes.c_char_p),
        ("val", ctypes.c_char_p),
        ("label", ctypes.c_char_p),
        ("dispchar", ctypes.c_char_p),
        ("dispsize", ctypes.c_int),
    ]


def load_libpq(libdir):
    candidates = []
    if libdir:
        for name in ("libpq.dylib", "libpq.so.5", "libpq.so"):
            candidates.append(os.path.join(libdir, name))
    found = ctypes.util.find_library("pq")
    if found:
        candidates.append(found)
    for path in candidates:
        try:
            return ctypes.CDLL(path)
        except OSError:
            continue
    sys.exit("libpq not found (tried: %s)" % ", ".join(candidates))


def main():
    libpq = load_libpq(sys.argv[1] if len(sys.argv) > 1 else None)
    libpq.PQconninfoParse.restype = ctypes.POINTER(Option)
    libpq.PQconninfoParse.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
    libpq.PQconninfoFree.argtypes = [ctypes.POINTER(Option)]
    libpq.PQconninfoFree.restype = None
    libpq.PQfreemem.argtypes = [ctypes.c_void_p]
    libpq.PQfreemem.restype = None

    results = []
    for encoded in json.load(sys.stdin):
        raw = bytes.fromhex(encoded)

        if not (raw.startswith(b"postgres://") or raw.startswith(b"postgresql://") or b"=" in raw):
            results.append({"ok": {"dbname": raw.hex()}})
            continue

        errmsg = ctypes.c_void_p()
        options = libpq.PQconninfoParse(raw, ctypes.byref(errmsg))

        if not options:
            message = ctypes.cast(errmsg, ctypes.c_char_p).value if errmsg.value else b"out of memory"
            if errmsg.value:
                libpq.PQfreemem(errmsg)
            results.append({"error": message.decode("utf-8", "replace").strip()})
            continue

        parsed = {}
        i = 0
        while options[i].keyword is not None:
            if options[i].val is not None:
                parsed[options[i].keyword.decode()] = options[i].val.hex()
            i += 1
        libpq.PQconninfoFree(options)
        results.append({"ok": parsed})

    json.dump(results, sys.stdout)


main()
