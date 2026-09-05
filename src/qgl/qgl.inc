;;
;; qgl.inc -- the surface, shared by every module that draws.
;;
;; A surface is pixels plus the two numbers needed to walk them, and it
;; does not say where it lives: qgl_sf_row hands back a far pointer either
;; way. Conventional memory answers with arithmetic; EMS answers with a
;; page map.
;;
;; THE SLOT IS THE CALLER'S, not the surface's. mgl's emsMapEx already
;; takes an explicit physical page (0..3) for exactly this reason -- its
;; own header says the plain accessor "evicts whatever the renderer had
;; there", which is why the Ex form exists -- and q_map.bi's PAGE_SLOT
;; has been using it that way all along. An earlier draft of this file
;; claimed mgl pooled its four pages and evicted least-recently-used,
;; and gave that as the reason for handing each surface a private slot.
;; That was wrong on both counts: emsSlotAcquire/emsSlotLock appear
;; nowhere in mgl, only in AGENTS.md's account of an experiment that was
;; REVERTED, and four private slots cannot cover the nine or more EMS
;; objects this renderer has live at once.
;;
;; So: the caller names the slot, and shares it deliberately where it
;; must, under the discipline q_map.bi already documents -- map
;; immediately before use, never hold the window across a call that
;; could remap it.
;;
;; WHAT ACTUALLY BUYS HEADROOM is placement, not slot policy. sb_build
;; today holds four windows live at once -- destination, atlas, luxels,
;; colormap -- which is 4 of 4 with nothing spare, and mgl's own span
;; filler gave up depth over it (uglspan.asm: "UGL.Z.OFF only,
;; deliberately. The depth window wants a fourth EMS slot"). Put the
;; destination and the depth buffer in conventional memory and the
;; builder needs three with one in hand.
;;
;; A texture the span filler reads must fit ONE 16K page: the texel
;; fetch is a 16-bit effective address in one segment with the base
;; patched in as an immediate, mapped once per polygon and never
;; remapped. Exceeding it cost a measured 15.5% triangle dropout. At
;; 8bpp that caps a texture at 128x128.
;;

;;
;; THE TWO KINDS OF ROUTINE, and the rules are not stylistic.
;;
;;   qgl_   the interface. FAR, pascal, arguments on the stack. This is
;;          what BASIC and C call, so the convention is theirs, and it is
;;          the only thing outside this layer may name.
;;
;;   qgl$   everything else. NEAR, arguments in registers, and it
;;          PRESERVES EVERY REGISTER but the one it returns in. A caller
;;          never has to know which internal it just called or what that
;;          one happened to use, which is what makes an internal safe to
;;          call from a loop whose live set is the whole register file --
;;          the fillers, when they land.
;;
;;          Near means same-module: .model medium gives each module its
;;          own code segment, so an internal is not reachable across
;;          files. Where two modules must share one, they do it through
;;          the qgl_ entry. If that ever costs too much, the fix is
;;          mgl's -- one shared `segment para public use16` for the whole
;;          layer, which is why UGL_CODE exists -- and not a far internal.
;;

;;
;; DISPATCH, not a compare. One entry per kind of surface, holding the
;; routines that kind needs -- mgl's ul$dctTB, narrowed to the two kinds
;; we have. The type constant IS the byte offset into the table, the
;; same trick as DC_MEM equ 0 * T DCT, so a call site indexes with no
;; multiply and no branch:
;;
;;      mov     cl, es:[bx].SF.sfWhere
;;      xor     ch, ch
;;      call    qgl$typeTB[cx].sftRow
;;
;; One field today. It is a struct rather than a bare word so that
;; adding the next per-kind routine does not move SF_CMEM and SF_EMS
;; out from under every surface already built with them.
;;
SurfaceOps      struc
row             dw      ?               ;; near: es:bx = surface, dx:ax = byte
                                        ;; offset of the row -> dx:ax far ptr
SurfaceOps      ends

SURF_CMEM       equ     0 * (SIZEOF SurfaceOps)
SURF_EMS        equ     1 * (SIZEOF SurfaceOps)

;; EMS physical pages. The numbering is the hardware's: the mapper takes
;; 0..3 and nothing else.
SURF_SLOT_MAX   equ     3

;;
;; Which free figure qgl_mem_avail should report. LARGEST is what an
;; allocation actually has to satisfy; TOTAL is every free block added
;; up, and the gap between them is the fragmentation. Same pre-scaled
;; table-offset trick as SURF_CMEM above.
;;
MemOps          struc
query           dw      ?               ;; near: -> dx:ax = bytes
MemOps          ends

MEM_LARGEST     equ     0 * (SIZEOF MemOps)
MEM_TOTAL       equ     1 * (SIZEOF MemOps)

;; Fields are unprefixed: they are scoped to the struct at every use
;; (.Surface.stride), and two structs may share a field name -- measured,
;; not assumed. The one real constraint is MASM's reserved words, which
;; is why this is x_res and not width: WIDTH is an operator, ORG is a
;; directive, and both fail at the STRUC rather than the use.
;;
;; stride, not bps: it is the row-to-row distance in bytes, and the old
;; name needed a comment to say so.
Surface         struc
x_res           dw      ?               ;; pixels
y_res           dw      ?
stride          dw      ?               ;; row to row, in bytes
kind            db      ?               ;; SURF_CMEM or SURF_EMS
slot            db      ?               ;; physical page to map through, EMS
handle          dw      ?               ;; EMS handle, or the segment if cmem
base_ofs        dd      ?               ;; byte offset of row 0 in the store
Surface         ends
