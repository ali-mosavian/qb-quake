;; z.asm -- the depth buffer, and the state the fillers read.
;;
;; name: qglZNew / qglZFree / qglZClear / qglZScale
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
;;         320 bytes and 320 is not one; qglZNew pads up to 512 rather
;;         than refusing. The padding is dead space in EMS, which has
;;         megabytes of it, and it costs nothing per pixel because the
;;         scanner addresses depth off the row pointer.
;;       - the per-scanline and per-polygon slots (zline, zacc, zdzdx)
;;         live here rather than in rs.asm because the FILLERS read them
;;         and the fillers are patched from two places. One owner.
;;       - which buffer and which mode are NOT here: they are arguments
;;         to qglRsPoly and scratch in rs.asm, so a draw cannot inherit
;;         a depth setting some earlier call left behind. There is no
;;         installed buffer, so nothing here has an install side effect.

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
;; qglZNew ( dst:far ptr Surface, kind:word ) -> dx:ax
;;
;; A depth buffer shaped to a destination. Nothing installs it: a caller
;; may hold as many as it likes and hands the one it wants to qglRsPoly.
;;::::::::::::::
qglZNew       proc    public uses bx cx si di es,\
                        dst:dword, kind:word

                local   bytes:word
                local   rows:word
                local   wide:word

                les     bx, dst
                mov     ax, es
                or      ax, bx
                jz      @@fail

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
                ;; which is not one, so pad to 512. The padding is dead
                ;; space in a store that has megabytes of it, and it costs
                ;; nothing per pixel -- the scanner addresses depth off
                ;; the row pointer, never off the width.
                cmp     kind, SURF_EMS
                jne     @F
                mov     ax, bytes
                call    qgl$Pow2
                test    ax, ax
                jz      @@fail
                mov     bytes, ax
@@:             invoke  qglSfNewEx, wide, rows, bytes, kind
                ret

@@fail:         xor     ax, ax
                xor     dx, dx
                ret
qglZNew       endp


;;::::::::::::::
;; qglZFree ( s:far ptr Surface )
;;::::::::::::::
qglZFree      proc    public uses ax,\
                        s:dword
                invoke  qglSfFree, s
                ret
qglZFree      endp


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
;; qglZClear ( s:far ptr Surface, val:word )
;;
;; A WORD fill: a byte fill would be right only for 0, and the one value
;; that matters after 0 is 0FFFFh -- clear to "nearest" and the next
;; frame draws nothing at all, which is how a depth test is proved to be
;; testing rather than passing everything.
;;::::::::::::::
qglZClear     proc    public uses ax bx cx dx si di es,\
                        s:dword, val:word

                local   wide:word, rows:word

                les     bx, s
                mov     ax, es
                or      ax, bx
                jz      @@out
                mov     ax, es:[bx].Surface.xRes
                mov     wide, ax
                mov     ax, es:[bx].Surface.yRes
                mov     rows, ax

                cld
                xor     si, si                  ;; row
@@row:          cmp     si, rows
                jae     @@out
                invoke  qglSfWrRow, s, si
                mov     di, ax
                mov     es, dx
                mov     cx, wide
                mov     ax, val
                rep     stosw
                inc     si
                jmp     @@row

@@out:          ret
qglZClear     endp


;;::::::::::::::
;; qglZScale ( f:dword ) -> dx:ax = the scale that was in force
;;::::::::::::::
qglZScale     proc    public uses bx,\
                        f:dword

                mov     ax, word ptr qgl$zscale
                mov     dx, word ptr qgl$zscale+2
                mov     bx, word ptr f
                mov     word ptr qgl$zscale, bx
                mov     bx, word ptr f+2
                mov     word ptr qgl$zscale+2, bx
                ret
qglZScale     endp

                end
