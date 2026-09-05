;; t02mem -- conventional memory: the invariants that must hold, and the
;;           two numbers this suite exists to find out.
;;
;; Note what is NOT asserted: an absolute free figure. It depends on the
;; DOSBox conf, the DOS version and what the loader did, so pinning it
;; would be testing the harness. What is asserted is the relationship --
;; the sum of free blocks cannot be smaller than the largest single one --
;; which is exactly the property memAvail gets wrong when it reports a
;; heap's size instead of its free space.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qgl_mem_alloc   proto   far :dword
qgl_mem_free    proto   far :dword
qgl_mem_copy    proto   far :dword, :dword, :dword
qgl_mem_avail   proto   far
qgl_mem_free_sum proto  far

BLK             equ     4096

.data
n_avail         db      'avail  (largest free)  $'
n_sum           db      'sum    (all free)      $'
n_sum_ge        db      'sum >= largest         $'
n_alloc         db      'alloc 4096 nonzero     $'
n_alloc_ofs     db      'alloc offset is 0      $'
n_rt            db      'write/read round trip  $'
n_copy          db      'copy 4096 bytes exact  $'
n_free0         db      'free of 0:0 is safe    $'
n_shrink        db      'alloc shrinks the sum  $'
n_odd           db      'copy 4095 at odd dst   $'

avail           dd      0
fsum            dd      0
blk_a           dd      0
blk_b           dd      0
fsum2           dd      0

.code
tmain           proc    far public uses bx cx dx si di es

                ;;
                ;; The two numbers, reported rather than asserted.
                ;;
                invoke  qgl_mem_avail
                SAVEP   avail
                invoke  tshow, offset n_avail, avail

                invoke  qgl_mem_free_sum
                SAVEP   fsum
                invoke  tshow, offset n_sum, fsum

                ;; A total smaller than its own largest member would mean
                ;; the walk is reading the chain wrong.
                mov     ax, W fsum+2
                cmp     ax, W avail+2
                ja      @@ge
                jb      @@lt
                mov     ax, W fsum
                cmp     ax, W avail
                jae     @@ge
@@lt:           xor     ax, ax
                jmp     @F
@@ge:           mov     ax, 1
@@:             CHK     n_sum_ge, ax, 1

                ;;
                ;; Allocation. Paragraph granular, so the offset is 0 and
                ;; a caller may do segment arithmetic on what it gets.
                ;;
                invoke  qgl_mem_alloc, BLK
                SAVEP   blk_a
                mov     bx, dx
                or      bx, ax
                NZ      bx
                CHK     n_alloc, ax, 1

                mov     ax, W blk_a
                NZ      ax
                CHK     n_alloc_ofs, ax, 0

                ;; The walk has to distinguish owned from free, and only
                ;; this catches it: taking BLK out of DOS must reduce the
                ;; free total by at least BLK. A walk that counts every
                ;; block reports a total that barely moves, while still
                ;; satisfying sum >= largest -- which is how the weaker
                ;; assertion above let a deliberately broken walk pass.
                invoke  qgl_mem_free_sum
                SAVEP   fsum2
                mov     ax, W fsum
                sub     ax, W fsum2
                mov     bx, W fsum+2
                sbb     bx, W fsum2+2
                mov     cx, 0
                cmp     bx, 0
                jne     @F                      ;; a whole 64K, plenty
                cmp     ax, BLK
                jb      @@noshrink
@@:             mov     cx, 1
@@noshrink:     CHK     n_shrink, cx, 1

                ;; write a walking pattern and read it back
                invoke  tfill, W blk_a+2, W blk_a, BLK, 3
                invoke  tvrfy, W blk_a+2, W blk_a, BLK, 3
                CHK     n_rt, ax, 0

                ;;
                ;; Copy, into a second block so a wrong length shows up
                ;; as a mismatch rather than as a no-op.
                ;;
                invoke  qgl_mem_alloc, BLK
                SAVEP   blk_b
                invoke  tfill, W blk_b+2, W blk_b, BLK, 99

                invoke  qgl_mem_copy, blk_b, blk_a, BLK
                invoke  tvrfy, W blk_b+2, W blk_b, BLK, 3
                CHK     n_copy, ax, 0

                ;; Odd length starting one byte in: forces the align
                ;; run, the dword bulk and the tail all to be non-empty,
                ;; which a 4096-at-0 copy never does.
                invoke  tfill, W blk_b+2, W blk_b, BLK, 99
                invoke  qgl_mem_copy, blk_b, blk_a, BLK-1
                invoke  tvrfy, W blk_b+2, W blk_b, BLK-1, 3
                CHK     n_odd, ax, 0

                invoke  qgl_mem_free, blk_b
                invoke  qgl_mem_free, blk_a

                ;; freeing nothing must not fault -- callers unwind through
                ;; this path when an earlier allocation already failed
                invoke  qgl_mem_free, 0
                CHK     n_free0, 1, 1

                ret
tmain           endp
                end
