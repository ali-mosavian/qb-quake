;; name: fmtstub
;; desc: Stand-ins for six of the nine symbols mgl links UNCONDITIONALLY
;;       from the 15/16/32-bit colour format drivers, plus the REAL bodies
;;       of the other three -- see the correction note below, which is the
;;       important part of this file's history.
;;
;;       b15_Init/b15_End, b16_Init/b16_End, b32_Init/b32_End are six FAR
;;       pointers in uglmain.asm's ul$cfmtTB, a static DATA table built at
;;       assemble time (`CFMT <bNN_Init, bNN_End,>` per format) and walked
;;       in full by uglInit/_end's CLR_FORMATS loops -- the only two
;;       places in all of mgl that touch every row, both unconditional.
;;       Every OTHER DC operation indexes ul$cfmtTB by the DC's own .fmt,
;;       which for qrender is always FMT_8BIT (env.c_fmt is UGL.8BIT
;;       everywhere, confirmed by grep) -- so these six are genuinely
;;       dead at runtime and safe to no-op.
;;
;;       b15_8, b16_8, b32_8 are NOT safe to no-op, and finding that out
;;       cost a "String space corrupt" crash in MOD_TEX. They live in
;;       8conv.asm's b8_rowReadTB, and that table is keyed on BUFFER
;;       FORMAT -- what pixel depth a BMP is stored in ON DISK (BF_8BIT,
;;       BF_15BIT, ... alongside BF_IDX8/4/1, all read by b8_SetPal) --
;;       not on any DC's .fmt. qrender's own DCs are always 8-bit, but a
;;       texture's source .bmp is not guaranteed to be, and uglNewBMPEx
;;       converts whatever depth it finds through this exact table. A
;;       no-op silently skipped the conversion instead of refusing it,
;;       leaving the destination row uninitialised and corrupting
;;       whatever the far heap put there next. These three are the real
;;       bodies from 15conv.asm/16conv.asm/32conv.asm, unmodified, kept
;;       here rather than in mgl because that is where the rest of this
;;       file's symbols live and there is no reason to split them.
;;
;;       This lives in QRENDER's tree, not mgl's: the real b15/b16/b32
;;       modules are untouched in the library, only left out of what this
;;       project's native build compiles into UGLV.LIB (see
;;       tools/native/Makefile's STUB library). Swap the Makefile groups
;;       back and this file goes unused.
;;
;;       UGL_CODE (from ugl.inc, included below) opens `ugl_text segment
;;       ... public`, a PUBLIC-combine segment -- every module that opens
;;       it contributes to the SAME physical segment at link time, which
;;       is what lets 8conv.asm's near `dw b15_8` table entry resolve
;;       against a b15_8 defined in a completely different source file.
;;
;; chng: aug/26 written, replacing 15main/16main/32main/15conv/16conv/32conv
;;       in qrender's build
;; chng: aug/26 b15_8/b16_8/b32_8 restored to their real bodies after a
;;       no-op version corrupted BASIC's string heap during texture load

                .model  medium, pascal
                .386
                option  proc:private

                include ugl.inc

UGL_CODE

b15_Init        proc    far public uses bx cx si dx
                clc
                ret
b15_Init        endp

b15_End         proc    far public uses bx cx si dx
                clc
                ret
b15_End         endp

b16_Init        proc    far public uses bx cx si dx
                clc
                ret
b16_Init        endp

b16_End         proc    far public uses bx cx si dx
                clc
                ret
b16_End         endp

b32_Init        proc    far public uses bx cx si dx
                clc
                ret
b32_Init        endp

b32_End         proc    far public uses bx cx si dx
                clc
                ret
b32_End         endp

;; r3:g3:b2 -> a1:r5:g5:b5. Verbatim from 15conv.asm.
b15_8           proc    near public
                pusha

@@loop:         xor     ax, ax
                mov     al, ds:[si]             ;; al= red:green:blue
                inc     si                      ;; ++x

                mov     dx, ax                  ;; dx= 00000000:rrrgggbb
                mov     bx, ax                  ;; bx= 00000000:rrrgggbb
                shl     ax, 3                   ;; ax= 00000rrr:gggbb000
                shl     dx, 7                   ;; dx= 0rrrgggb:b0000000
                and     ax, 0000000000011000b   ;; ax= 00000000:000bb000
                shl     bx, 5                   ;; bx= 000rrrgg:gbb00000
                and     dx, 0111000000000000b   ;; dx= 0rrr0000:00000000
                and     bx, 0000001110000000b   ;; bx= 000000gg:g0000000
                or      ax, dx                  ;; ax= 0rrr0000:000bb000
                or      ax, bx                  ;; ax= 0rrr00gg:g00bb000

                mov     es:[di], ax
                add     di, T word
                dec     cx
                jnz     @@loop

                popa
                ret
b15_8           endp

;; r3:g3:b2 -> r5:g6:b5. Verbatim from 16conv.asm.
b16_8           proc    near public
                pusha

@@loop:         xor     ax, ax
                mov     al, ds:[si]             ;; al= red:green:blue
                inc     si                      ;; ++x

                mov     dx, ax                  ;; dx= 00000000:rrrgggbb
                mov     bx, ax                  ;; bx= 00000000:rrrgggbb
                shl     ax, 3                   ;; ax= 00000rrr:gggbb000
                shl     dx, 8                   ;; dx= rrrgggbb:00000000
                and     ax, 0000000000011000b   ;; ax= 00000000:000bb000
                shl     bx, 6                   ;; bx= 00rrrggg:bb000000
                and     dx, 1110000000000000b   ;; dx= rrr00000:00000000
                and     bx, 0000011100000000b   ;; bx= 00000ggg:00000000
                or      ax, dx                  ;; ax= rrr00000:000bb000
                or      ax, bx                  ;; ax= rrr00ggg:000bb000

                mov     es:[di], ax
                add     di, T word
                dec     cx
                jnz     @@loop

                popa
                ret
b16_8           endp

;; r3:g3:b2 -> a8:r8:g8:b8. Verbatim from 32conv.asm.
b32_8           proc    near public
                pusha

@@loop:         xor     eax, eax
                mov     al, ds:[si]             ;; al= red:green:blue
                inc     si                      ;; ++x

                mov     edx, eax                ;; edx= 0::00000000:rrrgggbb
                mov     ebx, eax                ;; ebx= 0::00000000:rrrgggbb
                shl     eax, 6                  ;; eax= 0::00rrrggg:bb000000
                shl     edx, 16                 ;; edx= 00000000:rrrgggbb::0
                and     eax, 0000000011000000b  ;; eax= 0::0:bb000000
                shl     ebx, 11                 ;; ebx= ?::gggbb000:00000000
                and     edx, 111000000000000000000000b;; edx= 0:rrr00000::0
                and     ebx, 000000001110000000000000b;; ebx= 0::ggg00000:0
                or      eax, edx                ;; eax= 0:rrr00000::0:bb000000
                or      eax, ebx                ;; eax= 0:rrr00000::ggg00000:bb000000

                mov     es:[di], eax
                add     di, T dword
                dec     cx
                jnz     @@loop

                popa
                ret
b32_8           endp

UGL_ENDS
                end
