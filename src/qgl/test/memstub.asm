;; memstub.asm -- memAlloc/memFree over a static pool.
;;
;; NOT a convenience. A bare jwlink EXE claims all free DOS memory at
;; load, so int 21h/48h has nothing left to give and the real allocator
;; cannot be used from a test at all. mgl's own scratch suite hit this
;; first and solved it the same way.
;;
;; The pool never shrinks, which is the allocator's own contract for its
;; blocks anyway -- qgl_sf_free hands memory back but nothing here has to
;; reuse it for a test to be meaningful.

                .model  medium, pascal
                .386

POOL_PARAS      equ     4096            ;; 64K, enough for a >64K surface
                                        ;; test to fail honestly rather
                                        ;; than by running out here

POOLSEG         segment para 'FAR_DATA'
                db      POOL_PARAS*16 dup (?)
POOLSEG         ends

.data
p_used          dw      0               ;; paragraphs handed out

.code
memAlloc        proc    far public, nbytes:dword
                mov     eax, nbytes
                add     eax, 15
                shr     eax, 4                  ;; paragraphs
                mov     bx, ax
                add     ax, p_used
                cmp     ax, POOL_PARAS
                ja      @F
                mov     dx, POOLSEG
                add     dx, p_used
                mov     p_used, ax
                xor     ax, ax                  ;; dx:ax, offset 0
                ret
@@:             xor     ax, ax
                xor     dx, dx
                ret
memAlloc        endp

;; Accepted and ignored: the pool is reclaimed when the process exits.
memFree         proc    far public, p:dword
                ret
memFree         endp

                end
