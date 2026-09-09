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
qglRsPoly     proto   far :dword, :dword, :word, :word, :dword
qglSfZMode    proto   far :dword, :word
qglSfZNew     proto   far :dword, :word
qglSfZClear   proto   far :dword, :word
qglSfZFree    proto   far :dword
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
n_zbadmode      db      'a mode past TEST is off$'
n_znobuf        db      'no buffer is no depth  $'
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
;; Every case above sits wholly inside the surface, so until this one the
;; suite never drew a polygon the clipper had touched -- and the scanner's
;; edge chains are set up from the CLIPPED ring.
n_cliplin       db      'clipped covers 32 lines$'
n_clipcnt       db      'and 40x32 pixels       $'
n_clipbox       db      'bounded x 0..39 y 8..39$'
;; Every textured case above draws through a texture filled with ONE value,
;; which cannot tell a correct u step from a stuck one -- and the
;; perspective arm carries u and v as real4 where the affine arm carries
;; 16.16, so the two walks are different code.
;;
;; EIGHT changes of value, not seven. One repeat is eight texels across 32
;; pixels, but the span is sampled half a texel in, so u runs about 0.5 to
;; 8.5 and crosses every integer boundary from 1 to 8. Seven is what the
;; range 0..8 would give and it is the wrong derivation, not a wrong
;; renderer -- the half texel is mgl's 0.5*z, added on the far side of the
;; perspective divide. A stuck u reads 0 here and a doubled one about 16.
n_pruns         db      'ptex u walks once across$'
n_pvruns        db      'and v once down        $'
n_wide          db      'huge u gradient draws  $'
;; A FLAT polygon has no texture and still has gradients: qgl$Grad scales
;; u and v by the texture size whatever the mode is, then gates the
;; result. Left unset on the flat arm those two scales are the LAST
;; TEXTURED CALL'S, so a flat face is refused or not depending on what
;; was drawn before it -- cross-call state, in the one entry that exists
;; to have none. flatuv's u and v are 8192 texels per pixel raw: under
;; the gate at a scale of 1, four times over it at tx's 8.
n_flatuv        db      'flat ignores tex size  $'
n_widecnt       db      'and covers 32 pixels   $'
;; The clipper walks the caller's ring with a signed step and wraps by
;; comparing the stepped pointer against vtx[0] UNSIGNED. A ring at
;; offset 0 of its segment -- which is where BASIC puts a far-heap array
;; -- steps backwards to 0FFECh, reads as past the end, and the fourth
;; vertex comes out of whatever sits 64K above the array. The renderer's
;; alias model drew screen-corner wedges out of it for months.
n_seg0lin       db      'ring at seg:0 32 lines $'
n_seg0cnt       db      'and 32x32 pixels       $'
n_seg0box       db      'bounded 8..39 both ways$'
;; A one-pixel-wide column with a few thousand repeats of u across it.
;; vu is normalised, so that is legal data, and the gradient it gives is
;; 40000 texels per pixel -- fine as the float qgl$drawP reads, 2.62e9 in
;; 16.16 and past what a signed dword holds. mgl's perspective
;; calc_gradients never converts (uglplxtp.asm) and gates the float; qgl
;; gated the 16.16 in both modes, so this face was DROPPED ENTIRELY --
;; 32 scanlines became 0. u is centred on zero so the filler's own
;; 65536*u still fits, and the texture is one value so what it samples
;; cannot hide whether it drew.
flatuv          QVert   <8.0,  8.0,  1.0, -131072.0, -131072.0>
                QVert   <40.0, 8.0,  1.0,  131072.0,  131072.0>
                QVert   <40.0, 40.0, 1.0,  131072.0,  131072.0>
                QVert   <8.0,  40.0, 1.0, -131072.0, -131072.0>
flatuvp         dd      0

narrow          QVert   <20.0,  8.0, 1.0, -2500.0, 0.0>
                QVert   <21.0,  8.0, 1.0,  2500.0, 0.0>
                QVert   <21.0, 40.0, 1.0,  2500.0, 1.0>
                QVert   <20.0, 40.0, 1.0, -2500.0, 1.0>
narrowp         dd      0

;; room for a ring copied to the next paragraph boundary, offset 0
seg0            db      SIZEOF QVert*4 + 16 dup(?)
seg0p           dd      0

;; a square, clockwise, top-left first. z is 1/z and constant, so the
;; whole polygon sits at one depth and the test is about the compare and
;; not about interpolation.
sq              QVert   <8.0,  8.0,  1.0, 0.0, 0.0>
                QVert   <40.0, 8.0,  1.0, 1.0, 0.0>
                QVert   <40.0, 40.0, 1.0, 1.0, 1.0>
                QVert   <8.0,  40.0, 1.0, 0.0, 1.0>

;; qglZScale is the depth at 1/z = 1, so 100 here to be compared against
;; the 50 and 200 the buffer is pre-filled with. The scanner supplies the
;; 16.16 the filler's integer half reads; the scale does not, and passing
;; a pre-multiplied 65536*100 -- which is what this test used to say -- is
;; how the renderer's own 65535*z_near came to store zero for every pixel
;; in the frame.
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
dzs             real4   20000.0                 ;; the depth at 1/z = 1

;; a square hanging 8 pixels off the LEFT edge. The clipper replaces both
;; left vertices with x = 0 and the scanner then walks a ring it did not
;; receive, split at whichever vertex ends up topmost -- the one path the
;; cases above leave untested. 0.5 from the affine converter floors to 0
;; and 40.5 to 40, so it is x 0..39 by y 8..39.
clp             QVert   <-8.0,  8.0,  1.0, 0.0, 0.0>
                QVert   <40.0,  8.0,  1.0, 1.0, 0.0>
                QVert   <40.0, 40.0,  1.0, 1.0, 1.0>
                QVert   <-8.0, 40.0,  1.0, 0.0, 1.0>
clpp            dd      0

tfx             dw      0
tfy             dw      0

zs              real4   100.0

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


;;::::::::::::::
;; runs -- how many times the byte value CHANGES along the middle row of
;; the drawn square, and again down its middle column. Phase-independent,
;; which is what lets it be derived rather than read off a run.
;;::::::::::::::
rowruns         proc    near uses bx cx si di es
                invoke  qglSfRow, dst, 24
                mov     di, ax
                mov     es, dx
                add     di, 8
                mov     cx, 31                  ;; 32 pixels, 31 gaps
                xor     bx, bx
@@lp:           mov     al, es:[di]
                cmp     al, es:[di+1]
                je      @F
                inc     bx
@@:             inc     di
                dec     cx
                jnz     @@lp
                mov     ax, bx
                ret
rowruns         endp

colruns         proc    near uses bx cx si di es
                mov     si, 8
                xor     bx, bx
                mov     cl, 0
@@lp:           invoke  qglSfRow, dst, si
                mov     di, ax
                mov     es, dx
                mov     al, es:[di+24]
                cmp     si, 8
                je      @F
                cmp     al, cl
                je      @F
                inc     bx
@@:             mov     cl, al
                inc     si
                cmp     si, 40
                jb      @@lp
                mov     ax, bx
                ret
colruns         endp


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
                invoke  qglRsPoly, dst, sqp, 4, QGL_M_FLAT, COL
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
                invoke  qglSfZNew, dst, SURF_CMEM
                SAVEP   zb
                invoke  qglZScale, dword ptr zs

                invoke  qglSfZClear, dst, 0
                invoke  qglDrFill, dst, 0, 0, SFW-1, SFH-1, 0
                invoke  qglSfZMode, dst, QGL_Z_SET
                invoke  qglRsPoly, dst, sqp, 4, QGL_M_FLAT, COL

                invoke  qglSfRow, zb, 24
                mov     di, ax
                mov     es, dx
                mov     ax, es:[di+48]          ;; x = 24, two bytes a pixel
                CHK     n_zset, ax, 100

                ;; something NEARER is already there: nothing may draw
                invoke  qglSfZClear, dst, 200
                invoke  qglDrFill, dst, 0, 0, SFW-1, SFH-1, 0
                invoke  qglSfZMode, dst, QGL_Z_TEST
                invoke  qglRsPoly, dst, sqp, 4, QGL_M_FLAT, COL
                invoke  scan, COL
                CHK     n_znear, ax, 0

                ;; something FARTHER: all of it must draw
                invoke  qglSfZClear, dst, 50
                invoke  qglDrFill, dst, 0, 0, SFW-1, SFH-1, 0
                invoke  qglSfZMode, dst, QGL_Z_TEST
                invoke  qglRsPoly, dst, sqp, 4, QGL_M_FLAT, COL
                invoke  scan, COL
                CHK     n_zfar, ax, 32*32

                ;; A mode qgl has no filler for must become OFF, not
                ;; index past the table -- b8_span turns (mode, zmode)
                ;; into a table offset and then `call bx`, so an
                ;; unclamped 3 calls into whatever follows it. Drawn over
                ;; a buffer cleared NEARER than the polygon: depth off
                ;; means every pixel lands, a live test means none do.
                invoke  qglSfZClear, dst, 200
                invoke  qglDrFill, dst, 0, 0, SFW-1, SFH-1, 0
                invoke  qglSfZMode, dst, QGL_Z_TEST+1
                invoke  qglRsPoly, dst, sqp, 4, QGL_M_FLAT, COL
                invoke  scan, COL
                CHK     n_zbadmode, ax, 32*32

                ;; and a surface with NO depth takes no mode, or
                ;; qglSfWrRowEx reads Surface fields out of 0000:0000.
                ;; The buffer is freed here and not remade: THE MODE IS
                ;; STICKY -- it lives on the surface, so every case below
                ;; would otherwise inherit whichever one ran last, and a
                ;; texture case silently testing depth is a texture case
                ;; that proves nothing.
                invoke  qglSfZFree, dst
                invoke  qglDrFill, dst, 0, 0, SFW-1, SFH-1, 0
                invoke  qglSfZMode, dst, QGL_Z_TEST
                invoke  qglRsPoly, dst, sqp, 4, QGL_M_FLAT, COL
                invoke  scan, COL
                CHK     n_znobuf, ax, 32*32

                ;;
                ;; 3. textured, over the same square
                ;;
                invoke  qglDrFill, tx, 0, 0, 7, 7, 99
                invoke  qglDrFill, dst, 0, 0, SFW-1, SFH-1, 0
                invoke  qglRsPoly, dst, sqp, 4, QGL_M_TEX, tx
                NNEG    ax
                CHK     n_tex, ax, 1
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
                ;; refused, and a refusal answers -1 -- not the 0 a face
                ;; that merely covered nothing answers
                invoke  qglRsPoly, dst, sqp, 4, QGL_M_TEX, svwp
                CHK     n_straddle, ax, -1

                ;;
                ;; 5. the perspective converter adds NO half pixel
                ;;
                mov     word ptr sqhp, offset sqh
                mov     word ptr sqhp+2, ds
                invoke  qglDrFill, dst, 0, 0, SFW-1, SFH-1, 0
                invoke  qglRsPoly, dst, sqhp, 4, QGL_M_PTEX, tx
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
                invoke  qglDrFill, dst, 0, 0, SFW-1, SFH-1, 0
                invoke  qglRsPoly, dst, sqrp, 4, QGL_M_FLAT, COL
                invoke  scan, COL
                CHK     n_ccw, ax, 32*32

                ;;
                ;; 7. and a face whose first three vertices are collinear
                ;;
                mov     word ptr colp, offset col
                mov     word ptr colp+2, ds
                invoke  qglDrFill, dst, 0, 0, SFW-1, SFH-1, 0
                invoke  qglRsPoly, dst, colp, 4, QGL_M_FLAT, COL
                invoke  scan, COL
                NZ      ax
                CHK     n_coll, ax, 1

                ;;
                ;; 8. and z steps by the edge's fractional height
                ;;
                mov     word ptr dzqp, offset dzq
                mov     word ptr dzqp+2, ds
                invoke  qglSfZNew, dst, SURF_CMEM       ;; freed back in 2
                SAVEP   zb
                invoke  qglZScale, dword ptr dzs
                invoke  qglSfZClear, dst, 0
                invoke  qglDrFill, dst, 0, 0, SFW-1, SFH-1, 0
                invoke  qglSfZMode, dst, QGL_Z_SET
                invoke  qglRsPoly, dst, dzqp, 4, QGL_M_FLAT, COL
                invoke  qglSfRow, zb, 8
                mov     di, ax
                mov     es, dx
                mov     ax, es:[di+48]          ;; x = 24
                CHK     n_dzdy, ax, 19692
                invoke  qglSfZFree, dst                 ;; the rest draw flat

                ;;
                ;; 9. a polygon the clipper actually rewrote
                ;;
                mov     word ptr clpp, offset clp
                mov     word ptr clpp+2, ds
                invoke  qglDrFill, dst, 0, 0, SFW-1, SFH-1, 0
                invoke  qglRsPoly, dst, clpp, 4, QGL_M_FLAT, COL
                CHK     n_cliplin, ax, 32

                invoke  scan, COL
                CHK     n_clipcnt, ax, 40*32

                mov     ax, xmin
                add     ax, ymin
                mov     bx, xmax
                add     ax, bx
                mov     bx, ymax
                add     ax, bx                  ;; 0+8+39+39
                CHK     n_clipbox, ax, 86

                ;;
                ;; 10. the perspective arm's u and v actually walk
                ;;
                mov     tfy, 0
@@tfyl:         mov     tfx, 0
@@tfxl:         mov     ax, tfy
                imul    ax, 8
                add     ax, tfx
                inc     ax                      ;; 1..64, every texel apart
                invoke  qglSfPset, tx, tfx, tfy, ax
                inc     tfx
                cmp     tfx, 8
                jb      @@tfxl
                inc     tfy
                cmp     tfy, 8
                jb      @@tfyl

                invoke  qglDrFill, dst, 0, 0, SFW-1, SFH-1, 0
                invoke  qglRsPoly, dst, sqp, 4, QGL_M_PTEX, tx

                invoke  rowruns
                CHK     n_pruns, ax, 8
                invoke  colruns
                CHK     n_pvruns, ax, 8

                ;;
                ;; 11. a gradient no 16.16 can hold, in the mode that
                ;;     never reads the 16.16
                ;;
                mov     word ptr narrowp, offset narrow
                mov     word ptr narrowp+2, ds
                invoke  qglDrFill, tx, 0, 0, 7, 7, 99
                invoke  qglDrFill, dst, 0, 0, SFW-1, SFH-1, 0
                invoke  qglRsPoly, dst, narrowp, 4, QGL_M_PTEX, tx
                CHK     n_wide, ax, 32
                invoke  scan, 99
                CHK     n_widecnt, ax, 32

                ;;
                ;; 12. and a FLAT polygon after all of that, with u and v
                ;;     no texture size may be applied to
                ;;
                mov     word ptr flatuvp, offset flatuv
                mov     word ptr flatuvp+2, ds
                invoke  qglDrFill, dst, 0, 0, SFW-1, SFH-1, 0
                invoke  qglRsPoly, dst, flatuvp, 4, QGL_M_FLAT, COL
                invoke  scan, COL
                CHK     n_flatuv, ax, 32*32

                ;;
                ;; 13. the CCW square again, at offset 0 of its segment:
                ;;     the backwards walk has to wrap from vtx[0] to
                ;;     vtx[3] without stepping below offset 0
                ;;
                mov     ax, ds
                mov     bx, offset seg0
                add     bx, 15
                shr     bx, 4
                add     ax, bx                  ;; paragraph past seg0's start
                mov     es, ax
                xor     di, di
                mov     si, offset sqr
                mov     cx, SIZEOF QVert*4
                rep     movsb
                mov     word ptr seg0p, 0
                mov     word ptr seg0p+2, es
                invoke  qglDrFill, dst, 0, 0, SFW-1, SFH-1, 0
                invoke  qglRsPoly, dst, seg0p, 4, QGL_M_FLAT, COL
                CHK     n_seg0lin, ax, 32
                invoke  scan, COL
                CHK     n_seg0cnt, ax, 32*32
                mov     ax, xmin
                add     ax, ymin
                mov     bx, xmax
                add     ax, bx
                mov     bx, ymax
                add     ax, bx
                CHK     n_seg0box, ax, 94

                ret
tmain           endp
                end
