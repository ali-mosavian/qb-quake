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
;;       CORRECTION, checked against the actual allocator rather than
;;       assumed: sc_alloc's blocks ARE self-aligned to their own size.
;;       sc_grab (fresh store) rounds its offset up to a multiple of the
;;       block's own byte size before granting; sc_bsplit halves an
;;       aligned parent, which stays aligned; every reuse path inherits
;;       an offset that was aligned when the block was made. Since every
;;       size sc_alloc can hand out (SC_MAXSUM bounds it to <= 16384,
;;       one EMS page) divides SC_PGBYTES evenly, a live block never
;;       straddles a page in practice -- an earlier version of this
;;       comment claimed otherwise and was wrong; do not trust that
;;       claim if it resurfaces elsewhere.
;;
;;       That said, nothing in sc_alloc or qglRsTex CHECKS this -- it is
;;       an invariant of today's allocator, not a refusal anywhere in
;;       the chain, so a future change to sc_alloc could break it
;;       silently. This file writes one row at a time regardless: it
;;       costs nothing extra (mgl's own fix does the same, once per row,
;;       for the destination), and it means qglSbBuild's own correctness
;;       never depends on an invariant it cannot see.
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
;;       The texture cell is mkassets' guarantee, not sc_alloc's, but it
;;       is the same guarantee (never straddles a page), so it is read
;;       once through qglSfRdRow and never touched again.
;;
;; obs.: - NOTHING HERE IS MGL'S ANY MORE, and that is the fix, not a
;;         tidy-up. Both the destination write and the texture read used
;;         to go through mgl's dispatch table, ul$dctTB. Its entries are
;;         NEAR pointers (dct.inc: `rdAccess dw NULL ;; near!`), offsets
;;         into ugl_text -- and this file assembles into qgl_text, which
;;         the linker places elsewhere entirely (measured: qgl_text at
;;         0x2660, ugl_text at 0x3A82). A near call keeps CS, so
;;         `call ss:ul$dctTB[bx+rdAccess]` did not reach ems_RdAccess at
;;         all: it jumped to the same OFFSET inside qgl_text, 69 bytes
;;         into qgl$Fixup, the rasteriser's own SMC patcher. Real mode,
;;         so no fault -- it ran, patched immediates from garbage, and
;;         never came back. qgl.inc's own header names this hazard ("a
;;         near call cannot cross the per-module segments that .model
;;         medium hands out") and the mistake was believing QGL_CODE was
;;         UGL_CODE; it opens qgl_text, not ugl_text.
;;
;;         So: the store is qglSfNew&(...,QGL_SURF_EMS,...) and written
;;         with qglSfWrRow; the atlas is a qgl surface too now
;;         (mod_tex.bas, qglSfFromFileBas off TEXR.RAW/TEXS.RAW) and is
;;         read with qglSfRdRow. Cross-module calls out of qgl are FAR
;;         calls to public entries, which is what mglems.asm already did
;;         correctly for emsMapEx.
;;       - THE SLOTS. The atlas is QGL_TEX_SLOT (qgl.inc), 0: it is the
;;         one window held across the whole texel loop, so it cannot
;;         share with the luxel rect (PAGE_SLOT, 2) or the colormap
;;         (CM_SLOT, 3), both live at the same time. Slot 0 is free
;;         because it is exactly what mgl's legacy rdAccess used for
;;         this atlas, and every other mgl EMS object goes through
;;         uglMapEx with an explicit 2 or 3 -- checked in model.bas, not
;;         assumed. The destination goes through the PLAIN write
;;         accessor, EMS_WRITEPAGE (1), which is qgl's own and shares
;;         with nothing live here -- an earlier version of this note said
;;         PAGE_SLOT and was describing code that no longer exists. So
;;         the four windows are four distinct slots: atlas 0, destination
;;         1, luxels 2, colormap 3.
;;       - every map anywhere goes through qglGemMap now; mgl's emsMapEx
;;         maps nothing. The per-slot record is gem's, and qgl$emsCtx's
;;         ppgTB in dct/dctems.asm is a copy of it for slots 0 and 1.
;;       - the scratch block is sized SC_PGBYTES (16384): the same bound
;;         SC_MAXSUM enforces on every surface sc_alloc will ever hand
;;         back. A surface that could not fit could not have been
;;         allocated.
;;       - state lives in .data?, not stack locals, for the same reason
;;         mgl's version does: it frees bp for the inner loop's counter.

                .model  medium, pascal
                .386

                include qgl.inc

qglMemAlloc     proto   far pascal :dword
qglSfRdRow      proto   far pascal :dword, :word
qglSfWrRow      proto   far pascal :dword, :word

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
sb_msk          dw      ?               ;; u wrap mask, cell width - 1
sb_vmsk         dw      ?               ;; v wrap mask, cell height - 1 --
                                        ;; a cell is the texture's own
                                        ;; aspect now, so one mask cannot
                                        ;; serve both axes
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
sb$vmsk         dw      ?

sb$yy           dw      ?
sb$xx           dw      ?
sb$rowofs       dw      ?               ;; scratch-block offset of row sb$yy
sb$lyoff        dw      ?
sb$lynext       dw      ?
sb$lx           dw      ?
sb$nfull        dw      ?
sb$cnt          dw      ?


;; .data, not .data?: this needs a real zero baked into the EXE image, not
;; BSS's runtime zero-fill -- "never assume implicit init" is this
;; codebase's own rule, and JWasm already flagged the alternative
;; (A4184: initialized data not supported in BSS segments).
.data
sb$mseg         dw      0               ;; conventional scratch block's
                                        ;; segment, 0 until qglSbReserve.
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
;; qglSbReserve () -> ax nonzero once the scratch block exists
;;
;; The builder used to take its block at the first lit face, and short
;; of it every lit surface stayed zeros: a black world, polys and
;; sc_built reading normal, the unlit frame right. sc_store_open calls
;; this at load so a shortfall is an error with a name.
;;::::::::::::::
qglSbReserve    proc    public uses bx cx dx

                cmp     ss:sb$mseg, 0
                jne     @@have
                invoke  qglMemAlloc, SC_PGBYTES ;; dx:ax, offset always 0;
                                                ;; dx=0 means failure
                test    dx, dx
                jz      @@none
                mov     ss:sb$mseg, dx
@@have:         mov     ax, 1
                ret
@@none:         xor     ax, ax
                ret
qglSbReserve    endp

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
                mov     ax, fs:[bx].SBPARM.sb_vmsk
                mov     ss:sb$vmsk, ax

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

                ;; the scratch block -- reserved at load by sc_store_open,
                ;; taken here only for a caller that skipped that
                invoke  qglSbReserve
                test    ax, ax
                jz      @@error

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
                ;; One row-0 pointer for the whole cell, which is what
                ;; makes the texel loop's `ds:[bx+texrow]` legal: a cell
                ;; is a flat run of cell*cell bytes and never straddles a
                ;; page (mkassets places each at a multiple of its own
                ;; size), so nothing below has to remap.
                les     bx, texDc
                mov     ax, es:[bx].Surface.bps
                mov     ss:sb$texbps, ax
                invoke  qglSfRdRow, texDc, 0    ;; dx:ax-> the cell
                mov     ss:sb$texbase, ax
                mov     ds, dx                  ;; ds: texture, for the loop

                ;; gs is the COLORMAP's, not the texture's -- uglsurf.asm
                ;; line 368, "colormap keeps a segment". The port dropped
                ;; this line, which is why sb$cmseg was written and never
                ;; read: every shaded texel would have come out of the
                ;; texture's segment instead, at the colormap's offset.
                mov     gs, ss:sb$cmseg

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
                and     ax, ss:sb$vmsk
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
                ;; sc_alloc's blocks are self-aligned to their own size
                ;; (checked, not assumed -- see this file's header), so in
                ;; practice a live block never straddles a page. Nothing
                ;; downstream of sc_alloc CHECKS that, though, so this
                ;; still writes one row at a time through qglSfWrRow's
                ;; own per-row contract rather than trust it -- exactly
                ;; as mgl's own fixed uglBuildSurf does, and at the same
                ;; cost (one EMS touch per row either way). The only
                ;; difference from mgl's version is WHERE the row comes
                ;; from: a flat scratch buffer instead of live per-texel
                ;; computation, so this is nothing more than mgl's own
                ;; per-row copy with the maths already done.
                ;;
                ;; dstDc is qgl's own Surface now, not an mgl DC -- see
                ;; this file's header -- so the row pointer comes from
                ;; qglSfWrRow, a qgl_ entry, rather than ul$dctTB. That
                ;; is the whole point of this file no longer naming any
                ;; mgl symbol at all.
                ;;
                ;; BP FIRST, and it is load-bearing: the texel loop above
                ;; uses bp as its own counter, so the frame pointer is
                ;; gone by here -- and `dstDc` below is a stack parameter,
                ;; read bp-relative. The version this replaced never hit
                ;; it because it reached the destination through a saved
                ;; segment (sb$dstfs) and named no parameter at all.
@@done:         mov     bp, ss:sb$savebp

                xor     ax, ax
                mov     ss:sb$yy, ax            ;; reused as the copy's
                                                ;; own row counter

                ;; DS MUST BE DGROUP ACROSS qglSfWrRow, and the texel loop
                ;; above left it pointing at the texture. gem.asm reaches
                ;; its own qgl$pgframe with no segment override -- plain
                ;; DS, the medium-model default -- so a qglGemMap made
                ;; with ds elsewhere adds a word of the WRONG segment as
                ;; the page frame and every row lands somewhere arbitrary.
                ;; So ds is restored at the top of each iteration and only
                ;; borrowed for the movsb, rather than held on the scratch
                ;; block for the whole loop.
@@copyrow:      push    ss                      ;; ss IS DGROUP here, and is
                pop     ds                      ;; what every ss: override
                                                ;; in this file already
                                                ;; relies on -- no fixup to
                                                ;; disagree with BASIC's
                                                ;; own idea of the segment

                mov     ax, ss:sb$yy
                cmp     ax, ss:sb$sh
                jae     @@copied

                mov     cx, ss:sb$sw
                mul     cx                      ;; ax = yy * sw
                mov     si, ax                  ;; scratch-relative row,
                                                ;; and qglSfWrRow preserves
                                                ;; si -- checked against
                                                ;; sf.asm's `uses`, not
                                                ;; assumed
                invoke  qglSfWrRow, dstDc, ss:sb$yy
                mov     di, ax                  ;; es:di-> this row, and
                mov     es, dx                  ;; only this row

                mov     ds, ss:sb$mseg          ;; ds:si-> the scratch row,
                                                ;; for the copy alone
                mov     cx, ss:sb$sw
                cld
                rep     movsb

                inc     ss:sb$yy
                jmp     @@copyrow

@@copied:       mov     ax, 1                   ;; bp restored at @@done
                ret

@@error:        xor     ax, ax
                ret
qglSbBuild      endp

QGL_ENDS
                end
