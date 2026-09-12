;; t14far -- far pointers that cross a 64K offset wrap.
;;
;; qglMemCopy and qglFileRead both advance a far pointer by adding to
;; the offset and carrying into the segment with `adc seg, 0`. That adds
;; ONE to the segment when the offset wraps, and a wrapped offset is
;; 65536 bytes, which is 4096 paragraphs. So everything past the first
;; 64K lands 65520 bytes short of where it belongs.
;;
;; Nothing had crossed that boundary: the qgl suite's surfaces are a few
;; kilobytes and the fillers work a row at a time. The renderer's atlas is
;; 114688 bytes, so it would have crossed on the first real transfer.
;;
;; THE ORACLE NEVER ADVANCES A POINTER. Every probe recomputes its own
;; address from the base segment and a linear index -- seg + (i >> 4),
;; offset i and 15 -- so a bug in qgl's advance cannot hide inside the
;; check for it. The file side is verified by re-reading in 4K pieces,
;; which never crosses a wrap and is therefore independent of the path
;; under test.
;;
;; The sizes are the ones that actually occur: a nonzero start crossing
;; 32K, an exact 64K transition, and fgeom.bin, the project's own 114688
;; byte atlas.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglMemAlloc   proto   far :dword
qglMemFree    proto   far :dword
qglMemCopy    proto   far :dword, :dword, :dword
qglFileOpen   proto   far :dword
qglFileRead   proto   far :word, :dword, :dword
qglFileClose  proto   far :word

ATLAS           equ     114688                  ;; fgeom.bin, exactly

.data
n_alloc         db      'two 112K blocks        $'
n_near32        db      'nonzero start over 32K $'
n_at64          db      'exact 64K transition   $'
n_atlas         db      'the 114688 byte atlas  $'
n_hiofs         db      'source at offset FFF0h $'
n_fopen         db      'fgeom.bin opens        $'
n_fread         db      'reads all 114688 bytes $'
n_fdata         db      'and every byte is right$'
n_fhi           db      'read into offset FFF0h $'

fname           db      "fgeom.bin",0
fnp             dd      0
srcb            dd      0
dstb            dd      0
chunk           db      4096 dup (0)
chunkp          dd      0
bad             dw      0
fh              dw      0
srcoff          dd      0               ;; a far pointer INTO the source block
srchi           dd      0               ;; the same bytes, addressed high
dsthi           dd      0

.code

;;::::::::::::::
;; farof -- the far address of byte `i` of a block, from scratch.
;;
;; INTERNAL. base = the block's segment (its offset is always 0), i = the
;; linear index. Returns dx:ax. NOTHING here advances a pointer: that is
;; the whole point, since the code under test is the code that advances
;; pointers.
;;::::::::::::::
farof            proc    near private uses bx cx,\
                        base:word, i:dword

                mov     eax, i
                mov     edx, eax
                shr     eax, 4                  ;; paragraphs into the block
                and     dx, 15                  ;; and the byte within one
                add     ax, base
                xchg    ax, dx                  ;; dx:ax = seg:ofs
                ret
farof            endp

;;:::::::::::::: the byte a given index should hold
pat             proc    near private uses cx dx,\
                        i:dword
                mov     eax, i
                mov     edx, eax
                shr     edx, 8
                xor     eax, edx                ;; varies with the HIGH half,
                and     ax, 0FFh                ;; so a wrong segment shows
                ret
pat             endp

;;:::::::::::::: fill a block with that pattern
fill            proc    near private uses bx cx dx si di es,\
                        base:word, n:dword

                mov     esi, 0
@@b:            cmp     esi, n
                jae     @@out
                invoke  pat, esi
                mov     bl, al
                invoke  farof, base, esi
                mov     es, dx
                mov     di, ax
                mov     es:[di], bl
                inc     esi
                jmp     @@b
@@out:          ret
fill            endp

;;::::::::::::::
;; check -- dst[0..n) must equal the pattern for src index start+k.
;;
;; Every byte, not a sample: the wrap puts a whole 64K region 65520 bytes
;; out of place, and a sampled check that happened to miss the far side
;; would report success.
;;::::::::::::::
check           proc    near private uses bx cx dx si di es,\
                        base:word, start:dword, n:dword

                mov     bad, 0
                mov     esi, 0
@@b:            cmp     esi, n
                jae     @@out
                mov     eax, esi
                add     eax, start
                invoke  pat, eax
                mov     bl, al
                invoke  farof, base, esi
                mov     es, dx
                mov     di, ax
                cmp     es:[di], bl
                je      @F
                inc     bad
@@:             inc     esi
                jmp     @@b
@@out:          mov     ax, bad
                ret
check           endp


;;::::::::::::::
;; fverify -- the block must equal fgeom.bin, byte for byte.
;;
;; Reads the file again in 4K pieces, which never crosses a wrap, so this
;; cannot share the bug it is checking for. Addresses the block with
;; farof, which never advances a pointer either.
;;::::::::::::::
fverify         proc    near private uses bx cx dx si di es,\
                        base:word

                invoke  qglFileOpen, fnp
                mov     fh, ax
                mov     bad, 0
                mov     esi, 0
@@piece:        cmp     esi, ATLAS
                jae     @@fdone
                invoke  qglFileRead, fh, chunkp, 4096
                xor     ecx, ecx
@@byte:         cmp     cx, 4096
                jae     @@next
                mov     eax, esi
                add     eax, ecx
                cmp     eax, ATLAS
                jae     @@next
                invoke  farof, base, eax
                mov     es, dx
                mov     di, ax
                mov     bx, cx
                mov     al, chunk[bx]
                cmp     es:[di], al
                je      @F
                inc     bad
@@:             inc     ecx
                jmp     @@byte
@@next:         add     esi, 4096
                jmp     @@piece

@@fdone:        invoke  qglFileClose, fh
                mov     ax, bad
                ret
fverify         endp


tmain           proc    far public uses bx cx dx si di es

                invoke  qglSfInit

                invoke  qglMemAlloc, ATLAS
                SAVEP   srcb
                invoke  qglMemAlloc, ATLAS
                SAVEP   dstb
                mov     ax, word ptr srcb+2
                mov     bx, word ptr dstb+2
                test    ax, ax
                jz      @F
                test    bx, bx
                jz      @F
                mov     ax, 1
                jmp     @@ok
@@:             xor     ax, ax
@@ok:           CHK     n_alloc, ax, 1

                mov     word ptr fnp, offset fname
                mov     word ptr fnp+2, ds
                mov     word ptr chunkp, offset chunk
                mov     word ptr chunkp+2, ds

                invoke  fill, word ptr srcb+2, ATLAS

                ;;
                ;; 1. a nonzero start, crossing 32K
                ;;
                invoke  farof, word ptr srcb+2, 07000h
                mov     word ptr srcoff, ax
                mov     word ptr srcoff+2, dx
                invoke  qglMemCopy, dstb, srcoff, 03000h
                invoke  check, word ptr dstb+2, 07000h, 03000h
                CHK     n_near32, ax, 0

                ;;
                ;; 2. straight over the 64K line
                ;;
                invoke  qglMemCopy, dstb, srcb, 018000h
                invoke  check, word ptr dstb+2, 0, 018000h
                CHK     n_at64, ax, 0

                ;;
                ;; 3. and the whole atlas
                ;;
                invoke  qglMemCopy, dstb, srcb, ATLAS
                invoke  check, word ptr dstb+2, 0, ATLAS
                CHK     n_atlas, ax, 0

                ;;
                ;; 4. THE SAME BYTES, ADDRESSED WITH A HIGH OFFSET. A
                ;;    caller may hand in any valid far pointer, and this
                ;;    one carries out of the offset on the very first
                ;;    advance -- before any renormalising has happened, so
                ;;    it is the case the carry itself has to get right.
                ;;    It also means the first run starts 16 bytes from the
                ;;    end of its segment, which is what makes capping a
                ;;    run at 32K insufficient on its own.
                ;;
                mov     ax, word ptr srcb+2
                sub     ax, 0FFFh
                mov     word ptr srchi+2, ax
                mov     word ptr srchi, 0FFF0h
                invoke  qglMemCopy, dstb, srchi, ATLAS
                invoke  check, word ptr dstb+2, 0, ATLAS
                CHK     n_hiofs, ax, 0

                ;;
                ;; 5. the same distance, off disk, in ONE read
                ;;
                invoke  qglFileOpen, fnp
                mov     fh, ax
                NZ      ax
                CHK     n_fopen, ax, 1

                invoke  qglFileRead, fh, dstb, ATLAS
                mov     bx, dx
                CHK     n_fread, ax, ATLAS and 0FFFFh
                invoke  qglFileClose, fh

                invoke  fverify, word ptr dstb+2
                CHK     n_fdata, ax, 0

                ;;
                ;; 6. and the same read into a destination addressed
                ;;    high, which is what file_read's own entry
                ;;    normalisation is for
                ;;
                mov     ax, word ptr dstb+2
                sub     ax, 0FFFh
                mov     word ptr dsthi+2, ax
                mov     word ptr dsthi, 0FFF0h
                invoke  qglFileOpen, fnp
                mov     fh, ax
                invoke  qglFileRead, fh, dsthi, ATLAS
                invoke  qglFileClose, fh
                invoke  fverify, word ptr dstb+2
                CHK     n_fhi, ax, 0

                invoke  qglMemFree, srcb
                invoke  qglMemFree, dstb
                ret
tmain           endp
                end
