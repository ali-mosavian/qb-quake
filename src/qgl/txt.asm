;; txt.asm -- text from a packed 1bpp font.
;;
;; name: qgl_txt_load / qgl_txt_free / qgl_txt_char / qgl_txt_str /
;;       qgl_txt_width
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

qgl_mem_alloc   proto   far pascal :dword
qgl_mem_free    proto   far pascal :dword
qgl_sf_row      proto   far pascal :dword, :word
qgl_file_open   proto   far pascal :dword
qgl_file_size   proto   far pascal :word
qgl_file_read   proto   far pascal :word, :dword, :dword
qgl_file_close  proto   far pascal :word

FNT_HDR         equ     20              ;; mkfont.py's header IS the Font struct


.data
;; Nibble -> four bytes of 00 or FF. Four pixels a lookup, and the write
;; is (colour AND mask) OR (dst AND NOT mask) with no branch: a per-pixel
;; test-and-jump is the one thing an inner loop over text cannot afford.
qgl$nibTB       label   dword
                db      000h,000h,000h,000h     ;; 0000
                db      000h,000h,000h,0FFh     ;; 0001
                db      000h,000h,0FFh,000h     ;; 0010
                db      000h,000h,0FFh,0FFh
                db      000h,0FFh,000h,000h     ;; 0100
                db      000h,0FFh,000h,0FFh
                db      000h,0FFh,0FFh,000h
                db      000h,0FFh,0FFh,0FFh
                db      0FFh,000h,000h,000h     ;; 1000
                db      0FFh,000h,000h,0FFh
                db      0FFh,000h,0FFh,000h
                db      0FFh,000h,0FFh,0FFh
                db      0FFh,0FFh,000h,000h
                db      0FFh,0FFh,000h,0FFh
                db      0FFh,0FFh,0FFh,000h
                db      0FFh,0FFh,0FFh,0FFh     ;; 1111



.code

;;::::::::::::::
;; qgl_txt_load ( path:far ptr ) -> far ptr to the font, or 0:0
;;
;; Reads the whole file into one block: header, the advance table if it
;; has one, then the glyph bits.
;;::::::::::::::
;; NOT `uses dx`: this returns dx:ax, and the uses epilogue would pop the
;; segment straight back off over the answer. See qgl.inc's contract.
qgl_txt_load    proc    public uses bx cx si di es,\
                        path:dword

                local   fh:word
                local   fsize:dword
                local   blk:dword

                invoke  qgl_file_open, path
                test    ax, ax
                jz      @@nofile
                mov     fh, ax

                invoke  qgl_file_size, fh
                mov     word ptr fsize, ax
                mov     word ptr fsize+2, dx

                ;; a font past 64K is not a font
                cmp     word ptr fsize+2, 0
                jne     @@closefail
                cmp     word ptr fsize, FNT_HDR
                jbe     @@closefail

                invoke  qgl_mem_alloc, fsize
                mov     word ptr blk, ax
                mov     word ptr blk+2, dx
                or      ax, dx
                jz      @@closefail

                invoke  qgl_file_read, fh, blk, fsize
                cmp     ax, word ptr fsize
                jne     @@freefail
                invoke  qgl_file_close, fh

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

@@freefail2:    invoke  qgl_mem_free, blk
                jmp     @@nofile
@@freefail:     invoke  qgl_mem_free, blk
@@closefail:    invoke  qgl_file_close, fh
@@nofile:       xor     ax, ax
                xor     dx, dx
                ret
qgl_txt_load    endp


;;::::::::::::::
;; qgl_txt_free ( f:far ptr )
;;::::::::::::::
qgl_txt_free    proc    public,\
                        f:dword
                invoke  qgl_mem_free, f
                ret
qgl_txt_free    endp


;;::::::::::::::
;; qgl$adv_of -- how far this glyph moves the pen.
;;
;; INTERNAL: es:bx -> the font, al = the character. ax back, everything
;; else preserved.
;;::::::::::::::
qgl$adv_of      proc    near private uses si
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
qgl$adv_of      endp


;;::::::::::::::
;; qgl_txt_width ( f:far ptr, s:far ptr ) -> ax = pixels
;;
;; Walks the advances rather than multiplying by a cell size, so it is
;; still right when the font is proportional. draw_string_r needs this to
;; right-align without assuming anything about the glyphs.
;;::::::::::::::
qgl_txt_width   proc    public uses bx cx dx si di ds es,\
                        f:dword, s:dword

                les     bx, f
                lds     si, s
                xor     di, di                  ;; running width
                cld
@@ch:           lodsb
                test    al, al
                jz      @F
                call    qgl$adv_of
                add     di, ax
                jmp     @@ch
@@:             mov     ax, di
                ret
qgl_txt_width   endp


;;::::::::::::::
;; qgl_txt_char ( dst:far ptr, x:word, y:word, f:far ptr, glyph:word,
;;                col:word ) -> ax = the advance
;;
;; One glyph. Returns what it advanced, so a caller drawing a string does
;; not have to ask twice.
;;
;; The font and the destination are in different segments and there is
;; one es, so each row is fetched from the font FIRST, into a local, and
;; only then is the destination row asked for.
;;::::::::::::::
qgl_txt_char    proc    public uses bx cx dx si di ds es,\
                        dst:dword, x:word, y:word, f:dword, glyph:word, col:word

                local   src_ofs:word
                local   rows:word
                local   scan:word
                local   advance:word
                local   grow:byte

                les     bx, f
                mov     ax, glyph
                call    qgl$adv_of
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

@@row:          cmp     rows, 0
                je      @@out

                ;; this row's eight bits, out of the font
                les     bx, f
                mov     si, src_ofs
                mov     al, es:[bx+si]
                mov     grow, al

                ;; and where they go. Re-derived every scanline: the
                ;; destination may be an EMS surface whose window moved.
                invoke  qgl_sf_row, dst, scan
                mov     es, dx
                mov     di, ax
                add     di, x

                mov     dh, byte ptr col
                mov     bl, grow
                shr     bl, 4                   ;; high nibble first
                call    qgl$nib4
                mov     bl, grow
                and     bl, 0Fh
                call    qgl$nib4

                les     bx, f
                mov     al, es:[bx].Font.rowbytes
                xor     ah, ah
                add     src_ofs, ax
                inc     scan
                dec     rows
                jmp     @@row

@@out:          mov     ax, advance
                ret
qgl_txt_char    endp


;;::::::::::::::
;; qgl$nib4 -- four pixels from one nibble, no branch per pixel.
;;
;; INTERNAL: bl = the nibble, es:di -> the destination, col on the stack
;; frame of the caller is NOT reachable, so the colour arrives in dh.
;; di advances by four. Everything else survives.
;;::::::::::::::
qgl$nib4        proc    near private uses ax bx cx si
                xor     bh, bh
                shl     bx, 2                   ;; four bytes an entry
                mov     si, offset qgl$nibTB
                add     si, bx
                mov     cx, 4
@@px:           mov     al, ds:[si]             ;; 00 or FF
                mov     ah, al
                not     ah
                and     al, dh                  ;; colour where lit
                and     ah, es:[di]             ;; keep dst where clear
                or      al, ah
                mov     es:[di], al
                inc     si
                inc     di
                loop    @@px
                ret
qgl$nib4        endp


;;::::::::::::::
;; qgl_txt_str ( dst:far ptr, x:word, y:word, f:far ptr, s:far ptr,
;;               col:word )
;;::::::::::::::
qgl_txt_str     proc    public uses bx cx dx si di ds es,\
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
                invoke  qgl_txt_char, dst, penx, y, f, ax, col
                add     penx, ax
                inc     word ptr s
                jmp     @@ch
@@:             ret
qgl_txt_str     endp

                end
