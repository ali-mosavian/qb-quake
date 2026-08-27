"""Reformat BASIC procedure signatures to the hanging-indent form.

    function foo ( _
        a as integer, _
        b as single _
    ) as long

Applies to declares and definitions alike, for procedures taking two or
more parameters; nothing with fewer is worth three lines. Splits on the
commas that separate PARAMETERS, so a comma inside a nested construct
does not start a new line.
"""
import re, sys, io

SIG = re.compile(
    r'^(?P<lead>\s*)(?P<decl>declare\s+)?(?P<kind>sub|function)\s+'
    r'(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*'
    r'\((?P<params>.*)\)\s*(?P<tail>(?:as\s+\w+)?(?:\s*static)?)\s*$',
    re.I)


SIG_START = re.compile(r'^\s*(declare\s+)?(sub|function)\s+[A-Za-z_][A-Za-z0-9_]*\s*\(', re.I)


def logical_lines(raw):
    """Yield each source line, joining continuations ONLY for signatures.

    Joining every `_`-continued line and re-splitting just the signatures
    flattened multi-line expressions into single lines -- which is both
    unreadable and a run at BC's 255-character limit.
    """
    lines = raw.split('\r\n')
    i, n = 0, len(lines)
    while i < n:
        if not SIG_START.match(lines[i]):
            yield lines[i]
            i += 1
            continue
        buf = lines[i]
        while buf.rstrip().endswith('_') and i + 1 < n:
            i += 1
            buf = buf.rstrip()[:-1].rstrip() + ' ' + lines[i].strip()
        yield buf
        i += 1


def split_params(s):
    """Top-level commas only."""
    parts, depth, cur = [], 0, []
    for c in s:
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
        if c == ',' and depth == 0:
            parts.append(''.join(cur).strip())
            cur = []
            continue
        cur.append(c)
    if ''.join(cur).strip():
        parts.append(''.join(cur).strip())
    return parts


def reformat(line):
    m = SIG.match(line)
    if not m:
        return [line]
    params = split_params(m.group('params'))
    head = '%s%s%s %s ( ' % (m.group('lead'), m.group('decl') or '',
                             m.group('kind'), m.group('name'))
    tail = (' ' + m.group('tail').strip()) if m.group('tail').strip() else ''
    if len(params) < 2:
        one = '%s%s )%s' % (head, ', '.join(params), tail)
        return [one.replace('(  )', '( )')]
    ind = m.group('lead') + '    '
    out = [head.rstrip() + ' _']
    for i, p in enumerate(params):
        sep = ',' if i < len(params) - 1 else ''
        out.append('%s%s%s _' % (ind, p, sep))
    out.append('%s)%s' % (m.group('lead'), tail))
    return out


def main(paths):
    for p in paths:
        raw = io.open(p, 'rb').read().decode('latin-1')
        out = []
        for line in logical_lines(raw):
            out.extend(reformat(line))
        io.open(p, 'wb').write('\r\n'.join(out).encode('latin-1'))


if __name__ == '__main__':
    main(sys.argv[1:])
