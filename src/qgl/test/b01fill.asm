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

qgl_dr_fill     proto   far :dword, :word, :word, :word, :word, :word
qgl_rs_tex      proto   far :dword
qgl_rs_mode     proto   far :word
qgl_sf_wr_row   proto   far :dword, :word

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

;; a gradient that walks the whole texture across the span
DUDX            equ     (TEXW * 10000h) / SPANW
DVDX            equ     (TEXH * 10000h) / SPANW

.data
n_same          db      'both fillers draw alike$'
m2              db      'B qgl arm ran          $'
n_qgl           db      'qgl  ticks             $'
n_mgl           db      'mgl  ticks             $'

dst             dd      0
tex             dd      0
rowo            dw      0
rows            dw      0
qbuf            db      SPANW dup (0)           ;; qgl's span, copied out
showv           dd      0
t0              dd      0

;; BOTH ARMS CLOBBER bp -- qgl's with the filler's address, mgl's with
;; tex_v_msk, which hlinet_fixup's contract demands -- and bp is the
;; frame pointer, so neither may read a parameter after it starts. They
;; are copied out here first and the frame is never touched again.
bn              dw      0
bseg            dw      0
bofs            dw      0
bfill           dw      0
reps            dw      0

.code

;;::::::::::::::
;; bnow -> dx:ax, rising, 0.84us a unit
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

                externdef qgl$fixup:near
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

                call    qgl$fixup
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

tmain           proc    far public uses bx cx dx si di es

                invoke  qgl_sf_init
                invoke  qgl_sf_new, DSTW, DSTH, SURF_CMEM, 0
                SAVEP   dst
                invoke  qgl_sf_new, TEXW, TEXH, SURF_CMEM, 0
                SAVEP   tex

                ;; a texture where no two texels agree, so a u or v error
                ;; cannot hide
                xor     si, si
@@ty:           cmp     si, TEXH
                jae     @@tdone
                xor     di, di
@@tx:           cmp     di, TEXW
                jae     @F
                mov     ax, si
                add     ax, di
                and     ax, 0FFh
                invoke  qgl_sf_pset, tex, di, si, ax
                inc     di
                jmp     @@tx
@@:             inc     si
                jmp     @@ty
@@tdone:
                invoke  qgl_rs_tex, tex
                invoke  qgl_rs_mode, QGL_M_TEX
                mov     qgl$zmode, QGL_Z_OFF
                mov     D qgl$dudx, DUDX
                mov     D qgl$dvdx, DVDX

                invoke  qgl_sf_wr_row, dst, 0
                mov     rowo, ax
                mov     rows, dx

                ;;
                ;; 1. the same picture, or none of the rest means anything
                ;;
                invoke  qgl_dr_fill, dst, 0, 0, DSTW-1, DSTH-1, 0
                invoke  qgl_arm, 1, rows, rowo
                mov     si, rowo
                mov     di, offset qbuf
                mov     cx, SPANW
                push    ds
                mov     ds, rows
                push    es
                mov     ax, @data
                mov     es, ax
                cld
                rep     movsb
                pop     es
                pop     ds

                invoke  qgl_dr_fill, dst, 0, 0, DSTW-1, DSTH-1, 0
                invoke  mgl_arm, 1, rows, rowo
                mov     si, offset qbuf
                mov     di, rowo
                mov     cx, SPANW
                mov     ax, 0
                mov     es, rows
@@cmp:          mov     bl, ds:[si]
                cmp     bl, es:[di]
                je      @F
                inc     ax
@@:             inc     si
                inc     di
                loop    @@cmp
                CHK     n_same, ax, 0

                ;;
                ;; 2. and now the clock, alternating
                ;;
                mov     si, ROUNDS
@@round:        call    bnow
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
                invoke  tshow, offset n_qgl, showv

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
                invoke  tshow, offset n_mgl, showv

                dec     si
                jnz     @@round
                ret
tmain           endp
                end
