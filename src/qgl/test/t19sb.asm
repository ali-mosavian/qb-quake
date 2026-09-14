;; t19sb -- qglSbBuild composites a surface, and comes back.
;;
;; THIS TEST COULD NOT BE WRITTEN UNTIL sb.asm STOPPED NAMING MGL. The
;; suite links no UGLV.LIB by design, so a module reaching for ul$dctTB
;; could not appear here at all -- which is exactly why the builder was
;; the one qgl module with no native coverage, and why four separate
;; faults sat in it undetected. Every one of them is reproduced below:
;;
;;   1. the DISPATCH. mgl's table holds NEAR pointers into ugl_text and
;;      sb.asm assembles into qgl_text, so `call ss:ul$dctTB[bx+rdAccess]`
;;      kept CS and landed at that offset inside qgl_text -- 69 bytes
;;      into qgl$Fixup. Real mode, so it ran instead of faulting.
;;   2. the COLORMAP SEGMENT. uglsurf.asm reloads gs from its own cmseg
;;      before the texel loop ("colormap keeps a segment"); the port
;;      dropped that line, so sb$cmseg was written and never read and
;;      every shaded texel came out of the texture's segment.
;;   3. BP. The texel loop uses bp as its counter, so the frame pointer
;;      is gone by the copy loop -- where `dstDc` is read bp-relative.
;;   4. DS. gem.asm reaches qgl$pgframe with no override, so qglGemMap
;;      wants ds = DGROUP; the copy loop was calling it with ds on the
;;      scratch block, taking a word of scratch as the page frame.
;;
;; 3 and 4 lived in the copy loop, which is gone: the builder writes the
;; destination in place, mapped once while bp and ds are still intact.
;;
;; THE CASE IS RIGGED TO HAVE AN EXACT ANSWER, because "it returned" is
;; not evidence and a plausible-looking surface is worth nothing:
;;
;;   - every luxel is one level, so t is one number and the span is flat.
;;   - colormap row r maps texel i to (i + r) and 255, so each byte says
;;     both the texel and the row it was shaded through.
;;   - du = dv = 1.0 in 16.16 and msk = 15, so texel (x,y) of a 16-wide
;;     texture lands at (x,y) of the surface.
;;
;; The row at (x,y) is t ordered-dithered by the surface's own x,y:
;; min(max(t + raw(y and 3, x and 3)*16 - 120, 64) >> 8, 63), computed
;; here from this file's own copy of the matrix. Three levels: 4, t
;; 16056, straddles rows 62 and 63 where no entry and its x,y transpose
;; fall on one side; 255, t 64, dithers under zero and must
;; read row 0; 0, t 16320, dithers past 16383 and must read row 63 --
;; row 64 is past the table. A wrong segment, row, offset, skipped write
;; or stale pointer breaks the equality; none produces it by accident.
;;
;; The DESTINATION IS EMS on purpose: a conventional one never calls
;; qglGemMap, and fault 4 lives there and nowhere else.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglSbBuild    proto   far :dword, :dword, :dword

TEX_W           equ     16
TEX_H           equ     16
LM_W            equ     2
LM_H            equ     2

;; mirrors sb.asm's own SBPARM, which mirrors bspfile.bi's SurfBuild
SBPARM          struc
sb_lmptr        dd      ?
sb_lmstride     dd      ?
sb_cmapptr      dd      ?
sb_au0          dd      ?
sb_av0          dd      ?
sb_du           dd      ?
sb_dv           dd      ?
sb_sw           dw      ?
sb_sh           dw      ?
sb_lmw          dw      ?
sb_lmh          dw      ?
sb_shift        dw      ?
sb_msk          dw      ?
sb_vmsk         dw      ?
SBPARM          ends

.data
n_tex_new       db      'tex surface made       $'
n_dst_new       db      'ems dst surface made   $'
n_built         db      'qglSbBuild returned ok $'
n_mix           db      'level 4 rows 62 and 63 $'
n_low           db      'level 255 row 0        $'
n_high          db      'level 0 row 63         $'

raw             db      0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5

tex             dd      0
dst             dd      0
parmp           dd      0
mism            dw      0

.data?
parm            SBPARM  <>
cmap            db      64*256 dup (?)
lux             db      LM_W*LM_H dup (?)

.code

;;::::::::::::::
;; Every texel of dst against the byte that must have produced it: the
;; texture's y*TEX_W + x plus the dithered row of t.
;;::::::::::::::
sb_verify       proc    near private uses bx cx dx si di es, tval:word

                mov     mism, 0
                xor     si, si                  ;; y
@@row:          cmp     si, TEX_H
                jae     @@out
                xor     di, di                  ;; x
@@col:          cmp     di, TEX_W
                jae     @@next

                invoke  qglSfPget, dst, di, si
                and     ax, 0FFh
                push    ax

                mov     bx, si
                and     bx, 3
                shl     bx, 2
                mov     ax, di
                and     ax, 3
                add     bx, ax
                movzx   ax, byte ptr raw[bx]
                shl     ax, 4
                sub     ax, 120
                add     ax, tval
                cmp     ax, 64
                jge     @F
                mov     ax, 64
@@:             shr     ax, 8
                cmp     ax, 63
                jbe     @F
                mov     ax, 63
@@:             imul    cx, si, TEX_W
                add     ax, cx
                add     ax, di
                and     ax, 0FFh

                pop     bx
                cmp     ax, bx
                je      @F
                inc     mism
@@:             inc     di
                jmp     @@col

@@next:         inc     si
                jmp     @@row

@@out:          mov     ax, mism
                ret
sb_verify       endp

;;::::::::::::::
;; every luxel at one level, then one build
;;::::::::::::::
sb_case         proc    near private uses bx cx, level:word

                mov     cx, LM_W*LM_H
                xor     bx, bx
                mov     ax, level
@@lx:           mov     byte ptr lux[bx], al
                inc     bx
                loop    @@lx
                invoke  qglSbBuild, dst, tex, parmp
                ret
sb_case         endp


tmain           proc    far public uses bx cx dx si di es

                invoke  qglSfInit

                ;;
                ;; the texture: a walking byte, so a texel fetched from
                ;; the wrong row or column is a different value
                ;;
                invoke  qglSfNew, TEX_W, TEX_H, SURF_CMEM
                SAVEP   tex
                mov     bx, dx
                or      bx, ax
                NZ      bx
                CHK     n_tex_new, ax, 1

                xor     si, si                  ;; y
@@trow:         cmp     si, TEX_H
                jae     @F
                xor     di, di                  ;; x
@@tcol:         cmp     di, TEX_W
                jae     @@tnext
                mov     ax, si
                mov     cx, TEX_W
                mul     cx
                add     ax, di
                and     ax, 0FFh
                invoke  qglSfPset, tex, di, si, ax
                inc     di
                jmp     @@tcol
@@tnext:        inc     si
                jmp     @@trow

                ;;
                ;; the destination, in EMS -- see the header: the copy
                ;; loop's qglGemMap is the only thing that reads ds
                ;;
@@:             invoke  qglSfNew, TEX_W, TEX_H, SURF_EMS
                SAVEP   dst
                mov     bx, dx
                or      bx, ax
                NZ      bx
                CHK     n_dst_new, ax, 1

                ;; row r maps i to i + r
                mov     cx, 64*256
                xor     bx, bx
@@cm:           mov     al, bl
                add     al, bh
                mov     cmap[bx], al
                inc     bx
                loop    @@cm

                ;;
                ;; one texel per surface pixel, no wrap inside the cell
                ;;
                mov     word ptr parm.sb_lmptr, offset lux
                mov     word ptr parm.sb_lmptr+2, ds
                mov     word ptr parm.sb_lmstride, LM_W
                mov     word ptr parm.sb_lmstride+2, 0
                mov     word ptr parm.sb_cmapptr, offset cmap
                mov     word ptr parm.sb_cmapptr+2, ds

                mov     word ptr parm.sb_au0, 0
                mov     word ptr parm.sb_au0+2, 0
                mov     word ptr parm.sb_av0, 0
                mov     word ptr parm.sb_av0+2, 0
                mov     word ptr parm.sb_du, 0          ;; 1.0 in 16.16
                mov     word ptr parm.sb_du+2, 1
                mov     word ptr parm.sb_dv, 0
                mov     word ptr parm.sb_dv+2, 1

                mov     parm.sb_sw, TEX_W
                mov     parm.sb_sh, TEX_H
                mov     parm.sb_lmw, LM_W
                mov     parm.sb_lmh, LM_H
                mov     parm.sb_shift, 4                ;; stp 16, one span
                mov     parm.sb_msk, TEX_W-1
                mov     parm.sb_vmsk, TEX_H-1

                mov     word ptr parmp, offset parm
                mov     word ptr parmp+2, ds

                invoke  sb_case, 4
                CHK     n_built, ax, 1
                invoke  sb_verify, 16056
                CHK     n_mix, ax, 0

                invoke  sb_case, 255
                CHK     n_built, ax, 1
                invoke  sb_verify, 64
                CHK     n_low, ax, 0

                invoke  sb_case, 0
                CHK     n_built, ax, 1
                invoke  sb_verify, 16320
                CHK     n_high, ax, 0

                invoke  qglSfFree, dst
                invoke  qglSfFree, tex
                ret
tmain           endp
                end
