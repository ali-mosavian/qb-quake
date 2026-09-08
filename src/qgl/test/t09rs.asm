;; t09rs -- the scanner and the reference filler.
;;
;; The coverage numbers here are derived, not observed. A vertex at y = 8
;; becomes 8.5 through qgl$F2fx's half-pixel and floors to scanline 8; one
;; at y = 40 becomes 40.5 and floors to 40, so the edge is 32 scanlines
;; tall and covers rows 8..39. x works out the same way, so a square from
;; (8,8) to (40,40) is exactly 32 by 32 pixels and its bounding box is
;; 8..39 both ways. Anything else is a rounding rule that changed.
;;
;; THE DEPTH CASE IS THE ONE A WHOLE-FRAME TEST CANNOT SEE. A BSP walk
;; hands its polygons over back to front already, so a depth test with its
;; polarity inverted draws exactly the same picture as a correct one. Here
;; the buffer is pre-filled by hand: 200 against the polygon's own 100
;; means something nearer is already there and NOTHING may be drawn, while
;; 50 means everything must be. Depth is 1/z, so larger is nearer.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglSfNewEx   proto   far :word, :word, :word, :word
qglSfNew      proto   far :word, :word, :word
qglSfViewNew  proto   far :dword, :word, :word, :word
qglSfViewAim  proto   far :dword, :dword
qglDrFill     proto   far :dword, :word, :word, :word, :word, :word
qglClRect     proto   far :word, :word, :word, :word
qglRsTex      proto   far :dword
qglRsFlat     proto   far :word
qglRsMode     proto   far :word
qglRsPoly     proto   far :dword, :dword, :word
qglZNew       proto   far :dword, :word
qglZSet       proto   far :dword
qglZClear     proto   far :word
qglZMode      proto   far :word
qglZScale     proto   far :dword

SFW              equ     64
SFH              equ     64
COL             equ     37

.data
n_lines         db      'square covers 32 lines $'
n_count         db      'and 32x32 pixels       $'
n_bbox          db      'bounded 8..39 both ways$'
n_centre        db      'centre is the fill col $'
n_corner        db      'corner is untouched    $'
n_zset          db      'z set writes 100       $'
n_znear         db      'nearer depth blocks all$'
n_zfar          db      'farther depth blocks 0 $'
n_tex           db      'texture bound          $'
n_texdraw       db      'textured draw covers it$'
n_straddle      db      'straddling ems refused $'
;; the three below name what went wrong, not what is checked: each was a
;; real defect against mgl and each drew a wrong frame for months.
n_pbox          db      'ptex adds no half pixel$'
n_ccw           db      'ccw winding still draws$'
n_coll          db      'collinear 0,1,2 draws  $'
n_dzdy          db      'z steps by fx height   $'

;; a square, clockwise, top-left first. z is 1/z and constant, so the
;; whole polygon sits at one depth and the test is about the compare and
;; not about interpolation.
sq              QVert   <8.0,  8.0,  1.0, 0.0, 0.0>
                QVert   <40.0, 8.0,  1.0, 1.0, 0.0>
                QVert   <40.0, 40.0, 1.0, 1.0, 1.0>
                QVert   <8.0,  40.0, 1.0, 0.0, 1.0>

;; 65536 * 100: the accumulator is 16.16 and the filler reads its integer
;; half, so a 1/z of 1.0 has to land on 100 to be compared against 50
;; and 200 as whole numbers.
;; the same square shifted half a pixel, for the PERSPECTIVE converter.
;; With mgl's F2FX_tp2d -- no half pixel -- 8.5 floors to 8 and 40.5 to
;; 40, so it covers x 8..39; qgl's converter added the affine path's half
;; and put it at 9..40, one pixel down and right, and sampled every span
;; at u - 0.5*dudx with it. z is constant so the perspective divide is
;; the identity and only the converter is under test.
sqh             QVert   <8.5,  8.5,  1.0, 0.0, 0.0>
                QVert   <40.5, 8.5,  1.0, 1.0, 0.0>
                QVert   <40.5, 40.5, 1.0, 1.0, 1.0>
                QVert   <8.5,  40.5, 1.0, 0.0, 1.0>
sqhp            dd      0

;; the same square, wound the other way. mgl reads the winding off the
;; denominator's sign and walks the ring backwards for a CCW one
;; (uglPolyTP); without that the left and right chains start on the
;; wrong sides, every span comes out negative, and the polygon draws
;; NOTHING.
sqr             QVert   <8.0,  40.0, 1.0, 0.0, 1.0>
                QVert   <40.0, 40.0, 1.0, 1.0, 1.0>
                QVert   <40.0, 8.0,  1.0, 1.0, 0.0>
                QVert   <8.0,  8.0,  1.0, 0.0, 0.0>
sqrp            dd      0

;; a quad with a vertex sitting on one of its own edges -- a t-junction,
;; which bsp faces are full of. Vertices 0, 1 and 2 are collinear, so the
;; fixed 0, n/3, 2n/3 triple has denom EXACTLY zero and the whole face is
;; dropped. mgl searches for the widest triple instead and draws it.
col             QVert   <8.0,  8.0,  1.0, 0.0, 0.0>
                QVert   <24.0, 8.0,  1.0, 0.5, 0.0>
                QVert   <40.0, 8.0,  1.0, 1.0, 0.0>
                QVert   <24.0, 40.0, 1.0, 0.5, 1.0>
colp            dd      0

;; z varies down y alone, over an edge whose FRACTIONAL height is 32.5
;; rows while its row count is 33. mgl divides dz by the fractional
;; height, the same 65536/(y1-y0) it uses for x, u and v; dividing by the
;; row count instead -- and skipping z's sub-scanline correction, which
;; mgl also applies -- put 1/z at the top row at a flat 1.0 where it
;; belongs half a step down. 1/z is the perspective divisor as well as
;; the depth, so that is a texture error too.
;;
;;   y0 = 8.0 -> 8.5 fx, frac 0.5, floor 8
;;   y3 = 40.5 -> 41.0 fx, floor 41 -> 33 rows, 32.5 of height
;;   lf_dzdy = -1.0/32.5, lf_z(row 8) = 1.0 - 0.5/32.5 = 0.98461538
;;   * 20000 = 19692;  the old arithmetic gave a flat 20000
dzq             QVert   <8.0,  8.0,  1.0, 0.0, 0.0>
                QVert   <40.0, 8.0,  1.0, 1.0, 0.0>
                QVert   <40.0, 40.5, 0.0, 1.0, 1.0>
                QVert   <8.0,  40.5, 0.0, 0.0, 1.0>
dzqp            dd      0
dzs             real4   1310720000.0            ;; 65536 * 20000

zs              real4   6553600.0

dst             dd      0
zb              dd      0
tx              dd      0
sqp             dd      0

;; two EMS pages, and a view carved out of it straddling their boundary
STRAD_OFS       equ     4000h - 40h             ;; 64 short of page 0's end
ems2            dd      0
svwp            dd      0

hits            dw      0
showv           dd      0
n_l2            db      'lines                  $'
n_z2            db      'pixels still zero      $'
xmin            dw      0
xmax            dw      0
ymin            dw      0
ymax            dw      0

.code

;; every pixel of dst equal to val: count, and the box they fall in
scan            proc    near private uses bx cx dx si di es,\
                        val:word

                mov     hits, 0
                mov     xmin, 9999
                mov     ymin, 9999
                mov     xmax, 0
                mov     ymax, 0

                xor     si, si                  ;; y
@@row:          cmp     si, SFH
                jae     @@out
                invoke  qglSfRow, dst, si
                mov     di, ax
                mov     es, dx
                xor     bx, bx                  ;; x
@@px:           cmp     bx, SFW
                jae     @@nextrow
                mov     al, es:[di]
                xor     ah, ah
                cmp     ax, val
                jne     @F
                inc     hits
                cmp     bx, xmin
                jae     @@nolo
                mov     xmin, bx
@@nolo:         cmp     bx, xmax
                jbe     @@nohi
                mov     xmax, bx
@@nohi:         cmp     si, ymin
                jae     @@nylo
                mov     ymin, si
@@nylo:         cmp     si, ymax
                jbe     @F
                mov     ymax, si
@@:             inc     di
                inc     bx
                jmp     @@px
@@nextrow:      inc     si
                jmp     @@row
@@out:          mov     ax, hits
                ret
scan            endp


tmain           proc    far public uses bx cx dx si di es

                invoke  qglSfInit

                invoke  qglSfNew, SFW, SFH, SURF_CMEM
                SAVEP   dst
                invoke  qglSfNew, 8, 8, SURF_CMEM
                SAVEP   tx

                mov     word ptr sqp, offset sq
                mov     word ptr sqp+2, ds

                invoke  qglClRect, 0, 0, SFW-1, SFH-1

                ;;
                ;; 1. a flat square, and exactly which pixels it takes
                ;;
                invoke  qglDrFill, dst, 0, 0, SFW-1, SFH-1, 0
                invoke  qglRsMode, QGL_M_FLAT
                invoke  qglRsFlat, COL
                invoke  qglRsPoly, dst, sqp, 4
                CHK     n_lines, ax, 32

                invoke  scan, COL
                CHK     n_count, ax, 32*32

                mov     ax, xmin
                add     ax, ymin
                mov     bx, xmax
                add     ax, bx
                mov     bx, ymax
                add     ax, bx                  ;; 8+8+39+39
                CHK     n_bbox, ax, 94

                invoke  qglSfPget, dst, 24, 24
                CHK     n_centre, ax, COL
                invoke  qglSfPget, dst, 0, 0
                CHK     n_corner, ax, 0

                ;;
                ;; 2. depth, and its polarity
                ;;
                invoke  qglZNew, dst, SURF_CMEM
                SAVEP   zb
                invoke  qglZSet, zb
                invoke  qglZScale, dword ptr zs

                invoke  qglZClear, 0
                invoke  qglZMode, QGL_Z_SET
                invoke  qglDrFill, dst, 0, 0, SFW-1, SFH-1, 0
                invoke  qglRsPoly, dst, sqp, 4

                invoke  qglSfRow, zb, 24
                mov     di, ax
                mov     es, dx
                mov     ax, es:[di+48]          ;; x = 24, two bytes a pixel
                CHK     n_zset, ax, 100

                ;; something NEARER is already there: nothing may draw
                invoke  qglZClear, 200
                invoke  qglZMode, QGL_Z_TEST
                invoke  qglDrFill, dst, 0, 0, SFW-1, SFH-1, 0
                invoke  qglRsPoly, dst, sqp, 4
                invoke  scan, COL
                CHK     n_znear, ax, 0

                ;; something FARTHER: all of it must draw
                invoke  qglZClear, 50
                invoke  qglDrFill, dst, 0, 0, SFW-1, SFH-1, 0
                invoke  qglRsPoly, dst, sqp, 4
                invoke  scan, COL
                CHK     n_zfar, ax, 32*32

                ;;
                ;; 3. textured, over the same square
                ;;
                invoke  qglZMode, QGL_Z_OFF
                invoke  qglDrFill, tx, 0, 0, 7, 7, 99
                invoke  qglRsTex, tx
                CHK     n_tex, ax, 1

                invoke  qglRsMode, QGL_M_TEX
                invoke  qglDrFill, dst, 0, 0, SFW-1, SFH-1, 0
                invoke  qglRsPoly, dst, sqp, 4
                invoke  scan, 99
                CHK     n_texdraw, ax, 32*32

                ;;
                ;; 4. a texture under 4000h bytes but straddling two
                ;;    physical EMS pages must still be refused -- rs.asm's
                ;;    own guard (nothing here goes through mgl at all)
                ;;
                invoke  qglSfNew, 128, 256, SURF_EMS
                SAVEP   ems2
                invoke  qglSfViewNew, ems2, 40h, 40h, 40h
                SAVEP   svwp
                invoke  qglSfViewAim, svwp, STRAD_OFS
                invoke  qglRsTex, svwp
                CHK     n_straddle, ax, 0

                ;;
                ;; 5. the perspective converter adds NO half pixel
                ;;
                mov     word ptr sqhp, offset sqh
                mov     word ptr sqhp+2, ds
                invoke  qglRsTex, tx
                invoke  qglRsMode, QGL_M_PTEX
                invoke  qglDrFill, dst, 0, 0, SFW-1, SFH-1, 0
                invoke  qglRsPoly, dst, sqhp, 4
                invoke  scan, 99
                mov     ax, xmin
                add     ax, ymin
                mov     bx, xmax
                add     ax, bx
                mov     bx, ymax
                add     ax, bx                  ;; 8+8+39+39, not 9+9+40+40
                CHK     n_pbox, ax, 94

                ;;
                ;; 6. a CCW ring draws, because the winding is corrected
                ;;
                mov     word ptr sqrp, offset sqr
                mov     word ptr sqrp+2, ds
                invoke  qglRsMode, QGL_M_FLAT
                invoke  qglRsFlat, COL
                invoke  qglDrFill, dst, 0, 0, SFW-1, SFH-1, 0
                invoke  qglRsPoly, dst, sqrp, 4
                invoke  scan, COL
                CHK     n_ccw, ax, 32*32

                ;;
                ;; 7. and a face whose first three vertices are collinear
                ;;
                mov     word ptr colp, offset col
                mov     word ptr colp+2, ds
                invoke  qglDrFill, dst, 0, 0, SFW-1, SFH-1, 0
                invoke  qglRsPoly, dst, colp, 4
                invoke  scan, COL
                NZ      ax
                CHK     n_coll, ax, 1

                ;;
                ;; 8. and z steps by the edge's fractional height
                ;;
                mov     word ptr dzqp, offset dzq
                mov     word ptr dzqp+2, ds
                invoke  qglZScale, dword ptr dzs
                invoke  qglZClear, 0
                invoke  qglZMode, QGL_Z_SET
                invoke  qglDrFill, dst, 0, 0, SFW-1, SFH-1, 0
                invoke  qglRsPoly, dst, dzqp, 4
                invoke  qglSfRow, zb, 8
                mov     di, ax
                mov     es, dx
                mov     ax, es:[di+48]          ;; x = 24
                CHK     n_dzdy, ax, 19692

                ret
tmain           endp
                end
