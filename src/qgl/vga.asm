;; vga.asm -- VGA mode 13h: enter, leave, palette, and the screen surface.
;;
;; name: qglVgaInit / qglVgaShutdown / qglVgaScreen / qglVgaPalette
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
;;       - qglVgaShutdown restores the mode found at the FIRST qglVgaInit
;;         rather than assuming 3.

                .286
                .model medium, pascal

                include qgl.inc

qglSfInit       proto   far pascal
qglMemAlloc     proto   far pascal :dword

VGA_SEG         equ     0A000h
DAC_WRITE       equ     03C8h
DAC_DATA        equ     03C9h


VGA_W           equ     320
VGA_H           equ     200

.data
;; The screen, as a surface. ALLOCATED, not declared: a Surface lives at
;; offset 0 of its own segment -- every accessor reads it with no base
;; register, as mgl's do -- and a DGROUP static does not. So this is the
;; far pointer qgl$VgaShape fills on first ask, and 0:0 until then.
;; Internal: callers reach it through qglVgaScreen, not by name.
qgl$screen      dd      0
;; The mode to go back to, recorded at the FIRST init and never again:
;; the loading screen brings 13h up and vid_init brings it up a second
;; time, and re-recording there would save 13h as the mode to restore.
qgl$prevmode    db      3
qgl$modeset     db      0


.code

;;::::::::::::::
;; qglVgaInit () -> far ptr to the screen surface
;;
;; Records the current mode, sets 13h, hands back the screen. There is
;; no failure path worth reporting: INT 10h has none.
;;::::::::::::::
qglVgaInit    proc    public
                cmp     [qgl$modeset], 0
                jne     @F
                mov     ah, 0Fh
                int     10h                     ;; al = current mode
                mov     [qgl$prevmode], al
                mov     [qgl$modeset], 1

@@:             mov     ax, 0013h
                int     10h

                call    qgl$VgaShape
                mov     ax, W [qgl$screen+0]
                mov     dx, W [qgl$screen+2]
                ret
qglVgaInit    endp

;;::::::::::::::
;; qgl$VgaShape -- the screen surface's fields and its address table.
;;
;; A SUB rather than an initialiser, and called from qglVgaScreen as well
;; as from qglVgaInit: a caller that only wants the descriptor -- t01base
;; does, and so does anything that asks before the mode is set -- must
;; still get a filled one. It allocates once and then does nothing.
;;::::::::::::::
qgl$VgaShape    proc    near private uses ax bx cx dx es
                invoke  qglSfInit               ;; see qglSfNewEx's note

                cmp     W [qgl$screen+2], 0
                jne     @@done

                invoke  qglMemAlloc, T Surface + VGA_H * 4
                mov     W [qgl$screen+0], ax
                mov     W [qgl$screen+2], dx
                or      ax, dx
                jz      @@done

                mov     es, dx
                mov     es:[Surface.fmt], FMT_8BIT
                mov     es:[Surface.typ], SF_MEM
                mov     ax, FMT_8BIT_BPP
                mov     es:[Surface.bpp], al
                mov     ax, FMT_8BIT_P2B
                mov     es:[Surface.p2b], al
                mov     es:[Surface.xRes], VGA_W
                mov     es:[Surface.yRes], VGA_H
                mov     es:[Surface.bps], VGA_W
                mov     es:[Surface.pages], 1
                mov     es:[Surface.startSL], 0
                mov     es:[Surface.xMin], 0
                mov     es:[Surface.yMin], 0
                mov     es:[Surface.xMax], VGA_W-1
                mov     es:[Surface.yMax], VGA_H-1
                mov     W es:[Surface.fptr+0], 0
                mov     W es:[Surface.fptr+2], VGA_SEG
                mov     W es:[Surface._size+0], (VGA_W * VGA_H) and 0FFFFh
                mov     W es:[Surface._size+2], (VGA_W * VGA_H) shr 16

                ;; the address table: 320*200 is 64000, so every row is in
                ;; the one segment and the offset is all that moves
                xor     ax, ax
                mov     bx, SF_addrTB
                mov     cx, VGA_H
@@row:          mov     W es:[bx+0], VGA_SEG
                mov     W es:[bx+2], ax
                add     ax, VGA_W
                add     bx, T dword
                dec     cx
                jnz     @@row

@@done:         ret
qgl$VgaShape    endp


;;::::::::::::::
;; qglVgaShutdown ()
;;::::::::::::::
qglVgaShutdown proc    public
                mov     al, [qgl$prevmode]
                xor     ah, ah
                int     10h
                ret
qglVgaShutdown endp


;;::::::::::::::
;; qglVgaScreen () -> far ptr to the screen surface
;;
;; The same surface qglVgaInit returned, for callers that did not run the
;; init themselves.
;;::::::::::::::
qglVgaScreen  proc    public
                call    qgl$VgaShape
                mov     ax, W [qgl$screen+0]
                mov     dx, W [qgl$screen+2]
                ret
qglVgaScreen  endp


;;::::::::::::::
;; qglVgaPalette ( pal:far ptr )
;;
;; 768 bytes, R,G,B per entry, 8 bits each. Written from index 0 with no
;; retrace wait: the palette is set at load, not per frame, so tearing a
;; ramp for one frame costs nothing and waiting costs a scan.
;;::::::::::::::
qglVgaPalette proc    public uses si ds,\
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
qglVgaPalette endp

                end
