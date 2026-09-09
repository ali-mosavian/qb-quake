;; zip.asm -- one member of a ZIP archive, read as if it were a file.
;;
;; name: qglZipOpen / qglZipOpenBas / qglZipSize / qglZipRead /
;;       qglZipClose
;; desc: "archive.zip::member" opens that member; a name with no "::"
;;       opens the file itself. That is the slice of mgl's uar* this
;;       renderer uses -- open, size, read, close, one member at a time,
;;       start to end -- and nothing else of it.
;;
;;       STORED MEMBERS ONLY. mgl's reader carries an inflate and a
;;       window table to drive it; every asset here is written by
;;       tools/mkassets.py, which now stores. A member by any other
;;       method is REFUSED, not read as though it were stored: that is
;;       the one failure this module could otherwise turn into plausible
;;       garbage rather than a missing file.
;;
;; obs.: - the LOCAL headers are walked, not the central directory.
;;         Reaching the directory means scanning backwards for a
;;         signature past a comment of unknown length; walking forward
;;         from byte 0 needs no such guess, and sixteen members is
;;         sixteen seeks, once, at load.
;;       - a handle indexes a table here rather than being the DOS
;;         handle, so a read can be clamped to what is left of the
;;         member. mgl kept that state in a UAR the caller declared and
;;         then only ever passed back; the call sites lose a UDT.
;;       - the name is copied out of the caller's string before it is
;;         cut: the split writes a NUL where the "::" was.

                .model  medium, pascal
                .386

                include qgl.inc

qglFileOpen   proto   far pascal :dword
qglFileSize   proto   far pascal :word
qglFileRead   proto   far pascal :word, :dword, :dword
qglFileClose  proto   far pascal :word
IFDEF __BASIC__
qglFileNameBas proto  far pascal :word, :dword, :word
ENDIF

ZIP_PATH        equ     80              ;; the whole name, archive and member
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

ZipH            struc
                zh_fh           dw      ?       ;; 0 when the slot is free
                zh_left         dd      ?       ;; unread bytes of the member
                zh_size         dd      ?
ZipH            ends

.data
qgl$zip_tb      ZipH    QGL_ZIP_MAX dup (<0, 0, 0>)
qgl$zpath       db      ZIP_PATH dup (0)
qgl$zwant       db      ZIP_NAME dup (0)
qgl$zwlen       dw      0
qgl$zname       db      ZIP_NAME dup (0)
qgl$zhdr        LocHdr  <0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>
qgl$zhdrp       dd      0
qgl$znamep      dd      0
qgl$zpathp      dd      0

.code

;;::::::::::::::
;; qgl$ZipPtrs -- the three far pointers this module hands across a call.
;;
;; INTERNAL: nothing in, nothing out. Filled per open rather than
;; declared as data, because the data segment's paragraph is not known
;; until run time.
;;::::::::::::::
qgl$ZipPtrs     proc    near private uses ax
                mov     ax, ds
                mov     W qgl$zhdrp+2, ax
                mov     W qgl$znamep+2, ax
                mov     W qgl$zpathp+2, ax
                mov     W qgl$zhdrp, offset qgl$zhdr
                mov     W qgl$znamep, offset qgl$zname
                mov     W qgl$zpathp, offset qgl$zpath
                ret
qgl$ZipPtrs     endp


;;::::::::::::::
;; qgl$ZipCopy -- es:si, ASCIIZ, into qgl$zpath, truncated to fit.
;;
;; INTERNAL: everything survives.
;;::::::::::::::
qgl$ZipCopy     proc    near private uses ax cx si di
                mov     di, offset qgl$zpath
                mov     cx, ZIP_PATH-1
@@ch:           mov     al, es:[si]
                test    al, al
                jz      @F
                mov     [di], al
                inc     si
                inc     di
                loop    @@ch
@@:             mov     B [di], 0
                ret
qgl$ZipCopy     endp


;;::::::::::::::
;; qgl$ZipSplit -- cut qgl$zpath at "::".
;;
;; INTERNAL: ax = 1 when a member was named, and qgl$zpath then ends at
;; the archive with qgl$zwant/qgl$zwlen holding the member; 0 when the
;; name is a plain file. Everything else survives.
;;::::::::::::::
qgl$ZipSplit    proc    near private uses bx cx si di
                mov     si, offset qgl$zpath

@@scan:         mov     al, [si]
                test    al, al
                jz      @@plain
                cmp     al, ':'
                jne     @@next
                cmp     B [si+1], ':'
                je      @@found
@@next:         inc     si
                jmp     @@scan

@@plain:        xor     ax, ax
                ret

@@found:        mov     B [si], 0               ;; the archive ends here
                add     si, 2
                mov     di, offset qgl$zwant
                xor     cx, cx
@@cp:           mov     al, [si]
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
                mov     ax, 1
                ret
qgl$ZipSplit    endp


;;::::::::::::::
;; qgl$ZipSkip -- move the file pointer on by a signed dword.
;;
;; INTERNAL: bx = the DOS handle, edx = the distance. CF on failure;
;; every register survives but the high half of edx.
;;::::::::::::::
qgl$ZipSkip     proc    near private uses ax cx dx
                mov     ecx, edx
                shr     ecx, 16
                mov     ax, 4201h               ;; seek from where we are
                int     21h
                ret
qgl$ZipSkip     endp


;;::::::::::::::
;; qgl$ZipFind -- leave the handle positioned at the wanted member's data.
;;
;; INTERNAL: bx = the DOS handle; qgl$zwant and qgl$zwlen name the
;; member. Out: CF clear and edx = its length, or CF set. bx survives.
;;::::::::::::::
qgl$ZipFind     proc    near private uses ax cx si di

@@hdr:          invoke  qglFileRead, bx, qgl$zhdrp, T LocHdr
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
                invoke  qglFileRead, bx, qgl$znamep, ecx
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
                mov     edx, qgl$zhdr.lh_usize
                clc
                ret

@@none:         stc
                ret
qgl$ZipFind     endp


;;::::::::::::::
;; qgl$ZipSlot -- ax = a handle -> bx = its table offset, CF set if that
;; handle is not open.
;;
;; INTERNAL: ax is consumed; everything else survives.
;;::::::::::::::
qgl$ZipSlot     proc    near private
                dec     ax
                cmp     ax, QGL_ZIP_MAX
                jae     @@bad
                imul    bx, ax, T ZipH
                cmp     qgl$zip_tb[bx].zh_fh, 0
                je      @@bad
                clc
                ret
@@bad:          stc
                ret
qgl$ZipSlot     endp


;;::::::::::::::
;; qgl$ZipDo -- open whatever qgl$zpath now names.
;;
;; INTERNAL: ax = a handle, or 0.
;;::::::::::::::
qgl$ZipDo       proc    near private uses bx cx dx si
                local   member:word
                local   fh:word
                local   idx:word
                local   len:dword

                call    qgl$ZipPtrs
                call    qgl$ZipSplit
                mov     member, ax

                ;; a free slot BEFORE the file is opened: nothing to undo
                ;; on that path
                xor     bx, bx
                xor     cx, cx
@@slot:         cmp     qgl$zip_tb[bx].zh_fh, 0
                je      @@got
                add     bx, T ZipH
                inc     cx
                cmp     cx, QGL_ZIP_MAX
                jb      @@slot
                xor     ax, ax
                ret
@@got:          mov     si, bx
                mov     idx, cx

                invoke  qglFileOpen, qgl$zpathp
                test    ax, ax
                jz      @@fail
                mov     fh, ax

                mov     bx, fh
                cmp     member, 0
                jne     @@member

                invoke  qglFileSize, fh         ;; a plain file, all of it
                mov     W len, ax
                mov     W len+2, dx
                jmp     @@keep

@@member:       call    qgl$ZipFind
                jc      @@close
                mov     len, edx

@@keep:         mov     bx, si
                mov     ax, fh
                mov     qgl$zip_tb[bx].zh_fh, ax
                mov     eax, len
                mov     qgl$zip_tb[bx].zh_left, eax
                mov     qgl$zip_tb[bx].zh_size, eax
                mov     ax, idx
                inc     ax                      ;; 0 is "no handle"
                ret

@@close:        invoke  qglFileClose, fh
@@fail:         xor     ax, ax
                ret
qgl$ZipDo       endp


;;::::::::::::::
;; qglZipOpen ( path:far ptr to ASCIIZ ) -> ax = handle, 0 on failure
;;::::::::::::::
qglZipOpen    proc    public uses bx cx dx si di es,\
                        path:dword

                les     si, path
                call    qgl$ZipCopy
                call    qgl$ZipDo
                ret
qglZipOpen    endp


IFDEF __BASIC__
;;::::::::::::::
;; qglZipOpenBas ( s:BASIC string ) -> ax = handle, 0 on failure
;;
;; The string walk stays in file.asm, which is where this layer's one
;; piece of BASIC knowledge lives.
;;::::::::::::::
qglZipOpenBas proc    public uses bx cx dx si di es,\
                        s:word

                call    qgl$ZipPtrs
                invoke  qglFileNameBas, s, qgl$zpathp, ZIP_PATH
                call    qgl$ZipDo
                ret
qglZipOpenBas endp
ENDIF


;;::::::::::::::
;; qglZipSize ( h:word ) -> dx:ax = the member's length, 0 if h is not open
;;::::::::::::::
qglZipSize    proc    public uses bx,\
                        h:word

                mov     ax, h
                call    qgl$ZipSlot
                jc      @@bad
                mov     ax, W qgl$zip_tb[bx].zh_size
                mov     dx, W qgl$zip_tb[bx].zh_size+2
                ret
@@bad:          xor     ax, ax
                xor     dx, dx
                ret
qglZipSize    endp


;;::::::::::::::
;; qglZipRead ( h:word, dst:far ptr, nbytes:dword ) -> dx:ax = bytes read
;;
;; Clamped to what is left of the member. Without that a read past the
;; end of one walks into the next one's header and hands it back as
;; data, which is the whole reason a member is not just a file offset.
;;::::::::::::::
qglZipRead    proc    public uses bx cx,\
                        h:word, dst:dword, nbytes:dword

                mov     ax, h
                call    qgl$ZipSlot
                jc      @@bad

                mov     eax, nbytes
                cmp     eax, qgl$zip_tb[bx].zh_left
                jbe     @F
                mov     eax, qgl$zip_tb[bx].zh_left
@@:             mov     nbytes, eax
                mov     cx, qgl$zip_tb[bx].zh_fh
                push    bx
                invoke  qglFileRead, cx, dst, nbytes
                pop     bx

                movzx   ecx, dx                 ;; what it really gave, 32-bit
                shl     ecx, 16
                mov     cx, ax
                sub     qgl$zip_tb[bx].zh_left, ecx
                ret

@@bad:          xor     ax, ax
                xor     dx, dx
                ret
qglZipRead    endp


;;::::::::::::::
;; qglZipClose ( h:word )
;;::::::::::::::
qglZipClose   proc    public uses bx cx,\
                        h:word

                mov     ax, h
                call    qgl$ZipSlot
                jc      @@out
                mov     cx, qgl$zip_tb[bx].zh_fh
                invoke  qglFileClose, cx
                mov     qgl$zip_tb[bx].zh_fh, 0
                mov     qgl$zip_tb[bx].zh_left, 0
                mov     qgl$zip_tb[bx].zh_size, 0
@@out:          ret
qglZipClose   endp

                end
