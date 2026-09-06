;; mglstub -- the BASIC runtime, as far as mgl reaches for it.
;;
;; UGLV.LIB is built with __CMP__=VBD, so __LANG_BAS__ is on and the cold
;; paths call into the BASIC runtime: uglInit registers its exit handler
;; with B_ONEXIT, and dos/dosmem.asm asks B$SETM to give the far heap
;; back before it takes memory from DOS. A free-standing test links
;; neither BASIC nor its runtime and has nothing to hand back, so both
;; are no-ops here.
;;
;; BOTH ARE PASCAL AND BOTH TAKE A DWORD, so both must RET 4. Stubs that
;; simply returned left four bytes on the stack, and uglInit then
;; returned into whatever that made the return address: the program
;; exited, quietly, code 0, having printed nothing at all. That reads as
;; a dead test rather than as a calling-convention mistake, which is what
;; it cost to find.

                .model  medium, pascal
                .386

                .code

B_ONEXIT        proc    far public,\
                        p:dword
                ret
B_ONEXIT        endp

B$SETM          proc    far public,\
                        n:dword
                ret
B$SETM          endp

                end
