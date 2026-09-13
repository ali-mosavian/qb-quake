# Where a map lives

cport's memory: which of a map's lumps sit in conventional memory,
which go to EMS, and why. Figures are e1m1's, from the container's own
members.

One rule: **anything indexed as a flat array is conventional; anything
read as a stream or a rectangle is EMS.** `r_walk.c` and `pl_trace.c`
subscript nodes, leaves, clipnodes and the PVS through far pointers, and
an EMS store hands out one 16K page at a time -- tried, hung in
`pl_hull_contents`, reverted. Everything else goes through a window.

e1m1, bytes, from the container's own members:

    CONVENTIONAL  qglMemAlloc: DOS memory + the UMB pool qglMemInit links
    +---------------------------------------------------------------+
    | portalref.bld  92,736 |################################        |
    | faces.pag      55,160 |###################                     |
    | nodes.pag      44,000 |###############                         |
    | pvs.bin        40,843 |##############                          |
    | clip.pag       32,448 |###########                             |
    | planes.bld     28,960 |##########                              |
    | leaves.pag     24,496 |########                                |
    | texinf.bld     16,626 |#####                                   |
    | lface.bld      14,146 |#####                                   |
    | walk scratch  ~26,300 |#########  pflag, ord, parents, bitmaps |
    | idx/models/ofs  7,352 |##                                      |
    +---------------------------------------------------------------+
                   ~385 K            dm3ish is ~95 K of the same things

    EMS           qglSfNew(QGL_SURF_EMS) / qglGemAlloc, 16K windows
    +---------------------------------------------------------------+
    | snd.bsc       698,022 | texs.raw  573,440 | texr.raw  573,440  |
    | fgeom.bin     262,144 | lm.bin    237,568 | colmap.bin 16,384  |
    +---------------------------------------------------------------+
                    ~2.4 MB, plus the surface cache's 16384 x 256 store

**The vertex data is never resident.** `mod_load_facevtx` streams
fgeom.bin into an EMS surface a row at a time with no conventional
staging buffer, and the draw fetches one record per face:

    d_faces.c          mod_geom_map(row)        EMS page frame
    per face  ------>  qglSfAccessRdEx  ------>  E000:0000  +--------+
       |                  (maps row)                        | 16384  |
       +-- geom_row, geom_ofs from the Face record          | bytes  |
       +-- _fmemcpy the record out  <-----------------------+--------+

A quarter megabyte of geometry on a machine with none to spare, at the
cost of a window map and a copy per face. `geom_row`/`geom_ofs` are in
the 10-byte `Face`, so nothing has to be searched for.

## What the surface cache was short of

`sc_init` used to fail on e1m1 and nothing said why. Measured, it dies
on its FIRST allocation:

    sc_init FAILED step=1 want=44128 largest=13456 total=15616

44,128 bytes of `CacheSlot` against 15,616 free -- 28 KB short, not a
near miss, and `largest` within 2 KB of `total`, so a flat shortage
rather than fragmentation.

**The 95,800 bytes were the portal table, backing a pass that did
nothing.** `r_portal_mark` refuses a map past its own static tables on
its first line, and e1m1 is past both -- 1,531 leaves against
`PT_MAX_LEAVES` 1024, 6,624 refs against `PT_MAX_REFS` 4096. It
returned -2 every frame for the life of the run: `pt_pops 0`,
`pt_projs 0`, with the flood switched ON. `r_load_portals` loaded the
table regardless, and `-noportal` did not stop it either, since
`rdr.portal` was set 190 lines after the map was read.

The BASIC build never had this. Its `r_load_portals` bailed because
6,624 x 7 x 2 is past a BASIC array's 64 K; the port's far pointers
removed the accident that had been protecting it, and the surface
cache paid.

`r_load_portals` now applies the flood's own limits -- shared from
`r_portal.h`, one fact in one place -- and loads nothing it cannot
use. e1m1 gets its cache and draws lit; dm3ish still floods 5,759
portals a frame. `tools/test-lit.sh` holds both halves.

## The four cuts the port had not picked up

The BASIC build's per-face cuts were missing here, all four of them:

| | was | now | e1m1 |
|---|---|---|---|
| `CacheSlot` | 4 shorts a face | 1 -- tag, epoch and class describe the BLOCK | +33,096 |
| `face_mdl` | its own short array | the bits above `Face.side`'s one | +11,032 |
| `pflag` | a short a face, frame-stamped | one bit, `_fmemset` a frame | +10,342 |
| `SC_NBLK` | 1024 | 384 | +6,400 |

Less 1,536 for the two block arrays `CacheSlot`'s tag and epoch moved
to: **59,334 bytes on e1m1**, 65,298 on e1m4, 27,506 on dm3ish -- about
9.9 bytes a face plus a fixed 4,864. Both maps render byte-identically
either way.

After them e1m1 reports 117,168 and 120,416 bytes free on two runs of
one binary, where sc_init used to die wanting 44,128 of 15,616. Free
memory is not a deterministic figure here, which is why
`tools/test-lit.sh` floors its budget assertion well under the lower
reading rather than pinning it.

Every figure above except the `sc_init` line is a member size or an
allocation site, not a read-back: only that one line is DOS's own
answer, and only because sc.c prints it now. A `qglMemAvail` mark per load step would.
