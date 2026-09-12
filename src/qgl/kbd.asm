;; kbd.asm -- every key's state, from the scancode line.
;;
;; name: qglKbdInit / qglKbdShutdown
;; desc: Hooks INT 9 and keeps a word per scancode in the caller's table:
;;       -1 while the key is down, 0 once it is up, and word 0 the code
;;       of the last key pressed. The BIOS never sees a key while the
;;       hook is up -- INKEY$ and SLEEP would wait forever -- and its
;;       buffer is flushed at shutdown so nothing typed leaks to the
;;       prompt.
;;
;; obs.: The table is 128 words and lives in the caller's segment; the
;;       renderer's is Keys in in.bi, a field of Game, which is dim'd in
;;       DGROUP and does not move.

                .model  medium, pascal
                .386

                include qgl.inc

KBD_DATA        equ     60h
PIC_CMD         equ     20h
PIC_EOI         equ     20h
PIC_MASK        equ     21h
BIOS_KB_HEAD    equ     1Ah
BIOS_KB_TAIL    equ     1Ch

.code

qgl$kbd_on      dw      0
qgl$kbd_old     dd      0
qgl$kbd_tab     dd      0

;;::::::::::::::
;; the INT 9 handler: table[code] = down ? -1 : 0, table[0] = code or 0
;;::::::::::::::
qgl$KbdIsr      proc    far private
                push    ax
                push    bx
                push    si
                push    ds
                lds     si, cs:qgl$kbd_tab
                in      al, KBD_DATA
                mov     ah, al
                and     al, 7Fh
                movzx   bx, al
                shl     bx, 1
                shl     ah, 1                   ;; bit 7 set = released
                sbb     ah, ah
                not     ah                      ;; FFh down, 0 up
                mov     [si+bx], ah
                mov     [si+bx+1], ah
                and     al, ah
                mov     [si], al
                mov     al, PIC_EOI
                out     PIC_CMD, al
                pop     ds
                pop     si
                pop     bx
                pop     ax
                iret
qgl$KbdIsr      endp


;;::::::::::::::
;; qglKbdInit ( keys:far ptr ) -- a second call changes nothing
;;::::::::::::::
qglKbdInit    proc    public uses bx cx dx di es ds,\
                        keys:far ptr

                cmp     cs:qgl$kbd_on, 0
                jne     @@done

                les     di, keys
                mov     W cs:qgl$kbd_tab, di
                mov     W cs:qgl$kbd_tab+2, es
                xor     ax, ax
                mov     cx, 128
                cld
                rep     stosw

                mov     ax, 3509h
                int     21h
                mov     W cs:qgl$kbd_old, bx
                mov     W cs:qgl$kbd_old+2, es

                mov     ax, cs
                mov     ds, ax
                mov     dx, offset qgl$KbdIsr
                mov     ax, 2509h
                int     21h

                in      al, PIC_MASK
                and     al, not 2               ;; IRQ 1 on
                out     PIC_MASK, al
                mov     cs:qgl$kbd_on, 1
@@done:         ret
qglKbdInit    endp


;;::::::::::::::
;; qglKbdShutdown () -- the BIOS handler back, its buffer emptied
;;::::::::::::::
qglKbdShutdown proc   public uses ax dx ds

                cmp     cs:qgl$kbd_on, 0
                je      @@done
                mov     cs:qgl$kbd_on, 0

                lds     dx, cs:qgl$kbd_old
                mov     ax, 2509h
                int     21h

                mov     ax, 40h
                mov     ds, ax
                mov     ax, ds:[BIOS_KB_TAIL]
                mov     ds:[BIOS_KB_HEAD], ax
@@done:         ret
qglKbdShutdown endp

                end
