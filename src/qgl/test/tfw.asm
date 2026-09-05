;; tfw.asm -- the qgl test framework: entry, the ok/FAIL printer, and the
;;            RESULT line runall greps for.
;;
;; Ported from mgl's own scratch suite. Each test supplies tmain; the exit
;; code is the failure count, and the LAST line is RESULT PASS or RESULT
;; FAIL. Silence counts as failure at the harness level, deliberately --
;; the commonest way a DOS test passes is by never running.

                .model  medium, pascal
                .386
                .stack  2048

W               textequ <word ptr>
                extrn   tmain:far

.data
t_fails         dw      0
s_ok            db      '   ok   $'
s_bad           db      '   FAIL $'
s_nl            db      13,10,'$'
s_pass          db      'RESULT PASS',13,10,'$'
s_fail          db      'RESULT FAIL',13,10,'$'
s_hexpfx        db      '0x'
s_hex           db      '00000000$'

.data
psp_seg         dw      0

.code
;; Release the tail of our own memory block before anything runs.
;;
;; Not housekeeping: DOS hands a .EXE every free byte in the machine, so
;; INT 21h/48h has nothing left to give and qgl_mem_alloc returns 0 for
;; every request. Measured before this was added -- avail and the MCB
;; free-sum both read 0x00000000 and the first allocation failed. Any
;; real program does this at startup; the test framework has to as well
;; or it is testing a machine with no free memory.
;;
;; Keep everything up to the top of the stack, which in this model is the
;; end of DGROUP and the last thing linked.
start:          mov     ax, es                  ;; DOS entered with ES = PSP
                mov     bx, @data
                mov     ds, bx
                mov     psp_seg, ax

                mov     bx, ss
                mov     ax, sp
                shr     ax, 4
                add     bx, ax
                add     bx, 2                   ;; margin for the rounding
                sub     bx, psp_seg             ;; paragraphs to keep
                mov     es, psp_seg
                mov     ah, 4Ah
                int     21h

                mov     ax, @data
                mov     ds, ax
                cld
                call    tmain

                mov     dx, offset s_pass
                cmp     t_fails, 0
                je      @F
                mov     dx, offset s_fail
@@:             mov     ah, 9
                int     21h
                mov     al, byte ptr t_fails
                mov     ah, 4Ch
                int     21h


;;::::::::::::::
;; tchk ( nam:word, got:word, want:word )
;;
;; One assertion. Prints the name either way, so a passing run reads as a
;; list of what was actually checked rather than a bare PASS.
;;::::::::::::::
tchk            proc    far public uses bx cx dx si di es,\
                        nam:word, got:word, want:word

                mov     dx, offset s_ok
                mov     ax, got
                cmp     ax, want
                je      @F
                inc     t_fails
                mov     dx, offset s_bad
@@:             mov     ah, 9
                int     21h
                mov     dx, nam
                mov     ah, 9
                int     21h
                mov     dx, offset s_nl
                mov     ah, 9
                int     21h
                ret
tchk            endp


;;::::::::::::::
;; tshow ( nam:word, val:dword )
;;
;; Reports a measured number instead of asserting on it. Some of what
;; this suite exists to find out -- how much conventional memory there
;; really is -- has no right answer to compare against, and a number you
;; cannot see is a number nobody acts on.
;;::::::::::::::
tshow           proc    far public uses bx cx dx si di es,\
                        nam:word, val:dword

                mov     dx, nam
                mov     ah, 9
                int     21h

                mov     eax, val
                mov     cx, 8
                mov     si, offset s_hex
                ;; named, not @@: the digit test below needs its own @@,
                ;; and @B would then bind to that one instead of here
@@digit:        rol     eax, 4
                mov     bl, al
                and     bl, 0Fh
                cmp     bl, 10
                jb      @F
                add     bl, 'A'-'0'-10
@@:             add     bl, '0'
                mov     [si], bl
                inc     si
                loop    @@digit

                mov     dx, offset s_hexpfx
                mov     ah, 9
                int     21h
                mov     dx, offset s_nl
                mov     ah, 9
                int     21h
                ret
tshow           endp


;;::::::::::::::
;; tfill ( sg:word, len:word, seed:byte )
;;
;; A walking pattern rather than a constant: a constant cannot tell a
;; correct write from a write to the wrong row, since every row looks
;; alike.
;;::::::::::::::
tfill           proc    far public uses bx cx di es,\
                        sg:word, ofs:word, len:word, seed:byte

                mov     es, sg
                mov     di, ofs
                mov     cx, len
                mov     al, seed
@@:             mov     es:[di], al
                add     al, 7
                inc     di
                loop    @B
                ret
tfill           endp


;;::::::::::::::
;; tvrfy ( sg:word, ofs:word, len:word, seed:byte ) -> ax = mismatches
;;::::::::::::::
tvrfy           proc    far public uses bx cx di es,\
                        sg:word, ofs:word, len:word, seed:byte

                mov     es, sg
                mov     di, ofs
                mov     cx, len
                mov     al, seed
                xor     bx, bx
@@:             cmp     es:[di], al
                je      @F
                inc     bx
@@:             add     al, 7
                inc     di
                loop    @B
                mov     ax, bx
                ret
tvrfy           endp

                end     start
