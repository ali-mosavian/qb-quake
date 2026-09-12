;; t08clip -- the view-rect clipper on its own: no surface, no filler, no
;;            self-modifying anything. A pure function, tested as one.
;;
;; The expected outputs were derived from an independent Sutherland-
;; Hodgman written in Python, not read back off this implementation, and
;; every coordinate below is an exact binary fraction so the comparison
;; can be integer and still be exact.
;;
;; The two that matter most:
;;
;;   B -- a square across the LEFT edge, with u = 0 on the outside pair
;;        and u = 1 on the inside pair. The new vertices must land at
;;        u = 0.5, which is the only assertion here that notices whether
;;        attributes are interpolated at all rather than copied.
;;   C -- a triangle out of the bottom-RIGHT corner, clipped by two
;;        boundaries, coming back with five vertices ROTATED: the walk
;;        starts at the ring's last vertex, so the survivor order is not
;;        the input order and a scanner that assumes vtx[0] is topmost
;;        must be told, not trusted.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglClRect     proto   far :word, :word, :word, :word
qglClPoly     proto   far :dword, :word, :dword, :dword

.data
n_in            db      'inside passes through  $'
n_inx           db      'and unchanged          $'
n_bn            db      'left clip: 4 vertices  $'
n_bx0           db      'x snapped to the bound $'
n_bu            db      'u interpolated to half $'
n_bx1           db      'inside vertex untouched$'
n_cn            db      'corner clip: 5 vertices$'
n_c0            db      'rotated: first is 32,64$'
n_c4            db      'and last is 48,64      $'
n_bt            db      'bottom only: 4 vertices$'
n_out           db      'wholly outside: none   $'
n_few           db      'two vertices: none     $'
n_many          db      'past the ceiling: none $'

;; x, y, z, u, v
sq_in           QVert   <10.0, 10.0, 1.0, 0.0, 0.0>
                QVert   <50.0, 10.0, 1.0, 1.0, 0.0>
                QVert   <50.0, 50.0, 1.0, 1.0, 1.0>
                QVert   <10.0, 50.0, 1.0, 0.0, 1.0>

sq_lf           QVert   <-20.0, 10.0, 1.0, 0.0, 0.0>
                QVert   <20.0, 10.0, 1.0, 1.0, 0.0>
                QVert   <20.0, 50.0, 1.0, 1.0, 0.0>
                QVert   <-20.0, 50.0, 1.0, 0.0, 0.0>

tri_cn          QVert   <32.0, 32.0, 1.0, 0.0, 0.0>
                QVert   <80.0, 32.0, 1.0, 0.0, 0.0>
                QVert   <32.0, 80.0, 1.0, 0.0, 0.0>

;; inside on x, past the bottom alone: the trivial accept has to look
;; at every bound, not stop at the first that rules a vertex out
tri_bt          QVert   <10.0, 10.0, 1.0, 0.0, 0.0>
                QVert   <50.0, 10.0, 1.0, 0.0, 0.0>
                QVert   <30.0, 80.0, 1.0, 0.0, 0.0>

tri_out         QVert   <100.0, 10.0, 1.0, 0.0, 0.0>
                QVert   <120.0, 10.0, 1.0, 0.0, 0.0>
                QVert   <120.0, 50.0, 1.0, 0.0, 0.0>

dst             QVert   QGL_CLIPV dup (<>)

srcp            dd      0
dstp            dd      0
scl             dw      1
tmp             dw      0

.code

;; dst[idx].<fofs>, times scl, as an integer. Every value this test
;; compares is an exact binary fraction, so the rounding is not a
;; tolerance -- it is the answer.
q_at            proc    near private uses bx dx,\
                        idx:word, fofs:word, by:word

                mov     ax, idx
                mov     dx, SIZEOF QVert
                mul     dx
                add     ax, fofs
                mov     bx, ax
                add     bx, offset dst

                mov     ax, by
                mov     scl, ax
                fld     dword ptr [bx]
                fimul   scl
                fistp   tmp
                mov     ax, tmp
                ret
q_at            endp


tmain           proc    far public uses bx cx dx si di es

                mov     word ptr dstp, offset dst
                mov     word ptr dstp+2, ds

                invoke  qglClRect, 0, 0, 63, 63

                ;;
                ;; 1. wholly inside: through untouched
                ;;
                mov     word ptr srcp, offset sq_in
                mov     word ptr srcp+2, ds
                invoke  qglClPoly, srcp, 4, dstp, 0
                CHK     n_in, ax, 4
                invoke  q_at, 2, QVert.vx, 1
                CHK     n_inx, ax, 50

                ;;
                ;; 2. across the left edge
                ;;
                mov     word ptr srcp, offset sq_lf
                invoke  qglClPoly, srcp, 4, dstp, 0
                CHK     n_bn, ax, 4
                invoke  q_at, 0, QVert.vx, 1
                CHK     n_bx0, ax, 0
                invoke  q_at, 0, QVert.vu, 100
                CHK     n_bu, ax, 50
                invoke  q_at, 1, QVert.vx, 1
                CHK     n_bx1, ax, 20

                ;;
                ;; 3. out of the bottom-right corner: two boundaries, and
                ;;    the survivors come back rotated
                ;;
                mov     word ptr srcp, offset tri_cn
                invoke  qglClPoly, srcp, 3, dstp, 0
                CHK     n_cn, ax, 5
                invoke  q_at, 0, QVert.vx, 1
                mov     bx, ax
                invoke  q_at, 0, QVert.vy, 1
                add     ax, bx                  ;; 32 + 64
                CHK     n_c0, ax, 96
                invoke  q_at, 4, QVert.vx, 1
                mov     bx, ax
                invoke  q_at, 4, QVert.vy, 1
                add     ax, bx                  ;; 48 + 64
                CHK     n_c4, ax, 112

                mov     word ptr srcp, offset tri_bt
                invoke  qglClPoly, srcp, 3, dstp, 0
                CHK     n_bt, ax, 4

                ;;
                ;; 4. the refusals
                ;;
                mov     word ptr srcp, offset tri_out
                invoke  qglClPoly, srcp, 3, dstp, 0
                CHK     n_out, ax, 0

                mov     word ptr srcp, offset sq_in
                invoke  qglClPoly, srcp, 2, dstp, 0
                CHK     n_few, ax, 0

                invoke  qglClPoly, srcp, QGL_MAXV+1, dstp, 0
                CHK     n_many, ax, 0
                ret
tmain           endp
                end
