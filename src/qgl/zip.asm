;; zip.asm -- the ZIP driver for file.asm: a stored member, found.
;;
;; name: qglZipCheck / qglZipFind
;; desc: One row of FsDrv, registered by being linked (QGL_FSDRV at the
;;       end). check claims a file whose first bytes are a local header;
;;       find walks the local headers to the member named and leaves the
;;       file positioned at its data. The window, the clamped read and
;;       the handle are file.asm's; this module never sees a handle.
;;
;;       STORED MEMBERS ONLY. mgl's reader carries an inflate and a
;;       window table to drive it; every asset here is written by
;;       tools/mkassets.py, which stores. A member by any other method
;;       is REFUSED, not read as though it were stored: that is the one
;;       failure this module could otherwise turn into plausible garbage
;;       rather than a missing file. No write either -- the row's third
;;       entry is 0 -- because nothing here wants to rewrite an asset.
;;
;; obs.: - the LOCAL headers are walked, not the central directory.
;;         Reaching the directory means scanning backwards for a
;;         signature past a comment of unknown length; walking forward
;;         from byte 0 needs no such guess, and sixteen members is
;;         sixteen seeks, once, at load.
;;       - the name compared is capped at ZIP_NAME-1 characters; a
;;         longer one cannot match and its tail is skipped with the
;;         extra field.

                .model  medium, pascal
                .386

                include qgl.inc

qglFileRawRead  proto   far pascal :word, :dword, :dword
qglFileRawSeek  proto   far pascal :word, :word, :dword

ZIP_NAME        equ     48              ;; the longest member name comparable

LOC_SIG         equ     04034B50h       ;; "PK\3\4"
LOC_STORED      equ     0               ;; the only method read here
LOC_DESCR       equ     8               ;; flag bit 3: the sizes are in a trailer

;; PKWARE's local file header, the fixed part
LocHdr          struc
                lh_sig          dd      ?
                lh_ver          dw      ?
                lh_flags        dw      ?
                lh_method       dw      ?
                lh_time         dw      ?
                lh_date         dw      ?
                lh_crc          dd      ?
                lh_csize        dd      ?
                lh_usize        dd      ?
                lh_namelen      dw      ?
                lh_xtralen      dw      ?
LocHdr          ends

.data
qgl$zwant       db      ZIP_NAME dup (0)
qgl$zwlen       dw      0
qgl$zname       db      ZIP_NAME dup (0)
qgl$zhdr        LocHdr  <0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>
qgl$zhdrp       dd      0
qgl$znamep      dd      0

.code

;;::::::::::::::
;; qgl$ZipPtrs -- the far pointers this module hands across a call.
;;
;; INTERNAL: nothing in, nothing out. Filled per call rather than
;; declared as data, because the data segment's paragraph is not known
;; until run time.
;;::::::::::::::
qgl$ZipPtrs     proc    near private uses ax
                mov     ax, ds
                mov     W qgl$zhdrp+2, ax
                mov     W qgl$znamep+2, ax
                mov     W qgl$zhdrp, offset qgl$zhdr
                mov     W qgl$znamep, offset qgl$zname
                ret
qgl$ZipPtrs     endp


;;::::::::::::::
;; qgl$ZipSkip -- move the file on by a signed dword.
;;
;; INTERNAL: bx = the DOS handle, edx = the distance. CF on failure;
;; every register survives.
;;::::::::::::::
qgl$ZipSkip     proc    near private uses ax
                invoke  qglFileRawSeek, bx, 1, edx
                cmp     ax, 1                   ;; CF = (ax == 0)
                ret
qgl$ZipSkip     endp


;;::::::::::::::
;; qglZipCheck ( fh:DOS handle ) -> ax = 1 when the file starts with a
;; local header. The file is left rewound either way.
;;::::::::::::::
qglZipCheck   proc    public uses bx cx dx si di,\
                        fh:word

                call    qgl$ZipPtrs
                invoke  qglFileRawRead, fh, qgl$zhdrp, 4
                push    ax
                invoke  qglFileRawSeek, fh, 0, 0
                pop     ax
                cmp     ax, 4
                jne     @@no
                cmp     D qgl$zhdr.lh_sig, LOC_SIG
                jne     @@no
                mov     ax, 1
                ret
@@no:           xor     ax, ax
                ret
qglZipCheck   endp


;;::::::::::::::
;; qglZipFind ( fh:DOS handle, name:far ptr ASCIIZ, sizep:far ptr dword )
;;   -> ax = 1 and the file positioned at the member's data, its length
;;      stored through sizep; 0 when there is no such stored member.
;;::::::::::::::
qglZipFind    proc    public uses bx cx dx si di es,\
                        fh:word, member:dword, sizep:dword

                call    qgl$ZipPtrs

                ;; the wanted name, capped
                les     si, member
                mov     di, offset qgl$zwant
                xor     cx, cx
@@cp:           mov     al, es:[si]
                test    al, al
                jz      @@cpd
                cmp     cx, ZIP_NAME-1
                jae     @@cpd
                mov     [di], al
                inc     si
                inc     di
                inc     cx
                jmp     @@cp
@@cpd:          mov     B [di], 0
                mov     qgl$zwlen, cx

                mov     bx, fh
@@hdr:          invoke  qglFileRawRead, bx, qgl$zhdrp, T LocHdr
                cmp     ax, T LocHdr
                jne     @@none                  ;; short: past the last member
                cmp     D qgl$zhdr.lh_sig, LOC_SIG
                jne     @@none                  ;; the central directory

                ;; the name, capped. A longer one cannot match, and its
                ;; tail is skipped with the extra field below.
                mov     cx, qgl$zhdr.lh_namelen
                cmp     cx, ZIP_NAME-1
                jbe     @F
                mov     cx, ZIP_NAME-1
@@:             movzx   ecx, cx
                push    ecx
                invoke  qglFileRawRead, bx, qgl$znamep, ecx
                pop     ecx
                cmp     ax, cx
                jne     @@none

                mov     dx, qgl$zhdr.lh_namelen
                sub     dx, cx
                add     dx, qgl$zhdr.lh_xtralen
                movzx   edx, dx
                call    qgl$ZipSkip
                jc      @@none

                cmp     cx, qgl$zwlen
                jne     @@skip
                cmp     cx, qgl$zhdr.lh_namelen
                jne     @@skip                  ;; it was truncated: no match
                mov     si, offset qgl$zname
                mov     di, offset qgl$zwant
@@cmp:          jcxz    @@hit
                mov     al, [si]
                cmp     al, [di]
                jne     @@skip
                inc     si
                inc     di
                dec     cx
                jmp     @@cmp

@@skip:         mov     edx, qgl$zhdr.lh_csize
                call    qgl$ZipSkip
                jc      @@none
                jmp     @@hdr

                ;; Stored only, and tested HERE rather than at the top of
                ;; the loop, so an archive that merely contains a
                ;; compressed member still yields the stored ones.
@@hit:          cmp     qgl$zhdr.lh_method, LOC_STORED
                jne     @@none
                test    qgl$zhdr.lh_flags, LOC_DESCR
                jnz     @@none                  ;; the sizes are not here
                les     di, sizep
                mov     eax, qgl$zhdr.lh_usize
                mov     es:[di], eax
                mov     ax, 1
                ret

@@none:         xor     ax, ax
                ret
qglZipFind    endp

                QGL_FSDRV qglZipCheck, qglZipFind, 0

                end
