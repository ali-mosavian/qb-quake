;; ar.asm -- paged array stores: capacity, mapping, and access semantics.
;;
;; name: qglArNew / qglArLoad / qglArMap / qglArFree / qglArPerpg /
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
;;       - EMS asks qglGemMap for the page on every access. gem keeps
;;         the record of what a slot holds, so the page already there
;;         costs a compare and not an INT 67h -- and a store's own
;;         record would be wrong the moment another store sharing the
;;         slot took the window.
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
                ar_perpg        dw      ?
                ar_used         dw      ?
QAr             ends

.data
qgl$ar_tb       QAr     QGL_AR_MAX dup (<>)

IFDEF __BASIC__
;; Module-private and reused per call: the store outlives the name, the
;; name does not need to outlive the load. Same size as zip.asm's, which
;; is what will parse it.
AR_PATH         equ     80
qgl$ar_path     db      AR_PATH dup (0)
ENDIF

                qglArMap      proto   far pascal :dword, :word, :dword
                qglMemAlloc   proto   far pascal :dword
                qglMemFree    proto   far pascal :dword
                qglGemAlloc     proto   far pascal :dword
                qglGemFree      proto   far pascal :word
                qglGemMap       proto   far pascal :word, :word, :word
                qglFileOpen     proto   far pascal :dword
                qglFileRead     proto   far pascal :word, :dword, :dword
                qglFileClose    proto   far pascal :word
IFDEF __BASIC__
                qglFileNameBas  proto   far pascal :word, :dword, :word
ENDIF

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

                ;; BYTES, not pages. qglGemAlloc takes a byte count and
                ;; rounds it up to page granularity itself -- handing it
                ;; ceil(nbytes/16384) allocated 2 bytes for a 22,926-byte
                ;; fixture, one page, and the remap to page 1 then failed
                ;; in a way indistinguishable from the paging bug this
                ;; module exists to fix.
                push    si
                invoke  qglGemAlloc, nbytes
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

@@ems:          ;; Ask every time. Another store sharing the slot may
                ;; have taken the window since; gem's record says, and
                ;; it is a compare and not an INT 67h when the page is
                ;; still there.
                push    si
                invoke  qglGemMap, [si].QAr.ar_hnd, pg, [si].QAr.ar_slot
                pop     si
                test    ax, ax
                jz      @@no
                mov     wseg, ax
                mov     woff, 0

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
                invoke  qglGemFree, [si].QAr.ar_hnd
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
@@done:         ret
qglArFree     endp


;;::::::::::::::
;; qglArLoad ( path:dword, typ:word, elsz:word, cnt:dword, slot:word )
;;      -> dx:ax, a live store, or 0
;;
;; uglArrLoad's job: make the store, then stream the archive member into
;; it one WINDOW at a time, so the array is never resident whole. That is
;; the whole reason a store exists rather than a read into a BASIC array.
;;
;; A page carries perpg*elsz bytes and NOT QGL_AR_WIN. 16384\elsz floors
;; -- 2730 six-byte records is 16,380 -- and the four bytes left over are
;; padding the store keeps so no record straddles a page. Read a whole
;; window per page and the record on the seam is split and every later
;; one shifts, which reads exactly like a mapping fault and is not one.
;;
;; Through qglArWin deliberately: production streams in through the same
;; accessor it will read back through. -qglarr maps by hand for the
;; opposite reason -- a test that shares the arithmetic cannot see a
;; fault in it.
;;::::::::::::::
qglArLoad     proc    public uses bx cx si di,\
                        path:dword, typ:word, elsz:word, cnt:dword, slot:word

                local   h:dword, u:word, perpg:word
                local   payload:dword, remain:dword, idx:dword
                local   want:dword, p:dword

                invoke  qglArNew, typ, elsz, cnt, slot
                mov     W h+0, ax
                mov     W h+2, dx
                or      ax, dx
                jz      @@no

                invoke  qglFileOpen, path
                mov     u, ax
                test    ax, ax
                jz      @@kill

                invoke  qglArPerpg, h
                mov     perpg, ax
                test    ax, ax
                jz      @@shut

                movzx   eax, perpg
                movzx   ecx, elsz
                mul     ecx
                mov     payload, eax

                mov     eax, cnt
                movzx   ecx, elsz
                mul     ecx
                mov     remain, eax

                mov     idx, 0

@@page:         cmp     remain, 0
                je      @@done

                invoke  qglArWin, h, idx
                mov     W p+0, ax               ;; BEFORE the null test: `or
                mov     W p+2, dx               ;; ax, dx` first made the
                or      ax, dx                  ;; offset 0|seg and every
                jz      @@shut                  ;; read landed seg bytes in

                mov     eax, payload
                cmp     eax, remain
                jbe     @F
                mov     eax, remain
@@:             mov     want, eax

                invoke  qglFileRead, u, p, want
                cmp     ax, W want+0
                jne     @@shut
                cmp     dx, W want+2
                jne     @@shut                  ;; short read: the member is
                                                ;; not the size cnt claims

                mov     eax, remain
                sub     eax, want
                mov     remain, eax
                movzx   eax, perpg
                add     eax, idx
                mov     idx, eax
                jmp     @@page

@@done:         invoke  qglFileClose, u
                mov     ax, W h+0
                mov     dx, W h+2
                ret

@@shut:         invoke  qglFileClose, u
@@kill:         invoke  qglArFree, h
@@no:           xor     ax, ax
                xor     dx, dx
                ret
qglArLoad     endp


IFDEF __BASIC__
;;::::::::::::::
;; qglArLoadBas ( s:BASIC string, typ, elsz, cnt, slot ) -> dx:ax
;;::::::::::::::
qglArLoadBas  proc    public uses bx cx si di,\
                        s:word, typ:word, elsz:word, cnt:dword, slot:word

                local   pathp:dword

                mov     W pathp+0, O qgl$ar_path
                mov     W pathp+2, ds
                invoke  qglFileNameBas, s, pathp, AR_PATH
                test    ax, ax
                jz      @@no

                invoke  qglArLoad, pathp, typ, elsz, cnt, slot
                ret

@@no:           xor     ax, ax
                xor     dx, dx
                ret
qglArLoadBas  endp
ENDIF

                end
