;; mouse.asm -- a cursor position of our own, driven by the driver's mickeys.
;;
;; name: qglMouseInit / qglMousePos / qglMouseEvent / qglMouseShutdown
;; desc: The INT 33h driver calls qglMouseEvent on every move and button
;;       change. The position it keeps itself is ignored: the cursor here
;;       moves by the mickey delta, one pixel per mickey, and is clipped
;;       to the range given at init, so qglMousePos can put it anywhere
;;       in that range and a read straight after gets the same numbers.
;;       That is what the camera relies on -- the spawn yaw is applied by
;;       placing the mouse, and the look is read back from it.
;;
;;       The caller's MouseInf gets x, y, the button mask and one word per
;;       button, -1 down. The driver's own cursor is hidden throughout.

                .model  medium, pascal
                .386

                include qgl.inc

MOUSE           equ     33h
MS_RESET        equ     0
MS_HIDE         equ     2
MS_HANDLER      equ     0Ch
MS_EVENTS       equ     7Fh             ;; move, and press/release of L R M

MouseInf        struc
mi_x            dw      ?
mi_y            dw      ?
mi_any          dw      ?
mi_left         dw      ?
mi_middle       dw      ?
mi_right        dw      ?
MouseInf        ends

.code

qgl$ms_on       dw      0
qgl$ms_ptr      dd      0
qgl$ms_x        dw      0
qgl$ms_y        dw      0
qgl$ms_xmax     dw      0
qgl$ms_ymax     dw      0
qgl$ms_omx      dw      0               ;; the driver's mickeys at the last event
qgl$ms_omy      dw      0
qgl$ms_busy     dw      0               ;; qglMousePos is writing; events wait

;;::::::::::::::
;; ax, dx clipped to 0..xmax, 0..ymax; stored; written to the caller's struct
;;::::::::::::::
qgl$MsPlace     proc    near private uses si ds
                cmp     ax, 0
                jge     @F
                xor     ax, ax
@@:             cmp     ax, cs:qgl$ms_xmax
                jle     @F
                mov     ax, cs:qgl$ms_xmax
@@:             cmp     dx, 0
                jge     @F
                xor     dx, dx
@@:             cmp     dx, cs:qgl$ms_ymax
                jle     @F
                mov     dx, cs:qgl$ms_ymax
@@:             mov     cs:qgl$ms_x, ax
                mov     cs:qgl$ms_y, dx
                lds     si, cs:qgl$ms_ptr
                mov     [si].MouseInf.mi_x, ax
                mov     [si].MouseInf.mi_y, dx
                ret
qgl$MsPlace     endp


;;::::::::::::::
;; qglMouseEvent -- the driver's callback: bx buttons, si:di mickeys
;;::::::::::::::
qglMouseEvent   proc    far public
                pushad
                push    ds
                cmp     cs:qgl$ms_busy, 0
                jne     @@done

                mov     ax, si
                sub     ax, cs:qgl$ms_omx
                mov     cs:qgl$ms_omx, si
                add     ax, cs:qgl$ms_x
                mov     dx, di
                sub     dx, cs:qgl$ms_omy
                mov     cs:qgl$ms_omy, di
                add     dx, cs:qgl$ms_y
                call    qgl$MsPlace

                lds     si, cs:qgl$ms_ptr
                mov     [si].MouseInf.mi_any, bx
                shr     bx, 1
                sbb     ax, ax
                mov     [si].MouseInf.mi_left, ax
                shr     bx, 1
                sbb     ax, ax
                mov     [si].MouseInf.mi_right, ax
                shr     bx, 1
                sbb     ax, ax
                mov     [si].MouseInf.mi_middle, ax
@@done:         pop     ds
                popad
                ret
qglMouseEvent   endp


;;::::::::::::::
;; qglMouseInit ( m:far ptr, xmax:word, ymax:word ) -> ax = -1, or 0 with
;; no driver. Starts at the centre; a second call changes nothing.
;;::::::::::::::
qglMouseInit  proc    public uses bx cx dx si di es ds,\
                        m:far ptr, xmax:word, ymax:word

                mov     ax, -1
                cmp     cs:qgl$ms_on, 0
                jne     @@done

                mov     ax, MS_RESET
                int     MOUSE
                test    ax, ax
                jz      @@done
                mov     ax, MS_HIDE
                int     MOUSE

                les     di, m
                mov     W cs:qgl$ms_ptr, di
                mov     W cs:qgl$ms_ptr+2, es
                xor     ax, ax
                mov     cx, (size MouseInf) / 2
                cld
                rep     stosw
                mov     ax, xmax
                mov     cs:qgl$ms_xmax, ax
                mov     dx, ymax
                mov     cs:qgl$ms_ymax, dx
                mov     cs:qgl$ms_omx, 0
                mov     cs:qgl$ms_omy, 0
                shr     ax, 1
                shr     dx, 1
                call    qgl$MsPlace

                mov     ax, cs
                mov     es, ax
                mov     dx, offset qglMouseEvent
                mov     cx, MS_EVENTS
                mov     ax, MS_HANDLER
                int     MOUSE
                mov     cs:qgl$ms_on, 1
                mov     ax, -1
@@done:         ret
qglMouseInit  endp


;;::::::::::::::
;; qglMousePos ( x:word, y:word )
;;::::::::::::::
qglMousePos   proc    public uses ax dx,\
                        x:word, y:word

                cmp     cs:qgl$ms_on, 0
                je      @@done
                mov     cs:qgl$ms_busy, 1
                mov     ax, x
                mov     dx, y
                call    qgl$MsPlace
                mov     cs:qgl$ms_busy, 0
@@done:         ret
qglMousePos   endp


;;::::::::::::::
;; qglMouseShutdown () -- no more events, the driver reset
;;::::::::::::::
qglMouseShutdown proc public uses ax cx dx es

                cmp     cs:qgl$ms_on, 0
                je      @@done
                mov     cs:qgl$ms_on, 0
                xor     cx, cx
                mov     ax, MS_HANDLER
                int     MOUSE
                mov     ax, MS_RESET
                int     MOUSE
@@done:         ret
qglMouseShutdown endp

                end
