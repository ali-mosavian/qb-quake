;; t12clip -- nothing draws outside its surface.
;;
;; Every case is checked the same way: the surface under test is filled
;; with a known byte and a GUARD surface is allocated straight after it
;; and filled with another. An operation aimed out of range must leave
;; both untouched -- the guard because writing past the last row lands in
;; whatever was allocated next, and the surface itself because writing
;; past the last column lands in the next row of the same block, which a
;; guard alone would never see.
;;
;; That second half matters: the row-to-row overrun is the quiet one. It
;; keeps every byte inside the allocation, so nothing faults and nothing
;; downstream complains; the picture simply grows a wrong pixel.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglDrFill     proto   far :dword, :word, :word, :word, :word, :word
qglTxtLoad    proto   far :dword
qglTxtStr     proto   far :dword, :word, :word, :dword, :dword, :word
qglClRect     proto   far :word, :word, :word, :word
qglRsTex      proto   far :dword
qglRsMode     proto   far :word
qglRsPoly     proto   far :dword, :dword, :word

SFW             equ     64
SFH             equ     16
GDH             equ     64      ;; the guard is tall: an overrun jumps far
FILLB           equ     011h
GUARDB          equ     0A5h

.data
n_psetx         db      'pset past the last col $'
n_psety         db      'pset past the last row $'
n_pgetx         db      'pget past the edge is 0$'
n_txtr          db      'text off the right edge$'
n_txtb          db      'text off the bottom    $'
n_poly          db      'polygon past the edge  $'
n_guard         db      'guard survives it all  $'

fname           db      "font.fnt",0
fnp             dd      0
fnt             dd      0
sf              dd      0
guard           dd      0
tex             dd      0
pp              dd      0
msg             db      "MMMM$"
msgp            dd      0
sum0            dw      0

;; reaches well past the right edge and below the bottom
poly            QVert   <40.0, 4.0,  1.0, 0.0, 0.0>
                QVert   <200.0, 6.0, 1.0, 1.0, 0.0>
                QVert   <180.0, 40.0,1.0, 1.0, 1.0>
                QVert   <30.0, 30.0, 1.0, 0.0, 1.0>

.code

;; every byte of p added up
sums            proc    near private uses bx cx dx si di es,\
                        p:dword, w:word, h:word
                mov     sum0, 0
                xor     si, si
@@row:          cmp     si, h
                jae     @@out
                invoke  qglSfRdRow, p, si
                mov     di, ax
                mov     es, dx
                mov     cx, w
@@px:           mov     al, es:[di]
                xor     ah, ah
                add     sum0, ax
                inc     di
                loop    @@px
                inc     si
                jmp     @@row
@@out:          mov     ax, sum0
                ret
sums            endp

;; bytes of the guard that are no longer GUARDB
gfill           proc    near private
                invoke  qglDrFill, guard, 0, 0, SFW-1, GDH-1, GUARDB
                ret
gfill           endp

;; pixels in columns 0..w-1 of sf that are no longer FILLB. A glyph that
;; runs off the RIGHT edge lands in the next row's LEFT columns, so this
;; is the only place the overrun shows.
colchk          proc    near private uses bx cx dx si di es,\
                        w:word
                mov     sum0, 0
                xor     si, si
@@row:          cmp     si, SFH
                jae     @@out
                invoke  qglSfRdRow, sf, si
                mov     di, ax
                mov     es, dx
                mov     cx, w
@@px:           cmp     byte ptr es:[di], FILLB
                je      @F
                inc     sum0
@@:             inc     di
                loop    @@px
                inc     si
                jmp     @@row
@@out:          mov     ax, sum0
                ret
colchk          endp

gchk            proc    near private uses bx cx dx si di es
                mov     sum0, 0
                xor     si, si
@@row:          cmp     si, GDH
                jae     @@out
                invoke  qglSfRdRow, guard, si
                mov     di, ax
                mov     es, dx
                mov     cx, SFW
@@px:           cmp     byte ptr es:[di], GUARDB
                je      @F
                inc     sum0
@@:             inc     di
                loop    @@px
                inc     si
                jmp     @@row
@@out:          mov     ax, sum0
                ret
gchk            endp


tmain           proc    far public uses bx cx dx si di es

                invoke  qglSfInit
                invoke  qglSfNew, SFW, SFH, SURF_CMEM
                SAVEP   sf
                invoke  qglSfNew, SFW, GDH, SURF_CMEM
                SAVEP   guard
                invoke  qglSfNew, 8, 8, SURF_CMEM
                SAVEP   tex

                mov     word ptr pp, offset poly
                mov     word ptr pp+2, ds
                mov     word ptr msgp, offset msg
                mov     word ptr msgp+2, ds
                mov     word ptr fnp, offset fname
                mov     word ptr fnp+2, ds

                invoke  qglDrFill, tex, 0, 0, 7, 7, 99
                invoke  qglDrFill, guard, 0, 0, SFW-1, GDH-1, GUARDB

                ;;
                ;; 1. a pixel past the last column lands in the next ROW,
                ;;    inside the same allocation, where no guard can see it
                ;;
                invoke  qglDrFill, sf, 0, 0, SFW-1, SFH-1, FILLB
                invoke  sums, sf, SFW, SFH
                mov     bx, ax
                invoke  qglSfPset, sf, SFW+4, 0, 0FFh
                invoke  sums, sf, SFW, SFH
                CHK     n_psetx, ax, bx

                ;;
                ;; 2. and past the last row lands outside it entirely
                ;;
                invoke  gfill
                invoke  qglSfPset, sf, 0, SFH+40, 0FFh
                invoke  gchk
                CHK     n_psety, ax, 0

                ;;
                ;; 3. reading out of range answers, it does not wander
                ;;
                invoke  qglSfPget, sf, SFW+4, SFH+40
                CHK     n_pgetx, ax, 0

                ;;
                ;; 4. text at the edges
                ;;
                invoke  qglTxtLoad, fnp
                SAVEP   fnt
                invoke  qglDrFill, sf, 0, 0, SFW-1, SFH-1, FILLB
                invoke  sums, sf, SFW, SFH
                mov     bx, ax
                invoke  gfill
                invoke  qglTxtStr, sf, SFW-2, 0, fnt, msgp, 0FFh
                invoke  colchk, 8               ;; the far side, untouched
                mov     cx, ax
                invoke  gchk
                add     ax, cx
                CHK     n_txtr, ax, 0

                invoke  qglDrFill, sf, 0, 0, SFW-1, SFH-1, FILLB
                invoke  gfill
                invoke  qglTxtStr, sf, 0, SFH-2, fnt, msgp, 0FFh
                invoke  gchk                    ;; below the last row
                CHK     n_txtb, ax, 0

                ;;
                ;; 5. a polygon reaching well past both edges
                ;;
                invoke  qglRsTex, tex
                invoke  qglRsMode, QGL_M_TEX
                invoke  qglClRect, 0, 0, SFW-1, SFH-1
                invoke  qglDrFill, sf, 0, 0, SFW-1, SFH-1, FILLB
                invoke  gfill
                invoke  qglRsPoly, sf, pp, 4
                invoke  gchk
                CHK     n_poly, ax, 0

                invoke  gchk
                CHK     n_guard, ax, 0
                ret
tmain           endp
                end
