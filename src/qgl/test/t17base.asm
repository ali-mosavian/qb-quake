;; t17base -- every Surface qgl hands out sits at offset 0 of its segment.
;;
;; mgl's accessors read a dc as gs:[DC.field] and gs:[DC_addrTB][si],
;; with no base register, because memAlloc always answers on a paragraph
;; boundary. qgl's transcriptions do the same, so this is the invariant
;; the whole layer rests on -- and it is the one an earlier design broke:
;; qglSfScratch handed out four headers spaced through one block and
;; vga.asm declared its screen as a DGROUP static, which forced a base
;; register through every accessor in qgldc.asm, qglrow.asm and dct/.
;;
;; Checking the pointer alone would not be enough -- a plausible offset
;; and a working surface are different claims -- so each one is USED
;; through the pointer it gave: a pixel written and read back.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglSfNewEx    proto   far :word, :word, :word, :word
qglSfFree     proto   far :dword

SFW             equ     32
SFH             equ     8
VWW             equ     8
VWH             equ     4

.data
n_new           db      'qglSfNew   offset 0    $'
n_new_use       db      'qglSfNew   round trip  $'
n_newex         db      'qglSfNewEx offset 0    $'
n_newex_use     db      'qglSfNewEx round trip  $'
n_view          db      'qglSfViewNew offset 0  $'
n_view_use      db      'qglSfViewNew round trip$'
n_screen        db      'screen     offset 0    $'
n_ems           db      'ems surface offset 0   $'
n_ems_use       db      'ems surface round trip $'

sf              dd      0
sfx             dd      0
vw              dd      0
ems             dd      0

.code
tmain           proc    far public uses bx es

                invoke  qglSfInit

                invoke  qglSfNew, SFW, SFH, SURF_CMEM
                SAVEP   sf
                CHK     n_new, W sf+0, 0
                invoke  qglSfPset, sf, 5, 3, 0A7h
                invoke  qglSfPget, sf, 5, 3
                CHK     n_new_use, ax, 0A7h

                ;; a stride wider than the row -- the depth buffer's shape
                invoke  qglSfNewEx, SFW, SFH, SFW*2, SURF_CMEM
                SAVEP   sfx
                CHK     n_newex, W sfx+0, 0
                invoke  qglSfPset, sfx, 1, 2, 05Ch
                invoke  qglSfPget, sfx, 1, 2
                CHK     n_newex_use, ax, 05Ch

                ;; a view allocates its own header and address table
                invoke  qglSfViewNew, sf, VWW, VWH, VWW
                SAVEP   vw
                CHK     n_view, W vw+0, 0
                invoke  qglSfPset, vw, 2, 1, 03Bh
                invoke  qglSfPget, vw, 2, 1
                CHK     n_view_use, ax, 03Bh

                ;; the screen: allocated now, not a DGROUP static
                invoke  qglVgaScreen
                CHK     n_screen, ax, 0

                ;; and the EMS back-end, whose accessors index the same
                ;; table through the same fixed read and write pages
                invoke  qglSfNew, 64, 8, SURF_EMS
                SAVEP   ems
                CHK     n_ems, W ems+0, 0
                invoke  qglSfPset, ems, 63, 7, 0E1h
                invoke  qglSfPget, ems, 63, 7
                CHK     n_ems_use, ax, 0E1h

                invoke  qglSfFree, ems
                invoke  qglSfFree, sfx
                invoke  qglSfFree, sf
                ret
tmain           endp
                end
