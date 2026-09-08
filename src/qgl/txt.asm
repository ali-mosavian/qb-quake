;; txt.asm -- text from a packed 1bpp font.
;;
;; name: qglTxtLoad / qglTxtFree / qglTxtChar / qglTxtStr /
;;       qglTxtWidth
;; desc: the glyphs stay 1 bit a pixel and are expanded as they are drawn.
;;       screen.bas's own path builds 256 separate 8x8 DCs at load
;;       (uglNewMult) and a live MCB walk measured those at 16,400 bytes
;;       of conventional memory for 2,048 bytes of pixels -- against 3,632
;;       bytes actually free on this host, which is the whole reason this
;;       exists.
;;
;;       txt_, not fnt_: BASIC reserves every name beginning FN for DEF FN
;;       user functions, so a `declare sub fnt_char` does not compile.
;;
;; obs.: - the bytes come from file.asm, not from INT 21h here: this
;;         module knows about glyphs and nothing about disks. mkfont.py
;;         writes the file beside the exe, as mkmdl.py does soldier.geo.
;;       - header and payload are ONE allocation, and the payload is
;;         reached by offset from the header. Two bytes rather than four,
;;         and nothing to fix up if the block ever moves.
;;       - a set bit draws, a clear bit leaves the destination alone,
;;         which is what uglPutMsk did with a colour key. The mask table
;;         below does it without a branch per pixel.

                .model  medium, pascal
                .386

                include qgl.inc

qglMemAlloc   proto   far pascal :dword
qglMemFree    proto   far pascal :dword
qglSfWrRow   proto   far pascal :dword, :word
qglFileOpen   proto   far pascal :dword
qglFileSize   proto   far pascal :word
qglFileRead   proto   far pascal :word, :dword, :dword
qglFileClose  proto   far pascal :word

IFDEF __BASIC__
qglFileOpenBas proto far pascal :word
ENDIF

FNT_HDR         equ     20              ;; mkfont.py's header IS the Font struct


.data
;; Nibble -> four bytes of 00 or FF. Four pixels a lookup, and the write
;; is (colour AND mask) OR (dst AND NOT mask) with no branch: a per-pixel
;; test-and-jump is the one thing an inner loop over text cannot afford.



                QGL_CODE

                externdef qgl$Nib4:near

;;::::::::::::::
;; qgl$TxtLoadFh -- given an already-open handle, the shared body of
;; qglTxtLoad and qglTxtLoadBas: size it, read it whole, check the
;; magic, hand back the block or free it.
;;
;; INTERNAL: fh:word, the open handle -> dx:ax = far ptr to the font, or
;; 0:0. The handle is always closed before this returns, on every path.
;;::::::::::::::
;; NOT `uses dx`: this returns dx:ax, and the uses epilogue would pop the
;; segment straight back off over the answer. See qgl.inc's contract.
qgl$TxtLoadFh proc    near private uses bx cx si di es,\
                        fh:word

                local   fsize:dword
                local   blk:dword

                invoke  qglFileSize, fh
                mov     word ptr fsize, ax
                mov     word ptr fsize+2, dx

                ;; a font past 64K is not a font
                cmp     word ptr fsize+2, 0
                jne     @@closefail
                cmp     word ptr fsize, FNT_HDR
                jbe     @@closefail

                invoke  qglMemAlloc, fsize
                mov     word ptr blk, ax
                mov     word ptr blk+2, dx
                or      ax, dx
                jz      @@closefail

                invoke  qglFileRead, fh, blk, fsize
                cmp     ax, word ptr fsize
                jne     @@freefail
                invoke  qglFileClose, fh

                ;; The file IS the struct, magic included, and mkfont.py
                ;; wrote bits_ofs and adv_ofs because that end knew them.
                ;; So there is no fixup pass here to get wrong -- only a
                ;; check that this is the kind of file we were promised.
                les     bx, blk
                cmp     word ptr es:[bx], 'NF'          ;; "FN"
                jne     @@freefail2
                cmp     word ptr es:[bx+2], '1T'        ;; "T1"
                jne     @@freefail2

                mov     ax, word ptr blk
                mov     dx, word ptr blk+2
                ret

@@freefail2:    invoke  qglMemFree, blk
                jmp     @@nofile
@@freefail:     invoke  qglMemFree, blk
@@closefail:    invoke  qglFileClose, fh
@@nofile:       xor     ax, ax
                xor     dx, dx
                ret
qgl$TxtLoadFh endp


;;::::::::::::::
;; qglTxtLoad ( path:far ptr to ASCIIZ ) -> far ptr to the font, or 0:0
;;
;; Reads the whole file into one block: header, the advance table if it
;; has one, then the glyph bits.
;;::::::::::::::
qglTxtLoad    proc    public uses bx cx si di es,\
                        path:dword

                invoke  qglFileOpen, path
                test    ax, ax
                jz      @@nofile
                invoke  qgl$TxtLoadFh, ax
                ret
@@nofile:       xor     ax, ax
                xor     dx, dx
                ret
qglTxtLoad    endp


IFDEF __BASIC__
;;::::::::::::::
;; qglTxtLoadBas ( s:BASIC string ) -> far ptr to the font, or 0:0
;;
;; The BASIC-callable entry point: same shared loader, opened through
;; qglFileOpenBas instead of an ASCIIZ far pointer -- see file.asm's
;; header for why a BASIC string needs its own opener.
;;::::::::::::::
qglTxtLoadBas proc   public uses bx cx si di es,\
                        s:word

                invoke  qglFileOpenBas, s
                test    ax, ax
                jz      @@nofile
                invoke  qgl$TxtLoadFh, ax
                ret
@@nofile:       xor     ax, ax
                xor     dx, dx
                ret
qglTxtLoadBas endp
ENDIF


;;::::::::::::::
;; qglTxtFree ( f:far ptr )
;;::::::::::::::
qglTxtFree    proc    public,\
                        f:dword
                invoke  qglMemFree, f
                ret
qglTxtFree    endp


;;::::::::::::::
;; qgl$AdvOf -- how far this glyph moves the pen.
;;
;; INTERNAL: es:bx -> the font, al = the character. ax back, everything
;; else preserved.
;;::::::::::::::
qgl$AdvOf      proc    near private uses si
                xor     ah, ah
                mov     si, ax
                sub     si, es:[bx].Font.first
                cmp     si, es:[bx].Font.count
                jae     @@dflt                  ;; not in this font

                mov     ax, es:[bx].Font.adv_ofs
                test    ax, ax
                jz      @@dflt                  ;; fixed advance
                add     si, ax
                mov     al, es:[bx+si]
                xor     ah, ah
                ret

@@dflt:         mov     al, es:[bx].Font.adv
                xor     ah, ah
                ret
qgl$AdvOf      endp


;;::::::::::::::
;; qglTxtWidth ( f:far ptr, s:far ptr ) -> ax = pixels
;;
;; Walks the advances rather than multiplying by a cell size, so it is
;; still right when the font is proportional. draw_string_r needs this to
;; right-align without assuming anything about the glyphs.
;;::::::::::::::
qglTxtWidth   proc    public uses bx cx dx si di ds es,\
                        f:dword, s:dword

                les     bx, f
                lds     si, s
                xor     di, di                  ;; running width
                cld
@@ch:           lodsb
                test    al, al
                jz      @F
                call    qgl$AdvOf
                add     di, ax
                jmp     @@ch
@@:             mov     ax, di
                ret
qglTxtWidth   endp


;;::::::::::::::
;; qglTxtRow ( f:far ptr, glyph:word, row:word ) -> ax = the row's bits,
;;                                                    MSB leftmost, 0-cell_h-1
;;
;; For a caller that recolours per pixel -- draw_logo's ember gradient,
;; hud_num's chosen colour -- and so cannot use qglTxtChar's fixed
;; colour. Out of range answers 0 rather than faulting, matching
;; qglTxtChar's own silent no-draw for a glyph outside the font.
;;::::::::::::::
qglTxtRow     proc    public uses bx cx dx si es,\
                        f:dword, glyph:word, row:word

                les     bx, f
                mov     ax, glyph
                sub     ax, es:[bx].Font.first
                cmp     ax, es:[bx].Font.count
                jae     @@zero                  ;; not in this font

                mov     cl, es:[bx].Font.cell_h
                xor     ch, ch
                cmp     row, cx
                jae     @@zero                  ;; row past the cell

                ;; ax already holds glyph - first from the range check
                mov     cl, es:[bx].Font.rowbytes
                mul     cx                      ;; (glyph-first) * rowbytes
                mov     cl, es:[bx].Font.cell_h
                mul     cx                      ;; ... * cell_h -> glyph base
                add     ax, es:[bx].Font.bits_ofs
                mov     si, ax

                mov     ax, row
                mov     cl, es:[bx].Font.rowbytes
                xor     ch, ch
                mul     cx                      ;; row * rowbytes
                add     si, ax

                mov     al, es:[bx+si]
                xor     ah, ah
                ret

@@zero:         xor     ax, ax
                ret
qglTxtRow     endp


;;::::::::::::::
;; qglTxtChar ( dst:far ptr, x:word, y:word, f:far ptr, glyph:word,
;;                col:word ) -> ax = the advance
;;
;; One glyph. Returns what it advanced, so a caller drawing a string does
;; not have to ask twice.
;;
;; The font and the destination are in different segments and there is
;; one es, so each row is fetched from the font FIRST, into a local, and
;; only then is the destination row asked for.
;;::::::::::::::
qglTxtChar    proc    public uses bx cx dx si di ds es,\
                        dst:dword, x:word, y:word, f:dword, glyph:word, col:word

                local   src_ofs:word
                local   rows:word
                local   scan:word
                local   advance:word
                local   grow:byte
                local   xres:word
                local   yres:word
                local   vis0:word               ;; first visible column
                local   visn:word               ;; how many of them
                local   whole:byte              ;; the glyph fits entirely

                les     bx, f
                mov     ax, glyph
                call    qgl$AdvOf
                mov     advance, ax

                mov     ax, glyph
                sub     ax, es:[bx].Font.first
                cmp     ax, es:[bx].Font.count
                jae     @@out                   ;; not in this font

                mov     cl, es:[bx].Font.rowbytes
                xor     ch, ch
                mul     cx                      ;; glyph * rowbytes
                mov     cl, es:[bx].Font.cell_h
                mul     cx                      ;; ... * rows
                add     ax, es:[bx].Font.bits_ofs
                mov     src_ofs, ax

                mov     cl, es:[bx].Font.cell_h
                xor     ch, ch
                mov     rows, cx
                mov     ax, y
                mov     scan, ax

                ;;
                ;; CLIP ONCE, HERE, so the row filler below never tests a
                ;; bound. A glyph at the right-hand edge would otherwise
                ;; run into the NEXT ROW of the same surface -- inside the
                ;; allocation, so nothing faults and the picture simply
                ;; grows four wrong pixels, which is the shape of bug a
                ;; guard page never catches.
                ;;
                les     bx, dst
                mov     ax, es:[bx].Surface.xRes
                mov     xres, ax
                mov     ax, es:[bx].Surface.yRes
                mov     yres, ax

                mov     ax, x                   ;; the glyph spans x..x+7
                mov     cx, ax
                add     cx, 8
                cmp     cx, 0
                jle     @@out                   ;; entirely left of it
                cmp     ax, xres
                jge     @@out                   ;; entirely right of it

                mov     whole, 1
                test    ax, ax
                jl      @F
                cmp     cx, xres
                jle     @@span
@@:             mov     whole, 0

@@span:         ;; the visible run, as a column and a count
                test    ax, ax
                jge     @F
                xor     ax, ax
@@:             mov     vis0, ax
                mov     dx, cx
                cmp     dx, xres
                jle     @F
                mov     dx, xres
@@:             sub     dx, ax
                mov     visn, dx

@@row:          cmp     rows, 0
                je      @@out

                ;; this row's eight bits, out of the font
                les     bx, f
                mov     si, src_ofs
                mov     al, es:[bx+si]
                mov     grow, al

                ;; a row off the top or bottom is not drawn at all
                mov     ax, scan
                cmp     ax, yres                ;; unsigned: a negative
                jae     @@next                  ;; scan is a huge one

                ;; and where they go. Re-derived every scanline: the
                ;; destination may be an EMS surface whose window moved.
                invoke  qglSfWrRow, dst, scan
                mov     bx, ax                  ;; 0:0 -- a surface kind
                or      bx, dx                  ;; qgl cannot address
                jz      @@next
                mov     es, dx
                mov     di, ax

                mov     dh, byte ptr col
                cmp     whole, 0
                je      @@partial

                add     di, x                   ;; the whole glyph fits
                mov     bl, grow
                shr     bl, 4                   ;; high nibble first
                call    qgl$Nib4
                mov     bl, grow
                and     bl, 0Fh
                call    qgl$Nib4
                jmp     short @@next

                ;; the edge case, one pixel at a time. Only a glyph that
                ;; straddles the border pays for it.
@@partial:      add     di, vis0
                mov     cx, visn
                mov     si, vis0
                sub     si, x                   ;; first visible bit
@@pbit:         mov     bl, grow
                mov     ax, 7
                sub     ax, si
                push    cx
                mov     cl, al
                shr     bl, cl
                pop     cx
                test    bl, 1
                jz      @F
                mov     es:[di], dh
@@:             inc     di
                inc     si
                loop    @@pbit

@@next:         les     bx, f
                mov     al, es:[bx].Font.rowbytes
                xor     ah, ah
                add     src_ofs, ax
                inc     scan
                dec     rows
                jmp     @@row

@@out:          mov     ax, advance
                ret
qglTxtChar    endp





;;::::::::::::::
;; qglTxtStr ( dst:far ptr, x:word, y:word, f:far ptr, s:far ptr,
;;               col:word )
;;::::::::::::::
qglTxtStr     proc    public uses bx cx dx si di ds es,\
                        dst:dword, x:word, y:word, f:dword, s:dword, col:word

                local   penx:word

                mov     ax, x
                mov     penx, ax

@@ch:           push    ds
                lds     si, s
                mov     al, ds:[si]
                pop     ds
                test    al, al
                jz      @F

                xor     ah, ah
                invoke  qglTxtChar, dst, penx, y, f, ax, col
                add     penx, ax
                inc     word ptr s
                jmp     @@ch
@@:             ret
qglTxtStr     endp

                

                QGL_ENDS
                end
