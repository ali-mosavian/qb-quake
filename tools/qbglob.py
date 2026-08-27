"""List procedures that reach for a global struct instead of taking it."""
import io, re, glob, sys

STRUCTS = ['wld','env','pl','cam','rdr','vis','scr','cp','ft','pal']

ARRAYS = ['tri_buffer','tex_inf_buff','pln_buffer','nds_buffer','mdl_buffer',
          'order_list','poly_flag','gv_buf','h_textr_dc','mip_buff_inf',
          'h_rawtx_dc','brush','tele','face_mdl','plat','cp_x','cp_y','cp_z',
          'bit_array','frustum']


def procs(path):
    lines = io.open(path,'rb').read().decode('latin-1').replace('\r\n','\n').split('\n')
    i, n = 0, len(lines)
    while i < n:
        m = re.match(r'(sub|function)\s+(\w+)(.*)$', lines[i])
        if not m:
            i += 1
            continue
        kind, name = m.group(1), m.group(2)
        params, j = '', i
        if m.group(3).strip().endswith('_'):          # multi-line signature
            j = i + 1
            while j < n and not lines[j].startswith(')'):
                params += lines[j] + '\n'
                j += 1
        else:
            params = m.group(3)
        body, k = [], j + 1
        while k < n and not re.match(r'end\s+(sub|function)', lines[k]):
            if not lines[k].lstrip().startswith("''"):
                body.append(lines[k])
            k += 1
        yield name, set(re.findall(r'(\w+)\(?\)?\s+as\s+', params)), '\n'.join(body)
        i = k + 1


if __name__ == '__main__':
    bad = 0
    for f in sorted(glob.glob('src/*.bas')):
        for name, params, body in procs(f):
            hit = [v for v in STRUCTS
                   if v not in params
                   and re.search(r'(?<![A-Za-z0-9_.])%s(?![A-Za-z0-9_])' % v, body)]
            hit += [a + '()' for a in ARRAYS
                    if a not in params
                    and re.search(r'(?<![A-Za-z0-9_.])%s\s*\(' % a, body)]
            if hit:
                bad += 1
                print("%-14s %-22s %s" % (f.split('/')[-1], name, ', '.join(hit)))
    print("\n%d procedures still reaching" % bad)
