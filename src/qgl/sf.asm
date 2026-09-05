;; sf.asm -- surfaces: pixels, and the one call that finds a row of them.
;;
;; name: sf_init / sf_new / sf_free / sf_row / sf_view / sf_pget / sf_pset
;; desc: a surface is pixels plus a width, and it does not say where it
;;       lives. sf_row answers with a far pointer either way: arithmetic
;;       for conventional memory, a page map for EMS.
;;
;;       THE SLOT IS THE CALLER'S. sf_new takes it; this module never
;;       arbitrates one. See sf.inc: mgl's emsMapEx already works that
;;       way and PAGE_SLOT already relies on it, and four private slots
;;       could not cover the nine-plus EMS objects live at once anyway.
;;       A row pointer is good until the same slot is remapped -- by
;;       this surface crossing a page, or by anything else sharing it.
;;
;; obs.: - an EMS surface's bps must divide 16K, or a row would straddle
;;         two physical pages and sf_row could not answer with one
;;         pointer. sf_new REFUSES rather than padding: every EMS surface
;;         this renderer has is a power of two already (atlas cells
;;         64/32/16/8, font 8), and silently padding would waste memory
;;         nobody asked to spend. Conventional surfaces have no such rule.
;;       - the header and the pixels are ONE allocation for a cmem
;;         surface. e1m1 dies creating a 64,048-byte backbuffer with
;;         183,504 free: the far heap's problem is fragmentation, not
;;         total, so every object here is one block.
;;       - sf_view allocates nothing at all. It re-aims a caller-owned
;;         header at part of another surface's store, which is what
;;         turned 648 texture dcs into 8 views.

                .286
                .model medium, pascal

                include sf.inc

EMS_PAGE_MASK   equ     3FFFh
EMS_PAGE_SHIFT  equ     14

;; mgl's conventional allocator, until this layer grows its own.
memAlloc        proto   far pascal :dword
memFree         proto   far pascal :dword

gem_init        proto   far pascal
gem_alloc       proto   far pascal :dword
gem_free        proto   far pascal :word
gem_map         proto   far pascal :word, :word, :word


.code

;;::::::::::::::
;; sf_init () -> ax nonzero if EMS surfaces are possible
;;::::::::::::::
sf_init         proc    public
                invoke  gem_init
                ret
sf_init         endp


;;::::::::::::::
;; sf_new ( w:word, h:word, where:word ) -> far ptr, or 0:0
;;::::::::::::::
sf_new          proc    public uses bx cx si di es,\
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

                cmp     whr, SF_EMS
                je      @@ems

                ;;
                ;; Conventional: header and pixels in ONE block.
                ;;
                mov     ax, word ptr nbytes
                mov     dx, word ptr nbytes+2
                add     ax, SIZEOF SF
                adc     dx, 0
                mov     word ptr nbytes, ax
                mov     word ptr nbytes+2, dx
                invoke  memAlloc, nbytes
                mov     word ptr hdr, ax
                mov     word ptr hdr+2, dx
                or      ax, dx
                jz      @@fail

                les     bx, hdr
                mov     ax, wid
                mov     es:[bx].SF.sfWidth, ax
                mov     ax, hgt
                mov     es:[bx].SF.sfHeight, ax
                mov     ax, bps
                mov     es:[bx].SF.sfBps, ax
                mov     es:[bx].SF.sfWhere, SF_CMEM
                mov     es:[bx].SF.sfSlot, 0
                mov     ax, word ptr hdr+2
                mov     es:[bx].SF.sfHnd, ax            ;; the segment
                ;; pixels sit straight after the header
                mov     ax, word ptr hdr
                add     ax, SIZEOF SF
                mov     word ptr es:[bx].SF.sfOfs, ax
                mov     word ptr es:[bx].SF.sfOfs+2, 0
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

                invoke  memAlloc, SIZEOF SF
                mov     word ptr hdr, ax
                mov     word ptr hdr+2, dx
                or      ax, dx
                jz      @@fail

                invoke  gem_alloc, nbytes
                test    ax, ax
                jz      @@fail_free
                mov     si, ax                  ;; handle

                mov     di, slot

                les     bx, hdr
                mov     ax, wid
                mov     es:[bx].SF.sfWidth, ax
                mov     ax, hgt
                mov     es:[bx].SF.sfHeight, ax
                mov     ax, bps
                mov     es:[bx].SF.sfBps, ax
                mov     es:[bx].SF.sfWhere, SF_EMS
                mov     ax, di
                mov     es:[bx].SF.sfSlot, al
                mov     es:[bx].SF.sfHnd, si
                mov     word ptr es:[bx].SF.sfOfs, 0
                mov     word ptr es:[bx].SF.sfOfs+2, 0

@@ok:           mov     ax, word ptr hdr
                mov     dx, word ptr hdr+2
                ret

@@fail_free:    invoke  memFree, hdr
@@fail:         xor     ax, ax
                xor     dx, dx
                ret
sf_new          endp


;;::::::::::::::
;; sf_free ( s:far ptr )
;;::::::::::::::
sf_free         proc    public uses bx cx es,\
                        s:dword

                les     bx, s
                mov     ax, es
                or      ax, bx
                jz      @@done

                cmp     es:[bx].SF.sfWhere, SF_EMS
                jne     @@justfree

                invoke  gem_free, es:[bx].SF.sfHnd

@@justfree:     invoke  memFree, s
@@done:         ret
sf_free         endp


;;::::::::::::::
;; sf_row ( s:far ptr, y:word ) -> far ptr to row y
;;
;; Valid until this SAME surface is asked for a row in another page.
;; Another surface asking for a row cannot disturb it: its slot is its
;; own.
;;::::::::::::::
sf_row          proc    public uses bx cx si di es,\
                        s:dword, y:word

                les     bx, s
                mov     ax, es:[bx].SF.sfBps
                mul     y                       ;; dx:ax = y * bps
                add     ax, word ptr es:[bx].SF.sfOfs
                adc     dx, word ptr es:[bx].SF.sfOfs+2

                cmp     es:[bx].SF.sfWhere, SF_EMS
                je      @@ems

                ;; seg = sfHnd + linear>>4, off = linear and 15
                mov     cx, ax
                and     cx, 000Fh
                shr     ax, 4
                mov     si, dx
                shl     si, 12
                or      ax, si
                add     ax, es:[bx].SF.sfHnd
                mov     dx, ax
                mov     ax, cx
                ret

@@ems:          mov     di, ax
                and     di, EMS_PAGE_MASK       ;; offset within the page
                mov     cl, EMS_PAGE_SHIFT
                shr     ax, cl
                mov     si, dx
                mov     cl, 16 - EMS_PAGE_SHIFT
                shl     si, cl
                or      ax, si                  ;; ax = logical page

                mov     cx, es:[bx].SF.sfHnd
                xor     si, si
                mov     si, ax
                xor     ax, ax
                mov     al, es:[bx].SF.sfSlot

                invoke  gem_map, cx, si, ax
                mov     dx, ax                  ;; segment, or 0
                mov     ax, di
                ret
sf_row          endp


;;::::::::::::::
;; sf_view ( v:far ptr, parent:far ptr, ofs:dword, w:word, h:word, bps:word )
;;
;; Re-aims a caller-owned header at part of another surface's store.
;; Allocates nothing, owns nothing, and shares the parent's slot -- so a
;; view and its parent must never be walked at the same time.
;;::::::::::::::
sf_view         proc    public uses bx si di es,\
                        v:dword, parent:dword, ofs:dword,\
                        wid:word, hgt:word, bps:word

                les     bx, parent
                mov     al, es:[bx].SF.sfWhere
                mov     ah, es:[bx].SF.sfSlot
                mov     si, es:[bx].SF.sfHnd
                mov     di, word ptr es:[bx].SF.sfOfs
                mov     cx, word ptr es:[bx].SF.sfOfs+2

                les     bx, v
                mov     es:[bx].SF.sfWhere, al
                mov     es:[bx].SF.sfSlot, ah
                mov     es:[bx].SF.sfHnd, si

                ;; the view's own base is the parent's plus the offset
                mov     ax, di
                mov     dx, cx
                add     ax, word ptr ofs
                adc     dx, word ptr ofs+2
                mov     word ptr es:[bx].SF.sfOfs, ax
                mov     word ptr es:[bx].SF.sfOfs+2, dx

                mov     ax, wid
                mov     es:[bx].SF.sfWidth, ax
                mov     ax, hgt
                mov     es:[bx].SF.sfHeight, ax
                mov     ax, bps
                mov     es:[bx].SF.sfBps, ax
                ret
sf_view         endp


;;::::::::::::::
;; sf_pget ( s:far ptr, x:word, y:word ) -> al
;;
;; One pixel. Slow on purpose -- this exists for the round-trip checks
;; (-dumptex reads every atlas cell back through its own view) and not
;; for anything per frame.
;;::::::::::::::
sf_pget         proc    public uses bx es,\
                        s:dword, x:word, y:word

                invoke  sf_row, s, y
                mov     es, dx
                mov     bx, ax
                add     bx, x
                mov     al, es:[bx]
                xor     ah, ah
                ret
sf_pget         endp


;;::::::::::::::
;; sf_pset ( s:far ptr, x:word, y:word, c:word )
;;::::::::::::::
sf_pset         proc    public uses bx es,\
                        s:dword, x:word, y:word, col:word

                invoke  sf_row, s, y
                mov     es, dx
                mov     bx, ax
                add     bx, x
                mov     al, byte ptr col
                mov     es:[bx], al
                ret
sf_pset         endp

                end
