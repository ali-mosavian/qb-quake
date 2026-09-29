;; t41sbguard -- a logical cache rectangle remains clean at rendered edges.
;;
;; The 48x48 core lives in a reused, poison-filled 64x64 cache class.
;; qgl's masked affine and perspective samplers see the cache exactly as
;; d_faces does: UVs are normalised by the padded class, not the core.
;; The builder's duplicated far row and column must keep poison out of the
;; rendered 48x48 square.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglSbBuild    proto   far :dword, :dword, :dword
qglDrFill     proto   far :dword, :word, :word, :word, :word, :word
qglClRect     proto   far :word, :word, :word, :word
qglRsPoly     proto   far :dword, :dword, :word, :word, :dword
qglRsPolyBound proto  far :dword, :dword, :word, :word, :dword, :word, :word

DIM             equ     64
CORE            equ     48
LM_W            equ     4
LM_H            equ     4
GOOD            equ     7
FARCOL          equ     31
POISON          equ     99

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
n_build         db      'guarded cache built    $'
n_affine        db      'affine edge has no poison$'
n_persp         db      'persp edge has no poison $'
n_persp_draw    db      'persp quad draws pixels $'
n_low_wrap      db      'negative u clamps at zero$'
n_low_draw      db      'clamped quad draws pixels$'
n_plain_wrap    db      'ordinary texture still wraps$'
n_end_low       db      'later endpoint clamps low $'
n_end_draw      db      'endpoint quad draws pixels$'
n_high_clamp    db      'endpoint clamps logical max$'
n_high_draw     db      'upper clamp reaches far edge$'

quad            QVert   <8.0,  8.0,  1.0, 0.0,  0.0>
                QVert   <56.0, 8.0,  1.0, 0.75, 0.0>
                QVert   <56.0, 56.0, 1.0, 0.75, 0.75>
                QVert   <8.0,  56.0, 1.0, 0.0,  0.75>
trap            QVert   <8.0,  8.0,  1.0, 0.0,     0.0>
                QVert   <56.0, 18.0, 0.25, 0.1875, 0.0>
                QVert   <56.0, 46.0, 0.25, 0.1875, 0.1875>
                QVert   <8.0,  56.0, 1.0, 0.0,     0.75>
lowtrap         QVert   <8.0,  8.0,  1.0,  -0.015625,   0.0>
                QVert   <56.0, 18.0, 0.25, -0.00390625, 0.0>
                QVert   <56.0, 46.0, 0.25, -0.00390625, 0.125>
                QVert   <8.0,  56.0, 1.0,  -0.015625,   0.5>
endtrap         QVert   <8.0,  8.0,  1.0,  0.015625,  0.0>
                QVert   <56.0, 8.0,  1.0, -0.109375,  0.0>
                QVert   <56.0, 56.0, 1.0, -0.109375,  0.5>
                QVert   <8.0,  56.0, 1.0,  0.015625,  0.5>
hightrap        QVert   <8.0,  8.0,  1.0,  0.765625,   0.0>
                QVert   <56.0, 18.0, 0.25, 0.19140625, 0.0>
                QVert   <56.0, 46.0, 0.25, 0.19140625, 0.125>
                QVert   <8.0,  56.0, 1.0,  0.765625,   0.5>
quadp           dd      0

src             dd      0
cache           dd      0
dst             dd      0
parmp           dd      0

.data?
parm            SBPARM  <>
cmap            db      256 dup (?)
lux             db      LM_W*LM_H dup (?)

.code

count_good      proc    near private uses bx cx dx si di es
                xor     bx, bx
                xor     si, si
@@row:          cmp     si, DIM
                jae     @@out
                xor     di, di
@@col:          cmp     di, DIM
                jae     @@next
                invoke  qglSfPget, dst, di, si
                and     ax, 0FFh
                cmp     ax, GOOD
                jne     @F
                inc     bx
@@:             inc     di
                jmp     @@col
@@next:         inc     si
                jmp     @@row
@@out:          mov     ax, bx
                ret
count_good      endp

count_poison    proc    near private uses bx cx dx si di es
                xor     bx, bx
                xor     si, si
@@row:          cmp     si, DIM
                jae     @@out
                xor     di, di
@@col:          cmp     di, DIM
                jae     @@next
                invoke  qglSfPget, dst, di, si
                and     ax, 0FFh
                cmp     ax, POISON
                jne     @F
                inc     bx
@@:             inc     di
                jmp     @@col
@@next:         inc     si
                jmp     @@row
@@out:          mov     ax, bx
                ret
count_poison    endp

count_far       proc    near private uses bx cx dx si di es
                xor     bx, bx
                xor     si, si
@@row:          cmp     si, DIM
                jae     @@out
                xor     di, di
@@col:          cmp     di, DIM
                jae     @@next
                invoke  qglSfPget, dst, di, si
                and     ax, 0FFh
                cmp     ax, FARCOL
                jne     @F
                inc     bx
@@:             inc     di
                jmp     @@col
@@next:         inc     si
                jmp     @@row
@@out:          mov     ax, bx
                ret
count_far       endp

tmain           proc    far public uses bx cx dx si di es
                invoke  qglSfInit
                invoke  qglSfNew, DIM, DIM, SURF_CMEM
                SAVEP   src
                invoke  qglSfNew, DIM, DIM, SURF_EMS
                SAVEP   cache
                invoke  qglSfNew, DIM, DIM, SURF_CMEM
                SAVEP   dst

                invoke  qglDrFill, src, 0, 0, DIM-1, DIM-1, GOOD
                invoke  qglDrFill, cache, 0, 0, DIM-1, DIM-1, POISON

                mov     cx, 256
                xor     bx, bx
@@cm:           mov     cmap[bx], bl
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
                mov     D parm.sb_au0, 0
                mov     D parm.sb_av0, 0
                mov     D parm.sb_du, 10000h
                mov     D parm.sb_dv, 10000h
                mov     parm.sb_sw, CORE
                mov     parm.sb_sh, CORE
                mov     parm.sb_lmw, LM_W
                mov     parm.sb_lmh, LM_H
                mov     parm.sb_shift, 4
                mov     parm.sb_msk, DIM-1
                mov     parm.sb_vmsk, DIM-1
                mov     word ptr parmp, offset parm
                mov     word ptr parmp+2, ds

                invoke  qglSbBuild, cache, src, parmp
                CHK     n_build, ax, 1

                mov     word ptr quadp, offset quad
                mov     word ptr quadp+2, ds
                invoke  qglClRect, 0, 0, DIM-1, DIM-1

                invoke  qglDrFill, dst, 0, 0, DIM-1, DIM-1, 0
                invoke  qglRsPoly, dst, quadp, 4, QGL_M_TEX, cache
                invoke  count_good
                CHK     n_affine, ax, CORE*CORE

                invoke  qglDrFill, dst, 0, 0, DIM-1, DIM-1, 0
                mov     word ptr quadp, offset trap
                invoke  qglRsPoly, dst, quadp, 4, QGL_M_PTEX, cache
                invoke  count_poison
                CHK     n_persp, ax, 0
                invoke  count_good
                NZ      ax
                CHK     n_persp_draw, ax, 1

                ;; Quake clamps the start of a perspective span at zero.
                ;; qgl's masked sampler used to turn -0.5 into class-1,
                ;; where the far-edge padding lives.
                invoke  qglDrFill, src, 0, 0, DIM-1, DIM-1, GOOD
                invoke  qglDrFill, src, CORE-1, 0, CORE-1, DIM-1, FARCOL
                invoke  qglDrFill, cache, 0, 0, DIM-1, DIM-1, POISON
                invoke  qglSbBuild, cache, src, parmp
                CHK     n_build, ax, 1

                invoke  qglDrFill, dst, 0, 0, DIM-1, DIM-1, 0
                mov     word ptr quadp, offset lowtrap
                invoke  qglRsPoly, dst, quadp, 4, QGL_M_PTEX, cache
                invoke  count_far
                NZ      ax
                CHK     n_plain_wrap, ax, 1

                invoke  qglDrFill, dst, 0, 0, DIM-1, DIM-1, 0
                invoke  qglRsPolyBound, dst, quadp, 4, QGL_M_PTEX, cache, CORE, CORE
                invoke  count_far
                CHK     n_low_wrap, ax, 0
                invoke  count_good
                NZ      ax
                CHK     n_low_draw, ax, 1

                ;; The start is in range; only a later 16-pixel endpoint
                ;; crosses below zero. Quake clamps before deriving the
                ;; negative step so its last pixels cannot wrap.
                invoke  qglDrFill, dst, 0, 0, DIM-1, DIM-1, 0
                mov     word ptr quadp, offset endtrap
                invoke  qglRsPolyBound, dst, quadp, 4, QGL_M_PTEX, cache, CORE, CORE
                invoke  count_far
                CHK     n_end_low, ax, 0
                invoke  count_good
                NZ      ax
                CHK     n_end_draw, ax, 1

                ;; Direct physical class: the logical far edge is FARCOL
                ;; and everything beyond it is poison. Only an upper
                ;; endpoint clamp can keep the sample on column 47.
                invoke  qglDrFill, cache, 0, 0, DIM-1, DIM-1, POISON
                invoke  qglDrFill, cache, 0, 0, CORE-2, DIM-1, GOOD
                invoke  qglDrFill, cache, CORE-1, 0, CORE-1, DIM-1, FARCOL
                invoke  qglDrFill, dst, 0, 0, DIM-1, DIM-1, 0
                mov     word ptr quadp, offset hightrap
                invoke  qglRsPolyBound, dst, quadp, 4, QGL_M_PTEX, cache, CORE, CORE
                invoke  count_poison
                CHK     n_high_clamp, ax, 0
                invoke  count_far
                NZ      ax
                CHK     n_high_draw, ax, 1

                invoke  qglSfFree, dst
                invoke  qglSfFree, cache
                invoke  qglSfFree, src
                ret
tmain           endp
                end
