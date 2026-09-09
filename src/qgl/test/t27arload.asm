;; t27arload -- qglArLoad fills the store it makes, MEM and EMS alike.
;;
;; The renderer's three MEM stores loaded through qglArLoad came up ALL
;; ZEROS -- counts, handles and descriptors right, the read reporting
;; success, 17,820 bytes of nothing behind it. The loader tested the
;; window pointer with `or ax, dx` and stored ax AFTERWARDS, so the
;; destination offset was 0|segment and every read landed that many
;; bytes past the window: here at 0x1D23:1D23, which is the store's
;; contents shifted by 7,459 bytes; in the renderer 53,961 bytes past a
;; 22,926-byte block, which is somebody else's memory.
;;
;; The reference is the member itself, streamed a record-multiple at a
;; time, so no buffer the size of the member is needed: the SUM of every
;; byte the store hands back has to equal the sum of the first NBYTES of
;; the archive, on both store types. A sum is enough -- what went wrong
;; was not one byte, it was all of them -- and the EMS arm still checks
;; the record on the page seam byte for byte.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglArLoad       proto   far :dword, :word, :word, :dword, :word
qglArWin        proto   far :dword, :dword
qglArPerpg      proto   far :dword
qglArFree       proto   far :dword
qglArNew        proto   far :word, :word, :dword, :word
qglZipOpen      proto   far :dword
qglZipRead      proto   far :word, :dword, :dword
qglZipClose     proto   far :word

REC             equ     6
CNT             equ     3821            ;; faces.pag: 22,926 bytes
NBYTES          equ     CNT * REC
CHUNK           equ     60              ;; a record multiple: 16380 = 273 * 60
SEAM_CHUNK      equ     16380 / CHUNK   ;; the chunk holding record 2730
SEAM_IDX        equ     2730            ;; first record of EMS page 1
SLOT            equ     2

.data
n_ref           db      'reference streams whole$'
n_mopen         db      'MEM store loads        $'
n_msum_lo       db      'MEM sum lo == archive  $'
n_msum_hi       db      'MEM sum hi == archive  $'
n_eopen         db      'EMS store loads        $'
n_esum_lo       db      'EMS sum lo == archive  $'
n_esum_hi       db      'EMS sum hi == archive  $'
n_eseam         db      'EMS record on the seam $'
s_ref           db      'archive sum            $'
s_mem           db      'MEM store sum          $'
s_ems           db      'EMS store sum          $'

member          db      "assets.zip::faces.pag",0
memberp         dd      0

buf             db      CHUNK dup (0)
bufp            dd      0
seam            db      REC dup (0)     ;; record SEAM_IDX, from the archive

refsum          dd      0
left            dd      0
ask             dd      0
acc             dd      0
hm              dd      0
he              dd      0
got             dd      0

.code

;;::::::::::::::
;; sumrun -- add cx bytes at es:di into acc
;;::::::::::::::
sumrun          proc    near private uses ax cx di
                jcxz    @@done
@@:             mov     al, es:[di]
                movzx   eax, al
                add     acc, eax
                inc     di
                loop    @B
@@done:         ret
sumrun          endp

;;::::::::::::::
;; sumstore -- acc = every byte of store h, one window at a time
;;::::::::::::::
sumstore        proc    near private uses ax bx cx dx si di es,\
                        h:dword
                local   idx:dword, remain:dword, payload:dword, perpg:word

                mov     acc, 0
                invoke  qglArPerpg, h
                mov     perpg, ax
                movzx   eax, ax
                imul    eax, REC
                mov     payload, eax
                mov     remain, NBYTES
                mov     idx, 0
@@page:         cmp     remain, 0
                je      @@done
                invoke  qglArWin, h, idx
                mov     es, dx
                mov     di, ax
                mov     ecx, payload
                cmp     ecx, remain
                jbe     @F
                mov     ecx, remain
@@:             call    sumrun
                sub     remain, ecx
                movzx   eax, perpg
                add     idx, eax
                jmp     @@page
@@done:         ret
sumstore        endp


tmain           proc    far public uses bx cx dx si di es

                mov     word ptr memberp, offset member
                mov     word ptr memberp+2, ds
                mov     word ptr bufp, offset buf
                mov     word ptr bufp+2, ds

                invoke  qglGemInit

                ;;
                ;; the reference: the first NBYTES of the member, streamed,
                ;; summed, and the seam record kept. The member is 22,930
                ;; bytes -- four of padding past the last record -- and
                ;; summing it whole was a reference no correct store could
                ;; match.
                ;;
                mov     acc, 0
                invoke  qglZipOpen, memberp
                mov     bx, ax
                xor     si, si                  ;; chunk index
                mov     left, NBYTES
@@ref:          mov     ecx, CHUNK
                cmp     ecx, left
                jbe     @F
                mov     ecx, left
@@:             jecxz   @@refdone
                mov     ask, ecx
                invoke  qglZipRead, bx, bufp, ask
                test    ax, ax
                jz      @@refdone
                sub     left, eax
                push    ax
                cmp     si, SEAM_CHUNK
                jne     @F
                mov     edx, dword ptr buf
                mov     dword ptr seam, edx
                mov     dx, word ptr buf+4
                mov     word ptr seam+4, dx
@@:             pop     cx
                push    ds
                pop     es
                mov     di, offset buf
                call    sumrun
                inc     si
                jmp     @@ref
@@refdone:      invoke  qglZipClose, bx
                mov     eax, acc
                mov     refsum, eax
                invoke  tshow, offset s_ref, refsum
                NZ      eax
                CHK     n_ref, ax, 1

                ;;
                ;; MEM
                ;;
                invoke  qglArLoad, memberp, QGL_AR_MEM, REC, CNT, 0
                SAVEP   hm
                NZ      W hm
                CHK     n_mopen, ax, 1
                invoke  sumstore, hm
                mov     eax, acc
                mov     got, eax
                invoke  tshow, offset s_mem, got
                CHK     n_msum_lo, W got, W refsum
                CHK     n_msum_hi, W got+2, W refsum+2
                invoke  qglArFree, hm

                ;;
                ;; EMS
                ;;
                invoke  qglArLoad, memberp, QGL_AR_EMS, REC, CNT, SLOT
                SAVEP   he
                NZ      W he
                CHK     n_eopen, ax, 1
                invoke  sumstore, he
                mov     eax, acc
                mov     got, eax
                invoke  tshow, offset s_ems, got
                CHK     n_esum_lo, W got, W refsum
                CHK     n_esum_hi, W got+2, W refsum+2

                ;; the record on the seam, byte for byte
                invoke  qglArWin, he, SEAM_IDX
                mov     es, dx
                mov     di, ax
                mov     si, offset seam
                mov     cx, REC
                xor     bx, bx
@@cmp:          mov     al, es:[di]
                cmp     al, [si]
                je      @F
                inc     bx
@@:             inc     si
                inc     di
                loop    @@cmp
                CHK     n_eseam, bx, 0
                invoke  qglArFree, he

                ret
tmain           endp
                end
