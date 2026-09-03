# cport: portal culling removes visible geometry

**Symptom**: with portals on, whole leaves vanish -- a black void mid-frame
with floor and side walls still drawn around it. Camera-dependent.

**Confirmed**, dm3ish, `-comp -lm -nostats -ticks 120`, camera static:

| | frames | polys/frame |
|---|---|---|
| `-noportal` | 76 | 153 |
| portal on | 128 | 20 |

31.7% of pixels differ between the two. Correct culling removes only what
is not visible, so the two images must be identical; 20 polys/frame at the
dm3ish spawn is roughly an eighth of what is actually in view. F5 captures
taken at one position confirm it: the frames group into two byte-identical
sets, so the camera never moved and the toggle is the only variable.

This was invisible until `r_walk.c` was fixed to read `pvs_now` instead of
`pvsb` (see AGENTS.md). The flood had been running and having its result
discarded, so the overlay's "leaves portal-cut" moved while nothing else
did.

**Ruled out** -- every input compared against the BASIC-linked build, which
is reported to render correctly with portals on:

| checked | result |
|---|---|
| flood body in `r_portal.c` | same logic; only signatures and diagnostics differ |
| `r_ptproj.asm` | byte-identical between the two trees |
| `PT_MAX_LEAVES` / `_REFS` / `_STACK` | identical, and dm3ish's 1566 refs is well under the 4096 cap |
| `r_load_portals` sizing, `pt_idx[leaf_count]` | identical |
| `visleafs` (`leaf_count - 1`) | both derive `leaf_count` from the lump size |
| `xresh`/`yresh` | 80/50 in both (`env.x_res/2`, render res not screen) |
| portal default | on in both |
| `portalref.bld` boxes | 1566 refs, 0 degenerate or inverted, extents 16..800 |
| `pvsb` itself | correct -- portals-off renders right, and it reads `pvsb` |

So the fault is confined to `reached[]`, with every comparable input equal.

**Also found while checking the data** (separate, benign): 18 of 1566 refs
name a neighbour outside that leaf's own PVS, which `mkportals.py`'s own
docstring says cannot happen. `r_portal_mark` writes `pvs_now = pvsb AND
reached`, so those edges are filtered and cannot affect the picture. The
opposite direction -- the one that would cause this bug -- is clean: for
all 313 world leaves, every leaf in the PVS is reachable through the portal
graph (19,429 entries checked, 0 unreachable). Neither check is run by
`mkassets.py`.

**Open, and the next test.** Two explanations remain and cannot be
separated by reading the source:

1. a cport-only fault somewhere outside the sources compared above;
2. the BASIC build never actually culls -- if `r_portal_mark` returns
   negative there every frame, `r_bsp.bas` falls back to the full PVS and
   the build renders correctly while doing no portal work at all.

(2) deserves weight: the same result was being discarded in cport too,
until an hour before this was written. Run the identical portal-on/off A/B
on the BASIC build. Images identical there means the flood is genuinely
correct in BASIC and the bug is cport's; images differing by a similar
margin means both builds share it and "renders fine" was never a test of
the flood.
