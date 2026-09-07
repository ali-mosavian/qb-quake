;; t18txtrow -- qglTxtRow against the already-proven glyph draw.
;;
;; No hand-derived bitmap: b03font.asm already established that
;; qglTxtChar draws the real glyph bits. So the oracle here is that
;; draw, not a transcribed pattern -- 'A' is rendered once through
;; qglTxtChar into a small surface, and qglTxtRow's bits are checked
;; against every pixel qglSfPget reads back from that same drawing.
;; Two independently-walked views of the same glyph have to agree.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglTxtLoad    proto   far :dword
qglTxtFree    proto   far :dword
qglTxtRow     proto   far :dword, :word, :word
qglTxtChar    proto   far :dword, :word, :word, :dword, :word, :word
qglDrFill     proto   far :dword, :word, :word, :word, :word, :word

GLYPH           equ     41h             ;; 'A'
FG              equ     1
BG              equ     0

.data
n_init          db      'qglSfInit            $'
n_font          db      'the font loads         $'
n_bit           db      'row bit matches the draw$'
n_oob_glyph     db      'a glyph past the font is blank$'
n_oob_row       db      'a row past the cell is blank$'

fname           db      'font.fnt',0
fpath           dd      0
f               dd      0
sf              dd      0

.code

tmain           proc    far public uses bx cx dx si di es

                local   row:word
                local   col:word
                local   bits:word
                local   mism:word
                local   expect:word

                invoke  qglSfInit
                CHK     n_init, ax, 1

                mov     word ptr fpath, offset fname
                mov     word ptr fpath+2, ds
                invoke  qglTxtLoad, fpath
                SAVEP   f
                mov     ax, word ptr f+2
                NZ      ax
                CHK     n_font, ax, 1

                invoke  qglSfNew, 8, 8, SURF_CMEM, 0
                SAVEP   sf

                invoke  qglDrFill, sf, 0, 0, 7, 7, BG
                invoke  qglTxtChar, sf, 0, 0, f, GLYPH, FG

                mov     mism, 0
                mov     row, 0
@@rowloop:      mov     ax, row
                invoke  qglTxtRow, f, GLYPH, ax
                mov     bits, ax

                mov     col, 0
@@colloop:      invoke  qglSfPget, sf, col, row
                mov     dx, ax                  ;; dx = the pixel qglSfPget got

                ;; expected = (bits >> (7-col)) and 1
                mov     ax, 7
                sub     ax, col
                mov     cl, al                  ;; cl = shift count, the
                                                 ;; only variable-count reg
                mov     ax, bits
                shr     ax, cl
                and     ax, 1
                mov     expect, ax

                cmp     dx, expect
                je      @@colok
                inc     mism
@@colok:        inc     col
                cmp     col, 8
                jb      @@colloop

                inc     row
                cmp     row, 8
                jb      @@rowloop

                mov     ax, mism
                CHK     n_bit, ax, 0

                invoke  qglTxtRow, f, 0FFh, 0
                CHK     n_oob_glyph, ax, 0

                invoke  qglTxtRow, f, GLYPH, 99
                CHK     n_oob_row, ax, 0

                invoke  qglSfFree, sf
                invoke  qglTxtFree, f
                ret
tmain           endp
                end
