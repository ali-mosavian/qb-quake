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
;;       The destination is written in place, mapped once and held
;;       across the texel loop, which calls nothing. That is sound
;;       because sc_alloc's blocks are self-aligned to their own size
;;       (<= one EMS page), so a surface never straddles a page -- and
;;       qglSbBuild checks it rather than trusts it: the last row must
;;       come back (sh-1)*bps past row 0 in the same window, or the
;;       build is refused. The texture cell is mkassets' guarantee of
;;       the same kind, read once through qglSfRdRow.
;;
;;       The destination used to be built in a 16K conventional scratch
;;       block and copied row by row; writing in place saves the copy
;;       and the block.
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
;;       - state lives in .data?, not stack locals, for the same reason
;;         mgl's version does: it frees bp for the inner loop's counter.

                .model  medium, pascal
                .386

                include qgl.inc

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


;; Ordered dither on t, in the surface's own x,y so a cached surface is
;; the same picture from any camera: raw*16 + 8 - 128, about half a
;; colormap row either way.
.data
sb$bayer        dw        -120,    8,  -88,   40
                dw          72,  -56,  104,  -24
                dw         -72,   56, -104,   24
                dw         120,   -8,   88,  -40

.data?
sb$lgrid        dw      LM_MAXCELLS dup (?)     ;; t per luxel
sb$drow         dw      4 dup (?)               ;; this row's four, by
                                                ;; destination offset and 3
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
sb$texseg       dw      ?

sb$dstbps       dw      ?
sb$dstbase      dw      ?               ;; row 0, in window 1
sb$dstseg       dw      ?
sb$dstlast      dw      ?               ;; the last row, to prove the block
sb$dstlseg      dw      ?               ;; sits in that one window

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

                ;; a surface past one EMS page cannot be addressed flat.
                ;; sc_alloc already refuses this (SC_MAXSUM).
                mov     ax, ss:sb$sw
                imul    ax, ss:sb$sh
                cmp     ax, SC_PGBYTES
                ja      @@error

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
                mov     ss:sb$texseg, dx

                ;;
                ;; ---- map the destination, once -----------------------
                ;;
                ;; Written in place through window 1, held across the
                ;; loop: nothing below calls out. Row y is base + y*bps
                ;; only if the whole block sits in one window, which
                ;; sc_alloc's self-aligned blocks do -- checked here by
                ;; asking for the last row and then row 0, both while ds
                ;; is still DGROUP (gem.asm reads its frame through ds).
                les     bx, dstDc
                mov     ax, es:[bx].Surface.bps
                mov     ss:sb$dstbps, ax
                mov     ax, ss:sb$sh
                dec     ax
                invoke  qglSfWrRow, dstDc, ax
                mov     ss:sb$dstlast, ax
                mov     ss:sb$dstlseg, dx
                invoke  qglSfWrRow, dstDc, 0
                mov     ss:sb$dstbase, ax
                mov     ss:sb$dstseg, dx
                test    dx, dx
                jz      @@error
                cmp     dx, ss:sb$dstlseg
                jne     @@error
                mov     ax, ss:sb$sh
                dec     ax
                mul     W ss:sb$dstbps
                jc      @@error
                add     ax, ss:sb$dstbase
                jc      @@error
                cmp     ax, ss:sb$dstlast
                jne     @@error
                add     ax, ss:sb$sw
                jc      @@error
                cmp     ax, SC_PGBYTES          ;; and in that one window
                ja      @@error

                mov     ds, ss:sb$texseg        ;; ds: texture, for the loop

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
                mov     ax, ss:sb$duint
                mov     W cs:sb_pduin+2, ax
                mov     ax, ss:sb$msk
                mov     W cs:sb_pmsk+2, ax
                movzx   eax, W ss:sb$cmofs
                mov     D cs:sb_pcmap+4, eax

                xor     ax, ax
                mov     ss:sb$yy, ax

                ;;
                ;; ---- rows ---------------------------------------------
                ;;
                mov     es, ss:sb$dstseg        ;; es: the destination

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

                mov     ax, ss:sb$yy
                mul     W ss:sb$dstbps
                add     ax, ss:sb$dstbase
                mov     ss:sb$rowofs, ax
                mov     di, ax

                ;; the loop knows a pixel by its destination offset, di+bp,
                ;; which is rowofs + x: rotate the row's four by rowofs
                mov     ax, ss:sb$yy
                and     ax, 3
                shl     ax, 2
                xor     si, si
@@drow:         mov     bx, si
                sub     bx, ss:sb$rowofs
                and     bx, 3
                add     bx, ax
                shl     bx, 1
                mov     dx, ss:sb$bayer[bx]
                mov     bx, si
                shl     bx, 1
                mov     ss:sb$drow[bx], dx
                inc     si
                cmp     si, 4
                jb      @@drow

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

                ;; a flat span dithers per pixel too, so it is a run
                ;; with no step
@@flatspan:     mov     ss:sb$tstep, 0
                movzx   eax, W ss:sb$tleft
                shl     eax, 16
                mov     ss:sb$tacc, eax

@@runspan:      mov     si, ss:sb$texrow
                mov     bp, ss:sb$cnt
                add     di, bp
                neg     bp

                mov     edx, ss:sb$tacc

@@px:           mov     eax, edx
                shr     eax, 16
                lea     si, [bp+di]
                and     esi, 3
                add     ax, ss:sb$drow[esi*2]
                jns     @F                      ;; under 64 is row 0
                xor     ax, ax
@@:             cmp     ax, 16384               ;; over row 63 is row 63
                jb      @F
                mov     ax, 16128
@@:             and     ax, 0FF00h
sb_ptrow:       or      al, B ds:[bx+__SIMM16__]
sb_pcmap:       mov     al, gs:[eax+__SIMM32__]
                mov     es:[di+bp], al          ;; es: the destination

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
                ;; ---- done ---------------------------------------------
                ;;
                ;; bp was the texel loop's counter, and the epilogue
                ;; unwinds through it.
@@done:         mov     bp, ss:sb$savebp
                mov     ax, 1
                ret

@@error:        xor     ax, ax
                ret
qglSbBuild      endp

QGL_ENDS
                end
