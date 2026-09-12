;; t20zems -- the scanner with an EMS depth buffer, and an EMS texture
;; beside it on another slot.
;;
;; t09rs already covers depth, but only in conventional memory
;; (qglSfZNew dst, SURF_CMEM). The renderer's is EMS: 160x100 of two
;; bytes a pixel does not fit in what conventional memory has spare, so
;; main.bas asks for SURF_EMS on QGL_Z_SLOT. That path had no test and
;; the first frame that used it hung -- the whole world's geometry, no
;; output, no error.
;;
;; The shape here is the renderer's, which is what the coverage was
;; missing: a CONVENTIONAL destination, an EMS texture on one slot and
;; an EMS depth buffer on another, all live across one qglRsPoly. Three
;; owners of the EMS window and a per-scanline remap between two of
;; them; that alternation is the thing under test, not the arithmetic.
;;
;; Numbers are t09rs's and derived the same way: a square from (8,8) to
;; (40,40) covers rows 8..39, 32 by 32 pixels, at a constant 1/z of 1.0
;; which the 100.0 scale puts at 100. 200 in the buffer is nearer
;; and must block everything; 50 is farther and must block nothing.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglDrFill     proto   far :dword, :word, :word, :word, :word, :word
qglClRect     proto   far :word, :word, :word, :word
qglRsPoly     proto   far :dword, :dword, :word, :word, :dword
qglSfZMode    proto   far :dword, :word
qglSfZNew     proto   far :dword, :word
qglSfZClear   proto   far :dword, :word
qglZScale     proto   far :dword

SFW             equ     64
SFH             equ     64
COL             equ     37
TEXCOL          equ     99

.data
n_zb            db      'ems depth buffer made  $'
n_zset          db      'z set writes 100       $'
n_znear         db      'nearer depth blocks all$'
n_zfar          db      'farther depth draws all$'
n_tex           db      'ems texture bound      $'
n_both          db      'ems tex over ems depth $'
n_after         db      'depth survives the draw$'

sq              QVert   <8.0,  8.0,  1.0, 0.0, 0.0>
                QVert   <40.0, 8.0,  1.0, 1.0, 0.0>
                QVert   <40.0, 40.0, 1.0, 1.0, 1.0>
                QVert   <8.0,  40.0, 1.0, 0.0, 1.0>

zs              real4   100.0

dst             dd      0
zb              dd      0
tx              dd      0
sqp             dd      0
hits            dw      0

.code

;; every pixel of dst equal to val
scan            proc    near private uses bx cx dx si di es,\
                        val:word

                mov     hits, 0
                xor     si, si
@@row:          cmp     si, SFH
                jae     @@out
                invoke  qglSfRow, dst, si
                mov     di, ax
                mov     es, dx
                xor     bx, bx
@@px:           cmp     bx, SFW
                jae     @@nextrow
                mov     al, es:[di]
                xor     ah, ah
                cmp     ax, val
                jne     @F
                inc     hits
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

                ;; the renderer's shape: conventional destination, the
                ;; two EMS objects on the slots qgl.inc gives them
                invoke  qglSfNew, SFW, SFH, SURF_CMEM
                SAVEP   dst
                invoke  qglSfNew, 8, 8, SURF_EMS
                SAVEP   tx

                mov     word ptr sqp, offset sq
                mov     word ptr sqp+2, ds

                invoke  qglClRect, 0, 0, SFW-1, SFH-1

                invoke  qglSfZNew, dst, SURF_EMS
                SAVEP   zb
                mov     ax, word ptr zb
                or      ax, word ptr zb+2
                NZ      ax
                CHK     n_zb, ax, 1

                invoke  qglZScale, dword ptr zs

                ;;
                ;; 1. flat over EMS depth: the write, then both compares
                ;;
                invoke  qglSfZClear, dst, 0
                invoke  qglDrFill, dst, 0, 0, SFW-1, SFH-1, 0
                invoke  qglSfZMode, dst, QGL_Z_SET
                invoke  qglRsPoly, dst, sqp, 4, QGL_M_FLAT, COL

                invoke  qglSfRow, zb, 24
                mov     di, ax
                mov     es, dx
                mov     ax, es:[di+48]          ;; x = 24, two bytes a pixel
                CHK     n_zset, ax, 100

                invoke  qglSfZClear, dst, 200
                invoke  qglDrFill, dst, 0, 0, SFW-1, SFH-1, 0
                invoke  qglSfZMode, dst, QGL_Z_TEST
                invoke  qglRsPoly, dst, sqp, 4, QGL_M_FLAT, COL
                invoke  scan, COL
                CHK     n_znear, ax, 0

                invoke  qglSfZClear, dst, 50
                invoke  qglDrFill, dst, 0, 0, SFW-1, SFH-1, 0
                invoke  qglSfZMode, dst, QGL_Z_TEST
                invoke  qglRsPoly, dst, sqp, 4, QGL_M_FLAT, COL
                invoke  scan, COL
                CHK     n_zfar, ax, 32*32

                ;;
                ;; 2. an EMS TEXTURE over an EMS depth buffer. Two
                ;;    windows live across one call, and the scanner
                ;;    remaps the depth one every scanline while holding
                ;;    the texture's segment -- which is the exact thing
                ;;    a conventional-memory depth buffer cannot exercise.
                ;;
                invoke  qglDrFill, tx, 0, 0, 7, 7, TEXCOL

                invoke  qglSfZClear, dst, 50
                invoke  qglDrFill, dst, 0, 0, SFW-1, SFH-1, 0
                invoke  qglSfZMode, dst, QGL_Z_SET
                invoke  qglRsPoly, dst, sqp, 4, QGL_M_TEX, tx
                ;; an accepted EMS texture answers with scanlines, never
                ;; the -1 a refusal returns
                NNEG    ax
                CHK     n_tex, ax, 1
                invoke  qglSfZMode, dst, QGL_Z_SET
                invoke  qglRsPoly, dst, sqp, 4, QGL_M_TEX, tx
                invoke  scan, TEXCOL
                CHK     n_both, ax, 32*32

                ;; and the depth it wrote is still there afterwards --
                ;; a texture read that had taken the depth slot would
                ;; have left the last atlas page in it instead
                invoke  qglSfRow, zb, 24
                mov     di, ax
                mov     es, dx
                mov     ax, es:[di+48]
                CHK     n_after, ax, 100

                ret
tmain           endp

                end
