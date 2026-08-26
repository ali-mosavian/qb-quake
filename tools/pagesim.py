#!/usr/bin/env python3
"""pagesim.py -- how many page faults would a paged BSP walk cost?

The fixed-footprint design rests on one number: with only four EMS
physical pages to map through, how often does a frame's BSP descent have
to remap? If a descent fits in the window, map size stops mattering; if it
thrashes, the design is not worth building.

Answering it offline costs an afternoon and no target-side work.

Two layouts are compared:

  index    nodes in BSP file order, as the arrays are today
  dfs      nodes in depth-first order, so a subtree is contiguous and a
           descent walks forward through pages instead of jumping

and the node record is DENORMALISED -- each node carries its own plane --
because otherwise every visit touches two arrays and therefore two pages,
which doubles the fault rate before anything else is decided.

Culling is bracketed rather than reproduced exactly. `none` visits every
node and is the worst case any camera can produce; `frustum` uses a
standard frustum whose details need not match the renderer's, because the
conclusion only has to hold across the bracket.
"""
import struct, sys, math, os

NODE_BYTES = 40          # 22 of node + 18 of its plane, denormalised


def lumps(d):
    return [struct.unpack_from('<ii', d, 4 + i * 8) for i in range(15)]


def load(path):
    d = open(path, 'rb').read()
    L = lumps(d)
    def lump(i):
        o, n = L[i]
        return d[o:o + n]
    planes = []
    raw = lump(1)
    for k in range(0, len(raw), 20):
        nx, ny, nz, dist, _t = struct.unpack_from('<ffffi', raw, k)
        planes.append((nx, ny, nz, dist))
    nodes = []
    raw = lump(5)
    for k in range(0, len(raw), 24):
        pl, c0, c1 = struct.unpack_from('<ihh', raw, k)
        mins = struct.unpack_from('<3h', raw, k + 8)
        maxs = struct.unpack_from('<3h', raw, k + 14)
        nodes.append((pl, c0, c1, mins, maxs))
    leaves = []
    raw = lump(10)
    for k in range(0, len(raw), 28):
        cont, _vis = struct.unpack_from('<ii', raw, k)
        mins = struct.unpack_from('<3h', raw, k + 8)
        maxs = struct.unpack_from('<3h', raw, k + 14)
        leaves.append((cont, mins, maxs))
    return planes, nodes, leaves


def dfs_order(nodes):
    """Node index -> position in a depth-first walk."""
    pos, order, stack = {}, [], [0]
    while stack:
        n = stack.pop()
        if n < 0 or n in pos:
            continue
        pos[n] = len(order)
        order.append(n)
        _pl, c0, c1 = nodes[n][0], nodes[n][1], nodes[n][2]
        for c in (c1, c0):                    # push reversed: c0 first out
            if not (c & 0x8000) and c < len(nodes):
                stack.append(c)
    return pos


def frustum_planes(pos, yaw, fov, far):
    """Six half-spaces in BSP world space, outward normals.

    `culled` keeps a point when p.n <= dist, so every normal here points
    OUT of the volume and dist is the boundary along it. Getting either
    sign wrong culls the root and the walk reports zero visits, which is
    how the first version of this failed.
    """
    x0, y0, z0 = pos
    cy, sy = math.cos(yaw), math.sin(yaw)
    half = math.radians(fov) / 2.0
    ahead = cy * x0 + sy * y0
    out = [
        (-cy, -sy, 0.0, -ahead),              # near: keep p.v >= p0.v
        (cy,  sy,  0.0, ahead + far),         # far:  keep p.v <= p0.v+far
        (0.0, 0.0,  1.0, z0 + 2048),          # keep z <= z0+2048
        (0.0, 0.0, -1.0, -(z0 - 2048)),       # keep z >= z0-2048
    ]
    for s_ in (+1, -1):                       # right, then left
        a = yaw + s_ * half
        nx, ny = -math.sin(a) * s_, math.cos(a) * s_
        out.append((nx, ny, 0.0, nx * x0 + ny * y0))
    return out


def culled(box, fr):
    mins, maxs = box
    for nx, ny, nz, dist in fr:
        px = mins[0] if nx > 0 else maxs[0]
        py = mins[1] if ny > 0 else maxs[1]
        pz = mins[2] if nz > 0 else maxs[2]
        if px * nx + py * ny + pz * nz - dist > 0:
            return True
    return False


def walk(nodes, leaves, planes, pos, fr, touch):
    """The renderer's descent: cull, pick a side, recurse. Records every
    node whose record is read."""
    stack = [0]
    visits = 0
    while stack:
        n = stack.pop()
        if n & 0x8000:
            li = (~n) & 0xFFFF
            if li < len(leaves) and fr is not None:
                if culled((leaves[li][1], leaves[li][2]), fr):
                    continue
            continue
        if n >= len(nodes):
            continue
        pl, c0, c1, mins, maxs = nodes[n]
        if fr is not None and culled((mins, maxs), fr):
            continue
        touch(n)                                # the node record is read
        visits += 1
        nx, ny, nz, dist = planes[pl]
        side = (pos[0] * nx + pos[1] * ny + pos[2] * nz - dist) >= 0
        stack.append(c0 if side else c1)
        stack.append(c1 if side else c0)
    return visits


def simulate(path, npages, layout, cullmode, samples=64):
    planes, nodes, leaves = load(path)
    page_of = {}
    per_page = 16384 // NODE_BYTES
    if layout == 'dfs':
        pos_of = dfs_order(nodes)
        for n in range(len(nodes)):
            page_of[n] = pos_of.get(n, len(nodes)) // per_page
    else:
        for n in range(len(nodes)):
            page_of[n] = n // per_page

    # viewpoints: empty leaf centres, several yaws each
    spots = [((l[1][0] + l[2][0]) / 2.0, (l[1][1] + l[2][1]) / 2.0,
              (l[1][2] + l[2][2]) / 2.0) for l in leaves if l[0] == -1]
    step = max(1, len(spots) // samples)
    spots = spots[::step][:samples]

    faults, visits, frames = [], [], 0
    for p in spots:
        for yaw in [i * math.pi / 4 for i in range(8)]:
            fr = None if cullmode == 'none' else frustum_planes(p, yaw, 90.0, 4096)
            resident, order, f = set(), [], 0
            def touch(n, resident=resident, order=order):
                nonlocal f
                pg = page_of[n]
                if pg in resident:
                    order.remove(pg); order.append(pg); return
                f += 1
                if len(resident) >= npages:
                    old = order.pop(0); resident.discard(old)
                resident.add(pg); order.append(pg)
            v = walk(nodes, leaves, planes, p, fr, touch)
            faults.append(f); visits.append(v); frames += 1
            if cullmode == 'none':
                break                          # yaw is irrelevant with no cull
    faults.sort(); visits.sort()
    q = lambda a, p: a[min(len(a) - 1, int(len(a) * p))]
    return dict(pages=(len(nodes) * NODE_BYTES + 16383) // 16384,
                nodes=len(nodes), frames=frames,
                f50=q(faults, .5), f95=q(faults, .95), fmax=faults[-1],
                v50=q(visits, .5), vmax=visits[-1])


def summary(path, win=4):
    """One line per map: the numbers that decide whether paging is viable."""
    planes, nodes, leaves = load(path)
    per_page = 16384 // NODE_BYTES
    spots = [((l[1][0] + l[2][0]) / 2.0, (l[1][1] + l[2][1]) / 2.0,
              (l[1][2] + l[2][2]) / 2.0) for l in leaves if l[0] == -1]
    if not spots:
        return None
    spots = spots[::max(1, len(spots) // 48)][:48]

    faults, visits = [], []
    for p in spots:
        for yaw in [i * math.pi / 4 for i in range(8)]:
            fr = frustum_planes(p, yaw, 90.0, 4096)
            res, order, st = set(), [], [0]
            def touch(n, res=res, order=order, st=st):
                pg = n // per_page
                if pg in res:
                    order.remove(pg); order.append(pg); return
                st[0] += 1
                if len(res) >= win:
                    res.discard(order.pop(0))
                res.add(pg); order.append(pg)
            v = walk(nodes, leaves, planes, p, fr, touch)
            faults.append(st[0]); visits.append(v)
    faults.sort(); visits.sort()
    q = lambda a, pp: a[min(len(a) - 1, int(len(a) * pp))]
    return dict(nodes=len(nodes), leaves=len(leaves),
                pages=(len(nodes) * NODE_BYTES + 16383) // 16384,
                f50=q(faults, .5), f95=q(faults, .95), fmax=faults[-1],
                v50=q(visits, .5))


if __name__ == '__main__':
    args = [a for a in sys.argv[1:] if not a.startswith('-')]
    detail = '--detail' in sys.argv
    maps = args or ['data/dm3ish.bsp', 'data/e1m7.bsp', 'data/e1m1.bsp']

    if detail:
        for m in maps:
            if not os.path.exists(m):
                continue
            head = load(m)
            print(f"\n=== {m}  {len(head[1])} nodes, "
                  f"{(len(head[1])*NODE_BYTES+16383)//16384} pages of 16K ===")
            print(f"  {'layout':8} {'cull':8} {'win':>4} "
                  f"{'faults p50':>11} {'p95':>6} {'max':>6}   {'visits p50':>11}")
            for layout in ('index', 'dfs'):
                for cull in ('frustum', 'none'):
                    for win in (2, 4, 8):
                        r = simulate(m, win, layout, cull)
                        print(f"  {layout:8} {cull:8} {win:>4} "
                              f"{r['f50']:>11} {r['f95']:>6} {r['fmax']:>6}   "
                              f"{r['v50']:>11}")
        sys.exit(0)

    print(f"{'map':<12} {'nodes':>7} {'leaves':>7} {'pages':>6} "
          f"{'visits':>7} {'faults':>7} {'p95':>5} {'max':>5}")
    print("-" * 62)
    worst = []
    for m in sorted(maps):
        if not os.path.exists(m):
            continue
        r = summary(m)
        if r is None:
            continue
        name = os.path.basename(m).replace('.bsp', '')
        print(f"{name:<12} {r['nodes']:>7} {r['leaves']:>7} {r['pages']:>6} "
              f"{r['v50']:>7} {r['f50']:>7} {r['f95']:>5} {r['fmax']:>5}")
        worst.append((r['fmax'], name, r))
    if worst:
        worst.sort(reverse=True)
        fm, nm, r = worst[0]
        print("-" * 62)
        print(f"worst: {nm} at {fm} faults in a frame "
              f"({r['nodes']} nodes, {r['pages']} pages)")
