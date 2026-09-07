;; t03surf -- write a known pattern through qglSfRow and read it back.
;;
;; The round-trip rule: reading the thing back through its own accessor
;; is what proved the texture atlas correct when the fault was elsewhere.
;; A surface that stores nothing, stores to the wrong row, or wraps at a
;; page or segment boundary all look identical from the outside until
;; something reads them back.
;;
;; Four shapes, and each is here for a reason the others cannot cover:
;;
;;   cmem small   the base case
;;   cmem >64K    the ONLY thing that exercises qgl$RowCmem's segment
;;                arithmetic; every smaller surface fits one segment and
;;                the shift-and-add is dead code
;;   EMS          crosses 16K physical pages, so qgl$row_ems has to remap
;;                mid-surface and hand back a pointer into a new window
;;   view         a caller-owned header aimed at part of a parent's store
;;
;; The pattern is a walking byte, not a constant: a constant cannot tell
;; a correct write from a write to the wrong row, because every row of it
;; looks the same.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglDrFill     proto   far :dword, :word, :word, :word, :word, :word

SMALL_W         equ     64
SMALL_H         equ     16

;; 320 x 220 = 70,400 bytes: past one segment, so row 205 onwards lives
;; beyond 64K of the block's base and only the segment arithmetic finds it
BIG_W           equ     320
BIG_H           equ     220

;; 128 x 256 = 32,768 bytes across two 16K EMS pages. 128 divides 16384 so
;; no row straddles, which qglSfNew enforces anyway.
;;
;; The WIDTH is load-bearing. At 64 wide a page holds exactly 256 rows,
;; and the pattern seed is the row number in a byte -- so every row that
;; a broken page lookup aliases onto another carried the SAME seed, and a
;; surface that always mapped page 0 passed this test cleanly. At 128 a
;; page is 128 rows, aliased rows differ in seed, and the mutation shows.
EMS_W           equ     128
EMS_H           equ     256

.data
n_small_new     db      'cmem surface made      $'
n_small_rt      db      'cmem round trip        $'
n_big_new       db      'cmem >64K made         $'
n_big_rt        db      'cmem >64K round trip   $'
n_big_last      db      'cmem >64K last row     $'
n_ems_new       db      'ems surface made       $'
n_ems_rt        db      'ems round trip         $'
n_ems_cross     db      'ems across a page      $'
n_view_rt       db      'view sees parent rows  $'
n_clear         db      'fill lands on every px $'
n_odd_stride    db      'ems odd stride refused $'

small           dd      0
big             dd      0
ems             dd      0
vw              Surface <>
vwp             dd      0
mism            dw      0

.code

;;::::::::::::::
;; sf_fill -- walking pattern into every row, through qglSfRow.
;; sf_check -- read it back the same way; ax = mismatching rows.
;;
;; Row y starts at seed y so a row written to the wrong place shows up,
;; which a single seed for the whole surface would hide.
;;::::::::::::::
sf_fill         proc    near private uses bx cx dx si di es,\
                        s:dword, w:word, h:word

                xor     si, si
@@row:          cmp     si, h
                jae     @F
                invoke  qglSfRow, s, si
                invoke  tfill, dx, ax, w, si
                inc     si
                jmp     @@row
@@:             ret
sf_fill         endp


sf_check        proc    near private uses bx cx dx si di es,\
                        s:dword, w:word, h:word

                mov     mism, 0
                xor     si, si
@@row:          cmp     si, h
                jae     @F
                invoke  qglSfRow, s, si
                invoke  tvrfy, dx, ax, w, si
                test    ax, ax
                jz      @@next
                inc     mism
@@next:         inc     si
                jmp     @@row
@@:             mov     ax, mism
                ret
sf_check        endp


;; pixels in s that are NOT val -- 0 means the fill covered all of it
sf_const        proc    near private uses bx cx dx si di es,\
                        s:dword, w:word, h:word, val:word

                mov     mism, 0
                xor     si, si
@@row:          cmp     si, h
                jae     @@out
                invoke  qglSfRow, s, si
                mov     di, ax
                mov     es, dx
                mov     cx, w
                mov     al, byte ptr val
@@px:           cmp     es:[di], al
                je      @F
                inc     mism
@@:             inc     di
                loop    @@px
                inc     si
                jmp     @@row
@@out:          mov     ax, mism
                ret
sf_const        endp


tmain           proc    far public uses bx cx dx si di es

                invoke  qglSfInit

                ;;
                ;; 1. conventional, small enough to be uninteresting
                ;;
                invoke  qglSfNew, SMALL_W, SMALL_H, SURF_CMEM, 0
                SAVEP   small
                mov     bx, dx
                or      bx, ax
                NZ      bx
                CHK     n_small_new, ax, 1

                invoke  sf_fill,  small, SMALL_W, SMALL_H
                invoke  sf_check, small, SMALL_W, SMALL_H
                CHK     n_small_rt, ax, 0

                ;;
                ;; 2. conventional, past 64K
                ;;
                invoke  qglSfNew, BIG_W, BIG_H, SURF_CMEM, 0
                SAVEP   big
                mov     bx, dx
                or      bx, ax
                NZ      bx
                CHK     n_big_new, ax, 1

                invoke  sf_fill,  big, BIG_W, BIG_H
                invoke  sf_check, big, BIG_W, BIG_H
                CHK     n_big_rt, ax, 0

                ;; and the last row specifically -- it is the one past the
                ;; segment, so a wrong shift shows here and nowhere else
                invoke  qglSfPset, big, 7, BIG_H-1, 0ABh
                invoke  qglSfPget, big, 7, BIG_H-1
                CHK     n_big_last, ax, 0ABh

                ;;
                ;; 3. EMS, two pages
                ;;
                invoke  qglSfNew, EMS_W, EMS_H, SURF_EMS, 2
                SAVEP   ems
                mov     bx, dx
                or      bx, ax
                NZ      bx
                CHK     n_ems_new, ax, 1

                invoke  sf_fill,  ems, EMS_W, EMS_H
                invoke  sf_check, ems, EMS_W, EMS_H
                CHK     n_ems_rt, ax, 0

                ;; a row in the first page and one in the second, read
                ;; back after each other so the remap has to happen
                invoke  qglSfPset, ems, 3, 10, 055h
                invoke  qglSfPset, ems, 3, 200, 0AAh
                invoke  qglSfPget, ems, 3, 10
                mov     bx, ax
                invoke  qglSfPget, ems, 3, 200
                cmp     ax, 0AAh
                jne     @F
                cmp     bx, 055h
                jne     @F
                mov     ax, 1
                jmp     @@crossed
@@:             xor     ax, ax
@@crossed:      CHK     n_ems_cross, ax, 1

                ;;
                ;; 4. a view onto the big surface, aimed at row 100
                ;;
                mov     word ptr vwp, offset vw
                mov     word ptr vwp+2, ds
                invoke  qglSfView, vwp, big, BIG_W*100, BIG_W, 8, BIG_W
                invoke  qglSfPget, vwp, 5, 0
                mov     bx, ax
                invoke  qglSfPget, big, 5, 100
                cmp     ax, bx
                mov     ax, 0
                jne     @F
                mov     ax, 1
@@:             CHK     n_view_rt, ax, 1

                ;;
                ;; 5. fill the whole surface and require EVERY pixel to be
                ;;    the fill colour. Counting rows that merely CHANGED
                ;;    would pass for a fill that wrote one byte a row.
                ;;
                invoke  qglDrFill, small, 0, 0, SMALL_W-1, SMALL_H-1, 07Eh
                invoke  sf_const, small, SMALL_W, SMALL_H, 07Eh
                CHK     n_clear, ax, 0

                ;;
                ;; 6. an EMS surface whose rows would straddle a page is
                ;;    refused rather than quietly padded
                ;;
                invoke  qglSfNew, 100, 4, SURF_EMS, 3
                mov     bx, dx
                or      bx, ax
                NZ      bx
                CHK     n_odd_stride, ax, 0

                invoke  qglSfFree, ems
                invoke  qglSfFree, big
                invoke  qglSfFree, small
                ret
tmain           endp
                end
