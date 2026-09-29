;; ems.asm -- expanded memory: the four physical pages, and nothing else.
;;
;; name: qglGemInit / qglGemFrame / qglGemAlloc / qglGemFree / qglGemMap
;; desc: raw EMS 3.2. Who owns which physical page is the caller's
;;       business and never this module's -- the same contract mgl's own
;;       emsMapEx offers, and for the same stated reason: its plain
;;       accessor "evicts whatever the renderer had there", so the form
;;       that takes an explicit slot is the one anything sharing the page
;;       frame has to use.
;;
;;       What each slot holds IS this module's business, and the record
;;       lives here and nowhere else. A caller keeping its own "I mapped
;;       page N there" is wrong the moment anyone else remaps the slot,
;;       and wrong silently. Asked for the page a slot already holds,
;;       qglGemMap answers with a compare and no INT 67h -- which is what
;;       lets ar.asm ask on every access and a sequential walk cost
;;       nothing. qglGemFree forgets the handle: EMM hands a freed number
;;       straight back to the next allocation, and a record that survived
;;       would answer the new handle's first map with the old page.
;;
;;       This exists because it is a handful of INT 67h calls and owning
;;       them removes a dependency, not because mgl's were wrong.
;;
;;       gem_, not ems_: mgl owns that whole namespace for as long as it
;;       is linked (ems_Init, ems_New, ems_Del and a dozen more in
;;       dctems.asm), and LINK folds case, so ems_init collides outright.
;;
;; obs.: - a page is 16K and there are exactly four physical ones, at
;;         frame + slot*400h. Both are the hardware's numbers, not ours.
;;       - qglGemAlloc takes BYTES and rounds up; every caller had the byte
;;         count and none of them wanted to do that arithmetic twice.

                .286
                .model medium, pascal

EMS_INT         equ     67h
EMS_PAGE_SIZE   equ     4000h           ;; 16K
EMS_PAGE_SHIFT  equ     14


EMS_SLOTS       equ     4

.data
qgl$pgframe     dw      0               ;; segment, 0 until qglGemInit says otherwise
qgl$emsok       dw      0
qgl$gem_hnd     dw      EMS_SLOTS dup (0)   ;; handle mapped per slot, 0 = nothing
qgl$gem_pg      dw      EMS_SLOTS dup (0)   ;; and its logical page

;; The same record packed the way an addrTB entry packs it -- logical
;; page in the high byte, handle in the low -- because dctems compares a
;; scanline's entry against the slot on every access and a compare there
;; must not cost a call. It is published rather than duplicated: dctems
;; kept its own copy until an EMS read came back holding another store's
;; page, and a second copy of this is only ever as good as the last
;; caller that mapped without telling it. See its own note.
                public  qgl$gem_key
qgl$gem_key     dw      EMS_SLOTS dup (0FFFFh)


.code

;;::::::::::::::
;; qglGemInit () -> ax nonzero if EMS is usable
;;
;; Checks the driver is really there before trusting INT 67h: the vector
;; is populated on machines with no EMM at all, and the documented probe
;; is the device name sitting at offset 10 of the handler's segment.
;;::::::::::::::
;; uses CX, and it is load-bearing: `repe cmpsb` below eats it, and
;; qglSfInit walks the dispatch table with its loop counter in cx across
;; this very call. Without it the counter came back as whatever the string
;; compare left, qglSfInit ran off the end of the table and called through
;; garbage -- a hang with every test's output already printed, which reads
;; as a fault in whatever ran last. mgl's own emsCheck says
;; `uses bx cx di si es` for the same reason.
qglGemInit    proc    public uses bx cx si di es

                mov     [qgl$emsok], 0
                mov     [qgl$pgframe], 0
                call    qgl$GemForget

                ;; "EMMXXXX0" at handler_seg:000A
                mov     ax, 3567h               ;; get vector 67h
                int     21h
                mov     ax, es
                test    ax, ax
                jz      @@no

                mov     di, 10
                mov     si, offset qgl$emsname
                mov     cx, 8
                cld
                repe    cmpsb
                jne     @@no

                ;; the driver answers, so ask it for the page frame
                mov     ah, 41h
                int     EMS_INT
                test    ah, ah
                jnz     @@no
                mov     [qgl$pgframe], bx

                mov     [qgl$emsok], 1
                mov     ax, 1
                ret

@@no:           xor     ax, ax
                ret
qglGemInit    endp


;;::::::::::::::
;; qglGemFrame () -> ax = page frame segment, 0 if none
;;::::::::::::::
qglGemFrame   proc    public
                mov     ax, [qgl$pgframe]
                ret
qglGemFrame   endp


;;::::::::::::::
;; qglGemAlloc ( bytes:dword ) -> ax = handle, 0 on failure
;;::::::::::::::
qglGemAlloc   proc    public uses bx cx dx,\
                        nbytes:dword

                cmp     [qgl$emsok], 0
                je      @@fail

                ;; pages = (bytes + 16383) >> 14, in dx:ax
                mov     ax, word ptr nbytes
                mov     dx, word ptr nbytes+2
                add     ax, EMS_PAGE_SIZE-1
                adc     dx, 0

                ;; >>14 of dx:ax, which for any size we allocate leaves a
                ;; count that fits a word
                mov     cl, EMS_PAGE_SHIFT
                shr     ax, cl
                mov     bx, dx
                mov     cl, 16 - EMS_PAGE_SHIFT
                shl     bx, cl
                or      ax, bx

                test    ax, ax
                jz      @@fail                  ;; a zero-byte surface is a bug

                mov     bx, ax
                mov     ah, 43h                 ;; allocate pages
                int     EMS_INT
                test    ah, ah
                jnz     @@fail

                mov     ax, dx                  ;; handle
                ret

@@fail:         xor     ax, ax
                ret
qglGemAlloc   endp


;;::::::::::::::
;; qglGemFree ( handle:word )
;;::::::::::::::
qglGemFree    proc    public uses bx cx dx,\
                        hnd:word

                mov     dx, hnd
                test    dx, dx
                jz      @@done
                mov     ah, 45h
                int     EMS_INT

                ;; every slot that held a page of it forgets. Named
                ;; labels: with two `@@:` in the loop, `loop @B` went
                ;; back to the nearer one and only slot 0 was ever asked.
                mov     dx, hnd                 ;; the driver owes no register
                mov     cx, EMS_SLOTS
                xor     bx, bx
@@slot:         cmp     [qgl$gem_hnd+bx], dx
                jne     @@next
                mov     [qgl$gem_hnd+bx], 0
                mov     [qgl$gem_key+bx], 0FFFFh  ;; dctems compares the key, not gem_hnd
@@next:         add     bx, 2
                loop    @@slot
@@done:         ret
qglGemFree    endp


;;::::::::::::::
;; qgl$GemForget -- no slot holds anything, as far as this module knows
;;::::::::::::::
qgl$GemForget   proc    near private uses bx cx
                mov     cx, EMS_SLOTS
                xor     bx, bx
@@:             mov     [qgl$gem_hnd+bx], 0
                mov     [qgl$gem_key+bx], 0FFFFh
                add     bx, 2
                loop    @B
                ret
qgl$GemForget   endp


;;::::::::::::::
;; qglGemMap ( handle:word, logpage:word, slot:word ) -> ax = segment, 0 on fail
;;
;; Maps one logical page of a handle into one physical page, and hands
;; back the segment it now answers at. The caller owns the slot; nothing
;; here arbitrates them. What a slot holds is recorded here, and a
;; request for the page already there is answered without the driver.
;;::::::::::::::
qglGemMap     proc    public uses bx cx dx,\
                        hnd:word, logpage:word, slot:word

                mov     bx, slot
                cmp     bx, EMS_SLOTS
                jae     @@fail                  ;; four physical pages, no more
                shl     bx, 1

                mov     ax, hnd
                cmp     [qgl$gem_hnd+bx], ax
                jne     @@map
                mov     ax, logpage
                cmp     [qgl$gem_pg+bx], ax
                je      @@seg                   ;; already there

@@map:          mov     dx, hnd
                mov     bx, logpage
                mov     ax, slot
                mov     ah, 44h                 ;; al = physical page
                int     EMS_INT
                test    ah, ah
                jnz     @@lost

                mov     bx, slot
                shl     bx, 1
                mov     ax, hnd
                mov     [qgl$gem_hnd+bx], ax
                mov     ax, logpage
                mov     [qgl$gem_pg+bx], ax
                mov     ah, al                  ;; ah= logical page
                mov     al, byte ptr hnd        ;; al= handle
                mov     [qgl$gem_key+bx], ax

@@seg:          ;; frame + slot*400h -- 16K in paragraphs
                mov     ax, slot
                mov     cl, 10
                shl     ax, cl
                add     ax, [qgl$pgframe]
                ret

@@lost:         ;; the driver refused, and what the slot holds now is
                ;; its business: the record must not claim otherwise
                mov     bx, slot
                shl     bx, 1
                mov     [qgl$gem_hnd+bx], 0
                mov     [qgl$gem_key+bx], 0FFFFh
@@fail:         xor     ax, ax
                ret
qglGemMap     endp


.data
qgl$emsname     db      "EMMXXXX0"

                end
