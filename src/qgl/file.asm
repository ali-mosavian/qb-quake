;; file.asm -- opening, sizing, reading and closing a file.
;;
;; name: qgl_file_open / qgl_file_open_bas / qgl_file_size /
;;       qgl_file_read / qgl_file_close
;; desc: DOS handles, and nothing above them. Every other qgl module that
;;       needs bytes off disk asks here rather than reaching for INT 21h
;;       itself -- txt.asm had its own copy of exactly this and that is
;;       the duplication this removes.
;;
;;       It is also where the ONE piece of BASIC knowledge in the layer
;;       lives. A BASIC string is not a pointer to characters: under
;;       VBDOS's far strings the parameter is a NEAR pointer to a
;;       descriptor in ss, whose seg_tb and ofs_tb chase through two more
;;       indirections to an FSTRG, which is LENGTH-PREFIXED and carries
;;       no terminator (mgl's lang.inc STRGET does the same walk). DOS
;;       wants ASCIIZ. Something has to bridge that, once, here.
;;
;; obs.: - two entry points rather than one that guesses: qgl_file_open
;;         takes a far pointer to ASCIIZ and exists in every build;
;;         qgl_file_open_bas takes a BASIC string and exists only under
;;         __BASIC__. Adding the second did not change the first, which
;;         is the point -- a C or asm caller is unaffected by BASIC's
;;         string representation, and the test suite links without it.
;;       - the path buffer is module-private and reused per call. A
;;         handle outlives it; the name does not need to.

                .model  medium, pascal
                .386

                include qgl.inc

PATH_MAX        equ     80

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


.data
qgl$path        db      PATH_MAX dup (0)


.code

;;::::::::::::::
;; qgl$asciiz -- copy a NUL-terminated path into the module's buffer.
;;
;; INTERNAL: es:si -> the source. dx = the buffer's offset in DGROUP.
;; Everything else survives.
;;::::::::::::::
qgl$asciiz      proc    near private uses ax cx si di ds es

                push    es
                pop     ds                      ;; ds:si = the source
                mov     ax, @data
                mov     es, ax                  ;; es:di = our buffer
                mov     di, offset qgl$path
                mov     cx, PATH_MAX-1

@@ch:           lodsb
                test    al, al
                jz      @F
                stosb
                loop    @@ch
@@:             xor     al, al
                stosb

                mov     dx, offset qgl$path
                ret
qgl$asciiz      endp


;;::::::::::::::
;; qgl_file_open ( path:far ptr to ASCIIZ ) -> ax = handle, 0 on failure
;;::::::::::::::
qgl_file_open   proc    public uses bx cx dx si di es,\
                        path:dword

                les     si, path
                call    qgl$asciiz              ;; dx -> our copy

                mov     ax, 3D00h               ;; open, read only
                int     21h
                jnc     @F
                xor     ax, ax
@@:             ret
qgl_file_open   endp


IFDEF __BASIC__
;;::::::::::::::
;; qgl_file_open_bas ( s:BASIC string ) -> ax = handle, 0 on failure
;;
;; The parameter is a near pointer to a descriptor in ss, not a pointer
;; to characters. See this module's header for the walk; the short of it
;; is that the data is length-prefixed and has no terminator, so it is
;; copied out and terminated here.
;;::::::::::::::
qgl_file_open_bas proc  public uses bx cx dx si di ds es,\
                        s:word

                mov     si, s                   ;; ss:si -> BasStr
                mov     ax, ss:[si].BasStr.seg_tb
                mov     bx, ss:[si].BasStr.ofs_tb
                mov     si, ax
                mov     ax, ss:[si]             ;; the string's segment
                mov     si, bx
                mov     ds, ax
                mov     si, ds:[si]             ;; the string's offset

                mov     cx, ds:[si].FStrg.slen
                cmp     cx, PATH_MAX-1
                jbe     @F
                mov     cx, PATH_MAX-1
@@:             add     si, FStrg.sdat          ;; ds:si -> the characters

                mov     ax, @data
                mov     es, ax
                mov     di, offset qgl$path
                jcxz    @F
                rep     movsb
@@:             xor     al, al
                stosb

                mov     ax, @data
                mov     ds, ax
                mov     dx, offset qgl$path
                mov     ax, 3D00h
                int     21h
                jnc     @F
                xor     ax, ax
@@:             ret
qgl_file_open_bas endp
ENDIF


;;::::::::::::::
;; qgl_file_size ( h:word ) -> dx:ax = bytes, and the file is rewound
;;::::::::::::::
qgl_file_size   proc    public uses bx cx,\
                        h:word

                mov     bx, h
                mov     ax, 4202h               ;; seek from the end
                xor     cx, cx
                xor     dx, dx
                int     21h
                jc      @@fail

                push    dx
                push    ax
                mov     bx, h                   ;; and back to the start
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
qgl_file_size   endp


;;::::::::::::::
;; qgl_file_read ( h:word, dst:far ptr, nbytes:dword ) -> dx:ax = bytes read
;;
;; Reads in runs of at most 32K so a length past 64K is the caller's
;; business rather than a trap, and advances the destination itself.
;;::::::::::::::
qgl_file_read   proc    public uses bx cx si di ds es,\
                        h:word, dst:dword, nbytes:dword

                local   total:dword

                mov     total, 0

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
                mov     bx, h
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

                add     word ptr dst, ax
                adc     word ptr dst+2, 0
                sub     nbytes, ecx
                cmp     ax, si
                jb      @@done                  ;; short read: that is EOF
                jmp     @@chunk

@@done:         mov     ax, word ptr total
                mov     dx, word ptr total+2
                ret
qgl_file_read   endp


;;::::::::::::::
;; qgl_file_close ( h:word )
;;::::::::::::::
qgl_file_close  proc    public uses bx,\
                        h:word
                mov     bx, h
                test    bx, bx
                jz      @F
                mov     ah, 3Eh
                int     21h
@@:             ret
qgl_file_close  endp

                end
