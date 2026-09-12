;; r_sweep.asm -- r_sweep_row / r_sweep_ovf
;;
;; name: r_sweep_row
;; desc: one row of a span sweep: walk an active edge list left to right,
;;       keep the set of polygons currently inside sorted nearest-first,
;;       and hand back the spans where the nearest one changes.
;;
;;       This is r_span.c's inner loop, in assembly, because that
;;       loop runs about 3,400 times a frame and bcc spends most of it in
;;       memory: 401 stack references against clang's 106 for the same C.
;;       Nothing here is clever -- it is the same algorithm with the
;;       working set in registers and toggle_active folded in, so the per
;;       crossing near call and its prologue are gone.
;;
;;       Drawing stays with the caller. A span costs a far call into uGL
;;       whoever makes it, so there is nothing to win by making it here,
;;       and keeping it out means this routine needs no symbol from the
;;       caller and no callback.
;;
;; args: [in]  row      | the row, passed through to the caller's spans
;;             scrw     | clamp, and where a still-open span is closed
;;             nextp    | near ptr, ael_next[]  (word per slot)
;;             up       | near ptr, ael_u[]     (16.16 long per slot)
;;             polyp    | near ptr, ael_poly[]  (word per slot)
;;             headi    | the list head's slot index
;;             taili    | the tail sentinel's slot index
;;             outp     | near ptr, room for outmax triples x0,x1,poly
;;             outmax   | how many triples fit
;; retn: word           | triples written
;;
;; obs.: - the crossing x is the HIGH WORD of the 16.16 accumulator, so
;;         it is a word load, not a dword load and a shift. bcc emits the
;;         latter because it cannot see that the shift is free.
;;       - the active set is per row scratch, so it lives here rather
;;         than being handed in and reset by the caller every row.

                ;; 286 is enough and 386 is not free here: it makes the
;; data segment USE32 against 16-bit code. Nothing in this loop wants a
;; 32-bit register -- the crossing x is the high WORD of the 16.16
;; accumulator, so it is a word load rather than a dword load and shift.
                .286
                .model medium, pascal

MAX_ACTIVE      equ     96

.data
;; The polygons currently inside, nearest first. Nearest is the LARGER
;; emission index: the BSP walk hands them over back to front.
sw_poly         dw      MAX_ACTIVE dup (0)
sw_cnt          dw      0
                public  sw_ovf
sw_ovf     dw      0               ;; set bounds were exceeded


.code
;;::::::::::::::
r_sweep_row     proc    public uses bx cx dx si di,\
                        row:word, scrw:word,\
                        nextp:word, up:word, polyp:word,\
                        headi:word, taili:word,\
                        outp:word, outmax:word

                LOCAL   curpoly:word, spanx:word, nout:word

                mov     ss:sw_cnt, 0
                mov     ax, -1
                mov     curpoly, ax
                mov     spanx, 0
                mov     nout, 0

                ;; si = e = ael_next[head]
                mov     bx, headi
                shl     bx, 1
                add     bx, nextp
                mov     si, [bx]

@@walk:         cmp     si, taili
                je      @@tail

                ;; ---- cx = crossing x, clamped ------------------------
                ;; the high half of the 16.16 accumulator IS the integer
                mov     bx, si
                shl     bx, 2
                add     bx, up
                mov     cx, [bx+2]
                or      cx, cx
                jns     @@xpos
                xor     cx, cx
@@xpos:         cmp     cx, scrw
                jle     @@xok
                mov     cx, scrw
@@xok:

                ;; ---- dx = this edge's polygon ------------------------
                mov     bx, si
                shl     bx, 1
                add     bx, polyp
                mov     dx, [bx]

                ;; ---- toggle dx in the active set --------------------
                ;; The set is sorted on the same key it is searched by,
                ;; so one scan answers both: it stops where dx belongs,
                ;; which is also where dx is if it is present.
                xor     di, di
@@scan:         cmp     di, ss:sw_cnt
                jge     @@notfound
                mov     bx, di
                shl     bx, 1
                cmp     ss:sw_poly[bx], dx
                jle     @@scandone
                inc     di
                jmp     @@scan
@@scandone:     jne     @@insert                ;; flags still from cmp

                ;; present -> remove at di, shift the tail down
                mov     bx, di
                shl     bx, 1
@@rmv:          mov     ax, di
                inc     ax
                cmp     ax, ss:sw_cnt
                jge     @@rmvdone
                mov     ax, ss:sw_poly[bx+2]
                mov     ss:sw_poly[bx], ax
                add     bx, 2
                inc     di
                jmp     @@rmv
@@rmvdone:      dec     ss:sw_cnt
                jmp     @@toggled

@@notfound:     ;; di == sw_cnt, so it belongs at the end
@@insert:       cmp     ss:sw_cnt, MAX_ACTIVE
                jl      @@room
                inc     ss:sw_ovf
                jmp     @@toggled
@@room:         ;; shift up from the end down to di, then place
                mov     ax, ss:sw_cnt
@@ins:          cmp     ax, di
                jle     @@insdone
                mov     bx, ax
                shl     bx, 1
                mov     cx, ss:sw_poly[bx-2]
                mov     ss:sw_poly[bx], cx
                dec     ax
                jmp     @@ins
@@insdone:      mov     bx, di
                shl     bx, 1
                mov     ss:sw_poly[bx], dx
                inc     ss:sw_cnt

                ;; cx was clobbered by the shift loop -- take x again
                mov     bx, si
                shl     bx, 2
                add     bx, up
                mov     cx, [bx+2]
                or      cx, cx
                jns     @@xpos2
                xor     cx, cx
@@xpos2:        cmp     cx, scrw
                jle     @@toggled
                mov     cx, scrw

@@toggled:      ;; ---- did the FRONT change? ---------------------------
                ;; Only then does a span close: toggling a hidden
                ;; polygon in or out behind the winner must not split it.
                mov     ax, -1
                cmp     ss:sw_cnt, 0
                jle     @@front
                mov     ax, ss:sw_poly[0]
@@front:        cmp     ax, curpoly
                je      @@next

                ;; close the open span, if there is one with width
                push    ax
                mov     ax, curpoly
                or      ax, ax
                js      @@noclose
                cmp     cx, spanx
                jle     @@noclose
                call    @@emit
@@noclose:      pop     ax
                mov     curpoly, ax
                mov     spanx, cx

@@next:         mov     bx, si
                shl     bx, 1
                add     bx, nextp
                mov     si, [bx]
                jmp     @@walk

@@tail:         ;; a span still open at the right edge closes there
                mov     ax, curpoly
                or      ax, ax
                js      @@done
                mov     cx, scrw
                cmp     cx, spanx
                jle     @@done
                call    @@emit

@@done:         mov     ax, nout
                ret

;;  local: writes one triple -- spanx, cx, curpoly. Clobbers bx, di.
@@emit:         mov     di, nout
                cmp     di, outmax
                jge     @@emitfull
                mov     bx, di
                shl     bx, 1
                mov     ax, bx
                shl     bx, 1
                add     bx, ax                  ;; bx = di*6
                add     bx, outp
                mov     ax, spanx
                mov     [bx], ax
                mov     [bx+2], cx
                mov     ax, curpoly
                mov     [bx+4], ax
                inc     nout
                retn
@@emitfull:     inc     ss:sw_ovf
                retn

r_sweep_row     endp

;;::::::::::::::
;; r_sweep_ovf () -- bounds hit since the last read, and cleared by it.
r_sweep_ovf     proc    public
                mov     ax, ss:sw_ovf
                mov     ss:sw_ovf, 0
                xor     dx, dx
                ret
r_sweep_ovf     endp
                end
