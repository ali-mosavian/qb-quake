''
'' qgl.bi -- the qgl layer's constants, for BASIC callers.
''
'' The assembly reads qgl.inc and BASIC reads this; the two say the same
'' thing in the only two languages that both have to agree in. That is
'' the same split bspfile.bi and qcshared.h already make, and it carries
'' the same obligation: change one and change the other.
''
'' Values, not names, are what cross the boundary -- so they are spelled
'' out here rather than derived, and the derivation they must match is
'' written beside each one.
''

'' qgl_mem_avail's selector. In qgl.inc these are 0 and 1 scaled by
'' SIZEOF MemOps, which is one word.
const QGL_MEM_LARGEST = 0        '' largest single block DOS will give
const QGL_MEM_TOTAL   = 2        '' every free block added up

'' Where a surface's pixels live. qgl.inc scales these by SIZEOF
'' SurfaceOps, also one word.
const QGL_SURF_CMEM = 0
const QGL_SURF_EMS  = 2
