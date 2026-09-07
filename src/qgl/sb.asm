;; sb.asm -- the surface cache's builder: qgl's replacement for mgl's
;; uglBuildSurf.
;;
;; name: qglSbBuild
;; desc: composites a lightmapped surface: for every texel of the
;;       destination, samples the texture, bilinearly interpolates the
;;       four surrounding luxels, and writes the texel shaded through a
;;       colormap. This is the surface cache's builder -- see
;;       src/render/sb_build.c, which sets up an SBPARM and used to hand
;;       the texel loop to uglBuildSurf.
;;
;;       The maths is a faithful port of mgl's own uglsurf.asm (the
;;       already-fixed version, badlogic/mgl:src/ugl/uglsurf.asm), which
;;       is itself a statement-for-statement port of d_surf.bas's old
;;       sb_build. tools/sbref.py is the byte-exact Python reference,
;;       proven against the BASIC on the target (face 1544 mip 1: 0 of
;;       8192 bytes differ); this must reproduce it byte for byte.
;;
;;       WHERE THIS DIFFERS FROM mgl's VERSION, and why:
;;
;;       AGENTS.md's account of the churn bug: "the builder streams the
;;       atlas across many pages while holding a pointer to its
;;       destination, and the pool may take the destination's slot to
;;       map the next atlas page." mgl's fix was to re-derive the
;;       destination's EMS window every row instead of holding it. That
;;       works, but it still spends one of the four physical EMS page
;;       slots on the destination for the whole call.
;;
;;       d_surf.bas's own SC_MAXSUM bounds a cached surface's TOTAL bytes
;;       to one EMS page -- "2^a * 2^b <= 16384: one EMS page" is a
;;       REFUSAL at sc_alloc's own gate, not a hope. It does NOT bound
;;       where that block starts: sc_alloc packs blocks at SC_GRAN (256)
;;       granularity, not at their own size, so a full-page block can
;;       still start at any multiple of 256 and straddle the page
;;       boundary partway down. One ROW never straddles -- bps is a
;;       power of two that divides 16384 -- which is the guarantee that
;;       actually holds, and it is the same one mgl's own fix already
;;       relies on.
;;
;;       So this still touches the destination's EMS page once per row,
;;       the same count as mgl's fix. What changes is what happens
;;       BETWEEN those touches: the texel maths that used to run inside
;;       the mapped window now runs entirely in the scratch buffer, and
;;       each row is composited long before its own EMS copy happens, so
;;       nothing but that one row's own wrAccess-then-movsb pair ever
;;       touches the destination's slot for that row. That is the same
;;       immunity property mgl's fix has -- map immediately before use,
;;       nothing held across anything that could remap it -- just with
;;       the expensive per-texel work moved out of the window entirely.
;;
;;       That is also qgl.inc's own note on sb_build: "Put the
;;       destination and the depth buffer in conventional memory and the
;;       builder needs three [EMS windows] with one in hand." This is
;;       that move, for the destination half of it.
;;
;;       THE TEXTURE SIDE IS UNCHANGED: a texture cell is mkassets'
;;       guarantee, not sc_alloc's, but it is the same guarantee (never
;;       straddles a page), so it is read once via mgl's own rdAccess,
;;       exactly as before, and never touched again.
;;
;; obs.: - mgl's own EMS heap (src/ems/emsalloc.asm: "handle returned
;;         _can't_ be used to invoke the EMS manager") hands out handles
;;         private to its own accessors. The surface-cache store is
;;         allocated through it (d_surf.bas: uglNew&(UGL.EMS, ...)), so
;;         qgl cannot map its pages through qglGemMap -- that handle
;;         means nothing to a raw INT 67h call. The two mgl calls this
;;         file makes (rdAccess for the texture, wrAccess for the
;;         destination) are mgl's OWN dispatch table, ul$dctTB, reached
;;         the same way uglBuildSurf itself reaches it: a near call
;;         through a function pointer, register arguments, nothing on
;;         the stack. That is deliberate, not a shortcut -- see qgl.inc's
;;         own rule that an internal is register-convention, and this is
;;         the same convention one level out, into a table mgl already
;;         built and tested.
;;       - the destination's physical EMS slot is whichever one mgl's own
;;         ems_WrAccess uses (EMS_WRITEPAGE); q_map.bi documents this as
;;         "uglBuildSurf takes 0 and 1 for its own source and
;;         destination" and nothing else in this codebase ever touches
;;         either, so there is no eviction hazard to reason about beyond
;;         what mgl's own accessor already guarantees for a single call.
;;       - the scratch block is sized SC_PGBYTES (16384): the same bound
;;         SC_MAXSUM enforces on every surface sc_alloc will ever hand
;;         back. A surface that could not fit could not have been
;;         allocated.
;;       - state lives in .data?, not stack locals, for the same reason
;;         mgl's version does: it frees bp for the inner loop's counter.

                .model  medium, pascal
                .386

                include qgl.inc

;; mgl's DC struct, the handful of fields this needs (src/inc/ugl.inc).
;; Hardcoded rather than included, the same choice mgldc.asm/mglems.asm
;; already made: this file stays self-contained and does not pull mgl's
;; header graph onto qgl's include path.
DC_TYP          equ     2               ;; word
DC_BPS          equ     10              ;; word, bytes per scanline

;; mgl's DCT dispatch struct (src/inc/dct.inc): a table of near function
;; pointers, one row per dc type, the type value already pre-scaled as
;; its own byte offset (DC_EMS equ 128 = 2 * sizeof(DCT), the same trick
;; qgl.inc's own qgl$typeTB uses). Only the two offsets this file calls.
DCT_RDACCESS    equ     44              ;; near: in gs=dc,si=y*4 out ds:si
DCT_WRACCESS    equ     46              ;; near: in fs=dc,di=y*4 out es:di
                externdef ul$dctTB:byte

qglMemAlloc     proto   far pascal :dword

SC_PGBYTES      equ     16384           ;; d_surf.bas: one EMS page, and
                                        ;; sc_alloc refuses anything larger

LM_MAXDIM       equ     18              ;; 17 luxels + slack
LM_MAXCELLS     equ     LM_MAXDIM * LM_MAXDIM

;; patch placeholders -- deliberately wide so the assembler cannot pick a
;; shorter encoding and move every patch offset below it
__SIMM16__      equ     0DEADh
__SIMM32__      equ     0DEADBEEFh

;; mirrors bspfile.bi's SurfBuild / qcshared.h's SurfBuild -- the three
;; move together, the same rule the .bld lumps live by.
SBPARM          struc
sb_lmptr        dd      ?               ;; -> this face's luxel rect
sb_lmstride     dd      ?               ;; atlas bytes per row
sb_cmapptr      dd      ?               ;; -> colormap[64][256]
sb_au0          dd      ?               ;; initial u, 16.16
sb_av0          dd      ?               ;; initial v, 16.16
sb_du           dd      ?               ;; u step per texel
sb_dv           dd      ?               ;; v step per row
sb_sw           dw      ?               ;; surface width  (padded)
sb_sh           dw      ?               ;; surface height (padded)
sb_lmw          dw      ?               ;; luxel grid width
sb_lmh          dw      ?               ;; luxel grid height
sb_shift        dw      ?               ;; log2(texels per luxel)
sb_msk          dw      ?               ;; texture wrap mask
SBPARM          ends


.data?
sb$lgrid        dw      LM_MAXCELLS dup (?)     ;; t per luxel
sb$savebp       dw      ?

sb$v            dd      ?
sb$dv           dd      ?
sb$tacc         dd      ?
sb$tstep        dd      ?
sb$ty           dd      ?

sb$dufrc        dw      ?
sb$duint        dw      ?
sb$u0frc        dw      ?
sb$u0int        dw      ?

sb$t00          dw      ?
sb$t10          dw      ?
sb$t01          dw      ?
sb$t11          dw      ?
sb$tleft        dw      ?
sb$tright       dw      ?

sb$texbase      dw      ?
sb$texbps       dw      ?
sb$texrow       dw      ?

sb$cmofs        dw      ?
sb$cmseg        dw      ?
sb$lmoff        dw      ?
sb$lmseg        dw      ?
sb$lmstride     dw      ?

sb$sw           dw      ?
sb$sh           dw      ?
sb$lmw          dw      ?
sb$lmh          dw      ?
sb$lmw2         dw      ?
sb$lmh2         dw      ?
sb$shift        dw      ?
sb$ishift       dw      ?
sb$stp          dw      ?
sb$msk          dw      ?

sb$yy           dw      ?
sb$xx           dw      ?
sb$rowofs       dw      ?               ;; scratch-block offset of row sb$yy
sb$lyoff        dw      ?
sb$lynext       dw      ?
sb$lx           dw      ?
sb$nfull        dw      ?
sb$cnt          dw      ?

sb$dstfs        dw      ?               ;; dstDc's segment, for the one
                                        ;; wrAccess call at the very end


;; .data, not .data?: this needs a real zero baked into the EXE image, not
;; BSS's runtime zero-fill -- "never assume implicit init" is this
;; codebase's own rule, and JWasm already flagged the alternative
;; (A4184: initialized data not supported in BSS segments).
.data
sb$mseg         dw      0               ;; conventional scratch block's
                                        ;; segment, 0 until first use.
                                        ;; SC_PGBYTES does not fit in
                                        ;; DGROUP (L2041: stack plus data
                                        ;; exceed 64K) so it lives in its
                                        ;; own far block instead, sized
                                        ;; once and kept for the life of
                                        ;; the program, the same choice
                                        ;; qglMemAlloc's own header
                                        ;; documents for every caller of
                                        ;; it: "one big block for the
                                        ;; life of the program"


;; the vertical half of the bilinear, once per span per row -- see
;; uglsurf.asm's TLERP, which this reproduces exactly
SB_TLERP        macro   top:req, bot:req, dst:req
                mov     ax, ss:&bot
                sub     ax, ss:&top
                movsx   eax, ax
                imul    eax, ss:sb$ty
                sar     eax, 16
                add     ax, ss:&top
                mov     ss:&dst, ax
endm

;; bx= light level -> ax= t (floored at 64), bx destroyed. See uglsurf.asm's
;; LEVEL2T for the derivation of 66/16320/64.
SB_LEVEL2T      macro
                local   ok
                mov     ax, bx
                shl     ax, 6
                shl     bx, 1
                add     bx, ax
                mov     ax, 16320
                sub     ax, bx
                cmp     ax, 64
                jge     ok
                mov     ax, 64
ok:
endm

QGL_CODE

;;::::::::::::::
;; qglSbBuild (dstDc:dword, texDc:dword, parm:dword) :word
qglSbBuild      proc    public uses bx cx dx di si es ds fs gs,\
                        dstDc:dword, texDc:dword, parm:dword

                mov     fs, W parm+2
                mov     bx, W parm+0

                mov     ax, W fs:[bx].SBPARM.sb_au0+0
                mov     ss:sb$u0frc, ax
                mov     ax, W fs:[bx].SBPARM.sb_au0+2
                mov     ss:sb$u0int, ax

                mov     eax, fs:[bx].SBPARM.sb_av0
                mov     ss:sb$v, eax
                mov     eax, fs:[bx].SBPARM.sb_dv
                mov     ss:sb$dv, eax

                mov     ax, W fs:[bx].SBPARM.sb_du+0
                mov     ss:sb$dufrc, ax
                mov     ax, W fs:[bx].SBPARM.sb_du+2
                mov     ss:sb$duint, ax

                mov     ax, fs:[bx].SBPARM.sb_sw
                mov     ss:sb$sw, ax
                mov     ax, fs:[bx].SBPARM.sb_sh
                mov     ss:sb$sh, ax
                mov     ax, fs:[bx].SBPARM.sb_msk
                mov     ss:sb$msk, ax

                mov     ax, fs:[bx].SBPARM.sb_shift
                mov     ss:sb$shift, ax
                mov     cx, ax
                mov     dx, 16
                sub     dx, ax
                mov     ss:sb$ishift, dx
                mov     ax, 1
                shl     ax, cl
                mov     ss:sb$stp, ax

                mov     ax, fs:[bx].SBPARM.sb_lmw
                mov     ss:sb$lmw, ax
                sub     ax, 2
                mov     ss:sb$lmw2, ax
                mov     ax, fs:[bx].SBPARM.sb_lmh
                mov     ss:sb$lmh, ax
                sub     ax, 2
                mov     ss:sb$lmh2, ax

                mov     ax, W fs:[bx].SBPARM.sb_lmptr+0
                mov     ss:sb$lmoff, ax
                mov     ax, W fs:[bx].SBPARM.sb_lmptr+2
                mov     ss:sb$lmseg, ax
                mov     ax, W fs:[bx].SBPARM.sb_lmstride+0
                mov     ss:sb$lmstride, ax
                mov     ax, W fs:[bx].SBPARM.sb_cmapptr+0
                mov     ss:sb$cmofs, ax
                mov     ax, W fs:[bx].SBPARM.sb_cmapptr+2
                mov     ss:sb$cmseg, ax

                ;; a grid we cannot hold overruns sb$lgrid -- refuse
                mov     ax, ss:sb$lmw
                imul    ax, ss:sb$lmh
                cmp     ax, LM_MAXCELLS
                ja      @@error

                ;; a surface we cannot hold overruns the scratch block. sc_alloc
                ;; already refuses this (SC_MAXSUM), so this is a second
                ;; opinion, not the first line of defence.
                mov     ax, ss:sb$sw
                imul    ax, ss:sb$sh
                cmp     ax, SC_PGBYTES
                ja      @@error

                ;; the scratch block, allocated once and kept -- see
                ;; sb$mseg's own comment on why it cannot live in DGROUP.
                cmp     ss:sb$mseg, 0
                jne     @@havemem
                invoke  qglMemAlloc, SC_PGBYTES ;; dx:ax, offset always 0;
                                                ;; dx=0 means failure
                test    dx, dx
                jz      @@error
                mov     ss:sb$mseg, dx
@@havemem:

                mov     ss:sb$savebp, bp

                ;;
                ;; ---- expand the luxel rows, once --------------------
                ;;
                push    ds
                mov     ds, ss:sb$lmseg
                mov     si, ss:sb$lmoff
                push    ss
                pop     es
                mov     di, O sb$lgrid

                mov     dx, ss:sb$lmh

@@exprow:       mov     cx, ss:sb$lmw
                push    si

@@expand:       mov     bl, ds:[si]
                xor     bh, bh
                inc     si
                SB_LEVEL2T
                mov     es:[di], ax
                add     di, 2
                dec     cx
                jnz     @@expand

                pop     si
                add     si, ss:sb$lmstride
                dec     dx
                jnz     @@exprow

                pop     ds

                ;;
                ;; ---- map the texture, once ---------------------------
                ;;
                mov     fs, W texDc+2
                mov     ax, fs:[DC_BPS]
                mov     ss:sb$texbps, ax
                mov     bx, fs:[DC_TYP]
                mov     gs, W texDc+2
                xor     si, si
                call    W ss:ul$dctTB[bx+DCT_RDACCESS]  ;; ds:si-> texture
                mov     ss:sb$texbase, si

                ;; the destination is resolved once, at the very end --
                ;; stash its segment now, while fs is free to hold it.
                mov     ax, W dstDc+2
                mov     ss:sb$dstfs, ax

                mov     ax, ss:sb$lmw
                dec     ax
                jg      @F
                mov     ax, 1
@@:             mov     ss:sb$nfull, ax

                ;;
                ;; ---- patch the per-surface constants ------------------
                ;;
                mov     ax, ss:sb$dufrc
                mov     W cs:sb_pdufr+2, ax
                mov     W cs:sb_fdufr+2, ax
                mov     ax, ss:sb$duint
                mov     W cs:sb_pduin+2, ax
                mov     W cs:sb_fduin+2, ax
                mov     ax, ss:sb$msk
                mov     W cs:sb_pmsk+2, ax
                mov     W cs:sb_fmsk+2, ax
                movzx   eax, W ss:sb$cmofs
                mov     D cs:sb_pcmap+4, eax

                xor     ax, ax
                mov     ss:sb$yy, ax

                ;;
                ;; ---- rows ---------------------------------------------
                ;;
                ;; es addresses the scratch block for the whole loop:
                ;; unlike the destination's EMS window, a flat
                ;; conventional buffer never needs remapping between rows.
                mov     ax, ss:sb$mseg
                mov     es, ax

@@row:          mov     ax, ss:sb$yy
                cmp     ax, ss:sb$sh
                jae     @@done

                mov     eax, ss:sb$v
                shr     eax, 16
                and     ax, ss:sb$msk
                mov     cx, ss:sb$texbps
                mul     cx
                add     ax, ss:sb$texbase
                mov     ss:sb$texrow, ax
                mov     W cs:sb_ptrow+2, ax
                mov     W cs:sb_ftrow, ax

                mov     ax, ss:sb$yy
                mov     cx, ss:sb$shift
                shr     ax, cl
                cmp     ax, ss:sb$lmh2
                jle     @F
                mov     ax, ss:sb$lmh2
@@:             or      ax, ax
                jge     @F
                xor     ax, ax
@@:             mov     bx, ax

                mov     ax, bx
                imul    ax, ss:sb$lmw
                mov     ss:sb$lyoff, ax
                add     ax, ss:sb$lmw
                mov     ss:sb$lynext, ax

                mov     ax, bx
                imul    ax, ss:sb$stp
                mov     dx, ss:sb$yy
                sub     dx, ax
                movzx   edx, dx
                shl     edx, 16
                mov     cx, ss:sb$shift
                shr     edx, cl
                cmp     edx, 65536
                jbe     @F
                mov     edx, 65536
@@:             mov     ss:sb$ty, edx

                ;; row start in the scratch block: yy * sw, plain
                ;; arithmetic, 0-based within its own far segment -- no
                ;; window, so nothing here can be evicted.
                mov     ax, ss:sb$yy
                mov     cx, ss:sb$sw
                mul     cx
                mov     ss:sb$rowofs, ax
                mov     di, ax

                mov     ax, ss:sb$u0frc
                mov     cx, ax
                mov     ax, ss:sb$u0int
                and     ax, ss:sb$msk
                mov     bx, ax

                xor     ax, ax
                mov     ss:sb$xx, ax
                mov     ss:sb$lx, ax

                ;;
                ;; ---- one luxel span at a time -------------------------
                ;;
@@span:         mov     ax, ss:sb$xx
                cmp     ax, ss:sb$sw
                jae     @@endrow

                mov     dx, ss:sb$sw
                sub     dx, ax
                mov     ax, ss:sb$lx
                cmp     ax, ss:sb$nfull
                jae     @@tailspan

                cmp     dx, ss:sb$stp
                jbe     @F
                mov     dx, ss:sb$stp
@@:             mov     ss:sb$cnt, dx

                push    bx
                mov     bx, ss:sb$lx
                add     bx, ss:sb$lyoff
                shl     bx, 1
                mov     ax, ss:sb$lgrid[bx]
                mov     dx, ss:sb$lgrid[bx+2]
                mov     ss:sb$t00, ax
                mov     ss:sb$t10, dx

                mov     bx, ss:sb$lx
                add     bx, ss:sb$lynext
                shl     bx, 1
                mov     ax, ss:sb$lgrid[bx]
                mov     dx, ss:sb$lgrid[bx+2]
                mov     ss:sb$t01, ax
                mov     ss:sb$t11, dx
                pop     bx

                SB_TLERP sb$t00, sb$t01, sb$tleft
                SB_TLERP sb$t10, sb$t11, sb$tright

                mov     ax, ss:sb$tleft
                cmp     ax, ss:sb$tright
                je      @@flatspan

                push    cx
                mov     cl, B ss:sb$ishift
                mov     ax, ss:sb$tright
                sub     ax, ss:sb$tleft
                movsx   eax, ax
                shl     eax, cl
                mov     ss:sb$tstep, eax
                pop     cx
                movzx   eax, W ss:sb$tleft
                shl     eax, 16
                mov     ss:sb$tacc, eax

                jmp     @@runspan

@@tailspan:     mov     ss:sb$cnt, dx

                push    bx
                mov     bx, ss:sb$lmw2
                or      bx, bx
                jge     @F
                xor     bx, bx
@@:             mov     si, bx
                add     si, ss:sb$lyoff
                shl     si, 1
                mov     ax, ss:sb$lgrid[si+2]
                mov     ss:sb$t00, ax
                mov     si, bx
                add     si, ss:sb$lynext
                shl     si, 1
                mov     ax, ss:sb$lgrid[si+2]
                mov     ss:sb$t01, ax
                pop     bx
                SB_TLERP sb$t00, sb$t01, sb$tleft

@@flatspan:     mov     ax, ss:sb$tleft
                and     ax, 0FF00h
                add     ax, ss:sb$cmofs
                mov     dx, ax

                mov     si, ss:sb$texrow
                mov     bp, ss:sb$cnt
                add     di, bp
                neg     bp

@@flat:         movzx   eax, B ds:[bx+__SIMM16__]
sb_ftrow        equ     $ - 2
                add     ax, dx
                mov     al, gs:[eax]
                mov     es:[di+bp], al          ;; es:scratch block, flat
sb_fdufr:       add     cx, __SIMM16__
sb_fduin:       adc     bx, __SIMM16__
sb_fmsk:        and     bx, __SIMM16__
                inc     bp
                jnz     @@flat

                jmp     @@nextspan

@@runspan:      mov     si, ss:sb$texrow
                mov     bp, ss:sb$cnt
                add     di, bp
                neg     bp

                mov     edx, ss:sb$tacc

@@px:           mov     eax, edx
                shr     eax, 16
                and     ax, 0FF00h
sb_ptrow:       or      al, B ds:[bx+__SIMM16__]
sb_pcmap:       mov     al, gs:[eax+__SIMM32__]
                mov     es:[di+bp], al          ;; es:scratch block, flat

                add     edx, ss:sb$tstep
sb_pdufr:       add     cx, __SIMM16__
sb_pduin:       adc     bx, __SIMM16__
sb_pmsk:        and     bx, __SIMM16__
                inc     bp
                jnz     @@px

@@nextspan:     mov     ax, ss:sb$cnt
                add     ss:sb$xx, ax
                inc     ss:sb$lx
                mov     di, ss:sb$rowofs
                add     di, ss:sb$xx
                jmp     @@span

@@endrow:       mov     eax, ss:sb$dv
                add     ss:sb$v, eax
                inc     ss:sb$yy
                jmp     @@row

                ;;
                ;; ---- copy the scratch block to its EMS page, row by row
                ;;
                ;; SC_MAXSUM bounds a surface's TOTAL bytes to one page,
                ;; not its OFFSET: sc_alloc packs blocks at SC_GRAN (256)
                ;; granularity, not at their own size, so a block up to
                ;; 16384 bytes can start anywhere a multiple of 256 bytes
                ;; allows and straddle the page boundary partway through.
                ;; One ROW never straddles (bps is a power of two that
                ;; divides 16384), which is what makes wrAccess's own
                ;; per-row contract the right one to reuse here, exactly
                ;; as mgl's own fixed uglBuildSurf does. The only
                ;; difference from mgl's version is WHERE the row comes
                ;; from: a flat scratch buffer instead of live per-texel
                ;; computation, so the EMS side of this is nothing more
                ;; than mgl's own per-row copy with the maths already
                ;; done.
                ;;
@@done:         mov     fs, ss:sb$dstfs
                mov     ax, ss:sb$mseg
                mov     ds, ax                  ;; ds-> scratch, fixed for
                                                ;; every row of the copy

                xor     ax, ax
                mov     ss:sb$yy, ax            ;; reused as the copy's
                                                ;; own row counter

@@copyrow:      mov     ax, ss:sb$yy
                cmp     ax, ss:sb$sh
                jae     @@copied

                mov     cx, ss:sb$sw
                mul     cx                      ;; ax = yy * sw
                mov     si, ax                  ;; ds:si-> this row,
                                                ;; scratch-relative

                mov     bx, fs:[DC_TYP]
                mov     ax, ss:sb$yy
                shl     ax, 2                   ;; y*4, wrAccess's index
                mov     di, ax
                call    W ss:ul$dctTB[bx+DCT_WRACCESS] ;; es:di-> this
                                                ;; row, and only this row

                mov     cx, ss:sb$sw
                cld
                rep     movsb

                inc     ss:sb$yy
                jmp     @@copyrow

@@copied:       mov     bp, ss:sb$savebp
                mov     ax, 1
                ret

@@error:        xor     ax, ax
                ret
qglSbBuild      endp

QGL_ENDS
                end
