;; name: qglNewView
;; desc: a Surface over another Surface's pixels. A view, in the numpy
;;       sense: it has its own shape and clipping but owns no memory, and
;;       nothing is copied. Many small views over one big Surface replace
;;       many small Surfaces, which matters because a Surface costs
;;       sizeof(Surface) + yRes*4 bytes of CONVENTIONAL memory for its
;;       scanline address table -- so a surface cache that gave every
;;       cached surface one of its own spends its budget on tables rather
;;       than pixels.
;;
;;       The parent must outlive the view, and freeing the parent leaves
;;       every view of it dangling. Same bargain numpy makes.
;;
;; args: [in] src:long,         | the Surface that owns the pixels
;;            ofs:long,         | byte offset of the view within it
;;            xRes:integer,     | width  (> 0; <= 16384)
;;            yRes:integer      | height (> 0)
;; retn: long                   | surface (0 if error)
;;
;; obs.: SF_MEM and SF_EMS parents only. An SF_EMS view must not straddle a
;;       16K page: the texture fillers map one page and then address the
;;       texture flat, so the seam would read garbage. Sizes here are powers
;;       of two that divide the page, so aligning ofs to the view's byte
;;       size is enough.

;; name: qglSetView
;; desc: Re-aims a view at another offset in the same parent. No allocation
;;       and no copy -- this is the whole point of a view, and it is what
;;       lets one descriptor per size class stand in for a whole cache.
;;
;; args: [in] sf:long,          | the view
;;            ofs:long          | its new byte offset within the parent
;; retn: integer                | FALSE if error, TRUE otherwise

;; name: qglDelView
;; desc: Frees a view: its struct and its address table, never the pixels.
;;       Deliberately not qglDel -- a Surface carries no mark saying whose
;;       memory it is, so qglDel on a view would hand the parent's storage
;;       back while other views still point into it.
;;
;; chng: aug/26 written
;; obs.: transcribed from mgl's ugl/uglview.asm.

                .model  medium, pascal
                .386
                option  proc:private

                include qgl.inc

qglMemAlloc     proto   far pascal :dword
qglMemFree      proto   far pascal :dword

.code

;;::::::::::::::
;; qgl$fillView (sf:dword, ofs:dword) :word -- private
;;
;; Lays down the scanline address table. Both parent types store an entry
;; as a dword: the low word addresses a 'bank' and the high word an offset
;; inside it. They differ only in how far the offset runs before the bank
;; steps, and by how much:
;;
;;   SF_EMS   low = handle + (page << 8),  offset wraps at 16K, page += 1
;;   SF_MEM   low = segment,               offset wraps at 64K, seg  += 4096
;;
;; so one loop drives both, parameterised by that pair.
qgl$fillView    proc    near private uses bx cx dx si di es,\
                        sf:dword, ofs:dword

                mov     es, W sf+2              ;; es-> sf

                mov     cx, es:[Surface.bps]
                mov     ax, es:[Surface.yRes]
                test    ax, ax
                jz      @@error

                xor     di, di
                mov     si, es:[Surface.typ]
                cmp     si, SF_EMS
                je      @@ems
                cmp     si, SF_MEM
                je      @@mem
                jmp     short @@error           ;; anything else: not supported

                ;;
                ;; EMS: split the byte offset into a logical page and an
                ;; offset inside it, and add the page into the handle's
                ;; high byte exactly as qgl_ems_New does.
                ;;
@@ems:          push    eax
                mov     eax, ofs
                mov     ebx, eax
                shr     eax, 14                 ;; ax= logical page
                and     bx, EMS_PGSIZE-1        ;; bx= offset in page
                mov     dx, es:[Surface.hnd]
                add     dh, al                  ;; += page, as qgl_ems_New's
                                                ;; accumulating adc dh,0 does.
                                                ;; NOT mov: that discards the
                                                ;; handle's own high byte, which
                                                ;; is zero only for the first few
                                                ;; EMS allocations -- so a view
                                                ;; over any later surface addressed
                                                ;; somebody else's pages.
                pop     eax

@@eloop:        mov     W es:[SF_addrTB+di+0], dx
                mov     W es:[SF_addrTB+di+2], bx
                add     di, 4

                add     bx, cx                  ;; bx+= bps
                cmp     bx, EMS_PGSIZE
                jb      @@enext
                sub     bx, EMS_PGSIZE
                add     dh, 1                   ;; ++logical page
@@enext:        dec     ax
                jnz     @@eloop
                jmp     short @@done

                ;;
                ;; MEM: the parent's far pointer plus the offset, kept
                ;; normalised so the offset half starts inside a paragraph.
                ;;
@@mem:          push    eax
                mov     eax, ofs
                mov     ebx, eax
                shr     eax, 4                  ;; ax= paragraphs
                and     bx, 15                  ;; bx= remainder
                mov     dx, W es:[Surface.fptr+2]  ;; parent segment
                add     dx, ax
                add     bx, W es:[Surface.fptr+0]  ;; parent offset
                pop     eax

@@mloop:        mov     W es:[SF_addrTB+di+0], dx
                mov     W es:[SF_addrTB+di+2], bx
                add     di, 4

                add     bx, cx                  ;; bx+= bps
                jnc     @@mnext
                add     dx, 1000h               ;; past 64k: seg+= 4096
@@mnext:        dec     ax
                jnz     @@mloop

@@done:         mov     ax, TRUE
                ret

@@error:        xor     ax, ax                  ;; FALSE
                ret
qgl$fillView    endp

;;::::::::::::::
;; qglNewView (src:dword, ofs:dword, xRes:word, yRes:word) :dword
qglNewView      proc    public uses bx cx di si fs gs,\
                        src:dword, ofs:dword,\
                        xRes:word, yRes:word

                LOGBEGIN qglNewView

                mov     bx, xRes
                mov     si, yRes

                test    bx, bx
                jz      @@error
                test    si, si
                jz      @@error

                mov     ax, W src+2
                test    ax, ax
                jz      @@error
                mov     gs, ax                  ;; gs-> parent

                mov     di, gs:[Surface.typ]
                cmp     qgl$dctTB[di].state, TRUE
                jne     @@error

                ;; allocate the descriptor and its table -- and nothing else
                LOGMSG  <view Surface>
                mov     eax, T Surface
                mov     cx, si                  ;; addrTB size= yRes*4
                shl     cx, 2                   ;; /
                add     ax, cx
                invoke  qglMemAlloc, eax
                mov     cx, ax
                or      cx, dx
                jz      @@error

                push    dx
                mov     fs, dx                  ;; fs-> view

        ifdef   _DEBUG_
                mov     fs:[Surface.sign], QGL_SIGN
        endif
                lea     ax, [bx - 1]
                lea     dx, [si - 1]
                mov     fs:[Surface.xMin], 0
                mov     fs:[Surface.yMin], 0
                mov     fs:[Surface.xMax], ax
                mov     fs:[Surface.yMax], dx

                mov     fs:[Surface.xRes], bx
                mov     fs:[Surface.yRes], si

                ;; the view answers to the parent's type and format, so the
                ;; parent's accessors reach its pixels unchanged
                mov     fs:[Surface.typ], di
                mov     ax, gs:[Surface.fmt]
                mov     fs:[Surface.fmt], ax
                mov     cx, FMT_8BIT_BPP        ;; mgl reads ul$cfmtTB[fmt]
                mov     ax, FMT_8BIT_P2B        ;; here; qgl has one format
                mov     fs:[Surface.bpp], cl
                mov     fs:[Surface.p2b], al

                ;; the view's window is the parent's, and it has to be:
                ;; nothing here owns EMS pages

                ;;
                ;; Stride, as calcBPS computes it for one page -- that proc
                ;; is private to qglnew. The rest of it rounds the scanline
                ;; up so a banked surface's rows break outside the visible
                ;; area, which a view must not do: its rows are wherever the
                ;; parent's bytes already are.
                ;;
                shl     cl, 1                   ;; cl= bpp, +1 when bpp=15
                inc     cl                      ;; /
                shr     cl, 5                   ;; /
                shl     bx, cl                  ;; bps= xRes << pixel size
                add     bx, 7                   ;; multiple of 8
                and     bx, not 7               ;; /
                mov     fs:[Surface.bps], bx

                mov     fs:[Surface.pages], 1
                mov     fs:[Surface.startSL], 0

                ;; No depth until qglSfZNew makes one. qglMemAlloc does
                ;; not zero what it hands back, and a stale pointer here
                ;; is a depth write into whatever it names.
                mov     D fs:[Surface.zsf], 0
                mov     fs:[Surface.zmode], QGL_Z_OFF

                ;; size= bps * yRes
                mov     ax, bx
                mul     si
                mov     W fs:[Surface._size+0], ax
                mov     W fs:[Surface._size+2], dx

                ;; borrow the parent's storage identity: the handle for an
                ;; EMS parent, the far pointer for a MEM one. Same four
                ;; bytes either way.
                mov     eax, D gs:[Surface.fptr]
                mov     D fs:[Surface.fptr], eax

                pop     dx
                push    dx
                mov     ax, dx
                shl     eax, 16                 ;; eax= sf (seg:0)
                invoke  qgl$fillView, eax, ofs
                test    ax, ax
                jz      @@err_fill

                pop     dx
                xor     ax, ax                  ;; return seg:0, CF clean

@@exit:         LOGEND
                ret

@@err_fill:     pop     dx
                shl     edx, 16
                invoke  qglMemFree, edx

@@error:        LOGERROR
                xor     ax, ax                  ;; return NULL
                xor     dx, dx                  ;; /
                stc                             ;; CF set
                jmp     short @@exit
qglNewView      endp

;;::::::::::::::
;; qglSetView (sf:dword, ofs:dword) :word
qglSetView      proc    public uses bx,\
                        sf:dword, ofs:dword

                LOGBEGIN qglSetView

                mov     ax, W sf+2
                test    ax, ax
                jz      @@error

                invoke  qgl$fillView, sf, ofs
                test    ax, ax
                jz      @@error

                mov     ax, TRUE
                LOGEND
                ret

@@error:        LOGERROR
                xor     ax, ax                  ;; FALSE
                LOGEND
                ret
qglSetView      endp

;;::::::::::::::
;; qglAimView (sf:dword, ofs:dword) :word
;;
;; qglSetView for row 0 alone, which is all qgl$SetTex reads: a surface
;; cache hit re-aimed every row of its view once a face for nothing.
;; Rows past 0 are left pointing wherever they did.
qglAimView      proc    public,\
                        sf:dword, ofs:dword

                mov     ax, W sf+2
                test    ax, ax
                jz      @@error
                push    es
                push    bx
                push    dx
                mov     es, ax                  ;; es-> sf

                ;; fillView's first entry, both halves
                mov     ax, W ofs+0
                mov     dx, W ofs+2
                cmp     es:[Surface.typ], SF_EMS
                je      @@ems
                cmp     es:[Surface.typ], SF_MEM
                jne     @@refuse

                mov     bx, ax
                and     bx, 15                  ;; bx= remainder
                shrd    ax, dx, 4               ;; ax= paragraphs
                mov     dx, W es:[Surface.fptr+2]
                add     dx, ax
                add     bx, W es:[Surface.fptr+0]
                jmp     short @@put

@@ems:          mov     bx, ax
                and     bx, EMS_PGSIZE-1        ;; bx= offset in page
                shrd    ax, dx, 14              ;; al= logical page
                mov     dx, es:[Surface.hnd]
                add     dh, al                  ;; add, as fillView says why

@@put:          mov     W es:[SF_addrTB+0], dx
                mov     W es:[SF_addrTB+2], bx
                mov     ax, TRUE
                jmp     short @@out

@@refuse:       xor     ax, ax
@@out:          pop     dx
                pop     bx
                pop     es
                ret

@@error:        xor     ax, ax                  ;; FALSE
                ret
qglAimView      endp

;;::::::::::::::
;; qglDelView (sf:dword)
qglDelView      proc    public,\
                        sf:dword

                LOGBEGIN qglDelView

                mov     ax, W sf+2
                test    ax, ax
                jz      @@exit

                ;; the struct and its table, never the pixels
                invoke  qglMemFree, sf

@@exit:         LOGEND
                ret
qglDelView      endp

                end
