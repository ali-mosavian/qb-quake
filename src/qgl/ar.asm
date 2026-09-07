;; ar.asm -- paged array stores: capacity, mapping, and access semantics.
;;
;; name: qglArNew / qglArMap / qglArFree / qglArPerpg /
;;       qglArPages
;; desc: A store holds one flat array of fixed-size records somewhere
;;       that is not BASIC's far heap, and rewrites a dynamic array's
;;       descriptor to point at it so ordinary subscripting reaches it.
;;
;;       This replaces the narrow slice of mgl's uglArr* that qb-qrender
;;       actually uses -- uglArrLoad and uglArrMap, and nothing else --
;;       for two reasons that are defects, not preferences:
;;
;;       UA_MAX is 4 and all four are taken by leaves, faces, nodes and
;;       clip. d_mdl.bas records the model vertices asking for a fifth,
;;       being refused, and falling back to raw emsAlloc/emsMapEx. The
;;       table here is 8, sized from the callers that exist plus the one
;;       that was turned away.
;;
;;       And an EMS store is windowed at 16,384 bytes while every caller
;;       maps it ONCE, at index 0. Past the first window the descriptor
;;       names a page that is no longer mapped, and the read succeeds
;;       with wrong data. q_map.bi:223 states the contract -- "Every
;;       nds_buffer(i) must be preceded by uglArrMap for that i" -- and
;;       the traversal does not keep it. -qglarr fails on exactly the
;;       boundary element, 16384\elsz, and passes below it.
;;
;; obs.: - MEM keeps the flat bind: perpg = cnt, one window, one map,
;;         and no per-access cost. That is the hot production path and
;;         it is not made slower to fix a bug in the fallback.
;;       - EMS remaps when the requested index leaves the current page.
;;         emsMapEx consults the EMS layer's own record of what a slot
;;         holds, so a request for the page already there costs a
;;         compare and not an INT 67h.
;;       - Only a DYNAMIC array can be bound. BC bakes a STATIC array's
;;         address into the instruction stream, so repointing its
;;         descriptor changes nothing. redim then erase is required.
;;

                .model  medium, pascal
                .386

                include qgl.inc

;; the QuickBASIC array descriptor, from the runtime
AD_ODATA        equ     0
AD_HDATA        equ     2
AD_FFEAT        equ     9               ;; byte: 1 far, 64 static, 128 string
AD_OADJ         equ     10
AD_CBELEM       equ     12
AD_CELEM        equ     14

QAr             struc
                ar_typ          dw      ?
                ar_hnd          dw      ?       ;; EMS handle, or MEM segment
                ar_ofs          dw      ?       ;; MEM offset within it
                ar_elsz         dw      ?
                ar_cnt          dd      ?
                ar_slot         dw      ?
                ar_adesc        dw      ?
                ar_adj0         dw      ?
                ar_curpg        dw      ?       ;; -1 when nothing is mapped
                ar_perpg        dw      ?
                ar_used         dw      ?
QAr             ends

.data
qgl$ar_tb       QAr     QGL_AR_MAX dup (<>)

                qglArMap      proto   far pascal :dword, :word, :dword
                qglMemAlloc   proto   far pascal :dword
                qglMemFree    proto   far pascal :dword
                emsAlloc        proto   far pascal :dword
                emsFree         proto   far pascal :word
                emsMapEx        proto   far pascal :word, :word, :word

.code

;;::::::::::::::
;; handle in ax -> si points at its entry, carry set if the handle is
;; not a live store. Handles are index+1 so that 0 is never valid.
;;::::::::::::::
qgl$ArSlot     proc    near private
                dec     ax
                cmp     ax, QGL_AR_MAX
                jae     @@bad
                mov     si, ax
                imul    si, T QAr
                add     si, O qgl$ar_tb
                cmp     [si].QAr.ar_used, 0
                je      @@bad
                clc
                ret
@@bad:          stc
                ret
qgl$ArSlot     endp


;;::::::::::::::
;; qglArNew ( typ:word, elsz:word, cnt:dword, slot:word ) -> dx:ax
;;
;; dx:ax is the handle, 0 on failure. MEM takes a DOS block; EMS takes
;; whole 16K pages and the caller's slot.
;;::::::::::::::
qglArNew      proc    public uses bx cx si di,\
                        typ:word, elsz:word, cnt:dword, slot:word

                local   nbytes:dword, h:word

                xor     ax, ax
                xor     dx, dx

                cmp     elsz, 0
                je      @@no
                cmp     elsz, QGL_AR_WIN
                ja      @@no                    ;; a record wider than a page
                mov     eax, cnt
                test    eax, eax
                jz      @@no

                ;; a free entry
                xor     bx, bx
                mov     si, O qgl$ar_tb
@@find:         cmp     [si].QAr.ar_used, 0
                je      @@got
                add     si, T QAr
                inc     bx
                cmp     bx, QGL_AR_MAX
                jb      @@find
                jmp     @@no                    ;; every store is in use
@@got:          inc     bx
                mov     h, bx                   ;; the handle, index+1

                ;; bytes = cnt * elsz, and it must stay under 4G
                mov     eax, cnt
                movzx   ecx, elsz
                mul     ecx
                test    edx, edx
                jnz     @@no
                mov     nbytes, eax

                mov     ax, typ
                mov     [si].QAr.ar_typ, ax
                mov     ax, elsz
                mov     [si].QAr.ar_elsz, ax
                mov     eax, cnt
                mov     [si].QAr.ar_cnt, eax
                mov     ax, slot
                mov     [si].QAr.ar_slot, ax
                mov     [si].QAr.ar_adesc, 0
                mov     [si].QAr.ar_adj0, 0
                mov     [si].QAr.ar_curpg, -1
                mov     [si].QAr.ar_ofs, 0

                cmp     typ, QGL_AR_EMS
                je      @@ems

                ;; MEM is ONE window: perpg = cnt, so every index lands
                ;; on page 0 and the single bind covers the array. That
                ;; is what keeps the hot path free of per-access work.
                mov     eax, cnt
                cmp     eax, 0FFFFh
                ja      @@no                    ;; perpg is a word
                mov     [si].QAr.ar_perpg, ax

                push    si
                invoke  qglMemAlloc, nbytes
                pop     si
                test    dx, dx
                jz      @@no                    ;; a null segment is failure
                mov     [si].QAr.ar_hnd, dx
                mov     [si].QAr.ar_ofs, ax
                jmp     @@live

@@ems:          ;; elements per page, FLOORED: a record never straddles a
                ;; page, so the page end is padded instead.
                mov     ax, QGL_AR_WIN
                xor     dx, dx
                div     elsz
                test    ax, ax
                jz      @@no
                mov     [si].QAr.ar_perpg, ax

                ;; BYTES, not pages. emsAlloc takes a byte count and
                ;; rounds it up to page granularity itself -- handing it
                ;; ceil(nbytes/16384) allocated 2 bytes for a 22,926-byte
                ;; fixture, one page, and the remap to page 1 then failed
                ;; in a way indistinguishable from the paging bug this
                ;; module exists to fix.
                push    si
                invoke  emsAlloc, nbytes
                pop     si
                test    ax, ax                  ;; handle in ax, 0 on failure
                jz      @@no
                mov     [si].QAr.ar_hnd, ax

@@live:         mov     [si].QAr.ar_used, 1
                mov     ax, h
                xor     dx, dx
                ret

@@no:           xor     ax, ax
                xor     dx, dx
                ret
qglArNew      endp


;;::::::::::::::
;; qglArMap ( h:dword, adesc:word, idx:dword ) -> dx:ax
;;
;; THE accessor. Maps the page holding idx, binds the descriptor to that
;; window if one was given, and returns a far pointer to the element
;; itself. adesc 0 means "window only, do not bind" -- which is what a
;; loader wants while it is streaming pages in.
;;
;; For EMS this is what every read past the first window needs. Calling
;; it once at index 0 and then subscripting freely is the bug -qglarr
;; reproduces.
;;::::::::::::::
qglArMap      proc    public uses bx cx si di,\
                        h:dword, adesc:word, idx:dword

                local   pg:word, pbase:dword, wseg:word, woff:word

                mov     ax, W h
                call    qgl$ArSlot
                jc      @@no

                ;; idx < cnt
                mov     eax, idx
                cmp     eax, [si].QAr.ar_cnt
                jae     @@no

                ;; pg = idx \ perpg, pbase = pg * perpg
                movzx   ecx, [si].QAr.ar_perpg
                xor     edx, edx
                div     ecx                     ;; eax = pg, edx = within
                mov     pg, ax
                mul     ecx                     ;; eax = pg * perpg
                mov     pbase, eax

                cmp     [si].QAr.ar_typ, QGL_AR_EMS
                je      @@ems

                ;; MEM: one flat window, always page 0
                mov     ax, [si].QAr.ar_hnd
                mov     wseg, ax
                mov     ax, [si].QAr.ar_ofs
                mov     woff, ax
                jmp     @@bind

@@ems:          ;; Remap ONLY when the page actually changes. emsMapEx
                ;; checks the slot's own record first, so this is a
                ;; compare and not an INT 67h when it is already there --
                ;; but skipping the call entirely on a curpg match is
                ;; what makes a sequential walk cost nothing extra.
                mov     ax, pg
                cmp     ax, [si].QAr.ar_curpg
                je      @@ems_here
                push    si
                invoke  emsMapEx, [si].QAr.ar_hnd, pg, [si].QAr.ar_slot
                pop     si
                test    ax, ax
                jz      @@no
                mov     wseg, ax
                mov     cx, pg
                mov     [si].QAr.ar_curpg, cx
                jmp     @@ems_off

@@ems_here:     ;; the page is ours already, but another store sharing
                ;; the slot may have taken the window since. Ask again;
                ;; it is a compare inside the EMS layer when it agrees.
                push    si
                invoke  emsMapEx, [si].QAr.ar_hnd, pg, [si].QAr.ar_slot
                pop     si
                test    ax, ax
                jz      @@no
                mov     wseg, ax

@@ems_off:      mov     woff, 0

@@bind:         mov     di, adesc
                test    di, di
                jz      @@ptr                   ;; window only

                cmp     [si].QAr.ar_adesc, di
                je      @@rebind
                mov     [si].QAr.ar_adesc, di
                ;; the lower-bound term the compiler folded in, taken
                ;; while it is still the compiler's
                mov     ax, ss:[di+AD_OADJ]
                sub     ax, ss:[di+AD_ODATA]
                mov     [si].QAr.ar_adj0, ax

@@rebind:       mov     eax, [si].QAr.ar_cnt
                mov     ss:[di+AD_CELEM], ax
                mov     ax, [si].QAr.ar_elsz
                mov     ss:[di+AD_CBELEM], ax
                ;; exactly 1: clears STATIC (64) and STRING (128) too
                mov     B ss:[di+AD_FFEAT], 1

                mov     ax, woff
                mov     ss:[di+AD_ODATA], ax
                mov     cx, wseg
                mov     ss:[di+AD_HDATA], cx

                ;; oAdj = window + adj0 - pbase*elsz, so the caller keeps
                ;; indexing globally while the window is local
                mov     eax, pbase
                movzx   ecx, [si].QAr.ar_elsz
                mul     ecx
                mov     cx, ax
                mov     ax, woff
                add     ax, [si].QAr.ar_adj0
                sub     ax, cx
                mov     ss:[di+AD_OADJ], ax

@@ptr:          ;; the element's own far pointer
                mov     eax, idx
                sub     eax, pbase
                movzx   ecx, [si].QAr.ar_elsz
                mul     ecx
                add     ax, woff
                mov     dx, wseg
                ret

@@no:           xor     ax, ax
                xor     dx, dx
                ret
qglArMap      endp


;;::::::::::::::
;; qglArWin ( h:dword, idx:dword ) -> dx:ax
;;
;; The window holding idx, with NO descriptor binding. A loader wants
;; somewhere to put bytes, not an array it can subscript, and BASIC
;; cannot pass 0 where a declare says a() -- hence a named entry rather
;; than an alias with a null argument.
;;::::::::::::::
qglArWin      proc    public,\
                        h:dword, idx:dword
                invoke  qglArMap, h, 0, idx
                ret
qglArWin      endp


;;::::::::::::::
;; qglArHandle ( h:dword ) -> ax, the EMS handle (or MEM segment)
;;
;; So a loader can address the store's pages WITHOUT going through
;; qglArMap. A test whose write path and read path share the mapping
;; arithmetic cannot detect a fault in it: pinning the page to 0 moved
;; the loader and the reader together and the round trip still agreed.
;;::::::::::::::
qglArHandle   proc    public uses si,\
                        h:dword
                mov     ax, W h
                call    qgl$ArSlot
                jc      @@no
                mov     ax, [si].QAr.ar_hnd
                ret
@@no:           xor     ax, ax
                ret
qglArHandle   endp


;;:::::::::::::: qglArPerpg ( h:dword ) -> ax, 0 if the handle is dead
qglArPerpg    proc    public uses si,\
                        h:dword
                mov     ax, W h
                call    qgl$ArSlot
                jc      @@no
                mov     ax, [si].QAr.ar_perpg
                ret
@@no:           xor     ax, ax
                ret
qglArPerpg    endp


;;:::::::::::::: qglArPages ( h:dword ) -> ax, ceil(cnt/perpg)
qglArPages    proc    public uses bx cx dx si,\
                        h:dword
                mov     ax, W h
                call    qgl$ArSlot
                jc      @@no
                movzx   ecx, [si].QAr.ar_perpg
                mov     eax, [si].QAr.ar_cnt
                add     eax, ecx
                dec     eax
                xor     edx, edx
                div     ecx
                ret
@@no:           xor     ax, ax
                ret
qglArPages    endp


;;:::::::::::::: qglArFree ( h:dword )
qglArFree     proc    public uses bx cx dx si di,\
                        h:dword

                local   blk:dword

                mov     ax, W h
                call    qgl$ArSlot
                jc      @@done

                ;; DETACH FIRST. The bound descriptor still names memory
                ;; that is about to stop being ours, and BASIC will walk
                ;; it: a later ERASE hands B$FHDealloc a pointer into
                ;; memory it never owned, and heap compaction moves it --
                ;; "Far heap corrupt", printed after the run has otherwise
                ;; finished. Zeroed, ERASE returns at once.
                ;;
                ;; ar_adesc is 0 when a store was created and freed with
                ;; nothing ever bound to it -- creating and binding are
                ;; separate calls -- and writing through it then would
                ;; zero whatever sits at DGROUP:0000.
                mov     di, [si].QAr.ar_adesc
                test    di, di
                jz      @@nodesc
                mov     W ss:[di+AD_HDATA], 0
                mov     W ss:[di+AD_ODATA], 0
                mov     W ss:[di+AD_OADJ], 0

@@nodesc:       cmp     [si].QAr.ar_typ, QGL_AR_EMS
                jne     @@mem
                push    si
                invoke  emsFree, [si].QAr.ar_hnd
                pop     si
                jmp     @@clear

@@mem:          ;; the block as one dword, seg:off, the way qglMemFree
                ;; takes it
                mov     dx, [si].QAr.ar_hnd
                mov     ax, [si].QAr.ar_ofs
                mov     W blk, ax
                mov     W blk+2, dx
                push    si
                invoke  qglMemFree, blk
                pop     si

@@clear:        mov     [si].QAr.ar_used, 0
                mov     [si].QAr.ar_adesc, 0
                mov     [si].QAr.ar_curpg, -1
@@done:         ret
qglArFree     endp

                end
