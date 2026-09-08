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
;; THE CASE IS RIGGED TO HAVE AN EXACT ANSWER, because "it returned" is
;; not evidence and a plausible-looking surface is worth nothing:
;;
;;   - every luxel is 245, so SB_LEVEL2T gives t = 16320 - 66*245 = 150,
;;     which is under 256. tleft == tright, so the span is FLAT and
;;     `tleft and 0FF00h` is zero -- the colormap row is row 0.
;;   - the colormap is the IDENTITY, so a texel maps to itself.
;;   - du = dv = 1.0 in 16.16 and msk = 15, so texel (x,y) of a 16-wide
;;     texture lands at (x,y) of the surface.
;;
;; The surface must therefore come back EQUAL TO THE TEXTURE, byte for
;; byte. A wrong segment, a wrong row, a skipped write or a stale pointer
;; all break that equality; none of them can produce it by accident.
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
LEVEL           equ     245             ;; -> t 150, so row 0 and a flat span

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
SBPARM          ends

.data
n_tex_new       db      'tex surface made       $'
n_dst_new       db      'ems dst surface made   $'
n_built         db      'qglSbBuild returned ok $'
n_bytes         db      'surface equals texture $'

tex             dd      0
dst             dd      0
parmp           dd      0
mism            dw      0

.data?
parm            SBPARM  <>
cmap            db      256 dup (?)     ;; identity, only row 0 is reached
lux             db      LM_W*LM_H dup (?)

.code

;;::::::::::::::
;; Every texel of dst against the texture byte that must have produced
;; it. Counting rows that merely CHANGED would pass a builder that wrote
;; one byte a row, so this compares every pixel.
;;::::::::::::::
sb_verify       proc    near private uses bx cx dx si di es

                mov     mism, 0
                xor     si, si                  ;; y
@@row:          cmp     si, TEX_H
                jae     @@out
                xor     di, di                  ;; x
@@col:          cmp     di, TEX_W
                jae     @@next

                invoke  qglSfPget, dst, di, si
                mov     bx, ax

                ;; what the texture holds there: the walking pattern is
                ;; y*TEX_W + x, so the answer is computable, not looked up
                mov     ax, si
                mov     cx, TEX_W
                mul     cx
                add     ax, di
                and     ax, 0FFh

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

                ;; identity colormap, flat luxels
                mov     cx, 256
                xor     bx, bx
@@cm:           mov     al, bl
                mov     cmap[bx], al
                inc     bx
                loop    @@cm

                mov     cx, LM_W*LM_H
                xor     bx, bx
@@lx:           mov     byte ptr lux[bx], LEVEL
                inc     bx
                loop    @@lx

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

                mov     word ptr parmp, offset parm
                mov     word ptr parmp+2, ds
                invoke  qglSbBuild, dst, tex, parmp
                CHK     n_built, ax, 1

                invoke  sb_verify
                CHK     n_bytes, ax, 0

                invoke  qglSfFree, dst
                invoke  qglSfFree, tex
                ret
tmain           endp
                end
