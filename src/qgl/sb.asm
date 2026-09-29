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
;;       Native 1:1 mip cells take Quake's path: four fixed 16/8/4/2
;;       block drawers, right-to-left interpolation, and no dither. The
;;       generic path remains for atlas levels which share a larger cell
;;       and therefore need resampling.
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
sb_sw           dw      ?               ;; logical surface width
sb_sh           dw      ?               ;; logical surface height
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
sb$savebp       dd      ?

sb$v            dd      ?
sb$dv           dd      ?
sb$tacc         dd      ?
sb$tstep        dd      ?
sb$yin          dw      ?

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
sb$dstw         dw      ?
sb$dsth         dw      ?
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

;; Quake block-drawer state. These are globals for the same reason as
;; Quake's surf8.s state: the hot loop gets the registers.
sb$q_cols       dw      ?
sb$q_vblocks    dw      ?
sb$q_lcol       dw      ?
sb$q_lptr       dw      ?
sb$q_lrow       dw      ?
sb$q_destcol    dw      ?
sb$q_sx         dw      ?
sb$q_sy         dw      ?
sb$q_texsize    dw      ?
sb$q_srcmax     dw      ?
sb$q_left       dw      ?
sb$q_right      dw      ?
sb$q_lstep      dw      ?
sb$q_rstep      dw      ?
sb$q_hstep      dw      ?
sb$q_light      dw      ?


;; Quake's vertical interpolation: arithmetic-shift the signed delta
;; first, then accumulate that integer step. Multiplying before shifting
;; differs for every negative delta not divisible by the block size.
SB_TLERP        macro   top:req, bot:req, dst:req
                mov     ax, ss:&bot
                sub     ax, ss:&top
                push    cx
                mov     cl, B ss:sb$shift
                sar     ax, cl
                imul    ax, ss:sb$yin
                pop     cx
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

;; One Quake pixel. Horizontal blocks are written right to left: the
;; rightmost pixel sees the right-hand light exactly, then the light
;; walks toward the left corner. ebp is the mapped colormap offset.
SB_QPIX         macro   ofs:req
                mov     ax, ss:sb$q_light
                and     ax, 0FF00h
                or      al, ds:[si+ofs]
                movzx   eax, ax
                mov     al, gs:[eax+ebp]
                mov     es:[di+ofs], al
                mov     ax, ss:sb$q_hstep
                add     ss:sb$q_light, ax
endm

;; Quake's four R_DrawSurfaceBlock8_mipN routines in the 16-bit memory
;; model. Only the block width differs; assembly-time expansion keeps
;; every texel free of a coordinate calculation or loop branch.
SB_QDRAW        macro   name:req, block:req, divsh:req
                local   hloop, vloop, rowloop, rowdone, nowrap, out
name:
                mov     es, ss:sb$dstseg
                movzx   ebp, W ss:sb$cmofs
                mov     ax, ss:sb$lmw
                dec     ax
                mov     ss:sb$q_cols, ax
                mov     ax, O sb$lgrid
                mov     ss:sb$q_lcol, ax
                mov     ax, ss:sb$dstbase
                mov     ss:sb$q_destcol, ax
                mov     ax, ss:sb$u0int
                and     ax, ss:sb$msk
                mov     ss:sb$q_sx, ax

                mov     eax, ss:sb$v
                shr     eax, 16
                and     ax, ss:sb$vmsk
                mov     ss:sb$q_sy, ax

                mov     ax, ss:sb$vmsk
                inc     ax
                mul     W ss:sb$texbps
                mov     ss:sb$q_texsize, ax
                add     ax, ss:sb$texbase
                mov     ss:sb$q_srcmax, ax

                mov     ax, ss:sb$lmw
                shl     ax, 1
                mov     ss:sb$q_lrow, ax

hloop:          mov     ax, ss:sb$q_lcol
                mov     ss:sb$q_lptr, ax
                mov     ax, ss:sb$lmh
                dec     ax
                mov     ss:sb$q_vblocks, ax

                mov     ax, ss:sb$q_sy
                mul     W ss:sb$texbps
                add     ax, ss:sb$texbase
                add     ax, ss:sb$q_sx
                mov     si, ax
                mov     di, ss:sb$q_destcol

vloop:          mov     bx, ss:sb$q_lptr
                mov     ax, ss:[bx]
                mov     ss:sb$q_left, ax
                mov     dx, ss:[bx+2]
                mov     ss:sb$q_right, dx
                add     bx, ss:sb$q_lrow
                mov     ss:sb$q_lptr, bx

                mov     ax, ss:[bx]
                sub     ax, ss:sb$q_left
                sar     ax, divsh
                mov     ss:sb$q_lstep, ax
                mov     ax, ss:[bx+2]
                sub     ax, ss:sb$q_right
                sar     ax, divsh
                mov     ss:sb$q_rstep, ax

                mov     cx, block
rowloop:        mov     ax, ss:sb$q_left
                sub     ax, ss:sb$q_right
                sar     ax, divsh
                mov     ss:sb$q_hstep, ax
                mov     ax, ss:sb$q_right
                mov     ss:sb$q_light, ax

IF block EQ 16
                SB_QPIX 15
                SB_QPIX 14
                SB_QPIX 13
                SB_QPIX 12
                SB_QPIX 11
                SB_QPIX 10
                SB_QPIX 9
                SB_QPIX 8
                SB_QPIX 7
                SB_QPIX 6
                SB_QPIX 5
                SB_QPIX 4
                SB_QPIX 3
                SB_QPIX 2
                SB_QPIX 1
                SB_QPIX 0
ELSEIF block EQ 8
                SB_QPIX 7
                SB_QPIX 6
                SB_QPIX 5
                SB_QPIX 4
                SB_QPIX 3
                SB_QPIX 2
                SB_QPIX 1
                SB_QPIX 0
ELSEIF block EQ 4
                SB_QPIX 3
                SB_QPIX 2
                SB_QPIX 1
                SB_QPIX 0
ELSE
                SB_QPIX 1
                SB_QPIX 0
ENDIF

                mov     ax, ss:sb$q_lstep
                add     ss:sb$q_left, ax
                mov     ax, ss:sb$q_rstep
                add     ss:sb$q_right, ax

                add     si, ss:sb$texbps
                cmp     si, ss:sb$q_srcmax
                jb      nowrap
                sub     si, ss:sb$q_texsize
nowrap:         add     di, ss:sb$dstbps
                dec     cx
                jz      rowdone
                jmp     rowloop
rowdone:

                dec     ss:sb$q_vblocks
                jnz     vloop

                add     ss:sb$q_lcol, 2
                add     ss:sb$q_destcol, block
                mov     ax, ss:sb$q_sx
                add     ax, block
                and     ax, ss:sb$msk
                mov     ss:sb$q_sx, ax
                dec     ss:sb$q_cols
                jnz     hloop
out:            ret
endm

QGL_CODE

                SB_QDRAW sb$qdraw16, 16, 4
                SB_QDRAW sb$qdraw8,   8, 3
                SB_QDRAW sb$qdraw4,   4, 2
                SB_QDRAW sb$qdraw2,   2, 1

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

                cmp     ss:sb$sw, 1
                jl      @@error
                cmp     ss:sb$sh, 1
                jl      @@error

                mov     ss:sb$savebp, ebp

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
                mov     ax, es:[bx].Surface.xRes
                mov     ss:sb$dstw, ax
                cmp     ss:sb$sw, ax
                ja      @@error
                mov     ax, es:[bx].Surface.yRes
                mov     ss:sb$dsth, ax
                cmp     ss:sb$sh, ax
                ja      @@error

                ;; Prove the WHOLE cache class, including the possible
                ;; guard row, is flat in one EMS window.
                mov     ax, ss:sb$dsth
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
                mov     ax, ss:sb$dsth
                dec     ax
                mul     W ss:sb$dstbps
                jc      @@error
                add     ax, ss:sb$dstbase
                jc      @@error
                cmp     ax, ss:sb$dstlast
                jne     @@error
                add     ax, ss:sb$dstw
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

                ;;
                ;; ---- Quake's native-cell path ------------------------
                ;;
                ;; Shared tiny mip cells are resampled (du/dv != 1.0),
                ;; and arbitrary callers may ask for partial blocks. Both
                ;; stay on the generic builder below.
                cmp     ss:sb$dufrc, 0
                jne     @@generic
                cmp     ss:sb$duint, 1
                jne     @@generic
                cmp     D ss:sb$dv, 10000h
                jne     @@generic
                cmp     ss:sb$u0frc, 0
                jne     @@generic
                cmp     W ss:sb$v, 0
                jne     @@generic
                cmp     ss:sb$lmw, 2
                jb      @@generic
                cmp     ss:sb$lmh, 2
                jb      @@generic
                cmp     ss:sb$shift, 1
                jb      @@generic
                cmp     ss:sb$shift, 4
                ja      @@generic

                mov     cx, ss:sb$shift
                mov     ax, ss:sb$lmw
                dec     ax
                shl     ax, cl
                cmp     ax, ss:sb$sw
                jne     @@generic
                mov     ax, ss:sb$lmh
                dec     ax
                shl     ax, cl
                cmp     ax, ss:sb$sh
                jne     @@generic

                mov     dx, ss:sb$stp
                dec     dx
                test    ss:sb$u0int, dx
                jnz     @@generic
                mov     eax, ss:sb$v
                shr     eax, 16
                test    ax, dx
                jnz     @@generic
                mov     ax, ss:sb$msk
                inc     ax
                cmp     ax, ss:sb$stp
                jb      @@generic
                mov     ax, ss:sb$vmsk
                inc     ax
                cmp     ax, ss:sb$stp
                jb      @@generic

                cmp     ss:sb$shift, 4
                jne     @F
                call    sb$qdraw16
                jmp     @@guard
@@:             cmp     ss:sb$shift, 3
                jne     @F
                call    sb$qdraw8
                jmp     @@guard
@@:             cmp     ss:sb$shift, 2
                jne     @F
                call    sb$qdraw4
                jmp     @@guard
 @@:            call    sb$qdraw2
                jmp     @@guard

@@generic:

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
                cmp     dx, ss:sb$stp
                jbe     @F
                mov     dx, ss:sb$stp
@@:             mov     ss:sb$yin, dx

                mov     ax, ss:sb$yy
                mul     W ss:sb$dstbps
                add     ax, ss:sb$dstbase
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
                push    bx
                mov     cl, B ss:sb$shift
                mov     ax, ss:sb$tleft
                sub     ax, ss:sb$tright
                sar     ax, cl                    ;; Quake's integer step
                mov     ss:sb$q_hstep, ax
                movsx   eax, ax
                neg     eax                       ;; this loop walks left->right
                shl     eax, 16
                mov     ss:sb$tstep, eax

                mov     ax, ss:sb$q_hstep
                mov     cx, ss:sb$stp
                dec     cx
                imul    ax, cx
                add     ax, ss:sb$tright           ;; left pixel, one step short
                mov     dx, ax
                pop     bx
                pop     cx
                movzx   eax, dx
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

                ;; a flat span is a run with no step
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
                and     ax, 0FF00h
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
                ;; ---- padded cache guard -------------------------------
                ;;
                ;; Quake clamps every perspective span endpoint to
                ;; extents-1. qgl's masked sampler has no per-polygon
                ;; clamp and can overshoot by several texels at a shallow
                ;; angle, so extend the far edge through the whole unused
                ;; part of the power-of-two cache class.
@@done:
@@guard:        mov     es, ss:sb$dstseg
                cld
                mov     ax, ss:sb$sw
                cmp     ax, ss:sb$dstw
                jae     @@guardrow
                mov     cx, ss:sb$dstw
                sub     cx, ax
                mov     ss:sb$cnt, cx
                mov     di, ss:sb$dstbase
                add     di, ax
                dec     di
                mov     si, di
                mov     dx, ss:sb$sh
@@guardcol:     mov     al, es:[di]
                inc     di
                mov     cx, ss:sb$cnt
                rep     stosb
                add     si, ss:sb$dstbps
                mov     di, si
                dec     dx
                jnz     @@guardcol

@@guardrow:     mov     ax, ss:sb$sh
                cmp     ax, ss:sb$dsth
                jae     @@success
                dec     ax
                mul     W ss:sb$dstbps
                add     ax, ss:sb$dstbase
                mov     si, ax
                mov     ss:sb$rowofs, ax
                mov     di, ax
                add     di, ss:sb$dstbps
                mov     dx, ss:sb$dsth
                sub     dx, ss:sb$sh
                push    ds
                mov     ds, ss:sb$dstseg
@@guardrows:    mov     si, ss:sb$rowofs
                mov     cx, ss:sb$dstw
                rep     movsb
                add     di, ss:sb$dstbps
                sub     di, ss:sb$dstw
                dec     dx
                jnz     @@guardrows
                pop     ds

                ;; bp is the fast drawer's cmap base or the generic
                ;; loop's counter; the generated epilogue needs its frame.
@@success:      mov     ebp, ss:sb$savebp
                mov     ax, 1
                ret

@@error:        xor     ax, ax
                ret
qglSbBuild      endp

QGL_ENDS
                end
