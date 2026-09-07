;; b02prim -- application-level qgl drawing primitives against mgl.
;;
;; Both arms draw into the same mgl MEM DC. qgl reaches those pixels only
;; through qglSfAdoptDc, which is the transition path used by qrender.
;; Every operation is compared byte-for-byte before it is timed. Six rounds
;; are interleaved in one process so startup and host drift hit both arms.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglSfInit     proto   far
qglSfAdoptDc proto   far :dword, :dword
qglSfRdRow   proto   far :dword, :word
qglDrFill     proto   far :dword, :word, :word, :word, :word, :word
qglDrHline    proto   far :dword, :word, :word, :word, :word
qglDrVline    proto   far :dword, :word, :word, :word, :word
qglDrLine     proto   far :dword, :word, :word, :word, :word, :word
qglDrBlit     proto   far :dword, :word, :word, :dword
qglDrBlitScl proto   far :dword, :word, :word, :word, :word, :dword

uglInit         proto   far
uglEnd          proto   far
uglNew          proto   far :word, :word, :word, :word
uglDel          proto   far :dword
uglPSet         proto   far :dword, :word, :word, :dword
uglHLine        proto   far :dword, :word, :word, :word, :dword
uglVLine        proto   far :dword, :word, :word, :word, :dword
uglLine         proto   far :dword, :word, :word, :word, :word, :dword
uglRectF        proto   far :dword, :word, :word, :word, :word, :dword
uglPut          proto   far :dword, :word, :word, :dword
uglPutScl       proto   far :dword, :word, :word, :dword, :dword, :dword

DC_MEM          equ     0
FMT_8BIT        equ     0
WID             equ     160
HGT             equ     100
SWID            equ     32
SHGT            equ     24
BYTES           equ     WID * HGT
ROUNDS          equ     6

;; The oracle's coordinates are ITS OWN, deliberately duplicated from
;; the call sites rather than shared with them. A mutation that moves an
;; arm's operand must not move the expected image with it, or the
;; mutation proves nothing.
OR_PSETX        equ     73
OR_PSETY        equ     41
OR_HY           equ     37
OR_HX0          equ     8
OR_HX1          equ     151
OR_VX           equ     73
OR_VY0          equ     8
OR_VY1          equ     91
OR_LX0          equ     7
OR_LY0          equ     9
OR_LX1          equ     151
OR_LY1          equ     91
OR_BX           equ     61
OR_BY           equ     37
OR_SX           equ     48
OR_SY           equ     26
BG              equ     11
FG              equ     47

OP_PSET         equ     0
OP_HLINE        equ     1
OP_VLINE        equ     2
OP_LINE         equ     3
OP_FILL         equ     4
OP_BLIT         equ     5
OP_SCALE        equ     6
OPS             equ     7
FIRST_OP        equ     0
LAST_OP         equ     OPS

.data
n_init          db      'mgl initialized       $'
n_adopt         db      'mgl DC adopted by qgl $'
n_enter         db      'entered benchmark     $'
n_qinit         db      'qgl initialized       $'
n_qcheck        db      'qgl validation arm    $'
n_mcheck        db      'mgl validation arm    $'
n_duration      db      'duration >= 20 ticks  $'

samenames       dw      offset s_pset, offset s_hline, offset s_vline
                dw      offset s_line, offset s_fill, offset s_blit
                dw      offset s_scale
s_pset          db      'pset bytes alike      $'
s_hline         db      'hline bytes alike     $'
s_vline         db      'vline bytes alike     $'
s_line          db      'line bytes alike      $'
s_fill          db      'fill bytes alike      $'
s_blit          db      'blit bytes alike      $'
s_scale         db      'scale bytes alike     $'

qnames          dw      offset q_pset, offset q_hline, offset q_vline
                dw      offset q_line, offset q_fill, offset q_blit
                dw      offset q_scale
mnames          dw      offset m_pset, offset m_hline, offset m_vline
                dw      offset m_line, offset m_fill, offset m_blit
                dw      offset m_scale
;; Six-round counts scaled from the faster calibration arm so every sample
;; clears 20 BIOS ticks; time_arm enforces that floor.
loops           dw      60000, 50000, 5000, 3000, 1500, 10000, 4000
repsv           dw      30, 12, 24, 24, 10, 12, 2

q_pset          db      'pset qgl ticks         $'
m_pset          db      'pset mgl ticks         $'
q_hline         db      'hline qgl ticks        $'
m_hline         db      'hline mgl ticks        $'
q_vline         db      'vline qgl ticks        $'
m_vline         db      'vline mgl ticks        $'
q_line          db      'line qgl ticks         $'
m_line          db      'line mgl ticks         $'
q_fill          db      'fill qgl ticks         $'
m_fill          db      'fill mgl ticks         $'
q_blit          db      'blit qgl ticks         $'
m_blit          db      'blit mgl ticks         $'
q_scale         db      'scale qgl ticks        $'
m_scale         db      'scale mgl ticks        $'

dc              dd      0
sdc             dd      0
qptr            dd      0
qsptr           dd      0
qsurf           Surface <>
qsrc            Surface <>
snap            db      BYTES dup (0)
expect          db      BYTES dup (0)           ;; the oracle image
n_pitch         db      'dst pitch (adopted)   $'
qmednames       dw      offset qm_pset, offset qm_hline, offset qm_vline
                dw      offset qm_line, offset qm_fill, offset qm_blit
                dw      offset qm_scale
mmednames       dw      offset mm_pset, offset mm_hline, offset mm_vline
                dw      offset mm_line, offset mm_fill, offset mm_blit
                dw      offset mm_scale
qm_pset         db      'pset qgl MEDIAN       $'
qm_hline        db      'hline qgl MEDIAN      $'
qm_vline        db      'vline qgl MEDIAN      $'
qm_line         db      'line qgl MEDIAN       $'
qm_fill         db      'fill qgl MEDIAN       $'
qm_blit         db      'blit qgl MEDIAN       $'
qm_scale        db      'scale qgl MEDIAN      $'
mm_pset         db      'pset mgl MEDIAN       $'
mm_hline        db      'hline mgl MEDIAN      $'
mm_vline        db      'vline mgl MEDIAN      $'
mm_line         db      'line mgl MEDIAN       $'
mm_fill         db      'fill mgl MEDIAN       $'
mm_blit         db      'blit mgl MEDIAN       $'
mm_scale        db      'scale mgl MEDIAN      $'

qoknames        dw      offset qo_pset, offset qo_hline, offset qo_vline
                dw      offset qo_line, offset qo_fill, offset qo_blit
                dw      offset qo_scale
moknames        dw      offset mo_pset, offset mo_hline, offset mo_vline
                dw      offset mo_line, offset mo_fill, offset mo_blit
                dw      offset mo_scale
qo_pset         db      'pset qgl vs oracle    $'
qo_hline        db      'hline qgl vs oracle   $'
qo_vline        db      'vline qgl vs oracle   $'
qo_line         db      'line qgl vs oracle    $'
qo_fill         db      'fill qgl vs oracle    $'
qo_blit         db      'blit qgl vs oracle    $'
qo_scale        db      'scale qgl vs oracle   $'
mo_pset         db      'pset mgl vs oracle    $'
mo_hline        db      'hline mgl vs oracle   $'
mo_vline        db      'vline mgl vs oracle   $'
mo_line         db      'line mgl vs oracle    $'
mo_fill         db      'fill mgl vs oracle    $'
mo_blit         db      'blit mgl vs oracle    $'
mo_scale        db      'scale mgl vs oracle   $'
qsamp           dd      ROUNDS dup (0)
msamp           dd      ROUNDS dup (0)
ssort           dd      ROUNDS dup (0)
slot            dw      0
bad             dw      0
t0              dd      0
shown           dd      0
opv             dw      0
nv              dw      0
rv              dw      0

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

clear           proc    near private
                invoke  qglDrFill, qptr, 0, 0, WID-1, HGT-1, 11
                ret
clear           endp

qarm            proc    near private uses ax bx cx dx si di,
                        op:word, n:word
                mov     ax, n
                mov     nv, ax
                mov     ax, op
                mov     opv, ax
@@again:       cmp     opv, OP_PSET
                jne     @F
                invoke  qglSfPset, qptr, 73, 41, 47
                jmp     @@next
@@:             cmp     opv, OP_HLINE
                jne     @F
                invoke  qglDrHline, qptr, 8, 37, 151, 47
                jmp     @@next
@@:             cmp     opv, OP_VLINE
                jne     @F
                invoke  qglDrVline, qptr, 73, 8, 91, 47
                jmp     @@next
@@:             cmp     opv, OP_LINE
                jne     @F
                invoke  qglDrLine, qptr, 7, 9, 151, 91, 47
                jmp     @@next
@@:             cmp     opv, OP_FILL
                jne     @F
                invoke  qglDrFill, qptr, 0, 0, WID-1, HGT-1, 47
                jmp     @@next
@@:             cmp     opv, OP_BLIT
                jne     @F
                invoke  qglDrBlit, qptr, 61, 37, qsptr
                jmp     @@next
@@:             invoke  qglDrBlitScl, qptr, 48, 26, 64, 48, qsptr
@@next:         dec     nv
                jnz     @@again
                ret
qarm            endp

marm            proc    near private uses ax bx cx dx si di,
                        op:word, n:word
                mov     ax, n
                mov     nv, ax
                mov     ax, op
                mov     opv, ax
@@again:       cmp     opv, OP_PSET
                jne     @F
                invoke  uglPSet, dc, 73, 41, 47
                jmp     @@next
@@:             cmp     opv, OP_HLINE
                jne     @F
                invoke  uglHLine, dc, 8, 37, 151, 47
                jmp     @@next
@@:             cmp     opv, OP_VLINE
                jne     @F
                invoke  uglVLine, dc, 73, 8, 91, 47
                jmp     @@next
@@:             cmp     opv, OP_LINE
                jne     @F
                invoke  uglLine, dc, 7, 9, 151, 91, 47
                jmp     @@next
@@:             cmp     opv, OP_FILL
                jne     @F
                invoke  uglRectF, dc, 0, 0, WID-1, HGT-1, 47
                jmp     @@next
@@:             cmp     opv, OP_BLIT
                jne     @F
                invoke  uglPut, dc, 61, 37, sdc
                jmp     @@next
@@:             invoke  uglPutScl, dc, 48, 26, 40000000h, 40000000h, sdc
@@next:         dec     nv
                jnz     @@again
                ret
marm            endp

snapshot        proc    near private uses ax bx cx dx si di ds es
                xor     si, si
                mov     di, offset snap
@@row:          cmp     si, HGT
                jae     @@out
                invoke  qglSfRdRow, qptr, si
                push    ds
                mov     ds, dx
                mov     si, ax
                mov     cx, WID
                mov     ax, @data
                mov     es, ax
                rep     movsb
                pop     ds
                mov     ax, di
                sub     ax, offset snap
                xor     dx, dx
                mov     cx, WID
                div     cx
                mov     si, ax
                jmp     @@row
@@out:          ret
snapshot        endp

;;::::::::::::::
;; src_at ( x:word, y:word ) -> al -- the source fixture's own rule.
;;::::::::::::::
src_at          proc    near private uses bx,\
                        x:word, y:word
                mov     ax, x
                imul    ax, 7
                mov     bx, y
                imul    bx, 3
                add     ax, bx
                add     ax, 32
                and     ax, 0FFh
                ret
src_at          endp


;;::::::::::::::
;; build_expect ( op:word ) -- the whole 160x100 image this op should
;; leave behind, from the oracle's own constants.
;;
;; A whole image, not spot checks: a count, a border probe and a
;; neighbour test all pass while a stray write sits somewhere nobody
;; looked.
;;::::::::::::::
build_expect    proc    near private uses ax bx cx dx si di es,\
                        op:word

                mov     ax, @data               ;; background first
                mov     es, ax
                mov     di, offset expect
                mov     cx, BYTES
                mov     al, BG
                cld
                rep     stosb

                cmp     op, OP_PSET
                jne     @F
                mov     di, OR_PSETY
                imul    di, WID
                add     di, OR_PSETX
                mov     expect[di], FG
                jmp     @@out

@@:             cmp     op, OP_HLINE
                jne     @F
                mov     di, OR_HY
                imul    di, WID
                add     di, OR_HX0
                mov     cx, OR_HX1 - OR_HX0 + 1
                mov     al, FG
                mov     bx, offset expect
                add     bx, di
@@hb:           mov     [bx], al
                inc     bx
                loop    @@hb
                jmp     @@out

@@:             cmp     op, OP_VLINE
                jne     @F
                mov     si, OR_VY0
@@vb:           cmp     si, OR_VY1
                ja      @@out
                mov     di, si
                imul    di, WID
                add     di, OR_VX
                mov     expect[di], FG
                inc     si
                jmp     @@vb

@@:             cmp     op, OP_LINE
                jne     @F
                ;; FROZEN, and stated before either arm ran: round-half-up
                ;; at the pixel centre. x-major, dx 144 against dy 82, so
                ;; one lit pixel per column.
                ;;    y = OR_LY0 + floor( (82*(x-OR_LX0) + 72) / 144 )
                mov     si, OR_LX0
@@lb:           cmp     si, OR_LX1
                ja      @@out
                mov     ax, si
                sub     ax, OR_LX0
                imul    ax, OR_LY1 - OR_LY0
                add     ax, (OR_LX1 - OR_LX0) / 2
                xor     dx, dx
                mov     cx, OR_LX1 - OR_LX0
                div     cx
                add     ax, OR_LY0
                mov     di, ax
                imul    di, WID
                add     di, si
                mov     expect[di], FG
                inc     si
                jmp     @@lb

@@:             cmp     op, OP_FILL
                jne     @F
                mov     di, offset expect
                mov     cx, BYTES
                mov     al, FG
                rep     stosb
                jmp     @@out

@@:             cmp     op, OP_BLIT
                jne     @@scl
                xor     si, si                  ;; j
@@bj:           cmp     si, SHGT
                jae     @@out
                xor     bx, bx                  ;; i
@@bi:           cmp     bx, SWID
                jae     @@bjn
                invoke  src_at, bx, si
                mov     di, si
                add     di, OR_BY
                imul    di, WID
                add     di, OR_BX
                add     di, bx
                mov     expect[di], al
                inc     bx
                jmp     @@bi
@@bjn:          inc     si
                jmp     @@bj

@@scl:          xor     si, si                  ;; j, doubled both ways
@@sj:           cmp     si, SHGT
                jae     @@out
                xor     bx, bx
@@si:           cmp     bx, SWID
                jae     @@sjn
                invoke  src_at, bx, si
                mov     dx, si                  ;; dest row = SY + 2j
                shl     dx, 1
                add     dx, OR_SY
                mov     cx, bx                  ;; dest col = SX + 2i
                shl     cx, 1
                add     cx, OR_SX
                mov     di, dx
                imul    di, WID
                add     di, cx
                mov     expect[di], al
                mov     expect[di+1], al
                mov     expect[di+WID], al
                mov     expect[di+WID+1], al
                inc     bx
                jmp     @@si
@@sjn:          inc     si
                jmp     @@sj

@@out:          ret
build_expect    endp


;;::::::::::::::
;; cmp_expect -> ax -- the live surface against the oracle image, row by
;; row, WID bytes a row through the surface's real pitch.
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
;; median ( base:word ) -> dx:ax
;;
;; ROUNDS is even, so this is the mean of the two middle samples under
;; integer division and floors a half tick. The raw samples above it are
;; the record; this is a convenience.
;;::::::::::::::
median          proc    near private uses bx cx si di,\
                        base:word
                mov     si, base
                mov     di, offset ssort
                mov     cx, ROUNDS*2
                push    ds
                pop     es
                cld
                rep     movsw
                xor     si, si
@@i:            cmp     si, ROUNDS*4
                jae     @@mid
                mov     di, si
                mov     bx, si
                add     bx, 4
@@j:            cmp     bx, ROUNDS*4
                jae     @@swap
                mov     eax, D ssort[bx]
                cmp     eax, D ssort[di]
                jae     @F
                mov     di, bx
@@:             add     bx, 4
                jmp     @@j
@@swap:         mov     eax, D ssort[si]
                mov     ecx, D ssort[di]
                mov     D ssort[si], ecx
                mov     D ssort[di], eax
                add     si, 4
                jmp     @@i
@@mid:          mov     eax, D ssort[(ROUNDS/2-1)*4]
                add     eax, D ssort[(ROUNDS/2)*4]
                shr     eax, 1
                mov     edx, eax
                shr     edx, 16
                ret
median          endp


;;::::::::::::::
;; seed_src -- the shared source fixture, written by this test alone.
;;
;;   src(x,y) = (x*7 + y*3 + 32) and 255
;;
;; NOT through qglSfPset or uglPSet: the bytes the blit and scale
;; oracles rest on must not come out of either library under test. Only
;; the Surface's own fields are read, and the addressing is this
;; procedure's own.
;;
;; Varying down the column as well as across matters: one fill per
;; column left every row identical, and a blit that duplicated, skipped
;; or transposed rows then drew exactly the right bytes.
;;::::::::::::::
seed_src        proc    near private uses ax bx cx dx si di es

                mov     bx, offset qsrc
                mov     ax, W [bx].Surface.base_ofs
                mov     dx, W [bx].Surface.base_ofs+2
                mov     cx, 4                   ;; base -> seg:off
@@n:            shr     dx, 1
                rcr     ax, 1
                loop    @@n
                mov     di, W [bx].Surface.base_ofs
                and     di, 15
                add     ax, [bx].Surface.handle
                mov     es, ax                  ;; es:di -> row 0

                xor     si, si                  ;; y
@@row:          cmp     si, SHGT
                jae     @@out
                push    di
                xor     bx, bx                  ;; x
@@col:          cmp     bx, SWID
                jae     @@rnext
                mov     ax, bx
                imul    ax, 7
                mov     dx, si
                imul    dx, 3
                add     ax, dx
                add     ax, 32
                mov     es:[di], al
                inc     di
                inc     bx
                jmp     @@col
@@rnext:        pop     di
                mov     bx, offset qsrc
                add     di, [bx].Surface.stride
                inc     si
                jmp     @@row
@@out:          ret
seed_src        endp


;;::::::::::::::
;; mutate_line -- nothing, in the shipped harness.
;;
;; The seam a controlled mutation is applied at. Keeping it here means a
;; mutated build differs from the clean one in one procedure and not in
;; the oracle, the fixture or the arms.
;;::::::::::::::
;; Every register is preserved, si above all: the caller is the
;; validation loop and si is its op index. It runs before cmp_expect and
;; before snapshot, so a relocated pixel reaches both the oracle
;; comparison and the direct one.
mutate_line     proc    near private uses ax bx cx dx si di es,\
                        op:word
                cmp     op, OP_LINE
                jne     @@out
@@out:          ret
mutate_line     endp


compare         proc    near private uses bx cx dx si di es
                mov     bad, 0
                xor     si, si
                mov     di, offset snap
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
compare         endp

time_arm        proc    near private uses ax bx cx dx si di,
                        arm:word, op:word, n:word, reps:word, nam:word
                call    bnow
                mov     word ptr t0, ax
                mov     word ptr t0+2, dx
                mov     ax, reps
                mov     rv, ax
@@repeat:
                cmp     arm, 0
                jne     @F
                invoke  qarm, op, n
                jmp     @@next
@@:             invoke  marm, op, n
@@next:         dec     rv
                jnz     @@repeat
@@done:         call    bnow
                sub     ax, word ptr t0
                sbb     dx, word ptr t0+2
                mov     word ptr shown, ax
                mov     word ptr shown+2, dx
                invoke  tshow, nam, shown

                mov     di, offset qsamp        ;; keep it for the median
                cmp     arm, 0
                je      @F
                mov     di, offset msamp
@@:             mov     ax, slot
                shl     ax, 2
                add     di, ax
                mov     ax, W shown
                mov     [di], ax
                mov     ax, W shown+2
                mov     [di+2], ax

                xor     bx, bx
                cmp     word ptr shown+2, 0
                jne     @F
                cmp     word ptr shown, 20
                jb      @@short
@@:             inc     bx
@@short:        invoke  tchk, offset n_duration, bx, 1
                ret
time_arm        endp

tmain           proc    far public uses ax bx cx dx si di es
                mov     shown, 0
                invoke  tshow, offset n_enter, shown
                invoke  qglSfInit
                invoke  tshow, offset n_qinit, shown
                invoke  uglInit
                NZ      ax
                CHK     n_init, ax, 1

                invoke  uglNew, DC_MEM, FMT_8BIT, WID, HGT
                SAVEP   dc
                invoke  uglNew, DC_MEM, FMT_8BIT, SWID, SHGT
                SAVEP   sdc
                mov     word ptr qptr, offset qsurf
                mov     word ptr qptr+2, ds
                mov     word ptr qsptr, offset qsrc
                mov     word ptr qsptr+2, ds
                invoke  qglSfAdoptDc, dc, qptr
                mov     bx, ax
                invoke  qglSfAdoptDc, sdc, qsptr
                and     ax, bx
                NZ      ax
                CHK     n_adopt, ax, 1

                call    seed_src

                ;; the adopted destination's pitch, reported rather
                ;; than assumed: mgl pads scanlines, and b07 measured a
                ;; 400-wide DC at stride 440
                mov     bx, offset qsurf
                mov     ax, [bx].Surface.stride
                xor     dx, dx
                SAVEP   shown
                invoke  tshow, offset n_pitch, shown

@@check:        xor     si, si
@@cop:          cmp     si, OPS
                jae     @@timed
                invoke  build_expect, si

                ;; qgl against the oracle
                call    clear
                invoke  qarm, si, 1
                invoke  mutate_line, si         ;; no-op unless mutated
                call    cmp_expect
                mov     bx, si
                shl     bx, 1
                invoke  tchk, qoknames[bx], bad, 0
                call    snapshot                ;; keep qgl's image

                ;; mgl against the same oracle
                call    clear
                invoke  marm, si, 1
                call    cmp_expect
                mov     bx, si
                shl     bx, 1
                invoke  tchk, moknames[bx], bad, 0

                ;; and, secondary, the two arms against each other
                call    compare
                mov     bx, si
                shl     bx, 1
                invoke  tchk, samenames[bx], bad, 0
                inc     si
                jmp     @@cop

@@timed:        mov     si, FIRST_OP
@@op:           cmp     si, LAST_OP
                jae     @@free
                mov     bx, si
                shl     bx, 1
                mov     di, ROUNDS
@@round:        mov     ax, ROUNDS              ;; di counts down
                sub     ax, di
                mov     slot, ax
                test    di, 1
                jz      @@mq
                invoke  time_arm, 0, si, loops[bx], repsv[bx], qnames[bx]
                invoke  time_arm, 1, si, loops[bx], repsv[bx], mnames[bx]
                jmp     @@rnext
@@mq:           invoke  time_arm, 1, si, loops[bx], repsv[bx], mnames[bx]
                invoke  time_arm, 0, si, loops[bx], repsv[bx], qnames[bx]
@@rnext:
                dec     di
                jnz     @@round

                invoke  median, offset qsamp
                mov     W shown, ax
                mov     W shown+2, dx
                mov     bx, si
                shl     bx, 1
                invoke  tshow, qmednames[bx], shown
                invoke  median, offset msamp
                mov     W shown, ax
                mov     W shown+2, dx
                mov     bx, si
                shl     bx, 1
                invoke  tshow, mmednames[bx], shown

                inc     si
                jmp     @@op

@@free:         invoke  uglDel, addr sdc
                invoke  uglDel, addr dc
                invoke  uglEnd
                ret
tmain           endp
                end
