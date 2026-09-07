;; b07scale -- the public scaled blit, against an independent oracle and a
;;             speed bound.
;;
;; The present path is 3.91ms of a 42.61ms frame and runs every frame, and
;; qglDrBlitScl is what a qgl present would call. It has the shape the
;; unscaled blit had before b05: two far calls per destination row, one to
;; map the source row and one the destination.
;;
;; It also runs a FRACTIONAL sampler for a case production never produces.
;; view_scale is picked in common.bas as "the largest whole-number multiple
;; of the backbuffer that still fits the screen" -- 2 at the shipped
;; 160x100 into 320x200 -- so the 8.8 accumulator and its per-pixel shift
;; compute a step that is always exactly one half.
;;
;; THE ORACLE IS INDEPENDENT. Expected bytes are computed per destination
;; pixel by index -- src(((sx-x)*ustep) shr 8, ((sy-y)*vstep) shr 8) --
;; read back through qglSfPget, never by replaying the streaming loop.
;; Two streaming loops that share a mistake agree with each other.
;;
;; Every case is decided by the oracle alone. mgl is timed beside qgl and
;; is not consulted about clipping.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglSfInit     proto   far
qglSfAdoptDc proto   far :dword, :dword
qglSfPget     proto   far :dword, :word, :word
qglSfPset     proto   far :dword, :word, :word, :word
qglSfNewEx   proto   far :word, :word, :word, :word, :word
qglSfFree     proto   far :dword
qglDrFill     proto   far :dword, :word, :word, :word, :word, :word
qglDrBlitScl proto   far :dword, :word, :word, :word, :word, :dword

uglInit         proto   far
uglEnd          proto   far
uglNew          proto   far :word, :word, :word, :word
uglDel          proto   far :dword
uglPutScl       proto   far :dword, :word, :word, :dword, :dword, :dword

DC_MEM          equ     0
FMT_8BIT        equ     0

SWID            equ     160                     ;; the shipped backbuffer
SHGT            equ     100
DWID            equ     320                     ;; the shipped mode
DHGT            equ     200

;; a destination past 64K: 400x200 is 80,000 bytes, and its source is
;; a quarter of that
BWID            equ     400
BHGT            equ     200
BSWID           equ     200
BSHGT           equ     100

;; both sides past 64K, at 1:1 -- the only integer scale that fits a
;; source over 64K in conventional memory, since 2x would need four
;; times the destination
TWID            equ     512
THGT            equ     160

;; the wholly-below canary: a backing store taller than the surface says
GHGT            equ     300
GCANARY         equ     55
GPROBE          equ     220

;; 1024 bytes a row over 100 rows is 102,400: the source's own rows
;; cross 64K at row 64, while the surface stays 160x100.
PSTRIDE         equ     1024
ESTRIDE         equ     256                     ;; a power of two, for EMS
;; 328 is 8 past a paragraph, so the destination cursor's
;; low-nibble carry actually runs. Every other stride here --
;; 160, 320, 400, 512, 1024 -- divides by 16 exactly, which
;; left that branch dead in all of them. 328 x 200 is 65,600,
;; so it crosses 64K too.
CSTRIDE         equ     328

ROUNDS          equ     6
LOOPS           equ     40
REPS            equ     6
;; The same multiplier for both arms, inside the timed region. The
;; fast path put qgl at 6-7 ticks, under the floor this test
;; enforces, so the work goes up rather than the floor coming down.
INNER           equ     4
;; The close-gap target, RED on arrival: at INNER=4 the unchanged scaler
;; measures qgl 126 against mgl 105.5, medians, 1.194x. That number is
;; this epoch's -- cputype is pinned now and earlier ones were not -- so
;; it is not comparable with anything measured before the pin, nor with
;; the pre-INNER 32-against-26 reading it replaces.
BOUND10         equ     11                      ;; qsum*10 <= msum*11

.data
n_init          db      'mgl initialized       $'
n_adopt         db      'mgl DC adopted by qgl $'
n_full          db      'exact 2x full screen  $'
n_xm1           db      'x = -1 odd phase      $'
n_ym1           db      'y = -1 odd phase      $'
n_below         db      'wholly below: canary  $'
n_partb         db      'partial bottom + canary$'
n_dst64         db      'destination past 64k  $'
n_b64s          db      'dst64 mgl stride      $'
n_b64p          db      'dst64 base low nibble $'
n_both64        db      'src and dst past 64k  $'
n_frac          db      'fractional still right$'
n_alloc         db      'every dc allocated    $'
n_out           db      'outside rect untouched$'
n_ems           db      'ems operand still right$'
n_pad           db      'padded stride past 64k$'
n_carry         db      'dst stride 328 carry  $'
n_carry1        db      'carry on 1st advance  $'
n_phase         db      'view base nibble is 8 $'
n_ccan          db      'row under view untouched$'
n_kind          db      'constructor gave kind $'
n_out2          db      'y=-1 last row untouched$'
n_dur           db      'duration >= 20 ticks  $'
n_bound         db      'qgl scale <= 1.1x mgl $'
q_scl           db      'scale qgl ticks       $'
m_scl           db      'scale mgl ticks       $'
n_qsum          db      'scale qgl tick sum    $'
n_msum          db      'scale mgl tick sum    $'

dc              dd      0
sdc             dd      0
qptr            dd      0
qsptr           dd      0
qsurf           Surface <>
qsrc            Surface <>
qgsurf          Surface <>
qasurf          Surface <>
qbsurf          Surface <>
qbsrc           Surface <>
bad             dw      0
t0              dd      0
shown           dd      0
qsum            dd      0
msum            dd      0
nv              dw      0
rv              dw      0
psrc            dd      0
pdst            dd      0
ppar            dd      0
pview           dd      0
qvsurf          Surface <>
esrc            dd      0
ustep           dw      0
vstep           dw      0

.code

steps           proto   near :word, :word, :word, :word
verify          proto   near :dword, :dword, :word, :word, :word, :word, :word, :word
qarm            proto   near :word
marm            proto   near :word
time_arm        proto   near :word, :word, :word

bnow            proc    near private uses bx es
                xor     bx, bx
                mov     es, bx
@@try:          mov     ax, es:[46Ch]
                mov     dx, es:[46Eh]
                mov     bx, es:[46Ch]
                cmp     ax, bx
                jne     @@try
                ret
bnow            endp

;;::::::::::::::
;; steps -- the 8.8 rates the scaler itself derives, recomputed here from
;; the same inputs so the oracle does not read them out of the code under
;; test.
;;::::::::::::::
steps           proc    near private uses bx cx dx,
                        sw:word, sh:word, w:word, h:word
                mov     ax, sw
                xor     dx, dx
                shl     eax, 8
                div     w
                mov     ustep, ax
                mov     ax, sh
                xor     dx, dx
                shl     eax, 8
                div     h
                mov     vstep, ax
                ret
steps           endp

;;::::::::::::::
;; verify -- every destination pixel of the rectangle, against the index
;; oracle. Pixels outside the destination are not read; pixels inside it
;; but outside the rectangle are left to the caller's own canary.
;;::::::::::::::
verify          proc    near private uses bx cx dx si di,
                        dp:dword, srcp:dword, x:word, y:word, w:word, h:word,
                        dw_:word, dhh:word
                local   sx:word, sy:word, u:word, v:word
                mov     bad, 0
                xor     di, di                  ;; dy
@@row:          mov     ax, di
                cmp     ax, h
                jae     @@out
                mov     ax, y
                add     ax, di
                mov     sy, ax
                test    ax, ax
                js      @@rnext
                cmp     ax, dhh
                jae     @@rnext

                ;; 32 bits kept: dy up to 512 times a step up to 256
                ;; is 131,072, and a word mul leaves the top half in dx
                movzx   eax, di                 ;; v = (dy*vstep) shr 8
                movzx   ecx, vstep
                mul     ecx
                shr     eax, 8
                mov     v, ax

                xor     si, si                  ;; dx
@@col:          mov     ax, si
                cmp     ax, w
                jae     @@rnext
                mov     ax, x
                add     ax, si
                mov     sx, ax
                test    ax, ax
                js      @@cnext
                cmp     ax, dw_
                jae     @@cnext

                movzx   eax, si
                movzx   ecx, ustep
                mul     ecx
                shr     eax, 8
                mov     u, ax

                invoke  qglSfPget, srcp, u, v
                mov     bx, ax
                invoke  qglSfPget, dp, sx, sy
                cmp     ax, bx
                je      @@cnext
                inc     bad
@@cnext:        inc     si
                jmp     @@col
@@rnext:        inc     di
                jmp     @@row
@@out:          mov     ax, bad
                ret
verify          endp

tmain           proc    far public uses ax bx cx dx si di es
                local   gdc:dword, guardp:dword, aliasp:dword
                local   bdc:dword, bsdc:dword, bufp:dword, bufsp:dword
                invoke  qglSfInit
                invoke  uglInit
                NZ      ax
                CHK     n_init, ax, 1

                invoke  uglNew, DC_MEM, FMT_8BIT, DWID, DHGT
                SAVEP   dc
                mov     ax, W dc
                or      ax, W dc+2
                NZ      ax
                CHK     n_alloc, ax, 1
                invoke  uglNew, DC_MEM, FMT_8BIT, SWID, SHGT
                SAVEP   sdc
                mov     ax, W sdc
                or      ax, W sdc+2
                NZ      ax
                CHK     n_alloc, ax, 1
                mov     word ptr qptr, offset qsurf
                mov     word ptr qptr+2, ds
                mov     word ptr qsptr, offset qsrc
                mov     word ptr qsptr+2, ds
                invoke  qglSfAdoptDc, dc, qptr
                NZ      ax
                CHK     n_adopt, ax, 1
                mov     bx, ax
                invoke  qglSfAdoptDc, sdc, qsptr
                NZ      ax
                CHK     n_adopt, ax, 1

                ;; a source where every column differs from its neighbour,
                ;; so a scaler that drops or repeats one is visible
                ;; BOTH AXES. One fill per column left every row of a
                ;; column identical, so reusing the wrong source row --
                ;; exactly what an integer scaler's row duplication can
                ;; get wrong -- would have been invisible.
                xor     di, di
@@srow:         cmp     di, SHGT
                jae     @@full
                xor     si, si
@@scol:         cmp     si, SWID
                jae     @@srnext
                mov     ax, si
                add     ax, di
                add     ax, 17
                invoke  qglSfPset, qsptr, si, di, ax
                inc     si
                jmp     @@scol
@@srnext:       inc     di
                jmp     @@srow

                ;; ---- exact 2x, the shipped shape ----
@@full:         invoke  steps, SWID, SHGT, DWID, DHGT
                invoke  qglDrFill, qptr, 0, 0, DWID-1, DHGT-1, 3
                invoke  qglDrBlitScl, qptr, 0, 0, DWID, DHGT, qsptr
                invoke  verify, qptr, qsptr, 0, 0, DWID, DHGT, DWID, DHGT
                invoke  tchk, offset n_full, bad, 0

                ;; ---- odd phases ----
                invoke  qglDrFill, qptr, 0, 0, DWID-1, DHGT-1, 3
                invoke  qglDrBlitScl, qptr, -1, 0, DWID, DHGT, qsptr
                invoke  verify, qptr, qsptr, -1, 0, DWID, DHGT, DWID, DHGT
                invoke  tchk, offset n_xm1, bad, 0

                invoke  qglDrFill, qptr, 0, 0, DWID-1, DHGT-1, 3
                invoke  qglDrBlitScl, qptr, 0, -1, DWID, DHGT, qsptr
                invoke  verify, qptr, qsptr, 0, -1, DWID, DHGT, DWID, DHGT
                invoke  tchk, offset n_ym1, bad, 0

                ;; and the ground OUTSIDE a shifted rectangle: at x = -1
                ;; the last destination column has no source and must keep
                ;; the background, not a wrapped first column.
                invoke  qglDrFill, qptr, 0, 0, DWID-1, DHGT-1, 3
                invoke  qglDrBlitScl, qptr, -1, 0, DWID, DHGT, qsptr
                invoke  qglSfPget, qptr, DWID-1, 100
                mov     bx, ax
                invoke  tchk, offset n_out, bx, 3

                ;; the same at the other edge: shifted up by one, the LAST
                ;; destination row has no source row and must keep the
                ;; ground rather than a wrapped first row.
                invoke  qglDrFill, qptr, 0, 0, DWID-1, DHGT-1, 3
                invoke  qglDrBlitScl, qptr, 0, -1, DWID, DHGT, qsptr
                invoke  qglSfPget, qptr, 160, DHGT-1
                mov     bx, ax
                invoke  tchk, offset n_out2, bx, 3

                ;; ---- wholly below, proven by a canary read through a
                ;;      full-height alias of the same store ----
                invoke  uglNew, DC_MEM, FMT_8BIT, DWID, GHGT
                SAVEP   gdc
                mov     ax, W gdc
                or      ax, W gdc+2
                NZ      ax
                CHK     n_alloc, ax, 1
                mov     ax, offset qgsurf
                mov     word ptr guardp, ax
                mov     word ptr guardp+2, ds
                mov     ax, offset qasurf
                mov     word ptr aliasp, ax
                mov     word ptr aliasp+2, ds
                invoke  qglSfAdoptDc, gdc, guardp
                NZ      ax
                CHK     n_adopt, ax, 1
                invoke  qglSfAdoptDc, gdc, aliasp
                NZ      ax
                CHK     n_adopt, ax, 1
                mov     bx, offset qgsurf
                mov     [bx].Surface.y_res, DHGT
                invoke  qglDrFill, aliasp, 0, 0, DWID-1, GHGT-1, GCANARY
                invoke  qglDrBlitScl, guardp, 0, GPROBE, DWID, DHGT, qsptr
                invoke  qglSfPget, aliasp, 61, GPROBE
                mov     bx, ax
                invoke  tchk, offset n_below, bx, GCANARY

                ;; PARTIAL bottom: half on, half off. The visible rows go
                ;; to the oracle; the row just past the logical height is
                ;; the canary, and a scaler that clips its count but not
                ;; its cursor writes there.
                invoke  qglDrFill, aliasp, 0, 0, DWID-1, GHGT-1, GCANARY
                invoke  qglDrBlitScl, guardp, 0, DHGT-40, DWID, DHGT, qsptr
                invoke  verify, guardp, qsptr, 0, DHGT-40, DWID, DHGT, DWID, DHGT
                mov     bx, bad
                invoke  qglSfPget, aliasp, 61, DHGT
                cmp     ax, GCANARY
                je      @F
                inc     bx
@@:             invoke  tchk, offset n_partb, bx, 0
                invoke  uglDel, addr gdc
                invoke  uglDel, addr dc
                invoke  uglDel, addr sdc

                ;; ---- a destination past 64K ----
                invoke  uglNew, DC_MEM, FMT_8BIT, BWID, BHGT
                SAVEP   bdc
                mov     ax, W bdc
                or      ax, W bdc+2
                NZ      ax
                CHK     n_alloc, ax, 1
                invoke  uglNew, DC_MEM, FMT_8BIT, BSWID, BSHGT
                SAVEP   bsdc
                mov     ax, W bsdc
                or      ax, W bsdc+2
                NZ      ax
                CHK     n_alloc, ax, 1
                mov     ax, offset qbsurf
                mov     word ptr bufp, ax
                mov     word ptr bufp+2, ds
                mov     ax, offset qbsrc
                mov     word ptr bufsp, ax
                mov     word ptr bufsp+2, ds
                invoke  qglSfAdoptDc, bdc, bufp
                NZ      ax
                CHK     n_adopt, ax, 1
                mov     bx, ax
                invoke  qglSfAdoptDc, bsdc, bufsp
                NZ      ax
                CHK     n_adopt, ax, 1

                ;; REPORTED, not assumed: mgl picks this destination's
                ;; stride, not the test, so whether its rows carry a
                ;; paragraph is mgl's business and has to be read back.
                ;; Assuming 400 with remainder 0 is what made this case's
                ;; behaviour under a carry mutation look impossible.
                mov     bx, offset qbsurf
                mov     ax, [bx].Surface.stride
                xor     dx, dx
                SAVEP   shown
                invoke  tshow, offset n_b64s, shown
                mov     bx, offset qbsurf
                mov     ax, W [bx].Surface.base_ofs
                and     ax, 15
                xor     dx, dx
                SAVEP   shown
                invoke  tshow, offset n_b64p, shown

                xor     di, di
@@bsrow:        cmp     di, BSHGT
                jae     @@bgo
                xor     si, si
@@bscol:        cmp     si, BSWID
                jae     @@bsnext
                mov     ax, si
                add     ax, di
                add     ax, 23
                invoke  qglSfPset, bufsp, si, di, ax
                inc     si
                jmp     @@bscol
@@bsnext:       inc     di
                jmp     @@bsrow
@@bgo:          invoke  steps, BSWID, BSHGT, BWID, BHGT
                invoke  qglDrFill, bufp, 0, 0, BWID-1, BHGT-1, 3
                invoke  qglDrBlitScl, bufp, 0, 0, BWID, BHGT, bufsp
                invoke  verify, bufp, bufsp, 0, 0, BWID, BHGT, BWID, BHGT
                invoke  tchk, offset n_dst64, bad, 0
                invoke  uglDel, addr bdc
                invoke  uglDel, addr bsdc

                ;; ---- both sides past 64K, 1:1 ----
                invoke  uglNew, DC_MEM, FMT_8BIT, TWID, THGT
                SAVEP   bdc
                mov     ax, W bdc
                or      ax, W bdc+2
                NZ      ax
                CHK     n_alloc, ax, 1
                invoke  uglNew, DC_MEM, FMT_8BIT, TWID, THGT
                SAVEP   bsdc
                mov     ax, W bsdc
                or      ax, W bsdc+2
                NZ      ax
                CHK     n_alloc, ax, 1
                invoke  qglSfAdoptDc, bdc, bufp
                NZ      ax
                CHK     n_adopt, ax, 1
                mov     bx, ax
                invoke  qglSfAdoptDc, bsdc, bufsp
                NZ      ax
                CHK     n_adopt, ax, 1
                invoke  qglDrFill, bufsp, 0, 0, TWID-1, THGT-1, 41
                invoke  qglDrFill, bufsp, 0, 128, TWID-1, THGT-1, 91
                invoke  steps, TWID, THGT, TWID, THGT
                invoke  qglDrFill, bufp, 0, 0, TWID-1, THGT-1, 3
                invoke  qglDrBlitScl, bufp, 0, 0, TWID, THGT, bufsp
                invoke  verify, bufp, bufsp, 0, 0, TWID, THGT, TWID, THGT
                invoke  tchk, offset n_both64, bad, 0
                invoke  uglDel, addr bdc
                invoke  uglDel, addr bsdc

                ;; ---- and a fractional scale, which must keep working
                ;;      through whatever path it routes to ----
                invoke  uglNew, DC_MEM, FMT_8BIT, DWID, DHGT
                SAVEP   dc
                mov     ax, W dc
                or      ax, W dc+2
                NZ      ax
                CHK     n_alloc, ax, 1
                invoke  uglNew, DC_MEM, FMT_8BIT, SWID, SHGT
                SAVEP   sdc
                mov     ax, W sdc
                or      ax, W sdc+2
                NZ      ax
                CHK     n_alloc, ax, 1
                invoke  qglSfAdoptDc, dc, qptr
                NZ      ax
                CHK     n_adopt, ax, 1
                invoke  qglSfAdoptDc, sdc, qsptr
                NZ      ax
                CHK     n_adopt, ax, 1
                xor     di, di
@@s2row:        cmp     di, SHGT
                jae     @@fgo
                xor     si, si
@@s2col:        cmp     si, SWID
                jae     @@s2next
                mov     ax, si
                add     ax, di
                add     ax, 17
                invoke  qglSfPset, qsptr, si, di, ax
                inc     si
                jmp     @@s2col
@@s2next:       inc     di
                jmp     @@s2row
@@fgo:          invoke  steps, SWID, SHGT, 300, 150
                invoke  qglDrFill, qptr, 0, 0, DWID-1, DHGT-1, 3
                invoke  qglDrBlitScl, qptr, 0, 0, 300, 150, qsptr
                invoke  verify, qptr, qsptr, 0, 0, 300, 150, DWID, DHGT
                invoke  tchk, offset n_frac, bad, 0

                ;; ---- a padded CMEM source whose ROWS cross 64K,
                ;;      at the shipped exact-2x shape ----
                ;;
                ;; qglSfNewEx takes the stride, so the surface stays
                ;; 160x100 scaling to 320x200 -- the shape production
                ;; actually presents -- while 1024 bytes a row puts its
                ;; own rows across 64K at row 64. Changing the dimensions
                ;; instead would have changed the scale being tested.
                invoke  qglSfNewEx, SWID, SHGT, PSTRIDE, SURF_CMEM, 0
                SAVEP   psrc
                mov     ax, W psrc
                or      ax, W psrc+2
                NZ      ax
                CHK     n_alloc, ax, 1
                les     bx, psrc
                mov     al, es:[bx].Surface.kind
                xor     ah, ah
                CHK     n_kind, ax, SURF_CMEM

                ;; seeded on BOTH sides of the crossing
                xor     di, di
@@prow:         cmp     di, SHGT
                jae     @@pgo
                xor     si, si
@@pcol:         cmp     si, SWID
                jae     @@pnext
                mov     ax, si
                add     ax, di
                add     ax, 5
                invoke  qglSfPset, psrc, si, di, ax
                inc     si
                jmp     @@pcol
@@pnext:        inc     di
                jmp     @@prow
@@pgo:          invoke  steps, SWID, SHGT, DWID, DHGT
                invoke  qglDrFill, qptr, 0, 0, DWID-1, DHGT-1, 3
                invoke  qglDrBlitScl, qptr, 0, 0, DWID, DHGT, psrc
                invoke  verify, qptr, psrc, 0, 0, DWID, DHGT, DWID, DHGT
                invoke  tchk, offset n_pad, bad, 0
                invoke  qglSfFree, psrc

                ;; ---- a destination whose stride is NOT a multiple of
                ;;      16, so the cursor's paragraph carry has to run ----
                invoke  qglSfNewEx, DWID, DHGT, CSTRIDE, SURF_CMEM, 0
                SAVEP   pdst
                mov     ax, W pdst
                or      ax, W pdst+2
                NZ      ax
                CHK     n_alloc, ax, 1
                les     bx, pdst
                mov     al, es:[bx].Surface.kind
                xor     ah, ah
                CHK     n_kind, ax, SURF_CMEM

                invoke  steps, SWID, SHGT, DWID, DHGT
                invoke  qglDrFill, pdst, 0, 0, DWID-1, DHGT-1, 3
                invoke  qglDrBlitScl, pdst, 0, 0, DWID, DHGT, qsptr
                invoke  verify, pdst, qsptr, 0, 0, DWID, DHGT, DWID, DHGT
                invoke  tchk, offset n_carry, bad, 0
                invoke  qglSfFree, pdst

                ;; ---- the same stride, shifted so the carry falls on the
                ;;      OTHER advance ----
                ;;
                ;; A store's base offset is a whole paragraph, so the case
                ;; above starts every pair at offset 0 and 0+8 never
                ;; crosses 16: only the second of the two advances carries,
                ;; and the first one is untested by it. Shifted by 8 the
                ;; roles swap exactly -- 8+8 crosses, 0+8 does not -- so
                ;; the two cases together cover both advances, and which
                ;; one fails names which advance broke.
                ;;
                ;; The nibble is ASSERTED, not assumed. An allocator that
                ;; stopped handing back paragraph-aligned blocks would turn
                ;; this silently back into a second copy of the case above.
                invoke  qglSfNewEx, DWID, DHGT+1, CSTRIDE, SURF_CMEM, 0
                SAVEP   ppar
                mov     ax, W ppar
                or      ax, W ppar+2
                NZ      ax
                CHK     n_alloc, ax, 1

                mov     W pview, offset qvsurf
                mov     W pview+2, ds
                invoke  qglSfView, pview, ppar, 8, DWID, DHGT, CSTRIDE
                mov     bx, offset qvsurf
                mov     ax, W [bx].Surface.base_ofs
                and     ax, 15
                CHK     n_phase, ax, 8

                ;; the parent is one row taller than the view, and that
                ;; spare row is the canary: the view's last row ends one
                ;; byte before it starts
                invoke  qglDrFill, ppar, 0, 0, DWID-1, DHGT, 3
                invoke  qglDrBlitScl, pview, 0, 0, DWID, DHGT, qsptr
                invoke  verify, pview, qsptr, 0, 0, DWID, DHGT, DWID, DHGT
                invoke  tchk, offset n_carry1, bad, 0
                invoke  qglSfPget, ppar, DWID-1, DHGT
                CHK     n_ccan, ax, 3
                invoke  qglSfFree, ppar

                ;; ---- an EMS operand at the same exact-2x shape ----
                ;;
                ;; Right today through the generic mapper; once a
                ;; CMEM-only fast path exists this is the case that fails
                ;; if its predicate lets an EMS surface through. The
                ;; stride is a power of two because an EMS row wants one.
                invoke  qglSfNewEx, SWID, SHGT, ESTRIDE, SURF_EMS, 2
                SAVEP   esrc
                mov     ax, W esrc
                or      ax, W esrc+2
                NZ      ax
                CHK     n_alloc, ax, 1
                les     bx, esrc
                mov     al, es:[bx].Surface.kind
                xor     ah, ah
                CHK     n_kind, ax, SURF_EMS

                xor     di, di
@@erow:         cmp     di, SHGT
                jae     @@ego
                xor     si, si
@@ecol:         cmp     si, SWID
                jae     @@enext
                mov     ax, si
                add     ax, di
                add     ax, 17
                invoke  qglSfPset, esrc, si, di, ax
                inc     si
                jmp     @@ecol
@@enext:        inc     di
                jmp     @@erow
@@ego:          invoke  qglDrFill, qptr, 0, 0, DWID-1, DHGT-1, 3
                invoke  qglDrBlitScl, qptr, 0, 0, DWID, DHGT, esrc
                invoke  verify, qptr, esrc, 0, 0, DWID, DHGT, DWID, DHGT
                invoke  tchk, offset n_ems, bad, 0
                invoke  qglSfFree, esrc

                ;; ---- and the bound ----
                invoke  steps, SWID, SHGT, DWID, DHGT
                mov     qsum, 0
                mov     msum, 0
                mov     di, ROUNDS
@@round:        test    di, 1
                jz      @@mq
                invoke  time_arm, 0, offset q_scl, offset qsum
                invoke  time_arm, 1, offset m_scl, offset msum
                jmp     @@rnext
@@mq:           invoke  time_arm, 1, offset m_scl, offset msum
                invoke  time_arm, 0, offset q_scl, offset qsum
@@rnext:        dec     di
                jnz     @@round

                invoke  tshow, offset n_qsum, qsum
                invoke  tshow, offset n_msum, msum
                mov     eax, qsum
                mov     ecx, 10
                mul     ecx
                mov     ebx, eax
                mov     eax, msum
                mov     ecx, BOUND10
                mul     ecx
                xor     dx, dx
                cmp     ebx, eax
                ja      @F
                inc     dx
@@:             invoke  tchk, offset n_bound, dx, 1

                invoke  uglDel, addr sdc
                invoke  uglDel, addr dc
                invoke  uglEnd
                ret
tmain           endp

qarm            proc    near private uses ax bx cx dx si di,
                        n:word
                mov     ax, n
                mov     nv, ax
@@again:        invoke  qglDrBlitScl, qptr, 0, 0, DWID, DHGT, qsptr
                dec     nv
                jnz     @@again
                ret
qarm            endp

marm            proc    near private uses ax bx cx dx si di,
                        n:word
                mov     ax, n
                mov     nv, ax
@@again:        invoke  uglPutScl, dc, 0, 0, 40000000h, 40000000h, sdc
                dec     nv
                jnz     @@again
                ret
marm            endp

time_arm        proc    near private uses ax bx cx dx si di,
                        arm:word, nam:word, acc:word
                call    bnow
                mov     word ptr t0, ax
                mov     word ptr t0+2, dx
                mov     rv, REPS
@@repeat:       cmp     arm, 0
                jne     @F
                invoke  qarm, LOOPS*INNER
                jmp     @@next
@@:             invoke  marm, LOOPS*INNER
@@next:         dec     rv
                jnz     @@repeat
                call    bnow
                sub     ax, word ptr t0
                sbb     dx, word ptr t0+2
                mov     word ptr shown, ax
                mov     word ptr shown+2, dx
                invoke  tshow, nam, shown
                mov     bx, acc
                mov     cx, word ptr shown
                add     [bx], cx
                mov     cx, word ptr shown+2
                adc     [bx+2], cx
                xor     bx, bx
                cmp     word ptr shown+2, 0
                jne     @F
                cmp     word ptr shown, 20
                jb      @@short
@@:             inc     bx
@@short:        invoke  tchk, offset n_dur, bx, 1
                ret
time_arm        endp
                end
