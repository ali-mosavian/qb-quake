;; t30in -- the keyboard hook sees a real key, the mouse keeps the position
;;          it is given.
;;
;; run1.sh types 'a' three times through the emulator's AUTOTYPE, a second
;; in, so the INT 9 hook is driven by the hardware path and not by a call:
;; the table must show scancode 1Eh down, then up, and word 0 must have
;; carried the code. Three, because AUTOTYPE feeds the keyboard buffer
;; from a host thread with no lock and dropped one release under load; a
;; later pair still shows both transitions. Bounded by the BIOS tick so a
;; hook that never fires fails here rather than hanging the suite.
;; Afterwards the vector is the one that was there before.
;;
;; The mouse cannot be moved headlessly, so the driver's callback is
;; called the way the driver would: mickeys in si:di, buttons in bx.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglKbdInit      proto   far :far ptr
qglKbdShutdown  proto   far
qglMouseInit    proto   far :far ptr, :word, :word
qglMousePos     proto   far :word, :word
qglMouseEvent   proto   far
qglMouseShutdown proto  far

BIOS_TICK       equ     6Ch
SC_A            equ     1Eh

.data
n_down          db      'a came down            $'
n_last          db      'and word 0 said 1Eh    $'
n_up            db      'a went up              $'
n_back          db      'INT 9 restored         $'
n_ms            db      'mouse driver present   $'
n_ctr           db      'starts at 159,99       $'
n_pos           db      'pos 100,50             $'
n_clip          db      'pos 400,300 clips      $'
n_neg           db      'pos -5,-5 clips        $'
n_ev            db      'event moves 20,10 left $'
n_ev2           db      'same mickeys: no move  $'
n_rt            db      'right button           $'
n_evclip        db      'event clips            $'

keys            dw      128 dup (0)
ms              dw      6 dup (0)

old_ofs         dw      0
old_seg         dw      0
seen_down       dw      0
seen_last       dw      0
seen_up         dw      0
got             dw      0

.code

tmain           proc    far public uses bx cx dx si di es

                mov     ax, 3509h
                int     21h
                mov     old_ofs, bx
                mov     old_seg, es

                invoke  qglKbdInit, addr keys

                ;; six seconds of BIOS ticks for the key to arrive and go
                mov     ax, 40h
                mov     es, ax
                mov     ebx, es:[BIOS_TICK]
                add     ebx, 110
@@spin:         cmp     es:[BIOS_TICK], ebx
                jae     @@spun
                cmp     keys[SC_A*2], -1
                jne     @@notdown
                mov     seen_down, 1
                cmp     keys[0], SC_A
                jne     @@spin
                mov     seen_last, 1
                jmp     @@spin
@@notdown:      cmp     seen_down, 0
                je      @@spin
                mov     seen_up, 1
@@spun:         CHK     n_down, seen_down, 1
                CHK     n_last, seen_last, 1
                CHK     n_up, seen_up, 1

                invoke  qglKbdShutdown
                mov     ax, 3509h
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

                invoke  qglMouseInit, addr ms, 319, 199
                CHK     n_ms, ax, -1
                mov     ax, ms[0]
                mov     dx, ms[2]
                mov     got, 0
                cmp     ax, 159
                jne     @F
                cmp     dx, 99
                jne     @F
                mov     got, 1
@@:             CHK     n_ctr, got, 1

                invoke  qglMousePos, 100, 50
                mov     got, 0
                cmp     ms[0], 100
                jne     @F
                cmp     ms[2], 50
                jne     @F
                mov     got, 1
@@:             CHK     n_pos, got, 1

                invoke  qglMousePos, 400, 300
                mov     got, 0
                cmp     ms[0], 319
                jne     @F
                cmp     ms[2], 199
                jne     @F
                mov     got, 1
@@:             CHK     n_clip, got, 1

                invoke  qglMousePos, -5, -5
                mov     ax, ms[0]
                or      ax, ms[2]
                mov     got, ax
                CHK     n_neg, got, 0

                invoke  qglMousePos, 100, 50
                mov     si, 20
                mov     di, 10
                mov     bx, 1
                mov     ax, 1
                invoke  qglMouseEvent
                mov     got, 0
                cmp     ms[0], 120
                jne     @F
                cmp     ms[2], 60
                jne     @F
                cmp     ms[6], -1               ;; left
                jne     @F
                mov     got, 1
@@:             CHK     n_ev, got, 1

                mov     si, 20
                mov     di, 10
                mov     bx, 2
                invoke  qglMouseEvent
                mov     got, 0
                cmp     ms[0], 120
                jne     @F
                cmp     ms[2], 60
                jne     @F
                mov     got, 1
@@:             CHK     n_ev2, got, 1
                mov     got, 0
                cmp     ms[6], 0                ;; left up
                jne     @F
                cmp     ms[10], -1              ;; right down
                jne     @F
                mov     got, 1
@@:             CHK     n_rt, got, 1

                mov     si, 1000
                mov     di, 10
                xor     bx, bx
                invoke  qglMouseEvent
                mov     got, 0
                cmp     ms[0], 319
                jne     @F
                cmp     ms[10], 0
                jne     @F
                mov     got, 1
@@:             CHK     n_evclip, got, 1

                invoke  qglMouseShutdown
                ret
tmain           endp
                end
