;; t24zpage -- the RENDERER'S depth shape, which t20zems does not have.
;;
;; t20zems draws a 32x32 square over a 64x64 depth buffer: 128 bytes a
;; row, 8K in all, ONE EMS page. The renderer's is 160x100 -- 320 bytes a
;; row, padded to 512 so a row cannot straddle a page, 51,200 bytes, FOUR
;; pages -- and its texture is a view onto a multi-megabyte EMS surface
;; cache, not a one-page surface of its own. Between one face and the
;; next the surface builder writes through the same write window the
;; depth rows come through.
;;
;; Written chasing a renderer frame of slanted texture stripes that
;; appeared only with depth on. It passed from the first run: the
;; stripes were d_faces.c reading BASIC arrays through pointers the far
;; heap had moved out from under them, and depth only changed where the
;; compaction landed. It stays because nothing else draws depth over
;; four pages from a view aimed mid-page, and it reads back every byte
;; the draw could have touched: the destination, the whole texture
;; parent, and one row of each depth page.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglSfInit     proto   far
qglSfNew      proto   far :word, :word, :word
qglSfViewNew  proto   far :dword, :word, :word, :word
qglSfViewAim  proto   far :dword, :dword
qglSfRow      proto   far :dword, :word
qglSfPget     proto   far :dword, :word, :word
qglDrFill     proto   far :dword, :word, :word, :word, :word, :word
qglClRect     proto   far :word, :word, :word, :word
qglRsPoly     proto   far :dword, :dword, :word, :word, :dword
qglSfZMode    proto   far :dword, :word
qglSfZNew     proto   far :dword, :word
qglSfZClear   proto   far :dword, :word
qglZScale     proto   far :dword

SFW             equ     160
SFH             equ     100
TEXW            equ     256                     ;; the "surface cache": 8 pages
TEXH            equ     512
VIEW            equ     64
VIEW_OFS        equ     (2 * 4000h + 3000h)     ;; page 2, and NOT at its start:
                                                ;; a surface-cache block never is
VIEWCOL         equ     100                     ;; the view's own colour; the
                                                ;; parent around it stays TEXCOL
PX0             equ     4
PY0             equ     4
PX1             equ     156
PY1             equ     96
TEXCOL          equ     99
BGCOL           equ     0

.data
n_zb            db      'ems depth, 4 pages     $'
n_zbps          db      'stride padded to 512   $'
n_lines         db      'polygon covers 92 lines$'
n_inside        db      'view colour inside     $'
n_stray         db      'no read outside view   $'
n_outside       db      'nothing outside        $'
n_texkeep       db      'texture bytes untouched$'
n_texdiff       db      'every texel as filled  $'
n_z0            db      'depth row 4   (page 0) $'
n_z1            db      'depth row 40  (page 1) $'
n_z2            db      'depth row 70  (page 2) $'
n_z3            db      'depth row 95  (page 2) $'
n_zclr          db      'row 2 still clear      $'
n_test          db      'nearer depth blocks all$'

;; z constant: the renderer's models are not, but a wrong PAGE does not
;; depend on the value written into it
poly            QVert   <4.0,   4.0,  1.0, 0.0, 0.0>
                QVert   <156.0, 4.0,  1.0, 1.0, 0.0>
                QVert   <156.0, 96.0, 1.0, 1.0, 1.0>
                QVert   <4.0,   96.0, 1.0, 0.0, 1.0>
polyp           dd      0

zs              real4   100.0

dst             dd      0
zb              dd      0
tex             dd      0                       ;; the big EMS parent
vw              dd      0                       ;; the view drawn from
sb              dd      0                       ;; stands in for a build
sum0            dd      0
sum1            dd      0
hits            dw      0
dcnt            dw      0
drow            dw      -1
dcol            dw      -1
dval            dw      -1

.code

;; pixels of dst equal to val, inside [PX0,PX1)x[PY0,PY1) -> ax, and
;; outside it -> hits (the caller reads whichever it wants)
scan            proc    near private uses bx cx dx si di es,\
                        val:word

                local   inside:word
                mov     inside, 0
                mov     hits, 0
                xor     si, si
@@row:          cmp     si, SFH
                jae     @@out
                invoke  qglSfRow, dst, si
                mov     di, ax
                mov     es, dx
                xor     bx, bx
@@px:           cmp     bx, SFW
                jae     @@nextrow
                mov     al, es:[di]
                xor     ah, ah
                cmp     ax, val
                jne     @@next
                cmp     si, PY0
                jb      @@outside
                cmp     si, PY1
                jae     @@outside
                cmp     bx, PX0
                jb      @@outside
                cmp     bx, PX1
                jae     @@outside
                inc     inside
                jmp     @@next
@@outside:      inc     hits
@@next:         inc     di
                inc     bx
                jmp     @@px
@@nextrow:      inc     si
                jmp     @@row
@@out:          mov     ax, inside
                ret
scan            endp

;; sum of every byte of the big texture surface -> eax. Read a row at a
;; time through its own accessor, so every page of it gets mapped.
texsum          proc    near private uses bx cx dx si di es

                xor     ebx, ebx
                xor     si, si
@@row:          cmp     si, TEXH
                jae     @@out
                invoke  qglSfRow, tex, si
                mov     di, ax
                mov     es, dx
                mov     cx, TEXW
@@px:           movzx   eax, B es:[di]
                add     ebx, eax
                inc     di
                loop    @@px
                inc     si
                jmp     @@row
@@out:          mov     eax, ebx
                ret
texsum          endp

;; every texture byte against what the two fills left: VIEWCOL where the
;; view is (bytes B000h..BFFFh of the parent = rows 176..191), TEXCOL
;; elsewhere. Records the first stray and counts them all.
texdiff         proc    near private uses bx cx dx si di es
                xor     si, si
@@row:          cmp     si, TEXH
                jae     @@out
                invoke  qglSfRow, tex, si
                mov     di, ax
                mov     es, dx
                mov     cx, TEXW
                xor     bx, bx
@@px:           mov     dl, TEXCOL
                cmp     si, VIEW_OFS / TEXW
                jb      @F
                cmp     si, (VIEW_OFS + VIEW*VIEW) / TEXW
                jae     @F
                mov     dl, VIEWCOL
@@:             cmp     es:[di], dl
                je      @@next
                inc     dcnt
                cmp     drow, -1
                jne     @@next
                mov     drow, si
                mov     dcol, bx
                movzx   ax, B es:[di]
                mov     dval, ax
@@next:         inc     di
                inc     bx
                loop    @@px
                inc     si
                jmp     @@row
@@out:          ret
texdiff         endp

;; the depth word at (80, row) -> ax
zat             proc    near private uses bx dx di es,\
                        row:word
                invoke  qglSfRow, zb, row
                mov     di, ax
                mov     es, dx
                mov     ax, es:[di+160]         ;; x = 80, two bytes a pixel
                ret
zat             endp

;; What the renderer does between two faces: build a surface. The build
;; writes through EMS_WRITEPAGE and reads through EMS_READPAGE, so after
;; it neither window holds what the last polygon left there.
build           proc    near private uses ax
                invoke  qglDrFill, sb, 0, 0, 127, 127, 7
                invoke  qglSfPget, sb, 3, 3
                ret
build           endp


tmain           proc    far public uses bx cx dx si di es

                invoke  qglSfInit

                invoke  qglSfNew, SFW, SFH, SURF_CMEM
                SAVEP   dst
                invoke  qglSfNew, TEXW, TEXH, SURF_EMS
                SAVEP   tex
                invoke  qglSfViewNew, tex, VIEW, VIEW, VIEW
                SAVEP   vw
                invoke  qglSfViewAim, vw, VIEW_OFS
                invoke  qglSfNew, 128, 128, SURF_EMS
                SAVEP   sb

                mov     word ptr polyp, offset poly
                mov     word ptr polyp+2, ds

                invoke  qglClRect, 0, 0, SFW-1, SFH-1

                ;;
                ;; 1. the depth buffer, and its shape
                ;;
                invoke  qglSfZNew, dst, SURF_EMS
                SAVEP   zb
                mov     ax, word ptr zb
                or      ax, word ptr zb+2
                NZ      ax
                CHK     n_zb, ax, 1
                les     bx, zb
                CHK     n_zbps, es:[bx].Surface.bps, 512
                invoke  qglZScale, dword ptr zs

                ;;
                ;; 2. one textured polygon over all four pages, SET mode,
                ;;    with a build before it -- then where did the bytes go?
                ;;
                invoke  qglDrFill, tex, 0, 0, TEXW-1, TEXH-1, TEXCOL
                invoke  qglDrFill, vw, 0, 0, VIEW-1, VIEW-1, VIEWCOL
                call    texsum
                mov     sum0, eax

                invoke  qglSfZClear, dst, 0
                invoke  qglDrFill, dst, 0, 0, SFW-1, SFH-1, BGCOL
                call    build
                invoke  qglSfZMode, dst, QGL_Z_SET
                invoke  qglRsPoly, dst, polyp, 4, QGL_M_PTEX, vw
                CHK     n_lines, ax, PY1-PY0

                invoke  scan, VIEWCOL
                CHK     n_inside, ax, (PX1-PX0)*(PY1-PY0)
                mov     ax, hits
                CHK     n_outside, ax, 0
                invoke  scan, TEXCOL                    ;; a texel from OUTSIDE the view
                CHK     n_stray, ax, 0

                call    texsum
                mov     sum1, eax
                cmp     eax, sum0
                mov     ax, 0
                setne   al                      ;; 0 = unchanged
                CHK     n_texkeep, ax, 0
                call    texdiff
                mov     ax, dcnt
                CHK     n_texdiff, ax, 0

                invoke  zat, 4
                CHK     n_z0, ax, 100
                invoke  zat, 40
                CHK     n_z1, ax, 100
                invoke  zat, 70
                CHK     n_z2, ax, 100
                invoke  zat, 95
                CHK     n_z3, ax, 100
                invoke  zat, 2
                CHK     n_zclr, ax, 0

                ;;
                ;; 3. and the test reads the same pages it wrote
                ;;
                invoke  qglSfZClear, dst, 200
                invoke  qglDrFill, dst, 0, 0, SFW-1, SFH-1, BGCOL
                call    build
                invoke  qglSfZMode, dst, QGL_Z_TEST
                invoke  qglRsPoly, dst, polyp, 4, QGL_M_PTEX, vw
                invoke  scan, VIEWCOL
                CHK     n_test, ax, 0

                ret
tmain           endp
                end
