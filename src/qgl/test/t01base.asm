;; t01base -- the harness itself, plus the two things that need no setup:
;;            the screen surface's shape, and whether EMS answered.
;;
;; Deliberately does NOT call qglVgaInit: setting mode 13h in a headless
;; DOSBox proves nothing and makes the output unreadable if it half works.
;; qglVgaScreen hands back the same static either way, which is the
;; point of it being a separate entry.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

.data
n_scr_ptr       db      'screen ptr nonzero  $'
n_scr_x         db      'screen x_res 320    $'
n_scr_y         db      'screen y_res 200    $'
n_scr_stride    db      'screen stride 320   $'
n_scr_kind      db      'screen kind cmem    $'
n_scr_seg       db      'screen seg a000     $'
n_ems           db      'ems present         $'
n_ems_cx        db      'ems init keeps cx   $'
n_frame         db      'ems page frame set  $'

scr             dd      0

.code
tmain           proc    far public uses bx es

                ;;
                ;; The screen, as a surface. Static, so this is really a
                ;; check that qgl.inc's field offsets and vga.asm's
                ;; initialiser still agree -- which is exactly the thing a
                ;; struct rename breaks silently.
                ;;
                invoke  qglVgaScreen
                SAVEP   scr

                mov     bx, dx
                or      bx, ax
                NZ      bx
                CHK     n_scr_ptr, ax, 1

                les     bx, scr
                CHK     n_scr_x,      es:[bx].Surface.xRes,  320
                CHK     n_scr_y,      es:[bx].Surface.yRes,  200
                CHK     n_scr_stride, es:[bx].Surface.bps, 320
                ;; row 0's address table entry: the segment the pixels are
                ;; in, which is where the base segment used to be read
                CHK     n_scr_seg,    W es:[bx+SF_addrTB+0], 0A000h

                les     bx, scr
                mov     ax, es:[bx].Surface.typ
                CHK     n_scr_kind, ax, SF_MEM

                ;;
                ;; EMS. run1.sh sets ems=true, so a zero here is a real
                ;; failure and not an absent driver.
                ;;
                ;; CX MUST SURVIVE IT. qglGemInit ends in `repe cmpsb`,
                ;; which eats cx, and it was not in the uses clause --
                ;; qglSfInit walks the dispatch table with its loop counter
                ;; in cx across this call, so the counter came back as
                ;; whatever the string compare left, the walk ran off the
                ;; end of the table and called through garbage. Every
                ;; test's output had already printed by then, so it read
                ;; as a fault in whatever ran last.
                mov     cx, 0BEEFh
                invoke  qglGemInit
                CHK     n_ems_cx, cx, 0BEEFh
                NZ      ax
                CHK     n_ems, ax, 1

                invoke  qglGemFrame
                NZ      ax
                CHK     n_frame, ax, 1

                ret
tmain           endp
                end
