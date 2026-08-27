"""Move each DECLARE to the header that can actually see its types.

A declare may only name types the including module has already seen. The
headers form a chain (see AGENTS.md), so a declare belongs in whichever one
defines the LATEST type it mentions. Getting this wrong gives
`TYPE not defined` pointed at the definition, which reads as though the
definition is broken.
"""
import io, re, glob, sys

ORDER = ['bspfile.bi', 'q_env.bi', 'q_map.bi', 'q_vis.bi', 'q_draw.bi',
         'q_scr.bi', 'q_cam.bi', 'q_pl.bi', 'q_ent.bi', 'q_snd.bi']


def type_home():
    """type name -> index in ORDER of the header defining it."""
    home = {}
    for i, h in enumerate(ORDER):
        try:
            s = io.open('src/' + h, 'rb').read().decode('latin-1')
        except IOError:
            continue
        for m in re.finditer(r'^type (\w+)\s*$', s.replace('\r', ''), re.M):
            home[m.group(1).lower()] = i
    return home


DECL = (r'^declare (?:sub|function) \w+ \( _\n.*?^\)(?: as \w+)?$',
        r'^declare (?:sub|function) \w+(?: \([^\n]*\))?(?: as \w+)?$')


def collect():
    """(text, wanted_index) for every declare in every header."""
    home = type_home()
    found = []
    for h in ORDER:
        p = 'src/' + h
        try:
            s = io.open(p, 'rb').read().decode('latin-1').replace('\r\n', '\n')
        except IOError:
            continue
        def take(m):
            want = 0
            for t in re.findall(r'\bas (\w+)', m.group(0)):
                want = max(want, home.get(t.lower(), 0))
            found.append((m.group(0), want, h))
            return ''
        s = re.sub(DECL[0], take, s, flags=re.M | re.S)
        s = re.sub(DECL[1], take, s, flags=re.M)
        io.open(p, 'wb').write(s.replace('\n', '\r\n').encode('latin-1'))
    return found


def place(found):
    by_header = {}
    moved = 0
    for text, want, was in found:
        h = ORDER[want]
        by_header.setdefault(h, []).append(text)
        if h != was:
            moved += 1
    for h, decls in by_header.items():
        p = 'src/' + h
        s = io.open(p, 'rb').read().decode('latin-1').replace('\r\n', '\n')
        s = re.sub(r'\n{3,}', '\n\n', s).rstrip('\n')
        s += "\n\n''\n'' Procedures whose signatures can be read from here.\n''\n"
        s += "\n".join(sorted(decls)) + "\n"
        io.open(p, 'wb').write(s.replace('\n', '\r\n').encode('latin-1'))
    return moved


if __name__ == '__main__':
    f = collect()
    print("%d declares, %d moved" % (len(f), place(f)))
