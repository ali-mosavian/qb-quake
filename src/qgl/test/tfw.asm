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

.code
start:          mov     ax, @data
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
