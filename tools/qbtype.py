"""Rename UDTs, and delete dead ones, in BASIC source.

A type name only ever appears as `type X` or `as X`, so those are the only
places rewritten. That matters: `model` is a type, a parameter of
r_draw_world, AND a field of PlatEnt -- a general identifier rename would
corrupt the latter two.
"""
import re, sys, io
sys.path.insert(0, 'tools')
from qbrename import split_code


def apply(path, mapping, drop):
    raw = io.open(path, 'rb').read().decode('latin-1')
    lines = raw.split('\r\n')

    # 1. delete whole `type X ... end type` blocks for dead types
    out, i, n = [], 0, len(lines)
    while i < n:
        m = re.match(r'\s*type\s+(\w+)\s*$', lines[i], re.I)
        if m and m.group(1).lower() in drop:
            while i < n and not re.match(r'\s*end\s+type', lines[i], re.I):
                i += 1
            i += 1                                  # skip `end type`
            while out and out[-1].strip() == '':    # and a blank line before it
                out.pop()
            continue
        out.append(lines[i])
        i += 1

    # 2. rename, in code runs only
    pats = [(re.compile(r'(?<![A-Za-z0-9_.])(type\s+|as\s+)(%s)(?![A-Za-z0-9_])' % k, re.I), v)
            for k, v in mapping.items()]
    res, hits = [], 0
    for line in out:
        parts = []
        for text, is_code in split_code(line):
            if is_code:
                for pat, new in pats:
                    text, k = pat.subn(lambda m: m.group(1) + new, text)
                    hits += k
            parts.append(text)
        res.append(''.join(parts))
    io.open(path, 'wb').write('\r\n'.join(res).encode('latin-1'))
    return hits
