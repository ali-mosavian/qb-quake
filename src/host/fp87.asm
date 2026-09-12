;; fp87.asm -- the emulator's interrupts, patched back into 8087 code.
;;
;; name: sys_fp_native / sys_fp_sites
;; desc: BC emits every floating-point instruction as INT 34h-3Dh, the
;;       Microsoft emulator's encoding, and the VBDOS runtime answers
;;       each one for the life of the run -- it never writes the real
;;       instruction back, so a single add pays an interrupt every time.
;;       This installs its own handlers, which rewrite the site into the
;;       8087 instruction it stands for and return to it, so the site
;;       costs one interrupt and then nothing. The FPU is not optional
;;       here: the pinned machine is a Pentium III.
;;
;; obs.: - The encodings are LINK's, from the FIxRQQ fixups the runtime
;;         library exports: 34h..3Bh are `wait; esc D8..DF`, 3Dh is
;;         `nop; wait`, and 3Ch is a segment override -- its next byte
;;         carries the ESC opcode with the segment in bits 7-6, DS, SS,
;;         CS, ES in that order. Every form is the same length as the
;;         interrupt it replaces, which is what makes this a patch and
;;         not a relocation.
;;       - State lives in CS. A handler runs with whatever DS the
;;         interrupted code had, and qgl's fillers run on the texture's.
                .model  medium, pascal
                .386

.code

fp_seg          db      3Eh, 36h, 2Eh, 26h      ;; ds, ss, cs, es
fp_on           dw      0
fp_n            dd      0                       ;; sites patched
fp_old          dd      10 dup (0)              ;; the runtime's vectors

FPSTUB          macro   nm, k
nm:             push    bx
                mov     bl, k
                jmp     fp_body
endm

                FPSTUB  fp_h0, 0
                FPSTUB  fp_h1, 1
                FPSTUB  fp_h2, 2
                FPSTUB  fp_h3, 3
                FPSTUB  fp_h4, 4
                FPSTUB  fp_h5, 5
                FPSTUB  fp_h6, 6
                FPSTUB  fp_h7, 7
                FPSTUB  fp_h8, 8
                FPSTUB  fp_h9, 9

fp_tab          dw      offset fp_h0, offset fp_h1, offset fp_h2
                dw      offset fp_h3, offset fp_h4, offset fp_h5
                dw      offset fp_h6, offset fp_h7, offset fp_h8
                dw      offset fp_h9

;; bl = the vector's index, 0 for INT 34h. The interrupt frame puts the
;; site two bytes back.
fp_body:        push    bp
                mov     bp, sp                  ;; bp, bx, ip, cs, flags
                push    ax
                push    ds
                mov     al, bl
                lds     bx, [bp+4]              ;; ds:bx-> past the interrupt

                cmp     al, 8
                jb      @@esc
                ja      @@wait

                ;; 3Ch: the byte after it is the ESC opcode, its top two
                ;; bits naming the segment the override carried
                mov     al, [bx]
                mov     ah, al
                or      ah, 0C0h
                mov     [bx], ah                ;; esc opcode, restored
                shr     al, 6
                push    si
                movzx   si, al
                mov     ah, cs:fp_seg[si]
                pop     si
                mov     al, 9Bh
                mov     [bx-2], ax              ;; wait, segment prefix
                jmp     short @@back

@@wait:         mov     word ptr [bx-2], 9B90h  ;; nop, wait
                jmp     short @@back

@@esc:          add     al, 0D8h
                mov     ah, al
                mov     al, 9Bh
                mov     [bx-2], ax              ;; wait, esc

@@back:         inc     dword ptr cs:fp_n
                sub     word ptr [bp+4], 2      ;; and run it as itself
                pop     ds
                pop     ax
                pop     bp
                pop     bx
                iret

;;::::::::::::::
;; sys_fp_native () -- take INT 34h-3Dh off the runtime. Once.
;;::::::::::::::
sys_fp_native proc    far public uses bx cx dx si ds es
                cmp     word ptr cs:fp_on, 0
                jne     @@out
                mov     word ptr cs:fp_on, 1

                xor     cl, cl
@@next:         mov     ah, 35h
                mov     al, 34h
                add     al, cl
                int     21h                     ;; es:bx = the runtime's
                movzx   si, cl
                shl     si, 2
                mov     word ptr cs:fp_old[si], bx
                mov     ax, es
                mov     word ptr cs:fp_old[si+2], ax

                movzx   si, cl
                shl     si, 1
                mov     dx, word ptr cs:fp_tab[si]
                push    ds
                push    cs
                pop     ds
                mov     ah, 25h
                mov     al, 34h
                add     al, cl
                int     21h
                pop     ds

                inc     cl
                cmp     cl, 10
                jb      @@next
@@out:          ret
sys_fp_native endp

;;::::::::::::::
;; sys_fp_sites () -> dx:ax = the sites patched so far
;;::::::::::::::
sys_fp_sites  proc    far public
                mov     ax, word ptr cs:fp_n
                mov     dx, word ptr cs:fp_n+2
                ret
sys_fp_sites  endp
                end
