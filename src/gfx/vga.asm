;; vga.asm -- VGA mode 13h: enter, leave, palette, and the screen surface.
;;
;; name: vga_init / vga_shutdown / vga_screen / vga_palette
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
;;       - vga_shutdown restores the mode found at vga_init rather than
;;         assuming 3.

                .286
                .model medium, pascal

                include sf.inc

VGA_SEG         equ     0A000h
DAC_WRITE       equ     03C8h
DAC_DATA        equ     03C9h


.data
;; The screen, as a surface. Static rather than allocated: there is
;; exactly one, it is always 320x200, and its pixels are always at
;; A000:0000. Nothing about it is discovered at run time.
                public  vga_screen_sf
vga_screen_sf   SF      <320, 200, 320, SF_CMEM, 0, VGA_SEG, 0>

vga_prev_mode   db      3               ;; whatever was current at vga_init


.code

;;::::::::::::::
;; vga_init () -> far ptr to the screen surface
;;
;; Records the current mode, sets 13h, hands back the screen. There is
;; no failure path worth reporting: INT 10h has none.
;;::::::::::::::
vga_init        proc    public
                mov     ah, 0Fh
                int     10h                     ;; al = current mode
                mov     [vga_prev_mode], al

                mov     ax, 0013h
                int     10h

                ;; medium model: DS is DGROUP, and the surface is in it
                mov     dx, ds
                mov     ax, offset vga_screen_sf
                ret
vga_init        endp


;;::::::::::::::
;; vga_shutdown ()
;;::::::::::::::
vga_shutdown    proc    public
                mov     al, [vga_prev_mode]
                xor     ah, ah
                int     10h
                ret
vga_shutdown    endp


;;::::::::::::::
;; vga_screen () -> far ptr to the screen surface
;;
;; The same surface vga_init returned, for callers that did not run the
;; init themselves.
;;::::::::::::::
vga_screen      proc    public
                mov     dx, ds
                mov     ax, offset vga_screen_sf
                ret
vga_screen      endp


;;::::::::::::::
;; vga_palette ( pal:far ptr )
;;
;; 768 bytes, R,G,B per entry, 8 bits each. Written from index 0 with no
;; retrace wait: the palette is set at load, not per frame, so tearing a
;; ramp for one frame costs nothing and waiting costs a scan.
;;::::::::::::::
vga_palette     proc    public uses si ds,\
                        pal:far ptr byte

                lds     si, pal

                mov     dx, DAC_WRITE
                xor     al, al
                out     dx, al                  ;; start at entry 0
                inc     dx                      ;; DAC_DATA

                mov     cx, 768
@@next:         lodsb
                shr     al, 1
                shr     al, 1                   ;; 8-bit -> the DAC's 6
                out     dx, al
                loop    @@next

                ret
vga_palette     endp

                end
