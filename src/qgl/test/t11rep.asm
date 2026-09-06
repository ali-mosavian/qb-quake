;; t11rep -- the same polygon must draw the same picture every time, into
;;           any surface.
;;
;; sf2 is drawn FIRST and sf second, the reverse of the allocation order,
;; so a difference that follows the SURFACE can be told apart from one
;; that follows the CALL ORDER. Everything else is held identical: one
;; polygon, one texture, one mode, no depth.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qgl_dr_fill     proto   far :dword, :word, :word, :word, :word, :word
qgl_cl_rect     proto   far :word, :word, :word, :word
qgl_rs_tex      proto   far :dword
qgl_rs_flat     proto   far :word
qgl_rs_mode     proto   far :word
qgl_rs_ref      proto   far :word
qgl_rs_poly     proto   far :dword, :dword, :word

SFW             equ     64
SFH             equ     64

.data
n_l2            db      'same surface: lines    $'
n_s2            db      'same surface: picture  $'
n_l3            db      'other surface: lines   $'
n_s3            db      'other surface: picture $'
n_t1            db      'texture intact at start$'
n_t2            db      'texture intact at end  $'
n_e2            db      'sf  row27 cnt:last:frst$'
n_r2            db      'sf2 row27 seg:ofs      $'

poly            QVert   <12.0, 6.0,  1.00, 0.0, 0.0>
                QVert   <52.0, 18.0, 0.80, 1.0, 0.0>
                QVert   <44.0, 55.0, 0.55, 1.0, 1.0>
                QVert   <9.0,  41.0, 0.90, 0.0, 1.0>

sf              dd      0
sf2             dd      0
tx              dd      0
pp              dd      0
sum             dw      0
sum1            dw      0
lines1          dw      0

.code

chksum          proc    near private uses bx cx dx si di es,\
                        p:dword, w:word, h:word
                mov     sum, 0
                xor     si, si
@@row:          cmp     si, h
                jae     @@out
                invoke  qgl_sf_row, p, si
                mov     di, ax
                mov     es, dx
                mov     cx, w
@@px:           mov     al, es:[di]
                xor     ah, ah
                add     sum, ax
                inc     di
                loop    @@px
                inc     si
                jmp     @@row
@@out:          mov     ax, sum
                ret
chksum          endp

;; bytes of p that are NOT val
cntne           proc    near private uses bx cx dx si di es,\
                        p:dword, w:word, h:word, val:word
                mov     sum, 0
                xor     si, si
@@row:          cmp     si, h
                jae     @@out
                invoke  qgl_sf_row, p, si
                mov     di, ax
                mov     es, dx
                mov     cx, w
                mov     bl, byte ptr val
@@px:           cmp     es:[di], bl
                je      @F
                inc     sum
@@:             inc     di
                loop    @@px
                inc     si
                jmp     @@row
@@out:          mov     ax, sum
                ret
cntne           endp

;; row `yy` of p: (count<<16) | (last<<8) | first, over non-zero pixels


tmain           proc    far public uses bx cx dx si di es

                invoke  qgl_sf_init
                invoke  qgl_sf_new, SFW, SFH, SURF_CMEM, 0
                SAVEP   sf
                invoke  qgl_sf_new, SFW, SFH, SURF_CMEM, 0
                SAVEP   sf2
                invoke  qgl_sf_new, 8, 8, SURF_CMEM, 0
                SAVEP   tx

                mov     word ptr pp, offset poly
                mov     word ptr pp+2, ds

                invoke  qgl_dr_fill, tx, 0, 0, 7, 7, 99
                invoke  qgl_rs_tex, tx
                invoke  qgl_rs_flat, 37
                invoke  qgl_cl_rect, 0, 0, SFW-1, SFH-1
                invoke  qgl_rs_ref, 0
                invoke  qgl_rs_mode, QGL_M_TEX


                invoke  cntne, tx, 8, 8, 99
                CHK     n_t1, ax, 0

                ;; the SECOND-allocated surface, drawn FIRST
                invoke  qgl_dr_fill, sf2, 0, 0, SFW-1, SFH-1, 0
                invoke  qgl_rs_poly, sf2, pp, 4
                mov     lines1, ax
                invoke  chksum, sf2, SFW, SFH
                mov     sum1, ax

                ;; again, same surface
                invoke  qgl_dr_fill, sf2, 0, 0, SFW-1, SFH-1, 0
                invoke  qgl_rs_poly, sf2, pp, 4
                mov     bx, lines1
                CHK     n_l2, ax, bx
                invoke  chksum, sf2, SFW, SFH
                mov     bx, sum1
                CHK     n_s2, ax, bx

                ;; the FIRST-allocated surface, drawn LAST
                invoke  qgl_dr_fill, sf, 0, 0, SFW-1, SFH-1, 0
                invoke  qgl_rs_poly, sf, pp, 4
                mov     bx, lines1
                CHK     n_l3, ax, bx
                invoke  chksum, sf, SFW, SFH
                mov     bx, sum1
                CHK     n_s3, ax, bx

                invoke  cntne, tx, 8, 8, 99
                CHK     n_t2, ax, 0

                ret
tmain           endp
                end
