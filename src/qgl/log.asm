;; log.asm -- mgl's msclog.asm with the sink replaced and nothing else.
;;
;; name: log_open / log_begin / log_end / log_msg / log_close
;; desc: The five routines qgl.inc's LOG macros jump to. mgl's names, not
;;       qgl$ ones, deliberately: the macro expansion has to stay
;;       byte-comparable against mgl's, which is the whole reason the LOG
;;       lines were transcribed in the first place.
;;
;;       mgl appends each line to ugl.log, opening and closing the file
;;       per message so a hang still leaves a complete trace -- three INT
;;       21h a line, enough to move a frame time and hide whatever is
;;       being traced. Here the sink is port E9h, which DOSBox-X
;;       implements as the Bochs debug port: one `rep outsb` a message,
;;       no handle, no seek. It survives a hang for a better reason than
;;       mgl's, since DOSBox-X opens the log unbuffered.
;;
;; obs.: - Gated on mgl's own _DEBUG_, which is also what gates the
;;         macros, so an undefined build emits no call and needs no
;;         routine. `make SERIAL_LOG=1` is what defines it -- the switch
;;         lives on the assembler command line precisely so qgl.inc
;;         stays mgl's log.inc verbatim, with no qgl-specific gate in it.
;;       - Needs `bochs debug port e9 = true` in [dosbox] and a [log]
;;         logfile to read; each line arrives prefixed "Bochs port E9h: ".
;;       - AND IT NEEDS -nolog GONE. LOG_MSG returns early on opt_nolog,
;;         so that flag yields an empty log -- indistinguishable from
;;         macros that never fired. tools/dosbox.sh passes it by default.
;;       - `opened` starts TRUE, where mgl starts it FALSE and lets
;;         LOGOPEN create the file. There is no file to create, and qgl
;;         has no uglmain to call LOGOPEN from, so a FALSE default would
;;         make every one of the 57 call sites silently log nothing.
;;       - The handler buffers until CR, LF or 256 chars. Every macro
;;         already ends its message 13,10, so a message is a line.
;;       - EVERY ROUTINE HERE SAVES EVERYTHING. A logger is called from
;;         wherever a LOG line happens to sit, with no regard for what is
;;         live there, so it is the one kind of routine that cannot have
;;         a clobber list. t22log asserts it against four registers.

                .model  medium, pascal
                .386

                include qgl.inc

.code
IFDEF _DEBUG_

E9PORT          equ     0E9h

opened          word    TRUE
logbuff         byte    32 dup (9h)     ;; tabs, one per open LOGBEGIN
logtabs         word    0

;;:::
;; Write cx bytes at ds:si to E9h. cx = 0 is a legal no-op.
log_out         proc    near
                mov     dx, E9PORT
                cld
                rep     outsb
                ret
log_out         endp

;;:::
;; The current indent, if any.
log_indent      proc    near
                mov     cx, cs:logtabs
                cmp     cx, 0
                jle     @@exit
                cmp     cx, T logbuff
                jbe     @F
                mov     cx, T logbuff   ;; 32 nested LOGBEGINs, then flat
@@:             push    ds
                push    cs
                pop     ds
                mov     si, O logbuff
                call    log_out
                pop     ds
@@exit:         ret
log_indent      endp

;;::::::::::::::
log_open        proc    far public msg:dword, len:word
                pushad
                pushf
                push    ds
                mov     cs:opened, TRUE
                mov     cs:logtabs, 0
                lds     si, msg
                mov     cx, len
                call    log_out
                pop     ds
                popf
                popad
                ret
log_open        endp

;;::::::::::::::
log_close       proc    far public msg:dword, len:word
                pushad
                pushf
                push    ds
                cmp     cs:opened, TRUE
                jne     @@exit
                mov     cs:opened, FALSE
                lds     si, msg
                mov     cx, len
                call    log_out
@@exit:         pop     ds
                popf
                popad
                ret
log_close       endp

;;::::::::::::::
log_begin       proc    far public msg:dword, len:word
                pushad
                pushf
                push    ds
                cmp     cs:opened, TRUE
                jne     @@exit
                call    log_indent
                inc     cs:logtabs
                lds     si, msg
                mov     cx, len
                call    log_out
@@exit:         pop     ds
                popf
                popad
                ret
log_begin       endp

;;::::::::::::::
log_end         proc    far public msg:dword, len:word
                pushad
                pushf
                push    ds
                cmp     cs:opened, TRUE
                jne     @@exit
                dec     cs:logtabs      ;; before the indent: the closing
                call    log_indent      ;; brace lines up with its opener
                lds     si, msg
                mov     cx, len
                call    log_out
@@exit:         pop     ds
                popf
                popad
                ret
log_end         endp

;;::::::::::::::
log_msg         proc    far public msg:dword, len:word
                pushad
                pushf
                push    ds
                cmp     cs:opened, TRUE
                jne     @@exit
                call    log_indent
                lds     si, msg
                mov     cx, len
                call    log_out
@@exit:         pop     ds
                popf
                popad
                ret
log_msg         endp

ENDIF   ;; SERIAL_LOG
                end
