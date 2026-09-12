#ifndef __WORLD_H__
#define __WORLD_H__

#include "bsptypes.h"

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

    /* The message table, last in ents.bin: ENT_MSG_LEN bytes each, not
       NUL-terminated. A door's or a trigger's msg is a 1-based id into
       this, 0 for none. */
    short       msg_count;
    char        far *msgs;

    short       far *face_mdl;   /* which submodel owns each face -- the
                                     world's own faces read 0, a brush
                                     entity's own faces read its index.
                                     d_faces.c's, not read anywhere in
                                     cport/ yet (not ported), but written
                                     by ent_load_teleports regardless */

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
       whatever its pixels cost, and e1m1 would make 648 of them. Four
       VIEWS per atlas instead, one per mip size, re-aimed per face
       with qglSetView -- no allocation, no copy, the same trick the
       surface cache uses to avoid a dc per surface. */
    QSurf   tex_raw, tex_shaded;
    QSurf   tex_v_raw[4], tex_v_shaded[4];  /* a view per mip size */
    short tex_cell[4];      /* texels per side at that mip */
    short tex_aim_raw[4];    /* cell each view is already aimed at, -1
                                 none -- re-aiming rewrites a scanline
                                 table, and consecutive faces usually
                                 share a texture */
    short tex_aim_shd[4];
    long  tex_ofs[1024];    /* [id*4 + level] -> byte offset in the atlas */
} World;

#endif
