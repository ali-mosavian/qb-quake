;; t36sbcell -- qglSbBuild wraps u by the cell's WIDTH and v by its
;; HEIGHT, which are no longer the same number.
;;
;; An atlas cell was 64x64 down to 8x8, so one mask served both axes and
;; SBPARM carried one. Cells are the texture's own power-of-two size now,
;; so a 32x8 cell masked on its width alone reads row (y and 31): for
;; y >= 8 that is a row the cell does not have, and the surface comes
;; back carrying whatever is packed after it. The picture is a texture
;; smeared down the face with a seam at its own height -- plausible
;; enough to be read as a mip or a lightmap fault.
;;
;; Rigged for an exact answer: the four luxels form a gradient and the
;; colormap adds its row to the texture byte. The first 16-pixel span
;; therefore also proves that the generic resampler keeps Quake's
;; right-to-left interpolation; the remaining spans hold the right edge.
;; The destination is twice the cell on both axes, so every pixel past
;; the cell is a wrap.
;;
;;      texel = tex(x and 31, y and 7)
;;
;; which no single mask can produce.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglSbBuild    proto   far :dword, :dword, :dword

TEX_W           equ     32
TEX_H           equ     8
DST_W           equ     TEX_W * 2
DST_H           equ     TEX_H * 2
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
n_tex_new       db      'rect tex surface made  $'
n_dst_new       db      'ems dst surface made   $'
n_built         db      'qglSbBuild returned ok $'
n_bytes         db      'wraps 32 wide, 8 high  $'

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
;; Every pixel of the destination against the texture byte that must
;; have produced it. The answer is computed, not looked up, so a builder
;; that wrote the right bytes to the wrong rows cannot agree with it.
;;::::::::::::::
sb_verify       proc    near private uses bx cx dx si di es

                mov     mism, 0
                xor     si, si                  ;; y
@@row:          cmp     si, DST_H
                jae     @@out
                xor     di, di                  ;; x
@@col:          cmp     di, DST_W
                jae     @@next

                invoke  qglSfPget, dst, di, si
                push    ax

                mov     ax, si
                and     ax, TEX_H-1
                mov     cx, TEX_W
                mul     cx
                mov     dx, di
                and     dx, TEX_W-1
                add     ax, dx                  ;; texture byte
                push    ax

                ;; Quake shifts each signed vertical delta FIRST, then
                ;; accumulates it. These two slopes deliberately do not
                ;; divide by 16: left -330 >> 4 = -21; right 264 >> 4 = 16.
                mov     ax, si
                mov     bx, 16
                imul    ax, bx
                add     ax, 15462               ;; right(y)

                cmp     di, 16
                jae     @F                      ;; tail holds right edge
                push    ax
                mov     ax, si
                mov     bx, -21
                imul    ax, bx
                add     ax, 15660               ;; left(y)
                pop     bx                      ;; right(y)
                sub     ax, bx
                sar     ax, 4
                mov     cx, ax                  ;; horizontal step
                mov     bx, 15
                sub     bx, di
                imul    bx, cx
                mov     ax, si
                mov     cx, 16
                imul    ax, cx
                add     ax, 15462
                add     ax, bx
@@:             and     ax, 0FF00h
                shr     ax, 8
                pop     bx
                add     ax, bx
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


tmain           proc    far public uses bx cx dx si di es

                invoke  qglSfInit

                ;;
                ;; the cell: a walking byte over 32x8, so its 256 texels
                ;; are all distinct and a texel off by a row is a
                ;; different value
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

@@:             invoke  qglSfNew, DST_W, DST_H, SURF_EMS
                SAVEP   dst
                mov     bx, dx
                or      bx, ax
                NZ      bx
                CHK     n_dst_new, ax, 1

                ;; row r maps texel i to i + r
                mov     cx, 64*256
                xor     bx, bx
@@cm:           mov     al, bl
                add     al, bh
                mov     cmap[bx], al
                inc     bx
                loop    @@cm

                mov     byte ptr lux[0], 10
                mov     byte ptr lux[1], 13
                mov     byte ptr lux[2], 15
                mov     byte ptr lux[3], 9

                ;;
                ;; one texel per surface pixel, and the surface is twice
                ;; the cell on both axes, so every pixel past the cell is
                ;; a wrap
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

                mov     parm.sb_sw, DST_W
                mov     parm.sb_sh, DST_H
                mov     parm.sb_lmw, LM_W
                mov     parm.sb_lmh, LM_H
                mov     parm.sb_shift, 4
                mov     parm.sb_msk, TEX_W-1
                mov     parm.sb_vmsk, TEX_H-1

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
