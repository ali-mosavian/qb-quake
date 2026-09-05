;; z.asm -- the depth buffer, and the state the fillers read.
;;
;; name: qgl_z_new / qgl_z_set / qgl_z_free / qgl_z_clear / qgl_z_mode /
;;       qgl_z_scale
;; desc: Depth is 1/z in 16.16 and only the integer half is stored, so
;;       LARGER IS NEARER and a cleared buffer is 0 = infinitely far.
;;       That is mgl's convention and the renderer's scale factor already
;;       assumes it (main.bas: 65535 * z_near puts the near plane at the
;;       top of the range).
;;
;;       A depth buffer is an ordinary Surface with two bytes a pixel, so
;;       ITS x_res AND stride ARE IN BYTES, not pixels. The alternative --
;;       a bytes-per-pixel field on Surface -- would put a multiply in
;;       qgl$row for every colour surface in the program to serve the one
;;       that is not 8bpp. qgl$zw keeps the pixel width for the routines
;;       that need it.
;;
;; obs.: - qgl_sf_new demands a power-of-two stride for an EMS surface, so
;;         that a row cannot straddle a 16K page. 160 pixels of depth is
;;         320 bytes and 320 is not one; qgl_z_new pads up to 512 rather
;;         than refusing. The padding is dead space in EMS, which has
;;         megabytes of it, and it costs nothing per pixel because the
;;         scanner addresses depth off the row pointer.
;;       - the per-scanline and per-polygon slots (zline, zacc, zdzdx)
;;         live here rather than in rs.asm because the FILLERS read them
;;         and the fillers are patched from two places. One owner.

                .model  medium, pascal
                .386

                include qgl.inc

qgl_sf_new      proto   far pascal :word, :word, :word, :word
qgl_sf_free     proto   far pascal :dword
qgl_sf_row      proto   far pascal :dword, :word


.data
                ;; the installed buffer, and what the fillers need of it
                public  qgl$zsf, qgl$zmode, qgl$zscale
                public  qgl$zline, qgl$zacc, qgl$zdzdx, qgl$zseg, qgl$zw

qgl$zsf         dd      0               ;; far ptr Surface, 0 = no depth
qgl$zw          dw      0               ;; PIXELS, not bytes
qgl$zh          dw      0
qgl$zmode       dw      QGL_Z_OFF
qgl$zscale      dd      0               ;; 1/z -> 16.16, set by the caller

                ;; per scanline, written by the scanner
qgl$zline       dw      0               ;; byte offset of depth at x=0
qgl$zseg        dw      0               ;; its segment; the fillers' gs

                ;; per span / per polygon, read by the fillers
qgl$zacc        dd      0               ;; 1/z at the span's left, 16.16
qgl$zdzdx       dd      0               ;; d(1/z)/dx, 16.16


.code

;;::::::::::::::
;; qgl$pow2 -- round ax up to a power of two. ax only.
;;
;; INTERNAL. Returns 0 if the answer would not fit a word, which the
;; caller must treat as a refusal rather than as 65536.
;;::::::::::::::
qgl$pow2        proc    near private uses cx

                mov     cx, 1
@@up:           cmp     cx, ax
                jae     @F
                shl     cx, 1
                jnz     @@up
                xor     cx, cx                  ;; overflowed the word
@@:             mov     ax, cx
                ret
qgl$pow2        endp


;;::::::::::::::
;; qgl_z_new ( dst:far ptr Surface, kind:word, slot:word ) -> dx:ax
;;
;; A depth buffer shaped to a destination. Does NOT install it: that is
;; qgl_z_set, so a caller may hold more than one and switch.
;;::::::::::::::
qgl_z_new       proc    public uses bx cx si di es,\
                        dst:dword, kind:word, slot:word

                local   bytes:word
                local   rows:word

                les     bx, dst
                mov     ax, es
                or      ax, bx
                jz      @@fail

                mov     ax, es:[bx].Surface.x_res
                test    ax, ax
                jz      @@fail
                shl     ax, 1                   ;; two bytes a pixel
                jc      @@fail                  ;; a row past 64K is not ours
                mov     bytes, ax
                mov     ax, es:[bx].Surface.y_res
                test    ax, ax
                jz      @@fail
                mov     rows, ax

                cmp     kind, SURF_EMS
                jne     @F
                mov     ax, bytes
                call    qgl$pow2
                test    ax, ax
                jz      @@fail
                mov     bytes, ax
@@:             invoke  qgl_sf_new, bytes, rows, kind, slot
                ret

@@fail:         xor     ax, ax
                xor     dx, dx
                ret
qgl_z_new       endp


;;::::::::::::::
;; qgl_z_set ( s:far ptr Surface )
;;
;; Installs, or uninstalls when handed 0:0. The pixel width is derived
;; here once rather than shifted in every filler setup.
;;::::::::::::::
qgl_z_set       proc    public uses ax bx es,\
                        s:dword

                mov     ax, word ptr s
                mov     word ptr qgl$zsf, ax
                mov     ax, word ptr s+2
                mov     word ptr qgl$zsf+2, ax

                les     bx, s
                mov     ax, es
                or      ax, bx
                jz      @@none

                mov     ax, es:[bx].Surface.x_res
                shr     ax, 1                   ;; bytes -> pixels
                mov     qgl$zw, ax
                mov     ax, es:[bx].Surface.y_res
                mov     qgl$zh, ax
                ret

@@none:         mov     qgl$zw, 0
                mov     qgl$zh, 0
                mov     qgl$zmode, QGL_Z_OFF    ;; no buffer, no mode
                ret
qgl_z_set       endp


;;::::::::::::::
;; qgl_z_free ( s:far ptr Surface )
;;
;; Uninstalls it first if it is the installed one, so a freed buffer can
;; never be the one the next polygon writes through.
;;::::::::::::::
qgl_z_free      proc    public uses ax,\
                        s:dword

                mov     ax, word ptr s
                cmp     ax, word ptr qgl$zsf
                jne     @F
                mov     ax, word ptr s+2
                cmp     ax, word ptr qgl$zsf+2
                jne     @F
                invoke  qgl_z_set, 0
@@:             invoke  qgl_sf_free, s
                ret
qgl_z_free      endp


;;::::::::::::::
;; qgl_z_clear ( val:word )
;;
;; A WORD fill: a byte fill would be right only for 0, and the one value
;; that matters after 0 is 0FFFFh -- clear to "nearest" and the next
;; frame draws nothing at all, which is how a depth test is proved to be
;; testing rather than passing everything.
;;::::::::::::::
qgl_z_clear     proc    public uses ax bx cx dx si di es,\
                        val:word

                mov     ax, word ptr qgl$zsf
                or      ax, word ptr qgl$zsf+2
                jz      @@out

                xor     si, si                  ;; row
@@row:          cmp     si, qgl$zh
                jae     @@out
                invoke  qgl_sf_row, qgl$zsf, si
                mov     di, ax
                mov     es, dx
                mov     cx, qgl$zw
                mov     ax, val
                rep     stosw
                inc     si
                jmp     @@row

@@out:          ret
qgl_z_clear     endp


;;::::::::::::::
;; qgl_z_mode ( m:word ) -> ax = the mode that was in force
;;
;; Returns the previous one so a caller can restore it, which is what
;; d_faces.c's z_want/z_have pair already does with uglZMode. Asking for
;; a mode with no buffer installed gets QGL_Z_OFF, not a fault.
;;::::::::::::::
qgl_z_mode      proc    public uses bx,\
                        m:word

                mov     ax, qgl$zmode           ;; the answer, whatever happens

                mov     bx, word ptr qgl$zsf
                or      bx, word ptr qgl$zsf+2
                jz      @@off

                ;; the constants are pre-scaled table offsets, so an odd
                ;; value is not a mode however small it is -- accepting
                ;; one would index the table between its entries
                mov     bx, m
                cmp     bx, QGL_Z_TEST
                ja      @@out                   ;; nonsense leaves it alone
                test    bl, 1
                jnz     @@out
                mov     qgl$zmode, bx
                ret

@@off:          mov     qgl$zmode, QGL_Z_OFF
@@out:          ret
qgl_z_mode      endp


;;::::::::::::::
;; qgl_z_scale ( f:dword ) -> dx:ax = the scale that was in force
;;::::::::::::::
qgl_z_scale     proc    public uses bx,\
                        f:dword

                mov     ax, word ptr qgl$zscale
                mov     dx, word ptr qgl$zscale+2
                mov     bx, word ptr f
                mov     word ptr qgl$zscale, bx
                mov     bx, word ptr f+2
                mov     word ptr qgl$zscale+2, bx
                ret
qgl_z_scale     endp

                end
