;; t07z -- the depth buffer as STORAGE, with no filler anywhere near it.
;;
;; First of the depth tests deliberately: if the buffer's shape or its
;; addressing is wrong, every filler test after this one fails for a
;; reason that has nothing to do with the filler. Prove the bytes are
;; where they are claimed to be, then go and write to them.
;;
;; What each case is guarding, since none of it is obvious from the
;; assertion text:
;;
;;   stride  -- x_res is PIXELS and stride is BYTES. An earlier design put
;;              the doubling in x_res, which would have made every clip
;;              and every pget wrong by two with nothing to notice it.
;;   pad     -- an EMS row must not straddle a 16K page, so qglSfNewEx
;;              demands a power-of-two stride. 160 pixels of depth is 320
;;              bytes and 320 is not one. Unpadded, EMS depth is not
;;              merely slow, it cannot be allocated at all.
;;   word    -- the clear is a WORD fill. A byte fill is right only for 0,
;;              and the value that matters after 0 is 0FFFFh: clearing to
;;              "nearest" and drawing nothing is how a depth TEST is
;;              proved to be testing rather than passing everything.
;;   range   -- a mode is a plain 0,1,2 and anything past the last one is
;;              not a mode. It used to be a pre-scaled table offset, where
;;              an ODD value was the impossible one; that is exactly the
;;              coupling that let SURF_EMS drift from 2 to 10 under BASIC's
;;              feet, and it is gone.
;;   attach  -- the buffer belongs to the surface it was made for and is
;;              named nowhere else, so what the accessors do to the field
;;              IS the API. A second one on the same surface is refused
;;              rather than replacing the first under whoever holds it.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglSfZNew     proto   far :dword, :word
qglSfZFree    proto   far :dword
qglSfZClear   proto   far :dword, :word
qglSfZMode    proto   far :dword, :word
qglZScale     proto   far :dword

DST_W           equ     160
DST_H           equ     8

.data
n_new           db      'depth buffer made      $'
n_wide          db      'x_res is pixels        $'
n_stride        db      'stride is twice that   $'
n_high          db      'as tall as its target  $'
n_clear         db      'clear fills WORDS      $'
n_scale         db      'scale returns the old  $'
n_emspad        db      'ems stride padded to 2^$'
n_attach        db      'attached to its surface$'
n_twice         db      'a second one is refused$'
n_mode_set      db      'mode SET takes         $'
n_mode_bad      db      'mode 3 refused, left off$'
n_mode_none     db      'no buffer, no mode     $'
n_detach        db      'free detaches and offs $'
n_freed         db      'and clears the mode    $'

dst             dd      0
zb              dd      0
ems             dd      0
bad             dw      0

.code

;; words in the depth buffer that are not val -- 0 means the clear took
z_const         proc    near private uses bx cx dx si di es,\
                        s:dword, w:word, h:word, val:word

                mov     bad, 0
                xor     si, si
@@row:          cmp     si, h
                jae     @@out
                invoke  qglSfRow, s, si
                mov     di, ax
                mov     es, dx
                mov     cx, w
                mov     ax, val
@@px:           cmp     es:[di], ax
                je      @F
                inc     bad
@@:             add     di, 2
                loop    @@px
                inc     si
                jmp     @@row
@@out:          mov     ax, bad
                ret
z_const         endp


tmain           proc    far public uses bx cx dx si di es

                invoke  qglSfInit

                invoke  qglSfNew, DST_W, DST_H, SURF_CMEM
                SAVEP   dst

                ;;
                ;; 1. shape
                ;;
                invoke  qglSfZNew, dst, SURF_CMEM
                SAVEP   zb
                mov     bx, ax
                or      bx, dx
                NZ      bx
                CHK     n_new, ax, 1

                les     bx, zb
                CHK     n_wide,   es:[bx].Surface.xRes,  DST_W
                CHK     n_stride, es:[bx].Surface.bps, DST_W*2
                CHK     n_high,   es:[bx].Surface.yRes,  DST_H

                ;;
                ;; 2. it is ON the destination, and only one of it
                ;;
                les     bx, dst
                mov     ax, W es:[bx].Surface.zsf+0
                cmp     ax, W zb+0
                jne     @F
                mov     ax, W es:[bx].Surface.zsf+2
                cmp     ax, W zb+2
                jne     @F
                mov     ax, 1
                jmp     short @@att
@@:             xor     ax, ax
@@att:          CHK     n_attach, ax, 1

                invoke  qglSfZNew, dst, SURF_CMEM
                or      ax, dx
                CHK     n_twice, ax, 0

                ;;
                ;; 3. the mode, which lives on the destination too
                ;;
                invoke  qglSfZMode, dst, QGL_Z_SET
                les     bx, dst
                shl     ax, 4                   ;; 1 -> 16, so one CHK
                add     ax, es:[bx].Surface.zmode
                CHK     n_mode_set, ax, 16 + QGL_Z_SET

                invoke  qglSfZMode, dst, QGL_Z_TEST+1
                les     bx, dst
                shl     ax, 4
                add     ax, es:[bx].Surface.zmode
                CHK     n_mode_bad, ax, QGL_Z_OFF

                ;;
                ;; 4. the clear writes words, not bytes -- through the
                ;;    destination, which is the only handle there is
                ;;
                invoke  qglSfZClear, dst, 0BEEFh
                invoke  z_const, zb, DST_W, DST_H, 0BEEFh
                CHK     n_clear, ax, 0

                ;;
                ;; 5. the scale hands back what it replaced. It is the
                ;;    projection's, not a surface's, so it stays global.
                ;;
                invoke  qglZScale, 12345678h
                invoke  qglZScale, 0
                CHK     n_scale, ax, 5678h

                ;;
                ;; 6. free detaches, and a surface with no depth takes no
                ;;    mode -- a draw into it cannot be given one either
                ;;
                invoke  qglSfZFree, dst
                les     bx, dst
                mov     ax, W es:[bx].Surface.zsf+0
                or      ax, W es:[bx].Surface.zsf+2
                CHK     n_detach, ax, 0
                CHK     n_freed,  es:[bx].Surface.zmode, QGL_Z_OFF

                invoke  qglSfZMode, dst, QGL_Z_SET
                les     bx, dst
                shl     ax, 4
                add     ax, es:[bx].Surface.zmode
                CHK     n_mode_none, ax, QGL_Z_OFF

                ;;
                ;; 7. EMS: 320 bytes a row is not a power of two, so the
                ;;    stride has to be padded or nothing is allocated
                ;;
                invoke  qglSfZNew, dst, SURF_EMS
                SAVEP   ems
                mov     bx, ax
                or      bx, dx
                jz      @F
                les     bx, ems
                mov     ax, es:[bx].Surface.bps
                jmp     @@chk
@@:             xor     ax, ax
@@chk:          CHK     n_emspad, ax, 512

                invoke  qglSfZFree, dst
                invoke  qglSfFree, dst
                ret
tmain           endp
                end
