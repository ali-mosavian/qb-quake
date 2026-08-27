#!/usr/bin/env python3
"""Generate a camera flight path through a .bsp, for repeatable benchmarks.

    tools/campath.py <map.bsp> <outdir> [--points N] [--dump]

The benchmark used to render ONE fixed viewpoint, so every second did the
same work and peak, low and mean were all the same number -- which made it
useless for spotting a change that only hurts expensive views. This walks
the level instead, so a run sweeps cheap and expensive frames the same way
on every build.

The graph is the BSP's own leaves:

  * only CONTENTS_EMPTY (-1) leaves are nodes. Water (-3), slime (-4) and
    lava (-5) are excluded deliberately -- a path that dives through lava
    measures the water warp and the palette flash, not the renderer, and
    it does not represent how the map is actually traversed. SOLID (-2)
    and SKY (-6) are not spaces at all.
  * two leaves are adjacent when their bounding boxes touch or overlap,
    within a small slack. Quake's leaves are convex cells split by
    portals, so touching boxes approximate "you can get from here to
    there" well enough for a camera that is not doing collision.
  * edge cost is the distance between leaf centres, so A* with a straight
    line heuristic is admissible and the path comes out roughly direct.

Endpoints are the two reachable leaves furthest apart, which gives a long
traverse across the level rather than a corner-to-corner straight line
through one room.

Known limit: leaves are reconstructed from their BOUNDING BOXES, and a
Quake leaf is a convex polyhedron. Where geometry is angled, two leaves
that really do share a face can have boxes that never touch, so they end
up in different components -- e1m7 keeps 419 of 512 empty leaves for that
reason. The route still crosses the level, it just does not reach every
room. Doing better means clipping the BSP tree to recover the actual leaf
volumes, which is the real portal algorithm and a much larger job.

Output is campath.bin: a count, then that many <x, y, z> as int16 in BSP
coordinates. The renderer interpolates between them at a fixed speed, so
frame count and elapsed time stay comparable across builds.
"""
import heapq
import math
import os
import struct
import sys

CONTENTS_EMPTY = -1
TOUCH_SLACK    = 1.0    # units; leaves that share a portal touch exactly
# Quake's standard player hull is 32 x 32 x 56. An opening the camera can
# fit through but a player cannot is not a route anyone takes, and a
# benchmark that flies through them is measuring views the game never
# shows. These are hull-0 leaves, so the check is approximate -- the
# honest fix is to walk hull 1 (the clip hull, already expanded by the
# player box), which is what pl_move traces against.
PLAYER_W       = 32.0
PLAYER_H       = 56.0

# Only EMPTY is walkable for this purpose. Everything else is excluded on
# purpose, and named here so a map that is mostly lava says so out loud
# rather than silently producing a two-waypoint path.
CONTENTS = {
    -1: 'empty',
    -2: 'solid',
    -3: 'water',        # excluded: warps the view and tints the palette
    -4: 'slime',        # excluded: same, plus it is not a route anyone takes
    -5: 'lava',         # excluded: same
    -6: 'sky',
}


def read_lumps(d):
    return [struct.unpack_from('<ii', d, 4 + 8*i) for i in range(15)]


GRID      = 32.0    # sample spacing; the player is 32 wide
CLEAR     = 12.0    # margin required around a standing spot, see below
Z_STEP    = 8.0     # vertical scan resolution when hunting for floors
STEP_UP   = 18.0    # Quake's step height: taller than this needs a jump
FALL_MAX  = 96.0    # a drop the walk will accept without calling it a cliff


def standing_spots(planes, clip, root, mins, maxs):
    """Places the player could stand: hull-1 empty with solid just below.

    Scanning columns rather than enumerating leaves, because hull 1 has no
    leaf list -- it is a tree whose children ARE contents. A column gives
    every floor in it, so multi-storey rooms come out as separate spots at
    the same (x, y), which is what a stacked map needs.
    """
    spots = []
    x = mins[0] + GRID * 0.5
    while x < maxs[0]:
        y = mins[1] + GRID * 0.5
        while y < maxs[1]:
            z = mins[2] + Z_STEP
            was_solid = True
            while z < maxs[2]:
                soli = hull1_contents(planes, clip, root, (x, y, z)) != CONTENTS_EMPTY
                if was_solid and not soli:
                    spots.append((x, y, z))     # first empty above solid
                was_solid = soli
                z += Z_STEP
            y += GRID
        x += GRID
    return spots


def has_clearance(planes, clip, root, p, m=CLEAR):
    """Is there room to MANOEUVRE here, not merely room to exist?

    Hull 1 is already expanded by the player box, so "empty" means the
    player fits exactly -- with nothing to spare. A gap one unit wider
    than the hull passes that test and yields a legal standing spot, but
    walking it means threading a needle: Quake's slide-move bounces off
    one side into the other and the walk wedges. That is what getting
    stuck between two crates looks like.

    Requiring margin on both horizontal axes routes around such gaps
    instead of through them.
    """
    for dx, dy in ((m, 0), (-m, 0), (0, m), (0, -m)):
        if hull1_contents(planes, clip, root,
                          (p[0] + dx, p[1] + dy, p[2])) != CONTENTS_EMPTY:
            return False
    return True


def build_walk_graph(planes, clip, root, spots):
    """Edges between spots the player can actually walk between."""
    by_cell = {}
    for i, (x, y, z) in enumerate(spots):
        by_cell.setdefault((int(x // GRID), int(y // GRID)), []).append(i)

    adj = {i: [] for i in range(len(spots))}
    for i, (x, y, z) in enumerate(spots):
        cx, cy = int(x // GRID), int(y // GRID)
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                if dx == 0 and dy == 0:
                    continue
                for j in by_cell.get((cx + dx, cy + dy), ()):
                    if j <= i:
                        continue
                    a, b = spots[i], spots[j]
                    dz = b[2] - a[2]
                    if dz > STEP_UP or dz < -FALL_MAX:
                        continue                # needs a jump, or is a cliff
                    if not hull1_clear(planes, clip, root, a, b):
                        continue                # something solid in the way
                    w = dist(a, b)
                    adj[i].append((j, w))
                    adj[j].append((i, w))
    return adj


def load_leaves(d):
    """(contents, mins, maxs) per leaf, in BSP order."""
    o, n = read_lumps(d)[10]
    raw  = d[o:o+n]
    out  = []
    for k in range(0, len(raw), 28):
        cont = struct.unpack_from('<i', raw, k)[0]
        box  = struct.unpack_from('<6h', raw, k+8)
        out.append((cont, box[0:3], box[3:6]))
    return out


def portal(a, b, slack=TOUCH_SLACK):
    """Approximate the portal between two leaves, or None if there is none.

    Quake does not ship portals in the .bsp -- they are a compile-time
    artifact that lives in the .prt file -- so they are reconstructed here
    from the leaf volumes. Two leaves share a portal when their boxes meet
    on ONE axis and genuinely overlap on the other two.

    The overlap test is what makes this a portal rather than mere contact.
    Boxes that touch along an edge, or clip a corner, overlap on only one
    axis and are not a way through: joining them invents routes that pass
    through solid geometry. Requiring a real opening on both remaining
    axes -- and one wide enough to matter -- is the difference between a
    graph of rooms and a graph of coincidences.
    """
    (_, amin, amax), (_, bmin, bmax) = a, b

    meet = -1
    for i in range(3):
        if amin[i] - slack > bmax[i] or bmin[i] - slack > amax[i]:
            return None                     # separated: no contact at all
        # do they merely abut on this axis, rather than overlap through it?
        if abs(amax[i] - bmin[i]) <= slack or abs(bmax[i] - amin[i]) <= slack:
            if meet >= 0:
                return None                 # abutting on two axes = an edge
            meet = i
    if meet < 0:
        return None                         # fully overlapping, not a portal

    # The opening, on the two axes that are not the contact normal. Width
    # is checked against the player's box, height against its height --
    # z is up in BSP coordinates.
    for i in range(3):
        if i == meet:
            continue
        lo = max(amin[i], bmin[i])
        hi = min(amax[i], bmax[i])
        need = PLAYER_H if i == 2 else PLAYER_W
        if hi - lo < need:
            return None                     # a player would not fit
    return meet


def touching(a, b, slack=TOUCH_SLACK):
    return portal(a, b, slack) is not None


def load_hull1(d):
    """The player clip hull: planes + clipnodes, and its root.

    Hull 1 is the BSP already expanded by the 32x32x56 player box, and it
    is what pl_move traces against. Its empty space is exactly the set of
    positions a player's ORIGIN can occupy -- so a route through it is
    walkable by construction, with no approximating of the hull from
    render leaves and no asking the player to fit through a gap it cannot.
    """
    o, n = read_lumps(d)[1]
    raw = d[o:o+n]
    planes = [struct.unpack_from('<4f i', raw, k)[:4]
              for k in range(0, len(raw), 20)]
    o, n = read_lumps(d)[9]
    raw = d[o:o+n]
    clip = [struct.unpack_from('<i2h', raw, k) for k in range(0, len(raw), 8)]
    o, n = read_lumps(d)[14]
    head = struct.unpack_from('<3f3f3f4i i', d, o)
    return planes, clip, head[10], head[0:3], head[3:6]      # headnode[1]


def hull1_contents(planes, clip, root, p):
    """CONTENTS_* at p in the player hull. Children < 0 ARE the contents."""
    n = root
    while n >= 0:
        planenum, c0, c1 = clip[n]
        nx, ny, nz, dist = planes[planenum]
        n = c0 if (p[0]*nx + p[1]*ny + p[2]*nz) - dist >= 0 else c1
    return n


def hull1_clear(planes, clip, root, a, b, step=8.0):
    d = dist(a, b)
    k = max(2, int(d / step) + 1)
    for i in range(k + 1):
        t = i / float(k)
        q = tuple(a[j] + (b[j] - a[j]) * t for j in range(3))
        if hull1_contents(planes, clip, root, q) != CONTENTS_EMPTY:
            return False
    return True


def load_tree(d):
    """planes and nodes, for an exact point query."""
    o, n = read_lumps(d)[1]
    raw = d[o:o+n]
    planes = [struct.unpack_from('<4f i', raw, k)[:4]
              for k in range(0, len(raw), 20)]
    o, n = read_lumps(d)[5]
    raw = d[o:o+n]
    nodes = [struct.unpack_from('<i2h', raw, k) for k in range(0, len(raw), 24)]
    return planes, nodes


def point_contents(planes, nodes, leaves, p):
    """Contents of the leaf containing p, by descending the BSP.

    This is the EXACT test. Leaf bounding boxes are not: a Quake leaf is a
    convex polyhedron and its box is a loose cover, so a point can sit
    inside the box of an empty leaf while actually being in solid. Checking
    boxes said this path was clear; it flew through walls anyway.
    """
    n = 0
    while n >= 0:
        planenum, c0, c1 = nodes[n]
        nx, ny, nz, dist = planes[planenum]
        side = (p[0]*nx + p[1]*ny + p[2]*nz) - dist
        n = c0 if side >= 0 else c1
    leaf = -(n + 1)
    if leaf < 0 or leaf >= len(leaves):
        return -2
    return leaves[leaf][0]


def segment_clear(planes, nodes, leaves, a, b, step=8.0):
    """Is every point along a->b in EMPTY space?"""
    d = dist(a, b)
    n = max(2, int(d / step) + 1)
    for i in range(n + 1):
        t = i / float(n)
        q = tuple(a[k] + (b[k] - a[k]) * t for k in range(3))
        if point_contents(planes, nodes, leaves, q) != CONTENTS_EMPTY:
            return False
    return True


def centre(leaf):
    _, lo, hi = leaf
    return tuple((lo[i] + hi[i]) / 2.0 for i in range(3))


def portal_centre(a, b, slack=TOUCH_SLACK):
    """Middle of the opening between two leaves.

    Routing straight from one leaf centre to the next cuts corners: the
    segment between two centres is not guaranteed to lie inside either
    leaf, so the camera clips through whatever solid sits between them.
    Going centre -> portal -> centre keeps each segment within the two
    cells that actually share that opening, which is what the portal is.
    """
    meet = portal(a, b, slack)
    if meet is None:
        return None
    (_, amin, amax), (_, bmin, bmax) = a, b
    out = []
    for i in range(3):
        if i == meet:
            # the shared face: where the two boxes meet on this axis
            out.append((max(amin[i], bmin[i]) + min(amax[i], bmax[i])) / 2.0)
        else:
            lo = max(amin[i], bmin[i])
            hi = min(amax[i], bmax[i])
            out.append((lo + hi) / 2.0)
    return tuple(out)


def dist(p, q):
    return math.sqrt(sum((p[i] - q[i]) ** 2 for i in range(3)))


def build_graph(leaves):
    """Adjacency over the EMPTY leaves only."""
    idx = [i for i, l in enumerate(leaves) if l[0] == CONTENTS_EMPTY]
    adj = {i: [] for i in idx}
    for a in range(len(idx)):
        for b in range(a + 1, len(idx)):
            i, j = idx[a], idx[b]
            if touching(leaves[i], leaves[j]):
                w = dist(centre(leaves[i]), centre(leaves[j]))
                adj[i].append((j, w))
                adj[j].append((i, w))
    return idx, adj


def astar(adj, cen, src, dst):
    open_q = [(dist(cen[src], cen[dst]), 0.0, src)]
    came, best = {}, {src: 0.0}
    while open_q:
        _, g, cur = heapq.heappop(open_q)
        if cur == dst:
            path = [cur]
            while cur in came:
                cur = came[cur]
                path.append(cur)
            return path[::-1]
        if g > best.get(cur, float('inf')):
            continue
        for nxt, w in adj[cur]:
            ng = g + w
            if ng < best.get(nxt, float('inf')):
                best[nxt], came[nxt] = ng, cur
                heapq.heappush(open_q, (ng + dist(cen[nxt], cen[dst]), ng, nxt))
    return None


def far_pair(idx, adj, cen):
    """Two connected leaves far apart: BFS from the extreme, then again."""
    def reachable(start):
        seen, stack = {start}, [start]
        while stack:
            c = stack.pop()
            for n, _ in adj[c]:
                if n not in seen:
                    seen.add(n)
                    stack.append(n)
        return seen

    # biggest connected component, so the endpoints are actually joined
    unvisited, best_comp = set(idx), set()
    while unvisited:
        comp = reachable(next(iter(unvisited)))
        unvisited -= comp
        if len(comp) > len(best_comp):
            best_comp = comp
    comp = sorted(best_comp)
    if len(comp) < 2:
        return None, None, comp
    # furthest pair by straight line within the component (n is small)
    a, b, far = comp[0], comp[1], -1.0
    for i in range(len(comp)):
        for j in range(i + 1, len(comp)):
            dd = dist(cen[comp[i]], cen[comp[j]])
            if dd > far:
                far, a, b = dd, comp[i], comp[j]
    return a, b, comp


def chaikin(pts, iterations=2):
    """Corner-cutting subdivision: each iteration replaces every segment
    with two points at 1/4 and 3/4 along it.

    The A* route is a 32-unit grid walk, so it staircases round corners.
    Smoothing the TARGETS makes the steering turn instead of zig-zag --
    but only the targets: the player is still moved by pl_move, so a
    smoothed path is a suggestion, not a position.
    """
    for _ in range(iterations):
        if len(pts) < 3:
            return pts
        out = [pts[0]]
        for a, b in zip(pts, pts[1:]):
            out.append(tuple(0.75*a[k] + 0.25*b[k] for k in range(3)))
            out.append(tuple(0.25*a[k] + 0.75*b[k] for k in range(3)))
        out.append(pts[-1])
        pts = out
    return pts


def smooth_validated(planes, clip, root, pts):
    """Smooth, then keep only what the player hull still allows.

    A spline is free to bulge outside the corridor A* proved walkable --
    corner-cutting moves INTO the inside of a turn, which is exactly where
    a wall tends to be. So every smoothed point is re-tested against hull
    1, and any that fails takes the original corner back. Smoothing must
    never cost the walkability guarantee that made this path usable.
    """
    sm = chaikin(pts)
    kept, dropped = [], 0
    for q in sm:
        qi = tuple(int(round(v)) for v in q)
        if (hull1_contents(planes, clip, root, qi) == CONTENTS_EMPTY
                and has_clearance(planes, clip, root, qi)):
            if not kept or hull1_clear(planes, clip, root, kept[-1], qi):
                kept.append(qi)
                continue
        dropped += 1
    # never return something worse than we started with
    if len(kept) < len(pts):
        return pts, dropped, False
    return kept, dropped, True


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    bsp, outdir = sys.argv[1], sys.argv[2]
    dump = '--dump' in sys.argv

    d = open(bsp, 'rb').read()
    planes, clip, root, mins, maxs = load_hull1(d)
    leaves = load_leaves(d)

    counts = {}
    for c, _, _ in leaves:
        counts[c] = counts.get(c, 0) + 1
    print(f"  render leaves: {counts.get(CONTENTS_EMPTY,0)} empty "
          f"(the path does NOT use these; hull 1 does)")

    spots = standing_spots(planes, clip, root, mins, maxs)
    # only where a player may stand AND not in liquid: water, slime and
    # lava are excluded because a route through them times the warp and
    # the palette flash rather than the renderer
    pl_tree = load_tree(d)
    spots = [p for p in spots
             if point_contents(*pl_tree, leaves, p) == CONTENTS_EMPTY]
    print(f"  {len(spots)} standing spots (hull 1 empty, floor below, not liquid)")

    roomy = [p for p in spots if has_clearance(planes, clip, root, p)]
    print(f"  {len(roomy)} with {CLEAR:.0f} units of clearance "
          f"({len(spots)-len(roomy)} too tight to manoeuvre in)")
    spots = roomy

    adj = build_walk_graph(planes, clip, root, spots)
    cen = {i: spots[i] for i in range(len(spots))}
    src, dst, comp = far_pair(list(range(len(spots))), adj, cen)
    if src is None:
        raise SystemExit("no connected standing spots")
    print(f"  largest walkable component {len(comp)}")

    path = astar(adj, cen, src, dst)
    if not path:
        raise SystemExit("A* found no walkable route")

    pts = [tuple(int(round(v)) for v in cen[n]) for n in path]
    total = sum(dist(cen[path[i]], cen[path[i+1]]) for i in range(len(path)-1))
    print(f"  path {len(pts)} waypoints, {total:.0f} units walked, "
          f"{dist(cen[src], cen[dst]):.0f} apart")

    # every waypoint must be somewhere the player hull fits
    bad = sum(1 for p in pts
              if hull1_contents(planes, clip, root, p) != CONTENTS_EMPTY)
    print(f"  waypoints outside the player hull: {bad}")
    if bad:
        raise SystemExit("refusing to emit a path the player cannot stand on")

    pts, dropped, used = smooth_validated(planes, clip, root, pts)
    if used:
        print(f"  smoothed to {len(pts)} waypoints "
              f"({dropped} smoothed points rejected by the hull)")
    else:
        print(f"  smoothing rejected -- keeping the {len(pts)} A* waypoints "
              f"({dropped} smoothed points were unwalkable)")

    bad = sum(1 for p in pts
              if hull1_contents(planes, clip, root, p) != CONTENTS_EMPTY)
    if bad:
        raise SystemExit(f"{bad} waypoints outside the player hull after smoothing")

    if dump:
        for p in pts:
            print("   ", p)

    os.makedirs(outdir, exist_ok=True)
    blob = struct.pack('<h', len(pts))
    for x, y, z in pts:
        blob += struct.pack('<3h', x, y, z)
    open(os.path.join(outdir, 'campath.bin'), 'wb').write(blob)
    print(f"  campath.bin  {len(blob):,} bytes")


if __name__ == '__main__':
    main()
