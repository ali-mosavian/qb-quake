;; b01fill -- qgl's affine textured filler against mgl's, head to head.
;;
;; The same span, the same texture, the same destination bytes, in one
;; process, alternating A/B/A/B so host drift cannot land on one arm.
;; That is stricter than the six-interleaved-runs rule this repo sets for
;; comparing two BUILDS, because here both arms run inside a single run.
;;
;; IT CHECKS THE PICTURES FIRST. A speed comparison between two routines
;; that draw different things is not a measurement of anything, so both
;; fillers draw one span into the same buffer and the bytes must match
;; before a single tick is counted. That also puts qgl's fixup against
;; mgl's HLINET_SM_CALC on the arithmetic they share.
;;
;; TIMING IS BIOS TICKS, 18.2Hz, and the arms are long enough that 55ms
;; of quantisation does not matter. A finer timer was tried first --
;; latching PIT channel 0 for 0.84us -- and thrown away: its readings
;; clustered into two groups exactly 65536 units apart, one whole tick,
;; while the sub-tick part held to two parts in 65536. Reading the tick
;; on both sides of the latch and retrying did not change that, so it is
;; not a sampling race in this code; DOSBox does not advance the latched
;; counter and the tick together finely enough to combine them.
;;
;; That mattered: the spurious tick was 8% of the run, which is the size
;; of the difference it was about to be used to argue for. Coarse and
;; honest beats fine and wrong.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglDrFill     proto   far :dword, :word, :word, :word, :word, :word
qglRsTex      proto   far :dword
qglRsMode     proto   far :word
qglSfWrRow   proto   far :dword, :word

                externdef qgl$dudx:dword
                externdef qgl$dvdx:dword
                externdef qgl$tshift:word
                externdef qgl$tumsk:word
                externdef qgl$tvmsk:word
                externdef qgl$tofs:word
                externdef qgl$tseg:word
                externdef qgl$mode:word
                externdef qgl$zmode:word

DSTW            equ     320
DSTH            equ     4
TEXW            equ     64
TEXH            equ     64
SPANW           equ     256                     ;; pixels per call
LOOPS           equ     60000                   ;; spans per call of an arm
REPS            equ     4                       ;; arm calls per timed section
ROUNDS          equ     6

;; A gradient that walks the whole texture across the span in u, and HALF
;; of it in v.
;;
;; The two were equal, which made u and v indistinguishable: with u == v
;; at every pixel, swapping them -- or applying the row shift to the
;; wrong one -- produces identical bytes, and no oracle over this span
;; could ever see it. Different rates cost nothing and remove the blind
;; spot. The texel count per span is unchanged, so the timed work is too.
DUDX            equ     (TEXW * 10000h) / SPANW
DVDX            equ     (TEXH * 10000h) / (SPANW * 2)

.data
n_same          db      'both fillers draw alike$'
n_qok           db      'qgl span vs oracle     $'
n_mok           db      'mgl span vs oracle     $'
n_dur           db      'duration >= 20 ticks   $'
m2              db      'B qgl arm ran          $'
n_qgl           db      'qgl  ticks             $'
n_mgl           db      'mgl  ticks             $'
n_qmed          db      'qgl  median ticks      $'
n_mmed          db      'mgl  median ticks      $'

dst             dd      0
tex             dd      0
rowo            dw      0
rows            dw      0
qbuf            db      SPANW dup (0)           ;; qgl's span, copied out
mbuf            db      SPANW dup (0)           ;; mgl's, kept beside it
expect          db      SPANW dup (0)           ;; the oracle
showv           dd      0
t0              dd      0
qsamp           dd      ROUNDS dup (0)
msamp           dd      ROUNDS dup (0)
ssort           dd      ROUNDS dup (0)

;; BOTH ARMS CLOBBER bp -- qgl's with the filler's address, mgl's with
;; tex_v_msk, which hlinet_fixup's contract demands -- and bp is the
;; frame pointer, so neither may read a parameter after it starts. They
;; are copied out here first and the frame is never touched again.
bn              dw      0
bseg            dw      0
bofs            dw      0
bfill           dw      0
reps            dw      0
slot            dw      0

.code

;;::::::::::::::
;; bnow -> dx:ax, rising BIOS ticks (about 54.9ms each)
;;::::::::::::::
bnow            proc    near private uses bx cx es

                xor     cx, cx
                mov     es, cx
@@try:          mov     ax, es:[46Ch]           ;; the BIOS tick, 18.2Hz
                mov     dx, es:[46Eh]
                mov     bx, es:[46Ch]
                cmp     ax, bx
                jne     @@try                   ;; it rolled between halves
                ret
bnow            endp


                QGL_CODE

                externdef qgl$Fixup:near
                externdef b8_span:near

;;::::::::::::::
;; qgl_arm ( n:word ) -- n spans through qgl's chosen filler
;;
;; Far so the harness can reach it, but inside QGL_CODE so the call to
;; b8_span and the call to the filler it names both stay near.
;;::::::::::::::
qgl_arm         proc    far public uses bx cx dx si di bp ds es,\
                        n:word, dseg:word, dofs:word

                mov     ax, @data
                mov     fs, ax
                mov     ax, n
                mov     bn, ax
                mov     ax, dseg
                mov     bseg, ax
                mov     ax, dofs
                mov     bofs, ax                ;; the frame is done with

                call    qgl$Fixup
                call    b8_span
                mov     bfill, ax

@@again:        mov     bx, bfill
                mov     es, bseg
                mov     di, bofs
                mov     ds, qgl$tseg
                xor     ax, ax                  ;; x
                xor     ecx, ecx                ;; u
                xor     edx, edx                ;; v
                mov     si, SPANW
                call    bx
                mov     ax, fs
                mov     ds, ax
                dec     bn
                jnz     @@again
                ret
qgl_arm         endp

                QGL_ENDS


ugl_text        segment para public use16 'CODE'
                assume  cs:ugl_text

                externdef ul$hlinet8:near
                externdef ul$hlinet8_fxp:near

;;::::::::::::::
;; mgl_arm ( n:word ) -- the same n spans through ul$hlinet8
;;
;; hlinet_fixup's contract, from 8plxt.asm: bx= dudx_int, di= dudx_frc,
;; dx= dvdx_int, si= dvdx_frc, cl= tex_shift, ax= tex_u_msk,
;; bp= tex_v_msk, and tex_ofs pushed under the return address.
;;::::::::::::::
mgl_arm         proc    far public uses bx cx dx si di bp ds es,\
                        n:word, dseg:word, dofs:word

                mov     ax, @data
                mov     ds, ax
                mov     ax, n
                mov     bn, ax
                mov     ax, dseg
                mov     bseg, ax
                mov     ax, dofs
                mov     bofs, ax                ;; the frame is done with

                ;; HLINET_SM_CALC, shift 0, by hand
                mov     cx, qgl$tshift
                mov     ax, qgl$tumsk
                mov     bp, qgl$tvmsk
                mov     si, W qgl$dvdx+0
                mov     dx, W qgl$dvdx+2
                shl     dx, cl
                push    bp
                not     bp
                or      dx, bp
                pop     bp
                mov     di, W qgl$dudx+0
                mov     bx, W qgl$dudx+2

                push    qgl$tofs
                call    ul$hlinet8_fxp

@@again:        mov     es, bseg
                mov     di, bofs
                mov     ds, qgl$tseg
                xor     ax, ax
                xor     ecx, ecx
                xor     edx, edx
                mov     si, SPANW
                call    ul$hlinet8
                mov     ax, @data
                mov     ds, ax
                dec     bn
                jnz     @@again
                ret
mgl_arm         endp

ugl_text        ends


                .code

qgl_arm         proto   far :word, :word, :word
mgl_arm         proto   far :word, :word, :word

;;::::::::::::::
;; build_expect -- the span this test's own inputs imply, texel by texel.
;;
;; Derived from DUDX/DVDX and the seed the texture was written with, NOT
;; read back out of the texture and NOT obtained from either filler. That
;; is what makes it an oracle rather than a second opinion: it is still
;; correct on the day mgl is deleted.
;;
;;   u = x*DUDX, v = x*DVDX, both 16.16
;;   texel = seed( u>>16 and TEXW-1, v>>16 and TEXH-1 )
;;   seed( sx, sy ) = (sx*7 + sy*3) and 255
;;::::::::::::::
build_expect    proc    near private uses ax bx cx dx si di

                xor     si, si                  ;; x
@@px:           cmp     si, SPANW
                jae     @@out

                movzx   eax, si                 ;; u >> 16, wrapped
                imul    eax, DUDX
                shr     eax, 16
                and     ax, TEXW-1
                imul    ax, 7
                mov     bx, ax

                movzx   eax, si                 ;; v >> 16, wrapped
                imul    eax, DVDX
                shr     eax, 16
                and     ax, TEXH-1
                imul    ax, 3

                add     ax, bx
                mov     expect[si], al

                inc     si
                jmp     @@px
@@out:          ret
build_expect    endp


;;::::::::::::::
;; copy_span -- the drawn row out of the destination, into ds:di.
;;::::::::::::::
copy_span       proc    near private uses ax cx si di ds es

                mov     si, rowo
                mov     ax, @data
                mov     es, ax
                mov     ds, rows
                mov     cx, SPANW
                cld
                rep     movsb
                ret
copy_span       endp


;;::::::::::::::
;; cmp_span -- ds:si against ds:di, SPANW bytes, mismatches -> ax.
;;::::::::::::::
cmp_span        proc    near private uses bx cx si di

                xor     ax, ax
                mov     cx, SPANW
@@b:            mov     bl, [si]
                cmp     bl, [di]
                je      @F
                inc     ax
@@:             inc     si
                inc     di
                loop    @@b
                ret
cmp_span        endp


;;::::::::::::::
;; keepsamp ( nam:word, base:word, idx:word ) -- show one sample, assert it
;; clears the tick floor, and keep it for the median.
;;
;; The floor matters as much as the comparison: BIOS ticks are 54.9ms, so
;; an arm that finishes in two of them is being measured against the
;; clock's resolution and not against the other arm.
;;::::::::::::::
keepsamp          proc    near private uses ax bx cx dx si di,\
                        nam:word, base:word, idx:word

                invoke  tshow, nam, showv

                mov     bx, 1                   ;; assume it clears
                mov     dx, W showv+2
                test    dx, dx
                jnz     @@keep
                mov     ax, W showv
                cmp     ax, 20
                jae     @@keep
                xor     bx, bx
@@keep:         invoke  tchk, offset n_dur, bx, 1

                mov     di, base
                mov     ax, idx
                shl     ax, 2
                add     di, ax
                mov     ax, W showv
                mov     [di], ax
                mov     ax, W showv+2
                mov     [di+2], ax
                ret
keepsamp          endp


;;::::::::::::::
;; median ( base:word ) -> dx:ax -- the middle of ROUNDS samples.
;;
;; Six is even, so it is the mean of the two middle ones. Selection sort:
;; six elements, once, outside every timed region.
;;::::::::::::::
median          proc    near private uses bx cx si di,\
                        base:word

                mov     si, base                ;; copy out, sort in place
                mov     di, offset ssort
                mov     cx, ROUNDS*2
                push    ds
                pop     es
                cld
                rep     movsw

                xor     si, si                  ;; i, in bytes
@@i:            cmp     si, ROUNDS*4
                jae     @@mid
                mov     di, si                  ;; the smallest seen
                mov     bx, si
                add     bx, 4
@@j:            cmp     bx, ROUNDS*4
                jae     @@swap
                mov     eax, D ssort[bx]
                cmp     eax, D ssort[di]
                jae     @F
                mov     di, bx
@@:             add     bx, 4
                jmp     @@j
@@swap:         mov     eax, D ssort[si]
                mov     ecx, D ssort[di]
                mov     D ssort[si], ecx
                mov     D ssort[di], eax
                add     si, 4
                jmp     @@i

@@mid:          mov     eax, D ssort[(ROUNDS/2-1)*4]
                add     eax, D ssort[(ROUNDS/2)*4]
                shr     eax, 1
                mov     edx, eax
                shr     edx, 16
                ret
median          endp

tmain           proc    far public uses bx cx dx si di es

                invoke  qglSfInit
                invoke  qglSfNew, DSTW, DSTH, SURF_CMEM, 0
                SAVEP   dst
                invoke  qglSfNew, TEXW, TEXH, SURF_CMEM, 0
                SAVEP   tex

                ;; 4096 texels over 256 values must repeat, so this cannot
                ;; and does not make every texel unique. What it does is
                ;; make the repeats fall where a u or v error will not land:
                ;; the weights are different and coprime to the texture
                ;; size, so a shift along either axis changes the value.
                ;; x+y was symmetric, and a transposed fetch reads a
                ;; symmetric texture correctly -- the same blind spot the
                ;; gradients above had.
                xor     si, si
@@ty:           cmp     si, TEXH
                jae     @@tdone
                xor     di, di
@@tx:           cmp     di, TEXW
                jae     @F
                mov     ax, di
                imul    ax, 7
                mov     bx, si
                imul    bx, 3
                add     ax, bx
                and     ax, 0FFh
                invoke  qglSfPset, tex, di, si, ax
                inc     di
                jmp     @@tx
@@:             inc     si
                jmp     @@ty
@@tdone:
                invoke  qglRsTex, tex
                invoke  qglRsMode, QGL_M_TEX
                mov     qgl$zmode, QGL_Z_OFF
                mov     D qgl$dudx, DUDX
                mov     D qgl$dvdx, DVDX

                invoke  qglSfWrRow, dst, 0
                mov     rowo, ax
                mov     rows, dx

                ;;
                ;; 1. EACH filler against the oracle, separately.
                ;;
                ;; Not qgl against mgl: agreeing with the library we are
                ;; replacing is not evidence either is right, and every
                ;; such check dies with mgl. `expect` is built here from
                ;; the gradients and the seed this test chose, so it
                ;; stands on its own. The two arms are still compared,
                ;; afterwards and as an extra.
                ;;
                call    build_expect

                invoke  qglDrFill, dst, 0, 0, DSTW-1, DSTH-1, 0
                invoke  qgl_arm, 1, rows, rowo
                mov     di, offset qbuf
                call    copy_span               ;; qgl's row
                mov     si, offset qbuf
                mov     di, offset expect
                call    cmp_span
                CHK     n_qok, ax, 0

                invoke  qglDrFill, dst, 0, 0, DSTW-1, DSTH-1, 0
                invoke  mgl_arm, 1, rows, rowo
                mov     di, offset mbuf
                call    copy_span               ;; mgl's row
                mov     si, offset mbuf
                mov     di, offset expect
                call    cmp_span
                CHK     n_mok, ax, 0

                ;; and, as a secondary, that they agree with each other
                mov     si, offset qbuf
                mov     di, offset mbuf
                call    cmp_span
                CHK     n_same, ax, 0

                ;;
                ;; 2. and now the clock, alternating
                ;;
                mov     si, ROUNDS
@@round:        mov     ax, ROUNDS              ;; si counts down; slot counts up
                sub     ax, si
                mov     slot, ax
                call    bnow
                test    si, 1
                jz      @@mfirst
                mov     W t0, ax
                mov     W t0+2, dx
                mov     reps, REPS
@@qr:           invoke  qgl_arm, LOOPS, rows, rowo
                dec     reps
                jnz     @@qr
                call    bnow
                sub     ax, W t0
                sbb     dx, W t0+2
                mov     W showv, ax
                mov     W showv+2, dx
                invoke  keepsamp, offset n_qgl, offset qsamp, slot

                call    bnow
                mov     W t0, ax
                mov     W t0+2, dx
                mov     reps, REPS
@@mr:           invoke  mgl_arm, LOOPS, rows, rowo
                dec     reps
                jnz     @@mr
                call    bnow
                sub     ax, W t0
                sbb     dx, W t0+2
                mov     W showv, ax
                mov     W showv+2, dx
                invoke  keepsamp, offset n_mgl, offset msamp, slot
                jmp     @@next_round

@@mfirst:       mov     W t0, ax
                mov     W t0+2, dx
                mov     reps, REPS
@@mr2:          invoke  mgl_arm, LOOPS, rows, rowo
                dec     reps
                jnz     @@mr2
                call    bnow
                sub     ax, W t0
                sbb     dx, W t0+2
                mov     W showv, ax
                mov     W showv+2, dx
                invoke  keepsamp, offset n_mgl, offset msamp, slot

                call    bnow
                mov     W t0, ax
                mov     W t0+2, dx
                mov     reps, REPS
@@qr2:          invoke  qgl_arm, LOOPS, rows, rowo
                dec     reps
                jnz     @@qr2
                call    bnow
                sub     ax, W t0
                sbb     dx, W t0+2
                mov     W showv, ax
                mov     W showv+2, dx
                invoke  keepsamp, offset n_qgl, offset qsamp, slot

@@next_round:
                dec     si
                jnz     @@round

                ;; every sample is above, in the order it was taken; the
                ;; medians go last so the two numbers to compare are not
                ;; buried in twelve lines of samples
                invoke  median, offset qsamp
                mov     W showv, ax
                mov     W showv+2, dx
                invoke  tshow, offset n_qmed, showv
                invoke  median, offset msamp
                mov     W showv, ax
                mov     W showv+2, dx
                invoke  tshow, offset n_mmed, showv
                ret
tmain           endp
                end
