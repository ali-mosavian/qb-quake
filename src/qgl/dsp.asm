;; dsp.asm -- the Sound Blaster: an 8-bit mono ring the DSP plays by DMA.
;;
;; name: qglDspInit / qglDspPos / qglDspBuf / qglDspScratch / qglDspShutdown
;; desc: Quake's snd_dos.c on the SB16 path. The DSP at 220h is reset and
;;       asked its version; a 4096-byte ring is taken from qglMemAlloc and
;;       aligned to 4096 so it never crosses a 64K DMA page, filled with
;;       silence (128), and DMA channel 1 streams it in auto-init mode
;;       while the DSP plays 8-bit unsigned mono at the rate asked for,
;;       half the ring a block. Nobody waits for an interrupt: the mixer
;;       asks qglDspPos where the DMA is and writes ahead of it. The IRQ
;;       still fires every block, so a stub on IRQ 7 -- DOSBox's default
;;       for the card -- acknowledges it, or the BIOS's iret would leave
;;       the PIC's in-service bit set for the rest of the run.
;;
;; obs.: - the DMA count is the whole ring less one, the DSP's block half
;;         the ring less one; both are n-1 and they are not the same n.
;;       - the mode byte is 59h: single, auto-init, memory to card, and
;;         the channel number in the low two bits. 58h is channel 0.
;;       - qglDspPos clears the flip-flop and reads the count with
;;         interrupts off; the flip-flop is global to the controller.
;;       - qglDspShutdown is idempotent and runs from every exit path.
;;       - a machine without the card fails the reset and nothing else
;;         is touched: the game runs silent.

                .model  medium, pascal
                .386

                include qgl.inc

qglMemAlloc     proto   far pascal :dword
qglMemFree      proto   far pascal :dword

DSP_BASE        equ     220h
DSP_RESET       equ     DSP_BASE + 6
DSP_READ        equ     DSP_BASE + 0Ah
DSP_WRITE       equ     DSP_BASE + 0Ch          ;; bit 7 set: busy
DSP_RSTAT       equ     DSP_BASE + 0Eh          ;; bit 7 set: a byte waits; reading acks the 8-bit IRQ

DMA_CHAN        equ     1
DMA_ADDR        equ     02h
DMA_COUNT       equ     03h
DMA_MASK        equ     0Ah
DMA_MODE        equ     0Bh
DMA_FLIP        equ     0Ch
DMA_PAGE        equ     83h
DMA_MODE_BYTE   equ     58h + DMA_CHAN          ;; single, auto-init, read from memory

SB_IRQ_VEC      equ     0Fh                     ;; IRQ 7
PIC_CMD         equ     20h
PIC_EOI         equ     20h

DSP_RING        equ     4096
DSP_SCRATCH     equ     2864                    ;; the mixer's, after the ring: snd_mix.c's
                                                ;; paint buffer, 128 (offset, length) records,
                                                ;; 40 channels of 14 bytes, and the codec's
                                                ;; 512-byte table and decoded run. snd_mix_setup
                                                ;; refuses a layout longer than this rather than
                                                ;; running off the block, which it once did by
                                                ;; 304 bytes and hung in the heap compactor.
DSP_ALLOC       equ     DSP_RING*2 + DSP_SCRATCH

.code

qgl$dsp_on      dw      0
qgl$dsp_block   dd      0                       ;; what qglMemAlloc gave
qgl$dsp_ring    dw      0                       ;; its 4096-aligned segment
qgl$dsp_old     dd      0

;;::::::::::::::
;; the IRQ 7 handler: ack the DSP, ack the PIC
;;::::::::::::::
qgl$DspIsr      proc    far private
                push    ax
                push    dx
                mov     dx, DSP_RSTAT
                in      al, dx
                mov     al, PIC_EOI
                out     PIC_CMD, al
                pop     dx
                pop     ax
                iret
qgl$DspIsr      endp


;; -> ax = 1 if the DSP answered AAh to a reset, else 0
qgl$dsp_reset   proc    near private uses cx dx
                mov     dx, DSP_RESET
                mov     al, 1
                out     dx, al
                mov     cx, 2000
@@hold:         in      al, dx                  ;; a few microseconds
                loop    @@hold
                xor     al, al
                out     dx, al
                mov     cx, 0FFFFh
@@poll:         mov     dx, DSP_RSTAT
                in      al, dx
                test    al, 80h
                jz      @@next
                mov     dx, DSP_READ
                in      al, dx
                cmp     al, 0AAh
                je      @@ok
@@next:         loop    @@poll
                xor     ax, ax
                ret
@@ok:           mov     ax, 1
                ret
qgl$dsp_reset   endp


;; al -> the DSP, bounded: a card that never clears busy costs 64K polls
qgl$dsp_write   proc    near private uses ax cx dx
                mov     ah, al
                mov     dx, DSP_WRITE
                mov     cx, 0FFFFh
@@busy:         in      al, dx
                test    al, 80h
                jz      @@go
                loop    @@busy
@@go:           mov     al, ah
                out     dx, al
                ret
qgl$dsp_write   endp


;; -> al from the DSP, bounded the same way
qgl$dsp_read    proc    near private uses cx dx
                mov     dx, DSP_RSTAT
                mov     cx, 0FFFFh
@@wait:         in      al, dx
                test    al, 80h
                jnz     @@got
                loop    @@wait
@@got:          mov     dx, DSP_READ
                in      al, dx
                ret
qgl$dsp_read    endp


;;::::::::::::::
;; qglDspInit ( rate:word ) -> ax = 1 playing, 0 no card (nothing kept)
;;::::::::::::::
qglDspInit      proc    public uses bx cx dx si di es,\
                        rate:word

                cmp     cs:qgl$dsp_on, 0
                jne     @@yes

                call    qgl$dsp_reset
                test    ax, ax
                jz      @@no

                mov     al, 0E1h                ;; version: the SB16 commands need 4.x
                call    qgl$dsp_write
                call    qgl$dsp_read
                cmp     al, 4
                jb      @@no
                call    qgl$dsp_read            ;; the minor, unused

                invoke  qglMemAlloc, DSP_ALLOC
                mov     bx, ax
                or      bx, dx
                jz      @@no
                mov     W cs:qgl$dsp_block, ax
                mov     W cs:qgl$dsp_block+2, dx
                ;; the ring starts at the next 4096-byte physical boundary:
                ;; offset 0 of a segment that is a multiple of 100h paragraphs
                shr     ax, 4
                add     dx, ax
                add     dx, 0FFh
                and     dx, 0FF00h
                mov     cs:qgl$dsp_ring, dx

                ;; silence, not zero: 128 is the 8-bit unsigned midpoint
                mov     es, dx
                xor     di, di
                mov     al, 80h
                mov     cx, DSP_RING + DSP_SCRATCH
                cld
                rep     stosb

                ;; IRQ 7: our stub, the old vector kept
                mov     ax, 3500h + SB_IRQ_VEC
                int     21h
                mov     W cs:qgl$dsp_old, bx
                mov     W cs:qgl$dsp_old+2, es
                push    ds
                mov     ax, cs
                mov     ds, ax
                mov     dx, O qgl$DspIsr
                mov     ax, 2500h + SB_IRQ_VEC
                int     21h
                pop     ds

                ;; the DMA controller: channel 1 masked while it is programmed;
                ;; address = segment * 16, whose low 16 bits are (seg shl 4)
                ;; and whose page is seg shr 12
                mov     al, 4 + DMA_CHAN
                out     DMA_MASK, al
                out     DMA_FLIP, al
                mov     al, DMA_MODE_BYTE
                out     DMA_MODE, al
                mov     bx, cs:qgl$dsp_ring
                mov     ax, bx
                shl     ax, 4
                out     DMA_ADDR, al
                mov     al, ah
                out     DMA_ADDR, al
                mov     ax, bx
                shr     ax, 12
                out     DMA_PAGE, al
                out     DMA_FLIP, al
                mov     ax, DSP_RING - 1
                out     DMA_COUNT, al
                mov     al, ah
                out     DMA_COUNT, al
                mov     al, DMA_CHAN
                out     DMA_MASK, al

                ;; the DSP: speaker on, the rate high byte first, then 8-bit
                ;; unsigned mono auto-init with half the ring a block
                mov     al, 0D1h
                call    qgl$dsp_write
                mov     al, 41h
                call    qgl$dsp_write
                mov     ax, rate
                mov     al, ah
                call    qgl$dsp_write
                mov     ax, rate
                call    qgl$dsp_write
                mov     al, 0C6h
                call    qgl$dsp_write
                xor     al, al
                call    qgl$dsp_write
                mov     ax, DSP_RING/2 - 1
                call    qgl$dsp_write
                mov     al, ah
                call    qgl$dsp_write

                mov     cs:qgl$dsp_on, 1
@@yes:          mov     ax, 1
                ret
@@no:           xor     ax, ax
                ret
qglDspInit      endp


;;::::::::::::::
;; qglDspPos () -> ax = the sample the DMA is on, 0..4095
;;
;; The count register reads bytes-remaining-1; reading DSP_RSTAT first is
;; the 8-bit acknowledge, so a block end never goes unacked even with the
;; IRQ masked.
;;::::::::::::::
qglDspPos       proc    public uses dx
                cmp     cs:qgl$dsp_on, 0
                je      @@zero
                mov     dx, DSP_RSTAT
                in      al, dx
                cli
                out     DMA_FLIP, al
                in      al, DMA_COUNT
                mov     ah, al
                in      al, DMA_COUNT
                xchg    al, ah
                sti
                inc     ax                      ;; remaining
                neg     ax                      ;; ring - remaining, mod 4096
                and     ax, DSP_RING - 1
                ret
@@zero:         xor     ax, ax
                ret
qglDspPos       endp


;;::::::::::::::
;; qglDspBuf () -> dx:ax = the ring, 4096 bytes
;; qglDspScratch () -> dx:ax = DSP_SCRATCH bytes after it, the mixer's own
;; qglDspScratchBytes () -> ax = how many, for the mixer to check its layout
;;::::::::::::::
qglDspBuf       proc    public
                mov     dx, cs:qgl$dsp_ring
                xor     ax, ax
                ret
qglDspBuf       endp

qglDspScratch   proc    public
                mov     dx, cs:qgl$dsp_ring
                add     dx, DSP_RING/16
                xor     ax, ax
                ret
qglDspScratch   endp

qglDspScratchBytes proc public
                mov     ax, DSP_SCRATCH
                ret
qglDspScratchBytes endp


;;::::::::::::::
;; qglDspShutdown ()
;;::::::::::::::
qglDspShutdown  proc    public uses eax dx ds
                cmp     cs:qgl$dsp_on, 0
                je      @@done
                mov     cs:qgl$dsp_on, 0

                mov     al, 0D3h                ;; speaker off
                call    qgl$dsp_write
                call    qgl$dsp_reset           ;; stops the transfer
                mov     al, 4 + DMA_CHAN
                out     DMA_MASK, al

                mov     dx, W cs:qgl$dsp_old
                mov     ds, W cs:qgl$dsp_old+2
                mov     ax, 2500h + SB_IRQ_VEC
                int     21h

                mov     eax, cs:qgl$dsp_block
                invoke  qglMemFree, eax
@@done:         ret
qglDspShutdown  endp

                end
