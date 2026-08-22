''
'' Cross-module state.
''
'' DIM SHARED is module scope only; COMMON SHARED is what actually crosses a
'' module boundary, and it has to be declared identically in every module and
'' before any executable statement. Only state that is genuinely shared
'' belongs here -- COMMON arrays are always descriptor addressed, so the hot
'' renderer scratch stays module-local under '$STATIC where it is addressed
'' directly.
''
common shared /qenv/ env as EnvType
