;;
;; b8span.asm -- 8bpp scanline fillers, one per (mode, depth mode).
;;
;; name: b8_span / qgl$Fixup
;; desc: the pixels, and nothing about polygons. rs.asm walks the edges
;;       and this fills what lies between them, which is mgl's own split:
;;       ugl/uglplxt.asm scans and cfmt/b8/8plxt.asm fills.
;;
;;       The directory says the format. Everything here assumes one byte
;;       a pixel and says so in its name, so a second format would be a
;;       sibling directory and a second table -- never a flag in here.
;;
;; obs.: - shares QGL_CODE with the scanner. A near call cannot cross the
;;         per-module segments .model medium hands out, and the scanner
;;         reaches these through a table.
;;       - b8_span is the selector, and it is b8_HLineT's job: decide
;;         ONCE per polygon which routine runs and hand back its address.
;;         Nothing below ever tests a mode.
;;

                .model  medium, pascal
                .386
                option  proc:private

                include qgl.inc

                externdef qgl$zacc:dword
                externdef qgl$zdzdx:dword
                externdef qgl$zline:word
                externdef qgl$zmode:word
                externdef qgl$dudx:dword
                externdef qgl$dvdx:dword
                externdef qgl$fdudxn:dword
                externdef qgl$fdvdxn:dword
                externdef qgl$fdzdxn:dword
                externdef qgl$fdudx:dword
                externdef qgl$fdvdx:dword
                externdef qgl$fdzdx:dword
                externdef qgl$tshift:word
                externdef qgl$tumsk:word
                externdef qgl$tvmsk:word
                externdef qgl$tofs:word
                externdef qgl$fcol:word
                externdef qgl$mode:word
                externdef qgl$bound:word
                externdef qgl$bumax:dword
                externdef qgl$bvmax:dword

                public  qgl$Fixup, b8_span, qglB8Selftest

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

                ;; A BLOCK BOUNDARY between the stores above and the
                ;; instructions they patch, which sit ~40 bytes below with
                ;; no branch between. DOSBox-X's dynamic core only
                ;; rechecks the page a block STARTS in, so when the
                ;; patched fields fall in the next 4K page the write is
                ;; not seen and the block runs once on the stale
                ;; displacement -- which, on a polygon's first TexT
                ;; scanline, is still the 0DEADBEEFh placeholder. The cmp
                ;; then reads a wild address, jae fires, and the pixel
                ;; gets neither depth nor colour.
                ;;
                ;; Costs one taken short jump per depth-enabled span, not
                ;; per pixel. `nop`/`nop` in this slot -- the same 2-byte
                ;; shift without the block split -- still failed 13 of 13
                ;; positions, so it is the branch and not the alignment.
                jmp     short $+2

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


                QGL_CODE


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
;; obeys the rule, and qgl$Fixup breaking it -- using bp as scratch for a
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
qgl$TexO       proc    near
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
qgl$TexO       endp

;;:::::::::::::: textured, depth written and not tested: the first
;;               surface into a frame, or anything known to be in front
qgl$TexW       proc    near
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
qgl$TexW       endp

;;:::::::::::::: textured, tested then written. Depth is 1/z, so nearer
;;               is LARGER and the test rejects on "already >= ours".
;;
;; The compare goes first and the texel is fetched only if it passes,
;; which is why this is a separate routine and not a branch inside
;; qgl$TexW: a hidden pixel costs the compare and nothing else.
qgl$TexT       proc    near
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
qgl$TexT       endp


;;:::::::::::::: flat, no depth: the span is one string store
qgl$FlatO      proc    near
                PS      cx, di
                add     di, ax
                mov     cx, si
                cld
fo_col:         mov     al, __IMM8__
                ZEND    fo_col
                rep     stosb
                PP      di, cx
                ret
qgl$FlatO      endp

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

qgl$FlatW      proc    near
                FLAT_Z  fw
qgl$FlatW      endp

qgl$FlatT      proc    near
                FLAT_Z  ft, TEST
qgl$FlatT      endp


;;:::::::::::::: wireframe: the two ends of the span, nothing between.
;;
;; Two pixels, so the right end's depth is computed outright rather than
;; stepped to. A per-pixel loop that wrote twice would have the shape of
;; the fillers above and none of their reason.
qgl$WireO      proc    near
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
qgl$WireO      endp

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

qgl$WireW      proc    near
                WIRE_Z  ww
qgl$WireW      endp

qgl$WireT      proc    near
                WIRE_Z  wt, TEST
qgl$WireT      endp


;;:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
;; qgl$Ref -- the same span, drawn a second way.
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
qgl$Ref         proc    near
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
qgl$Ref         endp


;;:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
;; qgl$Fixup -- every per-polygon constant, into every filler.
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

;;:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
;; PERSPECTIVE. The pieces above interpolate u and v straight down the
;; span, which is only right where 1/z is flat. These divide.
;;
;; u/z, v/z and 1/z are all linear in screen space -- u is not -- so the
;; filler walks those three and recovers u = (u/z)/(1/z) every
;; QGL_SUBDIVP pixels, stepping affinely in between. That is Quake's
;; arrangement and mgl's, and the constant is mgl's 16.
;;
;; The steps come from MEMORY here rather than a patched immediate,
;; because unlike the affine ones they change every sub-span. Only what
;; is fixed for the polygon -- the masks, the shift, the texture base --
;; stays patched.
;;:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

;;::::::::::::::
;; 65536*u'/z' and 65536*v'/z' into the two named dwords.
;;
;;  FPU in : st0= u', st1= v', st2= z'
;;  FPU out: unchanged
;;
;; fistp ROUNDS, which is where the affine path's half texel went. Adding
;; it before the divide would scale it by z.
PDIV            macro   ?u, ?v
                fld     D fs:qgl$p65536         ;; k  u' v' z'
                fdiv    st(0), st(3)            ;; zf u' v' z'
                fld     st(0)                   ;; zf zf u' v' z'
                fmul    st(0), st(2)            ;; uf zf u' v' z'
                fxch    st(1)                   ;; zf uf u' v' z'
                fmul    st(0), st(3)            ;; vf uf u' v' z'
                fxch    st(1)                   ;; uf vf u' v' z'
                fistp   D fs:?u                 ;; vf u' v' z'
                fistp   D fs:?v                 ;; u' v' z'

                ;; half a texel, on THIS side of the divide, at both
                ;; boundaries so the step between them is untouched. mgl
                ;; adds it before the divide as 0.5*z at the span start,
                ;; and it comes out scaled by z(x)/z(start) -- two texels
                ;; where 1/z has fallen to a quarter. t09rs case 14.
                add     D fs:?u, 32768
                add     D fs:?v, 32768
endm

;; Quake clamps the first recovered coordinate to zero and each later
;; sub-span endpoint to a tiny positive epsilon before deriving a
;; negative step. QGL_SUBDIVP is 16 where Quake's span is eight, so the
;; corresponding raw 16.16 epsilon is 16.
PCLAMP          macro   ?u, ?v, ?lo
                local   umin, umax, ustore, vmin, vmax, vstore, done
                cmp     W fs:qgl$bound, 0
                je      done

                mov     eax, D fs:?u
                cmp     eax, ?lo
                jge     umin
                mov     eax, ?lo
                jmp     ustore
umin:           cmp     eax, D fs:qgl$bumax
                jle     ustore
                mov     eax, D fs:qgl$bumax
ustore:         mov     D fs:?u, eax

                mov     eax, D fs:?v
                cmp     eax, ?lo
                jge     vmin
                mov     eax, ?lo
                jmp     vstore
vmin:           cmp     eax, D fs:qgl$bvmax
                jle     vstore
                mov     eax, D fs:qgl$bvmax
vstore:         mov     D fs:?v, eax
done:
endm

;;:::::::::::::: the triple, one sub-span on
PSTEP           macro
                fadd    D fs:qgl$fdudxn         ;; u' v' z'
                fxch    st(1)                   ;; v' u' z'
                fadd    D fs:qgl$fdvdxn
                fxch    st(2)                   ;; z' u' v'
                fadd    D fs:qgl$fdzdxn
                fxch    st(2)                   ;; v' u' z'
                fxch    st(1)                   ;; u' v' z'
endm

;;::::::::::::::
;; the per-pixel step across this sub-span, in the form the stepper adds.
;;
;; The v half is shifted by tshift and has every bit above tvmsk set, for
;; the reason qgl$Fixup gives at length: si carries v already shifted, and
;; the carry out of the fractional add must not reach the bits the
;; following AND sweeps off. Computed here rather than patched because it
;; is different every sub-span.
PMKSTEP         macro
                mov     eax, D fs:qgl$plu
                sub     eax, D fs:qgl$ppu
                sar     eax, QGL_SUBDIVS
                mov     D fs:qgl$psdu, eax

                mov     eax, D fs:qgl$plv
                sub     eax, D fs:qgl$ppv
                sar     eax, QGL_SUBDIVS
                mov     W fs:qgl$psdv+0, ax
                mov     edx, eax
                sar     edx, 16
                mov     cl, B fs:qgl$tshift
                shl     dx, cl
                mov     cx, W fs:qgl$tvmsk
                not     cx
                or      dx, cx
                mov     W fs:qgl$psdv+2, dx
endm

;;:::::::::::::: ecx, edx 16.16 -> bx:cx and si:dx, int:frac, masked
PSPLIT          macro   ?p
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

;;:::::::::::::: one pixel on, from memory
PSTEPPX         macro   ?p
                add     dx, W fs:qgl$psdv+0
                adc     si, W fs:qgl$psdv+2
                add     cx, W fs:qgl$psdu+0
                adc     bx, W fs:qgl$psdu+2
?p&_vmsk:       and     si, __IMM16__
                ZEND    ?p&_vmsk
endm

;;::::::::::::::
;; The body, once per depth mode.
;;
;; bp runs -width..0 across the WHOLE span, exactly as the affine
;; fillers, which is what lets the depth displacement stay a single
;; patched immediate and the two depth variants below reuse ZDISP and
;; Z_STEP unaltered. The price is a compare against the sub-span boundary
;; per pixel; mgl instead restarts bp every sub-span and would have to
;; re-patch the displacement with it. Correct first -- the fast
;; arrangement is a change to this macro and to nothing else.
PTEX_BODY       macro   ?p, ?zwrite, ?ztest

                PS      ebx, bp
                add     di, ax
                mov     bp, si
                add     di, si
                neg     bp

        ifnb    <?ztest>
                ZDISP   ?p&_zcmp, ?p&_zofs
        else
          ifnb  <?zwrite>
                ZDISP   ?p&_zofs
          endif
        endif

                PDIV    qgl$ppu, qgl$ppv
                PCLAMP  qgl$ppu, qgl$ppv, 0

;;              a sub-span, or what is left of one
@@sub:          mov     ax, bp
                add     ax, QGL_SUBDIVP
                jle     @F
                xor     ax, ax                  ;; the last one is short
@@:             mov     W fs:qgl$pend, ax

                PSTEP                           ;; one WHOLE sub-span on,
                PDIV    qgl$plu, qgl$plv        ;; short tail or not: the
                PCLAMP  qgl$plu, qgl$plv, QGL_SUBDIVP
                PMKSTEP                         ;; step is per pixel

                mov     ecx, D fs:qgl$ppu
                mov     edx, D fs:qgl$ppv
                PSPLIT  ?p

@@inner:
        ifnb    <?ztest>
                mov     ax, W fs:qgl$zacc+2
?p&_zcmp:       cmp     gs:[ebp*2+__IMM32__], ax
                ZEND    ?p&_zcmp
                jae     @@behind
?p&_zofs:       mov     gs:[ebp*2+__IMM32__], ax
                ZEND    ?p&_zofs
                TEX_FETCH ?p
                mov     es:[di+bp], al
@@behind:       PSTEPPX ?p
?p&_umsk:       and     bx, __IMM16__
                ZEND    ?p&_umsk
                Z_STEP  ?p
        else
                TEX_FETCH ?p
                PSTEPPX ?p
                mov     es:[di+bp], al
?p&_umsk:       and     bx, __IMM16__
                ZEND    ?p&_umsk
          ifnb  <?zwrite>
                mov     ax, W fs:qgl$zacc+2
?p&_zofs:       mov     gs:[ebp*2+__IMM32__], ax
                ZEND    ?p&_zofs
                Z_STEP  ?p
          endif
        endif

                inc     bp
                jz      @@done
                cmp     bp, W fs:qgl$pend
                jne     @@inner

                mov     eax, D fs:qgl$plu       ;; this boundary becomes
                mov     D fs:qgl$ppu, eax       ;; the next one's start
                mov     eax, D fs:qgl$plv
                mov     D fs:qgl$ppv, eax
                jmp     @@sub

;;              THE CALLER PUSHED THREE. Leaving them costs nothing on the
;;              first span and overflows the stack on the third.
@@done:         fstp    st(0)
                fstp    st(0)
                fstp    st(0)
                PP      bp, ebx
                ret
endm

;;::::::::::::::
;; The affine-over-projective row. The scanner supplies the same u/z,
;; v/z, 1/z triple as PTEX. Recover both ends of this row, derive one
;; signed step from them, then keep that step for every pixel in between.
ASTEP           macro
                fild    W fs:qgl$pend           ;; w u' v' z'

                fld     D fs:qgl$fdudx          ;; du w u' v' z'
                fmul    st(0), st(1)
                faddp   st(2), st(0)            ;; w u1' v' z'

                fld     D fs:qgl$fdvdx          ;; dv w u1' v' z'
                fmul    st(0), st(1)
                faddp   st(3), st(0)            ;; w u1' v1' z'

                fld     D fs:qgl$fdzdx          ;; dz w u1' v1' z'
                fmulp   st(1), st(0)            ;; dz u1' v1' z'
                faddp   st(3), st(0)            ;; u1' v1' z1'
endm


AMKSTEP         macro
                mov     eax, D fs:qgl$plu
                sub     eax, D fs:qgl$ppu
                cdq
                movzx   ecx, W fs:qgl$pend
                idiv    ecx
                mov     D fs:qgl$psdu, eax

                mov     eax, D fs:qgl$plv
                sub     eax, D fs:qgl$ppv
                cdq
                idiv    ecx
                mov     W fs:qgl$psdv+0, ax
                mov     edx, eax
                sar     edx, 16
                mov     cl, B fs:qgl$tshift
                shl     dx, cl
                mov     cx, W fs:qgl$tvmsk
                not     cx
                or      dx, cx
                mov     W fs:qgl$psdv+2, dx
endm

ATEX_BODY       macro   ?p, ?zwrite, ?ztest

                PS      ebx, bp
                add     di, ax
                mov     bp, si
                add     di, si
                neg     bp
                mov     W fs:qgl$pend, si

        ifnb    <?ztest>
                ZDISP   ?p&_zcmp, ?p&_zofs
        else
          ifnb  <?zwrite>
                ZDISP   ?p&_zofs
          endif
        endif

                PDIV    qgl$ppu, qgl$ppv
                ASTEP
                PDIV    qgl$plu, qgl$plv
                AMKSTEP

                mov     ecx, D fs:qgl$ppu
                mov     edx, D fs:qgl$ppv
                PSPLIT  ?p

@@inner:
        ifnb    <?ztest>
                mov     ax, W fs:qgl$zacc+2
?p&_zcmp:       cmp     gs:[ebp*2+__IMM32__], ax
                ZEND    ?p&_zcmp
                jae     @@behind
?p&_zofs:       mov     gs:[ebp*2+__IMM32__], ax
                ZEND    ?p&_zofs
                TEX_FETCH ?p
                mov     es:[di+bp], al
@@behind:       PSTEPPX ?p
?p&_umsk:       and     bx, __IMM16__
                ZEND    ?p&_umsk
                Z_STEP  ?p
        else
                TEX_FETCH ?p
                PSTEPPX ?p
                mov     es:[di+bp], al
?p&_umsk:       and     bx, __IMM16__
                ZEND    ?p&_umsk
          ifnb  <?zwrite>
                mov     ax, W fs:qgl$zacc+2
?p&_zofs:       mov     gs:[ebp*2+__IMM32__], ax
                ZEND    ?p&_zofs
                Z_STEP  ?p
          endif
        endif

                inc     bp
                jnz     @@inner

                fstp    st(0)
                fstp    st(0)
                fstp    st(0)
                PP      bp, ebx
                ret
endm

;;:::::::::::::: perspective, no depth
qgl$PtexO      proc    near
                PTEX_BODY po
qgl$PtexO      endp

;;:::::::::::::: perspective, depth written and not tested
qgl$PtexW      proc    near
                PTEX_BODY pw, 1
qgl$PtexW      endp

;;:::::::::::::: perspective, tested then written
qgl$PtexT      proc    near
                PTEX_BODY pt, 1, 1
qgl$PtexT      endp

qgl$AtexO      proc    near
                ATEX_BODY ao
qgl$AtexO      endp

qgl$AtexW      proc    near
                ATEX_BODY aw, 1
qgl$AtexW      endp

qgl$AtexT      proc    near
                ATEX_BODY at, 1, 1
qgl$AtexT      endp


qgl$Fixup       proc    near uses ax bx cx dx si di bp

                mov     al, B qgl$tshift
                mov     bx, qgl$tumsk
                mov     bp, qgl$tvmsk
                mov     di, qgl$tofs
                FIX_TEX to
                FIX_TEX tw
                FIX_TEX tt
                FIX_TEX po
                FIX_TEX pw
                FIX_TEX pt
                FIX_TEX ao
                FIX_TEX aw
                FIX_TEX at

                ;; dvdx_int IS NOT THE PLAIN INTEGER HALF. si carries v
                ;; already shifted by tshift, so its step must be shifted
                ;; the same way; and every bit above tvmsk is set, so the
                ;; carry out of the fractional adc cannot walk into them
                ;; before the `and si, vmsk` sweeps them off.
                ;;
                ;; HLINET_SM_CALC does exactly this and patching the raw
                ;; half instead is the whole difference between the fast
                ;; fillers and the reference one. It is what t10ref caught:
                ;; wire and flat agreed, all three textured modes did not.
                ;;
                ;; The u step needs neither at one byte a pixel, which is
                ;; why mgl passes HLINET_SM_CALC a shift of 0 for b8 and 1
                ;; for b16.
                mov     dx, W qgl$dvdx+2
                mov     cl, B qgl$tshift
                shl     dx, cl
                mov     cx, qgl$tvmsk
                not     cx
                or      dx, cx

                mov     cx, W qgl$dudx+2
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
                FIX_Z   pw
                FIX_Z   pt
                FIX_Z   aw
                FIX_Z   at
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
qgl$Fixup       endp


;;::::::::::::::
;; b8_span -- which filler this polygon wants.
;;
;;  in: ds= DGROUP
;; out: ax= the filler, near, in QGL_CODE
;;
;; b8_HLineT's job, and its arrangement: the decision is made once, here,
;; and the routine it hands back tests nothing. qgl$mode and qgl$zmode are
;; pre-scaled table offsets, so choosing is an add and a load.
;;
;; qglRsRef swings the whole table over to the reference filler, which
;; is how a patched filler is judged against one that has no patch site.
;; ATEX is selected directly because both reference-table rows would cost
;; 12 bytes of the near heap; like PTEX, its FPU triple needs a real filler.
;;::::::::::::::
b8_span         proc    near
                ;; (mode * QGL_Z_KINDS + zmode) * 2. The modes are
                ;; semantic constants, so the scaling is here rather than
                ;; baked into values that also cross into BASIC.
                mov     ax, qgl$mode
                cmp     ax, QGL_M_ATEX
                jne     @@table
                mov     ax, O qgl$AtexO
                cmp     qgl$zmode, QGL_Z_OFF
                je      @@done
                mov     ax, O qgl$AtexW
                cmp     qgl$zmode, QGL_Z_SET
                je      @@done
                mov     ax, O qgl$AtexT
@@done:         ret
@@table:
                imul    ax, QGL_Z_KINDS
                add     ax, qgl$zmode
                shl     ax, 1
                add     ax, qgl$curTB
                xchg    ax, bx
                mov     bx, [bx]
                xchg    ax, bx
                ret
b8_span         endp

;;::::::::::::::
;; qglRsRef ( on:word ) -- send every mode to the reference filler.
;;::::::::::::::
qglRsRef      proc    far public uses ax,\
                        on:word
                mov     ax, O qgl$fillTB
                cmp     on, 0
                je      @F
                mov     ax, O qgl$refTB
@@:             mov     qgl$curTB, ax
                ret
qglRsRef      endp

;;::::::::::::::
;; qglB8Selftest -> ax = patch sites that are not where they claim
;;
;; Every site here is a placeholder chosen to be conspicuous: 0DEADh for
;; a word, 0DEADBEEFh for a dword, 0DEh for a byte. If cs:[label-N] still
;; reads its own placeholder then the address the fixup will write to is
;; the instruction it belongs to. If it does not, the site has been
;; relocated out from under the code that patches it, and the filler will
;; draw a plausible wrong picture with nothing to say so.
;;
;; MUST RUN BEFORE ANY FIXUP, which is the whole point: afterwards the
;; placeholders are gone and there is nothing left to check against.
;;::::::::::::::
CKB             macro   nm
                cmp     B cs:[nm&_e-1], 0DEh
                je      @F
                inc     ax
@@:
endm

CKW             macro   nm
                cmp     W cs:[nm&_e-2], 0DEADh
                je      @F
                inc     ax
@@:
endm

CKD             macro   nm
                cmp     D cs:[nm&_e-4], 0DEADBEEFh
                je      @F
                inc     ax
@@:
endm

qglB8Selftest proc    far public

                xor     ax, ax

                CKB     to_shift
                CKW     to_umskp
                CKW     to_vmskp
                CKW     to_ofs
                CKW     to_dudxi
                CKW     to_dvdxi
                CKW     to_umsk
                CKW     to_vmsk

                CKB     tw_shift
                CKW     tw_ofs
                CKD     tw_zofs
                CKW     tw_dzdxf
                CKW     tw_dzdxi

                CKB     tt_shift
                CKW     tt_ofs
                CKD     tt_zcmp
                CKD     tt_zofs
                CKW     tt_dzdxf
                CKW     tt_dzdxi

                CKB     po_shift
                CKW     po_umskp
                CKW     po_vmskp
                CKW     po_ofs
                CKW     po_umsk
                CKW     po_vmsk

                CKB     pw_shift
                CKW     pw_ofs
                CKD     pw_zofs
                CKW     pw_dzdxf
                CKW     pw_dzdxi

                CKB     pt_shift
                CKW     pt_ofs
                CKD     pt_zcmp
                CKD     pt_zofs
                CKW     pt_dzdxf
                CKW     pt_dzdxi

                CKB     ao_shift
                CKW     ao_umskp
                CKW     ao_vmskp
                CKW     ao_ofs
                CKW     ao_umsk
                CKW     ao_vmsk

                CKB     aw_shift
                CKW     aw_ofs
                CKD     aw_zofs
                CKW     aw_dzdxf
                CKW     aw_dzdxi

                CKB     at_shift
                CKW     at_ofs
                CKD     at_zcmp
                CKD     at_zofs
                CKW     at_dzdxf
                CKW     at_dzdxi

                CKB     fo_col
                CKB     fw_col
                CKD     fw_zofs
                CKB     ft_col
                CKD     ft_zcmp
                CKD     ft_zofs

                CKB     wo_col
                CKB     ww_col
                CKB     wwr_col
                CKB     wt_col
                CKB     wtr_col
                ret
qglB8Selftest endp

                QGL_ENDS

.data
;; qgl$Ref's span constants. Its LOOP STATE is in registers like every
;; other filler's; only what is fixed for the span sits here.
qgl$rzd         dw      0                       ;; depth displacement
qgl$rbp0        dd      0                       ;; -width, sign extended

;; The perspective filler's span state. Its LOOP state is in registers
;; like every other filler's; what sits here is what changes once a
;; sub-span, which is the whole point of a sub-span.
qgl$p65536      real4   65536.0
qgl$ppu         dd      0                       ;; u,v at this boundary
qgl$ppv         dd      0
qgl$plu         dd      0                       ;; and at the next
qgl$plv         dd      0
qgl$psdu        dd      0                       ;; per pixel, in between
qgl$psdv        dd      0
qgl$pend        dw      0                       ;; PTEX boundary / ATEX width



;;
;; Indexed qgl$mode + qgl$zmode, both pre-scaled, so a call site adds and
;; never multiplies -- SURF_CMEM's trick, twice.
;;

qgl$fillTB      dw      qgl$WireO, qgl$WireW, qgl$WireT
                dw      qgl$FlatO, qgl$FlatW, qgl$FlatT
                dw      qgl$TexO,  qgl$TexW,  qgl$TexT
                dw      qgl$PtexO, qgl$PtexW, qgl$PtexT

;; THE PROJECTIVE ROWS ARE NOT qgl$Ref. There is no reference projective
;; filler to compare against, and more to the point the scanner pushes
;; three values onto the FPU stack for those modes: a filler that did not
;; consume them would overflow it in three scanlines. PTEX stays here;
;; b8_span routes ATEX directly to its real filler for the same reason.
qgl$refTB       dw      qgl$Ref, qgl$Ref, qgl$Ref
                dw      qgl$Ref, qgl$Ref, qgl$Ref
                dw      qgl$Ref, qgl$Ref, qgl$Ref
                dw      qgl$PtexO, qgl$PtexW, qgl$PtexT

qgl$curTB       dw      O qgl$fillTB

                end
