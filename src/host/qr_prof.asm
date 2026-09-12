;; qr_prof.asm -- the qrProf* counters, as zeros.
;;
;; h_bench.bas reads ten profiling counters that only an instrumented
;; build of uGL's polygon filler defines. Against the plain library the
;; link had ten unresolved externals -- and LINK still emits an EXE with
;; an int 3 at each call site, so the miss surfaced as a trap at report
;; time rather than at build time. These stubs keep the plain link whole;
;; a profile of zeros is exactly what "not instrumented" means. Leave
;; them out of any instrumented library's link, where the real counters
;; take over.
                .286
                .model medium, pascal

.code

QRSTUB          macro   pname
pname           proc    far public
                xor     ax, ax
                xor     dx, dx
                ret
pname           endp
endm

                QRSTUB  qrProfRdAccess
                QRSTUB  qrProfWrBegin
                QRSTUB  qrProfWSwitchSum
                QRSTUB  qrProfWSwitchCnt
                QRSTUB  qrProfPolyCnt
                QRSTUB  qrProfFillSum
                QRSTUB  qrProfScanCnt
                QRSTUB  qrProfOuterSum
                QRSTUB  qrProfZSetSum
                QRSTUB  qrProfEdgeSum
                end
