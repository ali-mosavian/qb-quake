;; dr.asm -- drawing onto a surface: runs, rectangles, lines and blits.
;;
;; name: qgl_dr_fill / qgl_dr_hline / qgl_dr_vline / qgl_dr_rect /
;;       qgl_dr_line / qgl_dr_shade / qgl_dr_blit / qgl_dr_blit_scl
;; desc: nearly everything here is a horizontal run, or a stack of them.
;;       A filled rectangle is h runs of a colour, a blit is h runs
;;       copied, a clear is the whole surface as one rectangle. Only
;;       qgl_dr_line is not, and it is here because the loading spinner
;;       wants one.
;;
;;       Rows come from qgl_sf_row, so all of it works on an EMS surface
;;       as well as a conventional one and the paging is not this
;;       module's problem.
;;
;; obs.: - clipping is per primitive and to the surface's own extent.
;;         There is no clip rectangle: mgl carries one in every DC and
;;         this renderer never set it to anything but the whole surface.
;;       - the run fillers align, move dwords, then finish the tail. A
;;         quarter of the memory operations is a quarter of what an
;;         emulator charging per instruction bills for, and the HUD
;;         redraws every frame.
;;       - a colour is a palette index. At 8bpp there is nothing to
;;         convert and no format to dispatch on, which is most of what
;;         mgl's equivalent of this file was.
;;       - TWO-SURFACE calls (blit, blit_scl, shade) fetch the source row
;;         and the destination row from qgl_sf_row in turn. That is only
;;         safe while the two do not share one EMS slot, which is the
;;         same discipline q_map.bi already documents for PAGE_SLOT. A
;;         conventional destination -- what the backbuffer is -- cannot
;;         collide at all.

                .model  medium, pascal
                .386

                include qgl.inc

qgl_sf_row      proto   far pascal :dword, :word


.code

;;::::::::::::::
;; qgl$run_fill -- one run of a constant byte.
;;
;; INTERNAL: es:di -> the run, cx = length, al = the colour. Everything
;; survives except di, which is left past the run.
;;::::::::::::::
qgl$run_fill    proc    near private uses ax bx cx

                cld
                jcxz    @@out
                mov     ah, al                  ;; the byte, four to a dword
                mov     bx, ax
                shl     eax, 16
                mov     ax, bx

                mov     bx, cx                  ;; bytes left
                mov     cx, di                  ;; up to the next boundary
                neg     cx
                and     cx, 3
                cmp     cx, bx
                jbe     @F
                mov     cx, bx
@@:             sub     bx, cx
                rep     stosb

                mov     cx, bx                  ;; the bulk
                shr     cx, 2
                rep     stosd

                mov     cx, bx                  ;; and the tail
                and     cx, 3
                rep     stosb
@@out:          ret
qgl$run_fill    endp


;;::::::::::::::
;; qgl$run_copy -- one run copied, ds:si -> es:di.
;;
;; INTERNAL: cx = length. Everything survives except si and di, left
;; past the run.
;;::::::::::::::
qgl$run_copy    proc    near private uses ax bx cx

                cld
                jcxz    @@out
                mov     bx, cx
                mov     cx, di
                neg     cx
                and     cx, 3
                cmp     cx, bx
                jbe     @F
                mov     cx, bx
@@:             sub     bx, cx
                rep     movsb

                mov     cx, bx
                shr     cx, 2
                rep     movsd

                mov     cx, bx
                and     cx, 3
                rep     movsb
@@out:          ret
qgl$run_copy    endp


;;::::::::::::::
;; qgl$clip_run -- clip x0..x1 inclusive to 0..limit-1.
;;
;; INTERNAL: ax = x0, bx = x1, cx = limit. Carry set if nothing is left;
;; otherwise ax = first column and cx = length. bx is consumed.
;;::::::::::::::
qgl$clip_run    proc    near private

                cmp     ax, bx                  ;; least first
                jle     @F
                xchg    ax, bx

@@:             test    ax, 8000h               ;; x0 negative
                jz      @F
                xor     ax, ax
@@:             test    bx, 8000h               ;; x1 negative: all of it is
                jnz     @@none

                cmp     bx, cx
                jl      @F
                mov     bx, cx
                dec     bx
@@:             cmp     ax, cx
                jge     @@none
                cmp     bx, ax
                jl      @@none

                mov     cx, bx
                sub     cx, ax
                inc     cx                      ;; the range is inclusive
                clc
                ret

@@none:         stc
                ret
qgl$clip_run    endp


;;::::::::::::::
;; qgl_dr_hline ( d:far ptr, x0:word, y:word, x1:word, col:word )
;;::::::::::::::
qgl_dr_hline    proc    public uses bx cx dx si di es,\
                        d:dword, x0:word, y:word, x1:word, col:word

                local   runx:word
                local   runlen:word

                les     bx, d
                mov     ax, y
                cmp     ax, es:[bx].Surface.y_res
                jae     @@out                   ;; unsigned: catches y < 0

                mov     cx, es:[bx].Surface.x_res
                mov     ax, x0
                mov     bx, x1
                call    qgl$clip_run
                jc      @@out
                mov     runx, ax
                mov     runlen, cx

                invoke  qgl_sf_row, d, y
                mov     es, dx
                mov     di, ax
                add     di, runx
                mov     cx, runlen
                mov     al, byte ptr col
                call    qgl$run_fill

@@out:          ret
qgl_dr_hline    endp


;;::::::::::::::
;; qgl_dr_fill ( d:far ptr, x0:word, y0:word, x1:word, y1:word, col:word )
;;
;; Also how a surface is cleared: the whole of it is just the largest
;; rectangle, and there is no reason for a second routine that says so.
;;::::::::::::::
qgl_dr_fill     proc    public uses bx cx dx si di es,\
                        d:dword, x0:word, y0:word, x1:word, y1:word, col:word

                local   runx:word
                local   runlen:word
                local   yy:word
                local   ylast:word

                les     bx, d
                mov     cx, es:[bx].Surface.x_res
                mov     ax, x0
                mov     bx, x1
                call    qgl$clip_run
                jc      @@out
                mov     runx, ax
                mov     runlen, cx

                les     bx, d
                mov     cx, es:[bx].Surface.y_res
                mov     ax, y0
                mov     bx, y1
                call    qgl$clip_run            ;; the same clamp, on rows
                jc      @@out
                mov     yy, ax
                add     cx, ax
                dec     cx
                mov     ylast, cx

@@row:          mov     ax, yy
                cmp     ax, ylast
                ja      @@out

                invoke  qgl_sf_row, d, yy
                mov     es, dx
                mov     di, ax
                add     di, runx
                mov     cx, runlen
                mov     al, byte ptr col
                call    qgl$run_fill

                inc     yy
                jmp     @@row

@@out:          ret
qgl_dr_fill     endp


;;::::::::::::::
;; qgl_dr_vline ( d:far ptr, x:word, y0:word, y1:word, col:word )
;;::::::::::::::
qgl_dr_vline    proc    public uses bx cx dx si di es,\
                        d:dword, x:word, y0:word, y1:word, col:word

                local   yy:word
                local   ylast:word

                les     bx, d
                mov     ax, x
                cmp     ax, es:[bx].Surface.x_res
                jae     @@out

                mov     cx, es:[bx].Surface.y_res
                mov     ax, y0
                mov     bx, y1
                call    qgl$clip_run
                jc      @@out
                mov     yy, ax
                add     cx, ax
                dec     cx
                mov     ylast, cx

@@row:          mov     ax, yy
                cmp     ax, ylast
                ja      @@out

                invoke  qgl_sf_row, d, yy
                mov     es, dx
                mov     di, ax
                add     di, x
                mov     al, byte ptr col
                mov     es:[di], al

                inc     yy
                jmp     @@row

@@out:          ret
qgl_dr_vline    endp


;;::::::::::::::
;; qgl_dr_rect ( d:far ptr, x0:word, y0:word, x1:word, y1:word, col:word )
;;
;; The outline, as four runs. Each clips itself, so a rectangle hanging
;; off an edge loses only the parts that are off it.
;;::::::::::::::
qgl_dr_rect     proc    public uses bx,\
                        d:dword, x0:word, y0:word, x1:word, y1:word, col:word

                invoke  qgl_dr_hline, d, x0, y0, x1, col
                invoke  qgl_dr_hline, d, x0, y1, x1, col
                invoke  qgl_dr_vline, d, x0, y0, y1, col
                invoke  qgl_dr_vline, d, x1, y0, y1, col
                ret
qgl_dr_rect     endp


;;::::::::::::::
;; qgl_dr_line ( d:far ptr, x0:word, y0:word, x1:word, y1:word, col:word )
;;
;; Bresenham, one pixel at a time through qgl_sf_row. Slow per pixel and
;; deliberately so: the only caller is the loading spinner, and giving it
;; a run-based special case would be code nothing else reads.
;;::::::::::::::
qgl_dr_line     proc    public uses bx cx dx si di es,\
                        d:dword, x0:word, y0:word, x1:word, y1:word, col:word

                local   cx_:word
                local   cy:word
                local   sx:word
                local   sy:word
                local   dx_:word
                local   dy:word
                local   err:word

                mov     ax, x0
                mov     cx_, ax
                mov     ax, y0
                mov     cy, ax

                ;; dx = |x1-x0|, sx = sign
                mov     ax, x1
                sub     ax, x0
                mov     word ptr sx, 1
                jns     @F
                neg     ax
                mov     word ptr sx, -1
@@:             mov     dx_, ax

                ;; dy = -|y1-y0|, sy = sign
                mov     ax, y1
                sub     ax, y0
                mov     word ptr sy, 1
                jns     @F
                neg     ax
                mov     word ptr sy, -1
@@:             neg     ax
                mov     dy, ax

                mov     ax, dx_
                add     ax, dy
                mov     err, ax

@@step:         ;; plot, clipped
                les     bx, d
                mov     ax, cx_
                cmp     ax, es:[bx].Surface.x_res
                jae     @@skip
                mov     ax, cy
                cmp     ax, es:[bx].Surface.y_res
                jae     @@skip

                invoke  qgl_sf_row, d, cy
                mov     es, dx
                mov     di, ax
                add     di, cx_
                mov     al, byte ptr col
                mov     es:[di], al

@@skip:         mov     ax, cx_
                cmp     ax, x1
                jne     @F
                mov     ax, cy
                cmp     ax, y1
                je      @@out

@@:             mov     ax, err
                add     ax, ax                  ;; e2 = 2*err
                cmp     ax, dy
                jl      @F
                mov     bx, dy
                add     err, bx
                mov     bx, sx
                add     cx_, bx
@@:             mov     ax, err
                add     ax, ax
                cmp     ax, dx_
                jg      @F
                mov     bx, dx_
                add     err, bx
                mov     bx, sy
                add     cy, bx
@@:             jmp     @@step

@@out:          ret
qgl_dr_line     endp


;;::::::::::::::
;; qgl_dr_shade ( d:far ptr, x0:word, y0:word, x1:word, y1:word,
;;                lut:far ptr, row:word )
;;
;; Every pixel replaced by lut[row*256 + pixel] -- Quake's colormap, and
;; what puts tinted glass under the HUD panels with the scene still
;; visible through it.
;;::::::::::::::
qgl_dr_shade    proc    public uses bx cx dx si di ds es,\
                        d:dword, x0:word, y0:word, x1:word, y1:word,\
                        lut:dword, row:word

                local   runx:word
                local   runlen:word
                local   yy:word
                local   ylast:word
                local   lutseg:word
                local   lutofs:word

                les     bx, d
                mov     cx, es:[bx].Surface.x_res
                mov     ax, x0
                mov     bx, x1
                call    qgl$clip_run
                jc      @@out
                mov     runx, ax
                mov     runlen, cx

                les     bx, d
                mov     cx, es:[bx].Surface.y_res
                mov     ax, y0
                mov     bx, y1
                call    qgl$clip_run
                jc      @@out
                mov     yy, ax
                add     cx, ax
                dec     cx
                mov     ylast, cx

                ;; the colormap row, folded into a segment so row*256 +
                ;; index stays inside sixteen bits -- the same
                ;; normalisation sb_build does
                mov     ax, word ptr lut+2
                mov     lutseg, ax
                mov     ax, word ptr lut
                mov     bx, row
                shl     bx, 8
                add     ax, bx
                mov     lutofs, ax

@@row:          mov     ax, yy
                cmp     ax, ylast
                ja      @@out

                invoke  qgl_sf_row, d, yy
                mov     es, dx
                mov     di, ax
                add     di, runx
                mov     cx, runlen

                push    ds
                mov     ds, lutseg
                mov     si, lutofs
@@px:           mov     al, es:[di]
                xlat                            ;; al = ds:[si + al]
                mov     es:[di], al
                inc     di
                loop    @@px
                pop     ds

                inc     yy
                jmp     @@row

@@out:          ret
qgl_dr_shade    endp


;;::::::::::::::
;; qgl_dr_blit ( d:far ptr, x:word, y:word, s:far ptr )
;;
;; The whole source, one to one. See this module's header on why the two
;; surfaces must not share an EMS slot.
;;::::::::::::::
qgl_dr_blit     proc    public uses bx cx dx si di ds es,\
                        d:dword, x:word, y:word, s:dword

                local   sy:word
                local   srows:word
                local   swide:word
                local   dseg:word
                local   dofs:word

                les     bx, s
                mov     ax, es:[bx].Surface.y_res
                mov     srows, ax
                mov     ax, es:[bx].Surface.x_res
                mov     swide, ax

                xor     ax, ax
                mov     sy, ax

@@row:          mov     ax, sy
                cmp     ax, srows
                jae     @@out

                ;; destination first, then source: whichever is fetched
                ;; last is the one still mapped when the copy runs, and
                ;; the copy reads the source
                mov     ax, y
                add     ax, sy
                les     bx, d
                cmp     ax, es:[bx].Surface.y_res
                jae     @@next

                invoke  qgl_sf_row, d, ax
                mov     dseg, dx
                add     ax, x
                mov     dofs, ax

                invoke  qgl_sf_row, s, sy
                push    ds
                mov     ds, dx
                mov     si, ax
                mov     es, dseg
                mov     di, dofs
                mov     cx, swide
                call    qgl$run_copy
                pop     ds

@@next:         inc     sy
                jmp     @@row

@@out:          ret
qgl_dr_blit     endp


;;::::::::::::::
;; qgl_dr_blit_scl ( d:far ptr, x:word, y:word, w:word, h:word, s:far ptr )
;;
;; Nearest neighbour, which is what the present path needs: stuff.ini
;; renders at 160x100 into a 320x200 mode and the magnification is a
;; whole number. The inner loop is the affine texture step with the v
;; coordinate held still, so it is the same arithmetic one row at a time.
;;::::::::::::::
qgl_dr_blit_scl proc    public uses bx cx dx si di ds es,\
                        d:dword, x:word, y:word, w:word, h:word, s:dword

                local   dy:word
                local   ustep:word
                local   vstep:word
                local   vacc:word
                local   sseg:word
                local   sofs:word

                mov     ax, w
                test    ax, ax
                jz      @@out
                mov     ax, h
                test    ax, ax
                jz      @@out

                ;; 8.8 steps: source extent over destination extent
                les     bx, s
                mov     ax, es:[bx].Surface.x_res
                xor     dx, dx
                shl     eax, 8
                div     w
                mov     ustep, ax

                les     bx, s
                mov     ax, es:[bx].Surface.y_res
                xor     dx, dx
                shl     eax, 8
                div     h
                mov     vstep, ax

                xor     ax, ax
                mov     dy, ax
                mov     vacc, ax

@@row:          mov     ax, dy
                cmp     ax, h
                jae     @@out

                mov     ax, vacc
                shr     ax, 8                   ;; source row
                invoke  qgl_sf_row, s, ax
                mov     sseg, dx
                mov     sofs, ax

                mov     ax, y
                add     ax, dy
                les     bx, d
                cmp     ax, es:[bx].Surface.y_res
                jae     @@next

                invoke  qgl_sf_row, d, ax
                mov     es, dx
                mov     di, ax
                add     di, x

                push    ds
                mov     ds, sseg
                mov     cx, w
                xor     bx, bx                  ;; 8.8 u accumulator
@@px:           mov     si, bx
                shr     si, 8
                add     si, sofs
                mov     al, ds:[si]
                mov     es:[di], al
                inc     di
                add     bx, ustep
                loop    @@px
                pop     ds

@@next:         mov     ax, vstep
                add     vacc, ax
                inc     dy
                jmp     @@row

@@out:          ret
qgl_dr_blit_scl endp

                end
