"""Rename identifiers in BASIC source, skipping string literals and comments.

A blind regex over the whole file rewrote HUD text and bench.txt keys the
first time this was attempted. BASIC's lexical rules are simple enough to
respect exactly: "..." is a string (no escapes; "" is a literal quote), and
a ' outside a string starts a comment that runs to end of line.
"""
import re, sys

def split_code(line):
    """Yield (text, is_code) runs for one line."""
    out, i, n = [], 0, len(line)
    buf = []
    while i < n:
        c = line[i]
        if c == '"':
            if buf: out.append((''.join(buf), True)); buf = []
            j = i + 1
            while j < n:
                if line[j] == '"':
                    if j + 1 < n and line[j+1] == '"':
                        j += 2; continue
                    j += 1; break
                j += 1
            out.append((line[i:j], False)); i = j
        elif c == "'":
            if buf: out.append((''.join(buf), True)); buf = []
            out.append((line[i:], False)); i = n
        else:
            buf.append(c); i += 1
    if buf: out.append((''.join(buf), True))
    return out

def rename(path, mapping):
    raw = open(path, 'rb').read().decode('latin-1')
    # BASIC identifiers are case-insensitive: CamLookAt and camLookAt are the
    # same variable, and a case-sensitive rename leaves half the sites behind.
    pats = [(re.compile(r'(?<![A-Za-z0-9_.])' + k + r'(?![A-Za-z0-9_])', re.IGNORECASE), v)
            for k, v in mapping.items()]
    total = 0
    out_lines = []
    for line in raw.split('\r\n'):
        parts = []
        for text, is_code in split_code(line):
            if is_code:
                for pat, repl in pats:
                    text, k = pat.subn(repl, text)
                    total += k
            parts.append(text)
        out_lines.append(''.join(parts))
    open(path, 'wb').write('\r\n'.join(out_lines).encode('latin-1'))
    return total
