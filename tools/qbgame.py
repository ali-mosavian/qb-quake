"""Bundle the state structs into one Game parameter.

Every procedure taking some subset of wld/env/pl/cam/... takes `g as Game`
instead, and the references in its body are qualified. Done per procedure,
because a name means different things in different places: `pl` is the
player in pl_move and a Plane in r_plane_dist.
"""
import io, re, glob, sys

FIELDS = ['wld','env','pl','cam','rdr','vis','scr','cp','ft','pal',
          'mymod','tele_count','plat_count']
TYPES  = {'wld':'World','env':'Env','pl':'PlayerState','cam':'CamState',
          'rdr':'RenderState','vis':'VisState','scr':'ScreenState',
          'cp':'CamPath','ft':'FrameTimes','pal':'long','mymod':'UGMMOD',
          'tele_count':'integer','plat_count':'integer'}


def convert(path):
    s = io.open(path, 'rb').read().decode('latin-1').replace('\r\n', '\n')
    out, i, n, hits = [], 0, 0, 0
    lines = s.split('\n')
    n = len(lines)
    while i < n:
        m = re.match(r'(sub|function)\s+(\w+)\s+\( _$', lines[i])
        one = re.match(r'(sub|function)\s+(\w+)\s+\(([^\n]*)\)(.*)$', lines[i])
        if m:
            kind, name = m.group(1), m.group(2)
            j = i + 1
            params = []
            while j < n and not lines[j].startswith(')'):
                params.append(lines[j]); j += 1
            tail = lines[j][1:]
        elif one:
            kind, name = one.group(1), one.group(2)
            params = ['    %s, _' % a.strip() for a in split_args(one.group(3))]
            if params: params[-1] = params[-1].rstrip().rstrip('_').rstrip().rstrip(',') + ' _'
            j = i
            tail = one.group(4)
        else:
            out.append(lines[i]); i += 1; continue

        keep, taken = [], []
        for p in params:
            pm = re.match(r'\s+(?:byval\s+)?(\w+)(\(\))?\s+as\s+(\w+)', p)
            if pm and not pm.group(2) and pm.group(1) in FIELDS \
               and pm.group(3).lower() == TYPES[pm.group(1)].lower():
                taken.append(pm.group(1))
            else:
                keep.append(p)
        if not taken:
            out.append(lines[i]); i += 1; continue

        hits += 1
        keep = ['    g as Game, _'] + keep
        keep[-1] = keep[-1].rstrip().rstrip('_').rstrip().rstrip(',') + ' _'
        out.append('%s %s ( _' % (kind, name))
        out += keep
        out.append(')' + tail)

        k = j + 1
        body = []
        while k < n and not re.match(r'end\s+(sub|function)', lines[k]):
            body.append(lines[k]); k += 1
        blob = '\n'.join(body)
        for f in taken:
            blob = re.sub(r'(?<![A-Za-z0-9_.$])%s(?![A-Za-z0-9_(])' % f,
                          'g.' + f, blob)
        out += blob.split('\n')
        out.append(lines[k])
        i = k + 1
    io.open(path, 'wb').write('\n'.join(out).replace('\n', '\r\n').encode('latin-1'))
    return hits


if __name__ == '__main__':
    t = 0
    for p in sorted(glob.glob('src/*.bas')):
        k = convert(p)
        t += k
        if k: print("%-14s %d" % (p.split('/')[-1], k))
    print("total", t)


# ---------------------------------------------------------------- calls ----
def split_args(s):
    parts, depth, cur = [], 0, []
    for c in s:
        if c == '(': depth += 1
        elif c == ')': depth -= 1
        if c == ',' and depth == 0:
            parts.append(''.join(cur).strip()); cur = []; continue
        cur.append(c)
    if ''.join(cur).strip(): parts.append(''.join(cur).strip())
    return parts


def fix_calls(path, names):
    """Drop g.<field> arguments and pass g instead."""
    raw = io.open(path, 'rb').read().decode('latin-1')
    lines = raw.split('\r\n')
    out, i, n, hits = [], 0, len(lines), 0
    field = re.compile(r'^g\.(%s)$' % '|'.join(FIELDS))
    while i < n:
        line = lines[i]
        joined, j = line, i
        while joined.rstrip().endswith('_') and j + 1 < n:
            j += 1
            joined = joined.rstrip()[:-1].rstrip() + ' ' + lines[j].strip()
        m = re.match(r'(\s*)(?:(\w+)\s*=\s*)?(%s)\s*(\(?)(.*)$'
                     % '|'.join(names), joined)
        if not m or re.match(r'\s*(declare |sub |function )', joined, re.I):
            out.append(line); i += 1; continue
        indent, lhs, name, paren, rest = m.groups()
        if paren:
            k = rest.rfind(')')
            args, after = split_args(rest[:k]), rest[k+1:]
        else:
            args, after = split_args(rest), ''
        if not any(field.match(a) for a in args):
            out.append(line); i += 1; continue
        args = ['g'] + [a for a in args if not field.match(a)]
        call = "%s%s%s%s" % (indent, (lhs + ' = ') if lhs else '', name,
                             (' ( %s )%s' % (', '.join(args), after)) if paren
                             else (' ' + ', '.join(args)))
        if len(call) > 96:
            head = "%s%s%s %s" % (indent, (lhs + ' = ') if lhs else '', name,
                                  '( ' if paren else '')
            pad = ' ' * len(head.rstrip('( '))
            wrapped, cur = [], head
            for a, arg in enumerate(args):
                piece = arg + (', ' if a < len(args) - 1 else '')
                if len(cur) + len(piece) > 92:
                    wrapped.append(cur.rstrip() + ' _'); cur = pad + '  '
                cur += piece
            if paren: cur += ' )' + after
            wrapped.append(cur)
            out += wrapped
        else:
            out.append(call)
        hits += 1
        i = j + 1
    io.open(path, 'wb').write('\r\n'.join(out).encode('latin-1'))
    return hits
