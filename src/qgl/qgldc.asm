;; name: qglSetClipRect
;; desc: sets a Surface's clipping rectangle
;;
;; args: [in] sf:long,          | Surface to set
;;            cr:far CLIPRECT   | clipping rectangle, where:
;;                              |  xMin (>= 0; <= xMax)
;;                              |  yMin (>= 0; <= yMax)
;;                              |  xMax (>= xMin; < sf.xRes)
;;                              |  yMax (>= yMin; < sf.yRes)
;; retn: none
;;
;; chng: aug/01 written [v1ctor]
;; obs.: NOTHING IN qgl READS THESE FIELDS YET. clip.asm keeps one
;;       module-global rect for the whole layer (qglClRect), which is a
;;       divergence from mgl in its own right; transcribing this file
;;       brings the per-surface rect back as storage without moving the
;;       clipper onto it. Wiring clip.asm to it is a behaviour change --
;;       d_faces.c sets the global rect once -- and is deliberately not
;;       part of this pass.

;; name: qglGetClipRect
;; desc: gets a Surface's clipping rectangle
;;
;; chng: aug/01 written [v1ctor]

;; name: qglGetSetClipRect
;; desc: gets and sets a Surface's clipping rectangle
;;
;; chng: aug/01 written [v1ctor]

;; name: qglSfGet
;; desc: gets info about a Surface
;;
;; chng: aug/01 [v1ctor]

;; name: qglSfAccessRd
;; desc: returns a pointer to a surface scanline (for read access)
;;
;; args: [in]  sf:long,         | Surface to access
;;             y:integer        | scanline
;; retn: far pointer to scanline
;;
;; chng: sep/02 [v1ctor]
;; obs.: no clipping is done

;; name: qglSfAccessWr
;; desc: returns a pointer to a surface scanline (for write access)
;;
;; chng: sep/02 [v1ctor]
;; obs.: no clipping is done

;; name: qglSfAccessRdWr
;; desc: returns pointers to a surface scanline (for read and write access)
;;
;; chng: sep/02 [v1ctor]
;; obs.: no clipping is done

;; Transcribed from mgl's ugl/ugldc.asm. The two Ex entries at the end are
;; qgl's own: mgl reaches rdAccessEx/wrAccessEx from uglMapEx rather than
;; from here, and qgl's boundary is qglSfRdRowEx/qglSfWrRowEx, so they get
;; the same shell as the plain pair with the slot in cl.

                .model  medium, pascal
                .386
                option  proc:private

                include qgl.inc

.code
;;::::::::::::::
;; qglSetClipRect (sf:dword, cr:far CLIPRECT)
qglSetClipRect  proc    public uses bx di si es,\
                        sf:dword,\
                        cr:far ptr CLIPRECT

                mov     fs, W sf+2
                CHECKSF fs, @@exit

                les     di, cr
                mov     ax, es:[di].CLIPRECT.xMin
                mov     bx, es:[di].CLIPRECT.yMin
                mov     cx, es:[di].CLIPRECT.xMax
                mov     dx, es:[di].CLIPRECT.yMax

                mov     si, fs:[Surface.xRes]
                mov     di, fs:[Surface.yRes]

                cmp     ax, cx
                jle     @F
                xchg    ax, cx
@@:             cmp     bx, dx
                jle     @F
                xchg    bx, dx

@@:             test    ax, ax
                jge     @F
                xor     ax, ax
@@:             test    bx, bx
                jge     @F
                xor     bx, bx
@@:             cmp     cx, si
                jl      @F
                lea     cx, [si-1]
@@:             cmp     dx, di
                jl      @F
                lea     dx, [di-1]

@@:             mov     fs:[Surface.xMin], ax
                mov     fs:[Surface.yMin], bx
                mov     fs:[Surface.xMax], cx
                mov     fs:[Surface.yMax], dx

@@exit:         ret
qglSetClipRect  endp

;;::::::::::::::
;; qglGetClipRect (sf:dword, cr:far CLIPRECT)
qglGetClipRect  proc    public uses si di es,\
                        sf:dword,\
                        cr:far ptr CLIPRECT

                mov     fs, W sf+2
                CHECKSF fs, @@exit

                les     di, cr
                mov     ax, fs:[Surface.xMin]
                mov     bx, fs:[Surface.yMin]
                mov     cx, fs:[Surface.xMax]
                mov     dx, fs:[Surface.yMax]

                mov     es:[di].CLIPRECT.xMin, ax
                mov     es:[di].CLIPRECT.yMin, bx
                mov     es:[di].CLIPRECT.xMax, cx
                mov     es:[di].CLIPRECT.yMax, dx

@@exit:         ret
qglGetClipRect  endp

;;::::::::::::::
;; qglGetSetClipRect (sf:dword, inCr:far CLIPRECT, outCr:far CLIPRECT)
qglGetSetClipRect proc  public uses si di es,\
                        sf:dword,\
                        inCr:far ptr CLIPRECT,\
                        outCr:far ptr CLIPRECT

                mov     fs, W sf+2
                CHECKSF fs, @@exit

                push    fs:[Surface.xMin]
                push    fs:[Surface.yMin]
                push    fs:[Surface.xMax]
                push    fs:[Surface.yMax]

                invoke  qglSetClipRect, sf, inCr

                les     di, outCr
                pop     es:[di].CLIPRECT.yMax
                pop     es:[di].CLIPRECT.xMax
                pop     es:[di].CLIPRECT.yMin
                pop     es:[di].CLIPRECT.xMin

@@exit:         ret
qglGetSetClipRect endp

;;::::::::::::::
;; qglSfGet (sf:dword, sfInfo:dword)
qglSfGet        proc    public uses di si es ds,\
                        sf:dword,\
                        sfInfo:dword

                lds     si, sf
                les     di, sfInfo

                mov     cx, (Surface.yMax - Surface.fmt + (T Surface.yMax)) / 2
                rep     movsw

                ret
qglSfGet        endp

QGL_CODE

;;::::::::::::::
;; A KIND THAT IS NOT THERE MUST NOT ANSWER WITH THE CALLER'S OWN es.
;;
;; The accessors below take their answer out of the segment register
;; the back-end wrote, so a back-end that never ran leaves the CALLER's
;; register standing in for a row pointer. Dispatch slot 1 is mgl's banked
;; back-end, which qgl has none of and qglSfInit marks dead -- and the
;; loading screen's DC is exactly that kind. qglTxtChar holds the FONT's
;; segment in es two instructions before it asks for a row, so every glyph
;; row of the loading screen was written into the font block at
;; scan*4 + x. The HUD then drew whatever the font had become: 'a', '8'
;; and 'F' came out as solid 0xFE cells.
;;
;; The dead entry's stub does report the failure, in ax/dx and CF, and all
;; three of those were then overwritten. CF cannot carry it back either --
;; qgl_mem_WrAccess ends in `shr edi,16`, which sets CF from bit 15 of the
;; segment. So the check happens BEFORE the call, on the table.
;;::::::::::::::

;;::::::::::::::
;; qglSfAccessRd (sf:dword, y:word) :dword
qglSfAccessRd   proc    public uses bx si gs ds,\
                        sf:dword,\
                        y:word

                mov     gs, W sf+2                      ;; gs-> sf
                mov     si, y

                mov     bx, gs:[Surface.typ]
                CHECKKIND bx, @@dead
                add     si, gs:[Surface.startSL]        ;; + page

                shl     si, 2                           ;; * sizeof( addrTB )
                call    qgl$dctTB[bx].rdAccess

                mov     dx, ds                          ;; return sf->addrTB[y]
                mov     ax, si                          ;; /

                ret
@@dead:         xor     ax, ax
                xor     dx, dx
                ret
qglSfAccessRd   endp

;;::::::::::::::
;; qglSfAccessWr (sf:dword, y:word) :dword
qglSfAccessWr   proc    public uses bx di fs es,\
                        sf:dword,\
                        y:word

                mov     fs, W sf+2                      ;; fs-> sf
                mov     di, y

                mov     bx, fs:[Surface.typ]
                CHECKKIND bx, @@dead
                add     di, fs:[Surface.startSL]        ;; + page

                shl     di, 2                           ;; * sizeof( addrTB )
                call    qgl$dctTB[bx].wrAccess

                mov     dx, es                          ;; return sf->addrTB[y]
                mov     ax, di                          ;; /

                ret
@@dead:         xor     ax, ax
                xor     dx, dx
                ret
qglSfAccessWr   endp

;;::::::::::::::
;; qglSfAccessRdWr (sf:dword, y:word, rdPtr:near ptr dword) :dword
qglSfAccessRdWr proc    public uses bx di fs es,\
                        sf:dword,\
                        y:word,\
                        rdPtr:near ptr dword

                mov     fs, W sf+2                      ;; fs-> sf
                mov     di, y

                mov     bx, fs:[Surface.typ]
                CHECKKIND bx, @@dead
                add     di, fs:[Surface.startSL]        ;; + page

                shl     di, 2                           ;; * sizeof( addrTB )
                call    qgl$dctTB[bx].rdwrAccess

                ;; save read access ptr
                mov     bx, rdPtr
                mov     [bx+0], di
                mov     [bx+2], ax

                mov     dx, es                          ;; return sf->addrTB[y]
                mov     ax, di                          ;; /

                ret
@@dead:         xor     ax, ax
                xor     dx, dx
                mov     bx, rdPtr
                mov     [bx+0], ax
                mov     [bx+2], ax
                ret
qglSfAccessRdWr endp

;;::::::::::::::
;; qglSfAccessRdEx (sf:dword, y:word, slot:word) :dword
;;
;; qgl's own, shaped on the pair above: the accessor hands the pointer back
;; in dx:ax rather than through a segment register, so several surfaces can
;; be live at once. NOT `uses dx` -- the answer comes home in it.
qglSfAccessRdEx proc    public uses bx cx si gs,\
                        sf:dword,\
                        y:word,\
                        slot:word

                mov     gs, W sf+2                      ;; gs-> sf
                mov     si, y

                mov     bx, gs:[Surface.typ]
                CHECKKIND bx, @@dead
                add     si, gs:[Surface.startSL]        ;; + page

                shl     si, 2                           ;; * sizeof( addrTB )
                mov     cx, slot                        ;; cl= window slot
                call    qgl$dctTB[bx].rdAccessEx

                ret
@@dead:         xor     ax, ax
                xor     dx, dx
                ret
qglSfAccessRdEx endp

;;::::::::::::::
;; qglSfAccessWrEx (sf:dword, y:word, slot:word) :dword
qglSfAccessWrEx proc    public uses bx cx di fs,\
                        sf:dword,\
                        y:word,\
                        slot:word

                mov     fs, W sf+2                      ;; fs-> sf
                mov     di, y

                mov     bx, fs:[Surface.typ]
                CHECKKIND bx, @@dead
                add     di, fs:[Surface.startSL]        ;; + page

                shl     di, 2                           ;; * sizeof( addrTB )
                mov     cx, slot                        ;; cl= window slot
                call    qgl$dctTB[bx].wrAccessEx

                ret
@@dead:         xor     ax, ax
                xor     dx, dx
                ret
qglSfAccessWrEx endp
QGL_ENDS
                end
