;;
;; b8span.asm -- 8bpp scanline fillers, one per (mode, depth mode).
;;
;; name: b8_span / qgl$fixup
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
                externdef qgl$tshift:word
                externdef qgl$tumsk:word
                externdef qgl$tvmsk:word
                externdef qgl$tofs:word
                externdef qgl$fcol:word
                externdef qgl$mode:word

                public  qgl$fixup, b8_span

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
;; qgl_rs_ref swings the whole table over to the reference filler, which
;; is how a patched filler is judged against one that has no patch site.
;;::::::::::::::
b8_span         proc    near
                mov     ax, qgl$curTB
                add     ax, qgl$mode
                add     ax, qgl$zmode
                xchg    ax, bx
                mov     bx, [bx]
                xchg    ax, bx
                ret
b8_span         endp

;;::::::::::::::
;; qgl_rs_ref ( on:word ) -- send every mode to the reference filler.
;;::::::::::::::
qgl_rs_ref      proc    far public uses ax,\
                        on:word
                mov     ax, O qgl$fillTB
                cmp     on, 0
                je      @F
                mov     ax, O qgl$refTB
@@:             mov     qgl$curTB, ax
                ret
qgl_rs_ref      endp

                QGL_ENDS

.data
;; qgl$ref's span constants. Its LOOP STATE is in registers like every
;; other filler's; only what is fixed for the span sits here.
qgl$rzd         dw      0                       ;; depth displacement
qgl$rbp0        dd      0                       ;; -width, sign extended



;;
;; Indexed qgl$mode + qgl$zmode, both pre-scaled, so a call site adds and
;; never multiplies -- SURF_CMEM's trick, twice.
;;
;; Perspective shares the affine entries. The sub-span divide is not
;; written, and the affine filler draws a face that is right where 1/z is
;; flat and distorted where it is not, which is what "affine" means and is
;; visible. An empty entry would draw a face that is right nowhere.
;;

qgl$fillTB      dw      qgl$wire_o, qgl$wire_w, qgl$wire_t
                dw      qgl$flat_o, qgl$flat_w, qgl$flat_t
                dw      qgl$tex_o,  qgl$tex_w,  qgl$tex_t
                dw      qgl$tex_o,  qgl$tex_w,  qgl$tex_t

qgl$refTB       dw      qgl$ref, qgl$ref, qgl$ref
                dw      qgl$ref, qgl$ref, qgl$ref
                dw      qgl$ref, qgl$ref, qgl$ref
                dw      qgl$ref, qgl$ref, qgl$ref

qgl$curTB       dw      O qgl$fillTB

                end
