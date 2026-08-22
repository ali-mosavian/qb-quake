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
end type

common shared /vis_s/ vis as VisState
common shared /vis_a/ bitarray() as integer, frustum() as plane
