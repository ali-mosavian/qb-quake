;; t09rs -- the scanner and the reference filler.
;;
;; The coverage numbers here are derived, not observed. A vertex at y = 8
;; becomes 8.5 through qgl$f2fx's half-pixel and floors to scanline 8; one
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

qgl_sf_new_ex   proto   far :word, :word, :word, :word, :word
qgl_dr_fill     proto   far :dword, :word, :word, :word, :word, :word
qgl_cl_rect     proto   far :word, :word, :word, :word
qgl_rs_tex      proto   far :dword
qgl_rs_flat     proto   far :word
qgl_rs_mode     proto   far :word
qgl_rs_poly     proto   far :dword, :dword, :word
qgl_z_new       proto   far :dword, :word, :word
qgl_z_set       proto   far :dword
qgl_z_clear     proto   far :word
qgl_z_mode      proto   far :word
qgl_z_scale     proto   far :dword

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
zs              real4   6553600.0

dst             dd      0
zb              dd      0
tx              dd      0
sqp             dd      0

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
                invoke  qgl_sf_row, dst, si
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

                invoke  qgl_sf_init

                invoke  qgl_sf_new, SFW, SFH, SURF_CMEM, 0
                SAVEP   dst
                invoke  qgl_sf_new, 8, 8, SURF_CMEM, 0
                SAVEP   tx

                mov     word ptr sqp, offset sq
                mov     word ptr sqp+2, ds

                invoke  qgl_cl_rect, 0, 0, SFW-1, SFH-1

                ;;
                ;; 1. a flat square, and exactly which pixels it takes
                ;;
                invoke  qgl_dr_fill, dst, 0, 0, SFW-1, SFH-1, 0
                invoke  qgl_rs_mode, QGL_M_FLAT
                invoke  qgl_rs_flat, COL
                invoke  qgl_rs_poly, dst, sqp, 4
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

                invoke  qgl_sf_pget, dst, 24, 24
                CHK     n_centre, ax, COL
                invoke  qgl_sf_pget, dst, 0, 0
                CHK     n_corner, ax, 0

                ;;
                ;; 2. depth, and its polarity
                ;;
                invoke  qgl_z_new, dst, SURF_CMEM, 0
                SAVEP   zb
                invoke  qgl_z_set, zb
                invoke  qgl_z_scale, dword ptr zs

                invoke  qgl_z_clear, 0
                invoke  qgl_z_mode, QGL_Z_SET
                invoke  qgl_dr_fill, dst, 0, 0, SFW-1, SFH-1, 0
                invoke  qgl_rs_poly, dst, sqp, 4

                invoke  qgl_sf_row, zb, 24
                mov     di, ax
                mov     es, dx
                mov     ax, es:[di+48]          ;; x = 24, two bytes a pixel
                CHK     n_zset, ax, 100

                ;; something NEARER is already there: nothing may draw
                invoke  qgl_z_clear, 200
                invoke  qgl_z_mode, QGL_Z_TEST
                invoke  qgl_dr_fill, dst, 0, 0, SFW-1, SFH-1, 0
                invoke  qgl_rs_poly, dst, sqp, 4
                invoke  scan, COL
                CHK     n_znear, ax, 0

                ;; something FARTHER: all of it must draw
                invoke  qgl_z_clear, 50
                invoke  qgl_dr_fill, dst, 0, 0, SFW-1, SFH-1, 0
                invoke  qgl_rs_poly, dst, sqp, 4
                invoke  scan, COL
                CHK     n_zfar, ax, 32*32

                ;;
                ;; 3. textured, over the same square
                ;;
                invoke  qgl_z_mode, QGL_Z_OFF
                invoke  qgl_dr_fill, tx, 0, 0, 7, 7, 99
                invoke  qgl_rs_tex, tx
                CHK     n_tex, ax, 1

                invoke  qgl_rs_mode, QGL_M_TEX
                invoke  qgl_dr_fill, dst, 0, 0, SFW-1, SFH-1, 0
                invoke  qgl_rs_poly, dst, sqp, 4
                invoke  scan, 99
                CHK     n_texdraw, ax, 32*32

                ret
tmain           endp
                end
