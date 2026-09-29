;; t40sbwrap -- Quake's native block drawer wraps source blocks in u and v.
;;
;; A 64x64 logical surface starts halfway into a 32x32 texture, so both
;; axes cross the cell boundary twice. Removing either block-to-block u
;; wrap or row-to-row v wrap changes the observable bytes.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglSbBuild    proto   far :dword, :dword, :dword

TEX_W           equ     32
TEX_H           equ     32
DST_W           equ     64
DST_H           equ     64
LM_W            equ     5
LM_H            equ     5

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
n_tex           db      'native wrap texture made$'
n_dst           db      'native wrap cache made  $'
n_build         db      'native builder returned $'
n_wrap          db      'native u and v wrap     $'

tex             dd      0
dst             dd      0
parmp           dd      0
mism            dw      0

.data?
parm            SBPARM  <>
cmap            db      256 dup (?)
lux             db      LM_W*LM_H dup (?)

.code

sb_verify       proc    near private uses bx cx dx si di es

                mov     mism, 0
                xor     si, si
@@row:          cmp     si, DST_H
                jae     @@out
                xor     di, di
@@col:          cmp     di, DST_W
                jae     @@next

                invoke  qglSfPget, dst, di, si
                and     ax, 0FFh
                push    ax

                mov     ax, si
                add     ax, 16
                and     ax, TEX_H-1
                mov     cx, 37
                mul     cx
                mov     bx, ax
                mov     ax, di
                add     ax, 16
                and     ax, TEX_W-1
                mov     cx, 5
                mul     cx
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

                invoke  qglSfNew, TEX_W, TEX_H, SURF_CMEM
                SAVEP   tex
                mov     bx, dx
                or      bx, ax
                NZ      bx
                CHK     n_tex, ax, 1

                xor     si, si
@@trow:         cmp     si, TEX_H
                jae     @F
                xor     di, di
@@tcol:         cmp     di, TEX_W
                jae     @@tnext
                mov     ax, si
                mov     cx, 37
                mul     cx
                mov     bx, ax
                mov     ax, di
                mov     cx, 5
                mul     cx
                add     ax, bx
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
                CHK     n_dst, ax, 1

                mov     cx, 256
                xor     bx, bx
@@cm:           mov     al, bl
                mov     cmap[bx], al
                inc     bx
                loop    @@cm

                mov     cx, LM_W*LM_H
                xor     bx, bx
@@lux:          mov     byte ptr lux[bx], 255
                inc     bx
                loop    @@lux

                mov     word ptr parm.sb_lmptr, offset lux
                mov     word ptr parm.sb_lmptr+2, ds
                mov     word ptr parm.sb_lmstride, LM_W
                mov     word ptr parm.sb_lmstride+2, 0
                mov     word ptr parm.sb_cmapptr, offset cmap
                mov     word ptr parm.sb_cmapptr+2, ds
                mov     word ptr parm.sb_au0, 0
                mov     word ptr parm.sb_au0+2, 16
                mov     word ptr parm.sb_av0, 0
                mov     word ptr parm.sb_av0+2, 16
                mov     word ptr parm.sb_du, 0
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
                CHK     n_build, ax, 1
                invoke  sb_verify
                CHK     n_wrap, ax, 0

                invoke  qglSfFree, dst
                invoke  qglSfFree, tex
                ret
tmain           endp
                end
