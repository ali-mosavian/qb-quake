;;
;; rs.asm -- the convex scanner. The pixels are b8/'s.
;;
;; name: qgl_rs_tex / qgl_rs_flat / qgl_rs_mode / qgl_rs_poly
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
;;         one repeat spans it. mgl's uglplxtp.asm still scales by
;;         xRes-1; ugl-patch/README.md is about that off-by-one and its
;;         copies are the corrected ones. Do not take the gradient from
;;         mgl/src.
;;       - 1/z is a float. It is compared, never sampled, so it has no
;;         business in the same fixed point as a texture coordinate.
;;

                .model  medium, pascal
                .386
                option  proc:private

                include qgl.inc

qgl_sf_rd_row   proto   far pascal :dword, :word
qgl_cl_poly     proto   far pascal :dword, :word, :dword, :dword
qgl_sf_wr_row   proto   far pascal :dword, :word
qgl_sf_wr_row_ex proto  far pascal :dword, :word, :word

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

                public  qgl$dudx, qgl$dvdx, qgl$fcol, qgl$mode
                public  qgl$tshift, qgl$tumsk, qgl$tvmsk, qgl$tofs
                public  qgl$tseg



.data?
qgl$fx          QVertFx QGL_CLIPV dup (<>)
qgl$src         QVert   QGL_CLIPV dup (<>)
qgl$ztmp        dq      ?


                QGL_CODE

                externdef qgl$fixup:near
                externdef b8_span:near

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
                invoke  qgl_sf_rd_row, t, 0
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
                local   srcp:dword

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

                ;;
                ;; CLIP FIRST, and against the destination itself. The
                ;; fillers do not test a bound -- their whole job is to
                ;; fill as fast as the loop allows -- so nothing may reach
                ;; them that does not fit. Sutherland-Hodgman against the
                ;; four edges is mgl's arrangement too: SH_CLIP runs
                ;; before drawPoly ever sees a vertex.
                ;;
                ;; This also replaces the copy that used to be here: the
                ;; clipper reads the caller's far pointer and writes
                ;; qgl$src, so the vertices are moved once instead of
                ;; twice.
                ;;
                mov     ax, O qgl$src
                mov     W srcp, ax
                mov     ax, ds
                mov     W srcp+2, ax
                invoke  qgl_cl_poly, v, cnt, srcp, d
                test    ax, ax
                jz      @@done                  ;; nothing of it survived
                mov     cnt, ax

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
                call    b8_span                 ;; ONCE per polygon
                mov     fillp, ax

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

                invoke  qgl_sf_wr_row, d, yy
                mov     rowo, ax
                mov     rows, dx
                mov     zsegv, dx               ;; harmless when depth is off

                cmp     qgl$zmode, QGL_Z_OFF
                je      @@nodepth
                invoke  qgl_sf_wr_row_ex, qgl$zsf, yy, QGL_Z_SLOT
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

                ;; A SPAN MUST NOT LEAVE ITS ROW. qgl_cl_poly above makes
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



                

                QGL_ENDS
                end
