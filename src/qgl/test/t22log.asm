;; t22log -- the LOG macros, with the logger actually switched on.
;;
;; This is the only test built with -D_DEBUG_=1, so it is the only one
;; where the 57 transcribed LOG lines in qglnew, qglview and dctems emit
;; anything at all. Everywhere else they assemble to nothing and prove
;; nothing.
;;
;; What can go wrong is not the port write. It is the frame: each macro
;; pushes cs, an offset, a length, cs and a return offset, then FAR JUMPS
;; -- there is no call -- into a `proc far pascal msg:dword, len:word`
;; whose `ret` has to pop exactly those six bytes and land on the inline
;; ??ret label. Get the count wrong and control returns into the middle
;; of the message text, which in this codebase reads as a hang or as a
;; fault in whatever ran last.
;;
;; So: registers and sp across each macro, then a real qgl entry called
;; with logging compiled in, because a layer that only works with the
;; logging switched off is not a layer that can be debugged with it on.
;;
;; Seen to fail: saving only bx in log_msg (rather than pushad) fails
;; `keeps cx` and `keeps si` and takes qglSfNew down with it, while
;; `keeps bx` and `keeps di` stay green -- which is the shape that says
;; the four register checks are each doing their own work.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

.data
n_msg_bx        db      'LOGMSG keeps bx     $'
n_msg_cx        db      'LOGMSG keeps cx     $'
n_msg_si        db      'LOGMSG keeps si     $'
n_msg_di        db      'LOGMSG keeps di     $'
n_msg_sp        db      'LOGMSG keeps sp     $'
n_beg_sp        db      'LOGBEGIN keeps sp   $'
n_end_sp        db      'LOGEND keeps sp     $'
n_err_sp        db      'LOGERROR keeps sp   $'
n_nest_sp       db      'nested pair keeps sp$'
n_sf_ptr        db      'logged qglSfNew ok  $'
n_sf_x          db      'logged surface x 64 $'
n_sf_y          db      'logged surface y 32 $'

sp_was          dw      0
sf              dd      0

.code
tmain           proc    far public uses bx si di es

                ;;
                ;; One LOGMSG, everything live across it. pushad/pushf and
                ;; the ds push in log.asm are what make this hold; drop any
                ;; one of them and exactly one of these four fails, which
                ;; is the point of checking four rather than one.
                ;;
                mov     bx, 1234h
                mov     cx, 5678h
                mov     si, 9ABCh
                mov     di, 0DEF0h
                mov     sp_was, sp

                LOGMSG  <t22 live registers>

                CHK     n_msg_bx, bx, 1234h
                CHK     n_msg_cx, cx, 5678h
                CHK     n_msg_si, si, 9ABCh
                CHK     n_msg_di, di, 0DEF0h
                mov     ax, sp
                CHK     n_msg_sp, ax, sp_was

                ;;
                ;; The other three macros. LOGEND pushes a 1-byte message
                ;; and LOGERROR a variable one, so each has its own length
                ;; expression and each can be wrong on its own.
                ;;
                mov     sp_was, sp
                LOGBEGIN t22scope
                mov     ax, sp
                CHK     n_beg_sp, ax, sp_was

                mov     sp_was, sp
                LOGEND
                mov     ax, sp
                CHK     n_end_sp, ax, sp_was

                mov     sp_was, sp
                LOGERROR
                mov     ax, sp
                CHK     n_err_sp, ax, sp_was

                ;; Nested, because log_end decrements the indent before it
                ;; writes it and an unbalanced pair would walk logtabs
                ;; negative -- log_indent's `jle` is what stops that
                ;; becoming a 64K rep outsb.
                mov     sp_was, sp
                LOGBEGIN t22outer
                LOGBEGIN t22inner
                LOGMSG  <inside>
                LOGEND
                LOGEND
                mov     ax, sp
                CHK     n_nest_sp, ax, sp_was

                ;;
                ;; A real entry, compiled with its own LOG lines live.
                ;; qglNew carries LOGBEGIN, two LOGMSG, LOGEND and
                ;; LOGERROR, so this is the transcription under load
                ;; rather than the macros in isolation.
                ;;
                invoke  qglGemInit
                invoke  qglSfInit
                invoke  qglSfNew, 64, 32, SF_MEM
                SAVEP   sf

                mov     bx, dx
                or      bx, ax
                NZ      bx
                CHK     n_sf_ptr, ax, 1

                les     bx, sf
                CHK     n_sf_x, es:[bx].Surface.xRes, 64
                CHK     n_sf_y, es:[bx].Surface.yRes, 32

                invoke  qglSfFree, sf

                ret
tmain           endp
                end
