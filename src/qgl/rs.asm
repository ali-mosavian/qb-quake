;;
;; rs.asm -- scanline fillers, and the convex scanner that feeds them.
;;
;; name: qgl_rs_tex / qgl_rs_flat / qgl_rs_mode / qgl_rs_ref / qgl_rs_poly
;; desc: two edge chains walk down from the topmost vertex and hand one
;;       span per scanline to a filler. The scanner is the same code for
;;       every mode; only the filler differs.
;;
;;       WHICH FILLER IS DECIDED ONCE PER POLYGON, not per pixel and not
;;       per scanline -- b8_HLineT's arrangement. The mode is baked into
;;       each filler and never tested inside a loop.
;;
;; obs.: - fillers and scanner share a module because qgl has ONE pixel
;;         format. mgl splits cfmt/b8 from ugl/ because it has several and
;;         one scanner over all of them; splitting here would copy the
;;         shape without the reason, and would cost a far call per span.
;;       - fs IS DGROUP in every filler. ds is the texture and es the
;;         destination, so mgl says DGROUP with ss: and thereby assumes
;;         SS == DGROUP -- measured false in this repo's own test harness.
;;       - u and v are 16.16 in TEXELS, scaled by the texture's width so
;;         one repeat spans it. mgl's uglplxtp.asm still scales by
;;         xRes-1; ugl-patch/README.md is about that off-by-one, and the
;;         corrected copies are in ugl-patch/. Do not take the gradient
;;         from mgl/src.
;;       - 1/z is a float. It is compared, never sampled, so it has no
;;         business in the same fixed point as a texture coordinate.
;;

                .model  medium, pascal
                .386
                option  proc:private

                include qgl.inc

qgl_sf_row      proto   far pascal :dword, :word

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

FXFLOOR         macro   a:req
                shr     a, 16
endm

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

;; nom(f) = (a.f - b.f)*(b.y - c.y) - (b.f - c.f)*(a.y - b.y), left on the
;; FPU. si-> a, di-> b, bx-> c, all QVert in ds.
CALC_NOM        macro   f:req
                fld     [si].QVert.&f&
                fsub    [di].QVert.&f&
                fld     [di].QVert.vy
                fsub    [bx].QVert.vy
                fmul
                fld     [di].QVert.&f&
                fsub    [bx].QVert.&f&
                fld     [si].QVert.vy
                fsub    [di].QVert.vy
                fmul
                fsub
endm


.data
qgl$65536       real4   65536.0
qgl$half        real4   0.5
qgl$eps         real4   0.00001

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


;; qgl$ref's span constants. Its LOOP STATE is in registers like every
;; other filler's; only what is fixed for the span is here.
qgl$rzd         dw      0                       ;; depth displacement
qgl$rbp0        dd      0                       ;; -width, sign extended

.data?
qgl$fx          QVertFx QGL_CLIPV dup (<>)
qgl$src         QVert   QGL_CLIPV dup (<>)
qgl$ztmp        dq      ?


;;:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
;; The pieces every textured filler is built from. ?p is the label
;; prefix, and it is what gives each copy its own patch sites.
;;:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

;;::::::::::::::
;;  in: ax= x, si= width, di= dst base, ecx= u, edx= v
;; out: bp= -width, di= dst base + x + width
;;      bx:cx= u int:frac, si:dx= v int:frac
TEX_HEAD        macro   ?p
                add     di, ax
                mov     bp, si
                add     di, si
                neg     bp

                mov     esi, edx
                mov     ebx, ecx
                shr     esi, 16
                shr     ebx, 16
?p&_shift:      shl     si, __IMM8__
                ZEND    ?p&_shift
?p&_umskp:      and     bx, __IMM16__
                ZEND    ?p&_umskp
?p&_vmskp:      and     si, __IMM16__
                ZEND    ?p&_vmskp
endm

;;::::::::::::::
;; the same, and this scanline's depth displacement patched into one or
;; two sites while bx is still free
;;
;; out: as TEX_HEAD, plus ebp SIGN EXTENDED -- with a bare 16-bit bp the
;;      upper half reads as zero and ebp*2 addresses near 128K instead of
;;      just short of the scanline's end
ZDISP           macro   ?d1, ?d2
                ;; zdisp = zline + (x + width)*2. ax is x and bp is
                ;; -width, so x + width is ax - bp.
                ;;
                ;; A whole DWORD is stored: the placeholder is 0DEADBEEFh
                ;; and leaving DEAD in the high half sends every depth
                ;; write about 3.6GB up the address space.
                PS      eax, ebx
                mov     bx, ax
                sub     bx, bp
                shl     bx, 1
                add     bx, fs:qgl$zline
                movzx   ebx, bx
                mov     D cs:[?d1&_e-4], ebx
        ifnb    <?d2>
                mov     D cs:[?d2&_e-4], ebx
        endif
                PP      ebx, eax
                movsx   ebp, bp
endm

TEX_HEAD_Z      macro   ?p, ?d1, ?d2
                add     di, ax
                mov     bp, si
                add     di, si
                neg     bp

                ZDISP   ?d1, ?d2

                mov     esi, edx
                mov     ebx, ecx
                shr     esi, 16
                shr     ebx, 16
?p&_shift:      shl     si, __IMM8__
                ZEND    ?p&_shift
?p&_umskp:      and     bx, __IMM16__
                ZEND    ?p&_umskp
?p&_vmskp:      and     si, __IMM16__
                ZEND    ?p&_vmskp
endm

;;:::::::::::::: al= the texel
TEX_FETCH       macro   ?p
?p&_ofs:        mov     al, ds:[si+bx+__IMM16__]
                ZEND    ?p&_ofs
endm

;;:::::::::::::: u and v to the next pixel, v wrapped
TEX_STEP        macro   ?p
?p&_dvdxf:      add     dx, __IMM16__           ;; v_frc+= dvdx_frc
                ZEND    ?p&_dvdxf
?p&_dvdxi:      adc     si, __IMM16__           ;; v_int+= dvdx_int
                ZEND    ?p&_dvdxi
?p&_dudxf:      add     cx, __IMM16__           ;; u_frc+= dudx_frc
                ZEND    ?p&_dudxf
?p&_dudxi:      adc     bx, __IMM16__           ;; u_int+= dudx_int
                ZEND    ?p&_dudxi
?p&_vmsk:       and     si, __IMM16__
                ZEND    ?p&_vmsk
endm

;;:::::::::::::: u wrapped, kept apart so the pixel write sits between
TEX_WRAPU       macro   ?p
?p&_umsk:       and     bx, __IMM16__
                ZEND    ?p&_umsk
endm

;;:::::::::::::: the depth accumulator to the next pixel
Z_STEP          macro   ?p
?p&_dzdxf:      add     W fs:qgl$zacc+0, __IMM16__
                ZEND    ?p&_dzdxf
?p&_dzdxi:      adc     W fs:qgl$zacc+2, __IMM16__
                ZEND    ?p&_dzdxi
endm


.code

;;:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
;; The filler contract, which every one of them takes:
;;
;;  in: ds-> tex
;;      es:di-> dst scanline, offset of x= 0
;;      fs-> DGROUP
;;      gs-> depth scanline
;;      ax= x
;;      ecx= u 16.16 texels
;;      edx= v 16.16
;;      si= width, always > 0
;;
;; THE FILLERS ARE THE ONE EXEMPTION from the qgl$ rule that an internal
;; preserves every register. They take their arguments in ax, ecx, edx,
;; si and di and consume them, exactly as mgl's do. What they must
;; preserve is bp, ds and es -- bp because it is the scanner's frame
;; pointer, ds and es because the scanner set them. Everything else here
;; obeys the rule, and qgl$fixup breaking it -- using bp as scratch for a
;; mask -- cost a silent fault with no output at all.
;;
;; The constants are patched rather than read because there is nowhere to
;; read them into. At the top of the textured loop ax, bx, cx, dx, si, di
;; and bp are all live -- texel, u and v in integer and fractional halves,
;; the destination and the counter -- and ds is the texture and es the
;; destination. That is mgl's own reason in 8plxtz.asm and it is the whole
;; argument for the self-modifying code here.
;;
;; Depth is addressed off the loop counter the way the destination is,
;; but scaled:
;;
;;      destination     es:[di + bp]            one byte  a pixel
;;      depth           gs:[ebp*2 + zdisp]      two bytes a pixel
;;
;; bp counts up from -width to 0, so ebp*2 walks the depths in step for
;; nothing.
;;:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

;;:::::::::::::: textured, no depth
qgl$tex_o       proc    near
                PS      ebx, bp
                TEX_HEAD to

@@loop:         TEX_FETCH to
                TEX_STEP  to
                mov     es:[di+bp], al
                TEX_WRAPU to
                inc     bp
                jnz     @@loop

                PP      bp, ebx
                ret
qgl$tex_o       endp

;;:::::::::::::: textured, depth written and not tested: the first
;;               surface into a frame, or anything known to be in front
qgl$tex_w       proc    near
                PS      ebx, bp
                TEX_HEAD_Z tw, tw_zofs

@@loop:         TEX_FETCH tw
                TEX_STEP  tw
                mov     es:[di+bp], al
                TEX_WRAPU tw

                ;; al is spent, so ax can carry the depth now
                mov     ax, W fs:qgl$zacc+2     ;; integer half of 1/z
tw_zofs:        mov     gs:[ebp*2+__IMM32__], ax
                ZEND    tw_zofs
                Z_STEP  tw

                inc     bp
                jnz     @@loop

                PP      bp, ebx
                ret
qgl$tex_w       endp

;;:::::::::::::: textured, tested then written. Depth is 1/z, so nearer
;;               is LARGER and the test rejects on "already >= ours".
;;
;; The compare goes first and the texel is fetched only if it passes,
;; which is why this is a separate routine and not a branch inside
;; qgl$tex_w: a hidden pixel costs the compare and nothing else.
qgl$tex_t       proc    near
                PS      ebx, bp
                TEX_HEAD_Z tt, tt_zcmp, tt_zofs

@@loop:         mov     ax, W fs:qgl$zacc+2
tt_zcmp:        cmp     gs:[ebp*2+__IMM32__], ax
                ZEND    tt_zcmp
                jae     @@behind

tt_zofs:        mov     gs:[ebp*2+__IMM32__], ax
                ZEND    tt_zofs
                TEX_FETCH tt
                mov     es:[di+bp], al

@@behind:       TEX_STEP  tt
                TEX_WRAPU tt
                Z_STEP    tt

                inc     bp
                jnz     @@loop

                PP      bp, ebx
                ret
qgl$tex_t       endp


;;:::::::::::::: flat, no depth: the span is one string store
qgl$flat_o      proc    near
                PS      cx, di
                add     di, ax
                mov     cx, si
                cld
fo_col:         mov     al, __IMM8__
                ZEND    fo_col
                rep     stosb
                PP      di, cx
                ret
qgl$flat_o      endp

;;:::::::::::::: the two flat depth variants differ only in the compare
FLAT_Z          macro   ?p, ?tst
                PS      ebx, bp
                add     di, ax
                mov     bp, si
                add     di, si
                neg     bp

        ifnb    <?tst>
                ZDISP   ?p&_zcmp, ?p&_zofs
        else
                ZDISP   ?p&_zofs
        endif

@@loop:         mov     ax, W fs:qgl$zacc+2
        ifnb    <?tst>
?p&_zcmp:       cmp     gs:[ebp*2+__IMM32__], ax
                ZEND    ?p&_zcmp
                jae     @@behind
        endif
?p&_zofs:       mov     gs:[ebp*2+__IMM32__], ax
                ZEND    ?p&_zofs
?p&_col:        mov     al, __IMM8__
                ZEND    ?p&_col
                mov     es:[di+bp], al

@@behind:       Z_STEP  ?p
                inc     bp
                jnz     @@loop

                PP      bp, ebx
                ret
endm

qgl$flat_w      proc    near
                FLAT_Z  fw
qgl$flat_w      endp

qgl$flat_t      proc    near
                FLAT_Z  ft, TEST
qgl$flat_t      endp


;;:::::::::::::: wireframe: the two ends of the span, nothing between.
;;
;; Two pixels, so the right end's depth is computed outright rather than
;; stepped to. A per-pixel loop that wrote twice would have the shape of
;; the fillers above and none of their reason.
qgl$wire_o      proc    near
                PS      di
                add     di, ax
wo_col:         mov     al, __IMM8__
                ZEND    wo_col
                mov     es:[di], al
                add     di, si
                dec     di
                mov     es:[di], al
                PP      di
                ret
qgl$wire_o      endp

;;::::::::::::::
;;  in: es:di-> the pixel, bx= its depth offset, dx= 1/z there
WIRE_ONE        macro   ?p, ?tst
        ifnb    <?tst>
                cmp     gs:[bx], dx
                jae     @F
        endif
                mov     gs:[bx], dx
?p&_col:        mov     al, __IMM8__
                ZEND    ?p&_col
                mov     es:[di], al
@@:
endm

WIRE_Z          macro   ?p, ?tst
                PS      ebx, ecx, edx, di

                add     di, ax
                mov     bx, ax
                shl     bx, 1
                add     bx, fs:qgl$zline
                mov     dx, W fs:qgl$zacc+2
                WIRE_ONE ?p, ?tst

                mov     cx, si
                dec     cx
                jz      @@done                  ;; one pixel is one end

                ;; the right end: x + width-1, and 1/z stepped that far
                add     di, cx
                add     bx, cx
                add     bx, cx
                PS      eax
                movzx   eax, cx
                imul    D fs:qgl$zdzdx
                add     eax, fs:qgl$zacc
                shr     eax, 16
                mov     dx, ax
                PP      eax
                WIRE_ONE ?p&r, ?tst

@@done:         PP      di, edx, ecx, ebx
                ret
endm

qgl$wire_w      proc    near
                WIRE_Z  ww
qgl$wire_w      endp

qgl$wire_t      proc    near
                WIRE_Z  wt, TEST
qgl$wire_t      endp


;;:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
;; qgl$ref -- the same span, drawn a second way.
;;
;; Takes the filler contract and honours the same modes, but reads every
;; constant out of memory: no patched immediate, no fixup, nothing that
;; can be patched at the wrong offset. Its loop state is in registers
;; like everything else here -- what is in memory is what is fixed for
;; the span.
;;
;; This exists so a self-modifying filler can be judged. Drawing the same
;; polygon through both and comparing is the only test that catches a
;; patch site that is off by one byte, because the picture that produces
;; is plausible. mgl has no such oracle and its fillers carried the
;; xRes-1 bug for years.
;;:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
qgl$ref         proc    near
                PS      ebx, ecx, edx, esi, edi, bp

                add     di, ax
                mov     bp, si
                add     di, si
                neg     bp

                mov     bx, ax
                sub     bx, bp
                shl     bx, 1
                add     bx, fs:qgl$zline
                mov     fs:qgl$rzd, bx
                movsx   ebp, bp
                mov     fs:qgl$rbp0, ebp

@@loop:         mov     bx, fs:qgl$mode
                cmp     bx, QGL_M_WIRE
                je      @@wire
                cmp     bx, QGL_M_FLAT
                je      @@flat

                ;; texel
                mov     eax, ecx
                FXFLOOR eax
                and     ax, fs:qgl$tumsk
                mov     bx, ax
                mov     eax, edx
                FXFLOOR eax
                PS      cx
                mov     cx, fs:qgl$tshift
                shl     ax, cl
                PP      cx
                and     ax, fs:qgl$tvmsk
                add     bx, ax
                add     bx, fs:qgl$tofs
                mov     al, ds:[bx]
                jmp     short @@have

@@wire:         cmp     ebp, fs:qgl$rbp0
                je      @@flat                  ;; the left end
                cmp     ebp, -1
                je      @@flat                  ;; the right end
                jmp     short @@step

@@flat:         mov     al, B fs:qgl$fcol

@@have:         cmp     fs:qgl$zmode, QGL_Z_OFF
                je      @@write

                movzx   ebx, W fs:qgl$rzd
                PS      dx
                mov     dx, W fs:qgl$zacc+2
                cmp     fs:qgl$zmode, QGL_Z_TEST
                jne     @F
                cmp     gs:[ebx+ebp*2], dx
                jae     @@hidden
@@:             mov     gs:[ebx+ebp*2], dx
                PP      dx

@@write:        mov     es:[di+bp], al
                jmp     short @@step

@@hidden:       PP      dx

@@step:         add     ecx, fs:qgl$dudx
                add     edx, fs:qgl$dvdx
                PS      eax
                mov     eax, fs:qgl$zdzdx
                add     fs:qgl$zacc, eax
                PP      eax

                inc     bp
                jnz     @@loop

                PP      bp, edi, esi, edx, ecx, ebx
                ret
qgl$ref         endp


;;:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
;; qgl$fixup -- every per-polygon constant, into every filler.
;;
;;  in: ds= DGROUP
;;
;; Patches ALL of them and not just the one about to run: which mode is
;; current changes between polygons -- d_faces.c switches depth mode per
;; face -- and a half-patched filler draws the previous polygon's texture
;; with this one's mask.
;;:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

FIX_TEX         macro   ?p
                mov     B cs:[?p&_shift_e-1], al
                mov     W cs:[?p&_umskp_e-2], bx
                mov     W cs:[?p&_vmskp_e-2], bp
                mov     W cs:[?p&_umsk_e-2], bx
                mov     W cs:[?p&_vmsk_e-2], bp
                mov     W cs:[?p&_ofs_e-2], di
endm

FIX_STEP        macro   ?p
                mov     W cs:[?p&_dudxi_e-2], cx
                mov     W cs:[?p&_dvdxi_e-2], dx
endm

FIX_STEPF       macro   ?p
                mov     W cs:[?p&_dudxf_e-2], cx
                mov     W cs:[?p&_dvdxf_e-2], dx
endm

FIX_Z           macro   ?p
                mov     W cs:[?p&_dzdxf_e-2], cx
                mov     W cs:[?p&_dzdxi_e-2], dx
endm

FIX_COL         macro   ?p
                mov     B cs:[?p&_col_e-1], al
endm

qgl$fixup       proc    near uses ax bx cx dx si di bp

                mov     al, B qgl$tshift
                mov     bx, qgl$tumsk
                mov     bp, qgl$tvmsk
                mov     di, qgl$tofs
                FIX_TEX to
                FIX_TEX tw
                FIX_TEX tt

                mov     cx, W qgl$dudx+2
                mov     dx, W qgl$dvdx+2
                FIX_STEP to
                FIX_STEP tw
                FIX_STEP tt
                mov     cx, W qgl$dudx+0
                mov     dx, W qgl$dvdx+0
                FIX_STEPF to
                FIX_STEPF tw
                FIX_STEPF tt

                mov     cx, W qgl$zdzdx+0
                mov     dx, W qgl$zdzdx+2
                FIX_Z   tw
                FIX_Z   tt
                FIX_Z   fw
                FIX_Z   ft

                mov     al, B qgl$fcol
                FIX_COL fo
                FIX_COL fw
                FIX_COL ft
                FIX_COL wo
                FIX_COL ww
                FIX_COL wwr
                FIX_COL wt
                FIX_COL wtr
                ret
qgl$fixup       endp


;;
;; Indexed qgl$mode + qgl$zmode, both pre-scaled, so a call site adds and
;; never multiplies -- SURF_CMEM's trick, twice.
;;
;; Perspective shares the affine entries. The sub-span divide is not
;; written, and the affine filler draws a face that is right where 1/z is
;; flat and distorted where it is not, which is what "affine" means and is
;; visible. An empty entry would draw a face that is right nowhere.
;;
.data
qgl$fillTB      dw      qgl$wire_o, qgl$wire_w, qgl$wire_t
                dw      qgl$flat_o, qgl$flat_w, qgl$flat_t
                dw      qgl$tex_o,  qgl$tex_w,  qgl$tex_t
                dw      qgl$tex_o,  qgl$tex_w,  qgl$tex_t

qgl$refTB       dw      qgl$ref, qgl$ref, qgl$ref
                dw      qgl$ref, qgl$ref, qgl$ref
                dw      qgl$ref, qgl$ref, qgl$ref
                dw      qgl$ref, qgl$ref, qgl$ref

qgl$curTB       dw      O qgl$fillTB


.code

;;::::::::::::::
;; qgl$f2fx -- one vertex into the walk's form.
;;
;;  in: si-> QVert, di-> QVertFx, both in ds
;;
;; Half a pixel goes onto x and y so a coordinate names a pixel CENTRE,
;; which is what makes the sub-scanline correction symmetric. u and v are
;; scaled to texels here so nothing downstream has to remember to.
;;::::::::::::::
qgl$f2fx        proc    near uses ax

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
qgl$f2fx        endp


;;::::::::::::::
;; qgl$grad -- d(u)/dx, d(v)/dx and d(1/z)/dx for the whole polygon.
;;
;;  in: si-> a, di-> b, bx-> c, three QVert in ds
;; out: CF set if the triple is too near degenerate to divide by
;;
;; ONE GRADIENT SERVES THE WHOLE N-GON, exactly rather than approximately:
;; u, v and 1/z are linear in screen space here, so three points on the
;; plane fix them everywhere on it. What is not safe is three nearly
;; collinear points -- that error multiplies across every scanline of the
;; polygon, not just the triangle they span -- so the caller picks a
;; spread triple and this refuses what is left.
;;::::::::::::::
qgl$grad        proc    near uses ax bx cx dx si di

                local   tmp:dword

                CALC_NOM vx                     ;; denom
                fld     st(0)
                fabs
                fcomp   qgl$eps
                fstsw   ax
                sahf
                jb      @@degenerate

                fld     qgl$65536               ;; rdenom = 65536/denom
                fdivr

                ;; no texture scaling on z: it is 1/z, not a coordinate,
                ;; and qgl$zscale carries the caller's units
                fld     st(0)
                CALC_NOM vz
                fmul
                fmul    D qgl$zscale
                fistp   D qgl$zdzdx

                fld     st(0)
                CALC_NOM vu
                fimul   D qgl$twhole            ;; one repeat spans the width
                fmul
                fstp    tmp
                mov     eax, tmp
                mov     qgl$dudx, eax

                CALC_NOM vv
                fimul   D qgl$thwhole
                fmul                            ;; the last rdenom
                fstp    tmp
                mov     eax, tmp
                mov     qgl$dvdx, eax

                clc
                ret

@@degenerate:   fstp    st(0)
                stc
                ret
qgl$grad        endp


;;::::::::::::::
;; qgl_rs_tex ( t:far ptr Surface ) -> ax nonzero if it took
;;
;; Refuses anything whose sides are not powers of two, because the filler
;; wraps with an AND, and anything past one 16K page, because the texel
;; base is a patched immediate that is never remapped mid-polygon.
;; Exceeding that page cost mgl a measured 15.5% triangle dropout.
;;::::::::::::::
qgl_rs_tex      proc    public uses bx cx dx si di es,\
                        t:dword

                les     bx, t
                mov     ax, es
                or      ax, bx
                jz      @@no

                mov     cx, es:[bx].Surface.x_res
                mov     dx, es:[bx].Surface.y_res
                mov     ax, es:[bx].Surface.stride
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
                mov     dx, es:[bx].Surface.y_res

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

                movzx   eax, es:[bx].Surface.x_res
                mov     qgl$twhole, eax
                movzx   eax, es:[bx].Surface.y_res
                mov     qgl$thwhole, eax

                ;; row 0's pointer IS the base: the whole texture is one
                ;; page, so an EMS one maps here and stays mapped
                invoke  qgl_sf_row, t, 0
                mov     qgl$tofs, ax
                mov     qgl$tseg, dx

                mov     ax, 1
                ret

@@no:           xor     ax, ax
                ret
qgl_rs_tex      endp


;;:::::::::::::: qgl_rs_flat ( col:word )
qgl_rs_flat     proc    public uses ax,\
                        col:word
                mov     ax, col
                mov     qgl$fcol, ax
                ret
qgl_rs_flat     endp


;;:::::::::::::: qgl_rs_mode ( m:word ) -> ax= the mode that was in force
qgl_rs_mode     proc    public uses bx,\
                        m:word

                mov     ax, qgl$mode
                mov     bx, m
                cmp     bx, QGL_M_PTEX
                ja      @F
                test    bl, 1                   ;; pre-scaled: odd is not a mode
                jnz     @F
                mov     qgl$mode, bx
@@:             ret
qgl_rs_mode     endp


;;::::::::::::::
;; qgl_rs_ref ( on:word )
;;
;; Sends every mode to qgl$ref, or back to the patched fillers. A test
;; hook, deliberately: see qgl$ref.
;;::::::::::::::
qgl_rs_ref      proc    public uses ax,\
                        on:word

                mov     ax, O qgl$fillTB
                cmp     on, 0
                je      @F
                mov     ax, O qgl$refTB
@@:             mov     qgl$curTB, ax
                ret
qgl_rs_ref      endp


;;::::::::::::::
;; qgl$top -- the index of the topmost vertex of qgl$src.
;;
;;  in: cx= count
;; out: ax= its INDEX
;;
;; An offset, not a rotation. The ring is walked from here with wrap, the
;; way SH_INIT_poly walks one, so no vertex data moves. Rotating the array
;; to put the top first -- which this did -- is an O(n^2) memmove to avoid
;; two compares in the step.
;;::::::::::::::
qgl$top         proc    near uses bx cx dx si

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
qgl$top         endp


;;::::::::::::::
;; qgl_rs_poly ( d:far ptr Surface, v:far ptr QVert, n:word ) -> ax
;;
;; Draws one convex polygon and returns the scanlines it covered. The
;; vertices arrive clipped -- qgl_cl_poly's output -- in ring order and
;; clockwise; vtx[0] need not be the topmost.
;;::::::::::::::
qgl_rs_poly     proc    public uses bx cx dx si di ds es,\
                        d:dword, v:dword, n:word

                local   cnt:word, edges:word
                local   li:word, ri:word
                local   lines:word, yy:word, ycnt:word
                local   rowo:word, rows:word, zsegv:word
                local   dsth:word, dstw:word
                local   fillp:word
                local   lf_s:word, lf_e:word, rg_s:word, rg_e:word
                local   lf_hgt:word, rg_hgt:word, height:word
                local   lf_x:dword, lf_dxdy:dword
                local   lf_u:dword, lf_dudy:dword
                local   lf_v:dword, lf_dvdy:dword
                local   rg_x:dword, rg_dxdy:dword
                local   lf_z:real4, lf_dzdy:real4

                mov     ax, @data
                mov     fs, ax                  ;; DGROUP, for every filler

                mov     lines, 0
                les     bx, d
                mov     ax, es:[bx].Surface.y_res
                mov     dsth, ax                ;; scanlines that exist
                mov     ax, es:[bx].Surface.x_res
                mov     dstw, ax                ;; pixels that exist
                mov     ax, n
                mov     cnt, ax
                cmp     ax, 3
                jb      @@done
                cmp     ax, QGL_CLIPV
                ja      @@done

                ;; the caller's vertices, once, into our own segment
                push    ds
                pop     es
                mov     di, O qgl$src
                mov     cx, cnt
                imul    cx, T QVert / 4
                cld
                lds     si, v
                rep     movsd
                push    es
                pop     ds

                ;; gradients, from a spread triple: 0, n/3 and 2n/3 are as
                ;; far apart as three indices get on a convex ring, and on
                ;; a triangle they are just 0, 1, 2
                mov     ax, cnt
                xor     dx, dx
                mov     cx, 3
                div     cx
                mov     si, O qgl$src
                mov     di, ax
                imul    di, T QVert
                add     di, si
                mov     bx, ax
                shl     bx, 1
                imul    bx, T QVert
                add     bx, si
                call    qgl$grad
                jc      @@done

                call    qgl$fixup               ;; ONCE per polygon

                ;; and into the walk's form
                mov     si, O qgl$src
                mov     di, O qgl$fx
                mov     cx, cnt
@@conv:         call    qgl$f2fx
                add     si, T QVert
                add     di, T QVertFx
                loop    @@conv

                ;; the filler, ONCE per polygon
                mov     bx, qgl$curTB
                add     bx, qgl$mode
                add     bx, qgl$zmode
                mov     bx, [bx]
                mov     fillp, bx

                ;; both chains start at the topmost vertex; the left walks
                ;; backwards around the ring and the right forwards. n
                ;; edges close a ring of n vertices, and the two chains
                ;; between them consume exactly that many.
                mov     cx, cnt
                call    qgl$top                 ;; ax = the top vertex's INDEX
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

@@lf_dz:        ;; lf_hgt, NOT height. height is MIN(lf_hgt, rg_hgt) and
                ;; is not computed until below; here it still holds the
                ;; previous edge's -- zero on the first -- and 0/0 makes a
                ;; NaN that lf_z carries for the rest of the polygon.
                fld     [si].QVertFx.kz
                fsub    [bx].QVertFx.kz
                fild    lf_hgt
                fdiv
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

                ;; z gets no sub-scanline correction. Depth is compared,
                ;; never sampled: a fraction of a line's worth of 1/z
                ;; cannot change which surface is in front.
                mov     eax, D [bx].QVertFx.kz
                mov     D lf_z, eax

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
@@outer:        ;; A SCANLINE PAST THE SURFACE IS NOT A SCANLINE. qgl_sf_row
                ;; answers for any y it is asked about -- the arithmetic
                ;; does not know where the store ends -- so an overrunning
                ;; walk gets a valid pointer into whatever was allocated
                ;; next and writes a picture into it.
                mov     ax, yy
                cmp     ax, dsth
                jae     @@done

                invoke  qgl_sf_row, d, yy
                mov     rowo, ax
                mov     rows, dx
                mov     zsegv, dx               ;; harmless when depth is off

                cmp     qgl$zmode, QGL_Z_OFF
                je      @@nodepth
                invoke  qgl_sf_row, qgl$zsf, yy
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

                ;; A SPAN MUST NOT LEAVE ITS ROW. The filler walks
                ;; es:[di+bp] with no idea where the row ends, so a span
                ;; running past x_res writes the polygon's texels straight
                ;; through whatever follows -- and what follows a small
                ;; surface is other live data. This is the guard that was
                ;; missing: with the texture filled with 5Ah, 5A5Ah turned
                ;; up inside a VERTEX of qgl$fx, and the walk then read its
                ;; own corrupted geometry and ran further out of range.
                ;;
                ;; It cannot fire on a polygon that came through
                ;; qgl_cl_poly, which is why the clipper is not optional.
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

                mov     bx, fillp
                mov     di, rowo
                mov     es, rows
                mov     gs, zsegv

                ;; ds is DGROUP for the walk -- qgl_sf_row above reaches
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
qgl_rs_poly     endp



                end
