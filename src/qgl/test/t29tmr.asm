;; t29tmr -- the PIT hook keeps the BIOS clock and gives the machine back.
;;
;; 1000 of our ticks at 1000 Hz span a second, over which 0040:006C -- the
;; BIOS tick, 18.2 Hz -- must advance about 18: the old INT 8 is chained
;; when the divisor accumulates to 65536, and a handler that forgot to
;; would stall DOS's clock and TIMER with it, which sys_time_init
;; calibrates against. After qglTmrShutdown the vector is the one that
;; was there before and the counter stops.
;;
;; The wait is bounded by the BIOS tick as well, so a hook that never
;; fires fails here instead of hanging the suite.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglTmrInit      proto   far :word
qglTmrTicks     proto   far
qglTmrHz        proto   far
qglTmrShutdown  proto   far
qglTmrCycles    proto   far

BIOS_TICK       equ     6Ch             ;; 0040:006C, dword

.data
n_hz            db      'hz reads 1000          $'
n_hook          db      'INT 8 is hooked        $'
n_ticks         db      'reached 1000 ticks     $'
n_bios          db      'BIOS advanced 16..20   $'
n_back          db      'vector restored        $'
n_stop          db      'counter stopped        $'
n_tsc           db      'cycles advance         $'

old_ofs         dw      0
old_seg         dw      0
b0              dd      0
bdelta          dd      0
t1              dd      0
t2              dd      0
t3              dd      0
got             dw      0

.code

;; eax = BIOS tick - b0
bios_delta      proc    near private uses es
                mov     ax, 40h
                mov     es, ax
                mov     eax, es:[BIOS_TICK]
                sub     eax, b0
                ret
bios_delta      endp

;; spin until the BIOS tick has moved n times
bios_wait       proc    near private uses ebx es,\
                        n:word
                mov     ax, 40h
                mov     es, ax
                mov     ebx, es:[BIOS_TICK]
                movzx   eax, n
                add     ebx, eax
@@:             cmp     es:[BIOS_TICK], ebx
                jb      @B
                ret
bios_wait       endp

tmain           proc    far public uses bx cx dx si di es

                mov     ax, 3508h
                int     21h
                mov     old_ofs, bx
                mov     old_seg, es

                mov     ax, 40h
                mov     es, ax
                mov     eax, es:[BIOS_TICK]
                mov     b0, eax

                invoke  qglTmrInit, 1000

                invoke  qglTmrHz
                CHK     n_hz, ax, 1000

                mov     ax, 3508h
                int     21h
                mov     ax, es
                cmp     ax, old_seg
                jne     @@hooked
                cmp     bx, old_ofs
                jne     @@hooked
                mov     got, 0
                jmp     @@hk
@@hooked:       mov     got, 1
@@hk:           CHK     n_hook, got, 1

                ;; a second of our ticks, or two of BIOS time, whichever first
@@wait:         invoke  qglTmrTicks
                test    dx, dx
                jnz     @@waited
                cmp     ax, 1000
                jae     @@waited
                call    bios_delta
                cmp     eax, 40
                jb      @@wait
@@waited:       SAVEP   t1
                call    bios_delta
                mov     bdelta, eax

                ;; 1000 ticks of 1193 PIT cycles is 18.2 BIOS ticks
                mov     got, 1
                cmp     bdelta, 16
                jb      @@bad
                cmp     bdelta, 20
                jbe     @@bok
@@bad:          mov     got, 0
@@bok:          CHK     n_bios, got, 1
                mov     got, 1
                cmp     W t1+2, 0
                jne     @@tok
                cmp     W t1, 1000
                jae     @@tok
                mov     got, 0
@@tok:          CHK     n_ticks, got, 1

                invoke  qglTmrShutdown

                mov     ax, 3508h
                int     21h
                mov     ax, es
                cmp     ax, old_seg
                jne     @@notback
                cmp     bx, old_ofs
                jne     @@notback
                mov     got, 1
                jmp     @@bk
@@notback:      mov     got, 0
@@bk:           CHK     n_back, got, 1

                invoke  qglTmrTicks
                SAVEP   t2
                invoke  bios_wait, 3
                invoke  qglTmrTicks
                SAVEP   t3
                mov     eax, t3
                sub     eax, t2
                mov     got, ax
                CHK     n_stop, got, 0

                ;; two reads a BIOS tick apart: cycles ran, so the later is larger
                invoke  qglTmrCycles
                SAVEP   t2
                invoke  bios_wait, 1
                invoke  qglTmrCycles
                SAVEP   t3
                mov     eax, t3
                sub     eax, t2
                mov     got, 0
                cmp     eax, 1000
                jbe     @F
                mov     got, 1
@@:             CHK     n_tsc, got, 1

                ret
tmain           endp
                end
