;; r_gvcpy.asm -- r_gvcpy: one face's geometry row, far source to far
;; destination, d_faces.c's d_draw_faces:331-333.
;;
;; bcc's own -S output for this exact shape (both pointers far, compiled
;; standalone as gvcopy.c to match) showed the real cost:
;;
;;      mov     es, word ptr [bp+8]     ;; src's segment, EVERY BYTE
;;      mov     al, byte ptr es:[si]
;;      mov     es, word ptr [bp+12]    ;; dst's segment, EVERY BYTE
;;      mov     byte ptr es:[di], al
;;      inc     si
;;      inc     di
;;
;; Two segment reloads per byte, for a record up to GEOM_MAXREC (216)
;; bytes, on every visible face, every frame -- this is the same bug
;; class r_ptproj.asm and r_vxfrm.asm already fixed once each, just at
;; byte granularity instead of per-vertex. The fix is what it always is
;; for a flat byte range with two far pointers and no other work in the
;; loop: load each segment ONCE (DS for source, ES for destination -- a
;; real REP MOVSB, not a hand-rolled loop) and let the string instruction
;; walk both offsets itself.
;;
;; DS is borrowed for the source segment and MUST be restored before
;; return -- medium model addresses every near variable through DS
;; (DGROUP), including the caller's, the instant this function returns.
;; Pushed/popped around the copy, same discipline as ES elsewhere in
;; this tree.
;;
;; CLD before the string op: the direction flag is not something this
;; routine may assume as clear on entry. No FWAIT: nothing here touches
;; the FPU at all.
;;
;; name: r_gvcpy
;; desc: Copies gn bytes from src to dst, far to far. gn <= 0 is a no-op
;;       (the original C loop's `j < gn` never ran either); a negative
;;       gn is checked as SIGNED before it can turn into an enormous
;;       unsigned REP count.
;; args: [in]  src, dst | far ptr
;;             gn       | word, signed byte count
;; retn: none
;;::::::::::::::

                .model  medium, pascal
                .386

.code

;;::::::::::::::
r_gvcpy         proc    public uses cx si di, src:dword, dst:dword, gn:word

                cmp     gn, 0
                jle     gvcpy_done      ;; signed compare -- see header

                push    ds
                push    es
                lds     si, src         ;; DS:SI -> src, ONCE
                les     di, dst         ;; ES:DI -> dst, ONCE
                mov     cx, gn
                cld
                rep     movsb
                pop     es
                pop     ds

gvcpy_done:
                ret

r_gvcpy         endp

                end
