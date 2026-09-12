;; r_vxfrm.asm -- r_vxfrm: one face's vertices, unpacked, UV'd and
;; transformed, in a single pass.
;;
;; Replaces d_faces.c's two C loops (d_draw_faces:427-449 and :454-460)
;; for the non-liquid case. bcc's own -S output for the first of those
;; two loops (compiled standalone as vbfar.c, gv kept `far` to match the
;; real d_draw_faces exactly) showed the same bug class r_ptproj.asm
;; already fixed once in this tree:
;;
;;      les     bx, dword ptr [bp+6]    ;; reloads ALL of gv, EVERY VERTEX
;;      add     bx, ax
;;      mov     ax, word ptr es:[bx]
;;      mov     word ptr [bp-18], ax    ;; round-trips the far read through
;;      fild    word ptr [bp-18]        ;; a near stack temp before fild
;;
;; gv never moves across the loop -- only the per-vertex offset does.
;; Here ES:BX is loaded ONCE and the offset rides on BX itself (+6 bytes
;; a vertex, three shorts), and fild reads the far word directly
;; (`fild word ptr es:[bx]`), no near round-trip.
;;
;; The second loop (the 4x4 transform) was already found to be a dead
;; end for this exact bug -- m and vt_x/y/z/w are all near, so bcc has
;; no segment to mis-schedule there. What IS worth taking is that the
;; original runs it as a SEPARATE loop, storing vt_x[j]/vt_y[j]/vt_z[j]
;; out of loop 1 and reading them back into loop 2. Fused into one pass,
;; those three values live in named locals (vxL/vyL/vzpL below) instead
;; of a round trip through the array -- and because each is stored to a
;; real 32-bit memory local the moment it's computed (matching what a C
;; `float` local already does), the value seen is bit-identical to what
;; the two-loop version produced; only the memory traffic changes; see
;; the byte-identical gate this was checked against.
;;
;; su0..sv3 (the face's texture axes) are read from `suv`, a caller-
;; packed float[8] -- eight scalar params would have meant eight extra
;; stack slots for values that never change across the vertex loop, and
;; they are preloaded into locals here.
;;
;; An earlier version of this note justified that by claiming only three
;; pointer registers exist (bx/si/di, bp being the frame). That is the
;; 16-bit addressing rule and it does NOT bind here: .386 is in force
;; above, so the 67h address-size prefix is available and every one of
;; the eight 32-bit registers can serve as a base, with a scaled index
;; and a 32-bit displacement on top. The real reason su0..sv3 sit in
;; memory is duller and unrelated: fmul takes its operand from memory or
;; the FPU stack, never from a general register, so there is nothing for
;; a freed register to hold.
;;
;; What 67h WOULD buy is the per-vertex address arithmetic below -- six
;; `mov di,<arr>` + `add di,dx` pairs that a `[idx*4 + arr]` operand
;; folds into the store itself. Twelve instructions of about eighty-eight
;; per vertex, so roughly 0.12ms of this routine's measured 0.9ms: real,
;; but under the noise this project can resolve, and it needs the six
;; scratch arrays to lose `static` in d_faces.c so this file can name
;; them. Left undone deliberately, with the number written down rather
;; than the possibility merely noted.
;;
;; The 64K rule that comes with the prefix does not threaten any of it:
;; every array here is near, so the effective address cannot leave the
;; segment and the #GP that guards it is unreachable by construction.
;;
;; No FWAIT anywhere -- same reasoning as r_ptproj.asm: every sequence
;; here is FPU-to-FPU or FPU-to-memory, nothing a discrete 8087's bus
;; race could still be racing DOSBox's dynamic core over.
;;
;; Liquid faces are NOT handled here. The turbulence lookup (ifloor,
;; &255, a table read through dp->turb_ptr) is per-vertex conditional
;; work this routine has no branch for; the caller still runs the
;; original C loop for those faces. Only two faces on the maps this
;; renders are liquid at all -- not worth the risk of hand-porting the
;; turb table path blind.
;;
;; name: r_vxfrm
;; desc: Unpacks vcnt vertices out of gv (BSP-space Q13.3, GEOM_VTX0
;;       onward), swaps to renderer space, computes texture (u,v), and
;;       transforms through m -- writing vt_x/y/z/w and vt_u/v. Every
;;       output array is MAXV floats, indexed 0..vcnt-1.
;; args: [in]  gv     | far ptr, short[], BSP vertex ints (Q13.3)
;;             vcnt   | word, vertex count
;;             ofs    | near ptr, float[3], the brush entity's
;;                      | offset, BSP-space (x, y, z)
;;             suv    | near ptr, float[8]: su0..su3, sv0..sv3
;;             m      | near ptr, float[16], the transform matrix
;;             vt_x, vt_y, vt_z, vt_w, vt_u, vt_v | near ptr, float[MAXV] out
;; retn: none
;;::::::::::::::

                ;; .model FIRST, .386 second -- see r_ptproj.asm's own
                ;; note; same trap, same fix, same fmtstub.asm precedent.
                .model  medium, pascal
                .386

.data
vtx_unsc        dd      03E000000h      ;; 0.125f, VTX_UNSCALE

.code

;; DOT3L: dst-less dot product of 3 locals against 3 LOCAL coefficients
;; plus a constant, left to right -- (((a*c0)+(b*c1))+(c*c2))+c3 -- the
;; same left-to-right chain the C source evaluates. Leaves the result on
;; ST(0); the caller stores it.
DOT3L           MACRO   c0, c1, c2, c3, a, b, c
                fld     dword ptr a
                fmul    dword ptr c0
                fld     dword ptr b
                fmul    dword ptr c1
                fadd
                fld     dword ptr c
                fmul    dword ptr c2
                fadd
                fadd    dword ptr c3
                ENDM

;; DOT3M: same shape, but the four coefficients come from m[], addressed
;; through SI at compile-time offsets -- si is loaded once, outside the
;; loop, and never reloaded (r_ptproj's ES:BX discipline, applied to a
;; near pointer instead of a far one).
DOT3M           MACRO   o0, o1, o2, o3, a, b, c
                fld     dword ptr a
                fmul    dword ptr [si+o0]
                fld     dword ptr b
                fmul    dword ptr [si+o1]
                fadd
                fld     dword ptr c
                fmul    dword ptr [si+o2]
                fadd
                fadd    dword ptr [si+o3]
                ENDM

;;::::::::::::::
r_vxfrm         proc    public uses bx cx dx si di,\
                        gv:dword, vcnt:word, ofs:word, suv:word, m:word,\
                        vt_x:word, vt_y:word, vt_z:word, vt_w:word,\
                        vt_u:word, vt_v:word

                LOCAL   su0:dword, su1:dword, su2:dword, su3:dword
                LOCAL   sv0:dword, sv1:dword, sv2:dword, sv3:dword
                LOCAL   vxL:dword, vyL:dword, vzL:dword
                LOCAL   vxpL:dword, vypL:dword, vzpL:dword
                LOCAL   oxL:dword, oyL:dword, ozL:dword

                mov     cx, vcnt
                jcxz    vxfrm_zero      ;; jcxz is short-range only; the
                jmp     short vxfrm_cont ;; loop body below is past its
                                        ;; +-127 byte reach.
vxfrm_zero:
                jmp     vxfrm_done
vxfrm_cont:

                ;; suv -> locals. Transient use of si, before si is
                ;; handed to m for the rest of the routine.
                mov     si, suv
                fld     dword ptr [si+0]
                fstp    su0
                fld     dword ptr [si+4]
                fstp    su1
                fld     dword ptr [si+8]
                fstp    su2
                fld     dword ptr [si+12]
                fstp    su3
                fld     dword ptr [si+16]
                fstp    sv0
                fld     dword ptr [si+20]
                fstp    sv1
                fld     dword ptr [si+24]
                fstp    sv2
                fld     dword ptr [si+28]
                fstp    sv3

                ;; the brush entity's offset, BSP-space, three floats
                mov     si, ofs
                fld     dword ptr [si+0]
                fstp    oxL
                fld     dword ptr [si+4]
                fstp    oyL
                fld     dword ptr [si+8]
                fstp    ozL

                push    es
                les     bx, gv          ;; ES:BX -> gv, loaded ONCE
                add     bx, 18          ;; GEOM_VTX0 (9 shorts) * 2
                mov     si, m           ;; DS:SI -> m, ONCE, never reloaded
                xor     dx, dx          ;; running output byte-offset

vxfrm_loop:
                ;; vxL/vyL/vzL = gv[v0..v0+2] * VTX_UNSCALE, each rounded
                ;; to 32 bits the moment it's computed -- exactly what a
                ;; C `float` local does, which is what makes reusing
                ;; these directly (instead of a store/reload through
                ;; vt_x/y/z) bit-identical to the two-loop original.
                fild    word ptr es:[bx]
                fmul    dword ptr vtx_unsc
                fstp    vxL
                fild    word ptr es:[bx+2]
                fmul    dword ptr vtx_unsc
                fstp    vyL
                fild    word ptr es:[bx+4]
                fmul    dword ptr vtx_unsc
                fstp    vzL

                ;; The swapped, offset point, each coordinate rounded
                ;; once -- the same rounding point the original's stores
                ;; to vt_x/y/z[j] had, reused below in all four transform
                ;; rows instead of re-added. BSP is Z-up and the renderer
                ;; Y-up, so the offset swaps with the axes it rides on.
                fld     vxL
                fadd    oxL
                fstp    vxpL
                fld     vzL
                fadd    ozL
                fstp    vzpL
                fld     vyL
                fadd    oyL
                fstp    vypL

                ;; tu, tv -- BSP-space (pre-swap) vx, vy, vz.
                DOT3L   su0, su1, su2, su3, vxL, vyL, vzL
                mov     di, vt_u
                add     di, dx
                fstp    dword ptr [di]

                DOT3L   sv0, sv1, sv2, sv3, vxL, vyL, vzL
                mov     di, vt_v
                add     di, dx
                fstp    dword ptr [di]

                ;; Transform. vx,vy,vz (transform's own naming) are the
                ;; SWAPPED, offset inputs: vt_x[j]=vxpL, vt_y[j]=vzpL,
                ;; vt_z[j]=vypL.
                DOT3M   0, 16, 32, 48, vxpL, vzpL, vypL
                mov     di, vt_x
                add     di, dx
                fstp    dword ptr [di]

                DOT3M   4, 20, 36, 52, vxpL, vzpL, vypL
                mov     di, vt_y
                add     di, dx
                fstp    dword ptr [di]

                DOT3M   8, 24, 40, 56, vxpL, vzpL, vypL
                mov     di, vt_z
                add     di, dx
                fstp    dword ptr [di]

                DOT3M   12, 28, 44, 60, vxpL, vzpL, vypL
                mov     di, vt_w
                add     di, dx
                fstp    dword ptr [di]

                add     bx, 6           ;; next vertex: 3 shorts
                add     dx, 4           ;; next vertex: 1 float
                dec     cx
                jnz     vxfrm_loop

                pop     es

vxfrm_done:
                ret

r_vxfrm         endp

                end
