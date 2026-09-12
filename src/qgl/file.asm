;; file.asm -- the file layer: one name space, one kind of handle, any
;;             container a linked driver knows.
;;
;; name: qglFileOpen / qglFileOpenBas / qglFileNameBas / qglFileSize /
;;       qglFileRead / qglFileWrite / qglFileClose / qglFileDrivers,
;;       and beneath them qglFileRawRead / qglFileRawWrite /
;;       qglFileRawSeek / qglFileRawSize, for drivers
;; desc: "name" opens a file; "archive::member" opens a member of it as
;;       if it were a file. A handle indexes a table here -- a window on
;;       a DOS file -- so a read is clamped to the member and never walks
;;       into the next one's header, and a caller holds an integer
;;       rather than mgl's UAR it declared only to pass back.
;;
;;       Which containers exist is not this module's business. A driver
;;       is one row of FsDrv (qgl.inc): check claims an open file by
;;       its header, find turns a member name into a position and a
;;       size, write is 0 where the format cannot. mgl's UARDRV table
;;       held those rows; here there is no table to keep, because a
;;       driver registers BY BEING LINKED. QGL_FSDRV puts its row in
;;       segment QGLFS$M, this module brackets that segment with
;;       QGLFS$A and QGLFS$Z, and every open walks the bracket. Nothing
;;       runs at startup and nothing has to be told.
;;
;;       The one contract: file.obj links BEFORE every driver. MS LINK
;;       lays a class out in the order it meets its segments, so a
;;       driver met first puts its row in front of the bracket, unseen
;;       -- checked in QRENDER.MAP, zip.obj first: QGLFS$M at 47E26,
;;       QGLFS$A at 47E32. jwlink sorts the class by name and does not
;;       care. Both Makefiles list file first; qglFileDrivers says how
;;       many rows the walk finds, and t05file asserts the number.
;;
;;       It is also where the ONE piece of BASIC knowledge in the layer
;;       lives. A BASIC string is not a pointer to characters: under
;;       VBDOS's far strings the parameter is a NEAR pointer to a
;;       descriptor in ss, whose seg_tb and ofs_tb chase through two more
;;       indirections to an FSTRG, which is LENGTH-PREFIXED and carries
;;       no terminator (mgl's lang.inc STRGET does the same walk). DOS
;;       wants ASCIIZ. Something has to bridge that, once, here.
;;
;; obs.: - two entry points rather than one that guesses: qglFileOpen
;;         takes a far pointer to ASCIIZ and exists in every build;
;;         qglFileOpenBas takes a BASIC string and exists only under
;;         __BASIC__. A C or asm caller is unaffected by BASIC's string
;;         representation, and the test suite links without it.
;;       - a plain file opens read/write when DOS allows it and read-only
;;         when it does not, so qglFileWrite works on a file and is
;;         refused on a member of a format whose driver cannot.
;;       - the path buffer is module-private and reused per call. A
;;         handle outlives it; the name does not need to.

                .model  medium, pascal
                .386

                include qgl.inc

PATH_MAX        equ     80

;; the raw layer sits below the handles in this file and above them in
;; the listing, so the assembler is told first
qglFileRawRead  proto   far pascal :word, :dword, :dword
qglFileRawWrite proto   far pascal :word, :dword, :dword
qglFileRawSeek  proto   far pascal :word, :word, :dword
qglFileRawSize  proto   far pascal :word

IFDEF __BASIC__
;; VBDOS far strings, as mgl's lang.inc describes them.
BasStr          struc
ofs_tb          dw      ?               ;; -> the string's offset
seg_tb          dw      ?               ;; -> the string's segment
BasStr          ends

FStrg           struc
slen            dw      ?
sdat            db      ?
FStrg           ends
ENDIF

;; an open handle: a window on a DOS file
FileH           struc
                fh_dos          dw      ?       ;; 0 when the slot is free
                fh_row          dd      ?       ;; the driver's row, 0 for a plain file
                fh_left         dd      ?       ;; unread bytes of the window
                fh_size         dd      ?
FileH           ends

;; the bracket the drivers' rows land between -- see the header
QGLFS$A         segment word public 'QGLFS'
qgl$fs_begin    label   byte
QGLFS$A         ends
QGLFS$M         segment word public 'QGLFS'
QGLFS$M         ends
QGLFS$Z         segment word public 'QGLFS'
qgl$fs_end      label   byte
QGLFS$Z         ends
QGLFS           group   QGLFS$A, QGLFS$M, QGLFS$Z


.data
qgl$path        db      PATH_MAX dup (0)
qgl$file_tb     FileH   QGL_FILE_MAX dup (<0, 0, 0, 0>)


.code

;;::::::::::::::
;; qgl$Asciiz -- copy a NUL-terminated path into the module's buffer.
;;
;; INTERNAL: es:si -> the source. dx = the buffer's offset in DGROUP.
;; Everything else survives.
;;::::::::::::::
qgl$Asciiz      proc    near private uses ax cx si di ds es

                push    es
                pop     ds                      ;; ds:si = the source
                mov     ax, @data
                mov     es, ax                  ;; es:di = our buffer
                mov     di, offset qgl$path
                mov     cx, PATH_MAX-1

                cld
@@ch:           lodsb
                test    al, al
                jz      @F
                stosb
                loop    @@ch
@@:             xor     al, al
                stosb

                mov     dx, offset qgl$path
                ret
qgl$Asciiz      endp


;;::::::::::::::
;; qgl$Split -- cut qgl$path at "::".
;;
;; INTERNAL: ax = the member name's offset in DGROUP, and qgl$path then
;; ends at the archive; 0 when the name is a plain file. Everything else
;; survives.
;;::::::::::::::
qgl$Split       proc    near private uses si
                mov     si, offset qgl$path
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
                lea     ax, [si+2]
                ret
qgl$Split       endp


;;::::::::::::::
;; qgl$Slot -- ax = a handle -> bx = its table offset, CF set if that
;; handle is not open.
;;
;; INTERNAL: ax is consumed; everything else survives.
;;::::::::::::::
qgl$Slot        proc    near private
                dec     ax
                cmp     ax, QGL_FILE_MAX
                jae     @@bad
                imul    bx, ax, T FileH
                cmp     qgl$file_tb[bx].fh_dos, 0
                je      @@bad
                clc
                ret
@@bad:          stc
                ret
qgl$Slot        endp


;;::::::::::::::
;; qgl$Open -- open whatever qgl$path now names.
;;
;; INTERNAL: ax = a handle, or 0.
;;::::::::::::::
qgl$Open        proc    near private uses bx cx dx si di es
                local   member:word
                local   fh:word
                local   idx:word
                local   len:dword
                local   namep:dword, sizep:dword, row:dword

                ;; a free slot BEFORE the file is opened: nothing to undo
                ;; on that path
                xor     bx, bx
                xor     cx, cx
@@slot:         cmp     qgl$file_tb[bx].fh_dos, 0
                je      @@got
                add     bx, T FileH
                inc     cx
                cmp     cx, QGL_FILE_MAX
                jb      @@slot
                xor     ax, ax
                ret
@@got:          mov     idx, cx
                mov     row, 0

                call    qgl$Split
                mov     member, ax

                ;; read/write if DOS allows, read-only if not
                mov     dx, offset qgl$path
                mov     ax, 3D02h
                int     21h
                jnc     @@opened
                mov     ax, 3D00h
                int     21h
                jc      @@fail
@@opened:       mov     fh, ax

                cmp     member, 0
                jne     @@member
                invoke  qglFileRawSize, fh      ;; a plain file, all of it
                mov     W len, ax
                mov     W len+2, dx
                jmp     @@keep

@@member:       ;; the first driver whose check claims the file finds
                ;; the member, or the open fails: a second driver does
                ;; not get to disagree with the header
                mov     ax, member
                mov     W namep, ax
                mov     W namep+2, ds
                lea     ax, len
                mov     W sizep, ax
                mov     W sizep+2, ss

                mov     ax, QGLFS
                mov     es, ax
                mov     si, offset QGLFS:qgl$fs_begin
@@drv:          cmp     si, offset QGLFS:qgl$fs_end
                jae     @@close                 ;; no driver claims it
                push    fh
                call    D es:[si].FsDrv.fs_check
                test    ax, ax
                jnz     @@claimed
                add     si, T FsDrv
                jmp     @@drv

@@claimed:      mov     W row, si
                mov     W row+2, es
                push    fh
                push    W namep+2
                push    W namep
                push    W sizep+2
                push    W sizep
                call    D es:[si].FsDrv.fs_find
                test    ax, ax
                jz      @@close

@@keep:         mov     bx, idx
                imul    bx, T FileH
                mov     ax, fh
                mov     qgl$file_tb[bx].fh_dos, ax
                mov     eax, row
                mov     qgl$file_tb[bx].fh_row, eax
                mov     eax, len
                mov     qgl$file_tb[bx].fh_left, eax
                mov     qgl$file_tb[bx].fh_size, eax
                mov     ax, idx
                inc     ax                      ;; 0 is "no handle"
                ret

@@close:        mov     bx, fh
                mov     ah, 3Eh
                int     21h
@@fail:         xor     ax, ax
                ret
qgl$Open        endp


;;::::::::::::::
;; qglFileOpen ( path:far ptr to ASCIIZ ) -> ax = handle, 0 on failure
;;::::::::::::::
qglFileOpen   proc    public uses bx cx dx si di es,\
                        path:dword

                les     si, path
                call    qgl$Asciiz
                call    qgl$Open
                ret
qglFileOpen   endp


IFDEF __BASIC__
;;::::::::::::::
;; qglFileNameBas ( s:BASIC string, dst:far ptr, cap:word ) -> ax = length
;;
;; The walk itself, without the open on the end of it: ar.asm keeps a
;; name of its own to hand back here later, and this layer's one piece
;; of BASIC knowledge stays in one place.
;;
;; The result is ASCIIZ and truncated to cap-1 characters.
;;::::::::::::::
qglFileNameBas proc  public uses bx cx dx si di ds es,\
                        s:word, dst:dword, cap:word

                mov     si, s                   ;; ss:si -> BasStr
                mov     ax, ss:[si].BasStr.seg_tb
                mov     bx, ss:[si].BasStr.ofs_tb
                mov     si, ax
                mov     ax, ss:[si]             ;; the string's segment
                mov     si, bx
                mov     ds, ax
                mov     si, ds:[si]             ;; the string's offset

                mov     cx, ds:[si].FStrg.slen
                mov     dx, cap
                dec     dx
                cmp     cx, dx
                jbe     @F
                mov     cx, dx
@@:             add     si, FStrg.sdat          ;; ds:si -> the characters

                les     di, dst
                push    cx
                jcxz    @F
                cld
                rep     movsb
@@:             xor     al, al
                stosb
                pop     ax
                ret
qglFileNameBas endp


;;::::::::::::::
;; qglFileOpenBas ( s:BASIC string ) -> ax = handle, 0 on failure
;;
;; The parameter is a near pointer to a descriptor in ss, not a pointer
;; to characters. See this module's header for the walk; the short of it
;; is that the data is length-prefixed and has no terminator, so it is
;; copied out and terminated first.
;;::::::::::::::
qglFileOpenBas proc  public uses bx cx dx si di es,\
                        s:word

                local   pathp:dword

                mov     ax, ds
                mov     W pathp+2, ax
                mov     W pathp, offset qgl$path
                invoke  qglFileNameBas, s, pathp, PATH_MAX
                call    qgl$Open
                ret
qglFileOpenBas endp
ENDIF


;;::::::::::::::
;; qglFileSize ( h:word ) -> dx:ax = the window's length, 0 if h is not open
;;::::::::::::::
qglFileSize   proc    public uses bx,\
                        h:word

                mov     ax, h
                call    qgl$Slot
                jc      @@bad
                mov     ax, W qgl$file_tb[bx].fh_size
                mov     dx, W qgl$file_tb[bx].fh_size+2
                ret
@@bad:          xor     ax, ax
                xor     dx, dx
                ret
qglFileSize   endp

;;::::::::::::::
;; qglFileSeek ( h:word, pos:dword ) -> ax nonzero on success
;;
;; Absolute, from the start of the FILE, and REFUSED on a member: a
;; handle opened through a driver records how much of its window is
;; left but never where that window began, so a seek on one would clamp
;; against the wrong amount. A plain file is its own window, which is
;; what a caller holding a directory of offsets has open.
;;::::::::::::::
qglFileSeek   proc    public uses bx cx dx,\
                        h:word, pos:dword

                mov     ax, h
                call    qgl$Slot
                jc      @@bad
                cmp     D qgl$file_tb[bx].fh_row, 0
                jne     @@bad                   ;; a member: see above
                mov     eax, qgl$file_tb[bx].fh_size
                cmp     eax, pos
                jb      @@bad
                sub     eax, pos                ;; what is left after it
                mov     cx, qgl$file_tb[bx].fh_dos
                push    eax
                push    bx
                invoke  qglFileRawSeek, cx, 0, pos
                pop     bx
                pop     ecx
                test    ax, ax
                jz      @@bad
                mov     qgl$file_tb[bx].fh_left, ecx
                mov     ax, 1
                ret

@@bad:          xor     ax, ax
                ret
qglFileSeek   endp


;;::::::::::::::
;; qglFileRead ( h:word, dst:far ptr, nbytes:dword ) -> dx:ax = bytes read
;;
;; Clamped to what is left of the window. Without that a read past the
;; end of a member walks into the next one's header and hands it back as
;; data, which is the whole reason a member is not just a file offset.
;;::::::::::::::
qglFileRead   proc    public uses bx cx,\
                        h:word, dst:dword, nbytes:dword

                mov     ax, h
                call    qgl$Slot
                jc      @@bad

                mov     eax, nbytes
                cmp     eax, qgl$file_tb[bx].fh_left
                jbe     @F
                mov     eax, qgl$file_tb[bx].fh_left
@@:             mov     nbytes, eax
                mov     cx, qgl$file_tb[bx].fh_dos
                push    bx
                invoke  qglFileRawRead, cx, dst, nbytes
                pop     bx

                movzx   ecx, dx                 ;; what it really gave, 32-bit
                shl     ecx, 16
                mov     cx, ax
                sub     qgl$file_tb[bx].fh_left, ecx
                ret

@@bad:          xor     ax, ax
                xor     dx, dx
                ret
qglFileRead   endp


;;::::::::::::::
;; qglFileWrite ( h:word, src:far ptr, nbytes:dword ) -> dx:ax = bytes written
;;
;; A plain file takes the bytes at its current position. A member goes
;; to its driver's write, and a driver that has none refuses with 0 --
;; a stored zip member could take same-sized bytes in place, and does
;; not, because nothing here wants to rewrite an asset.
;;::::::::::::::
qglFileWrite  proc    public uses bx cx si es,\
                        h:word, src:dword, nbytes:dword

                mov     ax, h
                call    qgl$Slot
                jc      @@bad

                mov     cx, qgl$file_tb[bx].fh_dos
                les     si, qgl$file_tb[bx].fh_row
                mov     ax, es
                or      ax, si
                jz      @@plain

                mov     ax, W es:[si].FsDrv.fs_write
                or      ax, W es:[si].FsDrv.fs_write+2
                jz      @@bad                   ;; the format cannot
                push    cx
                push    W src+2
                push    W src
                push    W nbytes+2
                push    W nbytes
                call    D es:[si].FsDrv.fs_write
                ret

@@plain:        invoke  qglFileRawWrite, cx, src, nbytes
                ret

@@bad:          xor     ax, ax
                xor     dx, dx
                ret
qglFileWrite  endp


;;::::::::::::::
;; qglFileClose ( h:word )
;;::::::::::::::
qglFileClose  proc    public uses bx,\
                        h:word

                mov     ax, h
                call    qgl$Slot
                jc      @@out
                push    bx
                mov     bx, qgl$file_tb[bx].fh_dos
                mov     ah, 3Eh
                int     21h
                pop     bx
                mov     qgl$file_tb[bx].fh_dos, 0
                mov     qgl$file_tb[bx].fh_row, 0
                mov     qgl$file_tb[bx].fh_left, 0
                mov     qgl$file_tb[bx].fh_size, 0
@@out:          ret
qglFileClose  endp


;;::::::::::::::
;; qglFileDrivers () -> ax = how many driver rows the bracket holds
;;
;; 0 when no driver is linked -- or when one was linked ahead of this
;; module, which is the build error the header describes.
;;::::::::::::::
qglFileDrivers proc   public uses bx

                mov     ax, offset QGLFS:qgl$fs_end
                mov     bx, offset QGLFS:qgl$fs_begin
                sub     ax, bx
                jbe     @@none
                xor     dx, dx
                mov     bx, T FsDrv
                div     bx
                ret
@@none:         xor     ax, ax
                ret
qglFileDrivers endp


;;::::::::::::::
;; qglFileRawSize ( fh:DOS handle ) -> dx:ax = bytes, and the file is rewound
;;::::::::::::::
qglFileRawSize proc   public uses bx cx,\
                        fh:word

                mov     bx, fh
                mov     ax, 4202h               ;; seek from the end
                xor     cx, cx
                xor     dx, dx
                int     21h
                jc      @@fail

                push    dx
                push    ax
                mov     bx, fh                  ;; and back to the start
                mov     ax, 4200h
                xor     cx, cx
                xor     dx, dx
                int     21h
                pop     ax
                pop     dx
                ret

@@fail:         xor     ax, ax
                xor     dx, dx
                ret
qglFileRawSize endp


;;::::::::::::::
;; qglFileRawSeek ( fh:DOS handle, whence:word, pos:dword ) -> ax nonzero on success
;;
;; whence is DOS's: 0 from the start, 1 from here, 2 from the end.
;;::::::::::::::
qglFileRawSeek proc   public uses bx cx dx,\
                        fh:word, whence:word, pos:dword

                mov     bx, fh
                mov     ax, whence
                mov     ah, 42h
                mov     cx, W pos+2
                mov     dx, W pos
                int     21h
                mov     ax, 0
                jc      @F
                inc     ax
@@:             ret
qglFileRawSeek endp


;;::::::::::::::
;; qglFileRawRead ( fh:DOS handle, dst:far ptr, nbytes:dword ) -> dx:ax = bytes read
;;
;; Reads in runs of at most 32K so a length past 64K is the caller's
;; business rather than a trap, and advances the destination itself.
;;::::::::::::::
qglFileRawRead proc   public uses bx cx si di ds es,\
                        fh:word, dst:dword, nbytes:dword

                local   total:dword
                local   gotn:word

                mov     total, 0

                ;; normalised before the first read, so no single INT 21h
                ;; is handed a buffer that runs off the end of its segment
                FARADD  dst, 0

@@chunk:        mov     eax, nbytes
                test    eax, eax
                jz      @@done
                cmp     eax, 8000h
                jbe     @F
                mov     eax, 8000h
@@:             mov     si, ax                  ;; this run's length

                ;; every local read BEFORE ds moves: a local is
                ;; ss-relative and switching ds first leaves the rest of
                ;; the frame reachable only by the assembler's goodwill
                mov     cx, si
                mov     bx, fh
                mov     dx, word ptr dst
                mov     ax, word ptr dst+2
                push    ds
                mov     ds, ax
                mov     ah, 3Fh
                int     21h
                pop     ds
                jc      @@done

                movzx   ecx, ax                 ;; what it really gave
                add     total, ecx
                test    ax, ax
                jz      @@done                  ;; end of file

                ;; every count settled BEFORE the pointer moves: FARADD
                ;; takes ax, bx and cx, and ecx is still the byte count
                mov     gotn, ax
                sub     nbytes, ecx

                FARADD  dst, gotn

                mov     ax, gotn
                cmp     ax, si
                jb      @@done                  ;; short read: that is EOF
                jmp     @@chunk

@@done:         mov     ax, word ptr total
                mov     dx, word ptr total+2
                ret
qglFileRawRead endp


;;::::::::::::::
;; qglFileRawWrite ( fh:DOS handle, src:far ptr, nbytes:dword ) -> dx:ax = bytes written
;;
;; The same runs as the read, for the same reason.
;;::::::::::::::
qglFileRawWrite proc  public uses bx cx si di ds es,\
                        fh:word, src:dword, nbytes:dword

                local   total:dword
                local   gotn:word

                mov     total, 0
                FARADD  src, 0

@@chunk:        mov     eax, nbytes
                test    eax, eax
                jz      @@done
                cmp     eax, 8000h
                jbe     @F
                mov     eax, 8000h
@@:             mov     si, ax

                mov     cx, si
                mov     bx, fh
                mov     dx, word ptr src
                mov     ax, word ptr src+2
                push    ds
                mov     ds, ax
                mov     ah, 40h
                int     21h
                pop     ds
                jc      @@done

                movzx   ecx, ax
                add     total, ecx
                test    ax, ax
                jz      @@done                  ;; the disk is full

                mov     gotn, ax
                sub     nbytes, ecx

                FARADD  src, gotn

                mov     ax, gotn
                cmp     ax, si
                jb      @@done
                jmp     @@chunk

@@done:         mov     ax, word ptr total
                mov     dx, word ptr total+2
                ret
qglFileRawWrite endp

                end
