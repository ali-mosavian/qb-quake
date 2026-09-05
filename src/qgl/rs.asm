;; rs.asm -- the polygon scanner, and the reference filler it is proved
;;           against.
;;
;; name: qgl_rs_tex / qgl_rs_flat / qgl_rs_mode / qgl_rs_ref / qgl_rs_poly
;; desc: a general convex N-gon scanner. Two edge chains walk down from
;;       vtx[0] and every scanline hands one span to whichever filler the
;;       mode selected. The scanner is the same code for wireframe, flat
;;       and textured; only the filler differs, which is the whole design
;;       and the reason every filler takes its arguments the same way.
;;
;;       qgl$ref IS THE POINT OF THIS FILE, not a leftover. It is the
;;       reference filler: one pixel at a time, every constant read from
;;       memory, not one patched immediate. qgl_rs_ref switches the
;;       dispatch table over to it, so the same polygon can be drawn
;;       twice through the same scanner and the two frames compared. That
;;       is the only way to test self-modifying code whose failure mode
;;       is a plausible wrong picture, and mgl has nothing like it.
;;
;; obs.: - the destination row comes from qgl_sf_row per scanline, not
;;         from a precomputed scanline table. One far call a line, and it
;;         is what lets the destination be an EMS surface at all: a table
;;         of addresses into a window that moves is a table of stale
;;         pointers.
;;       - u and v are 16.16 in TEXELS, scaled by the texture's width at
;;         conversion so one repeat spans it. mgl's own uglplxtp.asm
;;         still scales by xRes-1 here and ugl-patch/README.md is about
;;         exactly that off-by-one. Do not take the gradient from
;;         mgl/src; ugl-patch's copies are the corrected ones.
;;       - fs IS DGROUP throughout, in the scanner and in every filler.
;;         ds is the texture and es the destination, so mgl says DGROUP
;;         with ss: instead and thereby assumes SS == DGROUP. See
;;         qgl_z_set for why that assumption does not hold here.
;;       - 1/z is carried as a float. It is compared, never sampled, so
;;         it has no business sharing a fixed point with a texture
;;         coordinate.

                .model  medium, pascal
                .386

                include qgl.inc

qgl_sf_row      proto   far pascal :dword, :word

                externdef qgl$zsf:dword
                externdef qgl$zmode:word
                externdef qgl$zscale:dword
                externdef qgl$zline:word
                externdef qgl$zacc:dword
                externdef qgl$zdzdx:dword

;; the walk's own vertex: the caller's floats converted once. x, y, u and
;; v are 16.16; z stays a float.
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

;; nom(f) = (a.f - b.f)*(b.y - c.y) - (b.f - c.f)*(a.y - b.y), left on
;; the FPU. si -> a, di -> b, bx -> c, all QVert in ds.
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
qgl$fcol        dw      0                       ;; flat fill colour
qgl$mode        dw      QGL_M_TEX

;; qgl$ref's working set. It cannot use stack locals: bp is the loop's
;; only spare register and a frame pointer would take it.
qgl$rx          dw      0
qgl$rcnt        dw      0
qgl$rfirst      dw      0
qgl$rlast       dw      0
qgl$rdi         dw      0
qgl$ru          dd      0
qgl$rv          dd      0

;; Two tables, same shape. qgl$fillTB is what runs; qgl$refTB sends every
;; mode and every depth mode to the one filler that cannot be wrong for
;; an interesting reason. qgl_rs_ref chooses.
qgl$fillTB      dw      qgl$ref, qgl$ref, qgl$ref        ;; wire  off/set/test
                dw      qgl$ref, qgl$ref, qgl$ref        ;; flat
                dw      qgl$ref, qgl$ref, qgl$ref        ;; affine
                dw      qgl$ref, qgl$ref, qgl$ref        ;; perspective

qgl$refTB       dw      qgl$ref, qgl$ref, qgl$ref
                dw      qgl$ref, qgl$ref, qgl$ref
                dw      qgl$ref, qgl$ref, qgl$ref
                dw      qgl$ref, qgl$ref, qgl$ref

qgl$curTB       dw      offset qgl$fillTB
qgl$rotn        dw      0                       ;; qgl$rotate's count

.data?
qgl$fx          QVertFx QGL_CLIPV dup (<>)
qgl$src         QVert   QGL_CLIPV dup (<>)
qgl$vtmp        QVert   <>
qgl$ztmp        dq      ?


.code

;;::::::::::::::
;; qgl$ref -- one span, the slow honest way.
;;
;; INTERNAL, and the contract is the one every filler here takes:
;;
;;      ds     -> the texture
;;      es:di  -> the destination scanline, offset of x = 0
;;      fs     -> DGROUP
;;      gs     -> the depth scanline's segment (qgl$zline is its offset)
;;      ax     =  x
;;      ecx    =  u, 16.16 texels
;;      edx    =  v, 16.16
;;      si     =  width in pixels
;;
;; Reads the mode and every constant out of memory rather than having
;; them patched in, so there is no encoding to get wrong and no fixup to
;; forget. Slow on purpose.
;;::::::::::::::
qgl$ref         proc    near private uses ax bx cx dx si di

                test    si, si
                jz      @@out

                mov     fs:qgl$rcnt, si
                dec     si
                add     si, ax
                mov     fs:qgl$rlast, si        ;; x of the last pixel
                mov     fs:qgl$rx, ax
                mov     fs:qgl$rfirst, ax
                add     di, ax
                mov     fs:qgl$rdi, di
                mov     fs:qgl$ru, ecx
                mov     fs:qgl$rv, edx

@@px:           ;;
                ;; the colour this pixel wants
                ;;
                cmp     fs:qgl$mode, QGL_M_WIRE
                jne     @@notwire
                mov     al, byte ptr fs:qgl$fcol
                mov     bx, fs:qgl$rx
                cmp     bx, fs:qgl$rfirst
                je      @@have
                cmp     bx, fs:qgl$rlast
                je      @@have
                jmp     @@step                  ;; a span's interior is not drawn

@@notwire:      cmp     fs:qgl$mode, QGL_M_FLAT
                jne     @@texel
                mov     al, byte ptr fs:qgl$fcol
                jmp     short @@have

@@texel:        mov     eax, fs:qgl$ru
                FXFLOOR eax
                and     ax, fs:qgl$tumsk
                mov     bx, ax
                mov     eax, fs:qgl$rv
                FXFLOOR eax
                mov     cx, fs:qgl$tshift
                shl     ax, cl
                and     ax, fs:qgl$tvmsk
                add     bx, ax
                add     bx, fs:qgl$tofs
                mov     al, ds:[bx]

@@have:         ;;
                ;; depth, if a mode is in force
                ;;
                cmp     fs:qgl$zmode, QGL_Z_OFF
                je      @@write

                mov     bx, fs:qgl$rx
                shl     bx, 1                   ;; two bytes a depth
                add     bx, fs:qgl$zline
                mov     dx, word ptr fs:qgl$zacc+2      ;; integer half

                cmp     fs:qgl$zmode, QGL_Z_TEST
                jne     @F
                cmp     gs:[bx], dx
                jae     @@step                  ;; nearer already: no pixel
@@:             mov     gs:[bx], dx

@@write:        mov     bx, fs:qgl$rdi
                mov     es:[bx], al

@@step:         mov     eax, fs:qgl$dudx
                add     fs:qgl$ru, eax
                mov     eax, fs:qgl$dvdx
                add     fs:qgl$rv, eax
                mov     eax, fs:qgl$zdzdx
                add     fs:qgl$zacc, eax

                inc     fs:qgl$rdi
                inc     fs:qgl$rx
                dec     fs:qgl$rcnt
                jnz     @@px

@@out:          ret
qgl$ref         endp


;;::::::::::::::
;; qgl$f2fx -- one vertex from the caller's floats into the walk's form.
;;
;; INTERNAL. si -> QVert, di -> QVertFx, both in ds. Half a pixel is
;; added to x and y so a coordinate names a pixel CENTRE, which is what
;; makes the sub-scanline correction below symmetric; u and v are scaled
;; to texels here so nothing downstream has to remember to.
;;::::::::::::::
qgl$f2fx        proc    near private uses ax

                fld     [si].QVert.vx
                fadd    qgl$half
                fmul    qgl$65536
                fistp   dword ptr [di].QVertFx.kx

                fld     [si].QVert.vy
                fadd    qgl$half
                fmul    qgl$65536
                fistp   dword ptr [di].QVertFx.ky

                mov     eax, dword ptr [si].QVert.vz
                mov     dword ptr [di].QVertFx.kz, eax

                fild    dword ptr qgl$twhole
                fmul    [si].QVert.vu
                fmul    qgl$65536
                fistp   dword ptr [di].QVertFx.ku

                fild    dword ptr qgl$thwhole
                fmul    [si].QVert.vv
                fmul    qgl$65536
                fistp   dword ptr [di].QVertFx.kv
                ret
qgl$f2fx        endp

                

;;::::::::::::::
;; qgl$grad -- d(u)/dx, d(v)/dx and d(1/z)/dx for the whole polygon.
;;
;; INTERNAL. si -> a, di -> b, bx -> c: three QVert in ds. Returns CF set
;; if the triple is too near degenerate to divide by, in which case the
;; polygon is not drawable and nothing has been written.
;;
;; ONE GRADIENT SERVES THE WHOLE N-GON, and that is exact rather than an
;; approximation: u, v and 1/z are linear in screen space here, so three
;; points on the plane determine them everywhere on it. What is NOT safe
;; is deriving them from three nearly collinear points -- the error then
;; multiplies across every scanline of the polygon, not just the triangle
;; those three span. The caller picks a spread triple for that reason and
;; this refuses what is left.
;;::::::::::::::
qgl$grad        proc    near private uses ax bx cx dx si di

                local   tmp:dword

                ;; denom is the same nominator, over x
                CALC_NOM vx
                fld     st(0)
                fabs
                fcomp   qgl$eps
                fstsw   ax
                sahf
                jb      @@degenerate            ;; |denom| < eps

                ;; rdenom = 65536 / denom
                fld     qgl$65536
                fdivr                           ;; st0 = rdenom

                ;; d(1/z)/dx. No texture scaling: z is 1/z, not a
                ;; coordinate, and qgl$zscale carries the caller's units.
                fld     st(0)
                CALC_NOM vz
                fmul
                fmul    dword ptr qgl$zscale
                fistp   dword ptr qgl$zdzdx

                fld     st(0)                   ;; rdenom rdenom
                CALC_NOM vu
                fimul   dword ptr qgl$twhole    ;; one repeat spans the width
                fmul
                fstp    tmp
                mov     eax, tmp
                mov     qgl$dudx, eax

                CALC_NOM vv
                fimul   dword ptr qgl$thwhole
                fmul                            ;; consumes the last rdenom
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
;; Binds the texture every later polygon samples. Refuses anything whose
;; sides are not powers of two, because the filler wraps with an AND, and
;; anything past one 16K page, because the texel base is a single patched
;; immediate that is never remapped mid-polygon. Exceeding that page cost
;; mgl a measured 15.5% triangle dropout.
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
                ;; mul writes dx:ax, so the height has to be taken back
                ;; off the Surface afterwards -- reusing dx here left
                ;; qgl$tvmsk built from the product's high word and sent
                ;; one row in eight past the end of the texture
                mov     ax, cx
                mul     dx
                test    dx, dx
                jnz     @@no
                cmp     ax, 4000h
                ja      @@no
                mov     dx, es:[bx].Surface.y_res

                ;; shift = log2(width)
                xor     ax, ax
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
                mov     cl, byte ptr qgl$tshift
                shl     si, cl
                mov     qgl$tvmsk, si

                les     bx, t
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


;;::::::::::::::
;; qgl_rs_flat ( col:word )
;;::::::::::::::
qgl_rs_flat     proc    public uses ax,\
                        col:word
                mov     ax, col
                mov     qgl$fcol, ax
                ret
qgl_rs_flat     endp


;;::::::::::::::
;; qgl_rs_mode ( m:word ) -> ax = the mode that was in force
;;::::::::::::::
qgl_rs_mode     proc    public uses bx,\
                        m:word

                mov     ax, qgl$mode
                mov     bx, m
                cmp     bx, QGL_M_PTEX
                ja      @F
                mov     qgl$mode, bx
@@:             ret
qgl_rs_mode     endp


;;::::::::::::::
;; qgl_rs_ref ( on:word )
;;
;; Sends every mode to the reference filler, or back to the fast ones.
;; This is a TEST HOOK and it is deliberate: a self-modifying filler that
;; draws a plausible wrong picture cannot be caught by reading it, only by
;; drawing the same polygon a second way and diffing the two.
;;::::::::::::::
qgl_rs_ref      proc    public uses ax,\
                        on:word

                mov     ax, offset qgl$fillTB
                cmp     on, 0
                je      @F
                mov     ax, offset qgl$refTB
@@:             mov     qgl$curTB, ax
                ret
qgl_rs_ref      endp


;;::::::::::::::
;; qgl$rotate -- put the topmost vertex of qgl$src first.
;;
;; INTERNAL. cx = the count, unchanged.
;;
;; The scanner walks two chains DOWN from vtx[0] and cannot find its own
;; starting point: with vtx[0] anywhere but the top, the left chain's
;; first edge has a negative height and the polygon is abandoned. Clipping
;; displaces the top routinely -- t08clip's corner case goes in starting
;; at (32,32) and comes back starting at (32,64).
;;
;; mgl leaves this to a one-position fixup at the end of SH_END, which is
;; right only because ITS clipper can move the top by exactly one. That is
;; a fact about that clipper, not about polygons, and it does not survive
;; being handed vertices from anywhere else.
;;::::::::::::::
qgl$rotate      proc    near private uses ax bx cx dx si di es

                local   top:word
                local   best:real4

                mov     top, 0
                mov     si, offset qgl$src
                mov     eax, dword ptr [si].QVert.vy
                mov     dword ptr best, eax

                mov     bx, 1
@@find:         cmp     bx, cx
                jae     @@got
                mov     si, bx
                imul    si, SIZEOF QVert
                add     si, offset qgl$src
                fld     [si].QVert.vy
                fcomp   best
                fstsw   ax
                sahf
                jae     @F                      ;; not higher up the screen
                mov     eax, dword ptr [si].QVert.vy
                mov     dword ptr best, eax
                mov     top, bx
@@:             inc     bx
                jmp     @@find

@@got:          cmp     top, 0
                je      @@out

                ;; rotate left one place at a time. n is at most 45 and
                ;; this runs once a polygon, so the simple thing wins.
                mov     dx, top
                push    ds
                pop     es

@@spin:         mov     si, offset qgl$src
                mov     di, offset qgl$vtmp
                mov     cx, SIZEOF QVert / 4
                rep     movsd

                mov     si, offset qgl$src + SIZEOF QVert
                mov     di, offset qgl$src
                mov     cx, qgl$rotn
                dec     cx
                imul    cx, SIZEOF QVert / 4
                rep     movsd

                mov     si, offset qgl$vtmp
                mov     di, qgl$rotn
                dec     di
                imul    di, SIZEOF QVert
                add     di, offset qgl$src
                mov     cx, SIZEOF QVert / 4
                rep     movsd

                dec     dx
                jnz     @@spin

@@out:          ret
qgl$rotate      endp


;;::::::::::::::
;; qgl_rs_poly ( d:far ptr Surface, v:far ptr QVert, n:word ) -> ax
;;
;; Draws one convex polygon and returns the number of scanlines it
;; covered. The vertices arrive already clipped -- qgl_cl_poly's output --
;; in ring order and clockwise.
;;::::::::::::::
qgl_rs_poly     proc    public uses bx cx dx si di ds es,\
                        d:dword, v:dword, n:word

                local   cnt:word
                local   lines:word
                local   yy:word
                local   ycnt:word
                local   rowo:word, rows:word
                local   zsegv:word
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
                mov     ax, n
                mov     cnt, ax
                mov     qgl$rotn, ax
                cmp     ax, 3
                jb      @@done
                cmp     ax, QGL_CLIPV
                ja      @@done

                ;;
                ;; the caller's vertices, once, into our own segment
                ;;
                push    ds
                pop     es
                mov     di, offset qgl$src
                mov     cx, ax
                imul    cx, SIZEOF QVert / 4
                lds     si, v
                rep     movsd
                push    es
                pop     ds

                mov     cx, cnt
                call    qgl$rotate              ;; topmost vertex first

                ;;
                ;; gradients, from a spread triple: 0, n/3 and 2n/3 are as
                ;; far apart as three indices get on a convex ring, and for
                ;; a triangle they are just 0, 1, 2
                ;;
                mov     ax, cnt
                xor     dx, dx
                mov     cx, 3
                div     cx                      ;; ax = n/3
                mov     si, offset qgl$src
                mov     di, ax
                imul    di, SIZEOF QVert
                add     di, si
                mov     bx, ax
                shl     bx, 1
                imul    bx, SIZEOF QVert
                add     bx, si
                call    qgl$grad
                jc      @@done

                ;;
                ;; and into the walk's form
                ;;
                mov     si, offset qgl$src
                mov     di, offset qgl$fx
                mov     cx, cnt
@@conv:         call    qgl$f2fx
                add     si, SIZEOF QVert
                add     di, SIZEOF QVertFx
                loop    @@conv

                ;;
                ;; both chains start at vertex 0: the left walks backwards
                ;; around the ring and the right forwards
                ;;
                mov     ax, offset qgl$fx
                mov     lf_s, ax
                mov     rg_s, ax
                add     ax, SIZEOF QVertFx
                mov     rg_e, ax
                mov     ax, cnt
                dec     ax
                imul    ax, SIZEOF QVertFx
                add     ax, offset qgl$fx
                mov     lf_e, ax

                xor     ax, ax
                mov     lf_hgt, ax
                mov     rg_hgt, ax
                mov     height, ax

                mov     si, offset qgl$fx
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
                cmp     si, offset qgl$fx
                jbe     @@done                  ;; the chains have met

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

@@lf_lt1:       ;; a sub-scanline edge: 16.16 has no room for its
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
                ;; NaN that lf_z then carries for the rest of the polygon.
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
                mov     eax, dword ptr [bx].QVertFx.kz
                mov     dword ptr lf_z, eax

@@lf_next:      mov     ax, lf_e
                mov     lf_s, ax
                sub     ax, SIZEOF QVertFx
                mov     lf_e, ax

@@srch_rg:      mov     ax, height
                sub     rg_hgt, ax
                jg      @@prep
                jl      @@done

@@new_rg:       mov     bx, rg_s
                mov     si, rg_e
                mov     ax, cnt
                imul    ax, SIZEOF QVertFx
                add     ax, offset qgl$fx
                cmp     si, ax
                jae     @@done                  ;; past the ring: chains met

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
                add     ax, SIZEOF QVertFx
                mov     rg_e, ax

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
@@outer:        invoke  qgl_sf_row, d, yy
                mov     rowo, ax
                mov     rows, dx
                mov     zsegv, dx               ;; harmless if depth is off

                cmp     qgl$zmode, QGL_Z_OFF
                je      @@nodepth
                invoke  qgl_sf_row, qgl$zsf, yy
                mov     qgl$zline, ax
                mov     zsegv, dx

                ;; a qword landing pad: depth runs to 65535 and the
                ;; accumulator is 16.16, so the product passes what a
                ;; SIGNED dword fistp can hold
                fld     lf_z
                fmul    dword ptr qgl$zscale
                fistp   qgl$ztmp
                mov     eax, dword ptr qgl$ztmp
                mov     qgl$zacc, eax

@@nodepth:      ;; sub-texel: u and v at the CENTRE of the first whole
                ;; pixel the span covers, not at the left edge
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

                mov     bx, qgl$curTB
                add     bx, qgl$mode
                add     bx, qgl$zmode
                mov     bx, [bx]                ;; the filler for this pair

                mov     di, rowo
                mov     es, rows
                mov     gs, zsegv
                push    ds
                mov     ds, qgl$tseg            ;; ds is the TEXTURE now
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
