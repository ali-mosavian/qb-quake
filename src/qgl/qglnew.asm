;; name: qglNew
;; desc: allocates a new Surface
;;
;; args: [in] typ:integer,      | Surface type (SF_MEM / SF_EMS -- the
;;                              | TABLE OFFSET, not the SURF_ enum. sf.asm
;;                              | converts at the boundary)
;;            cfmt:integer,     | color format
;;            xRes:integer,     | width (> 0; <= 16384)
;;            yRes:integer      | height (> 0)
;; retn: long                   | surface (0 if error)
;;
;; chng: sep/01 written [v1ctor]
;; obs.: transcribed from mgl's ugl/uglnew.asm. Two things differ:
;;       memAlloc -> qglMemAlloc, which reports failure as a null far
;;       pointer rather than CF; and calcBPS reads FMT_8BIT_BPP/P2B where
;;       mgl indexes ul$cfmtTB, qgl having one colour format and no CFMT
;;       layer to index.

;; NOT transcribed: uglNewMult. Its argument is a BASIC array descriptor
;; (mgl's BASARRAY, behind __LANG_BAS__) and nothing in qgl asks for a
;; batch of surfaces. The back-ends' newMult entries ARE transcribed and
;; wired, so adding it later is this file and nothing else.

                .model  medium, pascal
                .386
                option  proc:private

                include qgl.inc

qglMemAlloc     proto   far pascal :dword
qglMemFree      proto   far pascal :dword

.code
;;::::::::::::::
;; qglNew (typ:word, fmt:word, xRes:word, yRes:word) :dword
qglNew          proc    public uses bx cx di si fs,\
                        typ:word, fmt:word,\
                        xRes:word, yRes:word

                LOGBEGIN qglNew

                mov     bx, xRes
                mov     si, yRes

                ;; zero?
                test    bx, bx
                jz      @@error
                test    si, si
                jz      @@error

                mov     di, typ

                ;; check if state is OK
                cmp     qgl$dctTB[di].state, TRUE
                jne     @@error

                ;; allocate mem for Surface struct + addrTB
                LOGMSG  Surface
                mov     eax, T Surface
                mov     cx, si                  ;; addrTB size= yRes*4
                shl     cx, 2                   ;; /
                add     ax, cx
                invoke  qglMemAlloc, eax
                mov     cx, ax
                or      cx, dx
                jz      @@error

                push    dx
                mov     fs, dx                  ;; fs->sf

                ;; set Surface's fields
        ifdef   _DEBUG_
                mov     fs:[Surface.sign], QGL_SIGN
        endif
                lea     ax, [bx - 1]
                lea     dx, [si - 1]
                mov     fs:[Surface.xMin], 0
                mov     fs:[Surface.yMin], 0
                mov     fs:[Surface.xMax], ax
                mov     fs:[Surface.yMax], dx

                mov     fs:[Surface.xRes], bx
                mov     fs:[Surface.yRes], si

                mov     fs:[Surface.typ], di
                mov     ax, fmt
                mov     fs:[Surface.fmt], ax
                mov     cx, FMT_8BIT_BPP        ;; mgl reads ul$cfmtTB[fmt]
                mov     ax, FMT_8BIT_P2B        ;; here; qgl has one format
                mov     fs:[Surface.bpp], cl
                mov     fs:[Surface.p2b], al

                push    W 1
                call    calcBPS
                mov     fs:[Surface.bps], bx

                mov     fs:[Surface.pages], 1
                mov     fs:[Surface.startSL], 0

                ;; size= bps * yRes
                mov     ax, bx
                mul     si
                mov     W fs:[Surface._size+0], ax
                mov     W fs:[Surface._size+2], dx

                ;; let the LL New proc allocate the pixels and set addrTB
                LOGMSG  <LL New>
                call    qgl$dctTB[di].new       ;; dctTB[typ].new()
                pop     dx
                jc      @@err_ll                ;; error?

                xor     ax, ax                  ;; CF clean

@@exit:         LOGEND
                ret

@@err_ll:       shl     edx, 16
                invoke  qglMemFree, edx

@@error:        LOGERROR
                xor     ax, ax                  ;; return NULL
                xor     dx, dx                  ;; /
                stc                             ;; CF set
                jmp     short @@exit
qglNew          endp

;;::::::::::::::
;; qglNewEx (typ:word, fmt:word, xRes:word, yRes:word, bps:word, pages:word) :dword
qglNewEx        proc    public uses bx di si fs es,\
                        typ:word, fmt:word,\
                        xRes:word, yRes:word,\
                        bps:word, pages:word

                LOGBEGIN qglNewEx

                mov     bx, bps
                mov     si, yRes

                ;; zero?
                test    bx, bx
                jz      @@error
                test    si, si
                jz      @@error
                cmp     pages, 0
                je      @@error

                mov     di, typ

                ;; check if state is OK
                cmp     qgl$dctTB[di].state, TRUE
                jne     @@error

                imul    si, pages               ;; scanlines= pages * yRes

                ;; allocate mem for Surface struct + addrTB
                LOGMSG  Surface
                mov     eax, T Surface
                mov     cx, si                  ;; addrTB size= scanlines*4
                shl     cx, 2                   ;; /
                add     ax, cx
                invoke  qglMemAlloc, eax
                mov     cx, ax
                or      cx, dx
                jz      @@error

                push    dx
                mov     fs, dx                  ;; fs->sf

                ;; set Surface's fields
        ifdef   _DEBUG_
                mov     fs:[Surface.sign], QGL_SIGN
        endif
                mov     ax, xRes
                mov     dx, yRes
                mov     fs:[Surface.xRes], ax
                mov     fs:[Surface.yRes], dx

                dec     ax
                dec     dx
                mov     fs:[Surface.xMin], 0
                mov     fs:[Surface.yMin], 0
                mov     fs:[Surface.xMax], ax
                mov     fs:[Surface.yMax], dx

                mov     fs:[Surface.typ], di
                mov     ax, fmt
                mov     fs:[Surface.fmt], ax
                mov     cx, FMT_8BIT_BPP        ;; mgl reads ul$cfmtTB[fmt]
                mov     ax, FMT_8BIT_P2B        ;; here; qgl has one format
                mov     fs:[Surface.bpp], cl
                mov     fs:[Surface.p2b], al

                mov     fs:[Surface.bps], bx

                mov     ax, pages
                mov     fs:[Surface.pages], ax
                mov     fs:[Surface.startSL], 0

                ;; size= bps * scanlines
                mov     ax, bx
                mul     si
                mov     W fs:[Surface._size+0], ax
                mov     W fs:[Surface._size+2], dx

                ;; let the LL New proc allocate the pixels and set addrTB
                LOGMSG  <LL New>
                call    qgl$dctTB[di].new       ;; dctTB[typ].new()
                pop     dx
                jc      @@err_ll                ;; error?

                xor     ax, ax                  ;; CF clean

@@exit:         LOGEND
                ret

@@err_ll:       shl     edx, 16
                invoke  qglMemFree, edx

@@error:        LOGERROR
                xor     ax, ax                  ;; return NULL
                xor     dx, dx                  ;; /
                stc                             ;; CF set
                jmp     short @@exit
qglNewEx        endp

;;:::
;;  in: di= typ
;;      bx= xRes
;;      si= yRes
;;      cx= bpp
;;
;; out: bx= bps
calcBPS         proc    near uses ax cx dx,\
                        pages:word

                LOGBEGIN calcBPS

                ;; (!!FIX ME!! cannot handle 24 bpp)
                inc     cl                      ;; + 1 when bpp=15
                shr     cl, 4                   ;; 2 para
                shl     bx, cl                  ;; bps<<=2para(bpp+1)

                ;; must be multiple of 8
                add     bx, 7
                and     bx, not 7

                ;; bps * yRes * pages < winSize?
                mov     ax, pages
                mul     si
                mul     bx
                cmp     dx, W qgl$dctTB[di].winSize+2
                jb      @@exit
                ja      @F
                cmp     ax, W qgl$dctTB[di].winSize+0
                jbe     @@exit

@@:             LOGMSG  <gt 64k>
                ;; choose a scanline size where when it breaks the
                ;; winSize, it does that outside the visible area
                mov     cx, bx                  ;; divisor= bps
@@loop:         mov     ax, W qgl$dctTB[di].winSize+0
                mov     dx, W qgl$dctTB[di].winSize+2
                div     cx                      ;; winSize % divisor
                test    dx, dx
                jz      @@done                  ;; rem= 0?
                cmp     dx, bx
                jae     @@done                  ;; rem >= bps?
                add     cx, 8                   ;; divisor+= 8
                jmp     short @@loop

@@done:         mov     bx, cx                  ;; bps= divisor

@@exit:         LOGEND
                ret
calcBPS         endp
                end
