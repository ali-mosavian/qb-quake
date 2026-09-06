;; mgldc.asm -- a qgl Surface over one of mgl's MEM device contexts.
;;
;; name: qgl_sf_adopt_dc
;; desc: TRANSITIONAL, and the whole file goes when the destination is a
;;       qgl Surface in its own right.
;;
;;       qgl draws through qgl_sf_row; mgl draws into a DC. They are not
;;       interchangeable, and everything left on the plan -- the font,
;;       the texture views, the surface builder -- needs qgl to write
;;       where mgl currently owns the pixels. Rather than teach each of
;;       those about DCs, one place here turns a MEM DC into a Surface
;;       aliasing the same bytes. Nothing is copied and nothing is owned:
;;       the DC remains mgl's to free.
;;
;;       Only DC_MEM. An EMS or banked DC is not linearly addressable and
;;       is refused rather than half-supported.
;;
;; obs.: - the field offsets are mgl's struct, read out of ugl.inc: bps
;;         at 10, and the pixel far pointer at 28, where the MEM/EMS/XMS
;;         union sits. The union's widest arm is MEM_DC's own dword, so
;;         the layout ahead of it is fixed and there is nothing version
;;         dependent to get wrong.
;;       - it still CHECKS rather than trusts. A DC whose fields do not
;;         agree with each other -- zero extents, a stride narrower than
;;         a row, a null pointer -- is refused, so a layout that drifts
;;         under us fails loudly at adoption instead of quietly writing
;;         through a plausible wrong pointer. That is the same bargain
;;         r_walk.c's own layout check makes.

                .model  medium, pascal
                .386

                include qgl.inc

;; mgl's DC, as much of it as this needs (src/inc/ugl.inc)
DC_TYP          equ     2               ;; word: 0 = DC_MEM
DC_XRES         equ     6               ;; word
DC_YRES         equ     8               ;; word
DC_BPS          equ     10              ;; word, bytes per scanline
DC_FPTR         equ     28              ;; dword, MEM_DC.fptr

DC_MEM          equ     0


.code

;;::::::::::::::
;; qgl_sf_adopt_dc ( dc:dword, s:far ptr Surface ) -> ax nonzero on success
;;
;; Fills a caller-owned Surface that points at the DC's own pixels. The
;; caller keeps ownership of both: qgl_sf_free must NOT be called on the
;; result, since the bytes belong to mgl.
;;::::::::::::::
qgl_sf_adopt_dc proc    public uses bx cx dx si di es,\
                        dc:dword, s:dword

                les     bx, dc
                mov     ax, es
                or      ax, bx
                jz      @@no

                ;; linear memory only
                cmp     word ptr es:[bx+DC_TYP], DC_MEM
                jne     @@no

                mov     cx, word ptr es:[bx+DC_XRES]
                mov     dx, word ptr es:[bx+DC_YRES]
                mov     si, word ptr es:[bx+DC_BPS]

                ;; the fields have to agree with each other, or the
                ;; offsets above are not describing this DC
                test    cx, cx
                jz      @@no
                test    dx, dx
                jz      @@no
                cmp     si, cx
                jb      @@no                    ;; stride narrower than a row

                mov     ax, word ptr es:[bx+DC_FPTR]
                mov     di, word ptr es:[bx+DC_FPTR+2]
                test    di, di
                jz      @@no                    ;; null segment is not pixels

                push    es
                push    bx
                les     bx, s
                mov     es:[bx].Surface.x_res, cx
                mov     es:[bx].Surface.y_res, dx
                mov     es:[bx].Surface.stride, si
                mov     es:[bx].Surface.kind, SURF_CMEM
                mov     es:[bx].Surface.wr_slot, 0
                mov     es:[bx].Surface.rd_slot, 0
                mov     es:[bx].Surface.handle, di      ;; the segment
                mov     word ptr es:[bx].Surface.base_ofs, ax
                mov     word ptr es:[bx].Surface.base_ofs+2, 0
                pop     bx
                pop     es

                mov     ax, 1
                ret

@@no:           xor     ax, ax
                ret
qgl_sf_adopt_dc endp

                end
