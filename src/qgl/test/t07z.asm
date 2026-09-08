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

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglZNew       proto   far :dword, :word
qglZFree      proto   far :dword
qglZClear     proto   far :dword, :word
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
                invoke  qglZNew, dst, SURF_CMEM
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
                ;; 2. the clear writes words, not bytes
                ;;
                invoke  qglZClear, zb, 0BEEFh
                invoke  z_const, zb, DST_W, DST_H, 0BEEFh
                CHK     n_clear, ax, 0

                ;;
                ;; 3. the scale hands back what it replaced
                ;;
                invoke  qglZScale, 12345678h
                invoke  qglZScale, 0
                CHK     n_scale, ax, 5678h

                ;; A null buffer and an out-of-range mode are qglRsPoly's
                ;; to refuse now, not this module's -- there is nothing
                ;; installed to refuse them against. Both are tested where
                ;; they are decided, in t09rs.
                ;;
                ;; 4. EMS: 320 bytes a row is not a power of two, so the
                ;;    stride has to be padded or nothing is allocated
                ;;
                invoke  qglZNew, dst, SURF_EMS
                SAVEP   ems
                mov     bx, ax
                or      bx, dx
                jz      @F
                les     bx, ems
                mov     ax, es:[bx].Surface.bps
                jmp     @@chk
@@:             xor     ax, ax
@@chk:          CHK     n_emspad, ax, 512

                invoke  qglZFree, zb
                invoke  qglSfFree, dst
                ret
tmain           endp
                end
