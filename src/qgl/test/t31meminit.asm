;; t31meminit -- qglMemInit links the UMBs and asks for them first, and
;;               qglMemShutdown puts DOS back the way it found it.
;;
;; Read back through DOS's own queries, 5802h and 5800h, not qgl's record
;; of what it asked for. DOSBox starts with the link off and strategy 0,
;; which is what makes the restore observable.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglMemInit      proto   far
qglMemShutdown  proto   far

.data
n_link          db      'UMBs linked            $'
n_strat         db      'strategy 81h           $'
n_link0         db      'link restored          $'
n_strat0        db      'strategy restored      $'

link0           dw      0
strat0          dw      0
got             dw      0

.code

tmain           proc    far public uses bx cx dx si di es

                mov     ax, 5802h
                int     21h
                movzx   ax, al
                mov     link0, ax
                mov     ax, 5800h
                int     21h
                mov     strat0, ax

                invoke  qglMemInit

                mov     ax, 5802h
                int     21h
                movzx   ax, al
                mov     got, ax
                CHK     n_link, got, 1
                mov     ax, 5800h
                int     21h
                mov     got, ax
                CHK     n_strat, got, 81h

                invoke  qglMemShutdown

                mov     ax, 5802h
                int     21h
                movzx   ax, al
                mov     got, ax
                CHK     n_link0, got, link0
                mov     ax, 5800h
                int     21h
                mov     got, ax
                CHK     n_strat0, got, strat0

                ret
tmain           endp
                end
