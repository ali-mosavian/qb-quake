''
'' Visibility: r_bsp.bas marks what is visible, the rest reads it.
''
'' One named COMMON block per subsystem. Named blocks are shared
'' independently, so a module declares only the blocks it uses -- which is
'' the point of splitting this header up. Blank COMMON cannot do that: it
'' requires every module to declare the same variables in the same order.
''
'' Include after bspfile.bi and the uGL headers; the types come from there.
''

type VisState
    frame_stamp as integer      '' stamped into poly_flag for visible faces
    ord_count   as long         '' entries written to order_list
    drw_leafs   as integer      '' leaves the walk kept this frame, and
    cul_leafs   as integer      '' threw away; both shown on the stats panel
    ent_left    as integer      '' brush entities the walk has yet to emit.
                                '' Counted down so the per-node test costs an
                                '' integer compare, not a call, once they are
                                '' all placed -- which is early, there being
                                '' three of them and hundreds of nodes.
    no_ents     as integer      '' -noents, and
    bad_order   as integer      '' -badorder, copied here from env because
                                '' r_bsp.bas has no room for the env block
end type

common shared /vis_s/ vis as VisState
common shared /vis_a/ bit_array() as integer, frustum() as DiskPlane

''
'' r_bsp.bas. Declared here: r_draw_world names VisState.
''

''
'' Procedures whose signatures can be read from here.
''
