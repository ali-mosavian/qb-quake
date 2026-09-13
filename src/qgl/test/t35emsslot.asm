;; t35emsslot -- a surface row read through a window slot must be that
;; surface's OWN bytes, after somebody else has mapped the same slot.
;;
;; dctems kept a private per-slot record of which page it had put there
;; and answered a matching request with no map at all. Everything that
;; maps a slot through a plain qglGemMap -- snd.c's loader, snd_mix.c
;; once a frame, mdl.c, d_alias.c, ar.asm -- leaves that record standing
;; and wrong, and the next read through the slot hands back a window
;; holding the other owner's page. It is silent: the bytes are a
;; plausible record of the wrong thing. On e1m1 it made the geometry
;; store's rows 28 and 29 read back as sound samples, so a face's luxel
;; grid came out 61459 wide and _fmemcpy walked a 1024-byte buffer
;; through BSS and the stack into a return address of zero.
;;
;; The record belongs to gem, which owns the mapping. Here the
;; interloper is a second handle, which is all it takes.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglSfRdRowEx  proto   far :dword, :word, :word
qglSfWrRowEx  proto   far :dword, :word, :word

SLOT            equ     2
SFW             equ     64
SFH             equ     512                     ;; 32768 bytes: two EMS pages
MARK0           equ     55h                     ;; row 0,   page 0
MARK1           equ     0AAh                    ;; row 256, page 1
OTHER           equ     3Ch                     ;; the interloper's byte

.data
n_sf            db      'ems surface made       $'
n_hb            db      'second handle          $'
n_own0          db      'row 0 reads its own    $'
n_own1          db      'row 256 reads its own  $'
n_after0        db      'row 0 after interloper $'
n_after1        db      'row 256 after it too   $'

sf              dd      0
hB              dw      0

.code

tmain           proc    far public uses bx cx dx si di es

                invoke  qglSfInit

                invoke  qglSfNew, SFW, SFH, SURF_EMS
                SAVEP   sf
                NZ      dx      ;; a Surface is at offset 0 of its own segment
                CHK     n_sf, ax, 1

                ;; a distinct byte in each of the surface's two pages
                invoke  qglSfWrRowEx, sf, 0, SLOT
                mov     es, dx
                mov     di, ax
                mov     byte ptr es:[di], MARK0

                invoke  qglSfWrRowEx, sf, 256, SLOT
                mov     es, dx
                mov     di, ax
                mov     byte ptr es:[di], MARK1

                invoke  qglSfRdRowEx, sf, 0, SLOT
                mov     es, dx
                mov     di, ax
                mov     al, es:[di]
                xor     ah, ah
                CHK     n_own0, ax, MARK0

                invoke  qglSfRdRowEx, sf, 256, SLOT
                mov     es, dx
                mov     di, ax
                mov     al, es:[di]
                xor     ah, ah
                CHK     n_own1, ax, MARK1

                ;; somebody else takes the window -- the mixer's shape,
                ;; and it never tells this module
                invoke  qglGemAlloc, 16384
                mov     hB, ax
                NZ      ax
                CHK     n_hb, ax, 1

                invoke  qglGemMap, hB, 0, SLOT
                mov     es, ax
                mov     byte ptr es:[0], OTHER

                ;; row 256 was the last one this module mapped there, so
                ;; its record is what a stale one answers with
                invoke  qglSfRdRowEx, sf, 256, SLOT
                mov     es, dx
                mov     di, ax
                mov     al, es:[di]
                xor     ah, ah
                CHK     n_after1, ax, MARK1

                invoke  qglSfRdRowEx, sf, 0, SLOT
                mov     es, dx
                mov     di, ax
                mov     al, es:[di]
                xor     ah, ah
                CHK     n_after0, ax, MARK0

                invoke  qglGemFree, hB
                invoke  qglSfFree, sf

                ret
tmain           endp
                end
