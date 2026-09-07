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
                CHK     n_scr_x,      es:[bx].Surface.x_res,  320
                CHK     n_scr_y,      es:[bx].Surface.y_res,  200
                CHK     n_scr_stride, es:[bx].Surface.stride, 320
                CHK     n_scr_seg,    es:[bx].Surface.handle, 0A000h

                les     bx, scr
                xor     ax, ax
                mov     al, es:[bx].Surface.kind
                CHK     n_scr_kind, ax, SURF_CMEM

                ;;
                ;; EMS. run1.sh sets ems=true, so a zero here is a real
                ;; failure and not an absent driver.
                ;;
                invoke  qglGemInit
                NZ      ax
                CHK     n_ems, ax, 1

                invoke  qglGemFrame
                NZ      ax
                CHK     n_frame, ax, 1

                ret
tmain           endp
                end
