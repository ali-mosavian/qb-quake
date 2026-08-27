"""Refresh every DECLARE from its definition, in place.

A declare that has drifted from its definition is the most common build
break in this codebase, and BC reports it by pointing at the DEFINITION's
parameters -- which reads like the definition is wrong. This rewrites each
declare from the .bas that defines it, leaving the declare where it is:
which header a declare lives in is a real decision (the types it names have
to be visible there) and is not this tool's to make.
"""
import io, re, glob, sys


def definitions():
    """name -> declare text, from every .bas."""
    out = {}
    for f in glob.glob('src/*.bas'):
        s = io.open(f, 'rb').read().decode('latin-1').replace('\r\n', '\n')
        for m in re.finditer(
                r'^(sub|function) (\w+) \( _\n(.*?)^\)( as \w+)?( static)?$',
                s, re.M | re.S):
            out[m.group(2).lower()] = "declare %s %s ( _\n%s)%s" % (
                m.group(1), m.group(2), m.group(3), m.group(4) or '')
        for m in re.finditer(
                r'^(sub|function) (\w+)( \([^\n]*\))?( as \w+)?( static)?$',
                s, re.M):
            out.setdefault(m.group(2).lower(), "declare %s %s%s%s" % (
                m.group(1), m.group(2), m.group(3) or ' ( )', m.group(4) or ''))
    return out


def refresh(path, defs):
    s = io.open(path, 'rb').read().decode('latin-1').replace('\r\n', '\n')
    n = 0

    def one(m):
        nonlocal n
        name = m.group(2).lower()
        if name not in defs:
            return m.group(0)
        new = defs[name]
        if new.rstrip() != m.group(0).rstrip():
            n += 1
        return new

    s = re.sub(r'^declare (sub|function) (\w+) \( _\n.*?^\)( as \w+)?$',
               one, s, flags=re.M | re.S)
    s = re.sub(r'^declare (sub|function) (\w+)( \([^\n]*\))?( as \w+)?$',
               one, s, flags=re.M)
    io.open(path, 'wb').write(s.replace('\n', '\r\n').encode('latin-1'))
    return n


if __name__ == '__main__':
    defs = definitions()
    total = 0
    for p in sorted(glob.glob('src/*.bi')) + sorted(glob.glob('src/*.bas')):
        k = refresh(p, defs)
        total += k
        if k:
            print("%-16s %d refreshed" % (p.split('/')[-1], k))
    print("total", total)
