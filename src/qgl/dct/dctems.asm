;;
;; dctEms.asm -- EMS surfaces initilization/allocation/read & write access/...
;;
;; Transcribed from mgl's dct/dctems.asm. Beyond qgl's standing renames
;; (DC -> Surface, DC_addrTB -> SF_addrTB, ul$ -> qgl$, em$ -> qgl$,
;; UGL_CODE -> QGL_CODE, ems_* -> qgl_ems_* because UGLV.LIB already
;; defines every one of those names and LINK folds case), three things
;; differ and each is forced:
;;
;;   * MAPPING GOES THROUGH gem.asm. qglGemMap replaces mgl's EMS_MAP /
;;     EMS_MAPEX macros, which issue INT 67h inline. The macros below keep
;;     the same shape so the call sites read as mgl's do -- and they also
;;     record the segment gem hands back, which is where mgl's frame+slot
;;     arithmetic went.
;;
;;   * qglGemMap KEEPS NO CACHE. mgl's emsMapEx records the mapped page in
;;     em$emsCtx.ppgTB[slot] and skips a redundant remap; gem does neither.
;;     The cache is therefore entirely qgl$emsCtx's here, kept by
;;     qgl$AccessEx and by the macros -- which is where mgl kept most of it
;;     anyway.
;;
;;   * emsCalloc -> qglGemAlloc, which does not zero and reports failure as
;;     handle 0 rather than CF.
;;

                .model  medium, pascal
                .386
                option  proc:private

                include qgl.inc

qglGemInit      proto   far pascal
qglGemAlloc     proto   far pascal :dword
qglGemFree      proto   far pascal :word
qglGemMap       proto   far pascal :word, :word, :word

;; mgl's EMSCTX (inc/ems.inc), minus the frame word: gem.asm owns the page
;; frame and hands back a segment per map, so segTB is filled as pages are
;; mapped rather than derived once. It lives HERE and not in qgl.inc
;; because `rdCurrent equ ppgTB[...]` is a global text substitution --
;; in a shared header it eats dctmem.asm's MEMCTX.rdCurrent field.
EMSCTX          struc
                ppgTB           dw      4 dup (EMS_INVALID)
                segTB           dw      4 dup (?)

                rdCurrent       equ     ppgTB[EMS_READPAGE * 2]
                wrCurrent       equ     ppgTB[EMS_WRITEPAGE * 2]
EMSCTX          ends

;;::::::::::::::
;; mgl's EMS_MAP, over gem. si (read) or di (write) holds an addrTB entry's
;; low word -- logical page in the high byte, handle in the low.
;;
;; destroys: ax
QGL_MAP         macro   ppage:req

        if      (ppage eq EMS_READPAGE)
                push    si
                mov     ax, si
        else
                push    di
                mov     ax, di
        endif
                push    ax
                shr     ax, 8                   ;; ax= 0:logical page
                pop     bx                      ;; bx= entry
                push    ax
                mov     ax, bx
                and     ax, 00FFh               ;; ax= 0:handle
                pop     bx                      ;; bx= logical page
                invoke  qglGemMap, ax, bx, ppage
                mov     ss:qgl$emsCtx.segTB[ppage * 2], ax
        if      (ppage eq EMS_READPAGE)
                pop     si
        else
                pop     di
        endif
endm

.data
qgl$emsCtx      EMSCTX  <>


QGL_CODE
initialized     dw      FALSE

;;::::::::::::::
;; out: CF clean if OK
qgl_ems_Init    proc    near public uses bx

                LOGBEGIN qgl_ems_Init

                cmp     cs:initialized, TRUE
                je      @@done

                ;; check if EMS driver present
                LOGMSG  check
                invoke  qglGemInit
                test    ax, ax
                jz      @@error

                mov     cs:initialized, TRUE

@@done:         ;; setup qgl$dctTB[SF_EMS]
                mov     bx, O qgl$dctTB + SF_EMS

                mov     [bx].SurfaceOps.state, TRUE
                mov     [bx].SurfaceOps.winSize, 16384

                SET_DCT new, qgl_ems_New
                SET_DCT newMult, qgl_ems_NewMult
                SET_DCT del, qgl_ems_Del

                SET_DCT save, qgl_ems_Save
                SET_DCT restore, qgl_ems_Restore

                SET_DCT rdBegin, qgl_ems_RdBegin, TRUE
                SET_DCT wrBegin, qgl_ems_WrBegin, TRUE
                SET_DCT rdwrBegin, qgl_ems_RdWrBegin, TRUE
                SET_DCT rdSwitch, qgl_ems_RdSwitch, TRUE
                SET_DCT wrSwitch, qgl_ems_WrSwitch, TRUE
                SET_DCT rdwrSwitch, qgl_ems_RdWrSwitch, TRUE
                SET_DCT rdAccess, qgl_ems_RdAccess, TRUE
                SET_DCT wrAccess, qgl_ems_WrAccess, TRUE
                SET_DCT rdwrAccess, qgl_ems_RdWrAccess, TRUE
                SET_DCT fullAccess, qgl_ems_FullAccess, TRUE

                SET_DCT rdAccessEx, qgl_ems_RdAccessEx, TRUE
                SET_DCT wrAccessEx, qgl_ems_WrAccessEx, TRUE
                SET_DCT rdwrAccessEx, qgl_ems_WrAccessEx, TRUE
                mov     [bx].SurfaceOps.windows, 4      ;; four physical pages

                clc

@@exit:         LOGEND
                ret

@@error:        LOGERROR
                stc
                jmp     short @@exit
qgl_ems_Init    endp
QGL_ENDS

.code
;;::::::::::::::
;; out: CF clean if OK
qgl_ems_End     proc    far public
                LOGBEGIN qgl_ems_End
                LOGEND
                clc
                ret
qgl_ems_End     endp

;;::::::::::::::
;;  in: ds-> DGROUP
;;      fs->sf
;;      bx= bps
;;      si= yRes
;;
;; out: CF clean if OK
qgl_ems_New     proc    far public uses di

                LOGBEGIN qgl_ems_New

                cmp     bx, EMS_PGSIZE
                ja      @@error                 ;; bps > 16K?

                mov     cx, bx                  ;; save

                LOGMSG  alloc
                invoke  qglGemAlloc, fs:[Surface._size]
                test    ax, ax
                jz      @@error
                mov     fs:[Surface.hnd], ax    ;; save handle

                ;; fill addrTB
                xor     di, di                  ;; di= addrTB idx
                mov     dx, ax                  ;; dx= log-page:handle
                xor     bx, bx                  ;; bx= offset (<16k)

@@loop:         mov     W fs:[SF_addrTB+di+0], dx
                mov     W fs:[SF_addrTB+di+2], bx

                add     bx, cx                  ;; bx+= bps
                mov     ax, bx
                add     ax, not (EMS_PGSIZE-1)
                adc     dh, 0                   ;; ax>=16k? ++lpage
                add     bx, not (EMS_PGSIZE-1)
                sbb     ax, ax
                not     ax
                and     ax, EMS_PGSIZE-1
                and     bx, ax                  ;; bx>=16k? bx= 0

                add     di, T dword             ;; next
                dec     si
                jnz     @@loop                  ;; not last scanline?

                clc
@@exit:         LOGEND
                ret

@@error:        LOGERROR
                stc
                jmp     short @@exit
qgl_ems_New     endp

;;::::::::::::::
;;  in: ds-> DGROUP
;;      es:di-> sf array
;;      eax= surface size (bps * yRes)
;;      bx= bps
;;      si= yRes
;;      ecx= number of surfaces
;;
;; out: CF clean if OK
qgl_ems_NewMult proc    far public uses es ds
                local   bps:word, hnd:word

                LOGBEGIN qgl_ems_NewMult

                cmp     bx, EMS_PGSIZE
                ja      @@error                 ;; bps > 16K?

                mov     bps, bx                 ;; save

                ;; alloc mem for sf's data
                LOGMSG  alloc
                imul    eax, ecx
                invoke  qglGemAlloc, eax
                test    ax, ax
                jz      @@error
                mov     hnd, ax

                ;; fill addrTB
                LOGMSG  fill
                mov     dx, ax                  ;; dx= log-page:handle
                xor     bx, bx                  ;; bx= offset (<16k)

@@oloop:        mov     ds, es:[di+2]           ;; ds-> sf

                mov     ax, hnd
                mov     ds:[Surface.hnd], ax

                PS      di, si
                xor     di, di                  ;; di= addrTB idx

@@loop:         mov     W ds:[SF_addrTB+di+0], dx
                mov     W ds:[SF_addrTB+di+2], bx

                add     bx, bps                 ;; bx+= bps
                mov     ax, bx
                add     ax, not (EMS_PGSIZE-1)
                adc     dh, 0                   ;; ax>=16k? ++lpage
                add     bx, not (EMS_PGSIZE-1)
                sbb     ax, ax
                not     ax
                and     ax, EMS_PGSIZE-1
                and     bx, ax                  ;; bx>=16k? bx= 0

                add     di, T dword             ;; next
                dec     si
                jnz     @@loop                  ;; not last scanline?

                PP      si, di
                add     di, T dword             ;; next sf
                dec     cx
                jnz     @@oloop

                clc
@@exit:         LOGEND
                ret

@@error:        LOGERROR
                stc
                jmp     short @@exit
qgl_ems_NewMult endp

;;::::::::::::::
;;  in: fs->sf
;;
;; out: CF clean if OK
qgl_ems_Del     proc    far public

                LOGBEGIN qgl_ems_Del

                mov     ax, fs:[Surface.hnd]
                test    ax, ax
                jz      @@error
                invoke  qglGemFree, ax
        ;;;;;;;;jc      @@error

@@exit:         LOGEND
                ret

@@error:        LOGERROR
                stc
                jmp     short @@exit
qgl_ems_Del     endp

;;::::::::::::::
qgl_ems_Save    proc    far public
                pop     ebx                     ;; caller

                push    qgl$emsCtx.rdCurrent
                push    qgl$emsCtx.wrCurrent

                push    ebx                     ;; caller
                ret
qgl_ems_Save    endp
;;::::::::::::::
qgl_ems_Restore proc    far public
                pop     eax                     ;; caller

                pop     di
                pop     si
                push    eax                     ;; caller

                cmp     di, qgl$emsCtx.wrCurrent
                je      @F
                mov     qgl$emsCtx.wrCurrent, di
                QGL_MAP EMS_WRITEPAGE

@@:             cmp     si, qgl$emsCtx.rdCurrent
                je      @F
                mov     qgl$emsCtx.rdCurrent, si
                QGL_MAP EMS_READPAGE

@@:             ret
qgl_ems_Restore endp


QGL_CODE
;;:::
;; The Begin/Switch family is mgl's, verbatim, and it answers on the fixed
;; read and write pages the way mgl's does. Nothing in qgl reaches it --
;; qgl's fillers take a row pointer, not a gfxCtx -- so the pair of
;; hardwired slots stays mgl's rather than becoming the Surface's.
;;
;;  in: gs-> source sf
;;      si= y * T dword
;;
;; out: bp-> gfxCtx[src.type]
;;      ds-> source sf's framebuffer
qgl_ems_RdBegin proc    near private
                mov     bp, O qgl$emsCtx.rdCurrent
                mov     ds, ss:qgl$emsCtx.segTB[EMS_READPAGE * 2]
                ret
qgl_ems_RdBegin endp

;;:::
;;  in: fs-> destine sf
;;      di= y * T dword
;;
;; out: bx-> gfxCtx[dst.type]
;;      es-> destine sf's framebuffer
qgl_ems_WrBegin proc    near private
                mov     bx, O qgl$emsCtx.wrCurrent
                mov     es, ss:qgl$emsCtx.segTB[EMS_WRITEPAGE * 2]
                ret
qgl_ems_WrBegin endp

;;:::
;;  in: fs-> destine sf
;;      di= y * T dword
;;
;; out: bx-> gfxCtx[dst.type]
;;      es-> destine sf's framebuffer (write access)
;;      ax-> /       /    /           (read  /     )
qgl_ems_RdWrBegin proc  near private
                mov     bx, O qgl$emsCtx.wrCurrent
                mov     ax, ss:qgl$emsCtx.segTB[EMS_WRITEPAGE * 2]
                mov     es, ax
                ret
qgl_ems_RdWrBegin endp

;;:::
;;  in: bp-> gfxCtx[src.type]
;;      esi= src.addrTb[y]
qgl_ems_RdSwitch proc   near private
                mov     ss:qgl$emsCtx.rdCurrent, si
                PS      ax, bx, cx, dx
                QGL_MAP EMS_READPAGE
                PP      dx, cx, bx, ax
                ret
qgl_ems_RdSwitch endp

;;:::
;;  in: bx-> gfxCtx[dst.type]
;;      edi= dst.addrTb[y]
qgl_ems_WrSwitch proc   near private
                mov     ss:qgl$emsCtx.wrCurrent, di
                PS      ax, bx, cx, dx
                QGL_MAP EMS_WRITEPAGE
                PP      dx, cx, bx, ax
                ret
qgl_ems_WrSwitch endp

;;:::
;;  in: bx-> gfxCtx[dst.type]
;;      edi= dst.addrTb[y]
qgl_ems_RdWrSwitch proc near private
                mov     ss:qgl$emsCtx.wrCurrent, di
                PS      ax, bx, cx, dx
                QGL_MAP EMS_WRITEPAGE
                PP      dx, cx, bx, ax
                ret
qgl_ems_RdWrSwitch endp

;;:::
;;  in: gs-> source sf
;;      si= y * T dword
;;
;; out: ds:si-> src framebuffer
qgl_ems_RdAccess proc   near private

                mov     esi, gs:[SF_addrTB][si]
                cmp     ss:qgl$emsCtx.rdCurrent, si
                jne     @@change

                mov     ds, ss:qgl$emsCtx.segTB[EMS_READPAGE * 2]
                shr     esi, 16
                ret

@@change:       mov     ss:qgl$emsCtx.rdCurrent, si
                PS      ax, bx, cx, dx
                QGL_MAP EMS_READPAGE
                PP      dx, cx, bx, ax

                mov     ds, ss:qgl$emsCtx.segTB[EMS_READPAGE * 2]
                shr     esi, 16
                ret
qgl_ems_RdAccess endp

;;:::
;;  in: fs-> destine sf
;;      di= y * T dword
;;
;; out: es:di-> dst framebuffer
qgl_ems_WrAccess proc   near private

                mov     edi, fs:[SF_addrTB][di]
                cmp     ss:qgl$emsCtx.wrCurrent, di
                jne     @@change

                mov     es, ss:qgl$emsCtx.segTB[EMS_WRITEPAGE * 2]
                shr     edi, 16
                ret

@@change:       mov     ss:qgl$emsCtx.wrCurrent, di
                PS      ax, bx, cx, dx
                QGL_MAP EMS_WRITEPAGE
                PP      dx, cx, bx, ax

                mov     es, ss:qgl$emsCtx.segTB[EMS_WRITEPAGE * 2]
                shr     edi, 16
                ret
qgl_ems_WrAccess endp

;;:::
;;  in: fs-> destine sf
;;      di= y * T dword
;;
;; out: di= dst fbuffer offset
;;      es= dst fbuffer seg (write access)
;;      ax= /   /       /   (read  /     )
qgl_ems_RdWrAccess proc near private

                mov     edi, fs:[SF_addrTB][di]
                cmp     ss:qgl$emsCtx.wrCurrent, di
                jne     @@change

                mov     ax, ss:qgl$emsCtx.segTB[EMS_WRITEPAGE * 2]
                mov     es, ax
                shr     edi, 16
                ret

@@change:       mov     ss:qgl$emsCtx.wrCurrent, di
                PS      bx, cx, dx
                QGL_MAP EMS_WRITEPAGE
                PP      dx, cx, bx

                mov     ax, ss:qgl$emsCtx.segTB[EMS_WRITEPAGE * 2]
                mov     es, ax
                shr     edi, 16
                ret
qgl_ems_RdWrAccess endp

;;:::
;; The Ex accessors. Where RdAccess/WrAccess each take the Surface's own
;; physical page, these take the slot as an argument, so several surfaces
;; can sit mapped at the same time -- a texture, a lightmap and a
;; destination, each in its own window, with no remapping between them.
;;
;; ppgTB is indexed by slot, and rdCurrent/wrCurrent ARE ppgTB[0]/ppgTB[1],
;; so the cache these consult is the very same one the Begin/Switch family
;; keeps. Mixing the two on slots 0 and 1 stays coherent for free.
;;
;;  in: esi= sf.addrTB[y]   (offset:logical page:handle)
;;      cl = window slot, 0..3
;;
;; out: dx:ax= seg:offs of the scanline
;;      esi unchanged, CF clean
qgl$AccessEx    proc    near private uses bx cx

                movzx   bx, cl
                shl     bx, 1                   ;; bx= slot * T word

                cmp     ss:qgl$emsCtx.ppgTB[bx], si
                je      @@mapped                ;; that page already there?

                mov     ss:qgl$emsCtx.ppgTB[bx], si
                push    bx
                push    si
                mov     ax, si
                shr     ax, 8                   ;; ax= 0:logical page
                mov     dx, si
                and     dx, 00FFh               ;; dx= 0:handle
                movzx   cx, cl
                invoke  qglGemMap, dx, ax, cx
                pop     si
                pop     bx
                mov     ss:qgl$emsCtx.segTB[bx], ax

@@mapped:       mov     dx, ss:qgl$emsCtx.segTB[bx]
                mov     eax, esi
                shr     eax, 16                 ;; ax= scanline offset
                clc
                ret
qgl$AccessEx    endp

;;:::
;;  in: gs-> source sf
;;      si= y * T dword
;;      cl= window slot, 0..3
;;
;; out: dx:ax-> src framebuffer
qgl_ems_RdAccessEx proc near private uses si
                mov     esi, gs:[SF_addrTB][si]
                call    qgl$AccessEx
                ret
qgl_ems_RdAccessEx endp

;;:::
;;  in: fs-> destine sf
;;      di= y * T dword
;;      cl= window slot, 0..3
;;
;; out: dx:ax-> dst framebuffer
;;
;; The mapping EMS hands back is readable and writable both, so the rdwr
;; entry is this same code -- there is nothing extra to do for it.
qgl_ems_WrAccessEx proc near private uses si
                mov     esi, fs:[SF_addrTB][di]
                call    qgl$AccessEx
                ret
qgl_ems_WrAccessEx endp
QGL_ENDS

QGL_CODE
;;:::
;; mgl maps every page of the surface at once with one INT 67h call
;; (EMS_MEM_MMAP over em$mmTb). gem.asm has no multi-map, so this issues
;; one qglGemMap per page instead -- same effect, four calls rather than
;; one, and it keeps ppgTB and segTB current exactly as mgl's does.
;;
;;  in: gs-> source sf
;;
;; out: ds:si-> src framebuffer
qgl_ems_FullAccess proc near private uses ax bx ecx dx di bp

                mov     ecx, gs:[Surface._size]
                mov     dx, cx
                shr     ecx, 14                 ;; / 16384
                and     dx, 16384-1             ;; % 16384
                add     dx, 65535               ;; CF set if != 0
                adc     cx, 0                   ;; + CF

                cmp     cx, 4
                jle     @F
                mov     cx, 4

@@:             mov     ax, gs:[SF_addrTB][0]   ;; ax= y[0] lpage:handle
                push    ax                      ;; (0)

                ;;
                ;; Already in place? Ask ppgTB, the per-slot record every
                ;; mapping path keeps current.
                ;;
                xor     di, di
                mov     si, cx                  ;; counter
                mov     bx, ax                  ;; bx= expected lpage:handle

@@same:         cmp     ss:qgl$emsCtx.ppgTB[di], bx
                jne     @@build                 ;; slot holds something else?
                add     bx, 100h                ;; ++logical page
                add     di, T word
                dec     si
                jnz     @@same
                jmp     short @@done            ;; every page already there

@@build:        xor     di, di
                mov     si, cx                  ;; counter
                mov     bx, ax                  ;; bx= lpage:handle

@@loop:         push    bx
                push    si
                push    di
                mov     ss:qgl$emsCtx.ppgTB[di], bx
                mov     ax, bx
                shr     ax, 8                   ;; ax= logical page
                mov     dx, bx
                and     dx, 00FFh               ;; dx= handle
                shr     di, 1                   ;; di= slot
                invoke  qglGemMap, dx, ax, di
                pop     di
                mov     ss:qgl$emsCtx.segTB[di], ax
                pop     si
                pop     bx

                add     bx, 100h                ;; ++logical page
                add     di, T word
                dec     si
                jnz     @@loop

@@done:         pop     ax                      ;; (0) 1st lpage:handle

                mov     ds, ss:qgl$emsCtx.segTB[EMS_READPAGE * 2]
                mov     si, gs:[SF_addrTB+2][0]

                ret
qgl_ems_FullAccess endp
QGL_ENDS
                end
