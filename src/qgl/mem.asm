;; mem.asm -- conventional memory: allocate, free, copy, and how much
;;            there actually is.
;;
;; name: qgl_mem_alloc / qgl_mem_free / qgl_mem_copy / qgl_mem_avail /
;;       qgl_mem_free_sum
;; desc: DOS blocks, straight from INT 21h. No pool and no sub-allocator
;;       -- every caller here wants one big block for the life of the
;;       program, and a free list would be bookkeeping nothing reads.
;;
;;       The reason this module exists at all is qgl_mem_avail. mgl's
;;       memAvail returns MAX(DOS's largest free block, BASIC's far-heap
;;       size via B$SETM(0)), so it can report the SIZE of a heap rather
;;       than how much of it is free: a live MCB walk found 9,312 bytes
;;       actually free where memAvail said ~260,000. Every placement
;;       decision in this renderer has been made against that number, and
;;       it was the wrong number.
;;
;; obs.: - qgl_mem_avail asks DOS the only question that matters -- how
;;         big a block can I actually get -- by requesting 0FFFFh
;;         paragraphs and reading back what it says it could have given.
;;         That call is EXPECTED to fail; the answer is in bx.
;;       - qgl_mem_free_sum walks the MCB chain from our own PSP forward
;;         and adds up the unowned blocks. Larger than avail whenever
;;         free memory is fragmented, which is the interesting case: a
;;         64K allocation fails against 180K free if no single hole fits.
;;       - allocation is paragraph-granular, so a returned pointer always
;;         has offset 0 and a caller may do segment arithmetic on it.

                .model  medium, pascal
                .386

MCB_SIG_LAST    equ     5Ah             ;; 'Z', last block in the chain
MCB_OWNER_FREE  equ     0

.code

;;::::::::::::::
;; qgl_mem_alloc ( nbytes:dword ) -> dx:ax far ptr, 0:0 on failure
;;::::::::::::::
qgl_mem_alloc   proc    public uses bx cx,\
                        nbytes:dword

                mov     eax, nbytes
                add     eax, 15
                shr     eax, 4                  ;; paragraphs
                test    eax, 0FFFF0000h
                jnz     @F                      ;; past 1MB: not from DOS
                mov     bx, ax
                test    bx, bx
                jz      @F

                mov     ah, 48h
                int     21h
                jc      @F

                mov     dx, ax                  ;; segment
                xor     ax, ax                  ;; offset, always 0
                ret

@@:             xor     ax, ax
                xor     dx, dx
                ret
qgl_mem_alloc   endp


;;::::::::::::::
;; qgl_mem_free ( p:dword )
;;
;; Takes the pointer alloc handed back, not a segment, so a caller never
;; has to remember which half to keep.
;;::::::::::::::
qgl_mem_free    proc    public uses es,\
                        p:dword

                mov     ax, word ptr p+2
                test    ax, ax
                jz      @F
                mov     es, ax
                mov     ah, 49h
                int     21h
@@:             ret
qgl_mem_free    endp


;;::::::::::::::
;; qgl_mem_copy ( dst:dword, src:dword, nbytes:dword )
;;
;; Copies in runs that cannot cross a segment, so a length past 64K is
;; the caller's business and not a trap: an atlas is 114,688 bytes and
;; every one of them has to arrive.
;;::::::::::::::
qgl_mem_copy    proc    public uses bx cx si di ds es,\
                        dst:dword, src:dword, nbytes:dword

                mov     eax, nbytes
                test    eax, eax
                jz      @@done

@@chunk:        ;; how much is left, capped at 32K so neither side can
                ;; run off the end of its segment inside one run
                mov     ecx, nbytes
                cmp     ecx, 8000h
                jbe     @F
                mov     ecx, 8000h
@@:             mov     dx, cx                  ;; this run's length, kept
                mov     bx, cx                  ;; and counted down

                les     di, dst
                lds     si, src

                ;; Bytes to the next dword boundary of the DESTINATION --
                ;; writes are what is worth aligning. A whole run shorter
                ;; than the alignment is legal and handled by the clamp.
                mov     ax, di
                neg     ax
                and     ax, 3
                cmp     ax, bx
                jbe     @F
                mov     ax, bx
@@:             mov     cx, ax
                sub     bx, ax
                rep     movsb

                ;; the bulk, four bytes an instruction
                mov     cx, bx
                shr     cx, 2
                rep     movsd

                ;; and the tail
                mov     cx, bx
                and     cx, 3
                rep     movsb

                ;; advance both, carrying into the segment
                mov     ax, @data
                mov     ds, ax

                movzx   eax, dx
                add     word ptr dst, dx
                adc     word ptr dst+2, 0
                add     word ptr src, dx
                adc     word ptr src+2, 0
                sub     nbytes, eax
                jnz     @@chunk

@@done:         ret
qgl_mem_copy    endp


;;::::::::::::::
;; qgl_mem_avail () -> dx:ax = bytes in the LARGEST free block
;;
;; The only number an allocation actually has to satisfy. Asking for
;; 0FFFFh paragraphs is meant to fail; DOS returns what it could have
;; given in bx.
;;::::::::::::::
qgl_mem_avail   proc    public uses bx
                mov     bx, 0FFFFh
                mov     ah, 48h
                int     21h
                jnc     @F                      ;; it actually gave us 1MB?
                                                ;; then bx is the answer
                mov     ax, bx
                xor     dx, dx
                mov     cx, 4
@@shl:          shl     ax, 1
                rcl     dx, 1
                loop    @@shl
                ret

@@:             ;; succeeded, which should not happen -- hand it back and
                ;; report nothing free rather than lie
                mov     es, ax
                mov     ah, 49h
                int     21h
                xor     ax, ax
                xor     dx, dx
                ret
qgl_mem_avail   endp


;;::::::::::::::
;; qgl_mem_free_sum () -> dx:ax = bytes free across EVERY free block
;;
;; Walks the MCB chain from our own PSP forward, summing the unowned
;; blocks. Bigger than qgl_mem_avail exactly when free memory is
;; fragmented, which is what "183,504 free" meant while a 64,048-byte
;; allocation was failing.
;;::::::::::::::
qgl_mem_free_sum proc   public uses bx cx si di es

                xor     cx, cx                  ;; running total, paragraphs
                xor     di, di                  ;; high half

                mov     ah, 62h
                int     21h                     ;; bx = our PSP
                dec     bx                      ;; its MCB

@@walk:         mov     es, bx
                mov     al, es:[0]              ;; signature
                cmp     al, MCB_SIG_LAST
                je      @@last
                cmp     al, 4Dh                 ;; 'M'
                jne     @@done                  ;; chain is broken; stop

                call    qgl$mcb_add
                mov     ax, es:[3]              ;; size in paragraphs
                add     bx, ax
                inc     bx                      ;; past the header
                jmp     @@walk

@@last:         call    qgl$mcb_add

@@done:         ;; paragraphs -> bytes
                mov     ax, cx
                mov     dx, di
                mov     cx, 4
@@shl:          shl     ax, 1
                rcl     dx, 1
                loop    @@shl
                ret
qgl_mem_free_sum endp


;;::::::::::::::
;; qgl$mcb_add -- add this block's paragraphs to the total if it is free.
;;
;; INTERNAL, registers only: es -> the MCB, cx:di = running paragraph
;; total, and it clobbers ax alone so the walk above keeps bx.
;;::::::::::::::
qgl$mcb_add     proc    near private
                mov     ax, es:[1]              ;; owner PSP
                cmp     ax, MCB_OWNER_FREE
                jne     @F
                mov     ax, es:[3]              ;; paragraphs
                add     cx, ax
                adc     di, 0
@@:             ret
qgl$mcb_add     endp

                end
