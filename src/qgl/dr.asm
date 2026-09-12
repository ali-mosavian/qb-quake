;; dr.asm -- drawing onto a surface: runs, rectangles, lines and blits.
;;
;; name: qglDrFill / qglDrHline / qglDrVline / qglDrRect /
;;       qglDrLine / qglDrShade / qglDrBlit / qglDrBlitScl
;; desc: nearly everything here is a horizontal run, or a stack of them.
;;       A filled rectangle is h runs of a colour, a blit is h runs
;;       copied, a clear is the whole surface as one rectangle. Only
;;       qglDrLine is not, and it is here because the loading spinner
;;       wants one.
;;
;;       Rows come from qglSfRow, so all of it works on an EMS surface
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
;;         and the destination row from qglSfRow in turn. That is only
;;         safe while the two do not share one EMS slot, which is the
;;         same discipline q_map.bi already documents for PAGE_SLOT. A
;;         conventional destination -- what the backbuffer is -- cannot
;;         collide at all.

                .model  medium, pascal
                .386

                include qgl.inc

qglSfRdRow   proto   far pascal :dword, :word
qglSfWrRow   proto   far pascal :dword, :word


                QGL_CODE

                externdef qgl$RunFill:near
                externdef qgl$RunCopy:near




;;::::::::::::::
;; qgl$ClipRun -- clip x0..x1 inclusive to 0..limit-1.
;;
;; INTERNAL: ax = x0, bx = x1, cx = limit. Carry set if nothing is left;
;; otherwise ax = first column and cx = length. bx is consumed.
;;::::::::::::::
;;::::::::::::::
;; qgl$Dup2 -- one source row doubled into a destination row.
;;
;; INTERNAL: ds:si -> source, es:di -> destination, cx = SOURCE bytes.
;; Writes 2*cx. Forward only. Everything survives except si, di and cx.
;;
;; Two instructions a source byte, against the sampler's seven a
;; destination byte: at exactly 2x the 8.8 accumulator, its shift and its
;; add all compute a step of one half, and none of them has to run.
;;
;; No odd starting phase, because the only caller is the full-surface
;; case where x is zero.
;;::::::::::::::
qgl$Dup2        proc    near private uses ax cx
                cld
                jcxz    @@out
@@p:            lodsb
                mov     ah, al
                stosw
                loop    @@p
@@out:          ret
qgl$Dup2        endp


;;::::::::::::::
;; qgl$Norm -- a byte offset into a cmem store, split the way
;; qgl$RowCmem splits one: paragraphs into a segment, the remainder into
;; an offset of 0..15. The caller adds the surface's own handle.
;;
;; INTERNAL: eax = the offset. Out: ax = paragraphs, dx = 0..15.
;;::::::::::::::
qgl$Norm        proc    near private
                mov     dx, ax
                and     dx, 000Fh
                shr     eax, 4
                ret
qgl$Norm        endp

qgl$ClipRun    proc    near private

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
qgl$ClipRun    endp


;;::::::::::::::
;; qglDrHline ( d:far ptr, x0:word, y:word, x1:word, col:word )
;;::::::::::::::
qglDrHline    proc    public uses bx cx dx si di es,\
                        d:dword, x0:word, y:word, x1:word, col:word

                local   runx:word
                local   runlen:word

                les     bx, d
                mov     ax, y
                cmp     ax, es:[bx].Surface.yRes
                jae     @@out                   ;; unsigned: catches y < 0

                mov     cx, es:[bx].Surface.xRes
                mov     ax, x0
                mov     bx, x1
                call    qgl$ClipRun
                jc      @@out
                mov     runx, ax
                mov     runlen, cx

                invoke  qglSfWrRow, d, y
                mov     es, dx
                mov     di, ax
                add     di, runx
                mov     cx, runlen
                mov     al, byte ptr col
                call    qgl$RunFill

@@out:          ret
qglDrHline    endp


;;::::::::::::::
;; qglDrFill ( d:far ptr, x0:word, y0:word, x1:word, y1:word, col:word )
;;
;; Also how a surface is cleared: the whole of it is just the largest
;; rectangle, and there is no reason for a second routine that says so.
;;::::::::::::::
qglDrFill     proc    public uses bx cx dx si di es,\
                        d:dword, x0:word, y0:word, x1:word, y1:word, col:word

                local   runx:word
                local   runlen:word
                local   yy:word
                local   ylast:word

                les     bx, d
                mov     cx, es:[bx].Surface.xRes
                mov     ax, x0
                mov     bx, x1
                call    qgl$ClipRun
                jc      @@out
                mov     runx, ax
                mov     runlen, cx

                les     bx, d
                mov     cx, es:[bx].Surface.yRes
                mov     ax, y0
                mov     bx, y1
                call    qgl$ClipRun            ;; the same clamp, on rows
                jc      @@out
                mov     yy, ax
                add     cx, ax
                dec     cx
                mov     ylast, cx

@@row:          mov     ax, yy
                cmp     ax, ylast
                ja      @@out

                invoke  qglSfWrRow, d, yy
                mov     es, dx
                mov     di, ax
                add     di, runx
                mov     cx, runlen
                mov     al, byte ptr col
                call    qgl$RunFill

                inc     yy
                jmp     @@row

@@out:          ret
qglDrFill     endp


;;::::::::::::::
;; qglDrVline ( d:far ptr, x:word, y0:word, y1:word, col:word )
;;::::::::::::::
qglDrVline    proc    public uses bx cx dx si di es,\
                        d:dword, x:word, y0:word, y1:word, col:word

                local   yy:word
                local   ylast:word

                les     bx, d
                mov     ax, x
                cmp     ax, es:[bx].Surface.xRes
                jae     @@out

                mov     cx, es:[bx].Surface.yRes
                mov     ax, y0
                mov     bx, y1
                call    qgl$ClipRun
                jc      @@out
                mov     yy, ax
                add     cx, ax
                dec     cx
                mov     ylast, cx

@@row:          mov     ax, yy
                cmp     ax, ylast
                ja      @@out

                invoke  qglSfWrRow, d, yy
                mov     es, dx
                mov     di, ax
                add     di, x
                mov     al, byte ptr col
                mov     es:[di], al

                inc     yy
                jmp     @@row

@@out:          ret
qglDrVline    endp


;;::::::::::::::
;; qglDrRect ( d:far ptr, x0:word, y0:word, x1:word, y1:word, col:word )
;;
;; The outline, as four runs. Each clips itself, so a rectangle hanging
;; off an edge loses only the parts that are off it.
;;::::::::::::::
qglDrRect     proc    public uses bx,\
                        d:dword, x0:word, y0:word, x1:word, y1:word, col:word

                invoke  qglDrHline, d, x0, y0, x1, col
                invoke  qglDrHline, d, x0, y1, x1, col
                invoke  qglDrVline, d, x0, y0, y1, col
                invoke  qglDrVline, d, x1, y0, y1, col
                ret
qglDrRect     endp


;;::::::::::::::
;; qglDrLine ( d:far ptr, x0:word, y0:word, x1:word, y1:word, col:word )
;;
;; Bresenham, one pixel at a time through qglSfRow. Slow per pixel and
;; deliberately so: the only caller is the loading spinner, and giving it
;; a run-based special case would be code nothing else reads.
;;::::::::::::::
qglDrLine     proc    public uses bx cx dx si di es,\
                        d:dword, x0:word, y0:word, x1:word, y1:word, col:word

                local   cx_:word
                local   cy:word
                local   sx:word
                local   sy:word
                local   dx_:word
                local   dy:word
                local   err:word
                local   e2:word

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
                cmp     ax, es:[bx].Surface.xRes
                jae     @@skip
                mov     ax, cy
                cmp     ax, es:[bx].Surface.yRes
                jae     @@skip

                invoke  qglSfWrRow, d, cy
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
                mov     e2, ax
                cmp     ax, dy
                jl      @F
                mov     bx, dy
                add     err, bx
                mov     bx, sx
                add     cx_, bx
@@:             mov     ax, e2
                cmp     ax, dx_
                jg      @F
                mov     bx, dx_
                add     err, bx
                mov     bx, sy
                add     cy, bx
@@:             jmp     @@step

@@out:          ret
qglDrLine     endp


;;::::::::::::::
;; qglDrShade ( d:far ptr, x0:word, y0:word, x1:word, y1:word,
;;                lut:far ptr, row:word )
;;
;; Every pixel replaced by lut[row*256 + pixel] -- Quake's colormap, and
;; what puts tinted glass under the HUD panels with the scene still
;; visible through it.
;;::::::::::::::
qglDrShade    proc    public uses bx cx dx si di ds es,\
                        d:dword, x0:word, y0:word, x1:word, y1:word,\
                        lut:dword, row:word

                local   runx:word
                local   runlen:word
                local   yy:word
                local   ylast:word
                local   lutseg:word
                local   lutofs:word

                les     bx, d
                mov     cx, es:[bx].Surface.xRes
                mov     ax, x0
                mov     bx, x1
                call    qgl$ClipRun
                jc      @@out
                mov     runx, ax
                mov     runlen, cx

                les     bx, d
                mov     cx, es:[bx].Surface.yRes
                mov     ax, y0
                mov     bx, y1
                call    qgl$ClipRun
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

                invoke  qglSfWrRow, d, yy
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
qglDrShade    endp


;;::::::::::::::
;; qglDrBlit ( d:far ptr, x:word, y:word, s:far ptr )
;;
;; The whole source, one to one. See this module's header on why the two
;; surfaces must not share an EMS slot.
;;
;; TWO PATHS, chosen once. When both surfaces are cmem the rows are walked
;; with a cursor: the first address is resolved once and then advanced by
;; the stride, the way uglBlit resolves once and hands ul$copy the whole
;; rectangle. Anything else -- either surface in EMS -- keeps the generic
;; per-row mapper, because two live EMS pointers stop being valid the
;; moment a remap takes their window, and a cursor cannot notice that.
;;
;; The cursor is a SEGMENT and a 0..15 offset, not a flat 16-bit offset:
;; qgl$RowCmem normalises every row that way, and a surface wider than
;; 64K -- t15blit's 512x144 -- would wrap a plain offset back into its own
;; first column with nothing to say so.
;;::::::::::::::
qglDrBlit     proc    public uses bx cx dx si di ds es,\
                        d:dword, x:word, y:word, s:dword

                local   sy:word
                local   srows:word
                local   swide:word
                local   dseg:word
                local   dofs:word
                local   dcol:word
                local   dlen:word
                local   sskip:word
                local   nrows:word
                local   dsegc:word, dofsc:word
                local   ssegc:word, sofsc:word
                local   dsegs:word, dofss:word
                local   ssegs:word, sofss:word

                les     bx, s
                mov     ax, es:[bx].Surface.yRes
                mov     srows, ax
                mov     ax, es:[bx].Surface.xRes
                mov     swide, ax

                ;; the columns, once: x and the source width do not
                ;; change down the rows, so neither does the clip
                les     bx, d
                mov     cx, es:[bx].Surface.xRes
                mov     ax, x
                mov     bx, x
                add     bx, swide
                dec     bx                      ;; inclusive last column
                call    qgl$ClipRun
                jc      @@out
                mov     dcol, ax
                mov     dlen, cx
                sub     ax, x                   ;; columns clipped off the left
                mov     sskip, ax

                ;;
                ;; THE ROWS, once. y is signed here: a caller may place a
                ;; source above the top edge, and the rows that land off
                ;; it are skipped rather than drawn wrapped.
                ;;
                les     bx, d
                mov     cx, es:[bx].Surface.yRes

                ;;
                ;; THE ROWS, once, split on the sign of y. Kept as two
                ;; cases rather than one subtraction because the single
                ;; form has two traps: y_res-y wraps to a huge UNSIGNED
                ;; word when y is at or past the bottom edge, which an
                ;; unsigned cap then reads as an enormous row count; and
                ;; abs() has no answer for -32768. neg does, and the
                ;; source-height test rejects it.
                ;;
                mov     ax, y
                test    ax, ax
                js      @@above

                ;; y >= 0: at or below the top edge
                cmp     ax, cx
                jae     @@out                   ;; at or past the bottom
                mov     sy, 0
                sub     cx, ax                  ;; rows left on the dest
                mov     ax, srows
                cmp     ax, cx
                jbe     @F
                mov     ax, cx
@@:             mov     nrows, ax
                jmp     @@rowsok

@@above:        ;; y < 0: the first -y source rows are off the top
                neg     ax
                cmp     ax, srows
                jae     @@out                   ;; the whole source is above
                mov     sy, ax
                mov     ax, srows
                sub     ax, sy                  ;; what is left of it
                cmp     ax, cx
                jbe     @F
                mov     ax, cx                  ;; but no taller than the dest
@@:             mov     nrows, ax

@@rowsok:

                ;; both cmem? then walk the address tables. Decided ONCE.
                les     bx, d
                cmp     es:[bx].Surface.typ, SF_MEM
                jne     @@generic
                les     bx, s
                cmp     es:[bx].Surface.typ, SF_MEM
                jne     @@generic

                ;;
                ;; The cursor that used to be resolved once and stepped by
                ;; the stride is now a table read per row -- the address
                ;; table IS the cursor, and it is the one qgl_mem_New laid
                ;; down, so a surface crossing 64K needs no arithmetic here
                ;; to get right. sofss and dofss carry the byte index into
                ;; each table.
                ;;
                mov     ax, sy
                shl     ax, 2
                mov     sofss, ax

                mov     ax, y                   ;; first destination row
                add     ax, sy
                shl     ax, 2
                mov     dofss, ax

                mov     cx, nrows
@@crow:         push    cx

                les     bx, s
                mov     si, sofss
                add     bx, si
                mov     ax, W es:[bx+SF_addrTB+0]
                mov     dx, W es:[bx+SF_addrTB+2]
                add     dx, sskip
                mov     ssegc, ax
                mov     sofsc, dx

                les     bx, d
                mov     di, dofss
                add     bx, di
                mov     ax, W es:[bx+SF_addrTB+0]
                mov     dx, W es:[bx+SF_addrTB+2]
                add     dx, dcol
                mov     dsegc, ax
                mov     dofsc, dx

                mov     ds, ssegc
                mov     si, sofsc
                mov     es, dsegc
                mov     di, dofsc
                mov     cx, dlen
                call    qgl$RunCopy
                mov     ax, @data
                mov     ds, ax
                pop     cx

                add     sofss, T dword
                add     dofss, T dword

                dec     cx
                jnz     @@crow
                jmp     @@out

@@generic:
@@row:          mov     ax, sy
                cmp     ax, srows
                jae     @@out

                ;; destination first, then source: whichever is fetched
                ;; last is the one still mapped when the copy runs, and
                ;; the copy reads the source
                mov     ax, y
                add     ax, sy
                les     bx, d
                cmp     ax, es:[bx].Surface.yRes
                jae     @@next

                invoke  qglSfWrRow, d, ax
                mov     dseg, dx
                add     ax, dcol
                mov     dofs, ax

                invoke  qglSfRdRow, s, sy
                push    ds
                mov     ds, dx
                mov     si, ax
                add     si, sskip
                mov     es, dseg
                mov     di, dofs
                mov     cx, dlen
                call    qgl$RunCopy
                pop     ds

@@next:         inc     sy
                jmp     @@row

@@out:          ret
qglDrBlit     endp


;;::::::::::::::
;; qglDrBlitScl ( d:far ptr, x:word, y:word, w:word, h:word, s:far ptr )
;;
;; Nearest neighbour, which is what the present path needs: stuff.ini
;; renders at 160x100 into a 320x200 mode and the magnification is a
;; whole number. The inner loop is the affine texture step with the v
;; coordinate held still, so it is the same arithmetic one row at a time.
;;::::::::::::::
qglDrBlitScl proc    public uses bx cx dx si di ds es,\
                        d:dword, x:word, y:word, w:word, h:word, s:dword

                local   dy:word
                local   ustep:dword
                local   vstep:dword
                local   vacc:dword
                local   sseg:word
                local   sofs:word
                local   dcol:word
                local   dlen:word
                local   u0:dword
                local   srows2:word, swide:word
                local   dsegc:word, dofsc:word
                local   ssegc:word, sofsc:word
                local   dsegs:word, dofss:word
                local   ssegs:word, sofss:word

                mov     ax, w
                test    ax, ax
                jz      @@out
                mov     ax, h
                test    ax, ax
                jz      @@out

                ;; 8.8 steps: source extent over destination extent, in
                ;; 32 bits -- a word holds 255 columns of 8.8, and the
                ;; status bar is 320 (t15blit case 7).
                les     bx, s
                movzx   eax, es:[bx].Surface.xRes
                mov     swide, ax
                shl     eax, 8
                movzx   ecx, w
                xor     edx, edx
                div     ecx
                mov     ustep, eax

                les     bx, s
                movzx   eax, es:[bx].Surface.yRes
                shl     eax, 8
                movzx   ecx, h
                xor     edx, edx
                div     ecx
                mov     vstep, eax

                ;; the columns, once. u0 is where the accumulator starts
                ;; when the left of the rectangle was cut off.
                les     bx, d
                mov     cx, es:[bx].Surface.xRes
                mov     ax, x
                mov     bx, x
                add     bx, w
                dec     bx                      ;; inclusive last column
                call    qgl$ClipRun
                jc      @@out
                mov     dcol, ax
                mov     dlen, cx
                sub     ax, x
                movzx   eax, ax
                mul     ustep
                mov     u0, eax

                ;;
                ;; THE WHOLE SURFACE, EXACTLY DOUBLED, BOTH CMEM.
                ;;
                ;; Deliberately the narrowest predicate that covers the
                ;; shipped present -- common.bas picks view_scale as "the
                ;; largest whole-number multiple", 2 at 160x100 into
                ;; 320x200 -- and nothing else. Everything outside it,
                ;; including every clipped or fractional case and any EMS
                ;; operand, falls through to the generic loop below,
                ;; which is unchanged.
                ;;
                ;; Narrow ON PURPOSE: with the rectangle exactly covering
                ;; the destination there is no clipping to get wrong, and
                ;; with x zero there is no odd starting phase. The earlier
                ;; wider version had to reimplement both, and got the
                ;; previous-row cursor wrong by subtracting a normalised
                ;; offset without a borrow.
                ;;
                mov     ax, x
                or      ax, y
                jnz     @@generic               ;; the whole surface only
                les     bx, d
                cmp     es:[bx].Surface.typ, SF_MEM
                jne     @@generic
                mov     ax, w
                cmp     ax, es:[bx].Surface.xRes
                jne     @@generic
                mov     ax, h
                cmp     ax, es:[bx].Surface.yRes
                jne     @@generic
                mov     dx, W es:[bx].Surface.fptr+2

                les     bx, s
                cmp     es:[bx].Surface.typ, SF_MEM
                jne     @@generic
                cmp     dx, W es:[bx].Surface.fptr+2
                je      @@generic               ;; one store, so they overlap
                ;; HALVE THE DESTINATION, do not double the source: a
                ;; source extent over 32767 doubles into a wrap, and a
                ;; wrapped value can equal w and let the fast path take a
                ;; surface it does not fit.
                test    w, 1
                jnz     @@generic               ;; odd cannot be twice
                mov     ax, w
                shr     ax, 1
                cmp     ax, es:[bx].Surface.xRes
                jne     @@generic               ;; not exactly doubled
                test    h, 1
                jnz     @@generic
                mov     ax, h
                shr     ax, 1
                cmp     ax, es:[bx].Surface.yRes
                jne     @@generic
                mov     ax, es:[bx].Surface.yRes
                mov     srows2, ax

                ;; the two table cursors: a byte index into each address
                ;; table, stepped by one entry a row. The stride cursor
                ;; this replaced had to carry sixteens by hand and rebuild
                ;; the previous row forward to avoid a borrow; a table
                ;; entry is the whole address and has neither problem.
                xor     ax, ax
                mov     sofss, ax
                mov     dofss, ax

                mov     cx, srows2
@@r2:           push    cx

                les     bx, s
                mov     si, sofss
                add     bx, si
                mov     ax, W es:[bx+SF_addrTB+0]
                mov     dx, W es:[bx+SF_addrTB+2]
                mov     ssegc, ax
                mov     sofsc, dx

                les     bx, d
                mov     di, dofss
                add     bx, di
                mov     ax, W es:[bx+SF_addrTB+0]
                mov     dx, W es:[bx+SF_addrTB+2]
                mov     dsegc, ax
                mov     dofsc, dx

                ;; expand into the first row of the pair, keeping its
                ;; address for the copy
                push    ds
                mov     ds, ssegc
                mov     si, sofsc
                mov     es, dsegc
                mov     di, dofsc
                mov     cx, swide
                call    qgl$Dup2
                pop     ds

                mov     ax, dsegc               ;; the row just written
                mov     sseg, ax
                mov     ax, dofsc
                mov     sofs, ax

                add     dofss, T dword          ;; the second row of the pair
                les     bx, d
                mov     di, dofss
                add     bx, di
                mov     ax, W es:[bx+SF_addrTB+0]
                mov     dx, W es:[bx+SF_addrTB+2]
                mov     dsegc, ax
                mov     dofsc, dx

                ;; the second row is the same bytes; copy, do not expand
                push    ds
                mov     ds, sseg
                mov     si, sofs
                mov     es, dsegc
                mov     di, dofsc
                mov     cx, dlen
                call    qgl$RunCopy
                pop     ds

                add     dofss, T dword          ;; on to the next pair
                add     sofss, T dword

                pop     cx
                dec     cx
                jnz     @@r2
                jmp     @@out

@@generic:
                xor     eax, eax
                mov     dy, ax
                mov     vacc, eax

@@row:          mov     ax, dy
                cmp     ax, h
                jae     @@out

                mov     eax, vacc
                shr     eax, 8                  ;; source row
                invoke  qglSfRdRow, s, ax
                mov     sseg, dx
                mov     sofs, ax

                mov     ax, y
                add     ax, dy
                les     bx, d
                cmp     ax, es:[bx].Surface.yRes
                jae     @@next

                invoke  qglSfWrRow, d, ax
                mov     es, dx
                mov     di, ax
                add     di, dcol

                push    ds
                mov     ds, sseg
                mov     cx, dlen
                mov     ebx, u0                 ;; 8.8 u accumulator
@@px:           mov     esi, ebx
                shr     esi, 8
                add     si, sofs
                mov     al, ds:[si]
                mov     es:[di], al
                inc     di
                add     ebx, ustep
                loop    @@px
                pop     ds

@@next:         mov     eax, vstep
                add     vacc, eax
                inc     dy
                jmp     @@row

@@out:          ret
qglDrBlitScl endp

                

                QGL_ENDS
                end
