;; tmr.asm -- the tick: the PIT at a rate of our choosing, counted.
;;
;; name: qglTmrInit / qglTmrTicks / qglTmrHz / qglTmrShutdown
;; desc: Hooks INT 8, runs channel 0 in rate mode at the rate asked for
;;       and counts every interrupt into a dword the caller reads. The
;;       BIOS handler keeps its 18.2 Hz: the divisor accumulates per tick
;;       and the old vector is chained each time the sum wraps 65536,
;;       which is the interval the BIOS clock counts on. Every other
;;       tick is acknowledged here.
;;
;;       mgl's tmrInit programmed a divisor of 8192 whatever was asked
;;       for -- its Windows check always answered yes -- so "1 kHz"
;;       delivered 145.6 and sys_time_init learned to measure. It still
;;       does; the number it measures is ours now.
;;
;; obs.: - the counter, the divisor and the vector live in the code
;;         segment: an interrupt arrives with whatever ds the interrupted
;;         code had.
;;       - qglTmrShutdown puts the PIT back to the BIOS setting, mode 3
;;         with a divisor of 0, and the vector back. Idempotent: the
;;         error exit and the normal one both call it.

                .model  medium, pascal
                .386

                include qgl.inc

PIT_FREQ        equ     1234DDh         ;; 1,193,181 Hz
PIT_CNT_0       equ     40h
PIT_MODE        equ     43h
PIT_RATE        equ     34h             ;; counter 0, lo/hi, mode 2, binary
PIT_SQUARE      equ     36h             ;; counter 0, lo/hi, mode 3, binary -- the BIOS's
PIC_CMD         equ     20h
PIC_EOI         equ     20h

.code

qgl$tmr_on      dw      0
qgl$tmr_ticks   dd      0
qgl$tmr_hz      dd      0
qgl$tmr_div     dw      0
qgl$tmr_acc     dw      0
qgl$tmr_old     dd      0

;;::::::::::::::
;; the INT 8 handler
;;::::::::::::::
qgl$TmrIsr      proc    far private
                push    ax
                inc     D cs:qgl$tmr_ticks
                mov     ax, cs:qgl$tmr_div
                add     cs:qgl$tmr_acc, ax
                jc      @@bios                  ;; 65536 PIT cycles: the BIOS's turn
                mov     al, PIC_EOI
                out     PIC_CMD, al
                pop     ax
                iret
@@bios:         pop     ax
                jmp     D cs:qgl$tmr_old        ;; which acknowledges the PIC itself
qgl$TmrIsr      endp


;;::::::::::::::
;; qglTmrInit ( hz:word )
;;
;; hz below 19 cannot be honoured by a 16-bit divisor and is raised to
;; it; 0 means the BIOS's own rate. A second call changes nothing.
;;::::::::::::::
qglTmrInit    proc    public uses bx cx dx si es,\
                        hz:word

                cmp     cs:qgl$tmr_on, 0
                jne     @@done

                ;; divisor = PIT_FREQ / hz, a word
                movzx   ecx, hz
                test    ecx, ecx
                jnz     @F
                mov     ecx, 1
@@:             mov     eax, PIT_FREQ
                xor     edx, edx
                div     ecx
                cmp     eax, 0FFFFh
                jbe     @F
                mov     eax, 0FFFFh
@@:             mov     cs:qgl$tmr_div, ax

                ;; and the rate that divisor really gives, for the caller
                mov     ecx, eax
                mov     eax, PIT_FREQ
                xor     edx, edx
                div     ecx
                mov     cs:qgl$tmr_hz, eax

                mov     cs:qgl$tmr_ticks, 0
                mov     cs:qgl$tmr_acc, 0

                mov     ax, 3508h
                int     21h
                mov     W cs:qgl$tmr_old, bx
                mov     W cs:qgl$tmr_old+2, es

                cli
                push    ds
                mov     ax, cs
                mov     ds, ax
                mov     dx, offset qgl$TmrIsr
                mov     ax, 2508h
                int     21h
                pop     ds

                mov     al, PIT_RATE
                out     PIT_MODE, al
                mov     ax, cs:qgl$tmr_div
                out     PIT_CNT_0, al
                mov     al, ah
                out     PIT_CNT_0, al
                mov     cs:qgl$tmr_on, 1
                sti
@@done:         ret
qglTmrInit    endp


;;::::::::::::::
;; qglTmrTicks () -> dx:ax = interrupts since qglTmrInit
;;::::::::::::::
qglTmrTicks   proc    public
                cli
                mov     ax, W cs:qgl$tmr_ticks
                mov     dx, W cs:qgl$tmr_ticks+2
                sti
                ret
qglTmrTicks   endp


;;::::::::::::::
;; qglTmrHz () -> dx:ax = the rate the PIT was given, in Hz
;;::::::::::::::
qglTmrHz      proc    public
                mov     ax, W cs:qgl$tmr_hz
                mov     dx, W cs:qgl$tmr_hz+2
                ret
qglTmrHz      endp


;;::::::::::::::
;; qglTmrShutdown ()
;;::::::::::::::
qglTmrShutdown proc   public uses ax dx ds

                cmp     cs:qgl$tmr_on, 0
                je      @@done
                mov     cs:qgl$tmr_on, 0

                cli
                mov     al, PIT_SQUARE
                out     PIT_MODE, al
                xor     al, al
                out     PIT_CNT_0, al
                out     PIT_CNT_0, al

                lds     dx, cs:qgl$tmr_old
                mov     ax, 2508h
                int     21h
                sti
@@done:         ret
qglTmrShutdown endp

                end
