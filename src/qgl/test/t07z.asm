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
;;   pad     -- an EMS row must not straddle a 16K page, so qgl_sf_new_ex
;;              demands a power-of-two stride. 160 pixels of depth is 320
;;              bytes and 320 is not one. Unpadded, EMS depth is not
;;              merely slow, it cannot be allocated at all.
;;   word    -- the clear is a WORD fill. A byte fill is right only for 0,
;;              and the value that matters after 0 is 0FFFFh: clearing to
;;              "nearest" and drawing nothing is how a depth TEST is
;;              proved to be testing rather than passing everything.
;;   odd     -- the mode constants are pre-scaled table offsets, so an odd
;;              value is not a mode however small. Accepting one would
;;              index the filler table between its entries.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qgl_z_new       proto   far :dword, :word, :word
qgl_z_set       proto   far :dword
qgl_z_free      proto   far :dword
qgl_z_clear     proto   far :word
qgl_z_mode      proto   far :word
qgl_z_scale     proto   far :dword

DST_W           equ     160
DST_H           equ     8

.data
n_new           db      'depth buffer made      $'
n_wide          db      'x_res is pixels        $'
n_stride        db      'stride is twice that   $'
n_high          db      'as tall as its target  $'
n_set           db      'installs               $'
n_mode0         db      'mode starts off        $'
n_mode1         db      'mode reads back        $'
n_odd           db      'refuses an odd mode    $'
n_nobuf         db      'no buffer forces off   $'
n_clear         db      'clear fills WORDS      $'
n_scale         db      'scale returns the old  $'
n_emspad        db      'ems stride padded to 2^$'

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
                invoke  qgl_sf_row, s, si
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

                invoke  qgl_sf_init

                invoke  qgl_sf_new, DST_W, DST_H, SURF_CMEM, 0
                SAVEP   dst

                ;;
                ;; 1. shape
                ;;
                invoke  qgl_z_new, dst, SURF_CMEM, 0
                SAVEP   zb
                mov     bx, ax
                or      bx, dx
                NZ      bx
                CHK     n_new, ax, 1

                les     bx, zb
                CHK     n_wide,   es:[bx].Surface.x_res,  DST_W
                CHK     n_stride, es:[bx].Surface.stride, DST_W*2
                CHK     n_high,   es:[bx].Surface.y_res,  DST_H

                ;;
                ;; 2. install, and the mode it starts in
                ;;
                invoke  qgl_z_set, zb
                CHK     n_set, ax, 1

                invoke  qgl_z_mode, QGL_Z_TEST  ;; returns the PREVIOUS
                CHK     n_mode0, ax, QGL_Z_OFF

                invoke  qgl_z_mode, QGL_Z_SET
                CHK     n_mode1, ax, QGL_Z_TEST

                ;; an odd value is not a mode: it must be ignored, and the
                ;; mode in force must survive it
                invoke  qgl_z_mode, QGL_Z_SET+1
                invoke  qgl_z_mode, QGL_Z_OFF
                CHK     n_odd, ax, QGL_Z_SET

                ;;
                ;; 3. the clear writes words, not bytes
                ;;
                invoke  qgl_z_clear, 0BEEFh
                invoke  z_const, zb, DST_W, DST_H, 0BEEFh
                CHK     n_clear, ax, 0

                ;;
                ;; 4. the scale hands back what it replaced
                ;;
                invoke  qgl_z_scale, 12345678h
                invoke  qgl_z_scale, 0
                CHK     n_scale, ax, 5678h

                ;;
                ;; 5. with nothing installed, no mode can be set
                ;;
                invoke  qgl_z_set, 0
                invoke  qgl_z_mode, QGL_Z_TEST
                invoke  qgl_z_mode, QGL_Z_TEST
                CHK     n_nobuf, ax, QGL_Z_OFF

                ;;
                ;; 6. EMS: 320 bytes a row is not a power of two, so the
                ;;    stride has to be padded or nothing is allocated
                ;;
                invoke  qgl_z_new, dst, SURF_EMS, 3
                SAVEP   ems
                mov     bx, ax
                or      bx, dx
                jz      @F
                les     bx, ems
                mov     ax, es:[bx].Surface.stride
                jmp     @@chk
@@:             xor     ax, ax
@@chk:          CHK     n_emspad, ax, 512

                invoke  qgl_z_free, zb
                invoke  qgl_sf_free, dst
                ret
tmain           endp
                end
