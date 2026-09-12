;; clip.asm -- Sutherland-Hodgman against the view rectangle.
;;
;; name: qglClRect / qglClPoly
;; desc: four passes over the polygon, one per screen edge, ping-ponging
;;       between two buffers. No near plane: d_faces.c already clips w
;;       before it projects, and mgl never had one either.
;;
;; obs.: - THE PASSES DIFFER ONLY IN A COORDINATE AND A SIGN, so there is
;;         one pass routine and a four-entry table, rather than mgl's
;;         four expansions of one macro. The signed distance is
;;         (v.coord - bound) * sgn, and sgn is a float so the sign costs
;;         a multiply instead of a branch per vertex.
;;       - WHOLE VERTICES ARE COPIED, not pointers into a scratch array.
;;         mgl keeps pointers in SH_cpv and appends new vertices to
;;         SH_vbuff, which is how SH_vbuff came to be sized for one pass
;;         while four passes accumulate into it. Twenty bytes moved per
;;         surviving vertex is nothing next to a class of overrun that
;;         cannot happen.
;;       - the clipped coordinate is SNAPPED to the bound after the lerp.
;;         Without it a vertex lands a rounding step outside and the next
;;         pass clips it again, which is how a polygon loses an edge it
;;         was only touching.
;;       - x1 and y1 are stored one past the caller's, because the filler
;;         does not draw its last column or row. mgl does the same thing
;;         by incrementing DC.xMax inside SH_INIT and decrementing it in
;;         SH_ENDP -- the same fact, said once at the boundary instead of
;;         twice inside the loop.

                .model  medium, pascal
                .386

                include qgl.inc

qglClPolyEx   proto   far pascal :dword, :word, :dword, :dword, :word, :word

;; one clip boundary: which coordinate, which bound, which way is in
ClipEdge        struc
cofs            dw      ?               ;; offset of the coordinate in QVert
bofs            dw      ?               ;; offset of the bound, DGROUP
sofs            dw      ?               ;; offset of +1.0 or -1.0
ClipEdge        ends


                extrn   qgl_cy:dword

.data
qgl$one         real4   1.0
qgl$mone        real4   -1.0
qgl$ix          dw      0
qgl$iy          dw      0

qgl$ux0         dw      0                       ;; the caller's viewport
qgl$uy0         dw      0
qgl$ux1         dw      7FFFh
qgl$uy1         dw      7FFFh

qgl$clx0        real4   0.0
qgl$cly0        real4   0.0
qgl$clx1        real4   0.0
qgl$cly1        real4   0.0

qgl$edgeTB      ClipEdge <QVert.vx, qgl$clx0, qgl$one>     ;; left
                ClipEdge <QVert.vx, qgl$clx1, qgl$mone>    ;; right
                ClipEdge <QVert.vy, qgl$cly0, qgl$one>     ;; top
                ClipEdge <QVert.vy, qgl$cly1, qgl$mone>    ;; bottom

.data?
;; the two ping-pong buffers. Static rather than on the stack: 900 bytes
;; each, and this is called once per polygon.
qgl$buf0        QVert   QGL_CLIPV dup (<>)
qgl$buf1        QVert   QGL_CLIPV dup (<>)


.code

;;::::::::::::::
;; qgl$Dist -- signed distance of a vertex from the current boundary.
;;
;; INTERNAL. ds:si -> QVert, bx -> the ClipEdge. Leaves the distance on
;; the FPU and touches no register.
;;::::::::::::::
qgl$Dist        proc    near private uses ax bx si

                mov     ax, [bx].ClipEdge.cofs
                add     si, ax                  ;; si+ax is not an address
                fld     dword ptr [si]
                mov     si, [bx].ClipEdge.bofs
                fsub    dword ptr [si]
                mov     si, [bx].ClipEdge.sofs
                fmul    dword ptr [si]
                ret
qgl$Dist        endp


;;::::::::::::::
;; qgl$Lerp -- one vertex between two, at the fraction on the FPU.
;;
;; INTERNAL. ds:si -> the far vertex, ds:bx -> the near one, es:di -> out,
;; st(0) = t. The fraction is LEFT on the stack: the caller pops it, so
;; two emissions from one edge pay for the divide once.
;;
;; The boundary coordinate is not lerped, it is assigned: snapping is
;; what keeps the next pass from clipping the same vertex again.
;;::::::::::::::
qgl$Lerp        proc    near private uses bx cx si di

                ;; the pointers walk; dx as an index is not a 16-bit
                ;; addressing mode and a 32-bit one would want a prefix
                ;; on every one of these
                mov     cx, SIZEOF QVert / 4

@@fld:          fld     st(0)                   ;; t
                fld     dword ptr [si]
                fsub    dword ptr [bx]
                fmul                            ;; (far - near) * t
                fadd    dword ptr [bx]
                fstp    dword ptr es:[di]
                add     si, 4
                add     bx, 4
                add     di, 4
                loop    @@fld
                ret
qgl$Lerp        endp


;;::::::::::::::
;; qgl$Copyv -- one vertex, ds:si -> es:di. Both pointers advance.
;;
;; INTERNAL. Everything but si and di survives.
;;::::::::::::::
qgl$Copyv       proc    near private uses cx

                cld
                mov     cx, SIZEOF QVert / 4
                rep     movsd
                ret
qgl$Copyv       endp


;;::::::::::::::
;; qgl$Pass -- one boundary.
;;
;; INTERNAL. bx -> ClipEdge, ds:si -> input, es:di -> output, cx = input
;; count. Returns the output count in ax; every other register survives.
;;::::::::::::::
qgl$Pass        proc    near private uses bx cx dx si di

                local   edge:word
                local   ivtx:word
                local   ovtx:word
                local   incnt:word
                local   nout:word
                local   prev:word
                local   dprev:real4
                local   dcur:real4
                local   pin:word
                local   idx:word

                mov     edge, bx
                mov     ivtx, si
                mov     ovtx, di
                mov     incnt, cx
                mov     nout, 0

                cmp     cx, 3
                jb      @@out                   ;; not a polygon
                cmp     cx, QGL_CLIPV
                ja      @@out

                ;; prev = the LAST vertex: the ring closes there
                mov     ax, cx
                dec     ax
                mov     dx, SIZEOF QVert
                mul     dx
                add     ax, si
                mov     prev, ax

                mov     si, ax
                call    qgl$Dist
                fstp    dprev
                ;; A FLOAT'S SIGN IS AN INTEGER COMPARE. IEEE puts the
                ;; sign in the top bit, so read as a SIGNED dword every
                ;; positive float is >= 0 and every negative one < 0 --
                ;; no fcom, no status word, no branch on the FPU.
                mov     pin, 0
                cmp     dword ptr dprev, 0
                jl      @F
                mov     pin, 1
@@:
                mov     si, ivtx
                mov     di, ovtx
                mov     idx, 0

@@vtx:          mov     bx, edge
                call    qgl$Dist
                fstp    dcur

                ;; cur_in and prev_in decide which of the four cases this
                ;; is; the two that cross the boundary make a vertex
                mov     ax, 0
                cmp     dword ptr dcur, 0
                jl      @F
                mov     ax, 1
@@:             cmp     ax, pin
                je      @@nocross

                ;; t = dprev / (dprev - dcur)
                fld     dprev
                fld     dprev
                fsub    dcur
                fdiv
                push    si
                push    bx
                mov     bx, prev
                call    qgl$Lerp                ;; leaves t on the stack
                pop     bx
                pop     si
                fstp    st(0)                   ;; done with t

                ;; snap: the new vertex sits ON the boundary, exactly
                mov     bx, edge
                mov     dx, [bx].ClipEdge.cofs
                mov     bx, [bx].ClipEdge.bofs
                mov     eax, dword ptr [bx]
                add     di, dx
                mov     dword ptr es:[di], eax
                sub     di, dx

                add     di, SIZEOF QVert
                inc     nout
                cmp     nout, QGL_CLIPV
                jae     @@out                   ;; see below

@@nocross:      cmp     dword ptr dcur, 0
                jl      @@next                  ;; outside: nothing to emit

                call    qgl$Copyv               ;; advances si and di
                sub     si, SIZEOF QVert        ;; copyv consumed it
                inc     nout

                ;; A FULL BUFFER ABANDONS THE POLYGON, and this cannot
                ;; fire on valid input: a pass emits at most one vertex
                ;; more than it read, four passes at most four, and the
                ;; buffers hold QGL_MAXV + 4. It is here because when the
                ;; cross test was deliberately inverted to check that the
                ;; tests notice, the pass ran away and wrote through the
                ;; whole of DGROUP -- the assertion strings included. A
                ;; bug in here should cost a face, not the data segment.
                cmp     nout, QGL_CLIPV
                jae     @@out

@@next:         mov     eax, dcur
                mov     dprev, eax
                mov     ax, 0
                cmp     dword ptr dcur, 0
                jl      @F
                mov     ax, 1
@@:             mov     pin, ax

                mov     prev, si
                add     si, SIZEOF QVert
                inc     idx
                mov     ax, idx
                cmp     ax, incnt
                jb      @@vtx

@@out:          mov     ax, nout
                ret
qgl$Pass        endp


;;::::::::::::::
;; qglClRect ( x0:word, y0:word, x1:word, y1:word )
;;
;; The view rectangle, inclusive as the caller means it. Stored with x1
;; and y1 one larger, because the filler does not draw its last column or
;; row: a polygon reaching the right edge must survive to it.
;;::::::::::::::
qglClRect     proc    public uses ax,\
                        x0:word, y0:word, x1:word, y1:word

                mov     ax, x0
                mov     qgl$ux0, ax
                mov     ax, y0
                mov     qgl$uy0, ax
                mov     ax, x1
                mov     qgl$ux1, ax
                mov     ax, y1
                mov     qgl$uy1, ax
                ret
qglClRect     endp


;;::::::::::::::
;; qgl$Bounds -- the effective rect, into the float bounds the passes use.
;;
;; INTERNAL. es:bx -> the destination Surface, or es:bx null for the
;; viewport alone. The rect is the caller's viewport INTERSECTED with the
;; surface's own extents, so a polygon can never survive the clipper and
;; still fall outside the thing it is drawn on. mgl keeps the same rect on
;; the DC itself and SH_INIT reads it from there.
;;
;; x1 and y1 go in one larger than the last pixel, because the filler does
;; not draw its final column or row -- SH_INIT does the same with `inc
;; fs:[DC.xMax]`.
;;::::::::::::::
qgl$Bounds      proc    near private uses ax cx dx

                mov     ax, qgl$ux0
                mov     cx, qgl$uy0
                mov     dx, es
                or      dx, bx
                jz      @@lo                    ;; no surface named

                test    ax, ax                  ;; a viewport may not start
                jge     @F                      ;; left of the surface
                xor     ax, ax
@@:             test    cx, cx
                jge     @@lo
                xor     cx, cx

@@lo:           mov     qgl$ix, ax
                mov     qgl$iy, cx
                fild    qgl$ix
                fstp    qgl$clx0
                fild    qgl$iy
                fstp    qgl$cly0

                mov     ax, qgl$ux1
                mov     cx, qgl$uy1
                mov     dx, es
                or      dx, bx
                jz      @@hi

                mov     dx, es:[bx].Surface.xRes
                dec     dx
                cmp     ax, dx
                jle     @F
                mov     ax, dx
@@:             mov     dx, es:[bx].Surface.yRes
                dec     dx
                cmp     cx, dx
                jle     @@hi
                mov     cx, dx

@@hi:           inc     ax                      ;; the last column is not drawn
                inc     cx
                mov     qgl$ix, ax
                mov     qgl$iy, cx
                fild    qgl$ix
                fstp    qgl$clx1
                fild    qgl$iy
                fstp    qgl$cly1
                ret
qgl$Bounds      endp


;;::::::::::::::
;; qglClPoly ( src:far ptr QVert, n:word, dst:far ptr QVert, sf ) -> ax
;;
;; The ring in the order it was given. qglClPolyEx below is the same
;; thing with the walk spelled out.
;;::::::::::::::
qglClPoly     proc    public uses bx,\
                        src:dword, n:word, dst:dword, sf:dword

                mov     bx, W src
                invoke  qglClPolyEx, src, n, dst, sf, bx, SIZEOF QVert
                ret
qglClPoly     endp


;;::::::::::::::
;; qglClPolyEx ( src:far ptr QVert, n:word, dst:far ptr QVert, sf,
;;               base:word, step:word ) -> ax
;;
;; ax is the surviving vertex count, 0 if nothing does. dst must hold
;; QGL_CLIPV vertices; n past QGL_MAXV is refused rather than truncated,
;; because a truncated polygon is a wrong picture and a refused one is a
;; missing face.
;;
;; src names the vertex the ring is read FROM, base names vtx[0] in the
;; same segment, and step is +SIZEOF QVert or -SIZEOF QVert. That is
;; mgl's SH_INIT_poly signature (mscshpc.inc) and it exists for its
;; reason: the scanner needs vtx[0] topmost and the ring clockwise, and
;; a walk with a start and a signed step gives it both without a second
;; copy of the polygon anywhere.
;;::::::::::::::
qglClPolyEx   proc    public uses bx cx dx si di ds es,\
                        src:dword, n:word, dst:dword, sf:dword,\
                        base:word, step:word

                local   cnt:word
                local   pass:word

                les     bx, sf
                call    qgl$Bounds

                mov     ax, n
                mov     cnt, ax
                cmp     ax, 3
                jb      @@none
                cmp     ax, QGL_MAXV
                ja      @@none

                ;;
                ;; pass 0 reads the caller's vertices, walking the ring
                ;; from src by step with wrap; every later pass reads what
                ;; the one before it wrote
                ;;
                push    ds
                pop     es
                mov     di, offset qgl$buf0
                lds     si, src
                mov     cx, cnt
                mov     ax, cx
@@in:           call    qgl$Copyv               ;; advances si and di
                sub     si, SIZEOF QVert        ;; copyv consumed it
                push    ax
                push    dx
                mov     ax, cnt
                imul    ax, SIZEOF QVert
                mov     dx, base
                add     dx, ax                  ;; one past vtx[cnt-1]
                ;; wrap BEFORE stepping: base can be 0 (a BASIC far-heap
                ;; array), and a pointer already stepped below it has
                ;; wrapped to 0FFECh, which no unsigned compare can see
                cmp     step, 0
                jl      @@back
                add     si, step
                cmp     si, dx
                jb      @@advd
                mov     si, base                ;; stepped past vtx[cnt-1]
                jmp     short @@advd
@@back:         cmp     si, base
                jne     @@stepb
                mov     si, dx                  ;; at vtx[0]: come round
@@stepb:        add     si, step
@@advd:         pop     dx
                pop     ax
                dec     ax
                jnz     @@in
                push    es
                pop     ds

                ;;
                ;; WHOLLY INSIDE, the passes would copy the ring four times
                ;; and change nothing, so it goes straight out. The test is
                ;; the passes' own: in is x >= x0 and x < x1 -- a vertex ON
                ;; x1 has distance (x1 - x1) * -1 = -0.0, sign set, out.
                ;; With every bound >= 0 that is a signed integer compare
                ;; on the float's bits, and -0.0 and NaN both land on the
                ;; side the passes put them.
                ;;
                mov     si, offset qgl$buf0
                mov     eax, D qgl$clx0
                or      eax, D qgl$cly0
                or      eax, D qgl$clx1
                or      eax, D qgl$cly1
                js      @@clip
                mov     cx, cnt
@@acc:          mov     eax, D [si].QVert.vx
                cmp     eax, D qgl$clx0
                jl      @@clip
                cmp     eax, D qgl$clx1
                jge     @@clip
                mov     eax, D [si].QVert.vy
                cmp     eax, D qgl$cly0
                jl      @@clip
                cmp     eax, D qgl$cly1
                jge     @@clip
                add     si, SIZEOF QVert
                loop    @@acc
                inc     D qgl_cy+40             ;; wholly inside: no clip needed
                mov     si, offset qgl$buf0
                jmp     @@out

@@clip:         mov     pass, 0
                mov     si, offset qgl$buf0
                mov     di, offset qgl$buf1

@@edge:         mov     bx, pass
                imul    bx, SIZEOF ClipEdge
                add     bx, offset qgl$edgeTB
                mov     cx, cnt
                push    ds
                pop     es
                call    qgl$Pass
                mov     cnt, ax
                test    ax, ax
                jz      @@none

                xchg    si, di                  ;; the output becomes input
                inc     pass
                cmp     pass, 4
                jb      @@edge

                ;;
                ;; si now points at the last pass's OUTPUT, because the
                ;; xchg above ran after it
                ;;
;; One block move, not one call a vertex. The ring is contiguous in
;; both buffers by here -- only pass 0 walks it with a step -- and
;; qgl$Copyv's call, push, cld and pop cost about as much again as
;; the five movsd they wrap.
@@out:          les     di, dst
                mov     cx, cnt
                imul    cx, SIZEOF QVert / 4
                cld
                rep     movsd

                mov     ax, cnt
                ret

@@none:         xor     ax, ax
                ret
qglClPolyEx   endp

                end
