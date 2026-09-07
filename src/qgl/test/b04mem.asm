;; b04mem -- what one render target costs, per pool, in both storage kinds.
;;
;; b03 answered the FONT path. This answers the SURFACE path: the
;; conventional and EMS a single destination takes, at the sizes the
;; renderer creates, on both sides.
;;
;; THE METHOD IS THE POINT, and it is what the previous version got
;; wrong. Six allocations ran back to back in one fixed order, each free
;; feeding the next allocation's list, and the output was absolute
;; free-memory readings that the reader subtracted by hand. So:
;;
;;   - every case runs BOTH orders, qgl-first and mgl-first, and the two
;;     must agree, in BOTH pools. Disagreement is the finding, not
;;     noise: it says the number belongs to the sequence rather than to
;;     the allocation.
;;   - deltas are reported, not raw readings, one allocation at a time.
;;   - every block is freed and RESAMPLED. Recovery must be exact;
;;     a residual is a failure, not a footnote. b03 found 80 bytes only
;;     because it looked.
;;   - LARGEST is sampled before, after and post-free and printed as
;;     three numbers under a fragmentation label. No conclusion is drawn
;;     from it and it is never called footprint -- it is the shape of the
;;     free list, which is what an ordered sequence perturbs. e1m1 dies
;;     on a largest-block failure, so the signal is kept, not read.
;;   - emsAvail is TOTAL FREE EMS CAPACITY, in 16K pages and bytes.
;;     Never largest-free.
;;
;; A FAILED ALLOCATION ABORTS ITS RECORD. CHK notes a failure and keeps
;; going, so a null pointer would otherwise be dereferenced for its
;; stride, freed, and turned into a plausible-looking delta. Each record
;; carries a validity flag and every check that reads one requires it.
;;
;; No timing. Surfaces are created at load, not per frame, and a timed
;; allocation would measure the DOS allocator rather than either library.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglMemAvail   proto   far :word
qglSfNewEx   proto   far :word, :word, :word, :word, :word
qglSfAdoptDc proto   far :dword, :dword
qglZNew       proto   far :dword, :word, :word
qglZFree      proto   far :dword
uglInit         proto   far
uglEnd          proto   far
uglNew          proto   far :word, :word, :word, :word
uglNewZ         proto   far :dword, :word
uglDel          proto   far :dword
emsAvail        proto   far

DC_MEM          equ     0
DC_EMS          equ     128             ;; 2 * MGL's 64-byte DC type stride
FMT_8BIT        equ     0
DC_BPS          equ     10              ;; mgl's bytes-per-scanline field

ARM_QGL         equ     0
ARM_MGL         equ     1

K_CMEM          equ     0
K_EMS           equ     1
K_DEPTH         equ     2

SF_HDR          equ     16              ;; SIZEOF Surface: the header a
                                        ;; RETURNED qgl cmem surface adds.
                                        ;; It is qgl's model and is not
                                        ;; applied to mgl.
QGL_COLD_CONV   equ     32              ;; Surface header 16 + DOS MCB 16
MGL_COLD_FIX    equ     1120            ;; T DC 32 + bas_malloc rounding
                                        ;; + em$HeapNew's 1024-byte blockTB,
                                        ;; each with its own MCB. The 4*h
                                        ;; addrTB is added per record.

;; one record per arm per order
RC_CONV         equ     0               ;; dword
RC_EMS          equ     4               ;; dword
RC_STR          equ     8               ;; word, the stride it really got
RC_OK           equ     10              ;; word, 1 when the record is real
RC_SIZE         equ     12

.data
n_init          db      'mgl initialized       $'
n_ok            db      'allocation succeeded  $'
n_crec          db      'conv fully recovered  $'
n_erec          db      'EMS fully recovered   $'
n_ordc          db      'orders agree: conv    $'
n_orde          db      'orders agree: EMS     $'
n_minsz         db      'qgl delta >= px+16    $'
n_mfloor        db      'mgl delta >= strd*rows$'
n_emszero       db      'cmem takes no EMS     $'
n_ccold         db      'cold conv exact       $'
n_ecold         db      'cold EMS exact        $'
n_extern        db      'MGL 1MiB EXTERNAL heap$'
n_valid         db      'record is usable      $'
n_pnn           db      'parent DC non-null    $'
n_padopt        db      'parent adopted        $'
n_pxres         db      'parent x_res 160      $'
n_pyres         db      'parent y_res 100      $'
n_ppitch        db      'parent pitch valid    $'
n_q256          db      'qgl 256 stride is 256 $'
n_m256          db      'mgl 256 stride is 256 $'
n_strd          db      'matched stride is 256 $'
n_enz           db      'EMS delta nonzero     $'
n_ealign        db      'EMS delta page aligned$'
n_epages        db      'EMS pages >= rows*strd$'
n_mpad          db      'mgl row padding bytes $'
n_mdesc         db      'mgl over pixel storage$'

n_case          db      'case                  $'
n_rec           db      'rec case:arm:order    $'
n_cbv           db      '  conv before         $'
n_crv           db      '  conv postfree       $'
n_cdv           db      '  conv residual b-r   $'
n_ebv           db      '  EMS  before         $'
n_erv           db      '  EMS  postfree       $'
n_edv           db      '  EMS  residual b-r   $'
n_qc            db      'qgl conv delta        $'
n_mc            db      'mgl conv delta        $'
n_qe            db      'qgl EMS delta bytes   $'
n_me            db      'mgl EMS delta bytes   $'
n_qep           db      'qgl EMS delta 16K pgs $'
n_mep           db      'mgl EMS delta 16K pgs $'
n_qs            db      'qgl stride measured   $'
n_ms            db      'mgl stride measured   $'
n_exp           db      'qgl expected px+16    $'
n_mover         db      'mgl over pixels       $'
n_lb            db      'frag LARGEST before   $'
n_la            db      'frag LARGEST after    $'
n_lf            db      'frag LARGEST postfree $'
n_zlog          db      'qgl depth logical row $'
n_qstat         db      'caller static: return $'
n_bstat         db      'caller static: adopt  $'

cb              dd      0               ;; conv before
ca              dd      0
cr              dd      0
eb              dd      0               ;; EMS before
ea              dd      0
er              dd      0
v               dd      0
p               dd      0

rq1             db      RC_SIZE dup (0) ;; qgl, qgl-first
rm1             db      RC_SIZE dup (0) ;; mgl, qgl-first
rm2             db      RC_SIZE dup (0) ;; mgl, mgl-first
rq2             db      RC_SIZE dup (0) ;; qgl, mgl-first

parent          dd      0               ;; the retained mgl MEM DC
padopt          dd      0
psurf           Surface <>              ;; 16 bytes, caller-side static
pgood           dw      0               ;; the depth fixture is usable
okflag          dw      0               ;; survives CHK, which clobbers ax
okflag2         dw      0
need            dd      0

.code

conv_now        proc    near private
                invoke  qglMemAvail, MEM_TOTAL
                ret
conv_now        endp

ems_now         proc    near private
                invoke  emsAvail
                ret
ems_now         endp


;;::::::::::::::
;; alloc_arm ( arm:word, kind:word, w:word, h:word, strd:word ) -> p
;;::::::::::::::
alloc_arm       proc    near private uses bx cx dx si di,\
                        arm:word, kind:word, w:word, h:word, strd:word

                cmp     kind, K_DEPTH
                jne     @@surf
                cmp     arm, ARM_QGL
                jne     @@mz
                invoke  qglZNew, padopt, SURF_EMS, 0
                jmp     @@save
@@mz:           invoke  uglNewZ, parent, DC_EMS
                jmp     @@save

@@surf:         cmp     arm, ARM_QGL
                jne     @@mgl
                cmp     kind, K_EMS
                jne     @@qcm
                invoke  qglSfNewEx, w, h, strd, SURF_EMS, 0
                jmp     @@save
@@qcm:          invoke  qglSfNewEx, w, h, w, SURF_CMEM, 0
                jmp     @@save

@@mgl:          cmp     kind, K_EMS
                jne     @@mcm
                invoke  uglNew, DC_EMS, FMT_8BIT, w, h
                jmp     @@save
@@mcm:          invoke  uglNew, DC_MEM, FMT_8BIT, w, h

@@save:         mov     W p, ax
                mov     W p+2, dx
                ret
alloc_arm       endp


free_arm        proc    near private uses ax bx cx dx si di,\
                        arm:word, kind:word
                cmp     kind, K_DEPTH
                jne     @@surf
                cmp     arm, ARM_QGL
                jne     @@md
                invoke  qglZFree, p
                ret
@@md:           invoke  uglDel, addr p
                ret
@@surf:         cmp     arm, ARM_QGL
                jne     @@mf
                invoke  qglSfFree, p
                ret
@@mf:           invoke  uglDel, addr p
                ret
free_arm        endp


;;::::::::::::::
;; run_case ( arm, kind, w, h, strd, rec:word )
;;
;; One allocation, measured end to end. On a null allocation the record
;; is marked unusable and NOTHING is dereferenced, freed or stored:
;; CHK reports and returns, so without this guard the next line would
;; read a stride through a null far pointer.
;;::::::::::::::
run_case        proc    near private uses ax bx cx dx si di es,\
                        arm:word, kind:word, w:word, h:word,\
                        strd:word, rec:word, csx:word, ord:word

                ;; (case, arm, order), so every line below can be
                ;; attributed without counting from the top of the output
                mov     ax, csx
                mov     cl, 8
                shl     ax, cl
                mov     bx, arm
                mov     cl, 4
                shl     bx, cl
                or      ax, bx
                or      ax, ord
                xor     dx, dx
                SAVEP   v
                invoke  tshow, offset n_rec, v

                mov     di, rec
                mov     W [di+RC_OK], 0
                mov     W [di+RC_CONV], 0
                mov     W [di+RC_CONV+2], 0
                mov     W [di+RC_EMS], 0
                mov     W [di+RC_EMS+2], 0
                mov     W [di+RC_STR], 0

                invoke  qglMemAvail, MEM_LARGEST
                SAVEP   v
                invoke  tshow, offset n_lb, v

                call    conv_now
                mov     W cb, ax
                mov     W cb+2, dx
                call    ems_now
                mov     W eb, ax
                mov     W eb+2, dx

                invoke  alloc_arm, arm, kind, w, h, strd
                mov     ax, W p
                or      ax, W p+2
                NZ      ax
                CHK     n_ok, ax, 1
                mov     bx, W p
                or      bx, W p+2
                jnz     @@live
                ret                             ;; abort the record

@@live:         call    conv_now
                mov     W ca, ax
                mov     W ca+2, dx
                call    ems_now
                mov     W ea, ax
                mov     W ea+2, dx

                invoke  qglMemAvail, MEM_LARGEST
                SAVEP   v
                invoke  tshow, offset n_la, v

                ;; the stride each side actually chose -- measured, never
                ;; assumed: b07 caught a 400-wide mgl DC at stride 440
                les     bx, p
                cmp     arm, ARM_QGL
                jne     @@mstr
                mov     ax, es:[bx].Surface.stride
                jmp     @@gotstr
@@mstr:         mov     ax, es:[bx+DC_BPS]
@@gotstr:       mov     di, rec
                mov     [di+RC_STR], ax
                xor     dx, dx
                SAVEP   v
                mov     bx, offset n_qs
                cmp     arm, ARM_QGL
                je      @F
                mov     bx, offset n_ms
@@:             invoke  tshow, bx, v

                invoke  free_arm, arm, kind

                ;; THE PROBE COMES FIRST, as it does before the
                ;; allocation. INT 21h/48h with BX=FFFF is a failing
                ;; ALLOCATION request: DOS walks the MCB chain and
                ;; coalesces adjacent free blocks while servicing it.
                ;; Sampling cr ahead of it caught the chain un-coalesced
                ;; and read one paragraph short per block freed -- 16
                ;; for qgl's one block, 32 for mgl's two -- which is
                ;; what the 20 recovery failures were.
                invoke  qglMemAvail, MEM_LARGEST
                SAVEP   v
                invoke  tshow, offset n_lf, v

                call    conv_now
                mov     W cr, ax
                mov     W cr+2, dx
                call    ems_now
                mov     W er, ax
                mov     W er+2, dx

                ;; recovery is EQUALITY. A residual is a failure.
                mov     ax, 1
                mov     bx, W cr
                cmp     bx, W cb
                jne     @F
                mov     bx, W cr+2
                cmp     bx, W cb+2
                je      @@crok
@@:             xor     ax, ax
@@crok:         CHK     n_crec, ax, 1

                mov     ax, 1
                mov     bx, W er
                cmp     bx, W eb
                jne     @F
                mov     bx, W er+2
                cmp     bx, W eb+2
                je      @@erok
@@:             xor     ax, ax
@@erok:         CHK     n_erec, ax, 1

                ;; the numbers behind those two gates. Printed whatever
                ;; the gates said: a failing gate with no visible
                ;; residual is what made this run undiagnosable.
                mov     ax, W cb
                mov     dx, W cb+2
                SAVEP   v
                invoke  tshow, offset n_cbv, v
                mov     ax, W cr
                mov     dx, W cr+2
                SAVEP   v
                invoke  tshow, offset n_crv, v
                mov     ax, W cb
                sub     ax, W cr
                mov     dx, W cb+2
                sbb     dx, W cr+2
                SAVEP   v
                invoke  tshow, offset n_cdv, v

                mov     ax, W eb
                mov     dx, W eb+2
                SAVEP   v
                invoke  tshow, offset n_ebv, v
                mov     ax, W er
                mov     dx, W er+2
                SAVEP   v
                invoke  tshow, offset n_erv, v
                mov     ax, W eb
                sub     ax, W er
                mov     dx, W eb+2
                sbb     dx, W er+2
                SAVEP   v
                invoke  tshow, offset n_edv, v

                ;; both deltas stored, both pools
                mov     ax, W cb
                sub     ax, W ca
                mov     dx, W cb+2
                sbb     dx, W ca+2
                mov     di, rec
                mov     [di+RC_CONV], ax
                mov     [di+RC_CONV+2], dx
                SAVEP   v
                mov     bx, offset n_qc
                cmp     arm, ARM_QGL
                je      @F
                mov     bx, offset n_mc
@@:             invoke  tshow, bx, v

                mov     ax, W eb
                sub     ax, W ea
                mov     dx, W eb+2
                sbb     dx, W ea+2
                mov     di, rec
                mov     [di+RC_EMS], ax
                mov     [di+RC_EMS+2], dx
                SAVEP   v
                mov     bx, offset n_qe
                cmp     arm, ARM_QGL
                je      @F
                mov     bx, offset n_me
@@:             invoke  tshow, bx, v

                mov     ax, W v
                mov     dx, W v+2
                mov     cx, 14                  ;; bytes -> 16K pages
@@pg:           shr     dx, 1
                rcr     ax, 1
                loop    @@pg
                xor     dx, dx
                SAVEP   v
                mov     bx, offset n_qep
                cmp     arm, ARM_QGL
                je      @F
                mov     bx, offset n_mep
@@:             invoke  tshow, bx, v

                mov     di, rec
                mov     W [di+RC_OK], 1
                ret
run_case        endp


;;::::::::::::::
;; stride_is ( rec:word, want:word ) -- a matched case is only matched
;; if EVERY record got the same stride, not just the first of each arm.
;;::::::::::::::
stride_is       proc    near private uses ax bx cx dx si di,\
                        rec:word, want:word
                mov     si, rec
                mov     ax, [si+RC_OK]
                mov     okflag2, ax
                CHK     n_valid, ax, 1
                cmp     okflag2, 1
                jne     @@out
                mov     si, rec
                mov     ax, [si+RC_STR]
                CHK     n_strd, ax, want
@@out:          ret
stride_is       endp


;;::::::::::::::
;; pool_check ( rec:word, kind:word ) -- run for EVERY arm and order,
;; immediately, not once per case.
;;
;;   a cmem allocation must take no EMS at all
;;   an EMS or depth allocation costs each library a KNOWN cold amount,
;;   accounted for in mgl 0.23b: qgl 32, mgl 1120 + 4*h. The round
;;   "under 1K" that stood here was invented rather than measured, and
;;   mgl's real figure -- 1,920 for 200 rows -- is above it.
;;::::::::::::::
pool_check      proc    near private uses ax bx cx dx si di,\
                        rec:word, kind:word, h:word, arm:word

                mov     si, rec
                mov     ax, [si+RC_OK]
                mov     okflag, ax              ;; CHK clobbers ax
                CHK     n_valid, ax, 1
                cmp     okflag, 1
                jne     @@out

                mov     si, rec
                cmp     kind, K_CMEM
                jne     @@ems
                mov     ax, 1
                mov     bx, [si+RC_EMS]
                or      bx, [si+RC_EMS+2]
                jz      @F
                xor     ax, ax
@@:             CHK     n_emszero, ax, 1
                ret

                ;;
                ;; COLD CONVENTIONAL, exact, per arm. Not a threshold:
                ;; both numbers are accounted for in mgl 0.23b, and the
                ;; round 1024 that stood here was invented rather than
                ;; measured.
                ;;
                ;;   qgl  32          Surface header 16 + DOS MCB 16
                ;;   mgl  1120 + 4*h  T DC 32 + addrTB 4*h through
                ;;                    bas_malloc, plus em$HeapNew's
                ;;                    1024-byte blockTB
                ;;
@@ems:          mov     ax, QGL_COLD_CONV
                xor     dx, dx
                cmp     arm, ARM_QGL
                je      @@wantc
                mov     ax, h
                shl     ax, 2                   ;; 4 bytes an addrTB entry
                add     ax, MGL_COLD_FIX
                adc     dx, 0
@@wantc:        SAVEP   need

                mov     si, rec
                mov     cx, 1
                mov     bx, [si+RC_CONV]
                cmp     bx, W need
                jne     @F
                mov     bx, [si+RC_CONV+2]
                cmp     bx, W need+2
                je      @@ccok
@@:             xor     cx, cx
@@ccok:         CHK     n_ccold, cx, 1

                ;; the EMS side of an EMS or depth record, in full: it
                ;; must have taken EMS at all, taken it in whole 16K
                ;; pages, and taken at least as many as its own measured
                ;; rows need. Raw bytes and pages are already printed.
                mov     si, rec
                mov     ax, 1
                mov     bx, [si+RC_EMS]
                or      bx, [si+RC_EMS+2]
                jnz     @F
                xor     ax, ax
@@:             CHK     n_enz, ax, 1

                mov     si, rec
                mov     ax, 1
                mov     bx, [si+RC_EMS]
                and     bx, 3FFFh               ;; 16K - 1
                jz      @F
                xor     ax, ax
@@:             CHK     n_ealign, ax, 1

                ;;
                ;; COLD EMS, exact, per arm, and labelled for what each
                ;; number is:
                ;;
                ;;   qgl  ceil(stride*h / 16K) * 16K -- what it maps
                ;;   mgl  1 MiB                      -- HEAP_MIN, an
                ;;        EXTERNAL cold heap reservation. It is NOT this
                ;;        DC's consumption: the heap is shared, and it
                ;;        shows up per record here only because freeing
                ;;        the last block releases it again.
                ;;
                cmp     arm, ARM_QGL
                jne     @@mgle

                mov     si, rec
                mov     ax, [si+RC_STR]
                mul     h
                add     ax, 3FFFh
                adc     dx, 0
                mov     cx, 14                  ;; -> whole pages
@@cp:           shr     dx, 1
                rcr     ax, 1
                loop    @@cp
                mov     cx, 14                  ;; -> bytes again
@@cb2:          shl     ax, 1
                rcl     dx, 1
                loop    @@cb2
                SAVEP   need
                jmp     @@ecmp

@@mgle:         mov     W need, 0               ;; HEAP_MIN, 1 MiB
                mov     W need+2, 16
                invoke  tshow, offset n_extern, need

@@ecmp:         mov     si, rec
                mov     cx, 1
                mov     bx, [si+RC_EMS]
                cmp     bx, W need
                jne     @F
                mov     bx, [si+RC_EMS+2]
                cmp     bx, W need+2
                je      @@ecok
@@:             xor     cx, cx
@@ecok:         CHK     n_ecold, cx, 1
@@out:          ret
pool_check      endp


;;::::::::::::::
;; agree ( a:word, b:word ) -- the same arm from both orders, in BOTH
;; pools, reported separately so a conventional-only fault cannot hide
;; behind an EMS pass.
;;::::::::::::::
agree           proc    near private uses ax bx cx dx si di,\
                        a:word, b:word

                mov     si, a
                mov     di, b
                mov     ax, [si+RC_OK]
                and     ax, [di+RC_OK]
                mov     okflag, ax              ;; CHK clobbers ax
                CHK     n_valid, ax, 1
                cmp     okflag, 1
                jne     @@out
                mov     si, a
                mov     di, b

                mov     ax, 1
                mov     bx, [si+RC_CONV]
                cmp     bx, [di+RC_CONV]
                jne     @F
                mov     bx, [si+RC_CONV+2]
                cmp     bx, [di+RC_CONV+2]
                je      @@cok
@@:             xor     ax, ax
@@cok:          CHK     n_ordc, ax, 1

                mov     ax, 1
                mov     bx, [si+RC_EMS]
                cmp     bx, [di+RC_EMS]
                jne     @F
                mov     bx, [si+RC_EMS+2]
                cmp     bx, [di+RC_EMS+2]
                je      @@eok
@@:             xor     ax, ax
@@eok:          CHK     n_orde, ax, 1
@@out:          ret
agree           endp


;;::::::::::::::
;; qgl_floor ( rec:word, w:word, h:word ) -- a returned qgl cmem surface
;; carries its pixels plus a 16-byte Surface header, so its delta cannot
;; be less. The expected figure is printed beside the observed one, which
;; is paragraph-rounded.
;;::::::::::::::
qgl_floor       proc    near private uses ax bx cx dx si di,\
                        rec:word, w:word, h:word

                mov     si, rec
                mov     ax, [si+RC_OK]
                cmp     ax, 1
                jne     @@out

                mov     ax, w
                mul     h
                add     ax, SF_HDR
                adc     dx, 0
                SAVEP   v
                invoke  tshow, offset n_exp, v

                mov     cx, 1
                mov     bx, [si+RC_CONV+2]
                cmp     bx, W v+2
                ja      @@ok
                jb      @@no
                mov     bx, [si+RC_CONV]
                cmp     bx, W v
                jae     @@ok
@@no:           xor     cx, cx
@@ok:           CHK     n_minsz, cx, 1
@@out:          ret
qgl_floor       endp


;;::::::::::::::
;; mgl_floor ( rec:word, w:word, h:word ) -- mgl's descriptor and its
;; scanline table are ITS business, so qgl's 16-byte header model is not
;; applied here. The floor is the pixels alone, and what it takes above
;; them is printed as its own figure.
;;::::::::::::::
mgl_floor       proc    near private uses ax bx cx dx si di,\
                        rec:word, w:word, h:word

                mov     si, rec
                mov     ax, [si+RC_OK]
                cmp     ax, 1
                jne     @@out

                ;; mgl's PHYSICAL pixel storage is its own measured
                ;; stride times the rows, not w*h: a padded scanline is
                ;; storage, not descriptor. b07 measured a 400-wide DC at
                ;; stride 440, which is 8,000 bytes of padding alone.
                mov     ax, [si+RC_STR]
                mul     h
                SAVEP   v

                mov     cx, 1
                mov     bx, [si+RC_CONV+2]
                cmp     bx, W v+2
                ja      @@ok
                jb      @@no
                mov     bx, [si+RC_CONV]
                cmp     bx, W v
                jae     @@ok
@@no:           xor     cx, cx
@@ok:           CHK     n_mfloor, cx, 1

                ;; row padding, reported on its own
                mov     si, rec
                mov     ax, [si+RC_STR]
                sub     ax, w
                mul     h
                SAVEP   v
                invoke  tshow, offset n_mpad, v

                ;; and what it takes ABOVE its physical storage, which is
                ;; the descriptor and scanline table
                mov     si, rec
                mov     ax, [si+RC_STR]
                mul     h
                mov     bx, ax
                mov     cx, dx
                mov     ax, [si+RC_CONV]
                mov     dx, [si+RC_CONV+2]
                sub     ax, bx
                sbb     dx, cx
                SAVEP   v
                invoke  tshow, offset n_mdesc, v
@@out:          ret
mgl_floor       endp


;;::::::::::::::
;; mutate_delta -- nothing, in the shipped harness.
;;
;; The seam a controlled mutation is applied at, kept so a mutated build
;; differs from this one in one procedure and not in the samples, the
;; gates or the arms.
;;
;; Proven with it enabled -- the qgl-first 320x200 CMEM record's stored
;; CONVENTIONAL delta forced to zero after its samples were taken, so
;; the EMS delta, the stride, the validity flag and every raw sample
;; stayed untouched: exactly `qgl delta >= px+16` and
;; `orders agree: conv` failed, exit 2.
;;::::::::::::::
mutate_delta    proc    near private
                ret
mutate_delta    endp


;;::::::::::::::
;; cmem_case ( w:word, h:word ) -- both orders, both arms, every check
;; run per record.
;;::::::::::::::
cmem_case       proc    near private uses ax bx cx dx si di,\
                        w:word, h:word, csx:word

                invoke  run_case, ARM_QGL, K_CMEM, w, h, 0, offset rq1, csx, 0
                invoke  pool_check, offset rq1, K_CMEM, h, ARM_QGL
                invoke  run_case, ARM_MGL, K_CMEM, w, h, 0, offset rm1, csx, 0
                invoke  pool_check, offset rm1, K_CMEM, h, ARM_MGL
                invoke  run_case, ARM_MGL, K_CMEM, w, h, 0, offset rm2, csx, 1
                invoke  pool_check, offset rm2, K_CMEM, h, ARM_MGL
                invoke  run_case, ARM_QGL, K_CMEM, w, h, 0, offset rq2, csx, 1
                invoke  pool_check, offset rq2, K_CMEM, h, ARM_QGL
                ret
cmem_case       endp


;;::::::::::::::
;; cmem_checks ( w:word, h:word ) -- the floors on EVERY record and both
;; order comparisons.
;;::::::::::::::
cmem_checks     proc    near private uses ax bx cx dx si di,\
                        w:word, h:word

                invoke  qgl_floor, offset rq1, w, h
                invoke  qgl_floor, offset rq2, w, h
                invoke  mgl_floor, offset rm1, w, h
                invoke  mgl_floor, offset rm2, w, h
                invoke  agree, offset rq1, offset rq2
                invoke  agree, offset rm1, offset rm2
                ret
cmem_checks     endp


;;::::::::::::::
;; ems_case ( w:word, h:word, qstrd:word ) -- both orders, both arms.
;;::::::::::::::
ems_case        proc    near private uses ax bx cx dx si di,\
                        w:word, h:word, qstrd:word, csx:word

                invoke  run_case, ARM_QGL, K_EMS, w, h, qstrd, offset rq1, csx, 0
                invoke  pool_check, offset rq1, K_EMS, h, ARM_QGL
                invoke  run_case, ARM_MGL, K_EMS, w, h, qstrd, offset rm1, csx, 0
                invoke  pool_check, offset rm1, K_EMS, h, ARM_MGL
                invoke  run_case, ARM_MGL, K_EMS, w, h, qstrd, offset rm2, csx, 1
                invoke  pool_check, offset rm2, K_EMS, h, ARM_MGL
                invoke  run_case, ARM_QGL, K_EMS, w, h, qstrd, offset rq2, csx, 1
                invoke  pool_check, offset rq2, K_EMS, h, ARM_QGL
                invoke  agree, offset rq1, offset rq2
                invoke  agree, offset rm1, offset rm2
                ret
ems_case        endp


tmain           proc    far public uses ax bx cx dx si di es

                invoke  qglSfInit
                invoke  uglInit
                NZ      ax
                CHK     n_init, ax, 1

                ;; ---- 160x100 CMEM: the shipped backbuffer, vid.bas:104
                mov     W v, 160
                mov     W v+2, 100
                invoke  tshow, offset n_case, v
                invoke  cmem_case, 160, 100, 0
                invoke  cmem_checks, 160, 100

                ;; ---- 320x200 CMEM: a configurable stress case,
                ;;      video-DC adjacent. NOT "the mode" -- the mode
                ;;      goes through uglSetVideoDC and allocates no such
                ;;      surface.
                mov     W v, 320
                mov     W v+2, 200
                invoke  tshow, offset n_case, v
                invoke  run_case, ARM_QGL, K_CMEM, 320, 200, 0, offset rq1, 1, 0
                call    mutate_delta            ;; no-op unless mutated
                invoke  pool_check, offset rq1, K_CMEM, 200, ARM_QGL
                invoke  run_case, ARM_MGL, K_CMEM, 320, 200, 0, offset rm1, 1, 0
                invoke  pool_check, offset rm1, K_CMEM, 200, ARM_MGL
                invoke  run_case, ARM_MGL, K_CMEM, 320, 200, 0, offset rm2, 1, 1
                invoke  pool_check, offset rm2, K_CMEM, 200, ARM_MGL
                invoke  run_case, ARM_QGL, K_CMEM, 320, 200, 0, offset rq2, 1, 1
                invoke  pool_check, offset rq2, K_CMEM, 200, ARM_QGL
                invoke  cmem_checks, 320, 200

                ;; ---- 256x200 EMS: THE API COMPARISON. 256 is a power
                ;;      of two, so both libraries take the same stride.
                ;;      "Matched" is ASSERTED, on the real records.
                mov     W v, 256
                mov     W v+2, 200
                invoke  tshow, offset n_case, v
                invoke  ems_case, 256, 200, 256, 2
                invoke  stride_is, offset rq1, 256
                invoke  stride_is, offset rm1, 256
                invoke  stride_is, offset rm2, 256
                invoke  stride_is, offset rq2, 256

                ;; ---- 320x200 EMS: MODE-SHAPED POLICY AND STRESS.
                ;;      Nothing ships this surface. qgl refuses a
                ;;      non-power-of-two stride outright, so it takes 512
                ;;      where mgl takes its own; the excess is ROW-MAPPING
                ;;      POLICY COST, not allocator overhead, and it shows
                ;;      up in the measured strides rather than the label.
                mov     W v, 320
                mov     W v+2, 200
                invoke  tshow, offset n_case, v
                invoke  ems_case, 320, 200, 512, 3

                ;; ---- 160x100 DEPTH: THE PRODUCTION EMS PAIR.
                ;;      main.bas:910 does uglNewZ( h_dst_dc, UGL.EMS )
                ;;      over the shipped backbuffer.
                ;;
                ;;      qglZNew shapes from a Surface and uglNewZ from
                ;;      a DC, so one retained MEM DC is adopted and both
                ;;      arms shape from that same parent. EVERYTHING here
                ;;      is gated on the parent: a descriptor read through
                ;;      a failed adoption is worse than no measurement.
                mov     pgood, 0
                invoke  uglNew, DC_MEM, FMT_8BIT, 160, 100
                SAVEP   parent
                mov     ax, W parent
                or      ax, W parent+2
                NZ      ax
                CHK     n_pnn, ax, 1
                mov     bx, W parent
                or      bx, W parent+2
                jz      @@nodepth

                mov     W padopt, offset psurf
                mov     W padopt+2, ds
                ;; ONE cumulative flag: adoption AND x AND y AND
                ;; pitch. Each CHK clobbers ax, so each answer is folded
                ;; into pgood before its CHK runs and the depth arms
                ;; consume the total.
                mov     pgood, 1
                invoke  qglSfAdoptDc, parent, padopt
                NZ      ax
                mov     okflag, ax
                CHK     n_padopt, ax, 1
                cmp     okflag, 1
                je      @F
                mov     pgood, 0
@@:
                mov     bx, offset psurf
                mov     ax, [bx].Surface.x_res
                mov     okflag, 1
                cmp     ax, 160
                je      @F
                mov     okflag, 0
@@:             CHK     n_pxres, ax, 160
                cmp     okflag, 1
                je      @F
                mov     pgood, 0
@@:
                mov     bx, offset psurf
                mov     ax, [bx].Surface.y_res
                mov     okflag, 1
                cmp     ax, 100
                je      @F
                mov     okflag, 0
@@:             CHK     n_pyres, ax, 100
                cmp     okflag, 1
                je      @F
                mov     pgood, 0
@@:
                mov     bx, offset psurf
                mov     ax, [bx].Surface.stride
                mov     cx, 1
                test    ax, ax
                jz      @F
                cmp     ax, [bx].Surface.x_res
                jae     @@pok
@@:             xor     cx, cx
@@pok:          mov     okflag, cx
                CHK     n_ppitch, cx, 1
                cmp     okflag, 1
                je      @F
                mov     pgood, 0
@@:
                cmp     pgood, 1
                jne     @@delparent

                ;; qgl derives 160 x 2 = 320 and then pads THAT to a
                ;; power of two so a row cannot straddle a 16K page. Two
                ;; facts, not one; mgl's own stride is measured, never
                ;; assumed to be 320.
                mov     W v, 320
                mov     W v+2, 0
                invoke  tshow, offset n_zlog, v

                mov     W v, 160
                mov     W v+2, 100
                invoke  tshow, offset n_case, v
                invoke  run_case, ARM_QGL, K_DEPTH, 160, 100, 0, offset rq1, 4, 0
                invoke  pool_check, offset rq1, K_DEPTH, 100, ARM_QGL
                invoke  run_case, ARM_MGL, K_DEPTH, 160, 100, 0, offset rm1, 4, 0
                invoke  pool_check, offset rm1, K_DEPTH, 100, ARM_MGL
                invoke  run_case, ARM_MGL, K_DEPTH, 160, 100, 0, offset rm2, 4, 1
                invoke  pool_check, offset rm2, K_DEPTH, 100, ARM_MGL
                invoke  run_case, ARM_QGL, K_DEPTH, 160, 100, 0, offset rq2, 4, 1
                invoke  pool_check, offset rq2, K_DEPTH, 100, ARM_QGL
                invoke  agree, offset rq1, offset rq2
                invoke  agree, offset rm1, offset rm2

@@delparent:    invoke  uglDel, addr parent
@@nodepth:
                ;; caller-side static, and ONLY caller-side: resident
                ;; code and DGROUP are excluded, since this harness does
                ;; no per-arm link-map accounting.
                mov     W v, 0                  ;; a returned surface owns its header
                mov     W v+2, 0
                invoke  tshow, offset n_qstat, v
                mov     W v, SF_HDR             ;; the adopt bridge does not
                mov     W v+2, 0
                invoke  tshow, offset n_bstat, v

                invoke  uglEnd
                ret
tmain           endp
                end
