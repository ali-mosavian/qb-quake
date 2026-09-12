#ifndef __ASSETS_H__
#define __ASSETS_H__

/* dos.bi's own Const F4READ = 1 -- not in the real C headers, which
   carry function signatures, not BASIC-side constants. Shared here
   since more than one loader now opens a UAR member directly (mod.c's
   own EMS-store loads don't go through asset_load, which is whole-
   file-into-one-far-block only). */
#define F4READ 1

/*
 * assets.h -- one shared shape behind most of model.bas's/r_bsp.bas's/
 * pl_move.bas's/ent.bas's loaders: open one member of assets.zip (a UAR
 * archive, mkassets.py's own output), qglMemAlloc a far block, read the
 * member into it whole. That covers every "MEM store" and "mod_load_flat"
 * site in the original -- the EMS-fallback half of the MEM/EMS choice
 * those sites offered is NOT here: cport/'s existing node/leaf/clip
 * walkers (r_walk.c, pl_trace.c) already assume a plain, fully-addressable
 * far array, never a windowed one, so there is no fallback that would
 * preserve their own access pattern. A load that can't get a contiguous
 * block is a hard failure here, not a slower path.
 */

/*
 * name: asset_load
 * desc: qglMemAlloc(bytes), then read exactly that many bytes of flname
 *       (an assets.zip member, "archive::member") into it. Fatal (writes
 *       to stderr and exits) on a missing member, a short read, or a
 *       failed allocation -- matching sys_error's old role, since
 *       sys.bas's own error path isn't ported and nothing here can run
 *       without its map data anyway.
 */
unsigned char far *asset_load( char *flname, long bytes );

/* Same, but bytes comes from the member's own size (uarSize) rather
   than a size the caller already knows -- the visibility lump's own
   loading shape, where nothing sizes it ahead of time. */
unsigned char far *asset_load_whole( char *flname, long *out_bytes );

#endif
