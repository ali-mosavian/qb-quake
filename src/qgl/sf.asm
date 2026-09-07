;; sf.asm -- surfaces: pixels, and the one call that finds a row of them.
;;
;; name: qglSfInit / qglSfNew / qglSfFree / qglSfRow /
;;       qglSfView / qglSfLoad / qglSfPget / qglSfPset
;; desc: a surface is pixels plus a width, and it does not say where it
;;       lives. qglSfRow answers with a far pointer either way: arithmetic
;;       for conventional memory, a page map for EMS.
;;
;;       THE SLOT IS THE CALLER'S. qglSfNew takes it; this module never
;;       arbitrates one. See sf.inc: mgl's emsMapEx already works that
;;       way and PAGE_SLOT already relies on it, and four private slots
;;       could not cover the nine-plus EMS objects live at once anyway.
;;       A row pointer is good until the same slot is remapped -- by
;;       this surface crossing a page, or by anything else sharing it.
;;
;; obs.: - an EMS surface's bps must divide 16K, or a row would straddle
;;         two physical pages and qglSfRow could not answer with one
;;         pointer. qglSfNew REFUSES rather than padding: every EMS surface
;;         this renderer has is a power of two already (atlas cells
;;         64/32/16/8, font 8), and silently padding would waste memory
;;         nobody asked to spend. Conventional surfaces have no such rule.
;;       - the header and the pixels are ONE allocation for a cmem
;;         surface. e1m1 dies creating a 64,048-byte backbuffer with
;;         183,504 free: the far heap's problem is fragmentation, not
;;         total, so every object here is one block.
;;       - qglSfView allocates nothing at all. It re-aims a caller-owned
;;         header at part of another surface's store, which is what
;;         turned 648 texture dcs into 8 views.

                .model medium, pascal
                .386

                include qgl.inc

EMS_PAGE_MASK   equ     3FFFh
EMS_PAGE_SHIFT  equ     14

qglMemAlloc   proto   far pascal :dword
qglSfNewEx   proto   far pascal :word, :word, :word, :word, :word
qglMemFree    proto   far pascal :dword

qglGemInit        proto   far pascal
qglGemAlloc       proto   far pascal :dword
qglGemFree        proto   far pascal :word
qglGemMap         proto   far pascal :word, :word, :word

qglFileOpen   proto   far pascal :dword
qglFileRead   proto   far pascal :word, :dword, :dword
qglFileClose  proto   far pascal :word


.code

;;::::::::::::::
;; qglAbi ( what:word ) -> ax = the assembly's own value for a constant
;;
;; The ONE place a BASIC caller can ask the layer what it actually
;; believes. qgl.bi is generated from qgl.inc so the two cannot drift on
;; paper, but generated or not, nothing had ever checked that the EXE on
;; disk agrees with the header the BASIC beside it was compiled against.
;; abitest.bas asks here and compares.
;;
;; The order is the order qgl.bi declares them in, and adding a constant
;; means adding it in both places -- which the test then notices.
;;::::::::::::::
qglAbi         proc    public uses bx,\
                        what:word

                mov     bx, what
                cmp     bx, ABI_N
                jae     @@bad
                shl     bx, 1
                mov     ax, cs:qgl$abiTB[bx]
                ret
@@bad:          mov     ax, -1
                ret
qglAbi         endp

qgl$abiTB       dw      MEM_LARGEST, MEM_TOTAL
                dw      SURF_CMEM, SURF_EMS
                dw      QGL_Z_OFF, QGL_Z_SET, QGL_Z_TEST
                dw      QGL_M_WIRE, QGL_M_FLAT, QGL_M_TEX, QGL_M_PTEX
ABI_N           equ     11


;;::::::::::::::
;; qglSfInit () -> ax nonzero if EMS surfaces are possible
;;::::::::::::::
qglSfInit     proc    public
                invoke  qglGemInit
                ret
qglSfInit     endp


;;::::::::::::::
;; qglSfNew ( w:word, h:word, where:word, slot:word ) -> far ptr, or 0:0
;;
;; The common case: one byte a pixel, so the stride is the width.
;;::::::::::::::
qglSfNew      proc    public uses bx,\
                        wid:word, hgt:word, whr:word, slot:word

                invoke  qglSfNewEx, wid, hgt, wid, whr, slot
                ret
qglSfNew      endp


;;::::::::::::::
;; qglSfNewEx ( w:word, h:word, stride:word, where:word, slot:word )
;;
;; A stride wider than the row is what a depth buffer needs -- two bytes
;; a pixel -- and what padding an EMS row up to a power of two needs. The
;; width stays in PIXELS either way: x_res is what every clip and every
;; pget indexes against, and a surface that lies about it makes each of
;; those wrong by exactly the factor it lied by.
;;::::::::::::::
qglSfNewEx   proc    public uses bx cx si di es,\
                        wid:word, hgt:word, strd:word, whr:word, slot:word

                local   nbytes:dword
                local   hdr:dword
                local   bps:word

                mov     ax, strd
                cmp     ax, wid
                jb      @@refuse                ;; a row that does not fit
                mov     bps, ax

                ;; row bytes * rows, as a dword: an atlas is past 64K
                mul     hgt
                mov     word ptr nbytes, ax
                mov     word ptr nbytes+2, dx

                cmp     whr, SURF_EMS
                je      @@ems

                ;;
                ;; Conventional: header and pixels in ONE block.
                ;;
                mov     ax, word ptr nbytes
                mov     dx, word ptr nbytes+2
                add     ax, SIZEOF Surface
                adc     dx, 0
                mov     word ptr nbytes, ax
                mov     word ptr nbytes+2, dx
                invoke  qglMemAlloc, nbytes
                mov     word ptr hdr, ax
                mov     word ptr hdr+2, dx
                or      ax, dx
                jz      @@fail

                les     bx, hdr
                mov     ax, wid
                mov     es:[bx].Surface.x_res, ax
                mov     ax, hgt
                mov     es:[bx].Surface.y_res, ax
                mov     ax, bps
                mov     es:[bx].Surface.stride, ax
                mov     es:[bx].Surface.kind, SURF_CMEM
                mov     es:[bx].Surface.wr_slot, 0
                mov     es:[bx].Surface.rd_slot, 0
                mov     ax, word ptr hdr+2
                mov     es:[bx].Surface.handle, ax            ;; the segment
                ;; pixels sit straight after the header
                mov     ax, word ptr hdr
                add     ax, SIZEOF Surface
                mov     word ptr es:[bx].Surface.base_ofs, ax
                mov     word ptr es:[bx].Surface.base_ofs+2, 0
                jmp     @@ok

                ;;
                ;; EMS: a row must not straddle a physical page, so bps
                ;; has to divide 16K. Refuse rather than pad.
                ;;
@@ems:          mov     ax, bps
                test    ax, ax
                jz      @@fail
                cmp     ax, 4000h
                ja      @@fail
                mov     cx, ax
                dec     cx
                test    ax, cx
                jnz     @@fail                  ;; not a power of two

                invoke  qglMemAlloc, SIZEOF Surface
                mov     word ptr hdr, ax
                mov     word ptr hdr+2, dx
                or      ax, dx
                jz      @@fail

                invoke  qglGemAlloc, nbytes
                test    ax, ax
                jz      @@fail_free
                mov     si, ax                  ;; handle

                mov     di, slot

                les     bx, hdr
                mov     ax, wid
                mov     es:[bx].Surface.x_res, ax
                mov     ax, hgt
                mov     es:[bx].Surface.y_res, ax
                mov     ax, bps
                mov     es:[bx].Surface.stride, ax
                mov     es:[bx].Surface.kind, SURF_EMS
                mov     ax, di
                mov     es:[bx].Surface.wr_slot, al
                mov     es:[bx].Surface.rd_slot, al
                mov     es:[bx].Surface.handle, si
                mov     word ptr es:[bx].Surface.base_ofs, 0
                mov     word ptr es:[bx].Surface.base_ofs+2, 0

@@ok:           mov     ax, word ptr hdr
                mov     dx, word ptr hdr+2
                ret

@@fail_free:    invoke  qglMemFree, hdr
@@refuse:
@@fail:         xor     ax, ax
                xor     dx, dx
                ret
qglSfNewEx   endp


;;::::::::::::::
;; qglSfFree ( s:far ptr )
;;::::::::::::::
qglSfFree     proc    public uses bx cx es,\
                        s:dword

                les     bx, s
                mov     ax, es
                or      ax, bx
                jz      @F

                cmp     es:[bx].Surface.kind, SURF_EMS
                jne     @@justfree

                invoke  qglGemFree, es:[bx].Surface.handle

@@justfree:     invoke  qglMemFree, s
@@:             ret
qglSfFree     endp


;;::::::::::::::
;; qgl$RowCmem / qgl$row_ems -- the two halves of a row lookup.
;;
;; INTERNAL, so registers, not the stack:
;;      in   es:bx -> the surface
;;           dx:ax  = byte offset of the row within its store
;;      out  dx:ax  = far pointer to the row
;;      All other registers survive, per qgl.inc's contract.
;;
;; Reached through qgl$typeTB, never by name. A third kind of surface is
;; a table entry and a routine, not an edit to anything already working.
;;::::::::::::::
qgl$RowCmem    proc    near private uses cx si
                ;; seg = handle + offset>>4, off = offset and 15
                mov     cx, ax
                and     cx, 000Fh
                shr     ax, 4
                mov     si, dx
                shl     si, 12
                or      ax, si
                add     ax, es:[bx].Surface.handle
                mov     dx, ax
                mov     ax, cx
                ret
qgl$RowCmem    endp

;;:::::::::::::: cmem has no window; the slot means nothing to it
qgl$CmemEx     proc    near private
                call    qgl$RowCmem
                ret
qgl$CmemEx     endp

;;:::::::::::::: a kind that is not one
qgl$RowNone    proc    near private
                xor     ax, ax
                xor     dx, dx
                ret
qgl$RowNone    endp


;;::::::::::::::
;; qgl$EmsEx -- the EMS mapper, through a page the CALLER names.
;;
;; INTERNAL: es:bx -> the surface, dx:ax = the row's byte offset,
;; cl = the physical page. dx:ax back.
;;::::::::::::::
qgl$EmsEx      proc    near private uses bx cx si di es

                mov     di, ax
                and     di, EMS_PAGE_MASK       ;; offset within the page
                push    cx                      ;; the slot
                mov     cl, EMS_PAGE_SHIFT
                shr     ax, cl
                mov     si, dx
                mov     cl, 16 - EMS_PAGE_SHIFT
                shl     si, cl
                or      ax, si                  ;; logical page
                mov     si, ax
                pop     cx

                xor     ch, ch
                mov     ax, cx                  ;; slot
                mov     cx, es:[bx].Surface.handle
                invoke  qglGemMap, cx, si, ax
                mov     dx, ax                  ;; segment, or 0
                mov     ax, di
                ret
qgl$EmsEx      endp

;;:::::::::::::: through the surface's own READ page
qgl$RdEms      proc    near private
                mov     cl, es:[bx].Surface.rd_slot
                call    qgl$EmsEx
                ret
qgl$RdEms      endp

;;:::::::::::::: and its WRITE page, which is a different one
qgl$WrEms      proc    near private
                mov     cl, es:[bx].Surface.wr_slot
                call    qgl$EmsEx
                ret
qgl$WrEms      endp


;;::::::::::::::
;; qgl$Row -- row y, through whichever accessor the caller names.
;;
;; INTERNAL: es:bx -> the surface, ax = y, si = the SurfaceOps field,
;; cl = the slot (the Ex entries only). dx:ax back.
;;
;; THE FIELD IS AN ARGUMENT because read and write are different routines
;; for EMS and the same one for cmem, and only the caller knows which it
;; is doing. That is dct.inc's arrangement: rdAccess and wrAccess are two
;; entries, not one with a flag.
;;::::::::::::::
qgl$Row         proc    near private uses bx cx si

                push    cx                      ;; the slot, for the Ex forms
                mov     cx, es:[bx].Surface.stride
                mul     cx                      ;; dx:ax = y * stride
                add     ax, W es:[bx].Surface.base_ofs
                adc     dx, W es:[bx].Surface.base_ofs+2
                pop     cx

                PS      ax, dx, cx
                mov     cl, es:[bx].Surface.kind
                xor     ch, ch
                cmp     cx, SURF_KINDS
                jae     @@nokind
                imul    cx, T SurfaceOps        ;; kind indexes; it is not the index
                add     si, cx
                PP      cx, dx, ax
                call    W qgl$typeTB[si]
                ret

@@nokind:       PP      cx, dx, ax
                xor     ax, ax
                xor     dx, dx
                ret
qgl$Row         endp


;;::::::::::::::
;; qglSfRdRow / qglSfWrRow ( s:far ptr, y:word ) -> far ptr
;; qglSfRdRowEx / qglSfWrRowEx ( s, y, slot:word ) -> far ptr
;;
;; Say which you are doing. For a conventional surface the four are one
;; routine; for an EMS one they are not, and a texture read that came in
;; through the write accessor takes the destination's window with it.
;;
;; Good until that window is remapped -- by this surface crossing a page,
;; or by anything else sharing the slot.
;;::::::::::::::
qglSfRdRow   proc    public uses bx cx si es,\
                        s:dword, y:word
                les     bx, s
                mov     ax, y
                mov     si, SurfaceOps.rd_row
                call    qgl$Row
                ret
qglSfRdRow   endp

qglSfWrRow   proc    public uses bx cx si es,\
                        s:dword, y:word
                les     bx, s
                mov     ax, y
                mov     si, SurfaceOps.wr_row
                call    qgl$Row
                ret
qglSfWrRow   endp

qglSfRdRowEx proc   public uses bx cx si es,\
                        s:dword, y:word, slot:word
                les     bx, s
                mov     ax, y
                mov     cx, slot
                mov     si, SurfaceOps.rd_row_ex
                call    qgl$Row
                ret
qglSfRdRowEx endp

qglSfWrRowEx proc   public uses bx cx si es,\
                        s:dword, y:word, slot:word
                les     bx, s
                mov     ax, y
                mov     cx, slot
                mov     si, SurfaceOps.wr_row_ex
                call    qgl$Row
                ret
qglSfWrRowEx endp

;;::::::::::::::
;; qglSfWindows ( s:far ptr ) -> ax = slots this kind holds at once
;;
;; ASK, DO NOT ASSUME, which is dct.inc's own instruction. -1 means the
;; surface has no window and any number of rows may be live.
;;::::::::::::::
qglSfWindows  proc    public uses bx si es,\
                        s:dword
                les     bx, s
                mov     si, SurfaceOps.windows
                mov     al, es:[bx].Surface.kind
                xor     ah, ah
                cmp     ax, SURF_KINDS
                jae     @@nokind
                imul    ax, T SurfaceOps
                add     si, ax
                mov     ax, qgl$typeTB[si]
                ret
@@nokind:       xor     ax, ax
                ret
qglSfWindows  endp

;;::::::::::::::
;; qglSfRow ( s:far ptr, y:word ) -> far ptr
;;
;; The READ spelling, kept because most callers only look. Anything that
;; is about to write should say so.
;;::::::::::::::
qglSfRow      proc    public uses bx cx si es,\
                        s:dword, y:word
                les     bx, s
                mov     ax, y
                mov     si, SurfaceOps.rd_row
                call    qgl$Row
                ret
qglSfRow      endp


;;::::::::::::::
;; qglSfLoad ( s:far ptr, path:far ptr ) -> ax nonzero on success
;;
;; A raw blob straight into the surface's own store: no header, no
;; palette, no format. Everything this renderer loads is produced by its
;; own tools and is already exactly the bytes the surface wants, which is
;; why the BMP container went -- AGENTS.md's own note says "the BMP is
;; just a container for that byte stream".
;;
;; Page at a time, because an EMS surface has no single pointer covering
;; it: each row's window comes from qgl$Row, and the run stops at the
;; end of that row. Slower than one read for a conventional surface and
;; correct for both, which is the trade this whole layer makes.
;;::::::::::::::
qglSfLoad     proc    public uses bx cx dx si di es,\
                        s:dword, path:dword

                local   fh:word
                local   yy:word
                local   rows:word
                local   wide:word
                local   ok:word
                local   rowp:dword

                mov     ok, 0

                invoke  qglFileOpen, path
                test    ax, ax
                jz      @@out
                mov     fh, ax

                les     bx, s
                mov     ax, es:[bx].Surface.y_res
                mov     rows, ax
                mov     ax, es:[bx].Surface.x_res
                mov     wide, ax
                xor     ax, ax
                mov     yy, ax

@@row:          mov     ax, yy
                cmp     ax, rows
                jae     @@done

                invoke  qglSfRow, s, yy
                mov     word ptr rowp, ax
                mov     word ptr rowp+2, dx
                invoke  qglFileRead, fh, rowp, wide

                cmp     ax, wide
                jne     @@done                  ;; short: the file ran out

                inc     yy
                jmp     @@row

@@done:         mov     ax, yy
                cmp     ax, rows
                jne     @F
                mov     ok, 1                   ;; every row arrived
@@:             invoke  qglFileClose, fh

@@out:          mov     ax, ok
                ret
qglSfLoad     endp


;;::::::::::::::
;; qglSfView ( v:far ptr, parent:far ptr, ofs:dword, w:word, h:word, bps:word )
;;
;; Re-aims a caller-owned header at part of another surface's store.
;; Allocates nothing, owns nothing, and shares the parent's slot -- so a
;; view and its parent must never be walked at the same time.
;;::::::::::::::
qglSfView     proc    public uses bx dx si di es,\
                        v:dword, parent:dword, ofs:dword,\
                        wid:word, hgt:word, bps:word

                les     bx, parent
                mov     al, es:[bx].Surface.kind
                mov     ah, es:[bx].Surface.wr_slot
                mov     dl, es:[bx].Surface.rd_slot
                mov     si, es:[bx].Surface.handle
                mov     di, word ptr es:[bx].Surface.base_ofs
                mov     cx, word ptr es:[bx].Surface.base_ofs+2

                les     bx, v
                mov     es:[bx].Surface.kind, al
                mov     es:[bx].Surface.wr_slot, ah
                mov     es:[bx].Surface.rd_slot, dl
                mov     es:[bx].Surface.handle, si

                ;; the view's own base is the parent's plus the offset
                mov     ax, di
                mov     dx, cx
                add     ax, word ptr ofs
                adc     dx, word ptr ofs+2
                mov     word ptr es:[bx].Surface.base_ofs, ax
                mov     word ptr es:[bx].Surface.base_ofs+2, dx

                mov     ax, wid
                mov     es:[bx].Surface.x_res, ax
                mov     ax, hgt
                mov     es:[bx].Surface.y_res, ax
                mov     ax, bps
                mov     es:[bx].Surface.stride, ax
                ret
qglSfView     endp


;;::::::::::::::
;; qglSfPget ( s:far ptr, x:word, y:word ) -> al
;;
;; One pixel. Slow on purpose -- this exists for the round-trip checks
;; (-dumptex reads every atlas cell back through its own view) and not
;; for anything per frame.
;;::::::::::::::
qglSfPget     proc    public uses bx cx si es,\
                        s:dword, x:word, y:word

                les     bx, s
                mov     ax, x                   ;; unsigned: a negative x
                cmp     ax, es:[bx].Surface.x_res       ;; is a huge one
                jae     @@none
                mov     ax, y
                cmp     ax, es:[bx].Surface.y_res
                jae     @@none

                mov     si, SurfaceOps.rd_row
                call    qgl$Row
                mov     es, dx
                mov     bx, ax
                add     bx, x
                mov     al, es:[bx]
                xor     ah, ah
                ret

@@none:         xor     ax, ax                  ;; off the surface reads 0
                ret
qglSfPget     endp


;;::::::::::::::
;; qglSfPset ( s:far ptr, x:word, y:word, c:word )
;;::::::::::::::
qglSfPset     proc    public uses bx cx si es,\
                        s:dword, x:word, y:word, col:word

                ;; A PIXEL PAST THE LAST COLUMN LANDS IN THE NEXT ROW,
                ;; inside the same allocation, so nothing faults and
                ;; nothing downstream complains -- the picture just grows
                ;; a wrong pixel. Past the last row it leaves the surface
                ;; altogether. Both are refused here.
                les     bx, s
                mov     ax, x
                cmp     ax, es:[bx].Surface.x_res
                jae     @@none
                mov     ax, y
                cmp     ax, es:[bx].Surface.y_res
                jae     @@none

                mov     si, SurfaceOps.wr_row
                call    qgl$Row
                mov     es, dx
                mov     bx, ax
                add     bx, x
                mov     al, byte ptr col
                mov     es:[bx], al
@@none:         ret
qglSfPset     endp


;;::::::::::::::
;; qglSfScratch ( n:word ) -> dx:ax, a Surface this layer owns
;;
;; For callers that cannot spell the layout. qglSfAdoptDc fills a
;; Surface the CALLER owns, which is right -- the pixels are mgl's and
;; nothing here should pretend otherwise -- but d_faces.c adopts a
;; destination once a frame and a texture view once a face, and
;; declaring those sixteen bytes in C would be the same fact kept in two
;; places. That is exactly what qgl.bi is generated to prevent, and a C
;; struct would have no generator watching it.
;;
;; A fixed few, by index, so the caller allocates nothing either. Out of
;; range answers 0:0, which qglSfAdoptDc already refuses, so a wrong
;; index fails at adoption rather than writing through whatever lay at
;; that offset.
;;::::::::::::::
qglSfScratch  proc    public,\
                        n:word

                mov     ax, n
                cmp     ax, QGL_SCRATCH         ;; unsigned: negative is huge
                jae     @@none
                imul    ax, T Surface
                add     ax, O qgl$scratch
                mov     dx, ds                  ;; DGROUP, as everywhere here
                ret

@@none:         xor     ax, ax
                xor     dx, dx
                ret
qglSfScratch  endp


.data?
qgl$scratch     Surface QGL_SCRATCH dup (<>)


.data
;; One entry per surface kind, indexed by SURF_CMEM / SURF_EMS.
;; Indexed BY KIND, so there is a slot for every kind value and the one
;; between SURF_CMEM and SURF_EMS is not a kind. It refuses rather than
;; aliasing a real entry, so a bogus kind fails instead of drawing.
qgl$typeTB      SurfaceOps <O qgl$RowCmem, O qgl$RowCmem, O qgl$CmemEx, O qgl$CmemEx, -1>
                SurfaceOps <O qgl$RowNone, O qgl$RowNone, O qgl$RowNone, O qgl$RowNone, 0>
                SurfaceOps <O qgl$RdEms,   O qgl$WrEms,   O qgl$EmsEx,  O qgl$EmsEx,   4>

                end
