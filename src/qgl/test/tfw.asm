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
result_name     db      'OUT.TXT',0
t_handle        dw      -1

.data
psp_seg         dw      0

.code
;; Write CX bytes through stdout and the owned result file. Keeping the
;; measurement file separate from command-shell redirection avoids the MGL
;; process changing or closing stdout before DOS flushes it.
twrite_n        proc    near private uses ax bx cx dx
                mov     bx, 1
                mov     ah, 40h
                int     21h
                mov     bx, t_handle
                cmp     bx, -1
                je      @@out
                mov     ah, 40h
                int     21h
@@out:          ret
twrite_n        endp

;; Write a '$'-terminated framework string through stdout handle 1. AH=09
;; ignores redirection in this environment; AH=40 needs the exact length.
twrite          proc    near private uses ax bx cx si
                mov     si, dx
                xor     cx, cx
@@scan:         cmp     byte ptr [si], '$'
                je      @@write
                inc     si
                inc     cx
                jmp     @@scan
@@write:        call    twrite_n
                ret
twrite          endp

;; Release the tail of our own memory block before anything runs.
;;
;; Not housekeeping: DOS hands a .EXE every free byte in the machine, so
;; INT 21h/48h has nothing left to give and qglMemAlloc returns 0 for
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

                ;; KEEP THE WHOLE OF DGROUP, not just up to the stack.
                ;;
                ;; jwlink puts _BSS AFTER the stack. From a map of t11rep:
                ;; _DATA at 0215, STACK at 0243 for 800h, _BSS at 02c3 for
                ;; e18h, ending at 03a5. Releasing at ss:sp keeps only to
                ;; 02c5 and hands DOS 3.5K of live .data? -- which the
                ;; first qglMemAlloc takes straight back and hands to a
                ;; surface, so drawing wrote through the scanner's own
                ;; vertex arrays.
                ;;
                ;; That is why it followed the SURFACE and not the call
                ;; order: only the first allocation landed on the BSS.
                ;;
                ;; DGROUP cannot exceed 64K, so a flat 1000h paragraphs is
                ;; always enough and never wrong. The suite has 640K and
                ;; wants 25K of it; being exact here would buy nothing and
                ;; needs a symbol the linker will not promise to place
                ;; last.
                mov     bx, @data
                add     bx, 1000h
                sub     bx, psp_seg             ;; paragraphs to keep
                mov     es, psp_seg
                mov     ah, 4Ah
                int     21h

                ;; VBDOS medium model keeps SS = DS. MGL addresses its
                ;; runtime state and BASIC descriptors through SS, so a
                ;; standalone caller must establish the same contract.
                ;; The retained block reserves the full 64K DGROUP; the
                ;; live data in these tests stays well below this stack.
                cli
                mov     ax, @data
                mov     ss, ax
                mov     sp, 0FFFEh
                sti
                mov     ds, ax
                cld
                mov     dx, offset result_name
                xor     cx, cx
                mov     ah, 3Ch
                int     21h
                jc      @F
                mov     t_handle, ax
@@:
                call    tmain

                mov     dx, offset s_pass
                cmp     t_fails, 0
                je      @F
                mov     dx, offset s_fail
@@:             call    twrite
                mov     bx, t_handle
                cmp     bx, -1
                je      @F
                mov     ah, 3Eh
                int     21h
@@:
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
@@:             call    twrite
                mov     dx, nam
                call    twrite
                mov     dx, offset s_nl
                call    twrite
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
                call    twrite

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
                call    twrite
                mov     dx, offset s_nl
                call    twrite
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
                        sg:word, ofs:word, len:word, seed:word

                mov     es, sg
                mov     di, ofs
                mov     cx, len
                mov     ax, seed
@@:             mov     es:[di], al
                add     al, 7
                inc     di
                loop    @B
                ret
tfill           endp


;;::::::::::::::
;; tvrfy ( sg:word, ofs:word, len:word, seed:word ) -> ax = mismatches
;;::::::::::::::
tvrfy           proc    far public uses bx cx di es,\
                        sg:word, ofs:word, len:word, seed:word

                mov     es, sg
                mov     di, ofs
                mov     cx, len
                mov     ax, seed
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
