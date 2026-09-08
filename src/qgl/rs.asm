;;
;; rs.asm -- the convex scanner. The pixels are b8/'s.
;;
;; name: qglRsTex / qglRsFlat / qglRsMode / qglRsPoly
;; desc: two edge chains walk down from the topmost vertex and hand one
;;       span per scanline to a filler. The scanner is the same code for
;;       every mode; only the filler differs, and b8_span decides which
;;       ONCE per polygon.
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
;;       - u and v are 16.16 in TEXELS, scaled by the texture's width so
;;         one repeat spans it.
;;       - 1/z is a float. It is compared, never sampled, so it has no
;;         business in the same fixed point as a texture coordinate.
;;

                .model  medium, pascal
                .386
                option  proc:private

                include qgl.inc

qglSfRdRow   proto   far pascal :dword, :word
qglClPolyEx   proto   far pascal :dword, :word, :dword, :dword, :word, :word
qglSfWrRow   proto   far pascal :dword, :word
qglSfWrRowEx proto  far pascal :dword, :word, :word

;; sf.asm's own numbers, restated here rather than shared: gem.asm defines
;; the same pair independently too, on purpose (its own header: "removes a
;; dependency"), and this module already reaches qgl.inc for everything
;; else, so a third independent copy is the established pattern, not a new
;; one.
EMS_PAGE_SIZE   equ     4000h
EMS_PAGE_MASK   equ     3FFFh

                externdef qgl$zsf:dword
                externdef qgl$zmode:word
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

;; The same three gradients the perspective filler needs, and they are
;; not the same numbers. It steps u/z, v/z and 1/z -- all three linear in
;; screen space, which is the whole reason the divide can be amortised --
;; and it steps them a sub-span at a time, so these are floats, unscaled,
;; times QGL_SUBDIVP. The fixed-point pair above is what the AFFINE
;; fillers add per pixel and means nothing here.
qgl$fdudxn      real4   0.0
qgl$fdvdxn      real4   0.0
qgl$fdzdxn      real4   0.0
qgl$fdzdx       real4   0.0                     ;; per PIXEL, for the start

                public  qgl$dudx, qgl$dvdx, qgl$fcol, qgl$mode
                public  qgl$fdudxn, qgl$fdvdxn, qgl$fdzdxn
                public  qgl$tshift, qgl$tumsk, qgl$tvmsk, qgl$tofs
                public  qgl$tseg



.data?
qgl$fx          QVertFx QGL_CLIPV dup (<>)
qgl$src         QVert   QGL_CLIPV dup (<>)

qgl$ztmp        dq      ?


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
;; mgl's F2FX_tp2d, and the difference from F2FX_t2d beside it is the
;; whole point of there being two: NO HALF PIXEL ON x AND y. The affine
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
                fmul    qgl$65536
                fistp   D [di].QVertFx.ku

                fild    D qgl$thwhole
                fmul    [si].QVert.vv
                fmul    qgl$65536
                fistp   D [di].QVertFx.kv
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

                ;; fiSTp, like the z store above it. rdenom carries the
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
                fmul    qgl$subdivf
                fstp    qgl$fdudxn
                CHK2GB  @@err3
                fistp   D qgl$dudx

                CALC_NOM vv
                fimul   D qgl$thwhole
                fmul                            ;; the last rdenom
                fld     st(0)
                fmul    qgl$r65536
                fmul    qgl$subdivf
                fstp    qgl$fdvdxn
                CHK2GB  @@err2
                fistp   D qgl$dvdx

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
;; qglRsTex ( t:far ptr Surface ) -> ax nonzero if it took
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
qglRsTex      proc    public uses bx cx dx si di es,\
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
                ;; page, so an EMS one maps here and stays mapped
                invoke  qglSfRdRow, t, 0
                mov     qgl$tofs, ax
                mov     qgl$tseg, dx

                mov     ax, 1
                ret

@@no:           xor     ax, ax
                ret
qglRsTex      endp


;;:::::::::::::: qglRsFlat ( col:word )
qglRsFlat     proc    public uses ax,\
                        col:word
                mov     ax, col
                mov     qgl$fcol, ax
                ret
qglRsFlat     endp


;;:::::::::::::: qglRsMode ( m:word ) -> ax= the mode that was in force
qglRsMode     proc    public uses bx,\
                        m:word

                mov     ax, qgl$mode
                mov     bx, m
                cmp     bx, QGL_M_PTEX
                ja      @F
                mov     qgl$mode, bx
@@:             ret
qglRsMode     endp




;;::::::::::::::
;; qgl$Top -- the index of the topmost vertex of qgl$src.
;;
;;  in: cx= count
;; out: ax= its INDEX
;;
;; An offset, not a rotation. The ring is walked from here with wrap, the
;; way SH_INIT_poly walks one, so no vertex data moves. Rotating the array
;; to put the top first -- which this did -- is an O(n^2) memmove to avoid
;; two compares in the step.
;;::::::::::::::
qgl$Top         proc    near uses bx cx dx si

                local   best:real4

                xor     dx, dx                  ;; the winner's index
                mov     si, O qgl$src
                mov     eax, D [si].QVert.vy
                mov     D best, eax

                mov     bx, 1
@@scan:         dec     cx
                jz      @@done
                mov     si, bx
                imul    si, T QVert
                add     si, O qgl$src
                fld     [si].QVert.vy
                fcomp   best
                fstsw   ax
                sahf
                jae     @F                      ;; not higher up the screen
                mov     eax, D [si].QVert.vy
                mov     D best, eax
                mov     dx, bx
@@:             inc     bx
                jmp     @@scan

@@done:         mov     ax, dx
                ret
qgl$Top         endp


;;::::::::::::::
;; qglRsPoly ( d:far ptr Surface, v:far ptr QVert, n:word ) -> ax
;;
;; Draws one convex polygon and returns the scanlines it covered. The
;; vertices arrive in ring order, in EITHER winding, and vtx[0] need not
;; be the topmost -- mgl's uglPolyTP contract, and this is a transcription
;; of it: search the widest triple, take the gradients off the UNCLIPPED
;; polygon, cull on the denominator's magnitude, take the winding off its
;; sign, and only then clip.
;;::::::::::::::
qglRsPoly     proc    public uses bx cx dx si di ds es,\
                        d:dword, v:dword, n:word

                local   cnt:word, edges:word
                local   li:word, ri:word
                local   lines:word, yy:word, ycnt:word
                local   rowo:word, rows:word, zsegv:word
                local   dsth:word, dstw:word
                local   fillp:word
                local   persp:word
                local   pfrac:dword, pu:dword, pv:dword
                local   lf_s:word, lf_e:word, rg_s:word, rg_e:word
                local   lf_hgt:word, rg_hgt:word, height:word
                local   lf_x:dword, lf_dxdy:dword
                local   lf_u:dword, lf_dudy:dword
                local   lf_v:dword, lf_dvdy:dword
                local   rg_x:dword, rg_dxdy:dword
                local   lf_z:real4, lf_dzdy:real4
                local   srcp:dword, ringp:dword
                local   bestv:real4, curv:real4
                local   vstep:word, vbase:word

                mov     ax, @data
                mov     fs, ax                  ;; DGROUP, for every filler

                mov     lines, 0
                les     bx, d
                mov     ax, es:[bx].Surface.yRes
                mov     dsth, ax                ;; scanlines that exist
                mov     ax, es:[bx].Surface.xRes
                mov     dstw, ax                ;; pixels that exist
                mov     ax, n
                mov     cnt, ax
                cmp     ax, 3
                jb      @@done
                cmp     ax, QGL_MAXV
                ja      @@done

                ;; whether this is the filler that wants the FPU triple,
                ;; decided once rather than tested per scanline. The mode
                ;; cannot change inside a polygon, and the converter
                ;; below is picked off the same answer.
                xor     ax, ax
                cmp     qgl$mode, QGL_M_PTEX
                jne     @F
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
                test    ax, ax
                jz      @@done                  ;; nothing of it survived
                mov     cnt, ax

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

                ;; both chains start at the topmost vertex; the left walks
                ;; backwards around the ring and the right forwards. n
                ;; edges close a ring of n vertices, and the two chains
                ;; between them consume exactly that many.
                mov     cx, cnt
                call    qgl$Top                 ;; ax = the top vertex's INDEX
                mov     li, ax
                mov     ri, ax
                imul    ax, T QVertFx
                add     ax, O qgl$fx
                mov     lf_s, ax
                mov     rg_s, ax
                mov     lf_e, ax
                mov     rg_e, ax
                mov     ax, cnt
                mov     edges, ax

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

@@new_lf:       cmp     edges, 0
                jle     @@done
                dec     edges

                mov     bx, lf_s
                mov     ax, li                  ;; one back around the ring
                test    ax, ax
                jnz     @F
                mov     ax, cnt
@@:             dec     ax
                mov     li, ax
                imul    ax, T QVertFx
                add     ax, O qgl$fx
                mov     lf_e, ax
                mov     si, ax

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

@@lf_next:      mov     ax, lf_e
                mov     lf_s, ax

@@srch_rg:      mov     ax, height
                sub     rg_hgt, ax
                jg      @@prep
                jl      @@done

@@new_rg:       cmp     edges, 0
                jle     @@done
                dec     edges

                mov     bx, rg_s
                mov     ax, ri                  ;; one forward around the ring
                inc     ax
                cmp     ax, cnt
                jb      @F
                xor     ax, ax
@@:             mov     ri, ax
                imul    ax, T QVertFx
                add     ax, O qgl$fx
                mov     rg_e, ax
                mov     si, ax

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

@@rg_next:      mov     ax, rg_e
                mov     rg_s, ax

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
@@outer:        ;; A SCANLINE PAST THE SURFACE IS NOT A SCANLINE. qglSfRow
                ;; answers for any y it is asked about -- the arithmetic
                ;; does not know where the store ends -- so an overrunning
                ;; walk gets a valid pointer into whatever was allocated
                ;; next and writes a picture into it.
                mov     ax, yy
                cmp     ax, dsth
                jae     @@done

                invoke  qglSfWrRow, d, yy
                mov     rowo, ax
                mov     rows, dx
                mov     zsegv, dx               ;; harmless when depth is off

                cmp     qgl$zmode, QGL_Z_OFF
                je      @@nodepth
                invoke  qglSfWrRowEx, qgl$zsf, yy, QGL_Z_SLOT
                mov     qgl$zline, ax
                mov     zsegv, dx

                ;; a qword landing pad: depth runs to 65535 and the
                ;; accumulator is 16.16, so the product passes what a
                ;; SIGNED dword fistp can hold
                fld     lf_z
                fmul    D qgl$zscale
                fistp   qgl$ztmp
                mov     eax, D qgl$ztmp
                mov     qgl$zacc, eax

@@nodepth:      ;; sub-texel: u and v at the CENTRE of the first whole
                ;; pixel the span covers, not at its left edge
                mov     eax, lf_x
                and     eax, 0FFFFh
                mov     edi, 65536
                sub     edi, eax
                mov     pfrac, edi              ;; di is the row before the call

                FXMUL   edi, qgl$dudx
                mov     ecx, lf_u
                add     ecx, 32768
                add     ecx, eax
                FXMUL   edi, qgl$dvdx
                mov     edx, lf_v
                add     edx, 32768
                add     edx, eax

                ;; The perspective filler wants the same point WITHOUT the
                ;; half texel. That 32768 is a round-to-nearest for an
                ;; affine filler that truncates; here the divide comes
                ;; first, so half a texel added to u/z lands as half a
                ;; texel times z -- an error that grows with depth. The
                ;; filler's own fistp rounds instead.
                mov     eax, ecx
                sub     eax, 32768
                mov     pu, eax
                mov     eax, edx
                sub     eax, 32768
                mov     pv, eax

                mov     eax, lf_x
                FXFLOOR eax
                mov     esi, rg_x
                FXFLOOR esi
                sub     si, ax
                jle     @@advance               ;; the edges have crossed

                ;; A SPAN MUST NOT LEAVE ITS ROW. qglClPoly above makes
                ;; that true geometrically, so this cannot fire -- it is
                ;; kept because when it was absent a texture filled with
                ;; 5Ah put 5A5Ah inside a VERTEX of qgl$fx, and the walk
                ;; then read its own wreckage and ran further out of
                ;; range. Two pounds of clamp against that.
                test    ax, ax
                jl      @@advance
                cmp     ax, dstw
                jge     @@advance
                mov     bx, dstw
                sub     bx, ax
                cmp     si, bx
                jle     @F
                mov     si, bx
@@:

                ;; u/z, v/z and 1/z at the first pixel centre, in the
                ;; order the perspective filler reads them: st(0) u',
                ;; st(1) v', st(2) z'. Pushed here and not earlier
                ;; because every path out of the clamp above skips the
                ;; call, and three values left on the FPU stack per
                ;; skipped scanline overflow it in eight.
                cmp     persp, 0
                je      @@affine
                fild    D pfrac
                fmul    qgl$r65536
                fmul    qgl$fdzdx
                fadd    lf_z                    ;; z'
                ;; HALF A TEXEL, on the far side of the divide and paid
                ;; for here: mgl adds 0.5*z to u and v at the span start
                ;; (drawPoly_tp2d, `fld _0_5 / fmul st(0), st(3)`), so
                ;; that once the filler divides by z it is half a texel
                ;; at the span's own depth and follows z across the span.
                ;; Adding a flat 32768 to each sub-span's endpoints
                ;; instead -- which is what the filler used to do -- is
                ;; half a texel everywhere, which is not the same picture.
                fld     qgl$half
                fmul    lf_z                    ;; h  z'
                fild    D pv
                fmul    qgl$r65536
                fadd    st(0), st(1)            ;; v' h  z'
                fild    D pu
                fmul    qgl$r65536
                fadd    st(0), st(2)            ;; u' v' h  z'
                fxch    st(2)                   ;; h  v' u' z'
                fstp    st(0)                   ;; v' u' z'
                fxch    st(1)                   ;; u' v' z'
@@affine:
                mov     bx, fillp
                mov     di, rowo
                mov     es, rows
                mov     gs, zsegv

                ;; ds is DGROUP for the walk -- qglSfRow above reaches
                ;; its own dispatch table through it -- and the texture
                ;; for the filler. Two instructions a scanline against a
                ;; table of row addresses that an EMS destination would
                ;; invalidate the moment its window moved.
                push    ds
                mov     ds, qgl$tseg
                call    bx
                pop     ds

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
qglRsPoly     endp



                

                QGL_ENDS
                end
