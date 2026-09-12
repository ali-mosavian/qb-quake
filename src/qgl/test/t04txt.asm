;; t04txt -- the packed font: load it, draw with it, read the pixels back.
;;
;; The check that matters is the last one. Drawing text and eyeballing it
;; proves the glyph is SOME shape; comparing every pixel against the
;; font's own bits proves it is THE shape, in the right place, in the
;; right colour, and that a clear bit left the destination alone. That
;; last part is the whole of masked drawing and the easiest to get wrong
;; in a way that looks fine on screen.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglTxtLoad    proto   far :dword
qglTxtFree    proto   far :dword
qglTxtChar    proto   far :dword, :word, :word, :dword, :word, :word
qglTxtStr     proto   far :dword, :word, :word, :dword, :dword, :word
qglTxtWidth   proto   far :dword, :dword
qglDrFill     proto   far :dword, :word, :word, :word, :word, :word

SURF_W          equ     128
SURF_H          equ     16
BG              equ     11              ;; what an unlit bit must leave
FG              equ     47
STRW            equ     128             ;; the HUD-string canvas
STRH            equ     8

.data
n_load          db      'font loaded            $'
n_cell          db      'cell is 8x8            $'
n_count         db      'has 256 glyphs         $'
n_adv           db      'default advance is 4   $'
n_width         db      'width of "AB" is 8     $'
n_pixels        db      'every pixel matches    $'
n_bg            db      'clear bits left bg     $'
n_badfile       db      'missing file returns 0 $'
n_sweep         db      'each glyph at each x   $'
n_str           db      'a whole HUD line       $'
n_dead          db      'dead kind: no row ptr  $'
n_intact        db      'dead kind: font intact $'
n_swbad         db      'DBG sweep char<<16|x   $'
n_stbad         db      'DBG string y<<16|x     $'
n_ptr           db      'DBG font ptr           $'
n_hdr           db      'DBG first header dword $'
n_open          db      'DBG direct open ax     $'
n_cf            db      'DBG direct open CF     $'
n_sz            db      'DBG seek-end size      $'

fname           db      "font.fnt",0
badname         db      "nope.fnt",0
str_ab          db      "AB",0

;; The real overlay line, not a synthetic one: this is what came out as
;; `-|| 232 -16 1|| -y|| 151` on screen.
msg             db      "-at 232 -16 184 -yaw 151",0
expct           db      STRW*STRH dup(0)

swch            dw      0
swx             dw      0
swy             dw      0
swcol           dw      0
swwrong         dw      0
swbad           dd      0FFFFFFFFh
strpos          dw      0
strch           dw      0
strwrong        dw      0
stbad           dd      0FFFFFFFFh

msgp            dd      0
fsnap           db      256*8 dup (0)   ;; the glyph bits before the draw
fwrong          dw      0

fp              dd      0
sp_             dd      0
fnp             dd      0
bnp             dd      0
strp            dd      0
lit             dw      0
wrong           dw      0
gbits           db      0       ;; the row's bits, out of dx's way
dbgw            dd      0

.code

;;::::::::::::::
;; fbits -- one row of one glyph, straight out of the loaded file.
;;
;; INTERNAL: bx = the character, cx = the row -> al = the bits. The
;; reference the drawing is checked against, so it reads the font by
;; hand rather than through qglTxtRow.
;;::::::::::::::
fbits           proc    near private uses bx cx dx si di es
                les     di, fp
                mov     ax, bx
                sub     ax, es:[di].Font.first
                mov     dl, es:[di].Font.rowbytes
                xor     dh, dh
                mul     dx
                mov     dl, es:[di].Font.cell_h
                xor     dh, dh
                mul     dx
                add     ax, es:[di].Font.bits_ofs
                add     ax, cx                  ;; rowbytes is 1
                add     di, ax
                mov     al, es:[di]
                ret
fbits           endp


tmain           proc    far public uses bx cx dx si di es

                invoke  qglSfInit

                mov     word ptr fnp, offset fname
                mov     word ptr fnp+2, ds
                mov     word ptr bnp, offset badname
                mov     word ptr bnp+2, ds
                mov     word ptr strp, offset str_ab
                mov     word ptr strp+2, ds
                mov     word ptr msgp, offset msg
                mov     word ptr msgp+2, ds

                ;;
                ;; load
                ;;
                invoke  qglTxtLoad, fnp
                SAVEP   fp
                mov     bx, dx
                or      bx, ax
                NZ      bx
                CHK     n_load, ax, 1

                les     bx, fp
                xor     ax, ax
                mov     al, es:[bx].Font.cell_w
                mov     cx, ax
                xor     ax, ax
                mov     al, es:[bx].Font.cell_h
                add     ax, cx
                CHK     n_cell, ax, 16          ;; 8 + 8

                CHK     n_count, es:[bx].Font.count, 256

                xor     ax, ax
                mov     al, es:[bx].Font.adv
                CHK     n_adv, ax, 4

                invoke  qglTxtWidth, fp, strp
                CHK     n_width, ax, 8

                ;;
                ;; draw one glyph onto a known background
                ;;
                invoke  qglSfNew, SURF_W, SURF_H, SURF_CMEM
                SAVEP   sp_
                invoke  qglDrFill, sp_, 0, 0, SURF_W-1, SURF_H-1, BG

                invoke  qglTxtChar, sp_, 0, 0, fp, 'A', FG

                ;;
                ;; and compare every pixel of the 8x8 cell against the
                ;; font's own bits: lit -> FG, clear -> still BG
                ;;
                mov     lit, 0
                mov     wrong, 0
                xor     si, si                  ;; row
@@row:          cmp     si, 8
                jae     @@rows_done

                ;; the row's bits, out of the font
                les     bx, fp
                mov     ax, 'A'
                sub     ax, es:[bx].Font.first
                mov     cl, es:[bx].Font.cell_h
                xor     ch, ch
                mul     cx
                add     ax, si
                add     ax, es:[bx].Font.bits_ofs
                mov     di, ax
                mov     al, es:[bx+di]
                mov     gbits, al               ;; NOT dl: qglSfPget
                                                ;; returns through qgl$Row,
                                                ;; which writes dx

                xor     di, di                  ;; column
@@col:          cmp     di, 8
                jae     @@cols_done

                invoke  qglSfPget, sp_, di, si
                mov     dh, al                  ;; what is on the surface

                ;; was this bit set?
                mov     cx, 7
                sub     cx, di
                mov     al, gbits
                shr     al, cl
                test    al, 1
                jz      @@clear

                inc     lit
                cmp     dh, FG
                je      @@next
                inc     wrong
                jmp     @@next

@@clear:        cmp     dh, BG
                je      @@next
                inc     wrong

@@next:         inc     di
                jmp     @@col
@@cols_done:    inc     si
                jmp     @@row

@@rows_done:    CHK     n_pixels, wrong, 0

                ;; and the glyph really had ink, or the comparison above
                ;; passed by drawing nothing at all
                mov     ax, lit
                NZ      ax
                CHK     n_bg, ax, 1

                ;;
                ;; SWEEP: every printable glyph at every x in one cell's
                ;; worth of offsets. One glyph per pass on a clean
                ;; background, so a failure names a (char, x) pair and
                ;; separates a character-dependent fault from a
                ;; position-dependent one. Drawing 'A' at 0,0 -- all this
                ;; test used to do -- is one point of 760.
                ;;
                mov     swwrong, 0
                mov     swch, 32
@@swch:         cmp     swch, 127
                jae     @@swdone
                mov     swx, 0
@@swx:          cmp     swx, 8
                jae     @@swchnext

                invoke  qglDrFill, sp_, 0, 0, SURF_W-1, SURF_H-1, BG
                invoke  qglTxtChar, sp_, swx, 0, fp, swch, FG

                mov     swy, 0
@@swy:          cmp     swy, 8
                jae     @@swxnext
                mov     bx, swch
                mov     cx, swy
                call    fbits
                mov     gbits, al

                mov     swcol, 0
@@swc:          cmp     swcol, 8
                jae     @@swynext
                mov     ax, swx
                add     ax, swcol
                invoke  qglSfPget, sp_, ax, swy
                mov     dh, al                  ;; what is on the surface

                mov     cx, 7
                sub     cx, swcol
                mov     al, gbits
                shr     al, cl
                test    al, 1
                jz      @@swclear
                cmp     dh, FG
                je      @@swcnext
                jmp     short @@swwrong
@@swclear:      cmp     dh, BG
                je      @@swcnext
@@swwrong:      inc     swwrong
                cmp     word ptr swbad+2, 0FFFFh
                jne     @@swcnext
                mov     ax, swx
                mov     word ptr swbad, ax
                mov     ax, swch
                mov     word ptr swbad+2, ax
@@swcnext:      inc     swcol
                jmp     @@swc
@@swynext:      inc     swy
                jmp     @@swy
@@swxnext:      inc     swx
                jmp     @@swx
@@swchnext:     inc     swch
                jmp     @@swch

@@swdone:       cmp     swwrong, 0
                je      @F
                invoke  tshow, offset n_swbad, swbad
@@:             CHK     n_sweep, swwrong, 0

                ;;
                ;; And the symptom itself: a whole overlay line, drawn
                ;; the way draw_string draws it -- one qglTxtChar a
                ;; character, pen stepped by the font's fixed advance --
                ;; against a reference composed from the font's own bits.
                ;; Per-glyph correctness does not cover what one glyph
                ;; does to the one beside it.
                ;;
                push    es                      ;; expct <- BG
                mov     ax, ds
                mov     es, ax
                mov     di, offset expct
                mov     cx, STRW*STRH
                mov     al, BG
                cld
                rep     stosb
                pop     es

                mov     strpos, 0
@@ec:           mov     si, offset msg
                add     si, strpos
                mov     al, [si]
                test    al, al
                jz      @@edone
                xor     ah, ah
                mov     strch, ax

                mov     swy, 0
@@ey:           cmp     swy, 8
                jae     @@ecnext
                mov     bx, strch
                mov     cx, swy
                call    fbits
                mov     gbits, al

                mov     swcol, 0
@@ex:           cmp     swcol, 8
                jae     @@eynext
                mov     cl, 7
                sub     cl, byte ptr swcol
                mov     al, gbits
                shr     al, cl
                test    al, 1
                jz      @@exnext
                mov     ax, swy
                shl     ax, 7                   ;; * STRW
                mov     di, ax
                mov     ax, strpos
                shl     ax, 2                   ;; the pen steps by 4
                add     di, ax
                add     di, swcol
                mov     expct[di], FG
@@exnext:       inc     swcol
                jmp     @@ex
@@eynext:       inc     swy
                jmp     @@ey
@@ecnext:       inc     strpos
                jmp     @@ec

@@edone:        invoke  qglDrFill, sp_, 0, 0, SURF_W-1, SURF_H-1, BG
                mov     strpos, 0
@@dr:           mov     si, offset msg
                add     si, strpos
                mov     al, [si]
                test    al, al
                jz      @@drdone
                xor     ah, ah
                mov     strch, ax
                mov     ax, strpos
                shl     ax, 2
                invoke  qglTxtChar, sp_, ax, 0, fp, strch, FG
                inc     strpos
                jmp     @@dr

@@drdone:       mov     strwrong, 0
                mov     swy, 0
@@cy:           cmp     swy, STRH
                jae     @@cdone
                mov     swx, 0
@@cx:           cmp     swx, STRW
                jae     @@cynext
                invoke  qglSfPget, sp_, swx, swy
                mov     dh, al
                mov     di, swy
                shl     di, 7
                add     di, swx
                cmp     dh, expct[di]
                je      @@cxnext
                inc     strwrong
                cmp     word ptr stbad+2, 0FFFFh
                jne     @@cxnext
                mov     ax, swx
                mov     word ptr stbad, ax
                mov     ax, swy
                mov     word ptr stbad+2, ax
@@cxnext:       inc     swx
                jmp     @@cx
@@cynext:       inc     swy
                jmp     @@cy

@@cdone:        cmp     strwrong, 0
                je      @F
                invoke  tshow, offset n_stbad, stbad
@@:             CHK     n_str, strwrong, 0

                ;;
                ;; A KIND qgl CANNOT ADDRESS MUST NOT BE DRAWN ON.
                ;;
                ;; Dispatch slot 1 is mgl's banked back-end, which qgl
                ;; leaves dead -- and the loading screen's DC is exactly
                ;; that kind. qglSfAccessWr threw the dead entry's failure
                ;; away and returned the CALLER's es, which inside
                ;; qglTxtChar is the FONT's own segment two instructions
                ;; earlier. So every glyph row of the loading screen was
                ;; written into the font block at scan*4 + x, and the HUD
                ;; afterwards drew whatever the font had become: 'a', '8'
                ;; and 'F' came out as solid 0xFE cells.
                ;;
                mov     strpos, 0
@@snap:         cmp     strpos, 256
                jae     @@snapped
                mov     swy, 0
@@snapy:        cmp     swy, 8
                jae     @@snapnext
                mov     bx, strpos
                mov     cx, swy
                call    fbits
                mov     di, strpos
                shl     di, 3
                add     di, swy
                mov     fsnap[di], al
                inc     swy
                jmp     @@snapy
@@snapnext:     inc     strpos
                jmp     @@snap

@@snapped:      les     bx, sp_                 ;; make it the dead kind
                mov     es:[bx].Surface.typ, 1 * (T SurfaceOps)

                invoke  qglSfWrRow, sp_, 0
                or      ax, dx
                CHK     n_dead, ax, 0

                invoke  qglTxtStr, sp_, 0, 0, fp, msgp, FG

                les     bx, sp_
                mov     es:[bx].Surface.typ, SF_MEM

                mov     fwrong, 0
                mov     strpos, 0
@@vf:           cmp     strpos, 256
                jae     @@vfdone
                mov     swy, 0
@@vfy:          cmp     swy, 8
                jae     @@vfnext
                mov     bx, strpos
                mov     cx, swy
                call    fbits
                mov     di, strpos
                shl     di, 3
                add     di, swy
                cmp     al, fsnap[di]
                je      @F
                inc     fwrong
@@:             inc     swy
                jmp     @@vfy
@@vfnext:       inc     strpos
                jmp     @@vf

@@vfdone:       CHK     n_intact, fwrong, 0

                ;;
                ;; a path that is not there fails rather than faulting
                ;;
                invoke  qglTxtLoad, bnp
                mov     bx, dx
                or      bx, ax
                NZ      bx
                CHK     n_badfile, ax, 0

                invoke  qglSfFree, sp_
                invoke  qglTxtFree, fp
                ret
tmain           endp
                end
