;; t10ref -- every patched filler against the reference filler.
;;
;; This is the test the self-modifying code exists to survive. A patch
;; site written at the wrong offset, a mask patched into the prologue but
;; not the loop, a step patched into two of three variants: each of those
;; draws a PLAUSIBLE picture. Reading the code does not catch them and a
;; screenshot does not either.
;;
;; So the same polygon is drawn twice through the same scanner -- once
;; through the patched fillers, once through qgl$Ref, which reads every
;; constant from memory and has no patch site at all -- and the two
;; surfaces must be identical to the byte.
;;
;; Two things make it able to see anything:
;;
;;   the texture -- every texel is (x + y*8), so no two are alike. A flat
;;                  texture makes any u or v error invisible, which is the
;;                  trap this kind of test usually falls into.
;;   the polygon -- not axis aligned, and z differs at every vertex, so u,
;;                  v and 1/z all vary along both edges and across every
;;                  span.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglDrFill     proto   far :dword, :word, :word, :word, :word, :word
qglClRect     proto   far :word, :word, :word, :word
qglRsRef      proto   far :word
qglRsPoly     proto   far :dword, :dword, :word, :word, :dword
qglSfZMode    proto   far :dword, :word
qglSfZNew     proto   far :dword, :word
qglSfZClear   proto   far :dword, :word
qglZScale     proto   far :dword

SFW             equ     64
SFH             equ     64

.data
n_wo            db      'wire   no depth        $'
n_ww            db      'wire   depth set       $'
n_wt            db      'wire   depth tested    $'
n_fo            db      'flat   no depth        $'
n_fw            db      'flat   depth set       $'
n_ft            db      'flat   depth tested    $'
n_to            db      'tex    no depth        $'
n_tw            db      'tex    depth set       $'
n_tt            db      'tex    depth tested    $'
n_zd            db      'depth buffers agree too$'
n_notflat       db      'the texture is not flat$'
n_ovl2          db      'sb survives the others $'
n_fd            db      'first diff yyxx aabb   $'
n_hb            db      'sb seg:ofs             $'
n_zb            db      'zbb pointer            $'

;; not axis aligned, and 1/z varies at every vertex
poly            QVert   <12.0, 6.0,  1.00, 0.0, 0.0>
                QVert   <52.0, 18.0, 0.80, 1.0, 0.0>
                QVert   <44.0, 55.0, 0.55, 1.0, 1.0>
                QVert   <9.0,  41.0, 0.90, 0.0, 1.0>

zs              real4   100.0

sa              dd      0
sb              dd      0
za              dd      0
zbb             dd      0
tx              dd      0
pp              dd      0
diffs           dw      0
n_db            db      'ref  pixels            $'
n_la            db      'fast lines             $'

.code

;; bytes where two surfaces disagree
;; ds STAYS DGROUP. The first version pointed it at one of the surfaces
;; and then did `inc diffs`, which wrote a DGROUP variable into that
;; surface's pixels and read the count back out of them. The source goes
;; in fs instead.
cmpsf           proc    near private uses bx cx dx si di fs es,\
                        p:dword, q:dword, w:word, h:word

                local   po:word

                mov     diffs, 0
                xor     si, si
@@row:          cmp     si, h
                jae     @@out
                invoke  qglSfRow, p, si
                mov     po, ax
                mov     fs, dx
                invoke  qglSfRow, q, si
                mov     di, ax
                mov     es, dx
                mov     bx, po
                mov     cx, w
@@px:           mov     al, fs:[bx]
                cmp     al, es:[di]
                je      @F
                inc     diffs
@@:             inc     bx
                inc     di
                loop    @@px
                inc     si
                jmp     @@row
@@out:          mov     ax, diffs
                ret
cmpsf           endp

;; bytes of p that are NOT val

;; (y<<24)|(x<<16)|(a<<8)|b for the first disagreement



;; draw once each way and diff. ?nm names the assertion.
;; ?sr is the src slot: the texture in a textured mode, the flat colour
;; otherwise. One argument, read as whichever the mode says.
BOTH            macro   ?nm, ?md, ?zm, ?sr
                invoke  qglRsRef, 0                   ;; the patched fillers
                invoke  qglDrFill, sa, 0, 0, SFW-1, SFH-1, 0
                invoke  qglSfZClear, sa, 50
                invoke  qglSfZMode, sa, ?zm
                invoke  qglRsPoly, sa, pp, 4, ?md, ?sr

                invoke  qglRsRef, 1                   ;; the reference
                invoke  qglDrFill, sb, 0, 0, SFW-1, SFH-1, 0
                invoke  qglSfZClear, sb, 50
                invoke  qglSfZMode, sb, ?zm
                invoke  qglRsPoly, sb, pp, 4, ?md, ?sr


                invoke  cmpsf, sa, sb, SFW, SFH
                CHK     ?nm, ax, 0
endm



tmain           proc    far public uses bx cx dx si di es

                invoke  qglSfInit

                invoke  qglSfNew, SFW, SFH, SURF_CMEM
                SAVEP   sa
                invoke  qglSfNew, SFW, SFH, SURF_CMEM
                SAVEP   sb
                invoke  qglSfNew, 8, 8, SURF_CMEM
                SAVEP   tx

                mov     word ptr pp, offset poly
                mov     word ptr pp+2, ds

                ;; every texel distinct: (x + y*8)
                xor     si, si
@@ty:           cmp     si, 8
                jae     @@tdone
                xor     di, di
@@tx:           cmp     di, 8
                jae     @F
                mov     ax, si
                shl     ax, 3
                add     ax, di
                invoke  qglSfPset, tx, di, si, ax
                inc     di
                jmp     @@tx
@@:             inc     si
                jmp     @@ty
@@tdone:
                ;; and prove it, so a flat texture can never silently make
                ;; the comparisons below vacuous
                invoke  qglSfPget, tx, 3, 5
                mov     bx, ax
                invoke  qglSfPget, tx, 4, 5
                sub     ax, bx
                CHK     n_notflat, ax, 1

                invoke  qglClRect, 0, 0, SFW-1, SFH-1

                ;; a depth buffer each, so the two runs cannot see each
                ;; other's writes
                invoke  qglSfZNew, sa, SURF_CMEM
                SAVEP   za
                invoke  qglSfZNew, sb, SURF_CMEM
                SAVEP   zbb
                invoke  qglZScale, dword ptr zs


                ;; With all five blocks live, does writing each of the
                ;; others leave sa and sb alone?


                BOTH    n_wo, QGL_M_WIRE, QGL_Z_OFF,  37
                BOTH    n_ww, QGL_M_WIRE, QGL_Z_SET,  37
                BOTH    n_wt, QGL_M_WIRE, QGL_Z_TEST, 37
                BOTH    n_fo, QGL_M_FLAT, QGL_Z_OFF,  37
                BOTH    n_fw, QGL_M_FLAT, QGL_Z_SET,  37
                BOTH    n_ft, QGL_M_FLAT, QGL_Z_TEST, 37
                BOTH    n_to, QGL_M_TEX,  QGL_Z_OFF,  tx
                BOTH    n_tw, QGL_M_TEX,  QGL_Z_SET,  tx
                BOTH    n_tt, QGL_M_TEX,  QGL_Z_TEST, tx

                ;; the last pair also has to agree on what they WROTE to
                ;; depth, not only on the picture that came out
                invoke  cmpsf, za, zbb, SFW*2, SFH
                CHK     n_zd, ax, 0
                ret
tmain           endp
                end
