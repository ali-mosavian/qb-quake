;; mglems.asm -- a qgl Surface over a view onto one of mgl's EMS dcs.
;;
;; name: qglSfAdoptEms
;; desc: TRANSITIONAL, like mgldc.asm beside it, and for the same reason:
;;       it exists so qgl can draw from pixels mgl still owns.
;;
;;       SEPARATE FROM mgldc.asm BECAUSE IT CALLS INTO mgl. mgldc.asm is
;;       in the standalone suite's QGLSRC, so every one of its tests
;;       links it; a reference to emsMapEx from there is an undefined
;;       symbol in all sixteen, which is what happened when this was
;;       written into that file. The suite stays mgl-free and this module
;;       is linked only into qrender, where the top-level wildcard picks
;;       it up. Its test is -qgltex, in BASIC, against the shipping
;;       build -- the same vehicle as -qglcheck and -qgldiff, and for the
;;       same reason: UGLV.LIB is a __CMP__=VBD build whose cold paths
;;       call the BASIC runtime, so a free-standing EXE that stubs them
;;       is exercising a different program.
;;
;; obs.: - the atlas is an EMS dc (mod_tex.bas, uglNewBMPEx UGL.EMS) with
;;         one view per mip size aimed at a cell. An EMS dc has no linear
;;         address, so this MAPS the cell's page into a physical slot and
;;         hands back a Surface over the frame window. Conventional as
;;         far as qgl is concerned, because by then it is. Nothing is
;;         copied and nothing is owned.
;;       - ROW 0's addrTB ENTRY IS THE ONE FACT. mgl fills it as a pair,
;;         word 0 log-page:handle and word 2 the offset within that page,
;;         and uglSetView recomputes it when the view is re-aimed. The
;;         caller has another candidate in tex_ofs, the cell offset
;;         mkassets ships, but the two are not independent: mgl DERIVED
;;         addrTB from that very number. Taking addrTB means qgl reads
;;         the address mgl itself would use, and there is no second
;;         derivation of the page split to disagree with.
;;       - THE WINDOW IS ONLY GOOD UNTIL SOMETHING ELSE TAKES THE SLOT.
;;         That is AGENTS.md's "a mapped EMS pointer is only as good as
;;         its lock", and what makes it safe here is the bounded use: one
;;         qglRsPoly call, a conventional destination, no depth.
;;         Nothing inside that call maps anything. Widen the use and this
;;         needs a lock.

                .model  medium, pascal
                .386

                include qgl.inc

;; mgl's dc, the fields this needs (src/inc/ugl.inc)
DC_TYP          equ     2               ;; word
DC_XRES         equ     6               ;; word
DC_YRES         equ     8               ;; word
DC_BPS          equ     10              ;; word, bytes per scanline
DC_ADDRTB       equ     32              ;; the scanline table, straight after
                                        ;; the union. 32 and not 36: the
                                        ;; shipped library carries no
                                        ;; UGL_SIGN, so it was built without
                                        ;; _DEBUG_ and DC.sign is absent.
                                        ;; -qgltex reads real bytes back, so
                                        ;; this being wrong fails loudly.

DC_EMS          equ     128             ;; 2 * T DCT, and DCTSIZE is 64

;; One 16K logical page into one physical page, WITHOUT disturbing the
;; other three. mgl's own doc: it "takes the slot as an argument instead,
;; which is what lets several paged objects be live at once", and "the
;; slot cache in ppgTB is updated as em$AccessEx would, so a later dc
;; access through the same slot still sees a correct picture".
;;
;; That last sentence is why this goes through mgl instead of INT 67h. A
;; raw remap leaves ppgTB describing a page that is no longer there, and
;; mgl's next access through that slot skips a remap it needed -- reading
;; the wrong picture with nothing to say so.
emsMapEx        proto   far pascal :word, :word, :word

.code

;;::::::::::::::
;; qglSfAdoptEms ( dc:dword, slot:word, s:far ptr Surface ) -> ax nonzero
;;
;; Fills a caller-owned Surface. qglSfFree must NOT be called on it:
;; the bytes are mgl's and the window is the EMS frame's.
;;
;; A cell must not straddle a page, or one window would not cover it.
;; mkassets guarantees that -- sizes are 4096/1024/256/64 and each sits
;; at a multiple of its own size -- and this checks rather than trusts.
;;::::::::::::::
qglSfAdoptEms proc   public uses bx cx dx si di es,\
                        dc:dword, slot:word, s:dword

                local   a0:word, o0:word

                les     bx, dc
                mov     ax, es
                or      ax, bx
                jz      @@no

                cmp     word ptr es:[bx+DC_TYP], DC_EMS
                jne     @@no

                mov     cx, word ptr es:[bx+DC_XRES]
                mov     dx, word ptr es:[bx+DC_YRES]
                mov     si, word ptr es:[bx+DC_BPS]

                test    cx, cx
                jz      @@no
                test    dx, dx
                jz      @@no
                cmp     si, cx
                jne     @@no                    ;; a padded row is not a cell

                ;; the cell, whole, inside one 16K page.
                ;;
                ;; mul writes dx:ax, so the height is gone the moment it
                ;; runs and has to come back off the dc -- the same trap
                ;; qglRsTex records, where reusing dx built the v mask
                ;; out of the product's high word and sent one row in
                ;; eight past the end of the texture.
                mov     ax, cx
                mul     dx
                test    dx, dx
                jnz     @@no                    ;; past a word already
                mov     di, ax                  ;; di = the cell's bytes
                mov     dx, word ptr es:[bx+DC_YRES]

                mov     ax, word ptr es:[bx+DC_ADDRTB+0]
                mov     a0, ax
                mov     ax, word ptr es:[bx+DC_ADDRTB+2]
                mov     o0, ax

                add     ax, di
                jc      @@no
                cmp     ax, 4000h
                ja      @@no                    ;; it straddles a page

                invoke  emsMapEx, a0, 0, slot
                test    ax, ax
                jz      @@no                    ;; no frame, no window

                push    es
                les     bx, s
                mov     es:[bx].Surface.x_res, cx
                mov     es:[bx].Surface.y_res, dx
                mov     es:[bx].Surface.stride, si
                mov     es:[bx].Surface.kind, SURF_CMEM
                mov     es:[bx].Surface.wr_slot, 0
                mov     es:[bx].Surface.rd_slot, 0
                mov     es:[bx].Surface.handle, ax      ;; the frame segment
                mov     ax, o0
                mov     word ptr es:[bx].Surface.base_ofs, ax
                mov     word ptr es:[bx].Surface.base_ofs+2, 0
                pop     es

                mov     ax, 1
                ret

@@no:           xor     ax, ax
                ret
qglSfAdoptEms endp

                end
