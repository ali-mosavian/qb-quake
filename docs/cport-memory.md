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

**What does not fit is the surface cache.** `sc_init` wants
`face_count` x 8 bytes of `CacheSlot` plus five 1,024-entry block
tables -- 54,368 on e1m1 -- on top of that 385 K, and does not get it.
That is the `sc_init FAILED` in cstep.txt and the whole reason e1m1
renders unlit while dm3ish is lit.

These totals are the container's member sizes plus the allocation
sites, NOT a read-back of DOS free memory: cport has no equivalent of
the BASIC build's memtrace, so nothing here says how far short e1m1
actually is. A `qglMemAvail` mark per load step would.
