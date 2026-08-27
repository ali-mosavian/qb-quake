"""Snake-case sweep: UDT fields, identifiers, and bench.txt report keys.

Three passes because the three live in different lexical places. A field is
only ever `.name` or a declaration inside a `type` body; an identifier is
code but never a string or comment; a report key is only ever a string.
"""
import io, re, sys
sys.path.insert(0, 'tools')
from qbrename import split_code

FIELDS = {
 'camfov':'cam_fov', 'caminterp':'cam_interp', 'cammode':'cam_mode',
 'campath':'cam_path', 'camscrpt':'cam_script', 'clipnode':'clip_node',
 'cmapptr':'cmap_ptr', 'disclear':'clear_screen', 'firstface':'first_face',
 'fpsview':'fps_view', 'headnode0':'head_node0', 'headnode1':'head_node1',
 'headnode2':'head_node2', 'headnode3':'head_node3', 'ledgeid':'ledge_id',
 'ledgenum':'ledge_num', 'lfaceid':'lface_id', 'lfacenum':'lface_num',
 'lmstride':'lm_stride', 'miptex':'mip_tex', 'noclip':'no_clip',
 'numfaces':'num_faces', 'numtex':'num_tex', 'planeid':'plane_id',
 'planenum':'plane_num', 'rendmode':'rend_mode', 'tbuilds':'total_builds',
 'texinfo':'tex_info', 'texinfoid':'tex_info_id', 'usemips':'use_mips',
 'usepag':'use_paging', 'visleafs':'vis_leafs', 'vislist':'vis_list',
}

IDENTS = {
 'bitarray':'bit_array', 'bmpfile':'bmp_file', 'leaftmp':'leaf_tmp',
 'linenum':'line_num', 'loadmod':'load_mod', 'lumpbytes':'lump_bytes',
 'miplevel':'mip_level', 'nmodels':'model_count', 'nleafs':'leaf_count',
 'nfaces':'face_count', 'nodetmp':'node_tmp', 'offbits':'off_bits',
 'planetmp':'plane_tmp', 'polycnt':'poly_cnt', 'polyvert':'poly_vert',
 'texinfotmp':'tex_info_tmp', 'texoffs':'tex_offs', 'tmipinf':'t_mip_inf',
 'tokenlist':'token_list', 'turbsin':'turb_sin', 'uvbuffb':'uv_buff_b',
 'rawline':'raw_line', 'clptmp':'clip_tmp',
}

KEYS = {
 'geomrows':'geom_rows', 'lmsize':'lm_size', 'lmread':'lm_read',
 'cmsize':'cm_size', 'scmade':'sc_made', 'scbuilt':'sc_built',
 'scworst':'sc_worst', 'sclive':'sc_live', 'scevict':'sc_evict',
 'scflush':'sc_flush', 'scems':'sc_ems', 'sctest':'sc_test',
 'clprec':'clp_rec', 'clpcnt':'clp_cnt', 'platzofs':'plat_zofs',
 'platstate':'plat_state', 'waterlevel':'water_level',
 'watertype':'water_type', 'onground':'on_ground', 'peakz':'peak_z',
 'cppts':'cp_pts', 'tickhz':'tick_hz', 'memavail':'mem_avail',
 'lastfps':'last_fps', 'peakfps':'peak_fps', 'lowfps':'low_fps',
 'ftmin':'ft_min', 'ftmax':'ft_max', 'ftmean':'ft_mean', 'ftn':'ft_n',
 'fpsbest':'fps_best', 'fpsworst':'fps_worst', 'fpsmean':'fps_mean',
 'animtime':'anim_time',
}


def sweep(path):
    raw = io.open(path, 'rb').read().decode('latin-1')
    lines = raw.split('\r\n')
    in_type = False
    out, n = [], 0

    for line in lines:
        if re.match(r'\s*type\s+\w+\s*$', line, re.I):
            in_type = True
        elif re.match(r'\s*end\s+type', line, re.I):
            in_type = False

        parts = []
        for text, is_code in split_code(line):
            if is_code:
                # fields: `.name`, and the declaration inside a type body
                for a, b in FIELDS.items():
                    text, k = re.subn(r'\.%s(?![A-Za-z0-9_])' % a, '.' + b, text)
                    n += k
                    if in_type:
                        text, k = re.subn(r'^(\s*)%s(?![A-Za-z0-9_])' % a,
                                          r'\g<1>' + b, text)
                        n += k
                for a, b in IDENTS.items():
                    text, k = re.subn(r'(?<![A-Za-z0-9_.])%s(?![A-Za-z0-9_])' % a,
                                      b, text, flags=re.I)
                    n += k
            else:
                # report keys live only in string literals
                if text.startswith('"'):
                    for a, b in KEYS.items():
                        text, k = re.subn(r'(?<=")%s(?= )' % a, b, text)
                        n += k
            parts.append(text)
        out.append(''.join(parts))

    io.open(path, 'wb').write('\r\n'.join(out).encode('latin-1'))
    return n


if __name__ == '__main__':
    total = 0
    for p in sys.argv[1:]:
        k = sweep(p)
        total += k
        if k:
            print("%-22s %d" % (p.split('/')[-1], k))
    print("total", total)
