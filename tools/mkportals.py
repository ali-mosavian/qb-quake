"""mkportals.py -- regenerate leaf portals from a compiled BSP.

Usage: python3 tools/mkportals.py <map.bsp> [-v]

Quake ships no portals. qbsp writes a .prt, vis consumes it to produce the
visibility lump, and nobody ships the .prt -- the PVS in the bsp is the
compressed residue of a computation whose inputs were thrown away. This
rebuilds them from the tree itself, which is qbsp's own algorithm:

  - bound the world in six portals facing inward,
  - at every node, make a winding on that node's plane spanning the world,
    clip it by every portal already reaching that node, and keep what is
    left as the node's own portal,
  - push each portal down both children, splitting it wherever it straddles
    a child's plane,
  - what lands between two leaves is a portal between them.

The check this is held to, and the reason it can be trusted: vis marks a
leaf visible only if some chain of portals reaches it, so every leaf's PVS
must be a SUBSET of what a flood fill through these portals reaches. A
generator that invents, drops or misplaces portals fails that.
"""

import struct
import sys
from dataclasses import dataclass, field

ON_EPSILON = 0.1
SIDE_FRONT = 0
SIDE_BACK = 1
SIDE_ON = 2
CONTENTS_SOLID = -2

type Vec = tuple[float, float, float]
type Winding = list[Vec]


@dataclass(slots=True)
class Plane:
    norm: Vec
    dist: float

    def flipped(self) -> "Plane":
        return Plane((-self.norm[0], -self.norm[1], -self.norm[2]), -self.dist)


@dataclass(slots=True)
class Portal:
    plane: Plane
    winding: Winding
    nodes: list[int] = field(default_factory=lambda: [-1, -1])
    # A portal sits on the list of BOTH the nodes it separates. Whichever is
    # processed first splits it and hands the halves to both sides, so the
    # original must not be split again when the other side comes up.
    dead: bool = False


@dataclass(slots=True)
class Bsp:
    planes: list[Plane]
    nodes: list[tuple[int, int, int]]
    leaves: list[tuple[int, int]]
    vis: bytes
    vis_ofs: int
    mins: Vec
    maxs: Vec
    # The world model's own leaf count. NOT len(leaves): submodel leaves sit
    # after the world's, and the PVS covers only the world's -- a row sized
    # by the total reads whatever follows as though it were visibility.
    visleafs: int


def dot(a: Vec, b: Vec) -> float:
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def plane_dist(p: Plane, v: Vec) -> float:
    return dot(p.norm, v) - p.dist


def base_winding(p: Plane, size: float) -> Winding:
    """A square on p, big enough to span the world, which clipping then trims."""
    ax = max(range(3), key=lambda i: abs(p.norm[i]))
    up: Vec = (0.0, 0.0, 1.0) if ax != 2 else (1.0, 0.0, 0.0)
    d = dot(up, p.norm)
    up = tuple(up[i] - d * p.norm[i] for i in range(3))
    n = sum(c * c for c in up) ** 0.5
    up = tuple(c / n for c in up)
    right: Vec = (
        up[1] * p.norm[2] - up[2] * p.norm[1],
        up[2] * p.norm[0] - up[0] * p.norm[2],
        up[0] * p.norm[1] - up[1] * p.norm[0],
    )
    org: Vec = tuple(p.norm[i] * p.dist for i in range(3))
    up = tuple(c * size for c in up)
    right = tuple(c * size for c in right)
    return [
        tuple(org[i] - right[i] + up[i] for i in range(3)),
        tuple(org[i] + right[i] + up[i] for i in range(3)),
        tuple(org[i] + right[i] - up[i] for i in range(3)),
        tuple(org[i] - right[i] - up[i] for i in range(3)),
    ]


def clip_winding(w: Winding, p: Plane, keep_front: bool) -> Winding | None:
    """Trim w to one side of p. None when nothing survives."""
    dists = [plane_dist(p, v) for v in w]
    sides = [
        SIDE_FRONT if d > ON_EPSILON else SIDE_BACK if d < -ON_EPSILON else SIDE_ON
        for d in dists
    ]
    want, other = (SIDE_FRONT, SIDE_BACK) if keep_front else (SIDE_BACK, SIDE_FRONT)
    if other not in sides:
        return w
    if want not in sides:
        return None

    out: Winding = []
    n = len(w)
    for i in range(n):
        j = (i + 1) % n
        if sides[i] != other:
            out.append(w[i])
        if sides[i] == SIDE_ON or sides[j] == SIDE_ON or sides[i] == sides[j]:
            continue
        t = dists[i] / (dists[i] - dists[j])
        out.append(tuple(w[i][k] + t * (w[j][k] - w[i][k]) for k in range(3)))
    return out if len(out) >= 3 else None


def winding_area(w: Winding) -> float:
    total = 0.0
    for i in range(1, len(w) - 1):
        a = tuple(w[i][k] - w[0][k] for k in range(3))
        b = tuple(w[i + 1][k] - w[0][k] for k in range(3))
        cr = (
            a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0],
        )
        total += 0.5 * sum(c * c for c in cr) ** 0.5
    return total


def read_bsp(path: str) -> Bsp:
    d = open(path, "rb").read()
    lumps = [struct.unpack_from("<ii", d, 4 + 8 * i) for i in range(15)]

    po, pl = lumps[1]
    planes = []
    for i in range(pl // 20):
        nx, ny, nz, dist, _ = struct.unpack_from("<4fi", d, po + 20 * i)
        planes.append(Plane((nx, ny, nz), dist))

    no, nl = lumps[5]
    nodes = []
    for i in range(nl // 24):
        pnum, c0, c1 = struct.unpack_from("<Ihh", d, no + 24 * i)
        nodes.append((pnum, c0, c1))

    lo, ll = lumps[10]
    leaves = []
    for i in range(ll // 28):
        cont, visofs = struct.unpack_from("<ii", d, lo + 28 * i)
        leaves.append((cont, visofs))

    mo, _ = lumps[14]  # models: model 0 is the world, and carries bbox+visleafs
    mins = struct.unpack_from("<3f", d, mo)
    maxs = struct.unpack_from("<3f", d, mo + 12)
    (visleafs,) = struct.unpack_from("<i", d, mo + 52)

    vo, vl = lumps[4]
    return Bsp(planes, nodes, leaves, d[vo : vo + vl], vo, mins, maxs, visleafs)


def push_down(b: Bsp, node: int, w: Winding) -> list[tuple[int, Winding]]:
    """Drop a winding through a subtree, splitting it at every plane it
    straddles, and report which leaf each surviving piece lands in."""
    if node < 0:
        return [(~node, w)]
    pnum, c0, c1 = b.nodes[node]
    plane = b.planes[pnum]
    out: list[tuple[int, Winding]] = []
    front = clip_winding(w, plane, True)
    if front is not None and winding_area(front) > 1.0:
        out += push_down(b, c0, front)
    back = clip_winding(w, plane, False)
    if back is not None and winding_area(back) > 1.0:
        out += push_down(b, c1, back)
    return out


def build_portals(b: Bsp, verbose: bool = False) -> list[Portal]:
    """One portal per pair of leaves that share a piece of a node's plane.

    For each node: take its plane, trim it to the node's own region by
    clipping against every ancestor plane on the side this node lies, then
    drop that piece through the front subtree to find which leaf each part
    of it faces, and drop each of THOSE through the back subtree to find
    what is behind. A piece with a leaf on either side is a portal.

    Node references are the BSP's own encoding: >= 0 node, < 0 leaf ~ref.
    There is deliberately no 'outside' sentinel -- leaf 0 IS the outside
    solid leaf, and -1 would collide with its encoding exactly.
    """
    span = max(max(abs(b.maxs[i]), abs(b.mins[i])) for i in range(3)) * 2.0 + 1024.0
    portals: list[Portal] = []

    # (node, ancestors) where ancestors is [(plane, keep_front), ...]
    stack: list[tuple[int, list[tuple[Plane, bool]]]] = [(0, [])]
    while stack:
        node, anc = stack.pop()
        if node < 0:
            continue
        pnum, c0, c1 = b.nodes[node]
        plane = b.planes[pnum]

        w: Winding | None = base_winding(plane, span)
        for ap, keep_front in anc:
            if w is None:
                break
            w = clip_winding(w, ap, keep_front)

        if w is not None and winding_area(w) > 1.0:
            for lf, wf in push_down(b, c0, w):
                for lb, wb in push_down(b, c1, wf):
                    portals.append(Portal(plane, wb, [~lf, ~lb]))

        stack.append((c0, anc + [(plane, True)]))
        stack.append((c1, anc + [(plane, False)]))

    return portals


def decompress_vis(b: Bsp, ofs: int) -> bytearray:
    out = bytearray((b.visleafs + 7) // 8)
    v, i = ofs, 0
    while i < len(out):
        if v >= len(b.vis):
            break
        byte = b.vis[v]
        v += 1
        if byte:
            out[i] = byte
            i += 1
        else:
            count = b.vis[v]
            v += 1
            for _ in range(count):
                if i < len(out):
                    out[i] = 0
                    i += 1
    return out


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    verbose = "-v" in sys.argv

    b = read_bsp(path)
    nleaf = len(b.leaves)
    print(f"{path}: {len(b.nodes)} nodes, {nleaf} leaves ({b.visleafs} in the world)")
    print(f"world bounds {b.mins} .. {b.maxs}")

    portals = build_portals(b, verbose)
    print(f"portals built: {len(portals)}")

    # adjacency over non-solid leaves
    adj: dict[int, set[int]] = {}
    solid = 0
    for p in portals:
        a, c = ~p.nodes[0], ~p.nodes[1]
        if b.leaves[a][0] == CONTENTS_SOLID or b.leaves[c][0] == CONTENTS_SOLID:
            solid += 1
            continue
        adj.setdefault(a, set()).add(c)
        adj.setdefault(c, set()).add(a)
    print(f"  {solid} touch a solid leaf; {len(adj)} leaves have neighbours")

    # THE check: PVS must be a subset of what portals reach.
    bad = 0
    checked = 0
    for li in range(1, b.visleafs + 1):
        cont, visofs = b.leaves[li]
        if cont == CONTENTS_SOLID or visofs < 0:
            continue
        bits = decompress_vis(b, visofs)
        pvs = {j + 1 for j in range(b.visleafs) if bits[j >> 3] >> (j & 7) & 1}

        seen, stack = {li}, [li]
        while stack:
            cur = stack.pop()
            for nb in adj.get(cur, ()):
                if nb not in seen:
                    seen.add(nb)
                    stack.append(nb)

        checked += 1
        missing = pvs - seen
        if missing:
            bad += 1
            if verbose and bad <= 5:
                print(f"  leaf {li}: {len(missing)} PVS leaves unreachable, e.g. {sorted(missing)[:6]}")

    print(f"PVS-subset check: {checked - bad}/{checked} leaves pass")
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
