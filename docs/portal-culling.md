# Portal culling

Narrows the PVS to what the eye can actually see, not merely what its
leaf could see from somewhere. Two halves: `tools/mkportals.py` rebuilds
the portals a compiled BSP no longer carries, and `src/r_portal.c` floods
through them every frame to shrink the PVS down to the current view.

Status: correct, measured, and currently a net loss on this renderer's
main benchmark. See **Measured** at the end before building on this.

## The problem

The PVS lump answers "what can be seen from anywhere in leaf L, looking
any direction". It is baked once, offline, per leaf — not per eye
position, not per view direction. Standing still and turning around
never changes it, which is exactly why `r_mark_leaves` can cache it
until the camera crosses a leaf boundary.

That is also its blind spot. A leaf with two doorways keeps both rooms
in its PVS, whichever way you are actually looking:

```
                      YOU ARE HERE, facing north
                              |
                              v
        +-------------+      |      +-------------+
        |   Room A    |    (door)   |   Room C     |
        |  (PVS: yes) |------+------|  (PVS: yes)  |
        +-------------+      |      +-------------+
                        +-----+-----+
                        | current   |
                        |   leaf    |----(door)----+-------------+
                        +-----+-----+              |   Room B    |
                              |                     |  (PVS: yes) |
                              v                     +-------------+
                         (behind you)
```

Room B is behind you, through a door you are not looking through. The
PVS still includes it — correctly, since it answers "from anywhere in
this leaf", and someone standing at the B doorway looking through it
absolutely can see B. But *you*, right now, cannot, and every face in
those leaves your camera keeps anyway pays a full geometry fetch,
projection, cache lookup and rasterisation for nothing.

Portal culling asks the narrower, correct-for-this-frame question:
starting at the eye, what can actually be reached by a straight line
through a chain of openings, given where the eye is and which way it is
looking?

## Part 1 — rebuilding what qbsp threw away

Quake's own toolchain computes portals and then discards them. `qbsp`
writes a `.prt` file — one winding per pair of adjacent leaves — and
`vis` consumes it to produce the PVS lump that actually ships. Nobody
ships the `.prt`. The PVS in a compiled BSP is the compressed residue of
a computation whose inputs are gone.

`tools/mkportals.py` reconstructs them from the tree alone, offline, no
timing pressure:

```
for every node in the BSP tree:

    1. Take the node's own splitting plane as an infinite square.

    2. Clip that square down to the region THIS node actually owns,
       by clipping it against every ancestor plane on the side this
       node is on:

              ancestor A (front)         ancestor A
             ----------------->         ______________
                                        |              |
                    node's             |   node's      |
                    plane   ---->      |   plane,      |
                  (infinite)           |   clipped     |
                                       |   to A's       |
                                        \   front side  |
                                         \______________|

       Repeat for every ancestor plane on the path from the root.
       What survives is exactly the slice of that plane bounding
       this node's own two children.

    3. Drop that clipped piece down the FRONT child, splitting it
       further at every plane it straddles, and record which LEAF
       each surviving fragment ends up facing.

    4. Drop each of THOSE fragments down the BACK child the same way.

    5. A fragment that reaches a leaf on both sides is a portal
       between those two leaves.
```

A portal is therefore always planar (it lies exactly on some node's
splitting plane) and its winding is whatever survived four rounds of
half-space clipping — usually a quad, sometimes more.

### The check that makes this trustworthy

There is exactly one property a correct set of portals must have: `vis`
only ever marks a leaf reachable through *some chain of portals*, so
**every leaf's real PVS must be a subset of what a flood-fill through
these portals can reach**. A generator that drops, invents, or misplaces
a portal fails this immediately — it is not a heuristic check, it is the
definition vis itself relies on.

```
    PVS(leaf) subset-of  portal-flood-reachable(leaf)

    for EVERY leaf, or the portals are wrong.
```

`mkportals.py` runs this on every leaf before it will write anything,
and refuses to emit the lump if it fails:

```
$ python3 tools/mkportals.py data/dm3ish.bsp
data/dm3ish.bsp: 810 nodes, 336 leaves (313 in the world)
portals built: 4111
PVS-subset check: 313/313 leaves pass

$ python3 tools/mkportals.py data/e1m7.bsp
data/e1m7.bsp: 874 nodes, 532 leaves (281 in the world)
portals built: 3078
PVS-subset check: 281/281 leaves pass
```

Two real bugs were found and fixed by this check, and two more
suspected bugs were disproved by it — the numbers not moving after a
"fix" is as informative as them moving. The one that took the longest to
find was in the check, not the generator: the PVS row is sized by the
world model's `visleafs` field, not by the map's total leaf count.
Submodels (brush entities like doors and lifts) get their own leaves,
appended *after* the world's, and they carry no visibility data at all.
Sizing the row by every leaf reads a few bits of whatever data happens
to follow and calls it visibility.

### What gets shipped

Windings are exact but variable-length and expensive to clip at runtime
in real mode. Measured instead: flooding through a portal's plain
**world-space bounding box**, at eight independent viewpoints on
dm3ish, marks exactly the same set of leaves as flooding through the
full winding — a BSP portal is planar and close enough to rectangular
that the two give the same screen rectangle. So the lump carries boxes,
not polygons: 14 bytes a portal, no clipper needed at runtime at all.

Two files, both written into `assets.zip` by `tools/mkassets.py`:

```
portalidx.bld   short[visleafs + 1]
                one entry per leaf, prefix-summed: leaf L's own portal
                references are refs[idx[L] .. idx[L+1]).
                idx[visleafs] doubles as the total ref count -- the one
                number that is NOT in the compiled bsp and has to be
                derived this way.

portalref.bld   struct { short neighbour;
                          short min_x, min_y, min_z;
                          short max_x, max_y, max_z; } [nrefs]
                7 shorts (14 bytes) per portal reference, BSP space
                (Z-up), one entry per DIRECTION -- a portal between
                leaves A and B appears once under A's range and once
                under B's.
```

dm3ish: 4,111 portals -> 1,566 references between non-solid leaves ->
22,598 bytes. e1m7: 20,842 bytes.

## Part 2 — narrowing the PVS every frame

`src/r_portal.c` floods outward from the camera's leaf, carrying a
screen-space rectangle that only ever shrinks as it passes through
portals:

```
   screen at the eye leaf:               after passing through
   the full render target                portal P1's projected box:

   +-----------------------+              +-----------------------+
   |                       |              |                       |
   |                       |              |      +--------+       |
   |     (whole screen     |   ---P1--->  |      | rect  ' |       |
   |      is 'visible')    |              |      | clipped |      |
   |                       |              |      | to P1's |      |
   |                       |              |      | box     |       |
   +-----------------------+              +------+---------+------+

   the leaf on the far side of P1 is only as visible as THIS
   rectangle -- and every portal reachable from there is tested
   and clipped against IT, not against the full screen again.
```

This is the same idea as a shrinking frustum, done in screen space
instead of world space because a screen rectangle is four numbers and
an intersection is four comparisons, where a world-space frustum needs
a real polygon clipper. A leaf is visible from the eye only if some
chain of portals leaves a non-empty rectangle by the time it gets there:

```
   eye leaf --P1--> leaf B --P2--> leaf C --P3--> leaf D
             (big)         (narrower)     (rect empty: D not reached)

   eye leaf --P4--> leaf E   (rect survives: E IS reached)
```

### Where it plugs in

`r_draw_world` calls the flood right after `r_mark_leaves` computes the
PVS for the current leaf, and writes the result to a *separate* array,
`pvs_now`, rather than editing the PVS bit array in place:

```
   pvs_buffer_b()   -- the PVS. Rebuilt only when the camera crosses
                        into a new leaf; a stale copy is fine because
                        the answer does not depend on view direction.

   r_portal_mark()  -- reads pvs_buffer_b(), writes pvs_now(). Runs
                        EVERY frame: unlike the PVS, the answer moves
                        the instant you turn your head, so there is no
                        leaf-crossing to cache it on.

   pvs_now()        -- what r_recursive_world_node actually walks.
```

A bit is set in `pvs_now` only if it was set in the PVS **and** the
flood reached that leaf — the flood can only ever remove leaves the PVS
already had, never add one. A bug here therefore shows up as geometry
disappearing, not as something more dangerous like a leak through a
wall.

Two things the projection has to get right, both because this renderer
already has documented traps for them:

- **The coordinate swap.** Portal boxes are stored in BSP space (Z-up);
  the projection matrix wants the renderer's Y-up. Handled with the
  same swap `d_faces.c` uses building a face's own vertices.
- **A box straddling the near plane projects to something unbounded.**
  One corner just behind the eye sends the projected rectangle to
  infinity in that direction. The honest answer there is "the whole
  screen, conservatively" — it costs cull rate on that one portal, never
  correctness, and it is exactly why this code carries no near-plane
  clipper at all.

### Failure mode is always safe

If the flood runs past its per-frame work budget (a pathological view
with an enormous number of tiny portals) it aborts and `pvs_now` is
copied straight from the PVS, unmodified — today's behaviour, always
correct, just without the narrowing for that one frame.

## Debug visualization

`P` toggles the flood on and off live; `O` toggles drawing the portals
the flood actually passed through as wireframe boxes over the scene
(`-ptwire` on the command line starts it on, since key injection is not
reliable enough to trust when verifying headlessly). Only *traversed*
portals are drawn — every leaf that survives has many portals on it,
most facing away from you or behind you, and drawing all of them buries
the few that explain what you are looking through.

## Measured

Offline, before any runtime code existed, simulating the exact flood
against real dm3ish geometry at eight independent viewpoints:

| | PVS + frustum | portal-narrowed |
|---|---|---|
| faces (summed over 8 viewpoints) | 1,362 | 761 (-44%) |

At runtime, the same eight pinned viewpoints, `-ticks`-locked so the
comparison is a still frame: **byte-identical** output with portals on
vs. `-noportal`, and:

| | PVS + frustum | portal-narrowed |
|---|---|---|
| polys (summed over 8 viewpoints) | 781 | 579 (-26%) |
| worst single viewpoint | 292 | 131 |

But the campath — the actual benchmark this repo times everything
against — tells a different story. Six runs per arm, interleaved,
medians:

| | `-noportal` | portals on |
|---|---|---|
| ft_mean | 37.36 ms | 41.39 ms (**+4.03 ms**) |
| pt_cull (the flood itself) | 3.29 ms | 6.87 ms (**+3.58 ms**) |
| pt_draw | 28.59 ms | 28.71 ms (+0.12 ms, noise) |

The flood costs 3.58 ms a frame and `pt_draw` does not move — on the
campath it is removing almost nothing. The pinned viewpoints were
chosen specifically to show long sightlines the PVS keeps and the
player cannot see into, which is exactly the case portal culling wins
on; the campath spends most of its time in corridors where the
frustum's own node-bbox test has already done that job. Picking
viewpoints to make an effect visible, and then trusting them as
representative, is the same mistake the coverage-buffer measurement
made earlier in this branch's history — see `alim/occlusion-culling-methods-5c2d3d`.

The generator and the runtime are both correct and both committed. Cost
is currently in the wrong place: the flood pays every frame for a
narrowing that only pays off in specific geometry, and it has not yet
been measured whether a cheaper flood (fewer rectangles kept per leaf,
an early-out once nothing more can shrink) changes that balance.
