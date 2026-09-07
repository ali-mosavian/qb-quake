;; b05blit -- the public blit, qgl against mgl, with a SPEED BOUND that is
;;            part of the test rather than a number in a report.
;;
;; b01fill measured the private affine inner core at 1.0000x: qgl and mgl
;; fill pixels at the same rate. Every public primitive was nevertheless
;; slower, blit by 4.87x, so the whole difference was the boundary around
;; the loop and not the loop. That was a defect with a number attached,
;; and this is the test that holds the number.
;;
;; The bound is 2x. It is not fitted to a result -- it was chosen before
;; the work, from the inner core being equal: a public wrapper that costs
;; more than its own payload again has not been written the way mgl writes
;; one. uglBlit validates once, clips once, and calls ul$copy once for the
;; whole rectangle.
;;
;; BASELINE, the state this test was written against: qglDrBlit issued
;; two far calls PER ROW -- qglSfWrRow and qglSfRdRow, each
;; re-validating the surface and re-deriving an address that the previous
;; row had already computed -- and measured a median of 126 ticks against
;; mgl's 26. It now resolves both addresses once and advances them by the
;; stride, and measures 48.
;;
;; The bound is on the SUM, and a sum is a mean, not a median: it is not
;; robust to an outlier the way a median is, and the two do not order
;; arms identically in general. It is here because assembly can total
;; six numbers and cannot conveniently sort them. Every sample is still
;; printed under its own label, so the median is computed from the log
;; and the sum bound is a regression gate, not the evidence.
;;
;; CMEM ONLY. Both surfaces here are adopted mgl MEM DCs, which is what
;; the fast cursor path covers; an EMS surface still goes through the
;; generic per-row mapper and is not measured by this benchmark. Two
;; live EMS pointers can be invalidated by a remap, so that path does
;; not get a cursor until it has page-crossing and distinct rd/wr-slot
;; tests of its own.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglSfInit     proto   far
qglSfAdoptDc proto   far :dword, :dword
qglSfRdRow   proto   far :dword, :word
qglDrFill     proto   far :dword, :word, :word, :word, :word, :word
qglDrBlit     proto   far :dword, :word, :word, :dword
qglSfPget     proto   far :dword, :word, :word

uglInit         proto   far
uglEnd          proto   far
uglNew          proto   far :word, :word, :word, :word
uglDel          proto   far :dword
uglPut          proto   far :dword, :word, :word, :dword

DC_MEM          equ     0
FMT_8BIT        equ     0
WID             equ     160
HGT             equ     100
SWID            equ     32
SHGT            equ     24

;; A source that actually crosses 64K. t15blit's surface is 512 wide but
;; only four rows, so its rows never leave the first segment and a cursor
;; advanced as a plain 16-bit offset would pass it. 512 x 160 is 81,920
;; bytes: row 128 is the first one past the wrap.
TWID            equ     512
THGT            equ     160
TROW64K         equ     128

;; The wholly-below case needs somewhere for a buggy blit to LAND. A
;; destination that is only as tall as its logical height sends the bad
;; write past its own allocation, where a snapshot of the visible area
;; cannot see it and the mutation passes while corrupting whatever is
;; next in memory. So: a backing store three times as tall, one Surface
;; over it that claims the full height (the alias, used only to read),
;; and a second whose y_res is cut down to HGT (the one under test).
GHGT            equ     300
GCANARY         equ     55
GPROBE          equ     220
BYTES           equ     WID * HGT
ROUNDS          equ     6

;; From b02prim's calibration: this pair puts mgl near 26 ticks and qgl
;; near 126 at the baseline, 48 once the cursor lands, so both clear the
;; 20-tick floor either way and neither is measuring the timer.
LOOPS           equ     10000
REPS            equ     12

;; The bound the wrapper has to meet, as a numerator over 10 so it can be
;; stated in whole numbers: qsum * 10 <= msum * BOUND10.
BOUND10         equ     20

.data
n_init          db      'mgl initialized       $'
n_adopt         db      'mgl DC adopted by qgl $'
n_alike         db      'blit bytes alike      $'
n_below         db      'wholly below: canary  $'
n_partb         db      'partial bottom alike  $'
n_partt         db      'partial top alike     $'
n_tall          db      'tall src crosses 64k  $'
n_duration      db      'duration >= 20 ticks  $'
n_bound         db      'qgl cmem blit <= 2x   $'

q_blit          db      'blit qgl ticks        $'
m_blit          db      'blit mgl ticks        $'
n_qsum          db      'blit qgl tick sum     $'
n_msum          db      'blit mgl tick sum     $'

dc              dd      0
sdc             dd      0
tdc             dd      0
tsrc            dd      0
qtptr           dd      0
qtsptr          dd      0
qtall           Surface <>
qtsrc           Surface <>
gdc             dd      0
qgptr           dd      0
qaptr           dd      0
qguard          Surface <>
qalias          Surface <>
qptr            dd      0
qsptr           dd      0
qsurf           Surface <>
qsrc            Surface <>
snap            db      BYTES dup (0)
bad             dw      0
t0              dd      0
shown           dd      0
qsum            dd      0
msum            dd      0
nv              dw      0
rv              dw      0

.code

;; The BIOS tick count, read twice so a carry into the high word between
;; the two reads cannot be mistaken for a jump backwards.
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

clear           proc    near private
                invoke  qglDrFill, qptr, 0, 0, WID-1, HGT-1, 11
                ret
clear           endp

qarm            proc    near private uses ax bx cx dx si di,
                        n:word
                mov     ax, n
                mov     nv, ax
@@again:        invoke  qglDrBlit, qptr, 61, 37, qsptr
                dec     nv
                jnz     @@again
                ret
qarm            endp

marm            proc    near private uses ax bx cx dx si di,
                        n:word
                mov     ax, n
                mov     nv, ax
@@again:        invoke  uglPut, dc, 61, 37, sdc
                dec     nv
                jnz     @@again
                ret
marm            endp

snapshot        proc    near private uses ax bx cx dx si di ds es
                xor     si, si
                mov     di, offset snap
@@row:          cmp     si, HGT
                jae     @@out
                invoke  qglSfRdRow, qptr, si
                push    ds
                mov     ds, dx
                mov     si, ax
                mov     cx, WID
                mov     ax, @data
                mov     es, ax
                rep     movsb
                pop     ds
                mov     ax, di
                sub     ax, offset snap
                xor     dx, dx
                mov     cx, WID
                div     cx
                mov     si, ax
                jmp     @@row
@@out:          ret
snapshot        endp

compare         proc    near private uses bx cx dx si di es
                mov     bad, 0
                xor     si, si
                mov     di, offset snap
@@row:          cmp     si, HGT
                jae     @@out
                invoke  qglSfRdRow, qptr, si
                mov     es, dx
                mov     bx, ax
                mov     cx, WID
@@byte:         mov     al, ds:[di]
                cmp     al, es:[bx]
                je      @F
                inc     bad
@@:             inc     di
                inc     bx
                loop    @@byte
                inc     si
                jmp     @@row
@@out:          mov     ax, bad
                ret
compare         endp

;; One sample: run the arm REPS times over LOOPS blits, print the elapsed
;; ticks under its own label, assert the 20-tick floor, and add it to that
;; arm's running sum.
time_arm        proc    near private uses ax bx cx dx si di,
                        arm:word, nam:word, acc:word
                call    bnow
                mov     word ptr t0, ax
                mov     word ptr t0+2, dx
                mov     rv, REPS
@@repeat:       cmp     arm, 0
                jne     @F
                invoke  qarm, LOOPS
                jmp     @@next
@@:             invoke  marm, LOOPS
@@next:         dec     rv
                jnz     @@repeat

                call    bnow
                sub     ax, word ptr t0
                sbb     dx, word ptr t0+2
                mov     word ptr shown, ax
                mov     word ptr shown+2, dx
                invoke  tshow, nam, shown

                ;; into this arm's sum
                mov     bx, acc
                mov     cx, word ptr shown
                add     [bx], cx
                mov     cx, word ptr shown+2
                adc     [bx+2], cx

                xor     bx, bx
                cmp     word ptr shown+2, 0
                jne     @F
                cmp     word ptr shown, 20
                jb      @@short
@@:             inc     bx
@@short:        invoke  tchk, offset n_duration, bx, 1
                ret
time_arm        endp

tmain           proc    far public uses ax bx cx dx si di es
                invoke  qglSfInit
                invoke  uglInit
                NZ      ax
                CHK     n_init, ax, 1

                invoke  uglNew, DC_MEM, FMT_8BIT, WID, HGT
                SAVEP   dc
                invoke  uglNew, DC_MEM, FMT_8BIT, SWID, SHGT
                SAVEP   sdc
                mov     word ptr qptr, offset qsurf
                mov     word ptr qptr+2, ds
                mov     word ptr qsptr, offset qsrc
                mov     word ptr qsptr+2, ds
                invoke  qglSfAdoptDc, dc, qptr
                mov     bx, ax
                invoke  qglSfAdoptDc, sdc, qsptr
                and     ax, bx
                NZ      ax
                CHK     n_adopt, ax, 1

                ;; a source whose every column differs, so a blit that
                ;; loses or repeats one is visible in the compare
                xor     si, si
@@src:          cmp     si, SWID
                jae     @@check
                mov     ax, si
                add     ax, 32
                invoke  qglDrFill, qsptr, si, 0, si, SHGT-1, ax
                inc     si
                jmp     @@src

                ;; EXACT OUTPUT FIRST. A faster wrapper that draws
                ;; something else is not a faster wrapper.
@@check:        call    clear
                invoke  qarm, 1
                call    snapshot
                call    clear
                invoke  marm, 1
                call    compare
                mov     word ptr shown, ax
                mov     word ptr shown+2, 0
                invoke  tshow, offset n_alike, shown
                invoke  tchk, offset n_alike, bad, 0

                ;;
                ;; CLIPPING, against mgl as the reference for every case.
                ;; A cursor that is set up before the rows are clipped
                ;; writes off the end of the surface, and the wholly-below
                ;; case is the one that does it silently.
                ;;
                ;; A tall backing store, seen two ways: the alias keeps
                ;; its real height so the canary can be read back, and the
                ;; surface under test is told it is only HGT tall.
                invoke  uglNew, DC_MEM, FMT_8BIT, WID, GHGT
                SAVEP   gdc
                mov     word ptr qgptr, offset qguard
                mov     word ptr qgptr+2, ds
                mov     word ptr qaptr, offset qalias
                mov     word ptr qaptr+2, ds
                invoke  qglSfAdoptDc, gdc, qgptr
                invoke  qglSfAdoptDc, gdc, qaptr
                mov     bx, offset qguard
                mov     [bx].Surface.y_res, HGT     ;; the lie under test

                ;; canary over the whole store, through the honest view
                invoke  qglDrFill, qaptr, 0, 0, WID-1, GHGT-1, GCANARY
                ;; and a blit aimed well past the clipped height
                invoke  qglDrBlit, qgptr, 61, GPROBE, qsptr
                ;; read the landing row back through the honest view
                invoke  qglSfPget, qaptr, 61, GPROBE
                mov     bx, ax
                invoke  tchk, offset n_below, bx, GCANARY
                invoke  uglDel, addr gdc

                call    clear
                invoke  qglDrBlit, qptr, 61, HGT-10, qsptr
                call    snapshot
                call    clear
                invoke  uglPut, dc, 61, HGT-10, sdc
                call    compare
                invoke  tchk, offset n_partb, bad, 0

                call    clear
                invoke  qglDrBlit, qptr, 61, -9, qsptr
                call    snapshot
                call    clear
                invoke  uglPut, dc, 61, -9, sdc
                call    compare
                invoke  tchk, offset n_partt, bad, 0

                ;;
                ;; AND A SOURCE TALLER THAN A SEGMENT. Copied whole, then
                ;; one byte read back from beyond the 64K boundary: a
                ;; cursor advanced as a 16-bit offset wraps to the surface's
                ;; own first rows and returns the wrong colour here.
                ;;
                invoke  uglNew, DC_MEM, FMT_8BIT, TWID, THGT
                SAVEP   tdc
                invoke  uglNew, DC_MEM, FMT_8BIT, TWID, THGT
                SAVEP   tsrc
                mov     word ptr qtptr, offset qtall
                mov     word ptr qtptr+2, ds
                mov     word ptr qtsptr, offset qtsrc
                mov     word ptr qtsptr+2, ds
                invoke  qglSfAdoptDc, tdc, qtptr
                invoke  qglSfAdoptDc, tsrc, qtsptr

                invoke  qglDrFill, qtsptr, 0, 0, TWID-1, THGT-1, 17
                invoke  qglDrFill, qtsptr, 0, TROW64K, TWID-1, THGT-1, 33
                invoke  qglDrFill, qtptr, 0, 0, TWID-1, THGT-1, 0
                invoke  qglDrBlit, qtptr, 0, 0, qtsptr

                ;; row 128 column 3 must be the SECOND colour
                invoke  qglSfPget, qtptr, 3, TROW64K
                mov     bx, ax
                invoke  tchk, offset n_tall, bx, 33

                invoke  uglDel, addr tsrc
                invoke  uglDel, addr tdc

                mov     qsum, 0
                mov     msum, 0
                mov     di, ROUNDS
@@round:        test    di, 1
                jz      @@mq
                invoke  time_arm, 0, offset q_blit, offset qsum
                invoke  time_arm, 1, offset m_blit, offset msum
                jmp     @@rnext
@@mq:           invoke  time_arm, 1, offset m_blit, offset msum
                invoke  time_arm, 0, offset q_blit, offset qsum
@@rnext:        dec     di
                jnz     @@round

                invoke  tshow, offset n_qsum, qsum
                invoke  tshow, offset n_msum, msum

                ;; qsum * 10 <= msum * BOUND10, in 32 bits. Both sums are
                ;; a few thousand ticks at most, so neither product can
                ;; leave a dword.
                mov     eax, qsum
                mov     ecx, 10
                mul     ecx
                mov     ebx, eax                ;; qsum * 10
                mov     eax, msum
                mov     ecx, BOUND10
                mul     ecx                     ;; msum * 20
                xor     dx, dx
                cmp     ebx, eax
                ja      @F
                inc     dx
@@:             invoke  tchk, offset n_bound, dx, 1

                invoke  uglDel, addr sdc
                invoke  uglDel, addr dc
                invoke  uglEnd
                ret
tmain           endp
                end
