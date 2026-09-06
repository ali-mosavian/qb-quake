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
;; NEVER NAME A RETURN REGISTER IN `uses`. The epilogue pops what the
;; list holds, straight back over the answer, and the assembler says
;; nothing. qgl_txt_load returned dx:ax while declaring `uses ... dx`,
;; so every caller got the segment it happened to be holding already:
;; a missing file came back non-null, and a real one came back pointing
;; at a random segment whose bytes read as a plausible, wrong header.
;; It cost most of a session, and it bit a second time the same day in
;; a test that parked a glyph row in dl across a call returning dx:ax.
;;
;; The rule, therefore, both ways round: a routine must not `uses` what
;; it returns, and a caller must not leave anything live in dx across a
;; call that returns dx:ax.
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
rd_row          dw      ?               ;; near: map row for READING
wr_row          dw      ?               ;; near: map row for WRITING
rd_row_ex       dw      ?               ;; near: as rd_row, cl = the slot
wr_row_ex       dw      ?               ;; near: as wr_row, cl = the slot
windows         dw      ?               ;; slots this kind holds at once
SurfaceOps      ends

;; READ AND WRITE ARE SEPARATE ENTRIES, which is dct.inc's arrangement
;; and not ceremony. For conventional memory all four are the same
;; arithmetic. For EMS they are not: a texture being read and a
;; destination being written at the same instant need two different
;; physical pages, and one accessor cannot give both. mgl learned this
;; the same way -- its own span filler gave up depth over it
;; (uglspan.asm: "the depth window wants a fourth EMS slot").
;;
;; The Ex forms take the slot in cl and hand the pointer back in dx:ax
;; rather than clobbering a segment register on the caller's behalf,
;; so one routine can hold several surfaces mapped at once, each in
;; whatever register it likes. That is what the depth buffer needs, and
;; it is why mgl grew rdAccessEx/wrAccessEx.
;;
;; windows says how many can be live at once. ASK, DO NOT ASSUME: a
;; conventional surface has no window at all and answers with -1.

;; A KIND IS A KIND, NOT AN OFFSET, and these are the values BASIC has
;; always been told -- 0 and 2. They are written out, not derived.
;;
;; They used to be the dispatch table's byte offsets, pre-scaled so a
;; call site could index without a multiply, which is mgl's
;; DC_MEM equ 0 * T DCT. The saving is one instruction. The price is that
;; the constant CHANGES MEANING whenever the record grows: SurfaceOps
;; went from one word to five, SURF_EMS silently became 10, qgl.bi still
;; said 2, and a BASIC caller asking for an EMS surface would have
;; indexed the middle of the conventional entry.
;;
;; An exported enum must never be a SIZEOF. If the dispatch wants a
;; layout number it gets its own name, below.
SURF_CMEM       equ     0
SURF_EMS        equ     2

;; The dispatch table is indexed BY KIND, so it has a slot per kind value
;; and one of them is unused. Ten bytes to keep the exported enum and the
;; table layout from ever being the same number again.
SURF_KINDS      equ     3

SURF_SLOT_MAX   equ     3

;; The depth buffer's own page, mgl's Z_SLOT. It is the LAST one so it
;; cannot collide with a texture or a destination that took theirs in
;; order, which is the disjointness sb_build has been relying on by
;; accident rather than by statement.
QGL_Z_SLOT      equ     3

;;
;; Which free figure qgl_mem_avail should report. LARGEST is what an
;; allocation actually has to satisfy; TOTAL is every free block added
;; up, and the gap between them is the fragmentation. Same pre-scaled
;; table-offset trick as SURF_CMEM above.
;;
MemOps          struc
query           dw      ?               ;; near: -> dx:ax = bytes
MemOps          ends

MEM_LARGEST     equ     0
MEM_TOTAL       equ     2               ;; written out; BASIC has said 2 all along
MEM_KINDS       equ     3               ;; slots, indexed by the selector

;;
;; Drawing mode and depth mode. b8_span turns the pair into an index --
;; (mode * QGL_Z_KINDS + zmode) * 2 -- so these stay semantic for the
;; same reason the surface kinds do: they cross into BASIC, and a value
;; that is also a table offset changes meaning when the table changes
;; shape.
;;
;; The order within a mode is OFF, SET, TEST, and it is the order the
;; renderer uses them in: a frame draws the world with SET and then the
;; models with TEST.
;;
QGL_Z_OFF       equ     0
QGL_Z_SET       equ     1
QGL_Z_TEST      equ     2
QGL_Z_KINDS     equ     3               ;; depth modes per drawing mode

;; How many pixels one perspective divide serves. mgl's SUBDIVP, and the
;; same 16: a divide is the expensive instruction here, and sixteen
;; pixels of affine drift stays under a texel for anything the renderer
;; draws.
QGL_SUBDIVS     equ     4
QGL_SUBDIVP     equ     16
QGL_SUBDIVF     textequ <16.0>          ;; the same 16, as a real4 initialiser

QGL_M_WIRE      equ     0
QGL_M_FLAT      equ     1
QGL_M_TEX       equ     2
QGL_M_PTEX      equ     3

;;
;; Shortcuts, mgl's spelling (inc/equ.inc). They are here rather than
;; re-invented per module because a size override reads as noise and
;; every filler is full of them.
;;

;;::::::::::::::
;; ONE CODE SEGMENT FOR THE WHOLE LAYER, which is ugl.inc's UGL_CODE and
;; exists for one reason: the scanner picks a filler out of a table and
;; CALLS it, and a near call cannot cross the per-module segments that
;; .model medium hands out. mgl put its scanners in ugl/ and its fillers
;; in cfmt/b8/ and shares one `segment para public use16` between them.
;;
;; The alternative -- far pointers in the table -- costs a far call per
;; span, on the one path where that is not free.
;;::::::::::::::
QGL_CODE        macro
qgl_text        segment para public use16 'CODE'
                assume  cs:qgl_text, ds:DGROUP, ss:DGROUP, es:nothing
endm
                QGL_ENDS        equ     <qgl_text ends>



;;::::::::::::::
;; FARADD -- advance the far pointer at `p` by `n` bytes.
;;
;; n is a word register, memory operand or immediate, at most 8000h, and
;; MUST NOT be ax, bx or cx, which this uses.
;;
;; ADD, THEN FOLD THE OFFSET INTO THE SEGMENT. Both callers previously
;; did `adc seg, 0`,
;; which adds ONE to the segment when the offset wraps -- but a wrapped
;; offset is 65536 bytes, which is 4096 paragraphs, so everything past
;; the first 64K landed 65520 bytes short. Nothing had crossed that line:
;; the suite's surfaces are kilobytes and the fillers work a row at a
;; time. The renderer's atlas is 114688 bytes and would have crossed on
;; its first transfer.
;;
;; One fold, at the end, is all of it. It leaves the offset in 0..15, so
;; the NEXT add cannot carry however large n is -- there is no carry case
;; to get right and none left untested. A second fold before the add was
;; written first and removed: it was redundant with this one, and neither
;; could be mutated away without the other still covering it, which is
;; the definition of a branch no test can reach. It also means no run below can reach
;; the end of its segment, so no single DOS read or string move is ever
;; handed a range that straddles the boundary -- which capping a run at
;; 32K does NOT guarantee when the caller's pointer starts at FFF0h.
;;::::::::::::::
FARADD          macro   p, n
                mov     ax, W p
                mov     bx, W p+2
                add     ax, n                   ;; 800Fh at the very most:
                                                ;; the fold below leaves the
                                                ;; offset in 0..15, so the
                                                ;; next add cannot carry
                mov     cx, ax
                shr     cx, 4
                add     bx, cx                  ;; fold the offset into the
                and     ax, 15                  ;; segment, every time
                mov     W p, ax
                mov     W p+2, bx
endm

;; 16.16 to integer. Shared: the scanner steps in fixed point and the
;; fillers land on whole texels.
FXFLOOR         macro   a:req
                shr     a, 16
endm

O               equ     offset
T               equ     type
D               equ     dword ptr
W               equ     word ptr
B               equ     byte ptr

PS              macro   args:vararg
                local   a
        for     a, <args>
                push    a
        endm
endm

PP              macro   args:vararg
                local   a
        for     a, <args>
                pop     a
        endm
endm

;;
;; Self-patched operands. The placeholders are mgl's, and they are
;; deliberately conspicuous: an unpatched site draws with 0DEADh as its
;; mask, which is visibly wrong rather than subtly so.
;;
__IMM8__        equ     0DEh
__IMM16__       equ     0DEADh
__IMM32__       equ     0DEADBEEFh

;; A PATCH SITE IS ADDRESSED FROM THE END OF ITS INSTRUCTION, never by an
;; offset counted forward from its label. The immediate is always the
;; last field, so end-1 is a byte, end-2 a word and end-4 a dword,
;; whatever prefixes the assembler decided to put in front.
;;
;; Counting forward is how mgl's 8plxtp.asm came to patch at +4 an
;; operand a segment override had moved to +5: half the word went into
;; the operand's own address, and every step then landed on a DGROUP
;; offset the routine did not own.
ZEND            macro   nm
nm&_e           label   byte
endm

;;
;; A vertex, in screen space, floats. ONE layout, which is the whole
;; reason qgl's clipper is a procedure where mgl's is four hundred lines
;; of macro: mgl has seven vertex structures (f2d, g2d, gp2d, t2d, tp2d,
;; tg2d, tpg2d) and generates a clipper for each. We have colour and a
;; texture and nothing else, so there is nothing to generate.
;;
;; z is 1/z, not z. It is linear in screen space where u and v are not,
;; which is what lets a clipped vertex's depth be an ordinary lerp along
;; the edge and lets the affine mapper carry depth at all.
;;
QVert           struc
vx              real4   ?
vy              real4   ?
vz              real4   ?               ;; 1/z
vu              real4   ?
vv              real4   ?
QVert           ends

;; The ceiling is the CALLER's, plus what clipping can add. d_faces.c
;; builds up to MAXV = GEOM_MAXVTX + 8 = 41 vertices, and each of the
;; four boundaries can add at most one, so 45.
;;
;; mgl's is SH_MAXV equ 12 against a uglPolyTP that accepts 32, with
;; SH_vbuff sized MAXV+1 while intersections from all four passes
;; accumulate into it without reset -- an overrun waiting on a polygon
;; nobody had drawn yet. Sized from the caller here, and the buffers hold
;; whole vertices rather than pointers into a shared scratch, so there is
;; no second array to size wrongly.
QGL_MAXV        equ     41
QGL_CLIPV       equ     QGL_MAXV + 4

;;
;; A loaded font: header and payload in ONE block, with the payload
;; addressed by OFFSET from the header rather than by pointer. Two bytes
;; instead of four, and it survives the block being moved.
;;
;; adv is the default advance, and it is 4 for this renderer's own font --
;; the glyphs are 4x6 ink inside an 8x8 cell and draw_string has always
;; stepped 4, letting the cells overlap where the mask is clear. A
;; per-glyph table (flags bit 0) overrides it, so proportional text needs
;; a different file and not a different format.
;;
FONT_PROP       equ     1               ;; flags: per-glyph advance present

;; The file IS this struct, magic and all: mkfont.py writes bits_ofs and
;; adv_ofs because that end knows them, so loading is a read and a magic
;; check with no fixup pass to get wrong.
Font            struc
magic           dd      ?               ;; "FNT1"
cell_w          db      ?
cell_h          db      ?
rowbytes        db      ?               ;; (cell_w+7)>>3
flags           db      ?
adv             db      ?               ;; default advance
fpad            db      ?
first           dw      ?               ;; first codepoint present
count           dw      ?
bits_ofs        dw      ?               ;; from the block base
adv_ofs         dw      ?               ;; 0 when there is no table
fpad2           dw      ?
Font            ends

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
wr_slot         db      ?               ;; page this surface writes through
rd_slot         db      ?               ;; and the one it reads through
spad            db      ?
handle          dw      ?               ;; EMS handle, or the segment if cmem
base_ofs        dd      ?               ;; byte offset of row 0 in the store
Surface         ends
