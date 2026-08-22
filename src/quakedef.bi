''
'' Cross-module state.
''
'' DIM SHARED is module scope only; COMMON SHARED is what actually crosses a
'' module boundary, and it has to be declared identically in every module and
'' before any executable statement. Only state that is genuinely shared
'' belongs here -- COMMON arrays are always descriptor addressed, so the hot
'' renderer scratch stays module-local under '$STATIC where it is addressed
'' directly.
''
common shared /qenv/ env as EnvType

''
'' The map: written by qbsplod.bas, walked by the renderer. Already '$DYNAMIC
'' before the split, so COMMON costs them nothing.
''
common shared /qmapS/ bsphead as header, loading as single, loadDC as long
common shared /qmapS/ numtex as long, triCount as long, vtxCount as long
common shared /qmapS/ edgCount as long, lefCount as long, ndsCount as long
common shared /qmapS/ texiCount as long, CamPos as u3dVector3f, startAngle as single
common shared /qmapA/ triBuffer() as face2, edgBuffer() as edge, ledgBuffer() as integer
common shared /qmapA/ vtxBuffer() as vertex, lefBuffer() as leaf2, lfcBuffer() as integer
common shared /qmapA/ mdlBuffer() as model, plnBuffer() as plane2, ndsBuffer() as nodeb
common shared /qmapA/ orderList() as integer, pvsBufferA() as integer, pvsBufferB() as integer
common shared /qmapA/ texInfBuff() as texinfo, polyFlag() as integer

''
'' Visibility and traversal: r_bsp.bas walks the tree and marks what is
'' visible; the frame loop and the rasteriser read the result.
''
common shared /qvisS/ frameStamp as integer, ordCount as long
common shared /qvisA/ bitarray() as integer, frustum() as plane

''
'' Rasteriser state the frame loop also touches: the render-mode toggles,
'' the per-frame counters, and the texture handles it samples.
''
common shared /qdrwS/ backface as integer, polys as integer, rendmode as integer, tris as integer, usemips as integer
common shared /qdrwA/ hTextrDC() as long, mipBuffInf() as miptexb

''
'' The overlay: the frame counter and the stats toggle, written by the
'' frame loop and read by screen.bas.
''
common shared /qscrS/ fps as integer, stats as integer

''
'' pal is loaded by r_tex.bas, which needs its segment and offset to colour
'' match, and consumed by videoOpen, which installs it and frees it.
''
common shared /qpalS/ pal as long

''
'' Camera and view state: r_main.bas moves the camera, the frame loop and
'' the rasteriser consume the result.
''
common shared /qcamS/ camLookAt as u3dVector3f, fpsview as integer
