;; t21mem -- qglMemAlloc must never hand back a block smaller than asked.
;;
;; DOS 48h reports the largest block it COULD have given in bx when it
;; fails, over the paragraph count it was handed. qglMemAlloc's BASIC
;; fallback re-used bx after that call, so an allocation DOS could not
;; satisfy came back as whatever DOS had spare -- non-null, and short.
;; The caller then wrote the size it asked for.
;;
;; What it cost: with the row-address table in Surface a header is
;; T Surface + yRes*4 rather than a fixed few dozen bytes, so the atlas's
;; 290-byte views were served out of an 80-byte block and 200 bytes of
;; scanline table landed in BASIC's far heap. The next heap compaction --
;; the next FRE(-1), or the next allocation -- span in B$FCompactMove and
;; the renderer hung during load with no output at all.
;;
;; THE FALLBACK IS __BASIC__-ONLY, so this test is assembled with it and
;; supplies its own B$SETM: the point is qglMemAlloc's own arithmetic, not
;; the BASIC runtime's.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglMemAlloc     proto   far :dword
qglMemFree      proto   far :dword

;; More than DOS has under run1.sh's memsize=16, so the first 48h must
;; fail and the fallback must run. 0FFFF0h is 65535 paragraphs exactly.
HUGE_BYTES      equ     0FFFF0h
HUGE_PARAS      equ     0FFFFh

SMALL_BYTES     equ     4096
SMALL_PARAS     equ     256

.data
n_small         db      'small alloc nonnull $'
n_small_sz      db      'small block big enuf$'
n_huge          db      'huge alloc not short$'

blk             dd      0

.code
;;::::::::::::::
;; paras_of -- the MCB's paragraph count for the block at dx:ax.
;;
;; INTERNAL: dx = the block's segment. ax = paragraphs, 0 if dx is null.
paras_of        proc    near private uses es
                xor     ax, ax
                test    dx, dx
                jz      @@out
                mov     ax, dx
                dec     ax                      ;; the block's own MCB
                mov     es, ax
                mov     ax, es:[3]              ;; size, in paragraphs
@@out:          ret
paras_of        endp

tmain           proc    far public uses bx

                ;;
                ;; A request DOS can satisfy outright: the fallback is
                ;; never entered, so this is the control.
                ;;
                invoke  qglMemAlloc, SMALL_BYTES
                SAVEP   blk
                NZ      dx
                CHK     n_small, ax, 1

                mov     dx, W blk+2
                call    paras_of
                cmp     ax, SMALL_PARAS
                mov     ax, 0
                setae   al
                CHK     n_small_sz, ax, 1

                invoke  qglMemFree, blk

                ;;
                ;; And one it cannot. Either answer is correct -- a null,
                ;; or a block that really is that big -- but a non-null
                ;; block SHORTER than the request is the bug.
                ;;
                invoke  qglMemAlloc, HUGE_BYTES
                SAVEP   blk

                mov     dx, W blk+2
                test    dx, dx
                jz      @@refused               ;; null: correct

                call    paras_of
                cmp     ax, HUGE_PARAS
                mov     ax, 0
                setae   al
                push    ax
                invoke  qglMemFree, blk
                pop     ax
                jmp     short @@say

@@refused:      mov     ax, 1
@@say:          CHK     n_huge, ax, 1

                ret
tmain           endp

;;::::::::::::::
;; B$SETM -- the BASIC runtime's SETMEM, stubbed.
;;
;; qglMemAlloc asks it twice: once with 0 for the current heap size, then
;; with a negative delta and compares the two. Answering "large, then
;; nothing" makes the fallback believe it got the memory and go on to the
;; retry -- which is the call under test.
B$SETM          proc    far public,\
                        delta:dword

                mov     ax, W delta
                or      ax, W delta+2
                jnz     @@after

                xor     ax, ax                  ;; the query: a big heap
                mov     dx, 1000h               ;; dx:ax = 0x10000000
                ret

@@after:        xor     ax, ax                  ;; and nothing left of it,
                xor     dx, dx                  ;; so before-new is huge
                ret
B$SETM          endp

                end
