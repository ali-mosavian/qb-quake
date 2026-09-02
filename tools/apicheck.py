"""apicheck.py -- cross-check mgl's .bi declares against the asm proc directives.

The proc directive is authoritative: the assembler computes stack offsets
from it and the body addresses parameters by name, so it cannot drift from
the implementation. The .bi is what callers actually compile against. Any
disagreement between the two is a real defect in one of them.

Compares, per public proc: parameter COUNT and per-parameter SIZE in bytes.
Names are not compared (the two sides legitimately differ in spelling).
"""
import re, glob, sys

# --- asm side -------------------------------------------------------------
ASM_SIZE = {
    'byte': 1, 'sbyte': 1,
    'word': 2, 'sword': 2,
    'dword': 4, 'sdword': 4,
    'fword': 6, 'qword': 8, 'real4': 4, 'real8': 8,
}

def asm_param_size(t):
    t = t.strip().lower()
    if t.startswith('far ptr'):
        return 4
    if t.startswith('ptr') or t.startswith('near ptr'):
        return 2
    base = t.split()[0] if t else ''
    if base in ASM_SIZE:
        return ASM_SIZE[base]
    return None          # a named STRUC or unknown: size not derivable here

def parse_asm(root):
    out = {}
    for f in glob.glob(root + '/src/**/*.asm', recursive=True):
        lines = open(f, errors='ignore').read().split('\n')
        for i, l in enumerate(lines):
            m = re.match(r'^([A-Za-z_][\w$]*)\s+proc\s+(.*)$', l)
            if not m:
                continue
            name, rest = m.group(1), m.group(2)
            blob = rest
            j = i
            while blob.rstrip().endswith('\\') and j + 1 < len(lines):
                j += 1
                blob = blob.rstrip()[:-1] + ' ' + lines[j].strip()
            if 'private' in blob.lower():
                continue
            # The attribute clause and the FIRST parameter are separated by
            # whitespace, not a comma -- `proc public dc:dword, color:dword`.
            # Splitting on the first comma therefore ate parameter one, which
            # showed up as a systematic asm = bi-1 across 40 procs. Locate the
            # first `name:type` instead; `uses <regs>` and the langtype
            # keywords never contain a colon, so this cannot catch them.
            blob = blob.split(';')[0]
            mfirst = re.search(r'[A-Za-z_]\w*\s*:', blob)
            head = blob[:mfirst.start()] if mfirst else blob
            params = blob[mfirst.start():] if mfirst else ''
            if 'public' not in head.lower():
                continue
            plist = []
            for p in params.split(','):
                p = p.strip()
                if not p or ':' not in p:
                    continue
                pname, ptype = p.split(':', 1)
                plist.append((pname.strip(), ptype.strip(), asm_param_size(ptype)))
            out[name.lower()] = (name, plist, f)
    return out

# --- BASIC side -----------------------------------------------------------
BAS_SIZE = {'integer': 2, 'long': 4, 'single': 4, 'double': 8, 'string': 4, 'any': None}

def bas_param_size(decl_txt, typ):
    typ = typ.strip().lower()
    d = decl_txt.lower()
    if d.startswith('seg '):
        return 4                       # SEG = raw far pointer
    if d.startswith('byval'):
        return BAS_SIZE.get(typ, None)
    return 2                           # plain byref = near pointer

def parse_bi(root):
    out = {}
    for f in glob.glob(root + '/inc/*.bi'):
        txt = open(f, errors='ignore').read()
        txt = re.sub(r'_\s*\r?\n', ' ', txt)      # join continuations
        for line in txt.split('\n'):
            m = re.match(r'\s*declare\s+(function|sub)\s+([A-Za-z_][\w$]*)\s*([%&!#$]?)\s*\((.*)\)',
                         line, re.I)
            if not m:
                continue
            name, params = m.group(2), m.group(4)
            plist = []
            for p in params.split(','):
                p = p.strip()
                if not p:
                    continue
                mm = re.match(r'(.*?)\bas\s+([A-Za-z_]\w*)', p, re.I)
                if mm:
                    plist.append((p, bas_param_size(p, mm.group(2))))
                else:
                    plist.append((p, None))
            out[name.lower()] = (name, plist, f)
    return out

root = sys.argv[1]
asm, bi = parse_asm(root), parse_bi(root)
common = sorted(set(asm) & set(bi))

cnt_mismatch, size_mismatch = [], []
for k in common:
    an, ap, af = asm[k]
    bn, bp, bf = bi[k]
    if len(ap) != len(bp):
        cnt_mismatch.append((an, len(ap), len(bp), af))
        continue
    for idx, ((pn, pt, asz), (bd, bsz)) in enumerate(zip(ap, bp)):
        if asz is not None and bsz is not None and asz != bsz:
            size_mismatch.append((an, idx, pn, pt, asz, bd.strip(), bsz))

print(f"public procs in asm : {len(asm)}")
print(f"declares in .bi     : {len(bi)}")
print(f"matched by name     : {len(common)}")
print(f"in asm, absent .bi  : {len(set(asm)-set(bi))}")
print(f"in .bi, absent asm  : {len(set(bi)-set(asm))}")
print()
print(f"=== PARAM COUNT MISMATCH ({len(cnt_mismatch)}) ===")
for n, a, b, f in cnt_mismatch:
    print(f"  {n:22s} asm={a} bi={b}   {f}")
print()
print(f"=== PARAM SIZE MISMATCH ({len(size_mismatch)}) ===")
for n, i, pn, pt, asz, bd, bsz in size_mismatch:
    print(f"  {n:22s} #{i} {pn}:{pt} ({asz}B) vs BASIC '{bd}' ({bsz}B)")

print()
print("=== DECLARED IN .bi BUT NO ASM PROC (phantom-declare candidates) ===")
for k in sorted(set(bi) - set(asm)):
    print("  " + bi[k][0])
