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

SURF_W          equ     64
SURF_H          equ     16
BG              equ     11              ;; what an unlit bit must leave
FG              equ     47

.data
n_load          db      'font loaded            $'
n_cell          db      'cell is 8x8            $'
n_count         db      'has 256 glyphs         $'
n_adv           db      'default advance is 4   $'
n_width         db      'width of "AB" is 8     $'
n_pixels        db      'every pixel matches    $'
n_bg            db      'clear bits left bg     $'
n_badfile       db      'missing file returns 0 $'
n_ptr           db      'DBG font ptr           $'
n_hdr           db      'DBG first header dword $'
n_open          db      'DBG direct open ax     $'
n_cf            db      'DBG direct open CF     $'
n_sz            db      'DBG seek-end size      $'

fname           db      "font.fnt",0
badname         db      "nope.fnt",0
str_ab          db      "AB",0

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
tmain           proc    far public uses bx cx dx si di es

                invoke  qglSfInit

                mov     word ptr fnp, offset fname
                mov     word ptr fnp+2, ds
                mov     word ptr bnp, offset badname
                mov     word ptr bnp+2, ds
                mov     word ptr strp, offset str_ab
                mov     word ptr strp+2, ds

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
                invoke  qglSfNew, SURF_W, SURF_H, SURF_CMEM, 0
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
