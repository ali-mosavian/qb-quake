;; b03font -- the two font paths qrender actually uses.
;;
;; qgl draws the packed 1bpp font directly. The mgl arm reproduces
;; screen.bas: 256 8x8 EMS DCs, one uglPutMsk per character. The rendered
;; buffers must agree before timing. Conventional and EMS availability are
;; sampled around both representations; the static handle-table bytes are
;; reported separately because they are part of the BASIC program image.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglTxtLoad    proto   far :dword
qglTxtWidth   proto   far :dword, :dword
qglFileOpen   proto   far :dword
qglFileSize   proto   far :word
qglFileClose  proto   far :word
qglTxtFree    proto   far :dword
qglTxtStr     proto   far :dword, :word, :word, :dword, :dword, :word
qglDrFill     proto   far :dword, :word, :word, :word, :word, :word
qglMemAvail   proto   far :word
qglSfAdoptDc proto   far :dword, :dword

uglInit         proto   far
uglEnd          proto   far
uglNew          proto   far :word, :word, :word, :word
uglDel          proto   far :dword
uglNewMult      proto   far :word, :word, :word, :word, :word, :word
uglDelMult      proto   far :word
uglPSet         proto   far :dword, :word, :word, :dword
uglPutMsk       proto   far :dword, :word, :word, :dword
emsAvail        proto   far

DC_MEM          equ     0
DC_EMS          equ     128             ;; 2 * MGL's 64-byte DC type stride
FMT_8BIT        equ     0
WID             equ     160
HGT             equ     32
BYTES           equ     WID * HGT
FG              equ     47
BG              equ     11
MASK8           equ     0E3h
CHARS           equ     21
LOOPS           equ     8000
ROUNDS          equ     6

.data
                public  glyph_desc
n_init          db      'mgl initialized       $'
n_font          db      'packed font loaded    $'
n_mult          db      '256 mgl glyph DCs made$'
n_same          db      'font output identical $'
n_c0            db      'conv baseline bytes   $'
n_cq            db      'conv after qgl font   $'
n_cm            db      'conv after mgl glyphs $'
n_e0            db      'EMS baseline bytes    $'
n_eq            db      'EMS after qgl font    $'
n_em            db      'EMS after mgl glyphs  $'
n_qh            db      'qgl static handle byte$'
n_mh            db      'mgl static handle byte$'
n_qt            db      'font qgl ticks        $'
n_mt            db      'font mgl ticks        $'
n_qok           db      'text qgl vs oracle    $'
n_mok           db      'text mgl vs oracle    $'
n_magic         db      'font magic FNT1       $'
n_fsize         db      'font file is 2068     $'
n_cw            db      'cell_w 8              $'
n_chh           db      'cell_h 8              $'
n_rb            db      'rowbytes 1            $'
n_first         db      'first codepoint 0     $'
n_count         db      'count 256             $'
n_bofs          db      'bits_ofs 20           $'
n_adv           db      'advance 4             $'
n_aofs          db      'adv_ofs 0 (fixed)     $'
n_width         db      'txt_width is 84       $'
n_pitch         db      'dst pitch (adopted)   $'
n_cfont         db      'conv: packed font     $'
n_cmgl          db      'conv: mgl dynamic     $'
n_emgl          db      'EMS: mgl glyph pixels $'
n_cfree         db      'conv after all freed  $'
n_efree         db      'EMS after all freed   $'
n_qstat         db      'qgl caller static 4   $'
n_mstat         db      'mgl caller static 1042$'

;; The oracle's own constants, deliberately duplicated from the call
;; sites: a mutation that moves an arm's operand must not move the
;; expected image with it.
OR_X            equ     2
OR_Y            equ     2
OR_FIRST        equ     0
OR_CELLH        equ     8
OR_ROWB         equ     1
OR_BITS         equ     20
OR_ADV          equ     4
OR_WIDTH        equ     84                      ;; 21 glyphs x 4
MUT_X           equ     11                      ;; lit on the final image
MUT_Y           equ     4                       ;; (11,5) is background
FSIZE           equ     2068
n_duration      db      'duration >= 20 ticks  $'

fname           db      'font.fnt',0
textv           db      'FPS 60 powered by uGL',0
fpath           dd      0
textp           dd      0
fontp           dd      0
dc              dd      0
qptr            dd      0
qsurf           Surface <>

;; Only farptr is consumed by uglNewMult/uglDelMult. The remaining words
;; make this a real VBDOS BASARRAY descriptor instead of relying on stack
;; garbage after the pointer.
glyph_desc      dd      0
                dw      0, 0
                db      1, 64
                dw      0, 4, 256, 0
glyphs          dd      256 dup (0)
snap            db      BYTES dup (0)
expect          db      BYTES dup (0)           ;; the oracle image
qsamp           dd      ROUNDS dup (0)
msamp           dd      ROUNDS dup (0)
slot            dw      0

c0              dd      0
cq              dd      0
cm              dd      0
e0              dd      0
eqv             dd      0
em              dd      0
t0              dd      0
shown           dd      0
nv              dw      0
penv            dw      0
glyphv          dw      0
fh              dw      0
roundv          dw      0
bad             dw      0
grow            db      0

.code

bnow            proc    near private uses bx es
                xor     bx, bx
                mov     es, bx
@@try:         mov     ax, es:[46Ch]
                mov     dx, es:[46Eh]
                mov     bx, es:[46Ch]
                cmp     ax, bx
                jne     @@try
                ret
bnow            endp

save_surface    proc    near private uses ax bx cx dx si di ds es
                xor     bx, bx
                mov     di, offset snap
@@row:          cmp     bx, HGT
                jae     @@out
                invoke  qglSfRdRow, qptr, bx
                push    ds
                mov     ds, dx
                mov     si, ax
                mov     cx, WID
                mov     ax, @data
                mov     es, ax
                rep     movsb
                pop     ds
                inc     bx
                jmp     @@row
@@out:          ret
save_surface    endp

compare_surface proc    near private uses bx cx dx si di es
                mov     bad, 0
                xor     bx, bx
                mov     di, offset snap
@@row:          cmp     bx, HGT
                jae     @@out
                invoke  qglSfRdRow, qptr, bx
                mov     es, dx
                mov     si, ax
                mov     cx, WID
@@byte:         mov     al, ds:[di]
                cmp     al, es:[si]
                je      @F
                inc     bad
@@:             inc     di
                inc     si
                loop    @@byte
                inc     bx
                jmp     @@row
@@out:          mov     ax, bad
                ret
compare_surface endp

;;::::::::::::::
;; bg_at ( x:word, y:word ) -> al -- the background rule.
;;
;;   (7*x + 3*y) and 31
;;
;; 0..31 cannot collide with FG 47 or MASK8 0E3h, so a lit pixel and a
;; background pixel are always distinguishable. A UNIFORM background --
;; which this test had -- lets a routine that wrongly paints the
;; background colour into a glyph's clear bits produce a byte-identical
;; image. Transparency was exercised and never observed.
;;::::::::::::::
bg_at           proc    near private uses bx,\
                        x:word, y:word
                mov     ax, x
                imul    ax, 7
                mov     bx, y
                imul    bx, 3
                add     ax, bx
                and     ax, 31
                ret
bg_at           endp


;;::::::::::::::
;; live_row ( y:word ) -> dx:ax -- this test's OWN address for a row.
;;
;; Reads only handle/base_ofs/stride and does its own arithmetic. Going
;; through qglSfWrRow would make the fixture and the mutation depend
;; on the row addressing of the library under test, which is the same
;; dependence b02's seed_src exists to avoid.
;;
;; 160 x 32 is 5,120 bytes, so no row can wrap 64K and the offset stays
;; a single word.
;;::::::::::::::
live_row        proc    near private uses bx cx di,\
                        y:word
                local   seg_:word
                local   off_:word

                mov     bx, offset qsurf
                mov     ax, W [bx].Surface.base_ofs
                mov     dx, W [bx].Surface.base_ofs+2
                mov     cx, 4
@@n:            shr     dx, 1
                rcr     ax, 1
                loop    @@n
                add     ax, [bx].Surface.handle
                mov     seg_, ax

                mov     ax, W [bx].Surface.base_ofs
                and     ax, 15
                mov     off_, ax

                mov     ax, y
                mul     [bx].Surface.stride
                add     ax, off_
                mov     dx, seg_
                ret
live_row        endp


;;::::::::::::::
;; seed_bg -- the pattern into the live destination, by this test alone.
;;::::::::::::::
seed_bg         proc    near private uses ax bx cx dx si di es
                xor     si, si                  ;; y
@@row:          cmp     si, HGT
                jae     @@out
                invoke  live_row, si
                mov     es, dx
                mov     di, ax
                xor     bx, bx                  ;; x
@@col:          cmp     bx, WID
                jae     @@rnext
                invoke  bg_at, bx, si
                mov     es:[di], al
                inc     di
                inc     bx
                jmp     @@col
@@rnext:        inc     si
                jmp     @@row
@@out:          ret
seed_bg         endp


;;::::::::::::::
;; build_expect -- the whole 160x32 image the string should leave.
;;
;; The background is RECOMPUTED from the same rule, never copied out of
;; the live surface: copying would import whatever the seeding got wrong
;; and make the oracle agree with it. The glyph bits come from the font
;; block with this procedure's own indexing, never from either arm.
;;::::::::::::::
build_expect    proc    near private uses ax bx cx dx si di es
                xor     si, si
@@brow:         cmp     si, HGT
                jae     @@text
                xor     bx, bx
@@bcol:         cmp     bx, WID
                jae     @@bnext
                invoke  bg_at, bx, si
                mov     di, si
                imul    di, WID
                add     di, bx
                mov     expect[di], al
                inc     bx
                jmp     @@bcol
@@bnext:        inc     si
                jmp     @@brow

@@text:         mov     penv, OR_X
                mov     si, offset textv
@@ch:           mov     al, ds:[si]
                test    al, al
                jz      @@out
                xor     ah, ah
                sub     ax, OR_FIRST
                mov     glyphv, ax              ;; glyph index

                xor     cx, cx                  ;; row
@@grow:         cmp     cx, OR_CELLH
                jae     @@advance
                mov     ax, glyphv
                imul    ax, OR_CELLH
                add     ax, cx
                imul    ax, OR_ROWB
                add     ax, OR_BITS
                les     bx, fontp
                add     bx, ax
                mov     dl, es:[bx]             ;; this row's eight bits

                xor     bx, bx                  ;; column
@@gcol:         cmp     bx, 8
                jae     @@gnext
                mov     dh, 80h
                mov     ax, bx
                push    cx
                mov     cl, al
                shr     dh, cl
                pop     cx
                test    dl, dh
                jz      @F
                mov     di, cx
                add     di, OR_Y
                imul    di, WID
                add     di, penv
                add     di, bx
                mov     expect[di], FG
@@:             inc     bx
                jmp     @@gcol
@@gnext:        inc     cx
                jmp     @@grow

@@advance:      add     penv, OR_ADV
                inc     si
                jmp     @@ch
@@out:          ret
build_expect    endp


;;::::::::::::::
;; cmp_expect -> ax -- the live surface against the oracle, row by row,
;; WID bytes a row through the surface's real pitch.
;;::::::::::::::
cmp_expect      proc    near private uses bx cx dx si di es
                mov     bad, 0
                xor     si, si
                mov     di, offset expect
@@row:          cmp     si, HGT
                jae     @@out
                invoke  qglSfRdRow, qptr, si
                mov     es, dx
                mov     bx, ax
                mov     cx, WID
@@byte:         mov     al, ds:[di]
                cmp     al, es:[bx]
                je      @F
                inc     bad
@@:             inc     di
                inc     bx
                loop    @@byte
                inc     si
                jmp     @@row
@@out:          mov     ax, bad
                ret
cmp_expect      endp


;;::::::::::::::
;; mutate_glyph -- nothing, in the shipped harness.
;;
;; The seam a controlled mutation is applied at, kept so a mutated build
;; differs from this one in one procedure and not in the oracle, the
;; fixture or the arms.
;;
;; What it holds when enabled, and why here: MUT_X,MUT_Y is (11,4),
;; which is lit on the final overlapped image while (11,5) is
;; background, so moving that pixel one row down both clears a lit pixel
;; and lights an unlit one, leaving every pen position alone. It writes
;; the LIVE destination through this test's own row address and runs
;; BEFORE the oracle comparison -- mutating the snapshot afterwards
;; would leave qgl-vs-oracle green and prove nothing about the oracle it
;; exists to test.
;;
;; Proven: with the body in place the run failed exactly
;; `text qgl vs oracle` and `font output identical`, exit 2, with
;; `text mgl vs oracle` green.
;;::::::::::::::
mutate_glyph    proc    near private
                ret
mutate_glyph    endp


mgl_text        proc    near private uses ax bx cx dx si di
                mov     si, offset textv
                mov     di, 2
@@ch:           mov     al, ds:[si]
                test    al, al
                jz      @@out
                xor     ah, ah
                mov     bx, ax
                shl     bx, 2
                invoke  uglPutMsk, dc, di, 2, glyphs[bx]
                add     di, 4
                inc     si
                jmp     @@ch
@@out:          ret
mgl_text        endp

qarm            proc    near private uses ax bx cx dx si di
                mov     ax, LOOPS
                mov     nv, ax
@@:             invoke  qglTxtStr, qptr, 2, 2, fontp, textp, FG
                dec     nv
                jnz     @B
                ret
qarm            endp

marm            proc    near private uses ax bx cx dx si di
                mov     ax, LOOPS
                mov     nv, ax
@@:             call    mgl_text
                dec     nv
                jnz     @B
                ret
marm            endp

timeq           proc    near private
                call    bnow
                mov     word ptr t0, ax
                mov     word ptr t0+2, dx
                call    qarm
                call    bnow
                sub     ax, word ptr t0
                sbb     dx, word ptr t0+2
                mov     word ptr shown, ax
                mov     word ptr shown+2, dx
                invoke  tshow, offset n_qt, shown
                mov     di, offset qsamp
                mov     ax, slot
                shl     ax, 2
                add     di, ax
                mov     ax, W shown
                mov     [di], ax
                mov     ax, W shown+2
                mov     [di+2], ax
                mov     ax, 1
                cmp     word ptr shown+2, 0
                jne     @F
                cmp     word ptr shown, 20
                jae     @F
                xor     ax, ax
@@:             CHK     n_duration, ax, 1
                ret
timeq           endp

timem           proc    near private
                call    bnow
                mov     word ptr t0, ax
                mov     word ptr t0+2, dx
                call    marm
                call    bnow
                sub     ax, word ptr t0
                sbb     dx, word ptr t0+2
                mov     word ptr shown, ax
                mov     word ptr shown+2, dx
                invoke  tshow, offset n_mt, shown
                mov     di, offset msamp
                mov     ax, slot
                shl     ax, 2
                add     di, ax
                mov     ax, W shown
                mov     [di], ax
                mov     ax, W shown+2
                mov     [di+2], ax
                mov     ax, 1
                cmp     word ptr shown+2, 0
                jne     @F
                cmp     word ptr shown, 20
                jae     @F
                xor     ax, ax
@@:             CHK     n_duration, ax, 1
                ret
timem           endp

tmain           proc    far public uses ax bx cx dx si di es
                invoke  qglSfInit
                invoke  uglInit
                NZ      ax
                CHK     n_init, ax, 1

                mov     word ptr fpath, offset fname
                mov     word ptr fpath+2, ds
                mov     word ptr textp, offset textv
                mov     word ptr textp+2, ds
                mov     word ptr glyph_desc, offset glyphs
                mov     word ptr glyph_desc+2, ds
                mov     word ptr qptr, offset qsurf
                mov     word ptr qptr+2, ds

                invoke  qglMemAvail, MEM_TOTAL
                SAVEP   c0
                invoke  emsAvail
                SAVEP   e0
                invoke  tshow, offset n_c0, c0
                invoke  tshow, offset n_e0, e0

                invoke  qglTxtLoad, fpath
                SAVEP   fontp
                mov     bx, dx
                or      bx, ax
                NZ      bx
                CHK     n_font, ax, 1
                ;;
                ;; TEN FACTS THE ORACLE RESTS ON, asserted rather than
                ;; assumed. adv 4 and adv_ofs 0 are the two that matter
                ;; most: they are what makes the mgl loop's hardcoded
                ;; `add di,4` equivalent to qgl asking the font. Without
                ;; them the two arms could silently draw different
                ;; strings, and a timing comparison of different
                ;; workloads measures nothing.
                ;;
                les     bx, fontp
                ;; all four bytes: "FN" then "T1". Checking the first
                ;; word alone accepts any file starting "FN".
                mov     ax, 1
                cmp     W es:[bx].Font.magic, 'NF'
                jne     @F
                cmp     W es:[bx].Font.magic+2, '1T'
                je      @@magok
@@:             xor     ax, ax
@@magok:        CHK     n_magic, ax, 1
                mov     al, es:[bx].Font.cell_w
                xor     ah, ah
                CHK     n_cw, ax, 8
                les     bx, fontp
                mov     al, es:[bx].Font.cell_h
                xor     ah, ah
                CHK     n_chh, ax, OR_CELLH
                les     bx, fontp
                mov     al, es:[bx].Font.rowbytes
                xor     ah, ah
                CHK     n_rb, ax, OR_ROWB
                les     bx, fontp
                mov     ax, es:[bx].Font.first
                CHK     n_first, ax, OR_FIRST
                les     bx, fontp
                mov     ax, es:[bx].Font.count
                CHK     n_count, ax, 256
                les     bx, fontp
                mov     ax, es:[bx].Font.bits_ofs
                CHK     n_bofs, ax, OR_BITS
                les     bx, fontp
                mov     al, es:[bx].Font.adv
                xor     ah, ah
                CHK     n_adv, ax, OR_ADV
                les     bx, fontp
                mov     ax, es:[bx].Font.adv_ofs
                CHK     n_aofs, ax, 0

                ;; and the file itself, which the block does not record
                invoke  qglFileOpen, fpath
                mov     fh, ax
                invoke  qglFileSize, fh
                ;; DX:AX, and a nonzero DX is a file 64K or larger --
                ;; testing AX alone would accept 65536+2068
                mov     cx, 1
                test    dx, dx
                jnz     @F
                cmp     ax, FSIZE
                je      @@szok
@@:             xor     cx, cx
@@szok:         CHK     n_fsize, cx, 1
                invoke  qglFileClose, fh

                invoke  qglMemAvail, MEM_TOTAL
                SAVEP   cq
                invoke  emsAvail
                SAVEP   eqv
                invoke  tshow, offset n_cq, cq
                invoke  tshow, offset n_eq, eqv
                invoke  tshow, offset n_qh, 4

                invoke  uglNewMult, addr glyph_desc, 256, DC_EMS, FMT_8BIT, 8, 8
                NZ      ax
                CHK     n_mult, ax, 1
                invoke  qglMemAvail, MEM_TOTAL
                SAVEP   cm
                invoke  emsAvail
                SAVEP   em
                invoke  tshow, offset n_cm, cm
                invoke  tshow, offset n_em, em
                invoke  tshow, offset n_mh, 1024

                ;; Expand the exact packed bits into the exact MGL layout
                ;; used by screen.bas. This setup is outside the timed arm.
                xor     si, si                  ;; glyph
@@glyph:        cmp     si, 256
                jae     @@dest
                xor     di, di                  ;; row
@@grow:         cmp     di, 8
                jae     @@gnext
                les     bx, fontp
                mov     ax, si
                shl     ax, 3
                add     ax, di
                add     ax, es:[bx].Font.bits_ofs
                add     bx, ax
                mov     al, es:[bx]
                mov     grow, al
                xor     cx, cx                  ;; column
@@gcol:         cmp     cx, 8
                jae     @@rnext
                mov     ax, 7
                sub     ax, cx
                push    cx
                mov     cl, al
                mov     al, grow
                shr     al, cl
                pop     cx
                and     al, 1
                mov     edx, MASK8
                jz      @F
                mov     edx, FG
@@:             mov     bx, si
                shl     bx, 2
                invoke  uglPSet, glyphs[bx], cx, di, edx
                inc     cx
                jmp     @@gcol
@@rnext:        inc     di
                jmp     @@grow
@@gnext:        inc     si
                jmp     @@glyph

@@dest:         invoke  uglNew, DC_MEM, FMT_8BIT, WID, HGT
                SAVEP   dc
                invoke  qglSfAdoptDc, dc, qptr
                NZ      ax
                CHK     n_init, ax, 1

                ;; the adopted pitch, reported not assumed
                mov     bx, offset qsurf
                mov     ax, [bx].Surface.stride
                xor     dx, dx
                SAVEP   shown
                invoke  tshow, offset n_pitch, shown

                ;; the advance, which pixels cannot establish
                invoke  qglTxtWidth, fontp, textp
                CHK     n_width, ax, OR_WIDTH

                call    build_expect

                ;; ORDER MATTERS. The mutation hits the LIVE destination
                ;; before the oracle sees it; mutating the snapshot after
                ;; the comparison would leave qgl-vs-oracle green and
                ;; prove nothing about the oracle it tests.
                call    seed_bg
                invoke  qglTxtStr, qptr, 2, 2, fontp, textp, FG
                call    mutate_glyph
                call    cmp_expect
                CHK     n_qok, ax, 0
                call    save_surface            ;; the mutated qgl image

                call    seed_bg
                call    mgl_text
                call    cmp_expect
                CHK     n_mok, ax, 0

                call    compare_surface
                CHK     n_same, ax, 0

                mov     roundv, ROUNDS
@@round:        mov     ax, ROUNDS              ;; roundv counts down
                sub     ax, roundv
                mov     slot, ax
                test    roundv, 1
                jz      @@mq
                call    timeq
                call    timem
                jmp     @@rnext2
@@mq:           call    timem
                call    timeq
@@rnext2:       dec     roundv
                jnz     @@round

                ;;
                ;; SEPARATED, because the pools are not interchangeable.
                ;; c0-cq is the packed font (2068 rounded to paragraphs).
                ;; cq-cm is mgl's DYNAMIC allocations and DC metadata
                ;; only -- glyphs(256) is static and already resident at
                ;; baseline, so it is not in this delta. eq-em is the EMS
                ;; the glyph pixels take. Caller-side program image is
                ;; reported on its own and added to nothing.
                ;;
                mov     ax, W c0
                sub     ax, W cq
                mov     dx, W c0+2
                sbb     dx, W cq+2
                SAVEP   shown
                invoke  tshow, offset n_cfont, shown

                mov     ax, W cq
                sub     ax, W cm
                mov     dx, W cq+2
                sbb     dx, W cm+2
                SAVEP   shown
                invoke  tshow, offset n_cmgl, shown

                mov     ax, W eqv
                sub     ax, W em
                mov     dx, W eqv+2
                sbb     dx, W em+2
                SAVEP   shown
                invoke  tshow, offset n_emgl, shown

                mov     W shown, 4              ;; one far pointer
                mov     W shown+2, 0
                invoke  tshow, offset n_qstat, shown
                mov     W shown, 1042           ;; glyphs 1024 + desc 18
                mov     W shown+2, 0
                invoke  tshow, offset n_mstat, shown

                invoke  uglDel, addr dc
                invoke  uglDelMult, addr glyph_desc
                invoke  qglTxtFree, fontp

                ;; recovery is only claimable with these
                invoke  qglMemAvail, MEM_TOTAL
                SAVEP   shown
                invoke  tshow, offset n_cfree, shown
                invoke  emsAvail
                SAVEP   shown
                invoke  tshow, offset n_efree, shown

                invoke  uglEnd
                ret
tmain           endp
                end
