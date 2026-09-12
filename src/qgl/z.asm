;; z.asm -- the depth buffer, and the state the fillers read.
;;
;; name: qglSfZNew / qglSfZFree / qglSfZClear / qglSfZMode / qglZScale
;; desc: Depth is 1/z in 16.16 and only the integer half is stored, so
;;       LARGER IS NEARER and a cleared buffer is 0 = infinitely far.
;;       That is mgl's convention and the renderer's scale factor already
;;       assumes it (main.bas: 65535 * z_near puts the near plane at the
;;       top of the range).
;;
;;       A depth buffer is an ordinary Surface with two bytes a pixel:
;;       x_res stays in PIXELS and the doubling lives in stride, which is
;;       what stride is for. Putting bytes in x_res instead was tried on
;;       paper and is wrong by exactly a factor of two in every clip and
;;       every pget -- those index against x_res, and none of them would
;;       have known this one surface meant something else by it.
;;
;; obs.: - qglSfNew demands a power-of-two stride for an EMS surface, so
;;         that a row cannot straddle a 16K page. 160 pixels of depth is
;;         320 bytes and 320 is not one; qglSfZNew pads up to 512 rather
;;         than refusing. The padding is dead space in EMS, which has
;;         megabytes of it, and it costs nothing per pixel because the
;;         scanner addresses depth off the row pointer.
;;       - the per-scanline and per-polygon slots (zline, zacc, zdzdx)
;;         live here rather than in rs.asm because the FILLERS read them
;;         and the fillers are patched from two places. One owner.
;;       - A DEPTH BUFFER BELONGS TO THE SURFACE IT WAS MADE FOR.
;;         qglSfZNew stores it in that surface's zsf and no entry point
;;         takes one as an argument, so a draw cannot be handed the
;;         depth of some other destination -- nor inherit a setting an
;;         earlier call installed, because there is nothing installed:
;;         qglRsPoly reads both fields off the surface it is drawing on.
;;       - the scale is NOT per surface. It is the projection's, one for
;;         the frame, and every depth buffer in it shares the units.

                .model  medium, pascal
                .386

                include qgl.inc

qglSfNewEx   proto   far pascal :word, :word, :word, :word
qglSfFree     proto   far pascal :dword
qglSfWrRow   proto   far pascal :dword, :word


.data
                ;; what the fillers need, and the projection's scale
                public  qgl$zscale
                public  qgl$zline, qgl$zacc, qgl$zdzdx, qgl$zseg

qgl$zscale      dd      0               ;; 1/z -> 16.16, set by the caller

                ;; per scanline, written by the scanner
qgl$zline       dw      0               ;; byte offset of depth at x=0
qgl$zseg        dw      0               ;; its segment; the fillers' gs

                ;; per span / per polygon, read by the fillers
qgl$zacc        dd      0               ;; 1/z at the span's left, 16.16
qgl$zdzdx       dd      0               ;; d(1/z)/dx, 16.16


.code

;;::::::::::::::
;; qgl$Pow2 -- round ax up to a power of two. ax only.
;;
;; INTERNAL. Returns 0 if the answer would not fit a word, which the
;; caller must treat as a refusal rather than as 65536.
;;::::::::::::::
qgl$Pow2        proc    near private uses cx

                mov     cx, 1
@@up:           cmp     cx, ax
                jae     @F
                shl     cx, 1
                jnz     @@up
                xor     cx, cx                  ;; overflowed the word
@@:             mov     ax, cx
                ret
qgl$Pow2        endp


;;::::::::::::::
;; qglSfZNew ( surf:far ptr Surface, kind:word ) -> dx:ax
;;
;; A depth buffer shaped to surf, and ATTACHED to it. The pointer comes
;; back so a caller can look at what it got -- the tests read depth rows
;; through it -- and no entry point anywhere takes one, so there is no
;; way to draw against a depth buffer belonging to another destination.
;;
;; Refuses when surf already has one. Freeing the old buffer here would
;; drop it under whoever still holds the pointer; resizing is qglSfZFree
;; and then this.
;;::::::::::::::
qglSfZNew     proc    public uses bx cx si di es,\
                        surf:dword, kind:word

                local   bytes:word
                local   rows:word
                local   wide:word

                les     bx, surf
                mov     ax, es
                or      ax, bx
                jz      @@fail
                cmp     D es:[bx].Surface.zsf, 0
                jne     @@fail

                mov     ax, es:[bx].Surface.xRes
                test    ax, ax
                jz      @@fail
                mov     wide, ax
                shl     ax, 1                   ;; two bytes a pixel
                jc      @@fail                  ;; a row past 64K is not ours
                mov     bytes, ax
                mov     ax, es:[bx].Surface.yRes
                test    ax, ax
                jz      @@fail
                mov     rows, ax

                ;; EMS wants a power-of-two stride so a row cannot
                ;; straddle a 16K page: 160 pixels of depth is 320 bytes,
                ;; which is not one, so pad to 512. Depth is read and
                ;; written a scanline at a time, so the buffer may span as
                ;; many pages as it likes -- unlike a texture, which is
                ;; sampled at random and must fit in one. The padding is
                ;; dead space in a store that has megabytes of it, and it
                ;; costs nothing per pixel: the scanner addresses depth
                ;; off the row pointer, never off the width.
                cmp     kind, SURF_EMS
                jne     @F
                mov     ax, bytes
                call    qgl$Pow2
                test    ax, ax
                jz      @@fail
                mov     bytes, ax
@@:             invoke  qglSfNewEx, wide, rows, bytes, kind
                mov     cx, ax
                or      cx, dx
                jz      @@fail

                les     bx, surf
                mov     W es:[bx].Surface.zsf+0, ax
                mov     W es:[bx].Surface.zsf+2, dx
                mov     es:[bx].Surface.zmode, QGL_Z_OFF
                ret

@@fail:         xor     ax, ax
                xor     dx, dx
                ret
qglSfZNew     endp


;;::::::::::::::
;; qglSfZMode ( surf:far ptr Surface, mode:word ) -> ax = 1 set, 0 refused
;;
;; What a draw into surf does with the depth attached to it. A refusal --
;; no buffer, or a mode that is not one -- leaves OFF behind rather than
;; whatever was there, so a caller that ignores the return draws with no
;; depth instead of against a buffer it never set up.
;;
;; IT DOES NOT ANSWER WITH THE MODE THAT WAS IN FORCE. The entry it
;; replaces did, d_faces.c cached that answer, and after a run of entity
;; faces the cache said SET while TEST was live -- the next world face
;; tested against a buffer it was meant to write. There is nothing here
;; to cache: the mode lives on the surface and qglRsPoly reads it there.
;;::::::::::::::
qglSfZMode    proc    public uses bx es,\
                        surf:dword, mode:word

                les     bx, surf
                mov     ax, es
                or      ax, bx
                jz      @@fail                  ;; nothing to set it on

                mov     es:[bx].Surface.zmode, QGL_Z_OFF
                cmp     D es:[bx].Surface.zsf, 0
                je      @@fail
                mov     ax, mode
                cmp     ax, QGL_Z_TEST
                ja      @@fail
                mov     es:[bx].Surface.zmode, ax
                mov     ax, 1
                ret

@@fail:         xor     ax, ax
                ret
qglSfZMode    endp


;;::::::::::::::
;; qglSfZFree ( surf:far ptr Surface )
;;
;; Detaches first, frees second: the surface is left describing no depth
;; whatever the free does, and OFF with it.
;;::::::::::::::
qglSfZFree    proc    public uses ax bx cx dx es,\
                        surf:dword

                local   zb:dword

                les     bx, surf
                mov     ax, es
                or      ax, bx
                jz      @@out

                mov     ax, W es:[bx].Surface.zsf+0
                mov     dx, W es:[bx].Surface.zsf+2
                mov     cx, ax
                or      cx, dx
                jz      @@out
                mov     D es:[bx].Surface.zsf, 0
                mov     es:[bx].Surface.zmode, QGL_Z_OFF

                mov     W zb+0, ax
                mov     W zb+2, dx
                invoke  qglSfFree, zb

@@out:          ret
qglSfZFree    endp


;;::::::::::::::
;; How the scratch above is reached, and why not the obvious way.
;;
;; THE FILLERS REACH THIS STATE THROUGH fs, NOT ss, and that is a
;; deliberate divergence from mgl. mgl reads ss:ul$zacc because ds is the
;; texture and es the destination, leaving ss: as the only segment it had
;; spare to say DGROUP with -- which silently assumes SS == DGROUP. It is
;; not a safe assumption here: the qgl test harness links with SS 094Bh
;; against a DGROUP of 006Ch, measured, and this repo already has
;; coroutine stacks that are not DGROUP either. A depth write from one
;; would land in the stack with nothing to notice.
;;
;; fs is untouched by every filler in 8plxtz.asm, so the scanner loads it
;; with DGROUP once per polygon and the prefix costs the same one byte
;; ss: would have. No assumption, no check, no per-pixel cost.
;;::::::::::::::


;;::::::::::::::
;; qglSfZClear ( surf:far ptr Surface, val:word )
;;
;; Clears the depth attached to surf, and does nothing where there is
;; none -- a frame loop may run against a surface with depth off without
;; asking first.
;;
;; A WORD fill: a byte fill would be right only for 0, and the one value
;; that matters after 0 is 0FFFFh -- clear to "nearest" and the next
;; frame draws nothing at all, which is how a depth test is proved to be
;; testing rather than passing everything.
;;::::::::::::::
qglSfZClear   proc    public uses ax bx cx dx si di es,\
                        surf:dword, val:word

                local   wide:word, rows:word
                local   zb:dword

                les     bx, surf
                mov     ax, es
                or      ax, bx
                jz      @@out
                mov     ax, W es:[bx].Surface.zsf+0
                mov     dx, W es:[bx].Surface.zsf+2
                mov     cx, ax
                or      cx, dx
                jz      @@out
                mov     W zb+0, ax
                mov     W zb+2, dx

                mov     es, dx
                mov     bx, ax
                mov     ax, es:[bx].Surface.xRes
                mov     wide, ax
                mov     ax, es:[bx].Surface.yRes
                mov     rows, ax

                cld
                xor     si, si                  ;; row
@@row:          cmp     si, rows
                jae     @@out
                invoke  qglSfWrRow, zb, si
                mov     di, ax
                mov     es, dx
                mov     cx, wide
                mov     ax, val
                rep     stosw
                inc     si
                jmp     @@row

@@out:          ret
qglSfZClear   endp


;;::::::::::::::
;; qglZScale ( f:real4 ) -> dx:ax = the scale that was in force
;;
;; real4, not dword: the fillers read it with `fmul D qgl$zscale`,
;; so what crosses is a float's bit pattern. Declared dword, a C
;; caller CONVERTED 65535.0 to the integer and passed those bits,
;; which read back as 9.2e-41 -- every depth stored was 0, and
;; QGL_Z_TEST compared 0 against 0 on every pixel of every frame.
;;::::::::::::::
qglZScale     proc    public uses bx,\
                        f:real4

                mov     ax, word ptr qgl$zscale
                mov     dx, word ptr qgl$zscale+2
                mov     bx, word ptr f
                mov     word ptr qgl$zscale, bx
                mov     bx, word ptr f+2
                mov     word ptr qgl$zscale+2, bx
                ret
qglZScale     endp

                end
