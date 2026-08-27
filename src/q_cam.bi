''
'' Camera and view.
''
'' One named COMMON block per subsystem. Named blocks are shared
'' independently, so a module declares only the blocks it uses -- which is
'' the point of splitting this header up. Blank COMMON cannot do that: it
'' requires every module to declare the same variables in the same order.
''
'' Include after bspfile.bi and the uGL headers; the types come from there.
''

''
'' pos was map state because the spawn point sets it, but it belongs to the
'' camera and the backface test reads it for every face.
''
type CamState
    pos         as u3dVector3f  '' eye, from the map's spawn then mouse-driven
    look_at     as u3dVector3f
    start_angle as single       '' spawn yaw, seeds the mouse position
    fps_view     as integer      '' false = the fixed overhead view
    script_file as integer      '' open handle in cammode 1 and 2, else 0
end type

common shared /cam_s/ cam as CamState

''
'' model.bas. Declared here: mod_find_spawn names CamState.
''
declare sub mod_spawn_from_block ( _
    block as string, _
    cam as CamState _
)
declare sub mod_find_spawn ( _
    wld as World, _
    cam as CamState _
)
