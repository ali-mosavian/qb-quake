;; t17scr -- the Surfaces qgl hands out to callers that cannot spell one.
;;
;; qglSfAdoptDc fills a Surface the CALLER owns. d_faces.c is the
;; caller and is C, so the sixteen bytes would have to be declared there
;; -- the same fact in two places, with no generator watching it, which
;; is the drift qgl.bi exists to have stopped. qglSfScratch hands out
;; storage instead.
;;
;; THE TEST IS NOT THAT THE POINTERS LOOK RIGHT. Three plausible
;; non-null pointers spaced sixteen apart prove nothing about whether
;; anything may be written there: the arithmetic could name a segment
;; the caller cannot reach, or storage that overlaps something live. So
;; a real surface is copied into a slot and then USED through the slot's
;; own pointer -- written, read back, and the neighbouring slot checked
;; for spill.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglSfScratch  proto   far :word

SFW             equ     32
SFH             equ     8

.data
n_zero          db      'slot 0 exists          $'
n_apart         db      'slots are T Surface apart$'
n_range         db      'past the last is refused$'
n_neg           db      'and so is a negative one$'
n_use           db      'a surface used THROUGH one$'
n_spill         db      'the next slot is untouched$'

s0              dd      0
s1              dd      0
sf              dd      0
mark            db      16 dup (0)

.code

;;:::::::::::::: copy T Surface bytes from one far pointer to another
scopy           proc    near private uses bx cx si di ds es,\
                        dst:dword, src:dword
                lds     si, src
                les     di, dst
                mov     cx, T Surface
                cld
                rep     movsb
                ret
scopy           endp

;;:::::::::::::: the 16 bytes at p, saved into mark
ssave           proc    near private uses bx cx si di ds es,\
                        p:dword
                lds     si, p
                mov     ax, seg mark
                mov     es, ax
                mov     di, offset mark
                mov     cx, T Surface
                cld
                rep     movsb
                ret
ssave           endp

;;:::::::::::::: how many of those 16 bytes have changed since
schk            proc    near private uses bx cx si di es,\
                        p:dword
                xor     dx, dx
                les     di, p
                mov     si, offset mark
                mov     cx, T Surface
@@b:            mov     al, [si]
                cmp     es:[di], al
                je      @F
                inc     dx
@@:             inc     si
                inc     di
                loop    @@b
                mov     ax, dx
                ret
schk            endp


tmain           proc    far public uses bx cx dx si di es

                invoke  qglSfInit

                invoke  qglSfScratch, 0
                SAVEP   s0
                mov     ax, word ptr s0+2
                NZ      ax
                CHK     n_zero, ax, 1

                invoke  qglSfScratch, 1
                SAVEP   s1
                mov     ax, word ptr s1
                sub     ax, word ptr s0
                CHK     n_apart, ax, T Surface

                ;; the two refusals. 0:0 is what qglSfAdoptDc rejects,
                ;; so a wrong index fails there rather than writing
                ;; through whatever lay at that offset.
                invoke  qglSfScratch, QGL_SCRATCH
                or      ax, dx
                CHK     n_range, ax, 0

                invoke  qglSfScratch, -1
                or      ax, dx
                CHK     n_neg, ax, 0

                ;;
                ;; and now USE one. A real surface, copied in, then
                ;; written and read back through the slot's pointer --
                ;; which is the only thing that says the storage is
                ;; reachable and writable from here.
                ;;
                invoke  qglSfNew, SFW, SFH, SURF_CMEM, 0
                SAVEP   sf
                invoke  ssave, s1
                invoke  scopy, s0, sf

                invoke  qglSfPset, s0, 5, 3, 0A7h
                invoke  qglSfPget, s0, 5, 3
                CHK     n_use, ax, 0A7h

                invoke  schk, s1
                CHK     n_spill, ax, 0

                invoke  qglSfFree, sf
                ret
tmain           endp
                end
