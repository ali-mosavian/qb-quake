;; t16line -- general lines terminate and follow one Bresenham decision.
;;
;; The broken loop recomputed e2 after changing err in the x branch. A
;; 144:82 slope then passed the endpoint and ran forever; the suite timeout
;; is therefore part of this regression, while the pixel checks distinguish
;; termination from an early escape.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglDrFill     proto   far :dword, :word, :word, :word, :word, :word
qglDrLine     proto   far :dword, :word, :word, :word, :word, :word

WID             equ     160
HGT             equ     100
COL             equ     47

.data
n_long          db      '144:82 line has pixels $'
n_end           db      '144:82 reaches endpoint$'
n_short         db      '4:2 line has pixels    $'
n_p0            db      '4:2 pixel 0,0          $'
n_p1            db      '4:2 pixel 1,1          $'
n_p2            db      '4:2 pixel 2,1          $'
n_p3            db      '4:2 pixel 3,2          $'
n_p4            db      '4:2 pixel 4,2          $'

sf              dd      0

.code

count_pixels    proc    near private uses bx cx dx si di es
                xor     bx, bx
                xor     si, si
@@row:          cmp     si, HGT
                jae     @@out
                invoke  qglSfRdRow, sf, si
                mov     es, dx
                mov     di, ax
                mov     cx, WID
@@pixel:        cmp     byte ptr es:[di], COL
                jne     @F
                inc     bx
@@:             inc     di
                loop    @@pixel
                inc     si
                jmp     @@row
@@out:          mov     ax, bx
                ret
count_pixels    endp

tmain           proc    far public uses bx cx dx si di es
                invoke  qglSfInit
                invoke  qglSfNew, WID, HGT, SURF_CMEM, 0
                SAVEP   sf

                invoke  qglDrFill, sf, 0, 0, WID-1, HGT-1, 0
                invoke  qglDrLine, sf, 7, 9, 151, 91, COL
                call    count_pixels
                CHK     n_long, ax, 145
                invoke  qglSfPget, sf, 151, 91
                CHK     n_end, ax, COL

                invoke  qglDrFill, sf, 0, 0, WID-1, HGT-1, 0
                invoke  qglDrLine, sf, 0, 0, 4, 2, COL
                call    count_pixels
                CHK     n_short, ax, 5
                invoke  qglSfPget, sf, 0, 0
                CHK     n_p0, ax, COL
                invoke  qglSfPget, sf, 1, 1
                CHK     n_p1, ax, COL
                invoke  qglSfPget, sf, 2, 1
                CHK     n_p2, ax, COL
                invoke  qglSfPget, sf, 3, 2
                CHK     n_p3, ax, COL
                invoke  qglSfPget, sf, 4, 2
                CHK     n_p4, ax, COL

                invoke  qglSfFree, sf
                ret
tmain           endp
                end
