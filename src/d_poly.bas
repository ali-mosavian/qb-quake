option explicit
''
'' d_poly.bas -- the polygon rasteriser.
''
'' Builds each face's texture coordinates, transforms and clips to the near
'' and far planes, projects once per vertex, and hands the fan to uGL.
'' Quake's d_ files are this same layer: r_bsp decides what is seen, this
'' draws it.
''
'' Every scratch buffer below sits AFTER '$STATIC deliberately. In the
'' '$DYNAMIC region each element costs a descriptor indirection, and these
'' are touched per vertex per frame. It is also why none of them are
'' COMMON: COMMON arrays are always descriptor addressed.
''
'$include: 'u3d.bi'
'$include: 'ugl.bi'
'$include: 'pal.bi'
'$include: 'kbd.bi'
'$include: 'tmr.bi'
'$include: 'dos.bi'
'$include: 'arch.bi'
'$include: 'uglu.bi'
'$include: 'font.bi'
'$include: 'mouse.bi'
'$include: 'bspfile.bi'
'$include: 'snd.bi'
'$include: 'mod.bi'
'$include: 'q_env.bi'
'$include: 'q_map.bi'
'$include: 'q_vis.bi'
'$include: 'q_draw.bi'
'$include: 'q_scr.bi'
'$include: 'q_cam.bi'
'$include: 'q_pl.bi'
'$include: 'q_ent.bi'
'$include: 'q_snd.bi'
'$include: 'q_game.bi'

''
'' This module's own procedures.
''
declare sub d_clip_z ( _
    ot_vtx() as u3dVector4f, _
    ot_uv() as TexCoord, _
    ot_cnt as integer, _
    in_vtx() as u3dVector4f, _
    in_uv() as TexCoord, _
    in_cnt as integer, _
    byval z_near as single, _
    byval z_far as single _
)

''
'' This module's own procedures.
''
declare sub d_init_turb ( )
''

''
'' Declared here, not in a header: this module is the only caller, and a
'' header would hand these to modules that never use them -- BC's symbol
'' table is finite, and it ran out when they all got everything.
''
declare function r_cam_plane_dist ( _
    pt as u3dVector3f, _
    pl as Plane _
) as single
declare function sc_find ( _
    byval face as integer, _
    byval mip as integer, _
    byval w as integer, _
    byval h as integer, _
    byval stag as integer _
) as long
declare function sc_mipfloor ( _
    byval extw as integer, _
    byval exth as integer _
) as integer
declare function host_z_on ( ) as integer
declare function sc_held ( byval face as integer ) as integer
declare function sc_ready ( ) as integer
declare function sc_shift ( byval v as integer ) as integer
declare function ls_epoch ( byval style as integer ) as integer
declare function sys_rdtsc ( ) as long
'' r_span.c investigative prototype: global edge list -> sorted spans,
'' Quake's r_edge.c approach, timed against real per-frame polygons.
'' Draws nothing; only caller is d_draw_faces's own timing below.
declare sub r_span_emit_poly ( _
    byval poly_cnt as integer, _
    vx() as single, _
    vy() as single, _
    vu() as single, _
    vv() as single, _
    vz() as single, _
    byval texdc as long, _
    byval texofs as long _
)
declare sub r_span_draw_to ( byval dst_dc as long )
declare function sc_view_ofs ( ) as long
declare function r_span_flush ( byval screen_w as integer, byval screen_h as integer ) as integer
declare function r_span_overflow_count ( ) as integer
declare function sc_alloc ( _
    g as Game, _
    byval face as integer, _
    byval mip as integer, _
    byval w as integer, _
    byval h as integer, _
    byval fw as integer, _
    byval fh as integer, _
    byval stag as integer _
) as long
declare sub sb_build ( _
    g as Game, _
    byval dc as long, _
    byval tex as long, _
    byval face as integer, _
    byval mip as integer, _
    byval sw as integer, _
    byval sh as integer, _
    tri_buffer() as Face, _
    tex_inf_buff() as TexInfo, _
    gv_buf() as integer, _
    mip_buff_inf() as MipTex, _
    pln_buffer() as Plane _
)

'$static
''
'' Quake's turbsin. A table because two sines per vertex of every
'' liquid face is not something to compute in the draw loop.
''
dim shared turb_sin( 255 ) as single
dim shared poly(64) as u3dVector4f
dim shared polyb(32) as u3dVector4f
''
'' gv_buf lives in COMMON (q_map.bi) so sb_build can read the lightmap
'' header from the copy instead of from the window it came from.
dim shared prj_u(32) as single
dim shared prj_v(32) as single
dim shared prj_w(32) as single
dim shared prj_x(32) as single
dim shared prj_y(32) as single
dim shared su0 as single, su1 as single, su2 as single, su3 as single
dim shared sv0 as single, sv1 as single, sv2 as single, sv3 as single
dim shared tw as single, th as single
dim shared uvbuff(64) as TexCoord
dim shared uv_buff_b(32) as TexCoord
dim shared vcnt as integer, tex_id as integer

dim shared vtx(31) as tritype
''
'' Whole-face vertex buffer for uglPolyTP. The clipper caps a polygon at
'' SH_MAXV (12); faces arriving here are already z-clipped, so 16 is
'' headroom rather than a limit worth policing.
''
dim shared pvtx(15) as vector3f
dim shared vx as single, vy as single, vz as single

'' vtx_buffer is Q13.3 fixed point (bspfile.bi's vertex2); every read
'' multiplies back up to world-space float. A multiply, not a divide --
'' cheaper on the FPU and this runs per vertex per visible face per frame.
const VTX_UNSCALE# = 1.0 / 8.0




'':::::::
sub d_clip_z ( _
    ot_vtx() as u3dVector4f, _
    ot_uv() as TexCoord, _
    ot_cnt as integer, _
    in_vtx() as u3dVector4f, _
    in_uv() as TexCoord, _
    in_cnt as integer, _
    byval z_near as single, _
    byval z_far as single _
)

    dim n as integer
    dim scl as single
    dim dsti as integer, tm_cnt as integer
    dim src1 as integer, src2 as integer

    for  n = 0 to in_cnt-1
        src1 = n
        src2 = (n + 1) mod in_cnt
        
        if ( in_vtx(src1).w >= z_near ) then
            ot_vtx(dsti).x = in_vtx(src1).x
            ot_vtx(dsti).y = in_vtx(src1).y
            ot_vtx(dsti).z = in_vtx(src1).z
            ot_vtx(dsti).w = in_vtx(src1).w
            ot_uv(dsti).u = in_uv(src1).u
            ot_uv(dsti).v = in_uv(src1).v
            
            dsti = dsti + 1 
            
            if ( in_vtx(src2).w >= z_near ) then
                goto continuenfa
            end if
        else
            if ( in_vtx(src2).w < z_near ) then
                goto continuenfa
            end if
        end if

        scl = ((z_near - in_vtx(src1).w) / (in_vtx(src2).w - in_vtx(src1).w))
     
        ot_vtx(dsti).x = in_vtx(src1).x + (in_vtx(src2).x-in_vtx(src1).x)*scl
        ot_vtx(dsti).y = in_vtx(src1).y + (in_vtx(src2).y-in_vtx(src1).y)*scl
        ot_vtx(dsti).z = in_vtx(src1).z
        ot_vtx(dsti).w = z_near        
        ot_uv(dsti).u = in_uv(src1).u + (in_uv(src2).u-in_uv(src1).u)*scl
        ot_uv(dsti).v = in_uv(src1).v + (in_uv(src2).v-in_uv(src1).v)*scl
    
        dsti = dsti + 1
        
continuenfa:        
    next n
    
    ot_cnt = dsti
    if ( ot_cnt < 3 ) then exit sub
    dsti = 0
    
    for  n = 0 to ot_cnt-1
        src1 = n
        src2 = (n + 1) mod ot_cnt
        
        if ( ot_vtx(src1).w <= z_far ) then
            in_vtx(dsti).x = ot_vtx(src1).x
            in_vtx(dsti).y = ot_vtx(src1).y
            in_vtx(dsti).z = ot_vtx(src1).z
            in_vtx(dsti).w = ot_vtx(src1).w
            in_uv(dsti).u = ot_uv(src1).u
            in_uv(dsti).v = ot_uv(src1).v
            
            dsti = dsti + 1 
            
            if ( ot_vtx(src2).w <= z_far ) then
                goto continuenfb
            end if
        else
            if ( ot_vtx(src2).w > z_far ) then
                goto continuenfb
            end if
        end if

        scl = ((z_far - ot_vtx(src1).w) / (ot_vtx(src2).w - ot_vtx(src1).w))
     
        in_vtx(dsti).x = ot_vtx(src1).x + (ot_vtx(src2).x-ot_vtx(src1).x)*scl
        in_vtx(dsti).y = ot_vtx(src1).y + (ot_vtx(src2).y-ot_vtx(src1).y)*scl
        in_vtx(dsti).z = ot_vtx(src1).z
        in_vtx(dsti).w = z_far        
        in_uv(dsti).u = ot_uv(src1).u + (ot_uv(src2).u-ot_uv(src1).u)*scl
        in_uv(dsti).v = ot_uv(src1).v + (ot_uv(src2).v-ot_uv(src1).v)*scl
    
        dsti = dsti + 1
        
continuenfb:
    next n
    
    ot_cnt = dsti    
    
end sub



''::::::::::
'' name: d_draw_faces
'' desc: Draws the faces the BSP walk marked, in the walk's back to
''       front order.
''
'' One call per frame. Everything inside it runs per node, per face,
'' per vertex or per triangle and is therefore written out in place.
''::::::::::
'' ==========================================================================
''  RASTER
'' ==========================================================================
''
'' d_draw_faces now lives in d_faces.c -- the whole loop, ONE call per
'' frame. The BASIC version is gone rather than kept alongside: a port
'' that moved only the per-face math and kept the loop here measured
'' -0.100ms of a 38.773ms setup phase on e1m7, because the cost was the
'' 497 per-face crossings, not the arithmetic. See d_faces.c's header.
''



''::::::::::
'' name: d_turb_ptr
'' desc: Where the turbulence table lives, for d_faces.c -- which cannot
''       build its own without pulling Borland's math library into a
''       link that already has BASIC's runtime in it. Taken per frame,
''       not cached: the rule about far pointers to BASIC arrays going
''       stale is cheap to obey and expensive to forget.
''::::::::::
function d_turb_ptr ( ) as long
    d_turb_ptr = clng( varseg( turb_sin(0) ) ) * 65536& + _
                 (clng( varptr( turb_sin(0) ) ) and 65535&)
end function



''::::::::::
'' name: d_init_turb
'' desc: Builds the turbulence table once. Quake's is 8 texels of a 64 wide
''       texture; ours is in the normalised units the draw loop works in, so
''       the amplitude is that ratio.
''::::::::::
sub d_init_turb
    dim i as integer

    for  i = 0 to 255
        turb_sin(i) = TURB_AMP# * sin( i * (2.0*3.14159265 / 256.0) )
    next i

end sub
