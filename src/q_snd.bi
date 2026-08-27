''
'' Sound and palette handles.
''
'' One named COMMON block per subsystem. Named blocks are shared
'' independently, so a module declares only the blocks it uses -- which is
'' the point of splitting this header up. Blank COMMON cannot do that: it
'' requires every module to declare the same variables in the same order.
''
'' Include after bspfile.bi and the uGL headers; the types come from there.
''

''
'' Two unrelated handles that need no struct of their own: the loading MOD
'' track, and the palette mod_load_textures reads and vid_init installs.
''
common shared /snd_s/ mymod as UGMMOD
