;; ems.asm -- expanded memory: the four physical pages, and nothing else.
;;
;; name: gem_init / gem_frame / gem_alloc / gem_free / gem_map
;; desc: raw EMS 3.2. Who owns which physical page is the caller's
;;       business and never this module's -- the same contract mgl's own
;;       emsMapEx offers, and for the same stated reason: its plain
;;       accessor "evicts whatever the renderer had there", so the form
;;       that takes an explicit slot is the one anything sharing the page
;;       frame has to use.
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
;;       - gem_alloc takes BYTES and rounds up; every caller had the byte
;;         count and none of them wanted to do that arithmetic twice.

                .286
                .model medium, pascal

EMS_INT         equ     67h
EMS_PAGE_SIZE   equ     4000h           ;; 16K
EMS_PAGE_SHIFT  equ     14


.data
gem_pgframe     dw      0               ;; segment, 0 until gem_init says otherwise
gem_present     dw      0


.code

;;::::::::::::::
;; gem_init () -> ax nonzero if EMS is usable
;;
;; Checks the driver is really there before trusting INT 67h: the vector
;; is populated on machines with no EMM at all, and the documented probe
;; is the device name sitting at offset 10 of the handler's segment.
;;::::::::::::::
gem_init        proc    public uses bx si di es

                mov     [gem_present], 0
                mov     [gem_pgframe], 0

                ;; "EMMXXXX0" at handler_seg:000A
                mov     ax, 3567h               ;; get vector 67h
                int     21h
                mov     ax, es
                test    ax, ax
                jz      @@no

                mov     di, 10
                mov     si, offset gem_name
                mov     cx, 8
                cld
                repe    cmpsb
                jne     @@no

                ;; the driver answers, so ask it for the page frame
                mov     ah, 41h
                int     EMS_INT
                test    ah, ah
                jnz     @@no
                mov     [gem_pgframe], bx

                mov     [gem_present], 1
                mov     ax, 1
                ret

@@no:           xor     ax, ax
                ret
gem_init        endp


;;::::::::::::::
;; gem_frame () -> ax = page frame segment, 0 if none
;;::::::::::::::
gem_frame       proc    public
                mov     ax, [gem_pgframe]
                ret
gem_frame       endp


;;::::::::::::::
;; gem_alloc ( bytes:dword ) -> ax = handle, 0 on failure
;;::::::::::::::
gem_alloc       proc    public uses bx cx dx,\
                        nbytes:dword

                cmp     [gem_present], 0
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
gem_alloc       endp


;;::::::::::::::
;; gem_free ( handle:word )
;;::::::::::::::
gem_free        proc    public uses dx,\
                        hnd:word

                mov     dx, hnd
                test    dx, dx
                jz      @@done
                mov     ah, 45h
                int     EMS_INT
@@done:         ret
gem_free        endp


;;::::::::::::::
;; gem_map ( handle:word, logpage:word, slot:word ) -> ax = segment, 0 on fail
;;
;; Maps one logical page of a handle into one physical page, and hands
;; back the segment it now answers at. The caller owns the slot; nothing
;; here tracks or arbitrates them.
;;::::::::::::::
gem_map         proc    public uses bx cx dx,\
                        hnd:word, logpage:word, slot:word

                mov     dx, hnd
                mov     bx, logpage
                mov     ax, slot
                mov     ah, 44h                 ;; al = physical page
                int     EMS_INT
                test    ah, ah
                jnz     @@fail

                ;; frame + slot*400h -- 16K in paragraphs
                mov     ax, slot
                mov     cl, 10
                shl     ax, cl
                add     ax, [gem_pgframe]
                ret

@@fail:         xor     ax, ax
                ret
gem_map         endp


.data
gem_name        db      "EMMXXXX0"

                end
