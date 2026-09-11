option explicit
''
'' qglstub.bas -- the oracles' entry points when the oracles are not
'' linked. -qglcheck, -qgldiff, -qglarr and -qglface are 13K of code
'' the far heap pays for on every map; `make ORACLES=1` links
'' qglchk/qgldiff/qglarr/qglface in place of this, and tools/check.sh
'' runs them from that build.
''
'$include: 'qgl.bi'
'$include: 'in.bi'
'$include: 'bspfile.bi'

function qglCheckAll () as integer
    sys_error "0x0060, -qglcheck needs the oracle build: make ORACLES=1"
end function

function qglDiffAll () as integer
    sys_error "0x0060, -qgldiff needs the oracle build: make ORACLES=1"
end function

function qglArrAll () as integer
    sys_error "0x0060, -qglarr needs the oracle build: make ORACLES=1"
end function

function qglFaceAll () as integer
    sys_error "0x0060, -qglface needs the oracle build: make ORACLES=1"
end function
