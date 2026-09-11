;; t34dsp -- the Sound Blaster plays the ring at the rate asked for.
;;
;; Three BIOS ticks are 165 ms, 1819 samples at 11025 Hz: the DMA position
;; must have moved about that far -- the emulator feeds its mixer in
;; blocks, so within 600 -- which a wrong channel (no movement), a wrong
;; rate (twice or half the distance) or a wrong count register (garbage)
;; all fail. Then over ten ticks it wraps the 4096 ring at least once, and
;; after qglDspShutdown the vector is the one that was there.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglDspInit      proto   far :word
qglDspPos       proto   far
qglDspBuf       proto   far
qglDspShutdown  proto   far

BIOS_TICK       equ     6Ch
SB_IRQ_VEC      equ     0Fh
RING            equ     4096

.data
n_init          db      'DSP answered           $'
n_buf           db      'ring aligned to 4096   $'
n_adv           db      '3 ticks move 1219..2419$'
n_wrap          db      'ten ticks wrap the ring$'
n_back          db      'vector restored        $'

old_ofs         dw      0
old_seg         dw      0
p0              dw      0
got             dw      0
wraps           dw      0

.code

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

                mov     ax, 3500h + SB_IRQ_VEC
                int     21h
                mov     old_ofs, bx
                mov     old_seg, es

                invoke  qglDspInit, 11025
                CHK     n_init, ax, 1

                invoke  qglDspBuf
                and     dx, 0FFh
                or      dx, ax
                CHK     n_buf, dx, 0

                invoke  bios_wait, 1            ;; align to a tick edge
                invoke  qglDspPos
                mov     p0, ax
                invoke  bios_wait, 3
                invoke  qglDspPos
                sub     ax, p0
                and     ax, RING - 1
                mov     got, 1
                cmp     ax, 1219
                jb      @@bad
                cmp     ax, 2419
                jbe     @@ok
@@bad:          mov     got, 0
@@ok:           CHK     n_adv, got, 1

                ;; ten ticks: 6062 samples, past the ring's end at least once
                mov     wraps, 0
                invoke  qglDspPos
                mov     p0, ax
                mov     cx, 10
@@tick:         push    cx
                invoke  bios_wait, 1
                invoke  qglDspPos
                cmp     ax, p0
                jae     @@nowrap
                inc     wraps
@@nowrap:       mov     p0, ax
                pop     cx
                loop    @@tick
                mov     got, 1
                cmp     wraps, 1
                jae     @@w
                mov     got, 0
@@w:            CHK     n_wrap, got, 1

                invoke  qglDspShutdown

                mov     ax, 3500h + SB_IRQ_VEC
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
                ret
tmain           endp

                end
