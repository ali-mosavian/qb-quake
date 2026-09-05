;; sf.asm -- surfaces: pixels, and the one call that finds a row of them.
;;
;; name: qgl_sf_init / qgl_sf_new / qgl_sf_free / qgl_sf_row / qgl_sf_view / qgl_sf_pget / qgl_sf_pset
;; desc: a surface is pixels plus a width, and it does not say where it
;;       lives. qgl_sf_row answers with a far pointer either way: arithmetic
;;       for conventional memory, a page map for EMS.
;;
;;       THE SLOT IS THE CALLER'S. qgl_sf_new takes it; this module never
;;       arbitrates one. See sf.inc: mgl's emsMapEx already works that
;;       way and PAGE_SLOT already relies on it, and four private slots
;;       could not cover the nine-plus EMS objects live at once anyway.
;;       A row pointer is good until the same slot is remapped -- by
;;       this surface crossing a page, or by anything else sharing it.
;;
;; obs.: - an EMS surface's bps must divide 16K, or a row would straddle
;;         two physical pages and qgl_sf_row could not answer with one
;;         pointer. qgl_sf_new REFUSES rather than padding: every EMS surface
;;         this renderer has is a power of two already (atlas cells
;;         64/32/16/8, font 8), and silently padding would waste memory
;;         nobody asked to spend. Conventional surfaces have no such rule.
;;       - the header and the pixels are ONE allocation for a cmem
;;         surface. e1m1 dies creating a 64,048-byte backbuffer with
;;         183,504 free: the far heap's problem is fragmentation, not
;;         total, so every object here is one block.
;;       - qgl_sf_view allocates nothing at all. It re-aims a caller-owned
;;         header at part of another surface's store, which is what
;;         turned 648 texture dcs into 8 views.

                .286
                .model medium, pascal

                include qgl.inc

EMS_PAGE_MASK   equ     3FFFh
EMS_PAGE_SHIFT  equ     14

qgl_mem_alloc   proto   far pascal :dword
qgl_mem_free    proto   far pascal :dword

qgl_gem_init        proto   far pascal
qgl_gem_alloc       proto   far pascal :dword
qgl_gem_free        proto   far pascal :word
qgl_gem_map         proto   far pascal :word, :word, :word


.code

;;::::::::::::::
;; qgl_sf_init () -> ax nonzero if EMS surfaces are possible
;;::::::::::::::
qgl_sf_init     proc    public
                invoke  qgl_gem_init
                ret
qgl_sf_init     endp


;;::::::::::::::
;; qgl_sf_new ( w:word, h:word, where:word ) -> far ptr, or 0:0
;;::::::::::::::
qgl_sf_new      proc    public uses bx cx si di es,\
                        wid:word, hgt:word, whr:word, slot:word

                local   nbytes:dword
                local   hdr:dword
                local   bps:word

                mov     ax, wid
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
                invoke  qgl_mem_alloc, nbytes
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
                mov     es:[bx].Surface.slot, 0
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

                invoke  qgl_mem_alloc, SIZEOF Surface
                mov     word ptr hdr, ax
                mov     word ptr hdr+2, dx
                or      ax, dx
                jz      @@fail

                invoke  qgl_gem_alloc, nbytes
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
                mov     es:[bx].Surface.slot, al
                mov     es:[bx].Surface.handle, si
                mov     word ptr es:[bx].Surface.base_ofs, 0
                mov     word ptr es:[bx].Surface.base_ofs+2, 0

@@ok:           mov     ax, word ptr hdr
                mov     dx, word ptr hdr+2
                ret

@@fail_free:    invoke  qgl_mem_free, hdr
@@fail:         xor     ax, ax
                xor     dx, dx
                ret
qgl_sf_new      endp


;;::::::::::::::
;; qgl_sf_free ( s:far ptr )
;;::::::::::::::
qgl_sf_free     proc    public uses bx cx es,\
                        s:dword

                les     bx, s
                mov     ax, es
                or      ax, bx
                jz      @F

                cmp     es:[bx].Surface.kind, SURF_EMS
                jne     @@justfree

                invoke  qgl_gem_free, es:[bx].Surface.handle

@@justfree:     invoke  qgl_mem_free, s
@@:             ret
qgl_sf_free     endp


;;::::::::::::::
;; qgl$row_cmem / qgl$row_ems -- the two halves of a row lookup.
;;
;; INTERNAL, so registers, not the stack:
;;      in   es:bx -> the surface
;;           dx:ax  = byte offset of the row within its store
;;      out  dx:ax  = far pointer to the row
;;      uses cx si di
;;
;; Reached through qgl$typeTB, never by name. A third kind of surface is
;; a table entry and a routine, not an edit to anything already working.
;;::::::::::::::
qgl$row_cmem    proc    near private
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
qgl$row_cmem    endp


qgl$row_ems     proc    near private
                mov     di, ax
                and     di, EMS_PAGE_MASK       ;; offset within the page
                mov     cl, EMS_PAGE_SHIFT
                shr     ax, cl
                mov     si, dx
                mov     cl, 16 - EMS_PAGE_SHIFT
                shl     si, cl
                or      ax, si                  ;; logical page
                mov     si, ax

                mov     cx, es:[bx].Surface.handle
                xor     ax, ax
                mov     al, es:[bx].Surface.slot
                invoke  qgl_gem_map, cx, si, ax
                mov     dx, ax                  ;; segment, or 0
                mov     ax, di
                ret
qgl$row_ems     endp


;;::::::::::::::
;; qgl_sf_row ( s:far ptr, y:word ) -> far ptr to row y
;;
;; Good until the slot this surface maps through is remapped -- by this
;; surface crossing a page, or by anything else sharing the slot.
;;::::::::::::::
qgl_sf_row      proc    public uses bx cx si di es,\
                        s:dword, y:word

                les     bx, s
                mov     ax, es:[bx].Surface.stride
                mul     y                       ;; dx:ax = y * bps
                add     ax, word ptr es:[bx].Surface.base_ofs
                adc     dx, word ptr es:[bx].Surface.base_ofs+2

                ;; kind is already the byte offset into the table
                mov     cl, es:[bx].Surface.kind
                xor     ch, ch
                mov     si, cx
                call    qgl$typeTB[si].row
                ret
qgl_sf_row      endp


;;::::::::::::::
;; qgl_sf_view ( v:far ptr, parent:far ptr, ofs:dword, w:word, h:word, bps:word )
;;
;; Re-aims a caller-owned header at part of another surface's store.
;; Allocates nothing, owns nothing, and shares the parent's slot -- so a
;; view and its parent must never be walked at the same time.
;;::::::::::::::
qgl_sf_view     proc    public uses bx si di es,\
                        v:dword, parent:dword, ofs:dword,\
                        wid:word, hgt:word, bps:word

                les     bx, parent
                mov     al, es:[bx].Surface.kind
                mov     ah, es:[bx].Surface.slot
                mov     si, es:[bx].Surface.handle
                mov     di, word ptr es:[bx].Surface.base_ofs
                mov     cx, word ptr es:[bx].Surface.base_ofs+2

                les     bx, v
                mov     es:[bx].Surface.kind, al
                mov     es:[bx].Surface.slot, ah
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
qgl_sf_view     endp


;;::::::::::::::
;; qgl_sf_pget ( s:far ptr, x:word, y:word ) -> al
;;
;; One pixel. Slow on purpose -- this exists for the round-trip checks
;; (-dumptex reads every atlas cell back through its own view) and not
;; for anything per frame.
;;::::::::::::::
qgl_sf_pget     proc    public uses bx es,\
                        s:dword, x:word, y:word

                invoke  qgl_sf_row, s, y
                mov     es, dx
                mov     bx, ax
                add     bx, x
                mov     al, es:[bx]
                xor     ah, ah
                ret
qgl_sf_pget     endp


;;::::::::::::::
;; qgl_sf_pset ( s:far ptr, x:word, y:word, c:word )
;;::::::::::::::
qgl_sf_pset     proc    public uses bx es,\
                        s:dword, x:word, y:word, col:word

                invoke  qgl_sf_row, s, y
                mov     es, dx
                mov     bx, ax
                add     bx, x
                mov     al, byte ptr col
                mov     es:[bx], al
                ret
qgl_sf_pset     endp


.data
;; One entry per surface kind, indexed by SURF_CMEM / SURF_EMS.
qgl$typeTB      SurfaceOps     <offset qgl$row_cmem>
                SurfaceOps     <offset qgl$row_ems>

                end
