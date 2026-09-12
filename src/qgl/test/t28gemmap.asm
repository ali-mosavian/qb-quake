;; t28gemmap -- qglGemMap remaps only when the slot's page changes, and
;; forgets a handle when it is freed.
;;
;; ar.asm asks for the page it already has on every access; it is gem's
;; record of what each slot holds that makes a sequential walk cost a
;; compare and not an INT 67h, as mgl's emsMapEx did. And EMM hands a
;; freed handle's number straight back to the next allocation, so a
;; record that survived qglGemFree would answer the new handle's first
;; map with the old page and never issue the call.
;;
;; The instrument is INT 67h itself: a hook counts every function 44h on
;; its way to the driver, so "no remap" is a number and not an inference.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

SLOT            equ     2
OTHER           equ     3

.data
n_ems           db      'EMS is there           $'
n_first         db      'first map issues INT   $'
n_again         db      'same page issues none  $'
n_seg           db      'and the same segment   $'
n_page1         db      'new page issues one    $'
n_other         db      'other slot issues one  $'
n_back          db      'page 0 back reads p0   $'
n_p1            db      'page 1 back reads p1   $'
n_reuse         db      'EMM reused the handle  $'
n_freed         db      'map after free issues  $'
n_bad0          db      'slot 4 returns 0       $'
n_bad           db      'slot 4 issues none     $'

hA              dw      0
hB              dw      0
seg0            dw      0
got             dw      0

.code

;; the hook and its state live in the code segment: an interrupt arrives
;; with whatever ds the interrupted code had
calls           dw      0
oldvec          dd      0

hook            proc    far private
                cmp     ah, 44h
                jne     @F
                inc     W cs:calls
@@:             jmp     D cs:oldvec
hook            endp

COUNT           macro
                mov     ax, W cs:calls
                mov     got, ax
                endm

RESET           macro
                mov     W cs:calls, 0
                endm

tmain           proc    far public uses bx cx dx si di es

                invoke  qglGemInit
                NZ      ax
                CHK     n_ems, ax, 1

                mov     ax, 3567h
                int     21h
                mov     W cs:oldvec, bx
                mov     W cs:oldvec+2, es
                push    ds
                mov     ax, seg hook
                mov     ds, ax
                mov     dx, offset hook
                mov     ax, 2567h
                int     21h
                pop     ds

                invoke  qglGemAlloc, 32768      ;; two pages
                mov     hA, ax

                RESET
                invoke  qglGemMap, hA, 0, SLOT
                mov     seg0, ax
                mov     es, ax
                mov     byte ptr es:[0], 55h
                COUNT
                CHK     n_first, got, 1

                invoke  qglGemMap, hA, 0, SLOT
                mov     bx, ax
                COUNT
                CHK     n_again, got, 1
                CHK     n_seg, bx, seg0

                invoke  qglGemMap, hA, 1, SLOT
                mov     es, ax
                mov     byte ptr es:[0], 0AAh
                COUNT
                CHK     n_page1, got, 2

                invoke  qglGemMap, hA, 1, OTHER
                COUNT
                CHK     n_other, got, 3

                invoke  qglGemMap, hA, 0, SLOT
                mov     es, ax
                mov     al, es:[0]
                xor     ah, ah
                CHK     n_back, ax, 55h

                invoke  qglGemMap, hA, 1, SLOT
                mov     es, ax
                mov     al, es:[0]
                xor     ah, ah
                CHK     n_p1, ax, 0AAh

                ;; free with page 0 on record in SLOT, allocate again, and
                ;; the new handle's map of page 0 there has to reach the
                ;; driver -- a record that survived the free says it is
                ;; already there
                invoke  qglGemMap, hA, 0, SLOT
                invoke  qglGemFree, hA
                invoke  qglGemAlloc, 16384
                mov     hB, ax
                CHK     n_reuse, hB, hA
                RESET
                invoke  qglGemMap, hB, 0, SLOT
                COUNT
                CHK     n_freed, got, 1

                RESET
                invoke  qglGemMap, hB, 0, 4
                CHK     n_bad0, ax, 0
                COUNT
                CHK     n_bad, got, 0

                invoke  qglGemFree, hB

                push    ds
                lds     dx, D cs:oldvec
                mov     ax, 2567h
                int     21h
                pop     ds

                ret
tmain           endp
                end
