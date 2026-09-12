;;
;; dctMem.asm -- MEM surfaces initilization/allocation/read & write access/...
;;
;; Transcribed from mgl's dct/dctmem.asm. The renames are qgl's standing
;; ones -- DC -> Surface, DC_addrTB -> SF_addrTB, ul$ -> qgl$, UGL_CODE ->
;; QGL_CODE -- plus two forced by this tree:
;;
;;   mem_* -> qgl_mem_*   qrender links UGLV.LIB, whose own dctmem.asm
;;                        already defines mem_Init, mem_New, mem_RdAccess
;;                        and the rest. SET_DCT's externdef makes even the
;;                        `private` ones public, and LINK folds case.
;;
;;   memCalloc -> qglMemAlloc
;;                        qgl's allocator is DOS's, it does not zero, and
;;                        it reports failure as a null far pointer rather
;;                        than CF. A fresh MEM surface therefore holds
;;                        whatever DOS last left there, which is what
;;                        qglSfNewEx already did before this.
;;

                .model  medium, pascal
                .386
                option  proc:private

                include qgl.inc

qglMemAlloc     proto   far pascal :dword
qglMemFree      proto   far pascal :dword

MEMCTX          struc
                rdCurrent       dw      0
                wrCurrent       dw      0
MEMCTX          ends

.data
mm$memCtx       MEMCTX  <>


QGL_CODE
initialized     dw      FALSE

;;::::::::::::::
;; out: CF clean if OK
qgl_mem_Init    proc    near public uses bx

                LOGBEGIN qgl_mem_Init

                cmp     cs:initialized, TRUE
                je      @@done
                mov     cs:initialized, TRUE

@@done:         ;; setup qgl$dctTB[SF_MEM]
                mov     bx, O qgl$dctTB + SF_MEM

                mov     [bx].SurfaceOps.state, TRUE
                mov     [bx].SurfaceOps.winSize, 65536

                SET_DCT new, qgl_mem_New
                SET_DCT newMult, qgl_mem_NewMult
                SET_DCT del, qgl_mem_Del

                SET_DCT save, qgl_mem_Save
                SET_DCT restore, qgl_mem_Restore

                SET_DCT rdBegin, qgl_mem_RdBegin, TRUE
                SET_DCT wrBegin, qgl_mem_WrBegin, TRUE
                SET_DCT rdwrBegin, qgl_mem_RdWrBegin, TRUE

                SET_DCT rdSwitch, qgl_mem_RdSwitch, TRUE
                SET_DCT wrSwitch, qgl_mem_WrSwitch, TRUE
                SET_DCT rdwrSwitch, qgl_mem_RdWrSwitch, TRUE

                SET_DCT rdAccess, qgl_mem_RdAccess, TRUE
                SET_DCT wrAccess, qgl_mem_WrAccess, TRUE

                SET_DCT rdwrAccess, qgl_mem_RdWrAccess, TRUE
                SET_DCT fullAccess, qgl_mem_FullAccess, TRUE

                SET_DCT rdAccessEx, qgl_mem_RdAccessEx, TRUE
                SET_DCT wrAccessEx, qgl_mem_WrAccessEx, TRUE
                SET_DCT rdwrAccessEx, qgl_mem_WrAccessEx, TRUE
                mov     [bx].SurfaceOps.windows, 4      ;; slot is ignored, see below

                LOGEND
                clc                             ;; returns OK always
                ret
qgl_mem_Init    endp
QGL_ENDS

.code
;;::::::::::::::
;; out: CF clean if OK
qgl_mem_End     proc    far public
                LOGBEGIN qgl_mem_End
                LOGEND
                clc
                ret
qgl_mem_End     endp

;;::::::::::::::
;;  in: fs->sf
;;      bx= bps
;;      si= yRes
;;
;; out: CF clean if OK
qgl_mem_New     proc    far public uses di

                LOGBEGIN qgl_mem_New

                test    bx, bx
                jz      @@error                 ;; bps >= 64K?

                mov     cx, bx                  ;; save

                LOGMSG  alloc
                mov     eax, fs:[Surface._size]
                add     eax, 16                 ;; + 1 para (for alignment)
                invoke  qglMemAlloc, eax
                mov     di, ax
                or      di, dx
                jz      @@error
                mov     W fs:[Surface.fptr+0], ax       ;; save pointer
                mov     W fs:[Surface.fptr+2], dx       ;; /

                ;; make a zero based offset (i'm not assuming that the
                ;; offset returned by memAlloc will be always 0 (as it is
                ;; now) as a better allocator could be used later and...)
                add     ax, 15                  ;; seg+= (ofs+15) \ 16
                shr     ax, 4                   ;; /
                add     dx, ax                  ;; /
                xor     bx, bx                  ;; ofs= 0

                ;; fill addrTB
                xor     di, di                  ;; di= addrTB idx

@@loop:         mov     W fs:[SF_addrTB+di+0], dx
                mov     W fs:[SF_addrTB+di+2], bx

                add     bx, cx                  ;; bx+= bps
                sbb     ax, ax
                and     ax, 1000000000000b
                add     dx, ax                  ;; bx>=64k? seg+=4096
                add     ax, -1
                sbb     ax, ax
                not     ax
                and     bx, ax                  ;; bx>=64k? bx= 0

                add     di, T dword             ;; next
                dec     si
                jnz     @@loop                  ;; not last scanline?

                clc
@@exit:         LOGEND
                ret

@@error:        LOGERROR
                stc
                jmp     short @@exit
qgl_mem_New     endp

;;::::::::::::::
;;  in: ds-> DGROUP
;;      es:di-> sf array
;;      eax= surface size (bps * yRes)
;;      bx= bps
;;      si= yRes
;;      ecx= number of surfaces
;;
;; out: CF clean if OK
qgl_mem_NewMult proc    far public uses es ds
                local   bps:word, fptr:dword

                LOGBEGIN qgl_mem_NewMult

                test    bx, bx
                jz      @@error                 ;; bps >= 64K?

                mov     bps, bx                 ;; save

                ;; alloc mem for surfaces' data
                LOGMSG  alloc
                imul    eax, ecx
                add     eax, 16                 ;; + 1 para (for alignment)
                invoke  qglMemAlloc, eax
                mov     bx, ax
                or      bx, dx
                jz      @@error
                mov     W fptr, ax              ;; save pointer
                mov     W fptr, dx              ;; /
                                                ;; ^ mgl's own line, copied.
                                                ;; It writes the low word
                                                ;; twice; fptr+2 stays 0 and
                                                ;; every surface in the batch
                                                ;; gets a segment of 0. See
                                                ;; the report -- nothing here
                                                ;; calls qglNewMult.

                ;; fill addrTB
                LOGMSG  fill
                add     ax, 15                  ;; seg+= (ofs+15) \ 16
                shr     ax, 4                   ;; /
                add     dx, ax                  ;; /
                xor     bx, bx                  ;; ofs= 0

@@oloop:        mov     ds, es:[di+2]           ;; ds-> sf

                mov     eax, fptr
                mov     ds:[Surface.fptr], eax

                PS      di, si
                xor     di, di                  ;; di= addrTB idx

@@loop:         mov     W ds:[SF_addrTB+di+0], dx
                mov     W ds:[SF_addrTB+di+2], bx

                add     bx, bps                 ;; bx+= bps
                sbb     ax, ax
                and     ax, 1000000000000b
                add     dx, ax                  ;; bx>=64k? seg+=4096
                add     ax, -1
                sbb     ax, ax
                not     ax
                and     bx, ax                  ;; bx>=64k? bx= 0

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
qgl_mem_NewMult endp

;;::::::::::::::
;;  in: fs->sf
;;
;; out: CF clean if OK
qgl_mem_Del     proc    far public

                LOGBEGIN qgl_mem_Del

                mov     eax, fs:[Surface.fptr]
                test    eax, eax
                jz      @@error
                invoke  qglMemFree, eax
        ;;;;;;;;jc      @@error

@@exit:         LOGEND
                ret

@@error:        LOGERROR
                stc
                jmp     short @@exit
qgl_mem_Del     endp

;;::::::::::::::
qgl_mem_Save    proc    far public
                pop     ebx

                push    mm$memCtx.rdCurrent
                push    mm$memCtx.wrCurrent

                push    ebx
                ret
qgl_mem_Save    endp
;;::::::::::::::
qgl_mem_Restore proc    far public
                pop     ebx

                pop     mm$memCtx.wrCurrent
                pop     mm$memCtx.rdCurrent

                push    ebx
                ret
qgl_mem_Restore endp


QGL_CODE
;;:::
;; The Begin/Switch family is mgl's, verbatim -- INCLUDING the bare
;; gs:[SF_addrTB][si], which reads the header at offset 0 of its segment.
;; Every other addrTB read in this file carries the header's offset in bx
;; (see the note in qgldc.asm); these do not, because bx is an OUTPUT of
;; WrBegin and adding an input would change mgl's contract. Nothing in qgl
;; reaches them -- qgl's fillers take a row pointer, not a gfxCtx -- so
;; they stay as copied. Wiring one up means giving it a base register first.
;;
;;  in: gs-> source sf
;;      si= y * T dword
;;
;; out: bp-> gfxCtx[src.type]
;;      ds-> source sf's framebuffer
qgl_mem_RdBegin proc    near private uses ax
                mov     ax, W gs:[SF_addrTB][si]
                mov     bp, O mm$memCtx.rdCurrent
                mov     ss:mm$memCtx.rdCurrent, ax
                mov     ds, ax
                ret
qgl_mem_RdBegin endp

;;:::
;;  in: fs-> destine sf
;;      di= y * T dword
;;
;; out: bx-> gfxCtx[dst.type]
;;      es-> destine sf's framebuffer
qgl_mem_WrBegin proc    near private uses ax
                mov     ax, W fs:[SF_addrTB][di]
                mov     bx, O mm$memCtx.wrCurrent
                mov     ss:mm$memCtx.wrCurrent, ax
                mov     es, ax
                ret
qgl_mem_WrBegin endp

;;:::
;;  in: fs-> destine sf
;;      di= y * T dword
;;
;; out: bx-> gfxCtx[dst.type]
;;      es= destine sf's framebuffer (write access)
;;      ax= /        /    /          (read  /     )
qgl_mem_RdWrBegin proc  near private
                mov     ax, W fs:[SF_addrTB][di]
                mov     bx, O mm$memCtx.wrCurrent
                mov     ss:mm$memCtx.wrCurrent, ax
                mov     es, ax
                ret
qgl_mem_RdWrBegin endp

;;:::
;;  in: bp-> gfxCtx[src.type]
;;      esi= src.addrTb[y]
qgl_mem_RdSwitch proc   near private
                mov     ss:mm$memCtx.rdCurrent, si
                mov     ds, si
                ret
qgl_mem_RdSwitch endp

;;:::
;;  in: bx-> gfxCtx[dst.type]
;;      edi= dst.addrTb[y].segm
qgl_mem_WrSwitch proc   near private
                mov     ss:mm$memCtx.wrCurrent, di
                mov     es, di
                ret
qgl_mem_WrSwitch endp

;;:::
;;  in: bx-> gfxCtx[dst.type]
;;      edi= dst.addrTb[y].segm
qgl_mem_RdWrSwitch proc near private
                mov     ss:mm$memCtx.wrCurrent, di
                mov     es, di
                mov     ax, di
                ret
qgl_mem_RdWrSwitch endp

;;:::
;;  in: gs-> source sf
;;      si= y * T dword
;;
;; out: ds:si-> src framebuffer
qgl_mem_RdAccess proc   near private
                mov     esi, gs:[SF_addrTB][si]
                mov     ds, si
                shr     esi, 16
                ret
qgl_mem_RdAccess endp

;;:::
;;  in: fs-> destine sf
;;      di= y * T dword
;;
;; out: es:di-> dst framebuffer
qgl_mem_WrAccess proc   near private
                mov     edi, fs:[SF_addrTB][di]
                mov     es, di
                shr     edi, 16
                ret
qgl_mem_WrAccess endp

;;:::
;;  in: fs-> destine sf
;;      di= y * T dword
;;
;; out: di= dst fbuffer offset
;;      es= dst fbuffer seg (write access)
;;      ax= /   /       seg (read  /     )
qgl_mem_RdWrAccess proc near private
                mov     edi, fs:[SF_addrTB][di]
                mov     es, di
                mov     ax, di
                shr     edi, 16
                ret
qgl_mem_RdWrAccess endp

;;:::
;;  in: gs-> source sf
;;
;; out: ds:si-> src framebuffer
qgl_mem_FullAccess proc near private
                mov     esi, gs:[SF_addrTB][0]
                mov     ds, si
                shr     esi, 16
                ret
qgl_mem_FullAccess endp

;;:::
;; The Ex accessors. Conventional memory has no window to map through --
;; every surface is addressable all the time -- so the slot argument is
;; simply ignored and these cost the same as the plain accessors, minus the
;; segment register load. windows is reported as 4 only to match the
;; slot space; the real answer is "as many as you like".
;;
;;  in: gs-> source sf
;;      si= y * T dword
;;      cl= window slot (ignored)
;;
;; out: dx:ax-> src framebuffer
;;      si unchanged, CF clean
qgl_mem_RdAccessEx proc near private uses si
                mov     esi, gs:[SF_addrTB][si]
                mov     dx, si                  ;; dx= segment
                mov     eax, esi
                shr     eax, 16                 ;; ax= offset
                clc
                ret
qgl_mem_RdAccessEx endp

;;:::
;;  in: fs-> destine sf
;;      di= y * T dword
;;      cl= window slot (ignored)
;;
;; out: dx:ax-> dst framebuffer
;;      di unchanged, CF clean
qgl_mem_WrAccessEx proc near private uses di
                mov     edi, fs:[SF_addrTB][di]
                mov     dx, di                  ;; dx= segment
                mov     eax, edi
                shr     eax, 16                 ;; ax= offset
                clc
                ret
qgl_mem_WrAccessEx endp
QGL_ENDS
                end
