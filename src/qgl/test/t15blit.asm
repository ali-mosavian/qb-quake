;; t15blit -- the blitters clip horizontally, not only vertically.
;;
;; Both walked rows and tested each against the destination's height,
;; and then wrote the source's FULL WIDTH from column x with no test at
;; all. A blit starting left of zero wrapped its offset and landed in the
;; previous row; one running off the right ran into the next row. Neither
;; leaves the allocation, so nothing faults and nothing downstream
;; complains -- the picture simply grows a band of wrong pixels, which is
;; the quiet kind of bug this file exists for.
;;
;; The oracle is written out per pixel rather than as a count: a count
;; passes for a blit that moved the right NUMBER of bytes to the wrong
;; place, which is exactly what the unclipped version did. The source is
;; a per-column ramp so the check also says WHICH source column arrived,
;; and the scaled case uses a whole-number 2x so its expected column is
;; a shift and not a second copy of the 8.8 arithmetic under test.
;;
;; THE SURFACE IS DELIBERATELY LARGER THAN 64K, and that is the whole
;; reason it is 512 wide. A row comes back normalised -- offset 0..15,
;; the rest folded into the segment -- so an underflowing offset does
;; not step back into the previous row: it wraps to FFFDh and the copy
;; lands 65533 bytes ABOVE. The tail of it then wraps again to offset 0
;; and writes the row's first columns with exactly the bytes a correct
;; clip would have put there, so a small surface reports the left-hand
;; cases as PASSING. They were, in the first version of this file. Only
;; a surface long enough to contain the stray write can see it.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglDrFill     proto   far :dword, :word, :word, :word, :word, :word
qglDrBlit     proto   far :dword, :word, :word, :dword
qglDrBlitScl proto   far :dword, :word, :word, :word, :word, :dword

SFW             equ     512     ;; * SFH > 64K, so the wrap lands inside
SFH             equ     144
GDH             equ     64      ;; tall: an overrun past the last row jumps
SRCW            equ     8
SRCH            equ     4
FILLB           equ     011h
GUARDB          equ     0A5h
SRC0            equ     040h    ;; source column c holds SRC0 + c

.data
n_in            db      'blit inside            $'
n_left          db      'blit off the left      $'
n_right         db      'blit off the right     $'
n_allleft       db      'blit entirely left     $'
n_allright      db      'blit entirely right    $'
n_up            db      'blit off the top       $'
n_sin           db      'blit_scl inside        $'
n_sleft         db      'blit_scl off the left  $'
n_sright        db      'blit_scl off the right $'
n_sall          db      'blit_scl entirely left $'
n_guard         db      'guard survives it all  $'

sf              dd      0
guard           dd      0
src             dd      0
bad             dw      0

.code

;;::::::::::::::
;; vrfy -- count the pixels of sf that a correctly clipped blit would
;; not have left there.
;;
;; INTERNAL. x is signed. sh is the source-column shift: 0 for the 1:1
;; blit, 1 for the 2x scaled one, so the expected column is arithmetic
;; the code under test does not share.
;;::::::::::::::
vrfy            proc    near private uses bx cx dx si di es,\
                        x:word, y:word, w:word, h:word, sh:word

                mov     bad, 0
                xor     si, si                  ;; py
@@row:          cmp     si, SFH
                jae     @@out
                invoke  qglSfRdRow, sf, si
                mov     es, dx
                mov     di, ax
                xor     cx, cx                  ;; px

@@px:           cmp     cx, SFW
                jae     @@next
                mov     bl, FILLB               ;; what it should hold

                mov     ax, si
                sub     ax, y                   ;; dy, signed
                cmp     ax, 0
                jl      @@cmp
                cmp     ax, h
                jge     @@cmp

                mov     ax, cx
                sub     ax, x                   ;; dx, signed
                cmp     ax, 0
                jl      @@cmp
                cmp     ax, w
                jge     @@cmp

                push    cx
                mov     cx, sh
                shr     ax, cl                  ;; source column
                pop     cx
                add     al, SRC0
                mov     bl, al

@@cmp:          mov     al, es:[di]
                cmp     al, bl
                je      @F
                inc     bad
@@:             inc     di
                inc     cx
                jmp     @@px

@@next:         inc     si
                jmp     @@row
@@out:          mov     ax, bad
                ret
vrfy            endp


;;:::::::::::::: bytes of the guard that are no longer GUARDB
gchk            proc    near private uses bx cx dx si di es
                mov     bad, 0
                xor     si, si
@@row:          cmp     si, GDH
                jae     @@out
                invoke  qglSfRdRow, guard, si
                mov     es, dx
                mov     di, ax
                mov     cx, SFW
@@px:           cmp     byte ptr es:[di], GUARDB
                je      @F
                inc     bad
@@:             inc     di
                loop    @@px
                inc     si
                jmp     @@row
@@out:          mov     ax, bad
                ret
gchk            endp


;;:::::::::::::: put both surfaces back to their known bytes
reset           proc    near private
                invoke  qglDrFill, sf, 0, 0, SFW-1, SFH-1, FILLB
                invoke  qglDrFill, guard, 0, 0, SFW-1, GDH-1, GUARDB
                ret
reset           endp


tmain           proc    far public uses bx cx dx si di es

                invoke  qglSfInit
                invoke  qglSfNew, SFW, SFH, SURF_CMEM, 0
                SAVEP   sf
                invoke  qglSfNew, SFW, GDH, SURF_CMEM, 0
                SAVEP   guard
                invoke  qglSfNew, SRCW, SRCH, SURF_CMEM, 0
                SAVEP   src

                ;; the ramp: column c holds SRC0 + c
                xor     si, si
@@col:          cmp     si, SRCW
                jae     @@ramped
                mov     ax, si
                add     ax, SRC0
                invoke  qglDrFill, src, si, 0, si, SRCH-1, ax
                inc     si
                jmp     @@col
@@ramped:

                ;;
                ;; 1. wholly inside, so the oracle itself is checked
                ;;    against a case with nothing to clip
                ;;
                invoke  reset
                invoke  qglDrBlit, sf, 4, 4, src
                invoke  vrfy, 4, 4, SRCW, SRCH, 0
                CHK     n_in, ax, 0

                ;;
                ;; 2. starting left of zero. The offset wraps, so the
                ;;    write lands at the END of the previous row -- still
                ;;    inside the allocation, which is why the guard alone
                ;;    would never see it.
                ;;
                invoke  reset
                invoke  qglDrBlit, sf, -3, 4, src
                invoke  vrfy, -3, 4, SRCW, SRCH, 0
                CHK     n_left, ax, 0

                ;;
                ;; 3. running off the right, into the next row's left
                ;;
                invoke  reset
                invoke  qglDrBlit, sf, SFW-3, 4, src
                invoke  vrfy, SFW-3, 4, SRCW, SRCH, 0
                CHK     n_right, ax, 0

                ;;
                ;; 4. and the two that must draw nothing at all
                ;;
                invoke  reset
                invoke  qglDrBlit, sf, -SRCW, 4, src
                invoke  vrfy, -SRCW, 4, SRCW, SRCH, 0
                CHK     n_allleft, ax, 0

                invoke  reset
                invoke  qglDrBlit, sf, SFW, 4, src
                invoke  vrfy, SFW, 4, SRCW, SRCH, 0
                CHK     n_allright, ax, 0

                ;;
                ;; 5. vertical still clips -- it did before, and a fix to
                ;;    the horizontal side has no business breaking it
                ;;
                invoke  reset
                invoke  qglDrBlit, sf, 4, -2, src
                invoke  vrfy, 4, -2, SRCW, SRCH, 0
                CHK     n_up, ax, 0

                ;;
                ;; 6. the scaled blitter, 2x, so the expected source
                ;;    column is (px - x) >> 1
                ;;
                invoke  reset
                invoke  qglDrBlitScl, sf, 4, 4, SRCW*2, SRCH*2, src
                invoke  vrfy, 4, 4, SRCW*2, SRCH*2, 1
                CHK     n_sin, ax, 0

                invoke  reset
                invoke  qglDrBlitScl, sf, -5, 4, SRCW*2, SRCH*2, src
                invoke  vrfy, -5, 4, SRCW*2, SRCH*2, 1
                CHK     n_sleft, ax, 0

                invoke  reset
                invoke  qglDrBlitScl, sf, SFW-5, 4, SRCW*2, SRCH*2, src
                invoke  vrfy, SFW-5, 4, SRCW*2, SRCH*2, 1
                CHK     n_sright, ax, 0

                invoke  reset
                invoke  qglDrBlitScl, sf, -SRCW*2, 4, SRCW*2, SRCH*2, src
                invoke  vrfy, -SRCW*2, 4, SRCW*2, SRCH*2, 1
                CHK     n_sall, ax, 0

                invoke  gchk
                CHK     n_guard, ax, 0

                invoke  qglSfFree, src
                invoke  qglSfFree, guard
                invoke  qglSfFree, sf
                ret
tmain           endp
                end
