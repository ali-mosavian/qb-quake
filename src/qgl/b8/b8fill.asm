;;
;; b8fill.asm -- the 8bpp span primitives everything else fills through.
;;
;; name: qgl$run_fill / qgl$run_copy / qgl$nib4
;; desc: a run of one colour, a run copied, and a glyph row expanded from
;;       packed bits. No routine here looks at a surface, a clip rectangle
;;       or a coordinate; it is given a pointer and a count and it fills.
;;
;;       That is the whole reason they are in b8/ rather than beside the
;;       code that works out where a run belongs. mgl draws the same line:
;;       cfmt/b8 holds 8tfill, 8putb, 8puts, 8line, 8vline and 8pixel, and
;;       every one of them is pixels with no geometry in it. dr.asm and
;;       txt.asm keep the clipping and hand these a run that already fits.
;;
;; obs.: - QGL_CODE, so the callers reach them near across the module
;;         boundary, the same as the polygon fillers next door.
;;

                .model  medium, pascal
                .386
                option  proc:private

                include qgl.inc


.data
qgl$nibTB       label   dword
                db      000h,000h,000h,000h     ;; 0000
                db      000h,000h,000h,0FFh     ;; 0001
                db      000h,000h,0FFh,000h     ;; 0010
                db      000h,000h,0FFh,0FFh
                db      000h,0FFh,000h,000h     ;; 0100
                db      000h,0FFh,000h,0FFh
                db      000h,0FFh,0FFh,000h
                db      000h,0FFh,0FFh,0FFh
                db      0FFh,000h,000h,000h     ;; 1000
                db      0FFh,000h,000h,0FFh
                db      0FFh,000h,0FFh,000h
                db      0FFh,000h,0FFh,0FFh
                db      0FFh,0FFh,000h,000h
                db      0FFh,0FFh,000h,0FFh
                db      0FFh,0FFh,0FFh,000h
                db      0FFh,0FFh,0FFh,0FFh     ;; 1111

                QGL_CODE

;;::::::::::::::
;; qgl$run_fill -- one run of a constant byte.
;;
;; INTERNAL: es:di -> the run, cx = length, al = the colour. Everything
;; survives except di, which is left past the run.
;;::::::::::::::
qgl$run_fill    proc    near public uses ax bx cx

                cld
                jcxz    @@out
                mov     ah, al                  ;; the byte, four to a dword
                mov     bx, ax
                shl     eax, 16
                mov     ax, bx

                mov     bx, cx                  ;; bytes left
                mov     cx, di                  ;; up to the next boundary
                neg     cx
                and     cx, 3
                cmp     cx, bx
                jbe     @F
                mov     cx, bx
@@:             sub     bx, cx
                rep     stosb

                mov     cx, bx                  ;; the bulk
                shr     cx, 2
                rep     stosd

                mov     cx, bx                  ;; and the tail
                and     cx, 3
                rep     stosb
@@out:          ret
qgl$run_fill    endp


;;::::::::::::::
;; qgl$run_copy -- one run copied, ds:si -> es:di.
;;
;; INTERNAL: cx = length. Everything survives except si and di, left
;; past the run.
;;::::::::::::::
qgl$run_copy    proc    near public uses ax bx cx

                cld
                jcxz    @@out
                mov     bx, cx
                mov     cx, di
                neg     cx
                and     cx, 3
                cmp     cx, bx
                jbe     @F
                mov     cx, bx
@@:             sub     bx, cx
                rep     movsb

                mov     cx, bx
                shr     cx, 2
                rep     movsd

                mov     cx, bx
                and     cx, 3
                rep     movsb
@@out:          ret
qgl$run_copy    endp




;;::::::::::::::
;; qgl$nib4 -- four pixels from one nibble, no branch per pixel.
;;
;; INTERNAL: bl = the nibble, es:di -> the destination, col on the stack
;; frame of the caller is NOT reachable, so the colour arrives in dh.
;; di advances by four. Everything else survives.
;;::::::::::::::
qgl$nib4        proc    near public uses ax bx cx si
                xor     bh, bh
                shl     bx, 2                   ;; four bytes an entry
                mov     si, offset qgl$nibTB
                add     si, bx
                mov     cx, 4
@@px:           mov     al, ds:[si]             ;; 00 or FF
                mov     ah, al
                not     ah
                and     al, dh                  ;; colour where lit
                and     ah, es:[di]             ;; keep dst where clear
                or      al, ah
                mov     es:[di], al
                inc     si
                inc     di
                loop    @@px
                ret
qgl$nib4        endp

                QGL_ENDS
                end
