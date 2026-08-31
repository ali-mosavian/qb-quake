;; name: uglSpanBegin / uglSpanTP
;; desc: the perspective texture filler, driven one SPAN at a time
;;       instead of one polygon at a time.
;;
;;       drawPoly_tp2d walks a polygon's two edges and calls the scanline
;;       filler once per row. These two split that in half. Everything
;;       the filler needs that is per-polygon -- the texture read window,
;;       the destination write window, and the gradients and texture
;;       masks the selector patches into the filler's own inner loop --
;;       is established once by uglSpanBegin. uglSpanTP then draws any
;;       span of that polygon, taking the span's extent and its u/z, v/z
;;       and 1/z outright rather than stepping them down an edge.
;;
;;       For a caller that has already resolved its own spans (an edge
;;       list swept into a non-overlapping span list) that is the whole
;;       of the polygon driver it still needs: the edge walk moves to the
;;       caller, which was doing it anyway to resolve visibility.
;;
;;       Spans MUST be grouped by polygon.
;;
;;       u and v are TEXELS over z. uglPolyTP takes them normalised and
;;       scales by the texture's own size where it builds its gradients,
;;       which is above the level these two work at -- so a caller here
;;       scales for itself, and uglDcSize below is where it gets the same
;;       number uglPolyTP would have used. The gradients live patched
;;       inside the filler, so a span drawn after another polygon's
;;       uglSpanBegin is drawn with that polygon's gradients.
;;
;; obs.: - UGL.Z.OFF only, deliberately. The depth window wants a fourth
;;         EMS slot, and a caller that resolved its own spans has nothing
;;         left to depth-test against.
;;       - single-bank destinations only, for the same reason this is a
;;         measurement and not yet a driver: no wrSwitch on a scanline
;;         that crosses a bank. A conventional-memory backbuffer never
;;         does, which is what qrender uses.

                include common.inc
                include polyx.inc

                externdef ul$zmode:word
                externdef ul$zdc:dword
                externdef ul$zline:word
                externdef ul$zacc:dword
                externdef ul$zmul:dword

Z_SLOT          equ     3

.data
;; What uglSpanBegin leaves for uglSpanTP. Read through ss: throughout --
;; rdAccess re-points ds at the texture and it stays there, exactly as in
;; drawPoly_tp2d, so DGROUP is not addressable through ds after it.
                public  ul$spfiller
ul$spfiller     dw      0                       ;; patched filler address
sp_dcseg        dw      0                       ;; destination dc segment
sp_dstseg       dw      0                       ;; es -> framebuffer
sp_texseg       dw      0                       ;; ds -> texture
sp_dstctx       dw      0                       ;; wrBegin's context
sp_wrsw         dw      0                       ;; the dc's wrSwitch
sp_tw           real4   1.0                     ;; texture xRes, yRes, as
sp_th           real4   1.0                     ;; the u/v scale
sp_itmp         dw      0                       ;; fild landing pad
sp_i32          dd      0                       ;; fistp landing pad
;; Depth runs to 65535 against a 16.16 accumulator, so the product
;; reaches 4.29e9 -- past what a dword fistp can store, which is signed.
sp_ztmp         dq      0
sp_zsave        dw      0                       ;; caller's depth mode

UGL_CODE
;;::::::::::::::
;; uglSpanBegin (texdc:dword, dstdc:dword, masked:word,
;;               dudx:real4, dvdx:real4, dzdx:real4)
;;
;; retn: the filler's address; 0 means the destination's colour format
;;       has no perspective scanline filler and no span may be drawn.
uglSpanBegin    proc    public uses bx cx si di ds es fs gs,\
                        texdc:dword, dstdc:dword, masked:word,\
                        dudx:real4, dvdx:real4, dzdx:real4

                ;; destination: open the write window, keep the segment.
                mov     ax, W dstdc+2
                mov     ss:sp_dcseg, ax
                mov     fs, ax
                mov     bx, fs:[DC.typ]
                mov     ax, ss:ul$dctTB[bx].wrSwitch
                mov     ss:sp_wrsw, ax

                ;; di, not junk: wrBegin READS the scanline table at di to
                ;; pick the segment it hands back. Row 0 is as good as any
                ;; -- uglSpanTP re-derives it per span below -- but it has
                ;; to be a row.
                xor     di, di
                call    ss:ul$dctTB[bx].wrBegin ;; es-> fbuff, bx-> context
                mov     ss:sp_dstctx, bx
                mov     ax, es
                mov     ss:sp_dstseg, ax

                ;; texture: gs must point at it across the selector call
                ;; below, which reads its dimensions to build the masks.
                mov     gs, W texdc+2

                ;; The u/v scale, from the texture itself -- and it has
                ;; to be the SAME expression uglPolyTP uses a few hundred
                ;; lines up, or the two paths map the same coordinates to
                ;; different texels. It is xRes-1 there; qb-qrender's
                ;; ugl-patch changes that site to xRes, and this one has
                ;; to move with it. A duplicated scale is exactly the bug
                ;; that patch exists to fix, so keep them together.
                mov     ax, gs:[DC.xRes]
                dec     ax
                mov     ss:sp_itmp, ax
                fild    W ss:sp_itmp
                fstp    ss:sp_tw
                mov     ax, gs:[DC.yRes]
                dec     ax
                mov     ss:sp_itmp, ax
                fild    W ss:sp_itmp
                fstp    ss:sp_th

                xor     si, si
                mov     bx, gs:[DC.typ]
                call    ss:ul$dctTB[bx].rdAccess ;; ds:si-> tex
                mov     ax, ds
                mov     ss:sp_texseg, ax

                ;; gradients and texture masks, patched into the filler.
                ;;
                ;; Left alone, so with a buffer installed the selector
                ;; hands back the depth-writing filler. A caller drawing
                ;; resolved spans has no depth to TEST, but it still has
                ;; depth to WRITE: alias models are not in the edge list
                ;; and depth-test against what the world pass leaves.
                ;; uglSpanTP sets the scanline pointer that filler needs.
                mov     fs, ss:sp_dcseg
                mov     bx, fs:[DC.fmt]
                mov     ax, masked
                fld     dzdx
                fld     dvdx
                fld     dudx
                call    ss:ul$cfmtTB[bx].opt_hLineTP
                mov     ss:ul$spfiller, ax

                mov     ax, ss:ul$spfiller
                xor     dx, dx
                ret
uglSpanBegin    endp

;;::::::::::::::
;; uglSpanTP (x:word, wid:word, y:word,
;;            up:real4, vp:real4, zp:real4)
;;
;; One span of whichever polygon uglSpanBegin last opened. up/vp/zp are
;; u/z, v/z and 1/z AT x -- evaluated by the caller, not stepped, which
;; is the one cost a span-ordered caller pays that an edge walk does not.
uglSpanTP       proc    public uses bx cx dx si di ds es fs gs,\
                        x:word, wid:word, y:word,\
                        up:real4, vp:real4, zp:real4

                mov     si, wid
                cmp     si, 0
                jle     @@exit
                mov     ax, ss:ul$spfiller
                test    ax, ax
                jz      @@exit

                ;; this row's base address out of the dc's scanline table
                mov     fs, ss:sp_dcseg
                mov     di, y
                shl     di, 2                   ;; T dword
                mov     edi, D fs:[DC_addrTB][di]

                ;; Bank in the low half, offset in the high half. What
                ;; the bank MEANS is the dc type's business -- a segment
                ;; for a mem dc, a page to map for a banked one -- so es
                ;; only ever comes from wrBegin or wrSwitch, never from
                ;; loading the low word here. That shortcut is right on a
                ;; mem dc and silently draws nothing on a banked one.
                mov     es, ss:sp_dstseg        ;; whichever last set it
                mov     bx, ss:sp_dstctx
                cmp     di, ss:[bx].GFXCTX.current
                je      @@have_bank
                call    ss:sp_wrsw              ;; maps it, and sets es
                mov     ax, es
                mov     ss:sp_dstseg, ax        ;; carry to the next span
@@have_bank:    shr     edi, 16                 ;; offset within it

                ;; The depth scanline, for the filler the selector chose.
                ;; Per SPAN here where the polygon driver does it per
                ;; scanline -- there are fewer spans than scanlines, and
                ;; they are longer, so the window opens less often.
                cmp     ss:ul$zmode, UGL_Z_OFF
                je      @@nodepth

                PS      eax, ebx, ecx, edx, esi, edi, fs

                mov     fs, W ss:ul$zdc+2
                mov     bx, fs:[DC.typ]
                mov     si, ss:ul$dctTB[bx].wrAccessEx
                test    si, si
                jz      @@zdone                 ;; type has no Ex accessor
                mov     di, y
                shl     di, 2                   ;; T dword
                mov     cl, Z_SLOT
                call    si                      ;; -> dx:ax = seg:offs
                mov     gs, dx
                mov     ss:ul$zline, ax

                fld     zp
                fmul    ss:ul$zmul
                fistp   ss:sp_ztmp
                mov     eax, D ss:sp_ztmp
                mov     ss:ul$zacc, eax

@@zdone:        PP      fs, edi, esi, edx, ecx, ebx, eax

@@nodepth:      mov     ds, ss:sp_texseg

                fld     zp                      ;; z'
                fld     vp                      ;; v' z'
                fld     up                      ;; u' v' z'

                mov     ax, x
                call    ss:ul$spfiller          ;; empties the FPU stack

@@exit:         xor     ax, ax
                xor     dx, dx
                ret
uglSpanTP       endp

;;::::::::::::::
;; uglDcSize (dc:dword, sel:word) -- a dc's xRes (sel 0) or yRes (sel 1),
;; less one: the scale uglPolyTP applies to normalised u and v where it
;; builds its gradients. A caller driving the filler directly has to do
;; that scaling itself, and has to do it with THIS number -- if the site
;; in uglPolyTP changes, so does this one.
uglDcSize       proc    public uses fs,\
                        dc:dword, sel:word
                mov     fs, W dc+2
                mov     ax, sel
                cmp     ax, 1
                je      @@h
                mov     ax, fs:[DC.xRes]
                jmp     @@out
@@h:            mov     ax, fs:[DC.yRes]
@@out:          dec     ax
                xor     dx, dx
                ret
uglDcSize       endp

;;::::::::::::::
;; uglSpanScale (sel:word) -- what uglSpanBegin worked out for the u (0)
;; and v (1) scale. Diagnostic.
uglSpanScale    proc    public,\
                        sel:word
                mov     ax, sel
                cmp     ax, 1
                je      @@vv
                fld     ss:sp_tw
                jmp     @@out
@@vv:           fld     ss:sp_th
@@out:          fistp   D ss:sp_i32
                mov     ax, W ss:sp_i32+0
                mov     dx, W ss:sp_i32+2
                ret
uglSpanScale    endp

UGL_ENDS
                end
