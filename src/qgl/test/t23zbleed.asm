;; t23zbleed -- a depth-TESTED polygon may only touch its own pixels.
;;
;; The renderer draws the world with QGL_Z_SET and the models on top of it
;; with QGL_Z_TEST, and the second of those was scribbling dark streaks
;; across the whole frame -- far outside the model's own few pixels, and
;; in a different place every frame, so it read as surface-cache churn.
;;
;; The shape here is the renderer's own: a destination the size the game
;; uses (160x100, so the depth row is 320 bytes and not the 128 every
;; other test in this suite gives it), one big polygon written with
;; Z_SET, then a small one on top of it with Z_TEST. Drawing the pair is
;; compared against drawing the big one alone: outside the small
;; polygon's bounding box the two frames have to be identical, whatever
;; the depth test decided inside it.

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

SFW             equ     160
SFH             equ     100

;; the small polygon's box, and the margin the comparison skips
SMX0            equ     60
SMY0            equ     40
SMX1            equ     80
SMY1            equ     56

.data
n_bg            db      'background covers it   $'
n_bleed         db      'ztest stays in its box $'
n_off           db      'zoff  stays in its box $'
n_pbleed        db      'ptex ztest stays too   $'
n_ableed        db      'atex ztest stays too   $'
n_adrew         db      'atex tested draw drew  $'
n_drew          db      'and it drew something  $'
n_tdrew         db      'tested draw drew too   $'

;; far: 1/z small. The world, seen from across a room.
big             QVert   <0.0,   0.0,  0.002, 0.0, 0.0>
                QVert   <159.0, 0.0,  0.002, 1.0, 0.0>
                QVert   <159.0, 99.0, 0.002, 1.0, 1.0>
                QVert   <0.0,   99.0, 0.002, 0.0, 1.0>
bigp            dd      0

;; near: 1/z large, so every pixel of it passes the test against the
;; background above
small           QVert   <62.0, 42.0, 0.020, 0.0, 0.0>
                QVert   <78.0, 42.0, 0.020, 1.0, 0.0>
                QVert   <78.0, 54.0, 0.020, 1.0, 1.0>
                QVert   <62.0, 54.0, 0.020, 0.0, 1.0>
smallp          dd      0

zs              real4   65535.0

sa              dd      0
sb              dd      0
za              dd      0
zbb             dd      0
tx              dd      0
diffs           dw      0
drew            dw      0

.code

;; bytes where two surfaces disagree OUTSIDE the small polygon's box.
;; ds stays DGROUP -- t10ref's own note on why the source goes in fs.
cmpout          proc    near private uses bx cx dx si di fs es,\
                        p:dword, q:dword

                local   po:word
                local   xx:word

                mov     diffs, 0
                xor     si, si
@@row:          cmp     si, SFH
                jae     @@out
                invoke  qglSfRow, p, si
                mov     po, ax
                mov     fs, dx
                invoke  qglSfRow, q, si
                mov     di, ax
                mov     es, dx
                mov     bx, po
                mov     xx, 0
@@px:           cmp     si, SMY0
                jb      @F
                cmp     si, SMY1
                ja      @F
                cmp     xx, SMX0
                jb      @F
                cmp     xx, SMX1
                jbe     @@next                  ;; inside the box: skip
@@:             mov     al, fs:[bx]
                cmp     al, es:[di]
                je      @@next
                inc     diffs
@@next:         inc     bx
                inc     di
                inc     xx
                mov     cx, xx
                cmp     cx, SFW
                jb      @@px
                inc     si
                jmp     @@row
@@out:          mov     ax, diffs
                ret
cmpout          endp

;; bytes of the small polygon's box that differ between the two, which is
;; what says the tested polygon drew at all
cmpin           proc    near private uses bx cx dx si di fs es,\
                        p:dword, q:dword

                local   po:word

                mov     diffs, 0
                mov     si, SMY0
@@row:          cmp     si, SMY1
                ja      @@out
                invoke  qglSfRow, p, si
                mov     po, ax
                mov     fs, dx
                invoke  qglSfRow, q, si
                mov     di, ax
                mov     es, dx
                mov     bx, po
                add     bx, SMX0
                add     di, SMX0
                mov     cx, SMX1-SMX0+1
@@px:           mov     al, fs:[bx]
                cmp     al, es:[di]
                je      @F
                inc     diffs
@@:             inc     bx
                inc     di
                loop    @@px
                inc     si
                jmp     @@row
@@out:          mov     ax, diffs
                ret
cmpin           endp

;; sb = the background alone, sa = the background with the tested polygon
;; over it, both from a cleared depth buffer of their own.
PAIR            macro   ?md, ?zm
                invoke  qglDrFill, sb, 0, 0, SFW-1, SFH-1, 0
                invoke  qglSfZClear, sb, 0
                invoke  qglSfZMode, sb, QGL_Z_SET
                invoke  qglRsPoly, sb, bigp, 4, ?md, tx

                invoke  qglDrFill, sa, 0, 0, SFW-1, SFH-1, 0
                invoke  qglSfZClear, sa, 0
                invoke  qglSfZMode, sa, QGL_Z_SET
                invoke  qglRsPoly, sa, bigp, 4, ?md, tx
                invoke  qglSfZMode, sa, ?zm
                invoke  qglRsPoly, sa, smallp, 4, ?md, tx
endm

tmain           proc    far public uses bx cx dx si di es

                invoke  qglSfInit

                invoke  qglSfNew, SFW, SFH, SURF_CMEM
                SAVEP   sa
                invoke  qglSfNew, SFW, SFH, SURF_CMEM
                SAVEP   sb
                invoke  qglSfNew, 8, 8, SURF_CMEM
                SAVEP   tx

                mov     word ptr bigp, offset big
                mov     word ptr bigp+2, ds
                mov     word ptr smallp, offset small
                mov     word ptr smallp+2, ds

                ;; every texel distinct, so a u or v fault cannot hide
                xor     si, si
@@ty:           cmp     si, 8
                jae     @@tdone
                xor     di, di
@@tx:           cmp     di, 8
                jae     @F
                mov     ax, si
                shl     ax, 3
                add     ax, di
                inc     ax                      ;; never 0: 0 is the fill
                invoke  qglSfPset, tx, di, si, ax
                inc     di
                jmp     @@tx
@@:             inc     si
                jmp     @@ty
@@tdone:
                invoke  qglClRect, 0, 0, SFW-1, SFH-1

                invoke  qglSfZNew, sa, SURF_CMEM
                SAVEP   za
                invoke  qglSfZNew, sb, SURF_CMEM
                SAVEP   zbb
                invoke  qglZScale, dword ptr zs

                ;; the background really is drawn: a frame of zeroes would
                ;; make every comparison below vacuous
                PAIR    QGL_M_TEX, QGL_Z_OFF
                invoke  qglSfPget, sb, 4, 4
                NZ      ax
                CHK     n_bg, ax, 1

                invoke  cmpout, sa, sb
                CHK     n_off, ax, 0
                invoke  cmpin, sa, sb
                mov     drew, ax
                NZ      drew
                CHK     n_drew, ax, 1

                PAIR    QGL_M_TEX, QGL_Z_TEST
                invoke  cmpout, sa, sb
                CHK     n_bleed, ax, 0
                invoke  cmpin, sa, sb
                mov     drew, ax
                NZ      drew
                CHK     n_tdrew, ax, 1

                PAIR    QGL_M_PTEX, QGL_Z_TEST
                invoke  cmpout, sa, sb
                CHK     n_pbleed, ax, 0

                PAIR    QGL_M_ATEX, QGL_Z_TEST
                invoke  cmpout, sa, sb
                CHK     n_ableed, ax, 0
                invoke  cmpin, sa, sb
                NZ      ax
                CHK     n_adrew, ax, 1
                ret
tmain           endp
                end
