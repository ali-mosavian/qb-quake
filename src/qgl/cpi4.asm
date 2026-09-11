;; cpi4.asm -- BASIC's long arithmetic, in 32-bit instructions.
;;
;; name: B$CPI4 / B$CMI4 / B$MUI4 / B$DVI4 / B$RMI4
;; desc: BC routes every `long` operation through the runtime, which does
;;       it in 16-bit halves -- and two of them wrongly here. The machine
;;       is a 386: a compare is one cmp, a multiply one imul, a divide
;;       one idiv. Linking this object ahead of the runtime library
;;       replaces the routines. Arguments are two dwords pushed high word
;;       first, the RIGHT one first; the callee pops. That order is what
;;       `64 \ (2 ^ j)` assembles to, and a compare's operands come in
;;       the same way -- BC picks the jump to suit. The runtime keeps all
;;       five in one module, so all five live here or LINK pulls that
;;       module too.
;;
;; obs.: - VBDOS's B$CPI4 compares the high words and, when they are
;;         equal, turns the low words' carry into a sign bit through
;;         lahf / shr / shl / sahf. DOSBox-X's dynamic core gets that
;;         dance wrong: 23760 >= 40843 came back true and 40843 > 32767
;;         false, on the pinned core, while core=normal answered both
;;         right. A 32-bit cmp has no flag surgery to get wrong.
;;       - A long pushed high word first puts its low word at the lower
;;         address, so the pair IS the dword the caller meant.
;;       - Getting the two operands the wrong way round divides the
;;         divisor by the dividend, which reads as e1m6 loading another
;;         map's entities. t33cpi4 pushes them the way BC does.
;;       - idiv traps on a zero divisor and on 80000000h / -1, and what
;;         those two do is the runtime's business, not this file's: they
;;         go to the helpers this module used to hand everything to.
;;       - the answer comes home in dx:ax, which is where both the
;;         runtime and Borland's helpers leave it.

                .model  medium, pascal
                .386

                extrn   __aFldiv:far
                extrn   __aFlrem:far

.code

;; The two divides idiv cannot do. ecx is the divisor, eax the dividend.
DIVOK           macro   lbl
                local   ok
                test    ecx, ecx
                jz      lbl
                cmp     ecx, -1
                jne     ok
                cmp     eax, 80000000h
                je      lbl
ok:
endm

B$MUI4          proc    far public
                push    bp
                mov     bp, sp
                mov     eax, [bp+10]
                imul    dword ptr [bp+6]        ;; edx:eax; __aFlmul checked
                mov     edx, eax                ;; no overflow either
                shr     edx, 16
                pop     bp
                ret     8
B$MUI4          endp

B$DVI4          proc    far public
                push    bp
                mov     bp, sp
                push    ecx
                mov     eax, [bp+6]             ;; the dividend, pushed last
                mov     ecx, [bp+10]
                DIVOK   @@old
                cdq
                idiv    ecx
                mov     edx, eax
                shr     edx, 16
                pop     ecx
                pop     bp
                ret     8
@@old:          pop     ecx
                pop     bp
                jmp     __aFldiv
B$DVI4          endp

B$RMI4          proc    far public
                push    bp
                mov     bp, sp
                push    ecx
                mov     eax, [bp+6]             ;; the dividend, pushed last
                mov     ecx, [bp+10]
                DIVOK   @@old
                cdq
                idiv    ecx
                mov     eax, edx                ;; the remainder, dividend's sign
                mov     edx, eax
                shr     edx, 16
                pop     ecx
                pop     bp
                ret     8
@@old:          pop     ecx
                pop     bp
                jmp     __aFlrem
B$RMI4          endp

;; carry set when left < right, signed -- flipping both sign bits makes
;; an unsigned compare answer the signed question, and leaves ZF alone
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

;; the flags a signed jump reads, straight off the compare
B$CPI4          proc    far public
                push    bp
                mov     bp, sp
                push    ax
                push    cx
                mov     ax, [bp+12]
                cmp     ax, [bp+8]
                jne     @@cdone
                mov     ax, [bp+10]
                mov     cx, [bp+6]
                xor     ax, 8000h
                xor     cx, 8000h
                cmp     ax, cx
@@cdone:        pop     cx
                pop     ax
                pop     bp
                ret     8
B$CPI4          endp

                end
