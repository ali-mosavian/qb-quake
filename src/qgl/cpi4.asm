;; cpi4.asm -- BASIC's long compare, without lahf/sahf.
;;
;; name: B$CPI4
;; desc: BC routes every `long` compare through the runtime's B$CPI4 and
;;       reads the flags with signed jumps. VBDOS's own copy compares the
;;       high words, and when they are equal turns the low words' carry
;;       into a sign bit through lahf / shr / shl / sahf. DOSBox-X's
;;       dynamic core gets that dance wrong: 23760 >= 40843 came back
;;       true and 40843 > 32767 false, on the pinned core, while
;;       core=normal answered both right. Linking this object ahead of
;;       the runtime library replaces the routine; the low words are
;;       compared signed after flipping their sign bits, which is the
;;       same order and needs no flag surgery. Arguments are two dwords
;;       pushed high word first, the left one first; the callee pops.
;;       The runtime keeps B$CPI4 in one module with the other four long
;;       helpers, so all five live here or LINK pulls that module too:
;;       B$CMI4 as it was, and the three arithmetic jumps.

                .model  medium, pascal
                .386

                extrn   __aFlmul:far
                extrn   __aFldiv:far
                extrn   __aFlrem:far

.code

B$MUI4          proc    far public
                jmp     __aFlmul
B$MUI4          endp

B$DVI4          proc    far public
                jmp     __aFldiv
B$DVI4          endp

B$RMI4          proc    far public
                jmp     __aFlrem
B$RMI4          endp

;; carry set when left < right, the low words unsigned; the runtime's own
B$CMI4          proc    far public
                push    bp
                mov     bp, sp
                push    ax
                mov     ax, [bp+12]
                cmp     ax, [bp+8]
                stc
                jl      @@done
                clc
                jg      @@done
                mov     ax, [bp+10]
                cmp     ax, [bp+6]
@@done:         pop     ax
                pop     bp
                ret     8
B$CMI4          endp

B$CPI4          proc    far public
                push    bp
                mov     bp, sp
                push    ax
                push    cx
                mov     ax, [bp+12]             ;; left high
                cmp     ax, [bp+8]              ;; right high
                jne     @@done
                mov     ax, [bp+10]             ;; left low, unsigned order
                mov     cx, [bp+6]              ;; as a signed compare
                xor     ax, 8000h
                xor     cx, 8000h
                cmp     ax, cx
@@done:         pop     cx
                pop     ax
                pop     bp
                ret     8
B$CPI4          endp

                end
