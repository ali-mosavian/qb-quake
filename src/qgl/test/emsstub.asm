;; emsstub -- mgl's EMS entry points, over qgl's own, so ar.asm links
;; into the native suite without UGLV.LIB.
;;
;; ar.asm still calls emsAlloc / emsFree / emsMapEx by mgl's names: its
;; EMS path leans on emsMapEx's own record of what each slot holds, and
;; qglGemMap keeps no such record, so the swap in production is its own
;; cut. Here nothing is timed, so a plain INT 67h per map is fine.
;;
;; The contract, from ar.asm's protos and comments: emsAlloc takes BYTES
;; and returns a handle in ax (0 on failure); emsMapEx takes handle,
;; logical page, slot and returns the window's segment in ax.

                .model  medium, pascal
                .386

qglGemAlloc     proto   far pascal :dword
qglGemFree      proto   far pascal :word
qglGemMap       proto   far pascal :word, :word, :word

.code

emsAlloc        proc    far public,\
                        nbytes:dword
                invoke  qglGemAlloc, nbytes
                ret
emsAlloc        endp

emsFree         proc    far public,\
                        hnd:word
                invoke  qglGemFree, hnd
                ret
emsFree         endp

emsMapEx        proc    far public,\
                        hnd:word, logpage:word, slot:word
                invoke  qglGemMap, hnd, logpage, slot
                ret
emsMapEx        endp

                end
