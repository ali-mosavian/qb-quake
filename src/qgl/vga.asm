;; vga.asm -- VGA mode 13h: enter, leave, palette, and the screen surface.
;;
;; name: qgl_vga_init / qgl_vga_shutdown / qgl_vga_screen / qgl_vga_palette
;; desc: mode 13h and nothing else. There is no mode table, no VESA, no
;;       banking and no page flipping -- stuff.ini has shipped
;;       display.usepaging = no throughout, so the renderer has always
;;       drawn to a backbuffer and blitted it, and that is now the only
;;       path there is.
;;
;;       The screen is handed out AS A SURFACE rather than through a
;;       present call of its own. Presenting is then dr_blit (or
;;       dr_blit_scl when render.xres is smaller than display.xres) onto
;;       that surface, which is one code path instead of two and means
;;       nothing here needs to know about scaling.
;;
;; obs.: - vga_, not vid_: vid.bas already owns that prefix and would
;;         collide at the linker, and src/vid.bas would collide at
;;         build/vid.obj.
;;       - the DAC is 6 bits a channel and Quake's palette is 8, so the
;;         load shifts down by two. Getting this wrong is not subtle: it
;;         shows as a picture four times too bright, clamped flat.
;;       - qgl_vga_shutdown restores the mode found at qgl_vga_init rather than
;;         assuming 3.

                .286
                .model medium, pascal

                include qgl.inc

VGA_SEG         equ     0A000h
DAC_WRITE       equ     03C8h
DAC_DATA        equ     03C9h


.data
;; The screen, as a surface. Static rather than allocated: there is
;; exactly one, it is always 320x200, and its pixels are always at
;; A000:0000. Nothing about it is discovered at run time.
;; Internal: callers reach it through qgl_vga_screen, not by name.
qgl$screen      Surface <320, 200, 320, SURF_CMEM, 0, 0, 0, VGA_SEG, 0>
qgl$prevmode    db      3               ;; whatever was current at init


.code

;;::::::::::::::
;; qgl_vga_init () -> far ptr to the screen surface
;;
;; Records the current mode, sets 13h, hands back the screen. There is
;; no failure path worth reporting: INT 10h has none.
;;::::::::::::::
qgl_vga_init    proc    public
                mov     ah, 0Fh
                int     10h                     ;; al = current mode
                mov     [qgl$prevmode], al

                mov     ax, 0013h
                int     10h

                ;; medium model: DS is DGROUP, and the surface is in it
                mov     dx, ds
                mov     ax, offset qgl$screen
                ret
qgl_vga_init    endp


;;::::::::::::::
;; qgl_vga_shutdown ()
;;::::::::::::::
qgl_vga_shutdown proc    public
                mov     al, [qgl$prevmode]
                xor     ah, ah
                int     10h
                ret
qgl_vga_shutdown endp


;;::::::::::::::
;; qgl_vga_screen () -> far ptr to the screen surface
;;
;; The same surface qgl_vga_init returned, for callers that did not run the
;; init themselves.
;;::::::::::::::
qgl_vga_screen  proc    public
                mov     dx, ds
                mov     ax, offset qgl$screen
                ret
qgl_vga_screen  endp


;;::::::::::::::
;; qgl_vga_palette ( pal:far ptr )
;;
;; 768 bytes, R,G,B per entry, 8 bits each. Written from index 0 with no
;; retrace wait: the palette is set at load, not per frame, so tearing a
;; ramp for one frame costs nothing and waiting costs a scan.
;;::::::::::::::
qgl_vga_palette proc    public uses si ds,\
                        pal:far ptr byte

                lds     si, pal

                mov     dx, DAC_WRITE
                xor     al, al
                out     dx, al                  ;; start at entry 0
                inc     dx                      ;; DAC_DATA

                mov     cx, 768
                cld
@@:             lodsb
                shr     al, 1
                shr     al, 1                   ;; 8-bit -> the DAC's 6
                out     dx, al
                loop    @B

                ret
qgl_vga_palette endp

                end
