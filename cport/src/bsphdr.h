#ifndef __BSPHDR_H__
#define __BSPHDR_H__

/*
 * bsphdr.h -- the raw .bsp file's own layout. NOTHING HERE IS READ FROM
 * A .bsp any more: cport opens the map container and never the map, so
 * the lump directory and the DISK*_SIZE divisors are what mkassets.py
 * used to derive counts.bin, kept here as the statement of the format
 * those numbers came from. cport/tools/test-records.sh is what checks
 * them against a real .bsp.
 *
 * DiskMipTex is the one record still read at run time, and it arrives
 * as the container's miptex.bin: its per-texture NAMES are what encode
 * animation chains and liquids ("+0wall", "*water"), which the atlas
 * has no reason to carry as text.
 */
typedef struct {
    long offs;
    long size;
} LumpEntry;

typedef struct {
    long      version;
    LumpEntry entities;
    LumpEntry planes;
    LumpEntry mip_tex;
    LumpEntry vertices;
    LumpEntry vis_list;
    LumpEntry nodes;
    LumpEntry tex_info;
    LumpEntry faces;
    LumpEntry lightmaps;
    LumpEntry clip_node;
    LumpEntry leaves;
    LumpEntry lface;
    LumpEntry edges;
    LumpEntry ledges;
    LumpEntry models;
} BspHeader;

/* On-disk record sizes, bspfile.bi's own Disk* types -- used only as
   divisors to turn a lump's byte size into a count. Not represented
   as C structs here since nothing ever reads a field out of one; the
   size alone is everything mod_open needs. */
#define DISKVERTEX_SIZE   12  /* 3 singles */
#define DISKFACE_SIZE     20  /* plane_id+side+ledge_id+ledge_num+tex_info_id+flag1+flag2+lightmap */
#define DISKLEAF_SIZE     28  /* cont+vis_list+bound(12)+lface_id+lface_num+stuff(4) */
#define DISKPLANE_SIZE    20  /* norm(12)+dist+ptype */
#define DISKNODE_SIZE     24  /* plane_id(long)+child0+child1+bound(12)+lface_id+lface_num */
#define DISKTEXINFO_SIZE  40  /* vecs(16)+vect(16)+mip_tex+flags */
#define DISKCLIPNODE_SIZE  8  /* plane_num(long)+front+back */
#define DISKEDGE_SIZE      4  /* 2 shorts */
#define DISKLEDGE_SIZE     4  /* 1 long */
#define DISKSUBMODEL_SIZE 64  /* box(24)+origin(12)+4 hulls+vis_leafs+first_face+num_faces */

/* bspfile.bi's DiskMipTex -- the one on-disk record mod_tex.c actually
   reads fields out of (see this file's own header). Quake's own
   miptex_t: a 16-byte name, then width/height, then four mip-level
   byte offsets this project never uses (the pixels come from
   assets.zip's own atlas, not these). 40 bytes on disk. */
typedef struct {
    char name[16];
    long wdth, hght;
    long offset[4];
} DiskMipTex;

#endif
