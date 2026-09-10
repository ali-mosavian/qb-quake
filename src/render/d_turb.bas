option explicit
''
'' d_turb.bas -- the liquid turbulence table.
''
'' What is left of d_poly.bas, which was the rasteriser until d_draw_faces
'' moved to d_faces.c whole. The clipper (d_clip_z), the projection
'' scratch and the fan buffers went with it and are deleted rather than
'' kept alongside; d_faces.c does its own clipping in clip_w.
''
'' The table stays in BASIC because d_faces.c cannot build it: sin() would
'' pull Borland's math library into a link that already has BASIC's
'' runtime in it.
''
'' d_poly.bas's own list, truncated at q_draw.bi -- TURB_AMP# is the one
'' thing wanted from it, and everything before is what bspfile.bi's Game
'' needs to parse. Includes are read in file order and a type must be
'' defined before the line naming it, so the order is not negotiable.
'$include: 'in.bi'
'$include: 'bspfile.bi'
'$include: 'dos.bi'
'$include: 'arch.bi'
'$include: 'snd.bi'
'$include: 'mod.bi'
'$include: 'q_env.bi'
'$include: 'q_map.bi'
'$include: 'q_vis.bi'
'$include: 'q_draw.bi'

'$static
''
'' Quake's turbsin. A table because two sines per vertex of every liquid
'' face is not something to compute in the draw loop.
''
dim shared turb_sin( 255 ) as single


''::::::::::
'' name: d_turb_ptr
'' desc: Where the turbulence table lives, for d_faces.c. Taken per frame,
''       not cached: the rule about far pointers to BASIC arrays going
''       stale is cheap to obey and expensive to forget.
''::::::::::
function d_turb_ptr ( ) as long
    d_turb_ptr = clng( varseg( turb_sin(0) ) ) * 65536& + _
                 (clng( varptr( turb_sin(0) ) ) and 65535&)
end function


''::::::::::
'' name: d_init_turb
'' desc: Builds the table once. Quake's amplitude is 8 texels of a 64 wide
''       texture; ours is in the normalised units the draw loop works in,
''       so the amplitude is that ratio.
''::::::::::
sub d_init_turb
    dim i as integer

    for  i = 0 to 255
        turb_sin(i) = TURB_AMP# * sin( i * (2.0*3.14159265 / 256.0) )
    next i

end sub
