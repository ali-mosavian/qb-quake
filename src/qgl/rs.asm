;;
;; rs.asm -- the convex scanner. The pixels are b8/'s.
;;
;; name: qglRsPoly
;; desc: two edge chains walk down from the topmost vertex and hand one
;;       span per scanline to a filler. qglRsPoly is the front half --
;;       gradients, winding, clip, convert -- and it ends in one of TWO
;;       scanners, which is mgl's own split: uglPolyT ends in
;;       drawPoly_t2d and uglPolyTP in drawPoly_tp2d.
;;
;;       ONE ENTRY, AND IT TAKES EVERYTHING. There is no texture, mode,
;;       colour or depth to install first. The texture in particular is
;;       an EMS page that has to be mapped, and a mapping installed by
;;       one call and read by another is a mapping some third call is
;;       free to evict -- which is what qglRsTex did, and what the
;;       renderer's wandering black streaks were.
;;
;;       This module knows about polygons and nothing about pixel
;;       formats; b8/ knows about one byte a pixel and nothing about
;;       polygons. That is mgl's own line -- ugl/uglplxt.asm scans,
;;       cfmt/b8/8plxt.asm fills -- and it is what makes a second format
;;       a sibling directory rather than a flag in here.
;;
;; obs.: - both halves live in QGL_CODE, one segment for the layer, so
;;         the scanner's `call bx` into a filler is near. That is why
;;         UGL_CODE exists in mgl and it is the only reason here.
;;       - the destination is mapped for WRITING, the texture for
;;         READING, and depth through QGL_Z_SLOT: three accessors, three
;;         intents, dct.inc's arrangement. On EMS they are three
;;         different physical pages and the distinction is the whole
;;         point.
;;       - u and v are in TEXELS, scaled by the texture's width so one
;;         repeat spans it. qgl$drawA carries them 16.16 and qgl$drawP
;;         as real4, because drawP's are u/z and v/z: fixed point
;;         truncates those differently at every depth, which is the
;;         reason the two scanners exist at all.
;;       - 1/z is a float in both. It is compared, never sampled, so it
;;         has no business in a texture coordinate's fixed point.
;;

                .model  medium, pascal
                .386
                option  proc:private

                include qgl.inc

qglSfRdRow   proto   far pascal :dword, :word
qglClPolyEx   proto   far pascal :dword, :word, :dword, :dword, :word, :word
qglSfWrRow   proto   far pascal :dword, :word
qglSfWrRowEx proto  far pascal :dword, :word, :word

qgl$drawA       proto   near pascal :dword, :word, :word
qgl$drawP       proto   near pascal :dword, :word, :word

;; sf.asm's own numbers, restated here rather than shared: gem.asm defines
;; the same pair independently too, on purpose (its own header: "removes a
;; dependency"), and this module already reaches qgl.inc for everything
;; else, so a third independent copy is the established pattern, not a new
;; one.
EMS_PAGE_SIZE   equ     4000h
EMS_PAGE_MASK   equ     3FFFh

                externdef qgl$zscale:dword
                externdef qgl$zline:word
                externdef qgl$zacc:dword
                externdef qgl$zdzdx:dword

;; the walk's vertex: the caller's floats converted once. x, y, u and v
;; are 16.16; z stays a float.
QVertFx         struc
kx              dd      ?
ky              dd      ?
kz              real4   ?
ku              dd      ?
kv              dd      ?
QVertFx         ends

;; a*b >> 16, both 16.16. b may not be eax; edx is lost.
FXMUL           macro   a:req, b:req
                mov     eax, a
                imul    b
                shrd    eax, edx, 16
endm

FXMUL14         macro   a:req, b:req
                mov     eax, a
                imul    b
                shrd    eax, edx, 14
endm

;; a/b, both 16.16; a must already be in eax. edx is lost.
FXDIV           macro   a:req, b:req
                mov     eax, a
                mov     edx, a
                shl     eax, 16
                sar     edx, 16
                idiv    b
endm

;; mgl's fjmp.inc, verbatim. The FPU has no flags of its own that a jcc
;; can read, so every comparison here is a status word and a test.
FJG             macro   lbl:req
                fnstsw  ax
                test    ah, 01000001b
                jz      lbl                     ;; src > dst?
endm
FJGE            macro   lbl:req
                fnstsw  ax
                sahf
                jae     lbl                     ;; src >= dst?
endm
FJLE            macro   lbl:req
                fnstsw  ax
                test    ah, 01000001b
                jnz     lbl                     ;; src <= dst?
endm
FJE             macro   lbl:req
                fnstsw  ax
                test    ah, 01000000b
                jnz     lbl                     ;; src = dst?
endm

;; nom(f) = (a.f - b.f)*(b.y - c.y) - (b.f - c.f)*(a.y - b.y), left on the
;; FPU. mgl's polyx.inc CALC_NOM, register for register: es:bx-> a,
;; es:si-> b, es:di-> c, the caller's own vertices and not a copy.
CALC_NOM        macro   f:req
                fld     es:[bx].QVert.&f&
                fsub    es:[si].QVert.&f&
                fld     es:[si].QVert.vy
                fsub    es:[di].QVert.vy
                fmul
                fld     es:[si].QVert.&f&
                fsub    es:[di].QVert.&f&
                fld     es:[bx].QVert.vy
                fsub    es:[si].QVert.vy
                fmul
                fsub
endm

;; mgl's under/overflow gate on a gradient, `_2gb` in uglplxt.asm. A
;; triple that survived the denominator can still hand back a number no
;; fistp can store; without this the store writes 80000000h and the
;; polygon samples one texel for its whole width.
CHK2GB          macro   lbl:req
                fld     st(0)
                fabs
                fcomp   qgl$2gb
                FJGE    lbl
endm

;; The same gate on a u or v gradient, on WHICHEVER FORM THIS MODE'S
;; FILLER READS -- st(0) holds the 16.16 and `fval` the unscaled float,
;; and they differ by the 65536 that is inside the bound.
;;
;; mgl has two calc_gradients and each checks its own arm's number: the
;; affine one (uglplxt.asm :216, :224) the 16.16 it is about to fistp,
;; the perspective one (uglplxtp.asm :451, :456) the float, which it
;; never converts at all. qgl merged the routines and the check did not
;; follow, so a perspective face was refused at |gradient| >= 32768
;; texels per pixel -- 2^31/65536 -- for an overflow in a dword
;; qgl$drawP does not read. A narrow span with a few thousand repeats
;; reaches that and is legal data.
;;
;; The 16.16 store goes with the check, for the same reason: mgl's
;; perspective routine performs no fistp, and one that overflows writes
;; 80000000h into a slot only the affine filler reads.
GRADCHK         macro   fval:req, fxval:req, lbl:req
                local   aff, done
                cmp     qgl$mode, QGL_M_PTEX
                je      @F
                cmp     qgl$mode, QGL_M_ATEX
                jne     aff
@@:
                fld     fval
                fabs
                fcomp   qgl$2gb
                FJGE    lbl
                fstp    st(0)                   ;; the 16.16, unconverted
                jmp     done
aff:            CHK2GB  lbl
                fistp   D fxval
done:
endm


.data
qgl$65536       real4   65536.0
qgl$half        real4   0.5

;; mgl's _2gb and _l1sqr (uglplxtp.asm), real8 as they are there. The
;; second is an AREA test: denom is twice the triangle's signed area, so
;; 2.0 refuses anything under one square pixel -- and its SIGN is the
;; polygon's winding.
qgl$2gb         real8   2147483647.0
qgl$l1sqr       real8   2.0

;; The gradients come off the FPU already multiplied by 65536 and the
;; perspective filler wants them unscaled -- per pixel to carry the span
;; start across, per sub-span to walk it. Two multiplies rather than one
;; folded constant, so QGL_SUBDIVP stays a fact kept in one place.
qgl$r65536      real4   0.0000152587890625
qgl$subdivf     real4   QGL_SUBDIVF

;; Everything below is DERIVED, once per qglRsPoly, from that call's own
;; arguments. No caller can set it or read it, and nothing carries from
;; one call to the next -- a REFUSED call has still overwritten it, which
;; is fine precisely because no later call reads what it left. It is here
;; rather than on the stack because the fillers address it off fs and the
;; scanner patches immediates out of it.
;;
;; qgl$tofs/qgl$tseg in particular is a MAPPED EMS pointer. Deriving it
;; inside the call that reads it is the invariant this layer keeps: a
;; mapping is live for one qgl call and never across one, so nothing a
;; caller does between draws can pull the page out from under it.

;; per texture
qgl$tshift      dw      0                       ;; log2 of the width
qgl$tumsk       dw      0                       ;; width-1
qgl$tvmsk       dw      0                       ;; (height-1) << tshift
qgl$tofs        dw      0                       ;; base within its segment
qgl$tseg        dw      0
qgl$twhole      dd      0                       ;; width  as an integer
qgl$thwhole     dd      0                       ;; height as an integer

;; per polygon
qgl$dudx        dd      0                       ;; 16.16 texels per pixel
qgl$dvdx        dd      0
qgl$fcol        dw      0
qgl$mode        dw      QGL_M_TEX
qgl$zsf         dd      0                       ;; far ptr Surface, 0 = none
qgl$zmode       dw      QGL_Z_OFF

;; The same three gradients the perspective filler needs, and they are
;; not the same numbers. It steps u/z, v/z and 1/z -- all three linear in
;; screen space, which is the whole reason the divide can be amortised --
;; and it steps them a sub-span at a time, so these are floats, unscaled,
;; times QGL_SUBDIVP. The fixed-point pair above is what the AFFINE
;; fillers add per pixel and means nothing here.
qgl$fdudxn      real4   0.0
qgl$fdvdxn      real4   0.0
qgl$fdzdxn      real4   0.0
qgl$fdudx       real4   0.0                     ;; per PIXEL, for the span
qgl$fdvdx       real4   0.0                     ;; start; fdzdx's pair, and
qgl$fdzdx       real4   0.0                     ;; only qgl$drawP reads them

                public  qgl$dudx, qgl$dvdx, qgl$fcol, qgl$mode
                public  qgl$fdudxn, qgl$fdvdxn, qgl$fdzdxn
                public  qgl$fdudx, qgl$fdvdx, qgl$fdzdx
                public  qgl$tshift, qgl$tumsk, qgl$tvmsk, qgl$tofs
                public  qgl$tseg, qgl$zmode



;; THE COVERAGE, one interval a row: what the polygons drawn so far
;; already cover. It is never allowed to claim more than it has --
;; forgetting coverage costs pixels, claiming it would cost the picture
;; -- so two intervals that do not touch keep the wider and drop the
;; other. lo >= hi is a row nothing has covered.
;;
;; A row past the table simply claims nothing -- the scan bounds-checks
;; and skips, so a destination taller than this loses the skip and keeps
;; the picture. 256 is every mode qgl has a filler for.
QGL_COV_ROWS    equ     256

;; The depth row's page, and what it mapped to. A polygon's scanlines
;; walk one EMS page for most of its height and the dispatch that
;; resolves a row costs more than the whole of the rest of a scanline's
;; setup; this remembers the last answer and the page:handle it came
;; from. Dropped at every qglRsPoly, which is exactly as long as a
;; mapping is allowed to live -- anything else may take the window
;; between one call and the next, and the surface builder does.
;; 0FFFFh is no page: addrTB never holds it.
qgl_zrow_pg     dw      0FFFFh
qgl_zrow_seg    dw      0

qgl_cov_on      dw      0
qgl_cov_lo      dw      QGL_COV_ROWS dup (0)
qgl_cov_hi      dw      QGL_COV_ROWS dup (0)

;; qglRsPoly's phases in RDTSC cycles, and its calls: settex, gradients,
;; clip, fixup-to-scan, scan, count; then scanlines and pixels filled,
;; affine then perspective. qglPrfTake reads one and zeroes it.
;; slot 10 is clip.asm's: polygons that needed no clipping at all.
qgl_cy          dd      11 dup (0)
                public  qgl_cy

.data?
qgl$fx          QVertFx QGL_CLIPV dup (<>)
qgl$src         QVert   QGL_CLIPV dup (<>)

qgl$ztmp        dq      ?


;; eax, edx gone. k -1 only starts the lap.
CYLAP           macro   k
                db      0Fh, 31h                ;; rdtsc
                if      k GE 0
                mov     edx, eax
                sub     eax, cy0
                add     D fs:qgl_cy+k*4, eax    ;; ds may be the texture's
                mov     cy0, edx
                else
                mov     cy0, eax
                endif
endm

;; dx:ax = surface sf's row y, for writing. A conventional surface's row
;; is its table entry, read here; anything else goes through slow, the
;; accessor -- two far calls deep, and most of a scanline's walk when it
;; ran for every one. bx, es gone.
WRROW           macro   sf, y, slow
                local   acc, have
                mov     es, W sf+2              ;; a Surface sits at offset 0
                cmp     es:[Surface.typ], SF_MEM
                jne     acc
                mov     bx, y
                add     bx, es:[Surface.startSL]
                shl     bx, 2
                mov     dx, W es:[SF_addrTB][bx]      ;; segment, then
                mov     ax, W es:[SF_addrTB][bx]+2    ;; offset: the table's order
                jmp     short have
acc:            slow
have:
endm

;; dx:ax = surface sf's row y through window slot: qglSfWrRowEx's
;; dispatch without its two far frames. bx, cx gone.
DCTROW          macro   sf, y, slot
                local   dead, have
                push    fs
                push    di
                mov     fs, W sf+2
                mov     bx, fs:[Surface.typ]
                CHECKKIND bx, dead
                mov     di, y
                add     di, fs:[Surface.startSL]
                shl     di, 2
                mov     cl, slot
                call    qgl$dctTB[bx].wrAccessEx
                jmp     short have
dead:           xor     ax, ax
                xor     dx, dx
have:           pop     di
                pop     fs
endm

;; dx:ax = depth surface sf's row y, through the remembered page when it
;; is the one this row wants. bx, es, esi gone; fs kept, which is why
;; this does not simply inline DCTROW.
ZEMSROW         macro   sf, y, slot
                local   slow, have
                mov     es, W sf+2
                mov     bx, y
                add     bx, es:[Surface.startSL]
                shl     bx, 2
                mov     esi, es:[SF_addrTB][bx]
                cmp     si, qgl_zrow_pg
                jne     slow
                mov     dx, qgl_zrow_seg
                mov     eax, esi
                shr     eax, 16
                jmp     short have
slow:           DCTROW  sf, y, slot             ;; si survives it
                mov     qgl_zrow_pg, si
                mov     qgl_zrow_seg, dx
have:
endm

;; the filler call, its scanline and pixels counted; ds is the texture's
;; for it
FILLCALL        macro   k
                inc     D fs:qgl_cy+k*4
                push    edx
                movzx   edx, si
                add     D fs:qgl_cy+(k+1)*4, edx
                pop     edx
                push    ds
                mov     ds, qgl$tseg
                call    bx
                pop     ds
endm


                QGL_CODE

                externdef qgl$Fixup:near
                externdef b8_span:near

;;::::::::::::::
;; qgl$F2fxA -- one vertex into the walk's form, AFFINE.
;;
;;  in: si-> QVert, di-> QVertFx, both in ds
;;
;; mgl's F2FX_t2d (misc/mscshta.asm). Half a pixel goes onto x and y so a
;; coordinate names a pixel CENTRE, which is what makes the sub-scanline
;; correction symmetric. u and v are scaled to texels here so nothing
;; downstream has to remember to.
;;::::::::::::::
qgl$F2fxA       proc    near uses ax

                fld     [si].QVert.vx
                fadd    qgl$half
                fmul    qgl$65536
                fistp   D [di].QVertFx.kx

                fld     [si].QVert.vy
                fadd    qgl$half
                fmul    qgl$65536
                fistp   D [di].QVertFx.ky

                mov     eax, D [si].QVert.vz
                mov     D [di].QVertFx.kz, eax

                fild    D qgl$twhole
                fmul    [si].QVert.vu
                fmul    qgl$65536
                fistp   D [di].QVertFx.ku

                fild    D qgl$thwhole
                fmul    [si].QVert.vv
                fmul    qgl$65536
                fistp   D [di].QVertFx.kv
                ret
qgl$F2fxA       endp


;;::::::::::::::
;; qgl$F2fxP -- the same, PERSPECTIVE.
;;
;; mgl's F2FX_tp2d, and it differs from F2FX_t2d beside it twice. NO HALF
;; PIXEL ON x AND y, and u and v stay real4 TEXELS rather than going to
;; 16.16 -- qgl$drawP steps them on the FPU. The affine
;; path adds it because its filler truncates and the half turns that into
;; a round-to-nearest; the perspective filler rounds with its own fistp
;; after the divide, so the same addition here is not a rounding rule but
;; a displacement -- the polygon lands half a pixel down and right, and
;; every span is then sampled at u - 0.5*dudx. Measured against an
;; independent oracle as a peak at du = -1, dv = 0: one texel low in u
;; with v untouched, which is exactly half a pixel of x with no y.
;;::::::::::::::
qgl$F2fxP       proc    near uses ax

                fld     [si].QVert.vx
                fmul    qgl$65536
                fistp   D [di].QVertFx.kx

                fld     [si].QVert.vy
                fmul    qgl$65536
                fistp   D [di].QVertFx.ky

                mov     eax, D [si].QVert.vz
                mov     D [di].QVertFx.kz, eax

                fild    D qgl$twhole
                fmul    [si].QVert.vu
                fstp    D [di].QVertFx.ku

                fild    D qgl$thwhole
                fmul    [si].QVert.vv
                fstp    D [di].QVertFx.kv
                ret
qgl$F2fxP       endp


;;::::::::::::::
;; qgl$Grad -- d(u)/dx, d(v)/dx and d(1/z)/dx for the whole polygon.
;;
;;  in: es:bx-> a, es:si-> b, es:di-> c, three of the CALLER's QVert
;; out: CF set if the triple is degenerate or a gradient will not store;
;;      st(0)= denom on success, and the FPU empty on failure
;;
;; mgl's calc_gradients (ugl/uglplxt.asm, ugl/uglplxtp.asm) with qgl's
;; scaling. THE TRIPLE IS THE UNCLIPPED POLYGON'S, which is mgl's order --
;; sort, denom, gradients, cull, THEN clip. Taking it from the clipped
;; ring instead puts vertices that the screen edge just created into the
;; denominator, and two of those are collinear with the edge by
;; construction.
;;
;; ONE GRADIENT SERVES THE WHOLE N-GON, exactly rather than approximately:
;; u, v and 1/z are linear in screen space here, so three points on the
;; plane fix them everywhere on it. What is not safe is three nearly
;; collinear points -- that error multiplies across every scanline of the
;; polygon, not just the triangle they span -- so the caller picks a
;; spread triple, this refuses an exactly zero denominator, and the
;; magnitude gate below refuses what got through it.
;;::::::::::::::
qgl$Grad        proc    near uses ax cx dx

                CALC_NOM vx                     ;; denom
                ftst
                FJE     @@error                 ;; denom= 0?

                fld     st(0)                   ;; save denom

                fld     qgl$65536               ;; rdenom = 65536/denom
                fdivr

                ;; no texture scaling on z: it is 1/z, not a coordinate,
                ;; and qgl$zscale carries the caller's units
                ;;
                ;; and its gate stays on the 16.16 in BOTH modes, unlike
                ;; u and v below: qgl$Fixup patches qgl$zdzdx into the
                ;; PERSPECTIVE z fillers as well (b8span.asm, FIX_Z pw
                ;; and pt), so this arm consumes it too. mgl's
                ;; perspective calc_gradients checks the float there
                ;; only because it never computes zdzdx at all -- its z
                ;; fillers step whatever the last affine polygon left.
                fld     st(0)
                CALC_NOM vz
                fmul
                fld     st(0)                   ;; the perspective steps,
                fmul    qgl$r65536              ;; unscaled: per pixel to
                fst     qgl$fdzdx               ;; carry the span start
                fmul    qgl$subdivf             ;; across, per sub-span to
                fstp    qgl$fdzdxn              ;; walk it
                fmul    D qgl$zscale
                CHK2GB  @@err3
                fistp   D qgl$zdzdx

                ;; fiSTp on the affine arm, like the z store above it.
                ;; rdenom carries the
                ;; 65536, so what is on the stack is already the 16.16
                ;; value and wants converting to an integer, not writing
                ;; out as a float. fstp put 1.0 texel per pixel into the
                ;; gradient as 47800000h, whose top word is 4780h -- a
                ;; multiple of 64, so masking to a 64 wide texture gave a
                ;; step of exactly zero and the whole polygon sampled one
                ;; column. See src/host/qgldiff.bas for how that was
                ;; found; it is invisible to any test that takes its
                ;; gradients from here.
                fld     st(0)
                CALC_NOM vu
                fimul   D qgl$twhole            ;; one repeat spans the width
                fmul
                fld     st(0)
                fmul    qgl$r65536
                fst     qgl$fdudx
                fmul    qgl$subdivf
                fstp    qgl$fdudxn
                GRADCHK qgl$fdudx, qgl$dudx, @@err3

                CALC_NOM vv
                fimul   D qgl$thwhole
                fmul                            ;; the last rdenom
                fld     st(0)
                fmul    qgl$r65536
                fst     qgl$fdvdx
                fmul    qgl$subdivf
                fstp    qgl$fdvdxn
                GRADCHK qgl$fdvdx, qgl$dvdx, @@err2

                clc
                ret

                ;; fall through: three to pop for a gradient that still had
                ;; rdenom under it, two for the last one, one for denom
                ;; alone. mgl's @@error_du/@@error_dv/@@error ladder.
@@err3:         fstp    st(0)
@@err2:         fstp    st(0)
@@error:        fstp    st(0)
                stc
                ret
qgl$Grad        endp


;;::::::::::::::
;; qgl$SetTex ( t:far ptr Surface ) -> ax nonzero if it took
;;
;; INTERNAL, and called from inside qglRsPoly rather than by the caller.
;; It ends by MAPPING row 0, and that pointer is what the fillers read;
;; running it here is what keeps the mapping inside one qgl call.
;;
;; Refuses anything whose sides are not powers of two, because the filler
;; wraps with an AND, and anything past one 16K page, because the texel
;; base is a patched immediate that is never remapped mid-polygon.
;; Exceeding that page cost mgl a measured 15.5% triangle dropout.
;;
;; For an EMS surface this also refuses a texture that is UNDER 16K but
;; whose START isn't page-aligned, so its bytes cross into a second
;; physical page anyway -- row 0 maps one page and every later row is
;; read through that same fixed pointer, so a straddling texture reads
;; wrong bytes past the boundary with nothing to say so otherwise. No
;; caller hits this today (qglSfAdoptEms checks the same thing on mgl's
;; side, and sc_alloc's own blocks happen to be self-aligned -- see
;; sb.asm's header), which is exactly why it needs its own check here:
;; the guarantee lives in callers this proc cannot see.
;;::::::::::::::
qgl$SetTex      proc    near private uses bx cx dx si di es,\
                        t:dword

                les     bx, t
                mov     ax, es
                or      ax, bx
                jz      @@no

                mov     cx, es:[bx].Surface.xRes
                mov     dx, es:[bx].Surface.yRes
                mov     ax, es:[bx].Surface.bps
                cmp     ax, cx
                jne     @@no                    ;; a padded row does not wrap

                mov     ax, cx
                dec     ax
                test    cx, ax
                jnz     @@no
                mov     ax, dx
                dec     ax
                test    dx, ax
                jnz     @@no

                ;; mul writes dx:ax, so the height has to come back off
                ;; the Surface: reusing dx here built qgl$tvmsk out of the
                ;; product's high word and sent one row in eight past the
                ;; end of the texture
                mov     ax, cx
                mul     dx
                test    dx, dx
                jnz     @@no
                cmp     ax, 4000h
                ja      @@no

                cmp     es:[bx].Surface.typ, SF_EMS
                jne     @@onepage
                mov     si, ax                  ;; total bytes, saved: the
                                                ;; page check needs ax free
                ;; row 0's table entry: the high word IS the offset within
                ;; the logical page, so there is nothing to mask off. That
                ;; is the number qgl$fillView derived the page split from,
                ;; not a second derivation of it.
                mov     ax, W es:[bx+SF_addrTB+2]
                add     ax, si
                cmp     ax, EMS_PAGE_SIZE
                ja      @@no
@@onepage:      mov     dx, es:[bx].Surface.yRes

                xor     ax, ax                  ;; shift = log2(width)
                mov     si, cx
@@sh:           shr     si, 1
                cmp     si, 1
                jb      @F
                inc     ax
                jmp     @@sh
@@:             mov     qgl$tshift, ax

                mov     si, cx
                dec     si
                mov     qgl$tumsk, si
                mov     si, dx
                dec     si
                mov     cl, B qgl$tshift
                shl     si, cl
                mov     qgl$tvmsk, si

                movzx   eax, es:[bx].Surface.xRes
                mov     qgl$twhole, eax
                movzx   eax, es:[bx].Surface.yRes
                mov     qgl$thwhole, eax

                ;; row 0's pointer IS the base: the whole texture is one
                ;; page, so an EMS one maps here and the polygon this call
                ;; belongs to reads through it before anything else can
                ;; take the slot back
                invoke  qglSfRdRow, t, 0
                mov     qgl$tofs, ax
                mov     qgl$tseg, dx

                mov     ax, 1
                ret

@@no:           xor     ax, ax
                ret
qgl$SetTex      endp




;;::::::::::::::
;; qgl$Rev -- reverses the QVertFx elements in [si..di] inclusive.
;;
;; mgl's rev_range (uglplxtp.asm), register for register. Its vertices are
;; a stack local so it addresses them ss-relative; qgl$fx is DGROUP, so
;; these are ds. si and di are the loop variables and do not survive --
;; mgl's callers reload them before each call and so do ours.
;;::::::::::::::
qgl$Rev         proc    near private uses ax cx dx

@@outer:        cmp     si, di
                jae     @@done

                mov     cx, T QVertFx / 4
                push    si
                push    di
@@swap:         mov     eax, [si]
                mov     edx, [di]
                mov     [si], edx
                mov     [di], eax
                add     si, 4
                add     di, 4
                dec     cx
                jnz     @@swap
                pop     di
                pop     si

                add     si, T QVertFx
                sub     di, T QVertFx
                jmp     @@outer

@@done:         ret
qgl$Rev         endp


;;::::::::::::::
;; qglRsPoly ( d:far ptr Surface, v:far ptr QVert, n:word,
;;             mode:word, src:dword ) -> ax
;;
;; Draws one convex polygon and returns the scanlines it covered, 0 if it
;; covered none, and -1 if the call was refused. The vertices arrive in
;; ring order, in EITHER winding, and vtx[0] need not be the topmost --
;; mgl's uglPolyTP contract, and this is a transcription of it: search the
;; widest triple, take the gradients off the UNCLIPPED polygon, cull on
;; the denominator's magnitude, take the winding off its sign, and only
;; then clip.
;;
;; EVERY DRAW PARAMETER ARRIVES HERE. There is no qglRsTex, qglRsMode
;; or qglRsFlat to call first, deliberately: a texture is an EMS page
;; that has to be mapped, and a mapping installed by one call and read by
;; another is a mapping some third call is free to evict. So the texture
;; is validated and mapped inside this proc, used, and never spoken of
;; again -- and the mode comes with it rather than being left as one more
;; thing a caller has to have got right earlier.
;;
;; DEPTH IS THE EXCEPTION, and it is not state either: it belongs to the
;; DESTINATION. qglSfZNew attaches a depth Surface to the surface it was
;; made for and qglSfZMode says what a draw into that surface does with
;; it, so there is no depth argument to get wrong -- a draw reads both
;; off d, which is the one thing it cannot be mistaken about.
;;
;; src is one slot read two ways -- a Surface pointer when the mode is
;; textured, a colour when it is flat -- and that is qgl's, NOT mgl's.
;; mgl ships uglPolyF (col, arg 4 of 4, integer vertices) and uglPolyTP
;; (srcDC, arg 5 of 5, float vertices) as separate entries with different
;; arities, and never overloads a slot. One entry is the point here, so
;; the slot is overloaded instead -- with the cost that a Surface pointer
;; handed in with QGL_M_FLAT paints with its offset as a colour index and
;; nothing says so.
;;
;; -1 rather than 0 for a refusal because 0 is a legal answer -- a face
;; clipped entirely away covers no scanlines and is not a fault. The
;; renderer counts the two separately (d_faces.c's qgl_drop).
;;::::::::::::::
qglRsPoly     proc    public uses bx cx dx si di ds es,\
                        d:dword, v:dword, n:word,\
                        mode:word, src:dword

                local   cnt:word, fillp:word, persp:word
                local   srcp:dword, ringp:dword
                local   bestv:real4, curv:real4
                local   vstep:word, vbase:word
                local   cy0:dword

                mov     ax, @data
                mov     fs, ax                  ;; DGROUP, for every filler
                mov     W fs:qgl_zrow_pg, 0FFFFh
                CYLAP   -1

                les     bx, d
                mov     ax, es
                or      ax, bx
                jz      @@bad                   ;; no destination, no draw

                mov     ax, n
                mov     cnt, ax
                cmp     ax, 3
                jb      @@bad
                cmp     ax, QGL_MAXV
                ja      @@bad

                mov     ax, mode
                cmp     ax, QGL_M_ATEX
                ja      @@bad
                mov     qgl$mode, ax

                ;; DEPTH COMES OFF THE DESTINATION, both of it. es:bx
                ;; still points at d from the null test above.
                ;;
                ;; A mode without a buffer is no depth at all, and saying
                ;; so once here saves the fillers a null test per pixel.
                mov     ax, W es:[bx].Surface.zsf+0
                mov     dx, W es:[bx].Surface.zsf+2
                mov     W qgl$zsf+0, ax
                mov     W qgl$zsf+2, dx
                or      ax, dx
                mov     ax, QGL_Z_OFF
                jz      @F
                mov     ax, es:[bx].Surface.zmode
                cmp     ax, QGL_Z_TEST
                jbe     @F
                mov     ax, QGL_Z_OFF
@@:             mov     qgl$zmode, ax

                ;; the texture, or the flat colour: one argument slot, read
                ;; as whichever the mode says. The map lands here and is
                ;; read by the fillers below, inside this same call.
                cmp     qgl$mode, QGL_M_TEX
                jb      @@flatcol
                invoke  qgl$SetTex, src
                test    ax, ax
                jz      @@bad
                jmp     @@havesrc
                ;; A FLAT POLYGON STILL HAS GRADIENTS. qgl$Grad scales u
                ;; and v by the texture size whatever the mode is, and
                ;; without these two the scale would be the LAST TEXTURED
                ;; CALL'S -- cross-call state of exactly the kind this
                ;; entry exists to remove, and one that can refuse the
                ;; polygon outright: GRADCHK measures the scaled number
                ;; against qgl$2gb and qgl$Grad answers CF, which reads as
                ;; a face that covered no scanlines. 1 leaves u and v
                ;; alone, which is what a mode that never samples wants.
                ;;
                ;; qgl$tseg is deliberately NOT set here. Every mode runs
                ;; `mov ds, qgl$tseg` before calling the filler, and the
                ;; flat and wire fillers read fs:qgl$fcol and never
                ;; dereference ds. Do not give a flat filler a ds read.
@@flatcol:      mov     ax, word ptr src
                mov     qgl$fcol, ax
                mov     D qgl$twhole, 1
                mov     D qgl$thwhole, 1
@@havesrc:      CYLAP   0

                ;; whether this is the filler that wants the FPU triple,
                ;; decided once rather than tested per scanline. The mode
                ;; cannot change inside a polygon, and the converter
                ;; below is picked off the same answer.
                xor     ax, ax
                cmp     qgl$mode, QGL_M_PTEX
                je      @@persp
                cmp     qgl$mode, QGL_M_ATEX
                jne     @F
@@persp:
                inc     ax
@@:             mov     persp, ax

                ;;
                ;; THE GRADIENT TRIPLE, mgl's search (uglPolyTP). Gradients
                ;; come off three vertices of this face, and any
                ;; non-degenerate triple of a planar polygon gives the same
                ;; answer -- but not with the same conditioning. Picking a
                ;; fixed 0, n/3, 2n/3 looks spread out and is not: n/3 is an
                ;; integer divide, so a quad and a pentagon both collapse to
                ;; 0,1,2 -- consecutive vertices, which on a bsp face are
                ;; regularly collinear (t-junctions, merged edges). The
                ;; denominator then reads as degenerate and the whole face is
                ;; dropped; measured on dm3ish, 16 of 200 faces went that way.
                ;;
                ;; So search instead, in two O(n) passes: the vertex furthest
                ;; from vtx[0] (L1, no sqrt needed to rank), then the vertex
                ;; furthest off that baseline. That is the widest triangle the
                ;; face has to offer, give or take. The three are then sorted
                ;; by ring index, because the denominator's sign is what
                ;; decides the winding below and only increasing indices
                ;; carry it.
                ;;
                les     bx, v                   ;; es:bx-> vtx[0], vertex A
                mov     vbase, bx

                mov     si, bx
                add     si, T QVert             ;; si-> B, default vtx[1]
                mov     di, si
                mov     cx, cnt
                dec     cx
                mov     D bestv, 0              ;; 0.0

@@far_loop:     fld     es:[di].QVert.vx
                fsub    es:[bx].QVert.vx
                fabs
                fld     es:[di].QVert.vy
                fsub    es:[bx].QVert.vy
                fabs
                faddp   st(1), st(0)            ;; |dx| + |dy|
                fstp    curv
                fld     curv
                fcomp   bestv
                FJLE    @F
                mov     eax, curv
                mov     bestv, eax
                mov     si, di
@@:             add     di, T QVert
                loop    @@far_loop

                mov     dx, bx
                add     dx, T QVert*2           ;; dx-> C, default vtx[2]
                mov     di, bx
                add     di, T QVert
                mov     cx, cnt
                dec     cx
                mov     D bestv, 0

@@wide_loop:    cmp     di, si                  ;; C must not be B
                je      @@wide_next
                fld     es:[bx].QVert.vx
                fsub    es:[si].QVert.vx
                fld     es:[si].QVert.vy
                fsub    es:[di].QVert.vy
                fmulp   st(1), st(0)
                fld     es:[si].QVert.vx
                fsub    es:[di].QVert.vx
                fld     es:[bx].QVert.vy
                fsub    es:[si].QVert.vy
                fmulp   st(1), st(0)
                fsubp   st(1), st(0)            ;; cross( A, B, C )
                fabs
                fstp    curv
                fld     curv
                fcomp   bestv
                FJLE    @@wide_next
                mov     eax, curv
                mov     bestv, eax
                mov     dx, di
@@wide_next:    add     di, T QVert
                loop    @@wide_loop

                ;; sort B and C by ring index so the denominator's sign
                ;; still reports the ring's winding
                mov     ax, dx
                cmp     si, ax
                jbe     @F
                xchg    si, ax
@@:             mov     di, ax

                call    qgl$Grad                ;; st(0)= denom, kept
                jc      @@done

                ;;
                ;; winding + degeneracy, mgl's POLY_CULL: |denom| < 2 is
                ;; too small to matter (denom is twice the signed area),
                ;; denom > 0 is CW. A CCW ring is corrected by walking it
                ;; backwards rather than by swapping vertices, which an
                ;; N-gon cannot do -- and it has to be corrected, because
                ;; the scan below splits a LEFT chain and a RIGHT chain at
                ;; the topmost vertex and a CCW ring puts them the wrong
                ;; way round.
                ;;
                fld     st(0)
                fabs
                fcomp   qgl$l1sqr
                FJGE    @F
                fstp    st(0)                   ;; pop denom
                jmp     @@done

@@:             mov     vstep, T QVert          ;; assume CW
                ftst
                FJG     @F
                mov     vstep, -T QVert         ;; CCW, walk the other way
@@:             fstp    st(0)                   ;; pop denom

                ;;
                ;; the topmost vertex starts the ring walk -- the chains
                ;; below split there.
                ;;
                les     bx, v
                mov     si, bx                  ;; si= best so far
                mov     di, bx
                add     di, T QVert
                mov     cx, cnt
                dec     cx

@@top_loop:     fld     es:[di].QVert.vy
                fcomp   es:[si].QVert.vy
                FJGE    @F                      ;; vtx[i].y >= best? keep
                mov     si, di
@@:             add     di, T QVert
                loop    @@top_loop
                CYLAP   1

                ;;
                ;; CLIP, walking the ring from the topmost vertex in the
                ;; winding direction the denominator reported -- mgl's
                ;; SH_INIT_poly arguments, and no copy of the polygon
                ;; anywhere to hold the reordering.
                ;;
                ;; It clips against the destination itself. The fillers do
                ;; not test a bound -- their whole job is to fill as fast
                ;; as the loop allows -- so nothing may reach them that
                ;; does not fit. Its place in the order is mgl's: AFTER
                ;; the gradients, which are the unclipped polygon's.
                ;;
                mov     ax, O qgl$src
                mov     W srcp, ax
                mov     ax, ds
                mov     W srcp+2, ax
                mov     ax, si                  ;; the topmost vertex
                mov     W ringp, ax
                mov     ax, es
                mov     W ringp+2, ax
                invoke  qglClPolyEx, ringp, cnt, srcp, d, vbase, vstep
                cmp     ax, 3
                jl      @@done                  ;; not a polygon any more
                mov     cnt, ax
                CYLAP   2

                call    qgl$Fixup               ;; ONCE per polygon

                ;; and into the walk's form, through the converter this
                ;; mode wants -- mgl has two, and the difference is a half
                ;; pixel on x and y
                mov     si, O qgl$src
                mov     di, O qgl$fx
                mov     cx, cnt
                cmp     persp, 0
                jne     @@convp

@@conv:         call    qgl$F2fxA
                add     si, T QVert
                add     di, T QVertFx
                loop    @@conv
                jmp     short @@convd

@@convp:        call    qgl$F2fxP
                add     si, T QVert
                add     di, T QVertFx
                loop    @@convp

@@convd:        ;; the filler, ONCE per polygon
                call    b8_span
                mov     fillp, ax

                ;;
                ;; The two chains split at qgl$fx[0], so that vertex has to
                ;; be the topmost one or they never converge and the scan
                ;; does not terminate. Clipping can leave the topmost at any
                ;; index, so find it and rotate it to the front in place, as
                ;; three reversals -- mgl's uglPolyTP.
                ;;
                mov     bx, O qgl$fx            ;; bx-> best so far
                mov     di, bx
                add     di, T QVertFx
                mov     cx, cnt
                dec     cx
                jcxz    @@rot_done

@@find_top:     mov     eax, [di].QVertFx.ky
                cmp     eax, [bx].QVertFx.ky
                jge     @F
                mov     bx, di                  ;; strictly higher, take it
@@:             add     di, T QVertFx
                loop    @@find_top

                mov     ax, O qgl$fx
                sub     bx, ax                  ;; bx= k, in bytes
                jz      @@rot_done              ;; already at the front

                mov     dx, cnt
                dec     dx
                imul    dx, T QVertFx
                add     dx, ax                  ;; dx-> qgl$fx[n-1]

                ;; reverse [0 .. k-1]
                mov     si, ax
                mov     di, ax
                add     di, bx
                sub     di, T QVertFx
                call    qgl$Rev

                ;; reverse [k .. n-1]
                mov     si, ax
                add     si, bx
                mov     di, dx
                call    qgl$Rev

                ;; reverse the whole run -- now rotated left by k
                mov     si, ax
                mov     di, dx
                call    qgl$Rev

                ;; ONE arm or the OTHER, and this is the split mgl has:
                ;; uglPolyT ends in drawPoly_t2d, uglPolyTP in
                ;; drawPoly_tp2d, and they differ in how u and v are
                ;; carried down an edge.
@@rot_done:     CYLAP   3
                cmp     persp, 0
                jne     @@drawp
                invoke  qgl$drawA, d, cnt, fillp
                jmp     short @@scanned
@@drawp:        invoke  qgl$drawP, d, cnt, fillp
@@scanned:      push    ax
                CYLAP   4
                inc     D fs:qgl_cy+5*4
                pop     ax
                ret

@@done:         xor     ax, ax
                ret
@@bad:          mov     ax, -1
                ret
qglRsPoly     endp

;; qglPrfTake ( k ) -> dx:ax = qgl_cy[k], which is then zeroed
;;::::::::::::::
;; qglRsCoverClear -- forget every row, and switch the skip on. Once at
;; the top of a front-to-back pass.
;;
;; qglRsCover ( on ) -- whether the polygons that follow take part.
;; SEPARATE from the clear on purpose: a pass turns it off for the
;; polygons it cannot vouch for -- a brush entity, whose place in the
;; order is an approximation and not the tree's own answer -- and back on
;; afterwards, and neither may lose what the world has already claimed.
;;
;; Only the perspective scan reads it, which is the world: a model is
;; drawn after the world and IN FRONT of parts of it, and coverage
;; cannot tell those apart -- depth can, and does.
;;::::::::::::::
qglRsCoverClear proc    public uses ax cx di es
                push    ds
                pop     es
                cld
                xor     ax, ax
                mov     di, O qgl_cov_lo        ;; two clears, not one over
                mov     cx, QGL_COV_ROWS        ;; both: nothing declares
                rep     stosw                   ;; them adjacent
                mov     di, O qgl_cov_hi
                mov     cx, QGL_COV_ROWS
                rep     stosw
                mov     qgl_cov_on, 1
                ret
qglRsCoverClear endp

qglRsCover    proc    public uses ax, on:word
                mov     ax, on
                mov     qgl_cov_on, ax
                ret
qglRsCover    endp

qglPrfTake    proc    public uses bx, k:word
                mov     bx, k
                shl     bx, 2
                mov     ax, W qgl_cy[bx]
                mov     dx, W qgl_cy[bx]+2
                mov     D qgl_cy[bx], 0
                ret
qglPrfTake    endp

;;::::::::::::::
;; qgl$drawA -- the scan, AFFINE.
;;
;; mgl's drawPoly_t2d (ugl/uglplxt.asm). u and v are 16.16 texels the whole
;; way down an edge and the filler adds a constant per pixel, which is what
;; makes the affine path affine.
;;::::::::::::::
qgl$drawA       proc    near private,\
                        d:dword, cnt:word, fillp:word

                local   lines:word, yy:word, ycnt:word
                local   rowo:word, rows:word, zsegv:word
                local   pfrac:dword
                local   lf_s:word, lf_e:word, rg_s:word, rg_e:word
                local   rg_lim:word
                local   lf_hgt:word, rg_hgt:word, height:word
                local   lf_x:dword, lf_dxdy:dword
                local   lf_u:dword, lf_dudy:dword
                local   lf_v:dword, lf_dvdy:dword
                local   rg_x:dword, rg_dxdy:dword
                local   lf_z:real4, lf_dzdy:real4

                mov     lines, 0
                mov     si, O qgl$fx
                lea     ax, [si+T QVertFx*1]
                mov     bx, cnt
                imul    bx, T QVertFx
                lea     bx, [bx+si-T QVertFx*1]
                mov     rg_e, ax
                mov     lf_e, bx
                mov     rg_lim, bx
                mov     lf_s, si
                mov     rg_s, si

                xor     ax, ax
                mov     lf_hgt, ax
                mov     rg_hgt, ax
                mov     height, ax

                mov     si, lf_s
                mov     eax, [si].QVertFx.ky
                FXFLOOR eax
                mov     yy, ax                  ;; the top vertex's line

;;
;; ---- the edge chains -------------------------------------------------
;;
@@while:        mov     ax, height
                sub     lf_hgt, ax
                jg      @@srch_rg
                jl      @@done

@@new_lf:       mov     bx, lf_s
                mov     si, lf_e
                cmp     si, O qgl$fx
                jbe     @@done                  ;; if ( le == 0 ) break

                mov     eax, [si].QVertFx.ky
                mov     ecx, [bx].QVertFx.ky
                FXFLOOR eax
                FXFLOOR ecx
                sub     ax, cx
                mov     lf_hgt, ax


                jl      @@done
                jz      @@lf_next

                mov     ecx, [si].QVertFx.ky
                sub     ecx, [bx].QVertFx.ky
                cmp     ecx, 32768
                jl      @@lf_lt1

                mov     eax, 65536
                FXDIV   eax, ecx
                mov     ecx, eax

                mov     eax, [si].QVertFx.kx
                sub     eax, [bx].QVertFx.kx
                FXMUL   eax, ecx
                mov     lf_dxdy, eax
                mov     eax, [si].QVertFx.ku
                sub     eax, [bx].QVertFx.ku
                FXMUL   eax, ecx
                mov     lf_dudy, eax
                mov     eax, [si].QVertFx.kv
                sub     eax, [bx].QVertFx.kv
                FXMUL   eax, ecx
                mov     lf_dvdy, eax
                jmp     @@lf_dz

@@lf_lt1:       ;; a sub-scanline edge: 16.16 has no room for its own
                ;; reciprocal, so it is taken with 14 bits more
                mov     eax, 65536 shl 14
                cdq
                idiv    ecx
                mov     ecx, eax

                mov     eax, [si].QVertFx.kx
                sub     eax, [bx].QVertFx.kx
                FXMUL14 eax, ecx
                mov     lf_dxdy, eax
                mov     eax, [si].QVertFx.ku
                sub     eax, [bx].QVertFx.ku
                FXMUL14 eax, ecx
                mov     lf_dudy, eax
                mov     eax, [si].QVertFx.kv
                sub     eax, [bx].QVertFx.kv
                FXMUL14 eax, ecx
                mov     lf_dvdy, eax

@@lf_dz:        ;; THE FRACTIONAL HEIGHT, not the row count. mgl divides
                ;; every one of x, u, v and z by 65536/(y_end - y_start)
                ;; taken in 16.16; dividing z alone by FLOOR(y_end) -
                ;; FLOOR(y_start) makes its step disagree with theirs by
                ;; up to a whole row on a short edge, and 1/z is what the
                ;; perspective divide and the depth compare both read.
                ;; lf_hgt > 0 here, so the difference is at least 1 and
                ;; there is no zero to divide by.
                fld     [si].QVertFx.kz
                fsub    [bx].QVertFx.kz         ;; dz
                fld     qgl$65536
                fild    D [si].QVertFx.ky
                fisub   D [bx].QVertFx.ky
                fdivp   st(1), st(0)            ;; 1/hgt  dz
                fmul                            ;; dz/hgt
                fstp    lf_dzdy

                ;; how far into this scanline the vertex actually sits
                mov     eax, [bx].QVertFx.ky
                mov     ecx, 65536
                and     eax, 0000FFFFh
                sub     ecx, eax

                FXMUL   ecx, lf_dxdy
                add     eax, [bx].QVertFx.kx
                mov     lf_x, eax
                FXMUL   ecx, lf_dudy
                add     eax, [bx].QVertFx.ku
                mov     lf_u, eax
                FXMUL   ecx, lf_dvdy
                add     eax, [bx].QVertFx.kv
                mov     lf_v, eax

                ;; and z with it. mgl corrects it too (drawPoly_tp2d,
                ;; `lf_z = vtx[ls].z + diff*lf_dzdy`) and it is not only
                ;; depth that reads it: 1/z is what the perspective
                ;; filler DIVIDES BY, so a fraction of a scanline left
                ;; out here is a texture error as well as a depth one.
                ;; ecx still holds the 16.16 fraction -- FXMUL takes it
                ;; as the multiplier and does not write it.
                mov     D pfrac, ecx
                fild    D pfrac
                fmul    qgl$r65536
                fmul    lf_dzdy
                fadd    [bx].QVertFx.kz
                fstp    lf_z

@@lf_next:      mov     lf_s, si
                sub     si, T QVertFx
                mov     lf_e, si

@@srch_rg:      mov     ax, height
                sub     rg_hgt, ax
                jg      @@prep
                jl      @@done

@@new_rg:       mov     bx, rg_s
                mov     si, rg_e
                ;; The left chain stops when it walks down onto vtx[0]; the
                ;; right needs the mirror of that, or re steps to vtx[n] and
                ;; reads whatever followed the array.
                cmp     si, rg_lim
                ja      @@done                  ;; if ( re > n-1 ) break

                mov     eax, [si].QVertFx.ky
                mov     ecx, [bx].QVertFx.ky
                FXFLOOR eax
                FXFLOOR ecx
                sub     ax, cx
                mov     rg_hgt, ax
                jl      @@done
                jz      @@rg_next

                mov     ecx, [si].QVertFx.ky
                sub     ecx, [bx].QVertFx.ky
                cmp     ecx, 32768
                jl      @@rg_lt1

                mov     eax, 65536
                FXDIV   eax, ecx
                mov     ecx, eax
                mov     eax, [si].QVertFx.kx
                sub     eax, [bx].QVertFx.kx
                FXMUL   eax, ecx
                mov     rg_dxdy, eax
                jmp     short @@rg_sub

@@rg_lt1:       mov     eax, 65536 shl 14
                cdq
                idiv    ecx
                mov     ecx, eax
                mov     eax, [si].QVertFx.kx
                sub     eax, [bx].QVertFx.kx
                FXMUL14 eax, ecx
                mov     rg_dxdy, eax

@@rg_sub:       mov     eax, [bx].QVertFx.ky
                mov     ecx, 65536
                and     eax, 0000FFFFh
                sub     ecx, eax
                FXMUL   ecx, rg_dxdy
                add     eax, [bx].QVertFx.kx
                mov     rg_x, eax

@@rg_next:      mov     rg_s, si
                add     rg_e, T QVertFx

@@prep:         mov     ax, lf_hgt
                cmp     ax, rg_hgt
                jle     @F
                mov     ax, rg_hgt
@@:             mov     height, ax
                test    ax, ax
                jle     @@while
                mov     ycnt, ax

;;
;; ---- one scanline ----------------------------------------------------
;;
@@outer:        WRROW   d, yy, <invoke qglSfWrRow, d, yy>
                mov     rowo, ax
                mov     rows, dx
                mov     zsegv, dx               ;; harmless when depth is off

                cmp     qgl$zmode, QGL_Z_OFF
                je      @@nodepth
                WRROW   qgl$zsf, yy, <ZEMSROW qgl$zsf, yy, QGL_Z_SLOT>
                mov     qgl$zline, ax
                mov     zsegv, dx

                ;; a qword landing pad: depth runs to 65535 and the
                ;; accumulator is 16.16, so the product passes what a
                ;; SIGNED dword fistp can hold
                ;;
                ;; AND THE 65536 IS WHAT MAKES IT 16.16. qgl$zdzdx already
                ;; carries one -- qgl$Grad's rdenom is 65536/denom -- so
                ;; without it here the span STARTS 65536 times too small
                ;; and steps at the right rate from there: every depth the
                ;; filler stored was the integer half of a value that never
                ;; reached one, i.e. 0, and QGL_Z_TEST compared 0 against 0
                ;; on every pixel of the frame. Nothing was ever hidden and
                ;; nothing was ever shown; which faces that spoiled moved
                ;; with the draw order, so it read as wandering dark
                ;; streaks. qgl$zscale stays what its callers document it
                ;; to be: the depth at 1/z = 1.
                fld     lf_z
                fmul    D qgl$zscale
                fmul    qgl$65536
                fistp   qgl$ztmp
                mov     eax, D qgl$ztmp
                mov     qgl$zacc, eax

@@nodepth:      ;; sub-texel: u and v at the CENTRE of the first whole
                ;; pixel the span covers, not at its left edge
                mov     eax, lf_x
                and     eax, 0FFFFh
                mov     edi, 65536
                sub     edi, eax

                FXMUL   edi, qgl$dudx
                mov     ecx, lf_u
                add     ecx, 32768
                add     ecx, eax
                FXMUL   edi, qgl$dvdx
                mov     edx, lf_v
                add     edx, 32768
                add     edx, eax


                mov     eax, lf_x
                FXFLOOR eax
                mov     esi, rg_x
                FXFLOOR esi
                sub     si, ax
                jle     @@advance               ;; the edges have crossed

                mov     bx, fillp
                mov     di, rowo
                mov     es, rows
                mov     gs, zsegv

                ;; ds is DGROUP for the walk -- qglSfRow above reaches
                ;; its own dispatch table through it -- and the texture
                ;; for the filler. Two instructions a scanline against a
                ;; table of row addresses that an EMS destination would
                ;; invalidate the moment its window moved.
                FILLCALL 6

                inc     lines

@@advance:      mov     eax, lf_dxdy
                add     lf_x, eax
                mov     eax, lf_dudy
                add     lf_u, eax
                mov     eax, lf_dvdy
                add     lf_v, eax
                mov     eax, rg_dxdy
                add     rg_x, eax

                fld     lf_z
                fadd    lf_dzdy
                fstp    lf_z

                inc     yy
                dec     ycnt
                jnz     @@outer
                jmp     @@while

@@done:         mov     ax, lines
                ret
qgl$drawA       endp

;;::::::::::::::
;; qgl$drawP -- the scan, PERSPECTIVE.
;;
;; mgl's drawPoly_tp2d (ugl/uglplxtp.asm), and the one thing that makes it
;; a separate proc rather than a flag: u and v are real4 the whole way down
;; an edge. They are u/z and v/z here, the filler divides them, and 16.16
;; truncates u/z differently at every depth -- so the affine arm's fixed
;; point is not a representation this path may borrow.
;;::::::::::::::
qgl$drawP       proc    near private,\
                        d:dword, cnt:word, fillp:word

                local   lines:word, yy:word, ycnt:word
                local   rowo:word, rows:word, zsegv:word
                local   pfrac:dword
                local   lf_s:word, lf_e:word, rg_s:word, rg_e:word
                local   rg_lim:word
                local   lf_hgt:word, rg_hgt:word, height:word
                local   lf_x:dword, lf_dxdy:dword
                local   lf_u:real4, lf_dudy:real4
                local   lf_v:real4, lf_dvdy:real4
                local   rg_x:dword, rg_dxdy:dword
                local   lf_z:real4, lf_dzdy:real4
                local   cov_x0:word, cov_x1:word

                mov     lines, 0
                mov     si, O qgl$fx
                lea     ax, [si+T QVertFx*1]
                mov     bx, cnt
                imul    bx, T QVertFx
                lea     bx, [bx+si-T QVertFx*1]
                mov     rg_e, ax
                mov     lf_e, bx
                mov     rg_lim, bx
                mov     lf_s, si
                mov     rg_s, si

                xor     ax, ax
                mov     lf_hgt, ax
                mov     rg_hgt, ax
                mov     height, ax

                mov     si, lf_s
                mov     eax, [si].QVertFx.ky
                FXFLOOR eax
                mov     yy, ax                  ;; the top vertex's line

;;
;; ---- the edge chains -------------------------------------------------
;;
@@while:        mov     ax, height
                sub     lf_hgt, ax
                jg      @@srch_rg
                jl      @@done

@@new_lf:       mov     bx, lf_s
                mov     si, lf_e
                cmp     si, O qgl$fx
                jbe     @@done                  ;; if ( le == 0 ) break

                mov     eax, [si].QVertFx.ky
                mov     ecx, [bx].QVertFx.ky
                FXFLOOR eax
                FXFLOOR ecx
                sub     ax, cx
                mov     lf_hgt, ax
                jl      @@done
                jz      @@lf_next

                ;; ONE reciprocal of the FRACTIONAL height serves u, v and
                ;; z alike, which is mgl's arrangement and the reason the
                ;; three steps agree with each other. Pushed before the
                ;; sub-scanline branch because both arms of it want it.
                fld     qgl$65536
                fild    D [si].QVertFx.ky
                fisub   D [bx].QVertFx.ky
                fdivp   st(1), st(0)            ;; 1/hgt

                mov     ecx, [si].QVertFx.ky
                sub     ecx, [bx].QVertFx.ky
                cmp     ecx, 32768
                jl      @@lf_lt1

                mov     eax, 65536
                FXDIV   eax, ecx
                mov     ecx, eax
                mov     eax, [si].QVertFx.kx
                sub     eax, [bx].QVertFx.kx
                FXMUL   eax, ecx
                mov     lf_dxdy, eax

@@lf_grad:      fld     [si].QVertFx.ku         ;; u' 1/hgt
                fsub    [bx].QVertFx.ku
                fmul    st(0), st(1)            ;; dudy 1/hgt
                fxch    st(1)                   ;; 1/hgt dudy

                fld     [si].QVertFx.kv         ;; v' 1/hgt dudy
                fsub    [bx].QVertFx.kv
                fmul    st(0), st(1)            ;; dvdy 1/hgt dudy
                fxch    st(1)                   ;; 1/hgt dvdy dudy

                fld     [si].QVertFx.kz         ;; z' 1/hgt dvdy dudy
                fsub    [bx].QVertFx.kz
                fmulp   st(1), st(0)            ;; dzdy dvdy dudy
                fxch    st(2)                   ;; dudy dvdy dzdy

                fstp    lf_dudy
                fstp    lf_dvdy
                fstp    lf_dzdy

                ;; how far into this scanline the vertex actually sits --
                ;; x in fixed point, u, v and z on the FPU beside it
                mov     eax, [bx].QVertFx.ky
                mov     ecx, 65536
                and     eax, 0000FFFFh
                sub     ecx, eax
                mov     D pfrac, ecx

                FXMUL   ecx, lf_dxdy
                add     eax, [bx].QVertFx.kx
                mov     lf_x, eax

                fild    D pfrac
                fmul    qgl$r65536              ;; diff

                fld     lf_dudy                 ;; dudy diff
                fmul    st(0), st(1)
                fadd    [bx].QVertFx.ku         ;; lf_u diff
                fxch    st(1)                   ;; diff lf_u

                fld     lf_dvdy                 ;; dvdy diff lf_u
                fmul    st(0), st(1)
                fadd    [bx].QVertFx.kv         ;; lf_v diff lf_u
                fxch    st(1)                   ;; diff lf_v lf_u

                fld     lf_dzdy                 ;; dzdy diff lf_v lf_u
                fmulp   st(1), st(0)            ;; dzdy lf_v lf_u
                fadd    [bx].QVertFx.kz         ;; lf_z lf_v lf_u
                fxch    st(2)                   ;; lf_u lf_v lf_z

                fstp    lf_u
                fstp    lf_v
                fstp    lf_z

@@lf_next:      mov     lf_s, si
                sub     si, T QVertFx
                mov     lf_e, si
                jmp     short @@srch_rg

@@lf_lt1:       ;; a sub-scanline edge: 16.16 has no room for its own
                ;; reciprocal, so x is taken with 14 bits more. u, v and z
                ;; do not care -- they are floats and go on to @@lf_grad.
                mov     eax, 65536 shl 14
                cdq
                idiv    ecx
                mov     ecx, eax
                mov     eax, [si].QVertFx.kx
                sub     eax, [bx].QVertFx.kx
                FXMUL14 eax, ecx
                mov     lf_dxdy, eax
                jmp     @@lf_grad

@@srch_rg:      mov     ax, height
                sub     rg_hgt, ax
                jg      @@prep
                jl      @@done

@@new_rg:       mov     bx, rg_s
                mov     si, rg_e
                ;; The left chain stops when it walks down onto vtx[0]; the
                ;; right needs the mirror of that, or re steps to vtx[n] and
                ;; reads whatever followed the array.
                cmp     si, rg_lim
                ja      @@done                  ;; if ( re > n-1 ) break

                mov     eax, [si].QVertFx.ky
                mov     ecx, [bx].QVertFx.ky
                FXFLOOR eax
                FXFLOOR ecx
                sub     ax, cx
                mov     rg_hgt, ax
                jl      @@done
                jz      @@rg_next

                mov     ecx, [si].QVertFx.ky
                sub     ecx, [bx].QVertFx.ky
                cmp     ecx, 32768
                jl      @@rg_lt1

                mov     eax, 65536
                FXDIV   eax, ecx
                mov     ecx, eax
                mov     eax, [si].QVertFx.kx
                sub     eax, [bx].QVertFx.kx
                FXMUL   eax, ecx
                mov     rg_dxdy, eax
                jmp     short @@rg_sub

@@rg_lt1:       mov     eax, 65536 shl 14
                cdq
                idiv    ecx
                mov     ecx, eax
                mov     eax, [si].QVertFx.kx
                sub     eax, [bx].QVertFx.kx
                FXMUL14 eax, ecx
                mov     rg_dxdy, eax

@@rg_sub:       mov     eax, [bx].QVertFx.ky
                mov     ecx, 65536
                and     eax, 0000FFFFh
                sub     ecx, eax
                FXMUL   ecx, rg_dxdy
                add     eax, [bx].QVertFx.kx
                mov     rg_x, eax

@@rg_next:      mov     rg_s, si
                add     rg_e, T QVertFx

@@prep:         mov     ax, lf_hgt
                cmp     ax, rg_hgt
                jle     @F
                mov     ax, rg_hgt
@@:             mov     height, ax
                test    ax, ax
                jle     @@while
                mov     ycnt, ax

;;
;; ---- one scanline ----------------------------------------------------
;;
@@outer:        WRROW   d, yy, <invoke qglSfWrRow, d, yy>
                mov     rowo, ax
                mov     rows, dx
                mov     zsegv, dx               ;; harmless when depth is off

                cmp     qgl$zmode, QGL_Z_OFF
                je      @@nodepth
                WRROW   qgl$zsf, yy, <ZEMSROW qgl$zsf, yy, QGL_Z_SLOT>
                mov     qgl$zline, ax
                mov     zsegv, dx

                ;; a qword landing pad: depth runs to 65535 and the
                ;; accumulator is 16.16, so the product passes what a
                ;; SIGNED dword fistp can hold
                ;;
                ;; AND THE 65536 IS WHAT MAKES IT 16.16. qgl$zdzdx already
                ;; carries one -- qgl$Grad's rdenom is 65536/denom -- so
                ;; without it here the span STARTS 65536 times too small
                ;; and steps at the right rate from there: every depth the
                ;; filler stored was the integer half of a value that never
                ;; reached one, i.e. 0, and QGL_Z_TEST compared 0 against 0
                ;; on every pixel of the frame. Nothing was ever hidden and
                ;; nothing was ever shown; which faces that spoiled moved
                ;; with the draw order, so it read as wandering dark
                ;; streaks. qgl$zscale stays what its callers document it
                ;; to be: the depth at 1/z = 1.
                fld     lf_z
                fmul    D qgl$zscale
                fmul    qgl$65536
                fistp   qgl$ztmp
                mov     eax, D qgl$ztmp
                mov     qgl$zacc, eax

@@nodepth:      mov     eax, lf_x
                and     eax, 0FFFFh
                mov     edi, 65536
                sub     edi, eax
                mov     pfrac, edi

                mov     eax, lf_x
                FXFLOOR eax
                mov     esi, rg_x
                FXFLOOR esi
                sub     si, ax
                jle     @@advance               ;; the edges have crossed

                ;;
                ;; WHAT THIS ROW ALREADY COVERS comes off the front of the
                ;; span, or off its back. A covered MIDDLE is left alone:
                ;; splitting the span would need a list per row, and depth
                ;; is what keeps that case right anyway.
                ;;
                ;; TRIMMING THE FRONT MOVES A FEW PIXELS BY A TEXEL, and
                ;; that is this trim's whole cost, measured: the filler
                ;; re-divides every QGL_SUBDIVP pixels, so a span that
                ;; starts k pixels later restarts that phase elsewhere and
                ;; interpolates between different divides. e1m6 unlit, 600
                ;; ticks: back trim alone is BYTE-IDENTICAL to no coverage
                ;; at all, which is what says the bookkeeping below is
                ;; right; both trims move 6 pixels of 16,000 and save a
                ;; further 1.7ms of 44.6.
                ;;
                cmp     qgl_cov_on, 0
                je      @@cov_none
                mov     bx, yy
                add     bx, bx
                cmp     bx, QGL_COV_ROWS * 2
                jae     @@cov_none              ;; past the table: no claim
                mov     cx, qgl_cov_lo[bx]
                mov     dx, qgl_cov_hi[bx]
                mov     di, ax
                add     di, si                  ;; di= x1
                mov     cov_x0, ax
                mov     cov_x1, di
                cmp     cx, dx
                jge     @@cov_take              ;; nothing covered here yet

                cmp     ax, cx                  ;; x0 inside [lo,hi)?
                jl      @@cov_r
                cmp     ax, dx
                jge     @@cov_r
                mov     ax, dx
@@cov_r:        cmp     di, dx                  ;; x1 inside?
                jg      @@cov_u
                cmp     di, cx
                jle     @@cov_u
                mov     di, cx

                ;; the union where the two touch; where they do not, the
                ;; wider of them and the other forgotten
@@cov_u:        mov     si, cov_x1
                cmp     si, cx
                jl      @@cov_apart
                mov     si, cov_x0
                cmp     si, dx
                jg      @@cov_apart
                cmp     si, cx
                jge     @F
                mov     qgl_cov_lo[bx], si
@@:             mov     si, cov_x1
                cmp     si, dx
                jle     @F
                mov     qgl_cov_hi[bx], si
@@:             jmp     short @@cov_trim

@@cov_apart:    mov     si, cov_x1
                sub     si, cov_x0
                push    ax
                mov     ax, dx
                sub     ax, cx
                cmp     si, ax
                pop     ax
                jle     @@cov_trim              ;; the old one is wider

@@cov_take:     mov     si, cov_x0
                mov     qgl_cov_lo[bx], si
                mov     si, cov_x1
                mov     qgl_cov_hi[bx], si

@@cov_trim:     mov     si, di
                sub     si, ax
                jle     @@advance               ;; the row had all of it
                mov     di, ax
                sub     di, cov_x0              ;; di= pixels cut off the front
                jz      @@cov_none
                push    ax
                movzx   eax, di                 ;; the sub-pixel offset the
                shl     eax, 16                 ;; setup below carries takes
                add     pfrac, eax              ;; whole pixels too
                cmp     qgl$zmode, QGL_Z_OFF
                je      @F
                movzx   eax, di
                imul    eax, qgl$zdzdx
                add     qgl$zacc, eax
@@:             pop     ax
@@cov_none:

                ;; u/z, v/z and 1/z at the first pixel centre, in the order
                ;; the filler reads them: st(0) u', st(1) v', st(2) z'.
                ;; Pushed here and not earlier because the skip above takes
                ;; the values with it -- b8/'s filler pops them, where mgl's
                ;; leaves them for an unconditional three fstp after the
                ;; call.
                ;;
                ;; NO HALF TEXEL HERE. mgl adds 0.5*z to u and v at this
                ;; point (uglplxtp.asm), and the divide turns that into
                ;; 0.5*z(x)/z(start): half a texel at the span's left and
                ;; two texels where 1/z has fallen to a quarter. The filler
                ;; adds a flat half after each divide instead (PDIV);
                ;; qgldiff reads that a texel closer to the exact answer.
                fld     lf_z                    ;; z
                fld     lf_v                    ;; v z
                fld     lf_u                    ;; u v z

                fild    D pfrac                 ;; fxdiff u v z
                fmul    qgl$r65536              ;; diff u v z

                fld     qgl$fdudx               ;; dudx diff u v z
                fmul    st(0), st(1)
                faddp   st(2), st(0)            ;; diff u' v z

                fld     qgl$fdvdx               ;; dvdx diff u' v z
                fmul    st(0), st(1)
                faddp   st(3), st(0)            ;; diff u' v' z

                fld     qgl$fdzdx               ;; dzdx diff u' v' z
                fmulp   st(1), st(0)            ;; dzdx*diff u' v' z
                faddp   st(3), st(0)            ;; u' v' z'

                mov     bx, fillp
                mov     di, rowo
                mov     es, rows
                mov     gs, zsegv

                ;; ds is DGROUP for the walk -- qglSfRow above reaches its
                ;; own dispatch table through it -- and the texture for the
                ;; filler.
                FILLCALL 8

                inc     lines

@@advance:      mov     eax, lf_dxdy
                add     lf_x, eax
                mov     eax, rg_dxdy
                add     rg_x, eax

                fld     lf_u                    ;; u'
                fadd    lf_dudy
                fld     lf_v                    ;; v' u'
                fadd    lf_dvdy
                fld     lf_z                    ;; z' v' u'
                fadd    lf_dzdy
                fxch    st(2)                   ;; u' v' z'
                fstp    lf_u
                fstp    lf_v
                fstp    lf_z

                inc     yy
                dec     ycnt
                jnz     @@outer
                jmp     @@while

@@done:         mov     ax, lines
                ret
qgl$drawP       endp




                

                QGL_ENDS
                end
