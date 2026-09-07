;; b06movq -- does MOVQ actually beat REP MOVSD here, and does an exact-2x
;;            unpack core beat a scalar byte-doubler?
;;
;; Asked because the scaled present is 9.2% of a frame and its inner loop
;; is the only place per-pixel work is paid unconditionally. Two separate
;; questions, because they are two different loops:
;;
;;   the RUN COPY   -- qgl$RunCopy, rep movsd, used by the unscaled blit
;;                     and by every whole row an integer scaler duplicates
;;   the 2x EXPAND  -- one source byte to two destination bytes, which is
;;                     what the shipped present actually does: view_scale
;;                     is "the largest whole-number multiple", never
;;                     fractional
;;
;; MMX cannot help general scaling at all: a fractional sampler is a
;; GATHER, and there is no gather here. It can help the exact-2x case,
;; where punpcklbw duplicates every byte of a qword in one instruction.
;; So the 2x core is tested separately and is the one that bears on the
;; present path; a run-copy result alone would not.
;;
;; MOVQ RAISES THE CPU REQUIREMENT. Nothing here is production code. The
;; pinned bench machine is cputype=pentium_iii, and this test pins it too;
;; the suite's own run1.sh sets no cputype at all, so a result taken there
;; would not be the pinned machine. Shipping any of this needs either an
;; explicit project decision to require MMX or a one-time CPUID dispatch
;; with the 386 path as the fallback.
;;
;; EMMS on every exit from every MMX routine, including the ones that took
;; an early out without executing an MMX instruction: the state is the
;; FPU's, and the framework prints with it afterwards.

                .model  medium, pascal
                .586
                .mmx

                include qgl.inc
                include tfw.inc

SRCB            equ     4096
DSTB            equ     8192 + 16
ROUNDS          equ     6
;; 5x the first screen's work: the MMX arm sat at 4-5 ticks there,
;; under the floor, so the ratio was directional and not numeric.
REPS            equ     200
LOOPS           equ     200

.data
n_copy          db      'movq copy exact       $'
n_dup           db      'mmx 2x expand exact   $'
n_sdup          db      'scalar 2x expand ok   $'
n_dur           db      'duration >= 20 ticks  $'

q_movsd         db      'run copy movsd ticks  $'
q_movq          db      'run copy movq  ticks  $'
q_s2x           db      'expand 2x scalar ticks$'
q_m2x           db      'expand 2x mmx   ticks $'

n_align         db      'alignment under test  $'
n_len           db      'length under test     $'

;; lengths chosen for the seams: under a qword, exactly one, one past, and
;; the odd tails either side of a 4-byte and an 8-byte boundary
lens            dw      1, 2, 3, 4, 5, 7, 8, 9, 15, 16, 17, 31, 63, 64, 65
                dw      127, 255, 256, 257, 1023, 4095, 4096
NLENS           equ     22

src             db      SRCB dup (0)
dsta            db      DSTB dup (0)
dstb            db      DSTB dup (0)
expect          db      DSTB dup (0)
bad             dw      0
t0              dd      0
shown           dd      0
rv              dw      0
lv              dw      0
av              dw      0

.code

                externdef qgl$RunCopy:near

time_copy       proto   near :word, :word
time_dup        proto   near :word, :word
cmpbuf          proto   near :word
expect_copy     proto   near :word
expect_dup      proto   near :word
cmpexp          proto   near :word, :word

bnow            proc    near private uses bx es
                xor     bx, bx
                mov     es, bx
@@try:          mov     ax, es:[46Ch]
                mov     dx, es:[46Eh]
                mov     bx, es:[46Ch]
                cmp     ax, bx
                jne     @@try
                ret
bnow            endp

;;::::::::::::::
;; qgl$copy_movq -- a run copy in qwords. ds:si -> es:di, cx = bytes.
;;
;; The destination is brought to an 8-boundary with bytes first, because
;; an unaligned qword store costs more than the bytes saved. EMMS before
;; every ret.
;;::::::::::::::
copy_movq       proc    near private uses ax bx cx
                cld
                jcxz    @@out
                mov     bx, cx
                mov     cx, di
                neg     cx
                and     cx, 7
                cmp     cx, bx
                jbe     @F
                mov     cx, bx
@@:             sub     bx, cx
                rep     movsb

                mov     cx, bx
                shr     cx, 3
                jcxz    @@tail
@@q:            movq    mm0, [si]
                movq    es:[di], mm0
                add     si, 8
                add     di, 8
                loop    @@q

@@tail:         mov     cx, bx
                and     cx, 7
                rep     movsb
@@out:          emms
                ret
copy_movq       endp

;;:::::::::::::: one source byte to two, scalar. ds:si -> es:di, cx = src
dup_scalar      proc    near private uses ax cx
                cld
                jcxz    @@out
@@b:            lodsb
                mov     ah, al
                stosw
                loop    @@b
@@out:          ret
dup_scalar      endp

;;:::::::::::::: the same, eight source bytes at a time
dup_mmx         proc    near private uses ax bx cx
                cld
                jcxz    @@out
                mov     bx, cx
                shr     cx, 3
                jcxz    @@tail
@@q:            movq    mm0, [si]
                movq    mm1, mm0
                punpcklbw mm0, mm0              ;; low four bytes doubled
                punpckhbw mm1, mm1              ;; high four
                movq    es:[di], mm0
                movq    es:[di+8], mm1
                add     si, 8
                add     di, 16
                loop    @@q
@@tail:         mov     cx, bx
                and     cx, 7
                jcxz    @@out
@@b:            lodsb
                mov     ah, al
                stosw
                loop    @@b
@@out:          emms
                ret
dup_mmx         endp

;;::::::::::::::
;; expect_copy / expect_dup -- the answer, computed by INDEX, not by
;; streaming. dsta and dstb are both produced by streaming loops, and two
;; streaming loops that share a mistake agree with each other.
;;::::::::::::::
expect_copy     proc    near private uses ax bx cx si di es,
                        n:word
                mov     ax, @data
                mov     es, ax
                xor     bx, bx
@@b:            cmp     bx, n
                jae     @@out
                mov     si, offset src
                add     si, bx
                mov     al, ds:[si]
                mov     di, offset expect
                add     di, bx
                mov     es:[di], al
                inc     bx
                jmp     @@b
@@out:          ret
expect_copy     endp

;; expect[i] = src[i shr 1], for 2n bytes
expect_dup      proc    near private uses ax bx cx si di es,
                        n:word
                mov     ax, @data
                mov     es, ax
                xor     bx, bx
                mov     cx, n
                shl     cx, 1
@@b:            cmp     bx, cx
                jae     @@out
                mov     si, bx
                shr     si, 1
                add     si, offset src
                mov     al, ds:[si]
                mov     di, offset expect
                add     di, bx
                mov     es:[di], al
                inc     bx
                jmp     @@b
@@out:          ret
expect_dup      endp

;;:::::::::::::: buf vs expect over n bytes -> bad
cmpexp          proc    near private uses ax cx si di ds es,
                        buf:word, n:word
                mov     bad, 0
                mov     ax, @data
                mov     ds, ax
                mov     es, ax
                mov     si, buf
                mov     di, offset expect
                mov     cx, n
                jcxz    @@out
@@b:            mov     al, ds:[si]
                cmp     al, es:[di]
                je      @F
                inc     bad
@@:             inc     si
                inc     di
                loop    @@b
@@out:          mov     ax, bad
                ret
cmpexp          endp

;;:::::::::::::: fill dsta and dstb with a byte
wipe            proc    near private uses ax cx di es
                mov     ax, @data
                mov     es, ax
                mov     di, offset dsta
                mov     cx, DSTB
                mov     al, 0AAh
                rep     stosb
                mov     di, offset dstb
                mov     cx, DSTB
                mov     al, 0AAh
                rep     stosb
                ret
wipe            endp

;;:::::::::::::: dsta vs dstb over n bytes -> bad
cmpbuf          proc    near private uses ax cx si di ds es,
                        n:word
                mov     bad, 0
                mov     ax, @data
                mov     ds, ax
                mov     es, ax
                mov     si, offset dsta
                mov     di, offset dstb
                mov     cx, n
                jcxz    @@out
@@b:            mov     al, ds:[si]
                cmp     al, es:[di]
                je      @F
                inc     bad
@@:             inc     si
                inc     di
                loop    @@b
@@out:          mov     ax, bad
                ret
cmpbuf          endp

tmain           proc    far public uses ax bx cx dx si di ds es
                mov     ax, @data
                mov     ds, ax
                mov     es, ax

                ;; a source whose every byte differs from its neighbours,
                ;; so a copy that drops or repeats one shows up
                mov     di, offset src
                mov     cx, SRCB
                xor     al, al
@@fill:         stosb
                inc     al
                loop    @@fill

                ;;
                ;; STAGE ONE, the decision screen: one representative
                ;; ALIGNED 4 KiB copy and one aligned exact-2x expand,
                ;; each checked against the index oracle. The alignment
                ;; matrix, canaries, overlap and the VGA destination are
                ;; only worth building if MOVQ wins here.
                ;;
                call    wipe
                mov     ax, @data
                mov     ds, ax
                mov     es, ax
                mov     si, offset src
                mov     di, offset dsta
                mov     cx, SRCB
                call    qgl$RunCopy

                mov     ax, @data
                mov     ds, ax
                mov     es, ax
                mov     si, offset src
                mov     di, offset dstb
                mov     cx, SRCB
                call    copy_movq

                invoke  expect_copy, SRCB
                invoke  cmpexp, offset dstb, SRCB
                mov     bx, bad
                invoke  cmpexp, offset dsta, SRCB
                add     bx, bad                 ;; both arms against truth
                invoke  tchk, offset n_copy, bx, 0

                call    wipe
                mov     ax, @data
                mov     ds, ax
                mov     es, ax
                mov     si, offset src
                mov     di, offset dsta
                mov     cx, 2048
                call    dup_scalar

                mov     ax, @data
                mov     ds, ax
                mov     es, ax
                mov     si, offset src
                mov     di, offset dstb
                mov     cx, 2048
                call    dup_mmx

                invoke  expect_dup, 2048
                invoke  cmpexp, offset dsta, 4096
                mov     bx, bad
                invoke  tchk, offset n_sdup, bx, 0
                invoke  cmpexp, offset dstb, 4096
                invoke  tchk, offset n_dup, bad, 0

                ;;
                ;; and the timings, interleaved
                ;;
                mov     di, ROUNDS
                ;; THE 2x PAIR ONLY. The copy arm is settled and lost:
                ;; movq 5 against rep movsd 3 on the first screen, so it
                ;; is not expanded here. Its exactness check above stays.
@@round:        test    di, 1
                jz      @@bfirst
                invoke  time_dup,  0, offset q_s2x
                invoke  time_dup,  1, offset q_m2x
                jmp     @@rnext
@@bfirst:       invoke  time_dup,  1, offset q_m2x
                invoke  time_dup,  0, offset q_s2x
@@rnext:        dec     di
                jnz     @@round
                ret
tmain           endp

time_copy       proc    near private uses ax bx cx dx si di,
                        arm:word, nam:word
                call    bnow
                mov     word ptr t0, ax
                mov     word ptr t0+2, dx
                mov     rv, REPS
@@rep:          mov     bx, LOOPS
@@one:          push    bx
                mov     ax, @data
                mov     ds, ax
                mov     es, ax
                mov     si, offset src
                mov     di, offset dsta
                mov     cx, SRCB
                cmp     arm, 0
                jne     @F
                call    qgl$RunCopy
                jmp     @@onext
@@:             call    copy_movq
@@onext:        pop     bx
                dec     bx
                jnz     @@one
                dec     rv
                jnz     @@rep
                call    bnow
                sub     ax, word ptr t0
                sbb     dx, word ptr t0+2
                mov     word ptr shown, ax
                mov     word ptr shown+2, dx
                invoke  tshow, nam, shown
                xor     bx, bx
                cmp     word ptr shown+2, 0
                jne     @F
                cmp     word ptr shown, 20
                jb      @@short
@@:             inc     bx
@@short:        invoke  tchk, offset n_dur, bx, 1
                ret
time_copy       endp

time_dup        proc    near private uses ax bx cx dx si di,
                        arm:word, nam:word
                call    bnow
                mov     word ptr t0, ax
                mov     word ptr t0+2, dx
                mov     rv, REPS
@@rep:          mov     bx, LOOPS
@@one:          push    bx
                mov     ax, @data
                mov     ds, ax
                mov     es, ax
                mov     si, offset src
                mov     di, offset dsta
                mov     cx, 2048
                cmp     arm, 0
                jne     @F
                call    dup_scalar
                jmp     @@onext
@@:             call    dup_mmx
@@onext:        pop     bx
                dec     bx
                jnz     @@one
                dec     rv
                jnz     @@rep
                call    bnow
                sub     ax, word ptr t0
                sbb     dx, word ptr t0+2
                mov     word ptr shown, ax
                mov     word ptr shown+2, dx
                invoke  tshow, nam, shown
                xor     bx, bx
                cmp     word ptr shown+2, 0
                jne     @F
                cmp     word ptr shown, 20
                jb      @@short
@@:             inc     bx
@@short:        invoke  tchk, offset n_dur, bx, 1
                ret
time_dup        endp
                end
