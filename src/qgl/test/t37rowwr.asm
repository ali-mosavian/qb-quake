;; t37rowwr -- qglRowWriteEx writes the caller's row, masked or not.
;;
;; It loaded bp with the surface's dispatch offset and only then read
;; `buff` and `opt`, both bp-relative: the row came from whatever sat at
;; typ plus the parameter's offset, and the mask test read garbage too.
;; sc_selftest's page-edge check read -12 on every run for that reason,
;; so none of the surface cache's later checks ever ran.
;;
;; Both kinds, since typ is the offset into the dispatch table and so the
;; garbage differs: a walking row at (5,3) must read back pixel for pixel,
;; and a row of 0 and 55h written with mask 0 over 11h must leave the 0s
;; as 11h.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglRowWriteEx   proto   far :dword, :word, :word, :word, :word, :dword, :word

SF_W            equ     64
SF_H            equ     16
ROW_N           equ     32
ROW_X           equ     5
ROW_Y           equ     3
MASK_Y          equ     4
UNDER           equ     11h

.data
n_mem_new       db      'mem surface made       $'
n_ems_new       db      'ems surface made       $'
n_mem_plain     db      'mem row reads back     $'
n_mem_masked    db      'mem masked row         $'
n_ems_plain     db      'ems row reads back     $'
n_ems_masked    db      'ems masked row         $'

sf              dd      0
bufp            dd      0

.data?
buf             db      ROW_N dup (?)

.code

;;::::::::::::::
;; ax = pixels of the plain row at (ROW_X, ROW_Y) that differ from buf
;;::::::::::::::
rw_plain        proc    near private uses bx cx si di

                xor     si, si
@@fill:         mov     ax, si
                imul    ax, 7
                add     ax, 3
                mov     buf[si], al
                inc     si
                cmp     si, ROW_N
                jb      @@fill

                invoke  qglRowWriteEx, sf, ROW_X, ROW_Y, ROW_N, 0, bufp, 0

                xor     di, di                  ;; mismatches
                xor     si, si
@@chk:          mov     bx, si
                add     bx, ROW_X
                invoke  qglSfPget, sf, bx, ROW_Y
                cmp     al, buf[si]
                je      @F
                inc     di
@@:             inc     si
                cmp     si, ROW_N
                jb      @@chk
                mov     ax, di
                ret
rw_plain        endp

;;::::::::::::::
;; ax = pixels of the masked row that came out wrong: even x keeps UNDER,
;; odd x is 55h
;;::::::::::::::
rw_masked       proc    near private uses bx cx si di

                xor     si, si
@@fill:         invoke  qglSfPset, sf, si, MASK_Y, UNDER
                mov     al, 0
                test    si, 1
                jz      @F
                mov     al, 55h
@@:             mov     buf[si], al
                inc     si
                cmp     si, ROW_N
                jb      @@fill

                invoke  qglRowWriteEx, sf, 0, MASK_Y, ROW_N, 0, bufp, 0FF00h

                xor     di, di
                xor     si, si
@@chk:          invoke  qglSfPget, sf, si, MASK_Y
                mov     cl, UNDER
                test    si, 1
                jz      @F
                mov     cl, 55h
@@:             cmp     al, cl
                je      @F
                inc     di
@@:             inc     si
                cmp     si, ROW_N
                jb      @@chk
                mov     ax, di
                ret
rw_masked       endp


tmain           proc    far public uses bx cx dx si di es

                invoke  qglSfInit

                mov     word ptr bufp, offset buf
                mov     word ptr bufp+2, ds

                invoke  qglSfNew, SF_W, SF_H, SURF_CMEM
                SAVEP   sf
                mov     bx, dx
                or      bx, ax
                NZ      bx
                CHK     n_mem_new, ax, 1
                invoke  rw_plain
                CHK     n_mem_plain, ax, 0
                invoke  rw_masked
                CHK     n_mem_masked, ax, 0
                invoke  qglSfFree, sf

                invoke  qglSfNew, SF_W, SF_H, SURF_EMS
                SAVEP   sf
                mov     bx, dx
                or      bx, ax
                NZ      bx
                CHK     n_ems_new, ax, 1
                invoke  rw_plain
                CHK     n_ems_plain, ax, 0
                invoke  rw_masked
                CHK     n_ems_masked, ax, 0
                invoke  qglSfFree, sf

                ret
tmain           endp
                end
