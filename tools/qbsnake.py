import re, sys, glob
sys.path.insert(0,'/tmp')

def snake(n):
    s = re.sub(r'(.)([A-Z][a-z]+)', r'\1_\2', n)
    s = re.sub(r'([a-z0-9])([A-Z])', r'\1_\2', s)
    return s.lower()

def split_code(line):
    out, i, n, buf = [], 0, len(line), []
    while i < n:
        c = line[i]
        if c == '"':
            if buf: out.append((''.join(buf), True)); buf=[]
            j=i+1
            while j < n:
                if line[j]=='"':
                    if j+1<n and line[j+1]=='"': j+=2; continue
                    j+=1; break
                j+=1
            out.append((line[i:j], False)); i=j
        elif c == "'":
            if buf: out.append((''.join(buf), True)); buf=[]
            out.append((line[i:], False)); i=n
        else:
            buf.append(c); i+=1
    if buf: out.append((''.join(buf), True))
    return out

def apply(files, members, globals_):
    pats = []
    for k,v in members.items():                       # match only after a dot
        pats.append((re.compile(r'(?<=\.)' + k + r'(?![A-Za-z0-9_])', re.I), v))
    for k,v in globals_.items():                      # match only NOT after a dot
        pats.append((re.compile(r'(?<![A-Za-z0-9_.])' + k + r'(?![A-Za-z0-9_])', re.I), v))
    tot=0
    for f in files:
        raw=open(f,'rb').read().decode('latin-1')
        outl=[]
        for line in raw.split('\r\n'):
            parts=[]
            for text, is_code in split_code(line):
                if is_code:
                    for p,r in pats:
                        text,k = p.subn(r, text); tot+=k
                parts.append(text)
            outl.append(''.join(parts))
        open(f,'wb').write('\r\n'.join(outl).encode('latin-1'))
    return tot
