;; name: qglRowRead
;; desc: reads a row of pixels from a Surface to a buffer in conv mem
;;
;; args: [in] sf:long,                  | source surface
;;            x:integer,                | start pixel
;;            y:integer,                | row
;;            pixels:integer,           | pixels to read
;;            bufferFormat:integer,     | destine color format
;;            buffer:long               | destine far ptr
;; retn: none
;;
;; chng: sep/01 written [v1ctor]
;; obs.: no clipping is made

;; name: qglRowWrite
;; desc: writes a row of pixels from a buffer in conv mem to a Surface
;;
;; chng: sep/01 written [v1ctor]
;; obs.: no clipping is made

;; name: qglRowWriteEx
;; desc: same as qglRowWrite, but can do masking
;;
;; args: [in] ... opt:integer            | option
;;
;; chng: nov/02 written [v1ctor]
;; obs.: - same as for qglRowWrite
;;
;;       - the `opt' parameter can be:
;;         * masking: msb=FFh, lsb=mask
;;         * no masking: msb=any, lsb=any

;;
;; Transcribed from mgl's ugl/uglrow.asm, and it is the loosest of the
;; transcriptions -- two things could not come across:
;;
;;   * THE COLOUR CONVERSION IS GONE. mgl's body is one indirection into
;;     ul$cfmtTB[dc.fmt].rowReadTB[bufferFmt], a table per colour format
;;     of routines per buffer format. qgl has ONE format, 8bpp, and no
;;     CFMT layer to index; what is left of the dispatch is the byte move
;;     it would have reached. bufferFmt is therefore accepted and ignored,
;;     and uglRowSetPal has no counterpart at all.
;;
;;   * NO `ss:` ON THE DISPATCH. mgl reaches the table as ss:ul$dctTB
;;     because it has already clobbered ds with the buffer, which assumes
;;     SS == DGROUP. z.asm records that measured false here: the qgl test
;;     harness links with SS 094Bh against a DGROUP of 006Ch. So
;;     `lds si, buff` moves to AFTER the dispatch, and the dispatch goes
;;     through bx with ds still DGROUP. Through bp, as it first did, the
;;     table was read via ss and bp was no longer the frame: buff and opt
;;     came from wherever typ pointed (t37rowwr). Both back-ends' access
;;     routines preserve ax and cx, which the `add di, ax` relies on.
;;

                .model  medium, pascal
                .386
                option  proc:private

                include qgl.inc

qglRowWriteEx   proto   far pascal :dword, :word, :word, :word, :word,\
                                   :dword, :word

QGL_CODE
;;::::::::::::::
;; qglRowRead (sf:dword, x:word, y:word, pixels:word, buffFmt:word, buff:dword)
qglRowRead      proc    public uses es ds,\
                        sf:dword,\
                        x:word, y:word,\
                        pixels:word,\
                        buffFmt:word,\
                        buff:dword

                pusha

                mov     gs, W sf+2              ;; gs-> sf
                CHECKSF gs, @@exit

                les     di, buff                ;; es:di-> buffer

                mov     cl, gs:[Surface.p2b]
                mov     ax, x
                shl     ax, cl

                mov     cx, pixels

                mov     si, y
                shl     si, 2

                mov     bx, gs:[Surface.typ]
                call    qgl$dctTB[bx].rdAccess  ;; ds:si-> sf[y]
                add     si, ax

                cld                             ;; 8bpp: the whole of what
                rep     movsb                   ;; ul$cfmtTB would have run

@@exit:         popa
                ret
qglRowRead      endp

;;::::::::::::::
;; qglRowWrite (sf:dword, x:word, y:word, pixels:word, srcFmt:word, src:dword)
qglRowWrite     proc    public\
                        sf:dword,\
                        x:word, y:word,\
                        pixels:word,\
                        buffFmt:word,\
                        buff:dword

                invoke  qglRowWriteEx, sf, x, y, pixels, buffFmt, buff, 0

                ret
qglRowWrite     endp

;;::::::::::::::
;; qglRowWriteEx (sf:dword, x:word, y:word, pixels:word, srcFmt:word,
;;                src:dword, opt:word)
qglRowWriteEx   proc    public uses es ds,\
                        sf:dword,\
                        x:word, y:word,\
                        pixels:word,\
                        buffFmt:word,\
                        buff:dword,\
                        opt:word

                pusha

                mov     fs, W sf+2              ;; fs-> sf
                CHECKSF fs, @@exit

                mov     cl, fs:[Surface.p2b]
                mov     ax, x
                shl     ax, cl

                mov     cx, pixels

                mov     di, y
                shl     di, 2

                ;; through bx, not bp: buff and opt are read after the call,
                ;; and with bp holding typ they came from wherever it pointed
                mov     bx, fs:[Surface.typ]
                call    qgl$dctTB[bx].wrAccess  ;; es:di-> sf[y]
                add     di, ax

                mov     bx, opt                 ;; bh: FFh masks, bl: the mask
                lds     si, buff                ;; ds:si-> buffer

                cld
                cmp     bh, 0FFh
                je      @@masked

                rep     movsb                   ;; 8bpp: the whole of what
                jmp     short @@exit            ;; ul$cfmtTB would have run

                ;; masking: opt's low byte is the colour that does not draw
@@masked:       jcxz    @@exit
@@mloop:        lodsb
                cmp     al, bl
                je      @F
                mov     es:[di], al
@@:             inc     di
                dec     cx
                jnz     @@mloop

@@exit:         popa
                ret
qglRowWriteEx   endp
QGL_ENDS
                end
