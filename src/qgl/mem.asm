;; mem.asm -- conventional memory: allocate, free, copy, and how much
;;            there actually is.
;;
;; name: qglMemInit / qglMemShutdown / qglMemAlloc / qglMemFree / qglMemCopy / qglMemAvail
;; desc: DOS blocks, straight from INT 21h. No pool and no sub-allocator
;;       -- every caller here wants one big block for the life of the
;;       program, and a free list would be bookkeeping nothing reads.
;;
;;       The reason this module exists at all is qglMemAvail. mgl's
;;       memAvail returns MAX(DOS's largest free block, BASIC's far-heap
;;       size via B$SETM(0)), so it can report the SIZE of a heap rather
;;       than how much of it is free: a live MCB walk found 9,312 bytes
;;       actually free where memAvail said ~260,000. Every placement
;;       decision in this renderer has been made against that number, and
;;       it was the wrong number.
;;
;; obs.: - qglMemAvail asks DOS the only question that matters -- how
;;         big a block can I actually get -- by requesting 0FFFFh
;;         paragraphs and reading back what it says it could have given.
;;         That call is EXPECTED to fail; the answer is in bx.
;;       - MEM_TOTAL walks the MCB chain from our own PSP forward
;;         and adds up the unowned blocks. Larger than avail whenever
;;         free memory is fragmented, which is the interesting case: a
;;         64K allocation fails against 180K free if no single hole fits.
;;       - allocation is paragraph-granular, so a returned pointer always
;;         has offset 0 and a caller may do segment arithmetic on it.
;;       - qglMemInit links the upper memory blocks into DOS's chain and
;;         sets strategy 81h, upper memory first: that is where every
;;         block here lands, and it was uglInit's doing until mgl left.
;;         qglMemShutdown puts both back; DOS does not on exit.

                .model  medium, pascal
                .386

                include qgl.inc

;; BASIC's SETMEM, and the only thing in this layer wanting the
;; BASIC runtime -- so it sits behind __BASIC__, which the
;; renderer's build defines and the test suite does not. Without
;; it qgl links free-standing and an allocation DOS refuses just
;; fails, which is the honest answer for a standalone caller.
IFDEF __BASIC__
B$SETM          proto   far pascal :dword
ENDIF

MCB_SIG_LAST    equ     5Ah             ;; 'Z', last block in the chain
MCB_SIG_MORE    equ     4Dh             ;; 'M', more follow
MCB_OWNER_FREE  equ     0

.code

;;::::::::::::::
;; qglMemAlloc ( nbytes:dword ) -> dx:ax far ptr, 0:0 on failure
;;::::::::::::::
qglMemAlloc   proc    public uses bx cx,\
                        nbytes:dword

IFDEF __BASIC__
                local   before:dword
                local   want:dword
ENDIF
                mov     eax, nbytes
                add     eax, 15
                shr     eax, 4                  ;; paragraphs
                test    eax, 0FFFF0000h
                jnz     @@fail                  ;; past 1MB: not from DOS
                mov     bx, ax
                test    bx, bx
                jz      @@fail

                ;; BX IS THE REQUEST GOING IN AND DOS'S ANSWER COMING OUT.
                ;; A failing 48h reports the largest block it COULD have
                ;; given, in bx, over the count we asked for -- so the
                ;; retry below allocated that instead, and a caller writing
                ;; the size it asked for ran off the end of a short block.
                ;; mgl's bas_malloc brackets the call for this reason.
                push    bx
                mov     ah, 48h
                int     21h
                pop     bx
                jnc     @@got

IFDEF __BASIC__
                ;;
                ;; DOS has nothing, which on this host means BASIC's far
                ;; heap has it -- the whole gap between memAvail's 136,416
                ;; and the 3,632 DOS will actually hand over. Ask BASIC to
                ;; give some back and try again.
                ;;
                ;; VERIFIED, unlike mgl's bas_malloc, which this repo has
                ;; recorded as corrupting on this arena (see
                ;; docs/knowledge/qrender-memory-map.md). B$SETM's own
                ;; source says what it returns: "DX:AX = 32-bit size of
                ;; near and far heaps in bytes" -- the SIZE, not the free
                ;; tail. mgl's comment calls it "largest free block size"
                ;; and branches on it, then never checks that the shrink
                ;; it asks for happened. BASIC cannot shrink past live
                ;; data; it says so by returning a size that did not move,
                ;; and mgl walks on into memory BASIC still owns.
                ;;
                push    bx
                invoke  B$SETM, 0
                mov     word ptr before, ax
                mov     word ptr before+2, dx

                pop     bx
                push    bx
                movzx   eax, bx
                shl     eax, 4
                add     eax, 16                 ;; the block's own MCB
                mov     want, eax

                neg     eax                     ;; SETMEM takes a delta
                invoke  B$SETM, eax             ;; dx:ax = the new size

                movzx   ebx, ax
                movzx   ecx, dx
                shl     ecx, 16
                or      ebx, ecx                ;; ebx = new size

                mov     eax, before
                sub     eax, ebx                ;; what it really gave back
                cmp     eax, want
                jb      @@giveback              ;; less than asked: stop

                pop     bx
                mov     ah, 48h
                int     21h
                jnc     @@got
                push    bx

@@giveback:     pop     bx
                invoke  B$SETM, 7FFFFFFFh       ;; take back what we can
ENDIF
@@fail:         xor     ax, ax
                xor     dx, dx
                ret

@@got:          ;;
                ;; PROVE THE BLOCK IS MEMORY BEFORE HANDING IT OVER.
                ;;
                ;; DOS reported nothing free -- BASIC owns the arena --
                ;; and 48h still returned carry clear with segment 9FFFh
                ;; for a 33 paragraph request, one paragraph under the
                ;; 640K line. A surface built there runs into VGA at
                ;; A000h and every pixel reads back FFh.
                ;;
                ;; An address bound was tried first and did not fire. So
                ;; this writes a sentinel to the first and last byte and
                ;; reads it back, which tests the thing that actually
                ;; matters and does not care why the block was wrong --
                ;; note it does NOT test the block's SIZE, which is why a
                ;; short block got past it. t21mem covers that.
                ;;
                ;; This is the arena AGENTS.md records mgl's bas_malloc
                ;; corrupting. The comment above claiming this path was
                ;; VERIFIED was written before anything called it from
                ;; BASIC; the first BASIC caller found it in one run.
                ;;
                PS      bx, cx, di, es
                mov     es, ax
                mov     ecx, nbytes
                dec     ecx
                cmp     ecx, 0FFFFh             ;; only the first 64K is
                jbe     @F                      ;; reachable this way
                mov     ecx, 0FFFFh
@@:             mov     di, cx

                mov     bl, es:[0]
                mov     bh, es:[di]
                mov     byte ptr es:[0], 05Ah
                mov     byte ptr es:[di], 0A5h
                cmp     byte ptr es:[0], 05Ah
                jne     @@dead
                cmp     byte ptr es:[di], 0A5h
                jne     @@dead
                mov     es:[0], bl              ;; leave it as we found it
                mov     es:[di], bh
                PP      es, di, cx, bx

                mov     dx, ax                  ;; segment
                xor     ax, ax                  ;; offset, always 0
                ret

@@dead:         PP      es, di, cx, bx
                push    ax
                mov     es, ax                  ;; give it straight back
                mov     ah, 49h
                int     21h
                pop     ax
                xor     ax, ax
                xor     dx, dx
                ret
qglMemAlloc   endp


;;::::::::::::::
;; qglMemFree ( p:dword )
;;
;; Takes the pointer alloc handed back, not a segment, so a caller never
;; has to remember which half to keep.
;;::::::::::::::
qglMemFree    proc    public uses es,\
                        p:dword

                mov     ax, word ptr p+2
                test    ax, ax
                jz      @F
                mov     es, ax
                mov     ah, 49h
                int     21h
@@:             ret
qglMemFree    endp


;;::::::::::::::
;; qglMemCopy ( dst:dword, src:dword, nbytes:dword )
;;
;; Copies in runs that cannot cross a segment, so a length past 64K is
;; the caller's business and not a trap: an atlas is 114,688 bytes and
;; every one of them has to arrive.
;;::::::::::::::
qglMemCopy    proc    public uses bx cx si di ds es,\
                        dst:dword, src:dword, nbytes:dword

                cld
                mov     eax, nbytes
                test    eax, eax
                jz      @@done

                ;; NORMALISE BOTH ENDS FIRST. Capping a run at 32K only
                ;; keeps it inside a segment if the pointer started near
                ;; the bottom of one; a caller may hand in any valid far
                ;; pointer, and one at offset FFF0h has sixteen bytes left
                ;; before rep movsb wraps to the start of the same segment
                ;; and overwrites what it just read. Folding the offset
                ;; into the segment makes every run below safe by
                ;; construction rather than by the caller's good manners.
                FARADD  dst, 0
                FARADD  src, 0

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
                sub     nbytes, eax             ;; before FARADD takes ax

                FARADD  dst, dx
                FARADD  src, dx

                cmp     nbytes, 0
                jnz     @@chunk

@@done:         ret
qglMemCopy    endp


;;::::::::::::::
;; qglMemAvail ( what:word ) -> dx:ax = bytes
;;
;; MEM_LARGEST is what an allocation actually has to satisfy; MEM_TOTAL
;; is every free block added up. Reporting only one of them is how "183
;; kB free" and "the 64 kB allocation failed" were both true at once, so
;; the caller says which it means.
;;
;; Dispatched, not branched: what IS the byte offset into qgl$memTB.
;;::::::::::::::
qglMemAvail   proc    public uses bx,\
                        what:word

                mov     bx, what
                cmp     bx, MEM_KINDS
                jae     @F                      ;; not a selector we have
                imul    bx, T MemOps            ;; a selector, not an index
                call    qgl$memTB[bx].query
                ret

@@:             xor     ax, ax
                xor     dx, dx
                ret
qglMemAvail   endp


;;::::::::::::::
;; qgl$AvailLargest -- the biggest single block DOS will hand over.
;;
;; INTERNAL, no arguments, dx:ax back. Asking for 0FFFFh paragraphs is
;; MEANT to fail; the answer is what DOS puts in bx on the way out.
;;::::::::::::::
qgl$mem_umb     db      0               ;; DOS's UMB link before init
qgl$mem_strat   dw      0               ;; and its strategy
qgl$mem_on      dw      0

;;::::::::::::::
;; qglMemInit () -- UMBs linked, strategy 81h. A second call changes nothing.
;;::::::::::::::
qglMemInit    proc    public uses bx

                cmp     cs:qgl$mem_on, 0
                jne     @@done
                mov     ax, 5802h               ;; UMB link state
                int     21h
                jc      @@done
                mov     cs:qgl$mem_umb, al
                mov     ax, 5800h               ;; strategy
                int     21h
                jc      @@done
                mov     cs:qgl$mem_strat, ax
                mov     ax, 5803h
                mov     bx, 1
                int     21h
                mov     ax, 5801h
                mov     bx, 81h
                int     21h
                mov     cs:qgl$mem_on, 1
@@done:         ret
qglMemInit    endp


;;::::::::::::::
;; qglMemShutdown () -- the link and the strategy as they were
;;::::::::::::::
qglMemShutdown proc   public uses ax bx

                cmp     cs:qgl$mem_on, 0
                je      @@done
                mov     cs:qgl$mem_on, 0
                mov     ax, 5801h
                mov     bx, cs:qgl$mem_strat
                int     21h
                mov     ax, 5803h
                movzx   bx, cs:qgl$mem_umb
                int     21h
@@done:         ret
qglMemShutdown endp


qgl$AvailLargest proc  near private uses bx cx es
                mov     bx, 0FFFFh
                mov     ah, 48h
                int     21h
                jnc     @F                      ;; a whole megabyte? then
                                                ;; bx is still the answer
                mov     ax, bx
                xor     dx, dx
                call    qgl$ParasToBytes
                ret

@@:             ;; it succeeded, which should not happen. Give it back and
                ;; report nothing rather than report a lie.
                mov     es, ax
                mov     ah, 49h
                int     21h
                xor     ax, ax
                xor     dx, dx
                ret
qgl$AvailLargest endp


;;::::::::::::::
;; qgl$AvailTotal -- every free block in the chain, added up.
;;
;; INTERNAL, no arguments, dx:ax back. Walks the MCB chain from our own
;; PSP forward. Bigger than largest exactly when free memory is
;; fragmented, which is the case worth seeing.
;;::::::::::::::
qgl$AvailTotal proc    near private uses bx cx si di es

                xor     cx, cx                  ;; running total, paragraphs
                xor     di, di                  ;; high half

                mov     ah, 62h
                int     21h                     ;; bx = our PSP
                dec     bx                      ;; its MCB

@@walk:         mov     es, bx
                mov     al, es:[0]              ;; signature
                cmp     al, MCB_SIG_LAST
                je      @@last
                cmp     al, MCB_SIG_MORE
                jne     @@done                  ;; chain is broken; stop

                call    qgl$McbParas
                add     cx, ax
                adc     di, 0
                mov     ax, es:[3]              ;; size in paragraphs
                add     bx, ax
                inc     bx                      ;; past the header
                jmp     @@walk

@@last:         call    qgl$McbParas
                add     cx, ax
                adc     di, 0

@@done:         mov     ax, cx
                mov     dx, di
                call    qgl$ParasToBytes
                ret
qgl$AvailTotal endp

;;:::::::::::::: a selector that is not one
qgl$AvailNone  proc    near private
                xor     ax, ax
                xor     dx, dx
                ret
qgl$AvailNone  endp


;;::::::::::::::
;; qgl$McbParas -- this block's paragraphs, or 0 if it is owned.
;;
;; INTERNAL: es -> the MCB, ax back, everything else untouched. It
;; RETURNS the count rather than adding into the caller's accumulator --
;; an internal that writes cx and di behind its caller's back is the
;; thing qgl.inc's contract forbids, and the caller can add.
;;::::::::::::::
qgl$McbParas   proc    near private
                mov     ax, es:[1]              ;; owner PSP
                cmp     ax, MCB_OWNER_FREE
                jne     @F
                mov     ax, es:[3]              ;; paragraphs
                ret
@@:             xor     ax, ax
                ret
qgl$McbParas   endp


;;::::::::::::::
;; qgl$ParasToBytes -- dx:ax paragraphs -> dx:ax bytes.
;;
;; INTERNAL. Both queries end here, which is the only reason it is a
;; routine rather than five inline instructions twice.
;;::::::::::::::
qgl$ParasToBytes proc near private uses cx
                mov     cx, 4
@@:             shl     ax, 1
                rcl     dx, 1
                loop    @B
                ret
qgl$ParasToBytes endp


.data
;; One entry per selector, indexed by MEM_LARGEST / MEM_TOTAL.
qgl$memTB       MemOps  <O qgl$AvailLargest>
                MemOps  <O qgl$AvailNone>      ;; not a selector
                MemOps  <O qgl$AvailTotal>

                end
