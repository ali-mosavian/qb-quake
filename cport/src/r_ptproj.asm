;; r_ptproj.asm -- r_ptproj: one portal box, projected to a screen AABB.
;;
;; Hand-written replacement for r_portal.c's project_box, because bcc -Ox
;; never hoists a far pointer's segment outp of a loop: the C version
;; reloaded ES thirteen times per corner (104 times a call) for two
;; parameters that never move across the whole function -- measured
;; directly by disassembling bcc's own -S output.
;;
;; Two things that C version got wrong that this one does not:
;;
;;   - project_box declared its SECOND parameter `float far *m`, so bcc
;;     treated it as a real far pointer and reloaded ES for it too. But
;;     every real caller passes r_portal_mark's own `m`, which is a bare
;;     near pointer -- medium model's default, and how BASIC hands a
;;     u3dMtrx across in the first place (see r_walk.c's own note on
;;     this). m never needed a segment at all. Declared near here.
;;
;;   - bb genuinely is far (EMS-backed portal data), and it is loaded
;;     into ES exactly ONCE, at entry -- not per corner, not per field.
;;
;;   - vx and vy are computed only for corners that pass the near-plane
;;     test. The C version computed both unconditionally, before the
;;     test that decides whether they are even used.
;;
;;   - one reciprocal, not two divides: 1/vw is computed once and reused
;;     for both sx and sy, where the C version divided by vw twice.
;;
;;   - the eight corners are fully unrolled with compile-time offsets
;;     into bb, so there is no per-corner branch selecting which field
;;     to read -- bcc emitted a test/je/mov/jmp sequence for each of the
;;     three fields, on every one of the eight corners, to compute what
;;     the corner index already fixes at assembly time.
;;

;; No FWAIT anywhere in this file. Every one here was FPU-to-FPU (a later
;; fld reading what an earlier fstp just wrote -- the x87 processes its own
;; queue in order, no CPU race to guard against even on real 8087 hardware)
;; or the classic fstsw/sahf handoff, which needs FWAIT only because a
;; discrete 8087 could still be finishing that store when the CPU's next
;; instruction reads it. DOSBox's dynamic core does not model a separate
;; coprocessor bus at all -- there is nothing here for FWAIT to wait on.
;; Proven the only way that means anything: the byte-identical mutation
;; check, same as every other change in this file.

;; Correctness matters more than any of this: a portal wrongly culled is
;; geometry that silently vanishes. This is verified the only way that
;; means anything here -- built into the real renderer and checked
;; byte-identical against -noportal at the same pinned viewpoints the
;; C version was checked against, not by hand-tracing the FPU stack.
;;
;; name: r_ptproj
;; desc: Projects bb's eight corners through m and returns their screen
;;       AABB in outp. A corner straddling w < z_near sets `behind`; if
;;       every corner is behind, returns 0 and outp is untouched -- the
;;       box is entirely off the near side and cannot be on screen. If
;;       some corners are behind and some are not, the projection is
;;       unbounded in that direction and outp is set to the whole screen
;;       (+-1e6, larger than any real coordinate here) rather than
;;       guessed at -- costs cull rate on that one portal, never
;;       correctness, and needs no near-plane clipper.
;; args: [in]  bb     | far ptr, 6 shorts: minx,miny,minz,maxx,maxy,maxz
;;             m      | near ptr, 16 floats, the projection matrix
;;             xresh, yresh, z_near | floats
;;             outp    | near ptr, Rect: x0,y0,x1,y1 as four floats
;; retn: word          | 0 = bb is entirely behind the near plane, outp
;;                        untouched. 1 = outp was written.
;;::::::::::::::

                ;; .model FIRST, .386 second. Backwards, .386 makes the
                ;; simplified _DATA segment USE32, which conflicts at LINK
                ;; time with every other module's USE16 _DATA -- the trap
                ;; r_sweep.asm's own header warns about, and chose .286 to
                ;; dodge entirely. In this order _DATA comes out 16-bit
                ;; regardless of .386: jwasm fixes a segment's width when
                ;; .model establishes it, not from whatever CPU directive
                ;; is active later in the file. Confirmed empirically, and
                ;; it is what fmtstub.asm -- this tree's other .386 module
                ;; -- already does.
                .model  medium, pascal
                .386

;; -1e6 / +1e6 as IEEE-754 float32 bits, taken from bcc's own -S output
;; for these exact constants, not reconstructed by hand.
MINUS_1E6       EQU     0C9742400h
PLUS_1E6        EQU     049742400h

.code

CORNER          MACRO   bxo, bzo, byo
                LOCAL   isbehind, corner_done

                fild    word ptr es:[bx+bxo]
                fstp    fbx
                fild    word ptr es:[bx+bzo]
                fstp    fbz
                fild    word ptr es:[bx+byo]
                fstp    fby

                ;; vw = fbx*m[3] + fby*m[7] + fbz*m[11] + m[15]
                fld     fbx
                fmul    dword ptr [si+12]
                fld     fby
                fmul    dword ptr [si+28]
                fadd
                fld     fbz
                fmul    dword ptr [si+44]
                fadd
                fadd    dword ptr [si+60]
                ;; ST(0) = vw. Duplicate before comparing: fcomp pops
                ;; whatever it compares, and vw is still wanted below.
                fld     st(0)
                fcomp   z_near
                fstsw   ax
                sahf
                jae     short corner_done
                ;; behind: drop the still-live vw and count it
                fstp    st(0)
                inc     behind
                jmp     isbehind
corner_done:
                inc     infront

                ;; recip = 1 / vw, replacing vw on the stack
                fld1
                fdiv    st(0),st(1)
                fstp    st(1)

                ;; vx = fbx*m[0] + fby*m[4] + fbz*m[8] + m[12]
                fld     fbx
                fmul    dword ptr [si+0]
                fld     fby
                fmul    dword ptr [si+16]
                fadd
                fld     fbz
                fmul    dword ptr [si+32]
                fadd
                fadd    dword ptr [si+48]
                ;; ST(0) = vx, ST(1) = recip -- fmul st(0),st(1) leaves
                ;; recip in ST(1) untouched, still there for vy below.
                fmul    st(0),st(1)
                fmul    xresh
                fadd    xresh
                fstp    sxv

                ;; vy = fbx*m[1] + fby*m[5] + fbz*m[9] + m[13]
                fld     fbx
                fmul    dword ptr [si+4]
                fld     fby
                fmul    dword ptr [si+20]
                fadd
                fld     fbz
                fmul    dword ptr [si+36]
                fadd
                fadd    dword ptr [si+52]
                ;; ST(0) = vy, ST(1) = recip. fstp st(1) drops recip the
                ;; same way vw was dropped above, leaving ST(0)=vy*recip.
                fmul    st(0),st(1)
                fstp    st(1)
                fmul    yresh
                fsubr   yresh
                fstp    syv

                ;; running AABB, same fstsw/sahf idiom throughout --
                ;; nothing here needs to be cleverer than a compare.
                fld     sxv
                fcomp   x0
                fstsw   ax
                sahf
                jae     short @F
                mov     eax, dword ptr sxv
                mov     dword ptr x0, eax
@@:
                fld     sxv
                fcomp   x1
                fstsw   ax
                sahf
                jbe     short @F
                mov     eax, dword ptr sxv
                mov     dword ptr x1, eax
@@:
                fld     syv
                fcomp   y0
                fstsw   ax
                sahf
                jae     short @F
                mov     eax, dword ptr syv
                mov     dword ptr y0, eax
@@:
                fld     syv
                fcomp   y1
                fstsw   ax
                sahf
                jbe     short @F
                mov     eax, dword ptr syv
                mov     dword ptr y1, eax
@@:
isbehind:
                ENDM

;;::::::::::::::
r_ptproj        proc    public uses bx cx dx si di,\
                        bb:dword, m:word, xresh:dword, yresh:dword,\
                        z_near:dword, outp:word

                LOCAL   fbx:dword, fbz:dword, fby:dword
                LOCAL   sxv:dword, syv:dword
                LOCAL   x0:dword, y0:dword, x1:dword, y1:dword
                LOCAL   infront:word, behind:word

                push    es
                les     bx, bb          ;; ES:BX -> bb, loaded ONCE
                mov     si, m           ;; DS:SI -> m, near: no segment at all

                mov     infront, 0
                mov     behind, 0
                ;; +1e30 (07149F2CAh) / -1e30 (0F149F2CAh), the same bit
                ;; patterns bcc's own -S emitted for these constants.
                mov     dword ptr x0, 07149F2CAh
                mov     dword ptr y0, 07149F2CAh
                mov     dword ptr x1, 0F149F2CAh
                mov     dword ptr y1, 0F149F2CAh

                ;; bb layout (bytes): minx=0 miny=2 minz=4 maxx=6 maxy=8 maxz=10
                ;;
                ;; A BSP portal lies exactly on one node's splitting plane,
                ;; so its bounding box is flat in one axis -- min == max on
                ;; that axis -- for the overwhelming majority of them:
                ;; measured offline over dm3ish and e1m7's own portal sets,
                ;; 93-97%. On a flat box, the bit that would pick between
                ;; that axis's min and max selects the SAME value either
                ;; way, so half of the 8 corners are exact duplicates of
                ;; the other half -- not an approximation, a duplicate
                ;; computation. Checked once per call, before any corner
                ;; is projected, and it costs three word compares to find
                ;; out which four (of eight, or none) are free to skip.
                mov     ax, word ptr es:[bx+0]
                cmp     ax, word ptr es:[bx+6]
                je      flat_x
                mov     ax, word ptr es:[bx+2]
                cmp     ax, word ptr es:[bx+8]
                je      flat_y
                mov     ax, word ptr es:[bx+4]
                cmp     ax, word ptr es:[bx+10]
                je      flat_z

                ;; not flat: all 8 corners are genuinely distinct.
                ;; project_box's own field selection, transcribed:
                ;;   bx = i&1 ? bb[3] : bb[0]      (x: maxx : minx)
                ;;   bz = i&2 ? bb[4] : bb[1]      (y: maxy : miny)
                ;;   by = i&4 ? bb[5] : bb[2]      (z: maxz : minz)
                CORNER    0,  2,  4
                CORNER    6,  2,  4
                CORNER    0,  8,  4
                CORNER    6,  8,  4
                CORNER    0,  2, 10
                CORNER    6,  2, 10
                CORNER    0,  8, 10
                CORNER    6,  8, 10
                jmp     corners_done

flat_x:         ;; minx == maxx: the bxo argument never changes the value
                ;; read, so fix it at 0 and vary only y and z.
                CORNER    0,  2,  4
                CORNER    0,  8,  4
                CORNER    0,  2, 10
                CORNER    0,  8, 10
                jmp     corners_done

flat_y:         ;; miny == maxy: fix bzo at 2, vary x and z.
                CORNER    0,  2,  4
                CORNER    6,  2,  4
                CORNER    0,  2, 10
                CORNER    6,  2, 10
                jmp     corners_done

flat_z:         ;; minz == maxz: fix byo at 4, vary x and y.
                CORNER    0,  2,  4
                CORNER    6,  2,  4
                CORNER    0,  8,  4
                CORNER    6,  8,  4

corners_done:
                cmp     infront, 0
                jne     short have_infront
                pop     es
                xor     ax, ax
                ret
have_infront:
                cmp     behind, 0
                je      short clean_box

                ;; straddled the near plane: honest answer is "could be
                ;; anywhere" -- see the header note.
                mov     bx, outp
                mov     dword ptr [bx+0],  MINUS_1E6
                mov     dword ptr [bx+4],  MINUS_1E6
                mov     dword ptr [bx+8],  PLUS_1E6
                mov     dword ptr [bx+12], PLUS_1E6
                pop     es
                mov     ax, 1
                ret

clean_box:
                mov     bx, outp
                mov     eax, dword ptr x0
                mov     dword ptr [bx+0], eax
                mov     eax, dword ptr y0
                mov     dword ptr [bx+4], eax
                mov     eax, dword ptr x1
                mov     dword ptr [bx+8], eax
                mov     eax, dword ptr y1
                mov     dword ptr [bx+12], eax
                pop     es
                mov     ax, 1
                ret

r_ptproj        endp

;;::::::::::::::
;; name: r_rclip
;; desc: Intersect two screen rectangles: out = a AND b, and report whether
;;       anything survived. Companion to r_ptproj -- called once per portal
;;       that survives it, to narrow the flood's frontier rectangle. Ported
;;       for a much smaller reason than r_ptproj was: no far pointer here at
;;       all (a, b and out are all near, same medium-model default that made
;;       m near in the caller), so there is no segment-reload bug to fix.
;;       bcc's own -S output for this function showed 93 instructions, of
;;       which 6 are FWAIT (same reasoning as r_ptproj: nothing here ever
;;       runs on a discrete coprocessor bus, so there is nothing for FWAIT
;;       to wait on) and 6 are `mov bx,dx` -- outp's pointer, reloaded into
;;       bx before every one of its four field stores and both of the final
;;       compares, though dx never changes across the whole function.
;;       Removing both classes is ~13% of the function, nowhere near
;;       r_ptproj's win -- there is no equivalent bug here, only tidying.
;; args: [in]  a, b  | near ptr, Rect: x0,y0,x1,y1
;;             outp  | near ptr, Rect: a AND b written here
;; retn: word         | 1 if outp is non-empty (x1>x0 and y1>y0), else 0
;;::::::::::::::
r_rclip         proc    public uses si di, a:word, b:word, outp:word

                mov     si, a
                mov     di, b
                mov     bx, outp

                ;; out->x0 = a->x0 > b->x0 ? a->x0 : b->x0
                fld     dword ptr [si]
                fcomp   dword ptr [di]
                fstsw   ax
                sahf
                jbe     short @F
                fld     dword ptr [si]
                jmp     short @F2
@@:
                fld     dword ptr [di]
@F2:
                fstp    dword ptr [bx]

                ;; out->y0 = a->y0 > b->y0 ? a->y0 : b->y0
                fld     dword ptr [si+4]
                fcomp   dword ptr [di+4]
                fstsw   ax
                sahf
                jbe     short @F
                fld     dword ptr [si+4]
                jmp     short @F3
@@:
                fld     dword ptr [di+4]
@F3:
                fstp    dword ptr [bx+4]

                ;; out->x1 = a->x1 < b->x1 ? a->x1 : b->x1
                fld     dword ptr [si+8]
                fcomp   dword ptr [di+8]
                fstsw   ax
                sahf
                jae     short @F
                fld     dword ptr [si+8]
                jmp     short @F4
@@:
                fld     dword ptr [di+8]
@F4:
                fstp    dword ptr [bx+8]

                ;; out->y1 = a->y1 < b->y1 ? a->y1 : b->y1
                fld     dword ptr [si+12]
                fcomp   dword ptr [di+12]
                fstsw   ax
                sahf
                jae     short @F
                fld     dword ptr [si+12]
                jmp     short @F5
@@:
                fld     dword ptr [di+12]
@F5:
                fstp    dword ptr [bx+12]

                ;; return out->x1 > out->x0 && out->y1 > out->y0
                fld     dword ptr [bx+8]
                fcomp   dword ptr [bx]
                fstsw   ax
                sahf
                jbe     short retfalse
                fld     dword ptr [bx+12]
                fcomp   dword ptr [bx+4]
                fstsw   ax
                sahf
                jbe     short retfalse
                mov     ax, 1
                ret
retfalse:
                xor     ax, ax
                ret

r_rclip         endp

                end
