#ifndef __WORLD_H__
#define __WORLD_H__

#include "bsptypes.h"

/* Cell heights are powers of two and a cell is at most one EMS page,
   so 1..16384 -- nine of them can matter and the rest cannot exist. */
#define TEX_HEIGHTS 15
#include "mdltypes.h"

/*
 * World -- the loaded map. Grows a field at a time as the module that
 * owns it gets ported; this is ent.bas's, pl_move.bas's and r_bsp.bas's
 * slice (models/nodes/planes/clip/leaves/lfc/pvs_data, plus the entity
 * arrays ent.bas owns), plus faces/texinfo/miptex -- sb_build.c (d_surf.bas)
 * needs them, even though model.bas's own loader that would fill them
 * isn't ported yet. The surface cache itself is not here: SurfCache is
 * its own context struct (sc.h), not part of the map.
 *
 * Arrays are far pointers + counts rather than fixed-size members:
 * every one of these is sized at map-load time (REDIM in the old
 * BASIC), and nothing here should guess a bound before model.bas's
 * loader exists to allocate them.
 */
typedef struct {
    short       model_count;
    Submodel    far *models;
    Node        far *nodes;
    short       node_count;      /* the WORLD hud panel's own -- nothing in
                                     the walk itself needs a bound */
    short       vert_count;      /* likewise: the hud panel's WORLD stats */
    short       edge_count;
    Plane       far *planes;
    BrushModel  far *brush;      /* one per submodel, brush[0] is the world */

    ClipNode    far *clip;       /* hull 1: pre-expanded for the player box,
                                     walked by pl_trace -- no count needed,
                                     pl_trace never indexes past a child it
                                     was handed */

    short       leaf_count;       /* r_mark_leaves' PVS decompression loop
                                      bound -- a run can carry past the
                                      last leaf, and in real mode that
                                      writes over whatever follows the
                                      array if this isn't checked */
    Leaf        far *leaves;
    short       far *lfc;        /* the marksurface list: leaf.lface_id
                                     .. +lface_num indexes into this, and
                                     each entry is a face index */
    unsigned char far *pvs_data; /* the PVS lump, run-length compressed;
                                     leaf.vis_list is a byte offset into
                                     this. A plain far pointer here, not
                                     BASIC's packed-long + DEF SEG/PEEK --
                                     see r_bsp.c's r_mark_leaves */

    short       face_count;      /* r_draw_world's frame_stamp-reset loop
                                     bound; the walk itself never needs
                                     this, only the once-per-32,767-frames
                                     reset does */
    Face        far *faces;
    TexInfo     far *texinfo;    /* indexed by faces[f].tex_info_id */
    MipTex      far *miptex;     /* indexed by texinfo[t].mip_tex */
    short       far *anim_tab;   /* every animation chain's texture ids,
                                     back to back; MipTex.anim_base is an
                                     offset into THIS, not a texture id --
                                     chains are not contiguous in the
                                     miptex lump (see mod_link_anims) */

    short       far *pt_idx;     /* portal adjacency, mkportals.py's own
                                     output: one entry per leaf plus one
                                     past the end, so leaf l's refs are
                                     pt_idx[l]..pt_idx[l+1] */
    short       far *pt_ref;     /* PT_REF_SHORTS (7) shorts per entry --
                                     neighbour leaf, then the portal's
                                     bsp-space bounding box */

    short       tele_count;
    Teleporter  far *tele;

    short       plat_count;
    short       plat_max;        /* func_trains share the plat array */
    PlatEnt     far *plat;

    short       door_count;
    DoorEnt     far *door;

    short       trig_count;
    TrigEnt     far *trig;

    short       corner_count;
    PathCorner  far *corner;

    short       item_count;
    short       item_max;        /* the map's own plus a backpack a monster */
    ItemEnt     far *item;

    short       crate_count;
    CrateModel  far *crate;

    short       mon_count;
    MdlEnt      far *mon;
    MdlState    mdl[MDL_KINDS];   /* one per kind, only the map's own loaded */

    /* The view weapons -- the player's, not the map's, and here only
       because everything that draws already reaches World. Indexed by
       PL_VIEW_*, loaded the first time the weapon is in hand: six at
       once is six EMS handles and six skins for one that is drawn. */
    MdlState    vmdl[PL_VIEW_N];

    /* The message table, last in ents.bin: ENT_MSG_LEN bytes each, not
       NUL-terminated. A door's or a trigger's msg is a 1-based id into
       this, 0 for none. */
    short       msg_count;
    char        far *msgs;

    /* Which submodel owns a face is Face.side >> 1, written by
       ent_load_teleports -- see its own note. There is no array. */

    /* The three EMS-resident stores mod.c owns and hands scanlines/rows
       out of through mod_lm_map/mod_cm_map/mod_geom_map (sb_build.c
       already calls these, with exactly this World-taking signature,
       since before mod.c existed to implement them). */
    QSurf   geom_dc;      /* one face record per lookup, through mod_geom_map */
    short geom_rows;

    QSurf   light_atlas;  /* every luxel in the map, one 8-bit EMS dc */
    long  light_size;   /* bytes on disk */
    long  light_loaded; /* bytes that actually arrived */

    QSurf   cmap_dc;       /* the 64-shade table sb_build/hud_shade shade through */
    long  cmap_size;

    /* q_map.bi's TexStore -- every texture, in two atlas dcs (raw
       indices, and row-0-shaded) instead of one dc per texture per
       mip: a dc costs conventional memory for its scanline table
       whatever its pixels cost, and e1m1 would make 648 of them. A
       handful of VIEWS per atlas instead, re-shaped per face with
       qglSfViewShape -- no allocation, no copy, the same trick the
       surface cache uses to avoid a dc per surface. */
    QSurf   tex_raw, tex_shaded;
    /* A view per HEIGHT, not per mip level: a cell keeps its texture's
       own aspect now, and a view's address table is its height's while
       qglSfViewShape can still give it any width. Made on first use --
       a map wants a handful of the nine. */
    QSurf   tex_v_raw[TEX_HEIGHTS], tex_v_shaded[TEX_HEIGHTS];
    short tex_aim_raw[TEX_HEIGHTS];  /* cell each view is already aimed
                                         at, -1 none -- re-aiming
                                         rewrites a scanline table, and
                                         consecutive faces usually share
                                         a texture */
    short tex_aim_shd[TEX_HEIGHTS];
    long  tex_ofs[1024];    /* [id*4 + level] -> byte offset in the atlas */
} World;

#endif
