;; sf.asm -- the surface boundary: what BASIC and C call, and nothing else.
;;
;; name: qglSfInit / qglSfNew / qglSfFree / qglSfRow /
;;       qglSfView / qglSfLoad / qglSfPget / qglSfPset
;; desc: a surface is pixels plus a width, and it does not say where it
;;       lives. qglSfRow answers with a far pointer either way.
;;
;;       EVERYTHING BELOW IS A SHIM. The layer itself is mgl's, transcribed
;;       into qglnew.asm / qglview.asm / qgldc.asm / dct/dctmem.asm /
;;       dct/dctems.asm; a row comes out of a per-scanline address table
;;       there, not out of arithmetic here. What is left in this file is
;;       the boundary -- argument order, the public SURF_ enum, the
;;       BASIC-only entries -- plus the dispatch table itself, which mgl
;;       keeps in uglmain.asm and qgl has nowhere else to put.
;;
;;       THE PUBLIC KIND IS NOT THE TABLE OFFSET. SURF_CMEM/SURF_EMS are 0
;;       and 2 and have been told to BASIC as such; SF_MEM/SF_EMS are the
;;       byte offsets the transcribed code indexes with. qgl$Kind is the
;;       one place either is converted.
;;
;;       THE SLOT IS NOT THE SURFACE'S. The plain accessors use mgl's
;;       fixed read and write pages; a caller wanting another window says
;;       so at the point of access, through the Ex form. See qgl.inc.
;;
;; obs.: - an EMS surface's bps must divide 16K, or a row would straddle
;;         two physical pages and one pointer could not cover it.
;;         qglSfNewEx REFUSES rather than padding: every EMS surface this
;;         renderer has is a power of two already (atlas cells
;;         64/32/16/8, font 8), and silently padding would waste memory
;;         nobody asked to spend. This guard is qgl's, not mgl's.
;;       - the header and the PIXELS are two allocations now, which is
;;         mgl's shape: qglNewEx allocates the struct and its address
;;         table, and the back-end's `new` allocates the pixels. qglSfFree
;;         therefore frees both, through the back-end's `del`.
;;       - qglSfViewNew allocates the header and its address table and
;;         then aims it at part of another surface's store. The pixels
;;         stay the parent's; only the header is new.

                .model medium, pascal
                .386

                include qgl.inc

qglMemAlloc   proto   far pascal :dword
qglMemFree    proto   far pascal :dword

qglNew        proto   far pascal :word, :word, :word, :word
qglNewEx      proto   far pascal :word, :word, :word, :word, :word, :word
qglNewView    proto   far pascal :dword, :dword, :word, :word
qglSetView    proto   far pascal :dword, :dword

qglSfAccessRd   proto far pascal :dword, :word
qglSfAccessWr   proto far pascal :dword, :word
qglSfAccessRdEx proto far pascal :dword, :word, :word
qglSfAccessWrEx proto far pascal :dword, :word, :word

qglSfInit     proto   far pascal
qglSfNewEx    proto   far pascal :word, :word, :word, :word
qglSfNew      proto   far pascal :word, :word, :word
qglSfFree     proto   far pascal :dword
qglSfView     proto   far pascal :dword, :dword, :dword, :word, :word, :word

qglGemInit        proto   far pascal

qglFileOpen   proto   far pascal :dword
qglFileRead   proto   far pascal :word, :dword, :dword
qglFileClose  proto   far pascal :word
qglFileSize   proto   far pascal :word

IFDEF __BASIC__
qglFileOpenBas proto far pascal :word
ENDIF


.code

;;::::::::::::::
;; qglAbi ( what:word ) -> ax = the assembly's own value for a constant
;;
;; The ONE place a BASIC caller can ask the layer what it actually
;; believes. qgl.bi is generated from qgl.inc so the two cannot drift on
;; paper, but generated or not, nothing had ever checked that the EXE on
;; disk agrees with the header the BASIC beside it was compiled against.
;; abitest.bas asks here and compares.
;;
;; The order is the order qgl.bi declares them in, and adding a constant
;; means adding it in both places -- which the test then notices.
;;
;; qgl's own; mgl has no counterpart.
;;::::::::::::::
qglAbi         proc    public uses bx,\
                        what:word

                mov     bx, what
                cmp     bx, ABI_N
                jae     @@bad
                shl     bx, 1
                mov     ax, cs:qgl$abiTB[bx]
                ret
@@bad:          mov     ax, -1
                ret
qglAbi         endp

qgl$abiTB       dw      MEM_LARGEST, MEM_TOTAL
                dw      SURF_CMEM, SURF_EMS
                dw      QGL_Z_OFF, QGL_Z_SET, QGL_Z_TEST
                dw      QGL_M_WIRE, QGL_M_FLAT, QGL_M_TEX, QGL_M_PTEX
ABI_N           equ     11


;;::::::::::::::
;; The failed-driver stubs, mgl's ugl_Far / ugl_Near (uglmain.asm). An
;; entry whose _init reported failure gets these, so a call through it
;; returns an error rather than jumping to offset zero.
;;::::::::::::::
qgl_Far         proc    far public
                xor     ax, ax
                xor     dx, dx
                stc
                ret
qgl_Far         endp

;;::::::::::::::
;; The middle table entry. mgl's is DC_BNK, a banked back-end; qgl has no
;; second kind, and the slot exists only so SF_EMS stays 2 * T SurfaceOps
;; while SURF_EMS stays 2. Its _init refuses, so qglSfInit fills it with
;; the stubs above and marks it dead.
;;::::::::::::::
qgl_nul_End     proc    far public
                clc
                ret
qgl_nul_End     endp


;;::::::::::::::
;; qgl$Kind -- the public SURF_ enum to the dispatch table's byte offset.
;;
;; INTERNAL: ax = SURF_CMEM or SURF_EMS. ax = SF_MEM or SF_EMS back, CF
;; set if it was neither.
;;::::::::::::::
qgl$Kind        proc    near private
                cmp     ax, SURF_CMEM
                je      @@mem
                cmp     ax, SURF_EMS
                je      @@ems
                stc
                ret
@@mem:          mov     ax, SF_MEM
                clc
                ret
@@ems:          mov     ax, SF_EMS
                clc
                ret
qgl$Kind        endp


;;::::::::::::::
;; qglSfNew ( w:word, h:word, where:word ) -> far ptr, or 0:0
;;
;; The common case: one byte a pixel, so the stride is the width.
;;
;; THROUGH qglNew, WHICH MEANS THROUGH calcBPS, and that is load-bearing
;; rather than tidy. The address table places a row that would straddle
;; the back-end's window (64K conventional, 16K EMS) at the START of the
;; next window instead -- the offset it would have had is discarded, which
;; is mgl's `and bx, ax` in qgl_mem_New. That is only safe if the tail it
;; skips lies outside the visible part of the row, and calcBPS is what
;; arranges that: it widens the scanline until the window divides evenly
;; or leaves at least a whole row spare. Handing the width straight
;; through as the stride, which this used to do, put the seam in the
;; middle of a row -- t03surf's 320x220 surface had rows 204 and 205
;; overlapping by 64 bytes.
;;
;; qglSfNewEx keeps the caller's stride and therefore the caller's
;; problem; nothing that uses it exceeds one window.
;;::::::::::::::
qglSfNew      proc    public uses bx cx si di es,\
                        wid:word, hgt:word, whr:word

                local   typ:word

                invoke  qglSfInit               ;; see qglSfNewEx's note

                mov     ax, whr
                call    qgl$Kind
                jc      @@refuse
                mov     typ, ax

                cmp     ax, SF_EMS
                jne     @@make
                mov     ax, wid
                call    qgl$EmsBps
                jc      @@refuse

@@make:         invoke  qglNew, typ, FMT_8BIT, wid, hgt
                test    dx, dx
                jz      @@refuse

                xor     ax, ax
                ret

@@refuse:       xor     ax, ax
                xor     dx, dx
                ret
qglSfNew      endp


;;::::::::::::::
;; qgl$EmsBps -- an EMS row must not straddle a physical page, so bps has
;; to divide 16K. Refuse rather than pad: every EMS surface this renderer
;; has is a power of two already (atlas cells 64/32/16/8, font 8), and
;; padding would waste memory nobody asked to spend.
;;
;; qgl's own guard, not mgl's -- mgl pads through calcBPS instead.
;;
;; INTERNAL: ax = bps. CF set if it will not do; ax preserved.
;;::::::::::::::
qgl$EmsBps      proc    near private uses cx
                test    ax, ax
                jz      @@no
                cmp     ax, 4000h
                ja      @@no
                mov     cx, ax
                dec     cx
                test    ax, cx
                jnz     @@no                    ;; not a power of two
                clc
                ret
@@no:           stc
                ret
qgl$EmsBps      endp


;;::::::::::::::
;; qglSfNewEx ( w:word, h:word, stride:word, where:word )
;;
;; A stride wider than the row is what a depth buffer needs -- two bytes
;; a pixel -- and what padding an EMS row up to a power of two needs. The
;; width stays in PIXELS either way: xRes is what every clip and every
;; pget indexes against, and a surface that lies about it makes each of
;; those wrong by exactly the factor it lied by.
;;::::::::::::::
qglSfNewEx   proc    public uses bx cx si di es,\
                        wid:word, hgt:word, strd:word, whr:word

                local   typ:word

                ;; THE LAYER INITIALISES ITSELF, which mgl does not do:
                ;; uglInit "must be the 1st called" and a DC made before it
                ;; dispatches through a table of NULLs. qgl never had that
                ;; rule -- every caller and half the suite creates surfaces
                ;; without an init call -- and the failure is a jump to
                ;; offset zero rather than an error, so the guard goes here
                ;; and in the other two places a Surface can first appear
                ;; (mgldc.asm, mglems.asm, vga.asm). qglSfInit is
                ;; idempotent: after the first call it is three compares.
                invoke  qglSfInit

                mov     ax, strd
                cmp     ax, wid
                jb      @@refuse                ;; a row that does not fit

                mov     ax, whr
                call    qgl$Kind
                jc      @@refuse
                mov     typ, ax

                cmp     ax, SF_EMS
                jne     @@make
                mov     ax, strd
                call    qgl$EmsBps
                jc      @@refuse

@@make:         invoke  qglNewEx, typ, FMT_8BIT, wid, hgt, strd, 1
                test    dx, dx
                jz      @@refuse

                xor     ax, ax
                ret

@@refuse:       xor     ax, ax
                xor     dx, dx
                ret
qglSfNewEx   endp


;;::::::::::::::
;; qglSfFree ( s:far ptr )
;;
;; The back-end's `del` frees the pixels -- the EMS handle, or the
;; conventional block -- and this frees the struct and its address table.
;; mgl's uglDel, minus the write-back of NULL to the caller's variable.
;;::::::::::::::
qglSfFree     proc    public uses bx cx es fs,\
                        s:dword

                les     bx, s
                mov     ax, es
                or      ax, bx
                jz      @F

                push    es                      ;; the back-end wants fs->sf
                pop     fs
                mov     bx, fs:[Surface.typ]
                call    qgl$dctTB[bx].del       ;; dctTB[typ].del()

                invoke  qglMemFree, s
@@:             ret
qglSfFree     endp


;;::::::::::::::
;; qglSfRdRow / qglSfWrRow ( s:far ptr, y:word ) -> far ptr
;; qglSfRdRowEx / qglSfWrRowEx ( s, y, slot:word ) -> far ptr
;;
;; Say which you are doing. For a conventional surface the four are one
;; routine; for an EMS one they are not, and a texture read that came in
;; through the write accessor takes the destination's window with it.
;;
;; Good until that window is remapped -- by this surface crossing a page,
;; or by anything else sharing the slot.
;;
;; NOT `uses dx`: the pointer comes home in dx:ax.
;;::::::::::::::
qglSfRdRow   proc    public,\
                        s:dword, y:word
                invoke  qglSfAccessRd, s, y
                ret
qglSfRdRow   endp

qglSfWrRow   proc    public,\
                        s:dword, y:word
                invoke  qglSfAccessWr, s, y
                ret
qglSfWrRow   endp

qglSfRdRowEx proc   public,\
                        s:dword, y:word, slot:word
                invoke  qglSfAccessRdEx, s, y, slot
                ret
qglSfRdRowEx endp

qglSfWrRowEx proc   public,\
                        s:dword, y:word, slot:word
                invoke  qglSfAccessWrEx, s, y, slot
                ret
qglSfWrRowEx endp

;;::::::::::::::
;; qglSfRow ( s:far ptr, y:word ) -> far ptr
;;
;; The READ spelling, kept because most callers only look. Anything that
;; is about to write should say so.
;;::::::::::::::
qglSfRow      proc    public,\
                        s:dword, y:word
                invoke  qglSfAccessRd, s, y
                ret
qglSfRow      endp

;;::::::::::::::
;; qglSfWindows ( s:far ptr ) -> ax = slots this kind holds at once
;;
;; ASK, DO NOT ASSUME, which is dct.inc's own instruction.
;;::::::::::::::
qglSfWindows  proc    public uses bx es,\
                        s:dword
                les     bx, s
                mov     ax, es
                or      ax, bx
                jz      @@none
                mov     bx, es:[bx].Surface.typ
                mov     ax, qgl$dctTB[bx].windows
                ret
@@none:         xor     ax, ax
                ret
qglSfWindows  endp


;;::::::::::::::
;; qglSfLoad ( s:far ptr, path:far ptr ) -> ax nonzero on success
;;
;; A raw blob straight into the surface's own store: no header, no
;; palette, no format. Everything this renderer loads is produced by its
;; own tools and is already exactly the bytes the surface wants.
;;
;; Row at a time, because an EMS surface has no single pointer covering
;; it: each row's window comes from qglSfRow, and the run stops at the
;; end of that row.
;;
;; qgl's own; mgl loads through uglNewBMP and a CFMT conversion.
;;::::::::::::::
;; qgl$SfLoadFh -- the shared body of qglSfLoad and qglSfFromFileBas.
;;
;;  in: s = surface, fh = an open handle positioned at the pixels
;; out: ax nonzero if every row arrived
qgl$SfLoadFh  proc    near private uses bx cx dx si di es,\
                        s:dword, fh:word

                local   yy:word
                local   rows:word
                local   wide:word
                local   rowp:dword

                les     bx, s
                mov     ax, es:[bx].Surface.yRes
                mov     rows, ax
                mov     ax, es:[bx].Surface.xRes
                mov     wide, ax
                xor     ax, ax
                mov     yy, ax

@@row:          mov     ax, yy
                cmp     ax, rows
                jae     @@done

                invoke  qglSfRow, s, yy
                mov     word ptr rowp, ax
                mov     word ptr rowp+2, dx
                invoke  qglFileRead, fh, rowp, wide

                cmp     ax, wide
                jne     @@done                  ;; short: the file ran out

                inc     yy
                jmp     @@row

@@done:         xor     ax, ax
                mov     dx, yy
                cmp     dx, rows
                jne     @F
                mov     ax, 1                   ;; every row arrived
@@:             ret
qgl$SfLoadFh  endp


qglSfLoad     proc    public uses bx cx dx si di es,\
                        s:dword, path:dword

                local   fh:word
                local   ok:word

                mov     ok, 0

                invoke  qglFileOpen, path
                test    ax, ax
                jz      @@out
                mov     fh, ax

                invoke  qgl$SfLoadFh, s, fh
                mov     ok, ax
                invoke  qglFileClose, fh

@@out:          mov     ax, ok
                ret
qglSfLoad     endp


IFDEF __BASIC__
;;::::::::::::::
;; qglSfFromFileBas ( path:BasStr, wide:word, kind:word )
;;                                      -> dx:ax = surface, 0:0 on failure
;;
;; Open, size, make, fill, close -- the one call BASIC needs to own a
;; surface that came off disk. qgl's own; mgl has no counterpart.
;;
;; THE HEIGHT COMES FROM THE FILE, not from the caller. The alternative
;; is for the caller to re-derive the packer's layout (textures x mips x
;; cell area, rounded up to the atlas width) to know how tall its own
;; atlas is, and mkassets.py owns that layout. A file whose length is not
;; a whole number of rows is refused rather than rounded.
;;
;; __BASIC__ only, like file.asm's own qglFileOpenBas -- BASIC cannot
;; hand over an asciiz path.
;;::::::::::::::
;; NOT `uses dx`: the surface comes home in dx:ax, and the epilogue pops
;; over the high half. qblint checks for this.
qglSfFromFileBas proc public uses bx cx si di es,\
                        path:word, wide:word, kind:word

                local   fh:word
                local   surf:dword

                mov     word ptr surf, 0
                mov     word ptr surf+2, 0

                invoke  qglFileOpenBas, path
                test    ax, ax
                jz      @@fail
                mov     fh, ax

                ;; rows = size / wide, and dx:ax must divide exactly
                invoke  qglFileSize, fh
                mov     cx, wide
                jcxz    @@shut
                cmp     dx, cx
                jae     @@shut                  ;; quotient would not fit ax
                div     cx                      ;; ax= rows, dx= remainder
                test    dx, dx
                jnz     @@shut                  ;; not a whole number of rows
                test    ax, ax
                jz      @@shut                  ;; an empty file is not a surface

                invoke  qglSfNew, wide, ax, kind
                mov     word ptr surf, ax
                mov     word ptr surf+2, dx
                or      ax, dx
                jz      @@shut

                invoke  qgl$SfLoadFh, surf, fh
                test    ax, ax
                jnz     @@shut                  ;; loaded: keep it

                invoke  qglSfFree, surf         ;; short read, own nothing
                mov     word ptr surf, 0
                mov     word ptr surf+2, 0

@@shut:         invoke  qglFileClose, fh

@@fail:         mov     ax, word ptr surf
                mov     dx, word ptr surf+2
                ret
qglSfFromFileBas endp
ENDIF


;;::::::::::::::
;; qglSfView ( v:far ptr, parent:far ptr, ofs:dword, w:word, h:word, bps:word )
;;
;; uglNewView's body with the allocation taken out and the stride taken
;; from the caller instead of derived -- which is what sc_alloc needs, its
;; classes being 2^a wide. qglSfViewNew allocates and calls this.
;;
;; PRIVATE: the header must sit at offset 0 of its segment and carry h
;; entries of address table, which only this module's allocator arranges.
;;::::::::::::::
qglSfView     proc    private uses bx cx dx si di es,\
                        v:dword, parent:dword, ofs:dword,\
                        wid:word, hgt:word, bps:word

                les     bx, parent
                mov     ax, es
                or      ax, bx
                jz      @@fail

                mov     si, es:[bx].Surface.typ
                mov     di, es:[bx].Surface.fmt
                mov     cx, W es:[bx].Surface.fptr+0
                mov     dx, W es:[bx].Surface.fptr+2

                les     bx, v
                mov     es:[bx].Surface.typ, si
                mov     es:[bx].Surface.fmt, di
                mov     W es:[bx].Surface.fptr+0, cx
                mov     W es:[bx].Surface.fptr+2, dx

                mov     cx, FMT_8BIT_BPP
                mov     ax, FMT_8BIT_P2B
                mov     es:[bx].Surface.bpp, cl
                mov     es:[bx].Surface.p2b, al

                mov     ax, wid
                mov     es:[bx].Surface.xRes, ax
                dec     ax
                mov     es:[bx].Surface.xMin, 0
                mov     es:[bx].Surface.xMax, ax
                mov     ax, hgt
                mov     es:[bx].Surface.yRes, ax
                dec     ax
                mov     es:[bx].Surface.yMin, 0
                mov     es:[bx].Surface.yMax, ax

                mov     ax, bps
                mov     es:[bx].Surface.bps, ax
                mov     es:[bx].Surface.pages, 1
                mov     es:[bx].Surface.startSL, 0

                mul     hgt                     ;; size= bps * yRes
                mov     W es:[bx].Surface._size+0, ax
                mov     W es:[bx].Surface._size+2, dx

                invoke  qglSetView, v, ofs
                neg     ax                      ;; TRUE (-1) -> 1, as above
                sbb     ax, ax
                neg     ax
                ret

@@fail:         xor     ax, ax
                ret
qglSfView     endp


;;::::::::::::::
;; qglSfViewNew ( parent:far ptr, w:word, h:word, bps:word ) -> far ptr, or 0:0
;;
;; qglSfView for a BASIC caller: BASIC has no way to allocate a header
;; matching Surface's own layout, so this allocates one -- the header AND
;; its h-entry address table, which is what mgl's uglNewView allocates --
;; and hands the far pointer back. What it aims at is qglSfView's job
;; exactly, at ofs 0.
;;
;; DO NOT qglSfFree the result. A view SHARES its parent's store rather
;; than owning it, and qglSfFree goes through the back-end's `del`, which
;; would free the parent's pixels out from under it. Free the parent once,
;; when every view of it is done; leak the view's own header, the same way
;; sc_alloc's per-class views already do.
;;::::::::::::::
qglSfViewNew  proc    public uses bx cx,\
                        parent:dword, wid:word, hgt:word, bps:word

                local   hdr:dword
                local   nbytes:dword

                mov     ax, hgt
                shl     ax, 2                   ;; the address table
                add     ax, T Surface
                mov     word ptr nbytes, ax
                mov     word ptr nbytes+2, 0

                invoke  qglMemAlloc, nbytes
                mov     word ptr hdr, ax
                mov     word ptr hdr+2, dx
                or      ax, dx
                jz      @@fail

                invoke  qglSfView, hdr, parent, 0, wid, hgt, bps
                test    ax, ax
                jz      @@freed

                mov     ax, word ptr hdr
                mov     dx, word ptr hdr+2
                ret

@@freed:        invoke  qglMemFree, hdr
@@fail:         xor     ax, ax
                xor     dx, dx
                ret
qglSfViewNew  endp


;;::::::::::::::
;; qglSfViewAim ( v:far ptr, ofs:dword ) -> ax nonzero
;;
;; Re-aims an existing qglSfViewNew view at a new byte offset into its
;; store. It IS mgl's uglSetView -- the transcribed qglSetView, called
;; with the same two arguments and nothing added.
;;
;; The old note here said this was absolute where mgl's is parent-
;; relative. With the address table back they are the same thing: a view
;; carries the parent's own base pointer, and qgl$fillView adds ofs to it.
;; Every caller (sc_alloc, mod_tex) owns a store whose base is the store,
;; so "absolute within the store" is what parent-relative already means.
;;::::::::::::::
qglSfViewAim  proc    public,\
                        v:dword, ofs:dword

                invoke  qglSetView, v, ofs
                ;; mgl answers TRUE, which is -1. qgl's boundary answers
                ;; 1/0 everywhere else, and BASIC's TRUE is -1 while C's
                ;; is 1, so the shim normalises rather than leaking mgl's.
                neg     ax
                sbb     ax, ax
                neg     ax
                ret
qglSfViewAim  endp

;;::::::::::::::
;; qglSfViewShape ( v:far ptr, wid:word, ofs:dword ) -> ax nonzero
;;
;; Re-aims a view AND gives it a new width: xRes, the clip's xMax and
;; the stride, a cached surface being a flat run wid bytes a row. The
;; address table is the height's whatever the width, so one view a
;; HEIGHT serves every class of that height -- five for the cache
;; where a view a class was twenty-two, made at the first face of each
;; class where the load trace could not see them.
;;::::::::::::::
qglSfViewShape proc   public uses bx dx es,\
                        v:dword, wid:word, ofs:dword

                les     bx, v
                mov     ax, es
                or      ax, bx
                jz      @@fail
                mov     ax, wid
                mov     es:[bx].Surface.xRes, ax
                mov     es:[bx].Surface.bps, ax
                dec     ax
                mov     es:[bx].Surface.xMax, ax
                mov     ax, wid
                mul     es:[bx].Surface.yRes
                mov     W es:[bx].Surface._size+0, ax
                mov     W es:[bx].Surface._size+2, dx
                invoke  qglSetView, v, ofs
                neg     ax
                sbb     ax, ax
                neg     ax
                ret

@@fail:         xor     ax, ax
                ret
qglSfViewShape endp


;;::::::::::::::
;; qglSfPget ( s:far ptr, x:word, y:word ) -> al
;;
;; One pixel. Slow on purpose -- this exists for the round-trip checks
;; (-dumptex reads every atlas cell back through its own view) and not
;; for anything per frame.
;;::::::::::::::
qglSfPget     proc    public uses bx cx si es,\
                        s:dword, x:word, y:word

                les     bx, s
                mov     ax, x                   ;; unsigned: a negative x
                cmp     ax, es:[bx].Surface.xRes        ;; is a huge one
                jae     @@none
                mov     ax, y
                cmp     ax, es:[bx].Surface.yRes
                jae     @@none

                invoke  qglSfAccessRd, s, y
                mov     es, dx
                mov     bx, ax
                add     bx, x
                mov     al, es:[bx]
                xor     ah, ah
                ret

@@none:         xor     ax, ax                  ;; off the surface reads 0
                ret
qglSfPget     endp


;;::::::::::::::
;; qglSfSize ( s:far ptr, sel:word ) -> ax = xRes (sel 0) or yRes
;;
;; mgl's uglDcSize answers xRes-1, which every caller then adds one to.
;; This answers the size. 0 for a null surface, which is the same answer
;; a zero-sized one gives and is what a caller should refuse either way.
;;::::::::::::::
qglSfSize     proc    public uses bx es,\
                        s:dword, sel:word

                les     bx, s
                mov     ax, es
                or      ax, bx
                jz      @@none
                mov     ax, es:[bx].Surface.xRes
                cmp     sel, 0
                je      @F
                mov     ax, es:[bx].Surface.yRes
@@:             ret

@@none:         xor     ax, ax
                ret
qglSfSize     endp


;;::::::::::::::
;; qglSfPset ( s:far ptr, x:word, y:word, c:word )
;;::::::::::::::
qglSfPset     proc    public uses bx cx si es,\
                        s:dword, x:word, y:word, col:word

                ;; A PIXEL PAST THE LAST COLUMN LANDS IN THE NEXT ROW,
                ;; inside the same allocation, so nothing faults and
                ;; nothing downstream complains -- the picture just grows
                ;; a wrong pixel. Past the last row it leaves the surface
                ;; altogether. Both are refused here.
                les     bx, s
                mov     ax, x
                cmp     ax, es:[bx].Surface.xRes
                jae     @@none
                mov     ax, y
                cmp     ax, es:[bx].Surface.yRes
                jae     @@none

                invoke  qglSfAccessWr, s, y
                mov     es, dx
                mov     bx, ax
                add     bx, x
                mov     al, byte ptr col
                mov     es:[bx], al
@@none:         ret
qglSfPset     endp




QGL_CODE
;;::::::::::::::
;; qgl_Near -- the near half of the failed-driver stubs.
;;::::::::::::::
qgl_Near        proc    near public
                xor     ax, ax
                xor     dx, dx
                stc
                ret
qgl_Near        endp

;;::::::::::::::
;; qgl_nul_Init -- the middle entry refuses, always.
;;::::::::::::::
qgl_nul_Init    proc    near public
                stc
                ret
qgl_nul_Init    endp

;;::::::::::::::
;; qglSfInit () -> ax nonzero if EMS surfaces are possible
;;
;; mgl's uglInit, the dct half of it: walk the table, let each back-end
;; wire its own entry, and stub out any that refuses. IN QGL_CODE because
;; _init is a NEAR pointer and .model medium gives every module its own
;; code segment -- the call could not reach otherwise.
;;::::::::::::::
qglSfInit     proc    public uses bx cx si

                xor     si, si
                mov     cx, SF_TYPES

@@loop:         call    qgl$dctTB[si]._init
                jc      @@dummy                 ;; error?!? argh
@@next:         add     si, T SurfaceOps
                dec     cx
                jnz     @@loop

                ;; 1, not the table's TRUE. mgl's uglInit answers -1
                ;; because that is BASIC's TRUE; this entry has answered 1
                ;; since it was a forwarder to qglGemInit, and t18txtrow
                ;; asserts on the value rather than on nonzero-ness.
                xor     ax, ax
                cmp     qgl$dctTB[SF_EMS].state, TRUE
                jne     @F
                mov     ax, 1
@@:             ret

@@dummy:        lea     bx, qgl$dctTB[si]
                mov     [bx].SurfaceOps.state, FALSE

                SET_DCT new, qgl_Far
                SET_DCT newMult, qgl_Far
                SET_DCT del, qgl_Far
                SET_DCT save, qgl_Far
                SET_DCT restore, qgl_Far

                SET_DCT rdBegin, qgl_Near, TRUE
                SET_DCT wrBegin, qgl_Near, TRUE
                SET_DCT rdwrBegin, qgl_Near, TRUE
                SET_DCT rdSwitch, qgl_Near, TRUE
                SET_DCT wrSwitch, qgl_Near, TRUE
                SET_DCT rdwrSwitch, qgl_Near, TRUE
                SET_DCT rdAccess, qgl_Near, TRUE
                SET_DCT wrAccess, qgl_Near, TRUE
                SET_DCT rdwrAccess, qgl_Near, TRUE
                SET_DCT fullAccess, qgl_Near, TRUE
                SET_DCT rdAccessEx, qgl_Near, TRUE
                SET_DCT wrAccessEx, qgl_Near, TRUE
                SET_DCT rdwrAccessEx, qgl_Near, TRUE
                jmp     @@next
qglSfInit     endp
QGL_ENDS


.data
;;
;; THE DISPATCH TABLE. mgl keeps ul$dctTB in uglmain.asm; qgl has no main
;; module, so it lives here, in the file that already owns qglSfInit.
;;
;; One entry per KIND, so SURF_EMS can stay 2 while SF_EMS is 2 * 64. The
;; middle entry is mgl's DC_BNK slot with no back-end behind it: its _init
;; refuses and qglSfInit marks it dead, so a bogus typ fails instead of
;; drawing.
;;
qgl$dctTB       label   SurfaceOps
                SurfaceOps      <qgl_mem_Init, qgl_mem_End,>
                SurfaceOps      <qgl_nul_Init, qgl_nul_End,>
                SurfaceOps      <qgl_ems_Init, qgl_ems_End,>

                public  qgl$dctTB

                end
