;;
;; qgl.inc -- the surface, shared by every module that draws.
;;
;; A surface is pixels plus the two numbers needed to walk them, and it
;; does not say where it lives: qglSfRow hands back a far pointer either
;; way. Conventional memory answers with arithmetic; EMS answers with a
;; page map.
;;
;; THE SLOT IS NOT THE SURFACE'S, and never was mgl's either. The plain
;; read and write accessors hardwire physical pages 0 and 1 -- mgl's
;; EMS_READPAGE/EMS_WRITEPAGE -- and a caller wanting some other window
;; says so at the point of access, through the Ex form. That is what
;; emsMapEx has always been: its own header says the plain accessor
;; "evicts whatever the renderer had there", and q_map.bi's PAGE_SLOT
;; has been using it that way all along.
;;
;; A Surface carrying its own rd/wr slot was a qgl invention and is gone:
;; it made the struct two bytes wider than a DC, which is the one thing
;; a transcription of mgl cannot afford.
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
;; nothing. qglTxtLoad returned dx:ax while declaring `uses ... dx`,
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

O               equ     offset
S               equ     seg
T               equ     type
D               equ     dword ptr
W               equ     word ptr
B               equ     byte ptr

;; mgl's equ.inc, the three names the transcribed modules spell out.
FALSE           equ     0
TRUE            equ     -1
NULL            equ     0

;; mgl's log.inc, transcribed verbatim, gate included: the macro bodies
;; still test _DEBUG_, which nothing here defines, so a diff against the
;; original is clean and every macro assembles to nothing.
log_proc        textequ <>

LOGOPEN         macro   msg:req
                local   ??msg, ??ret
        ifdef   _DEBUG_
                push    cs
                push    offset ??msg
                push    word ptr @SizeStr(<msg>) + 2+2
                push    cs
                push    offset ??ret
                externdef log_open:far
                jmp     log_open
??msg           byte    "&msg {", 13, 10
??ret:
        endif
endm

LOGCLOSE        macro
                local   ??msg, ??ret
        ifdef   _DEBUG_
                push    cs
                push    offset ??msg
                push    word ptr 1 + 2
                push    cs
                push    offset ??ret
                externdef log_close:far
                jmp     log_close

??msg           byte    "}", 13, 10
??ret:
        endif
endm

LOGBEGIN        macro   procname:req
                local   ??msg, ??ret
        ifdef   _DEBUG_
                log_proc catstr <'>, <procname>, <'>

                push    cs
                push    offset ??msg
%               push    word ptr @SizeStr(<%log_proc>)-2 +2+2
                push    cs
                push    offset ??ret
                externdef log_begin:far
                jmp     log_begin

??msg           byte    log_proc
                byte    ' {', 13, 10
??ret:
        endif
endm

LOGEND          macro
                local   ??msg, ??ret
        ifdef   _DEBUG_
                externdef log_end:far
                push    cs
                push    offset ??msg
%               push    word ptr 1+2
                push    cs
                push    offset ??ret
                jmp     log_end

??msg           byte    '}', 13, 10
??ret:
        endif
endm

LOGMSG          macro   msg:req
                local   ??msg, ??ret
        ifdef   _DEBUG_
                push    cs
                push    offset ??msg
%               push    word ptr @SizeStr(<msg>) +2
                push    cs
                push    offset ??ret
                externdef log_msg:far
                jmp     log_msg

??msg           byte    "&msg", 13, 10
??ret:
        endif
endm

LOGERROR        macro   msg
                local   ??msg, ??ret
        ifdef   _DEBUG_
                push    cs
                push    offset ??msg
        ifnb    <msg>
%               push    word ptr @SizeStr(<msg>) +7+2
        else
                push    word ptr 8+2
        endif
                push    cs
                push    offset ??ret
                externdef log_msg:far
                jmp     log_msg

        ifnb    <msg>
??msg           byte    "ERROR: &msg", 13, 10
        else
??msg           byte    "ERROR!!!", 13, 10
        endif

??ret:
        endif
endm

;; mgl's ems.inc, the constants the EMS back-end spells out. The MAP
;; macros are dctems.asm's own -- qgl maps through gem.asm, not INT 67h
;; inline.
EMS_PGSIZE      equ     16384
EMS_PGSHIFT     equ     14
EMS_INVALID     equ     -1
EMS_READPAGE    equ     0
EMS_WRITEPAGE   equ     1

;; EMSCTX is dctems.asm's, not this file's. It carries `rdCurrent equ
;; ppgTB[...]`, and a struct EQU is a GLOBAL text substitution -- with it
;; here, dctmem.asm's own MEMCTX.rdCurrent field stops being a name and
;; becomes an index expression. mgl's ems.inc records the same trap for
;; xms.inc and vbe.inc.

;;
;; DISPATCH, not a compare. One entry per kind of surface, holding the
;; routines that kind needs -- mgl's ul$dctTB, narrowed to the two kinds
;; we have. Surface.typ IS the byte offset into the table, so a call site
;; indexes with no multiply and no branch:
;;
;;      mov     bx, es:[bx].Surface.typ
;;      call    qgl$dctTB[bx].rdAccess
;;
;; mgl's DCT (inc/dct.inc), field for field and padded to the same 64
;; bytes. Transcribed, not designed: the dispatch the copied code performs
;; is `call qgl$dctTB[bx].rdAccess`, so the record it indexes has to be
;; the record mgl's code indexed.
SurfaceOps      struc
                _init           dw      ?       ;; near!
                _end            dd      ?

                state           dw      FALSE
                winSize         dd      ?

                new             dd      NULL
                newMult         dd      NULL
                del             dd      NULL

                save            dd      NULL
                restore         dd      NULL

                rdBegin         dw      NULL    ;; near!
                wrBegin         dw      NULL    ;; /
                rdwrBegin       dw      NULL    ;; /
                rdSwitch        dw      NULL    ;; /
                wrSwitch        dw      NULL    ;; /
                rdwrSwitch      dw      NULL    ;; /
                rdAccess        dw      NULL    ;; /
                wrAccess        dw      NULL    ;; /
                rdwrAccess      dw      NULL    ;; /
                fullAccess      dw      NULL    ;; /

                ;;
                ;; The Ex accessors: as rdAccess/wrAccess, but the caller
                ;; picks WHICH window (physical page slot) to map into, and
                ;; gets the pointer back as a VALUE in dx:ax rather than
                ;; having ds/es clobbered on its behalf. That is what lets
                ;; one routine hold several surfaces mapped at once, each in
                ;; whatever segment register it likes.
                ;;
                ;; They sit in what used to be this struct's tail padding,
                ;; so sizeof(SurfaceOps) is still 64 and every field above
                ;; keeps the offset it already had.
                ;;
                ;; windows: how many independent slots this kind can hold
                ;; mapped at once. 0 = Ex not supported (the three pointers
                ;; stay NULL). Ask, do not assume.
                ;;
                rdAccessEx      dw      NULL    ;; near!
                wrAccessEx      dw      NULL    ;; /
                rdwrAccessEx    dw      NULL    ;; /
                windows         dw      0

        if      ($ gt 64)
                .err    <sizeof(SurfaceOps) !> 64 bytes>
        else
        if      ($ ne 64)
                                db      64-$ dup (?)
        endif
        endif
SurfaceOps      ends

;;::::::::::::::
;; ds:bx-> qgl$dctTB[SF_???]
SET_DCT         macro   field:req, function:req, nearFlag
        ifb     <nearFlag>
                externdef function:far
                mov     W [bx].SurfaceOps.&field+0, O function
                mov     W [bx].SurfaceOps.&field+2, S function
        else
                externdef function:near
                mov     [bx].SurfaceOps.&field, O function
        endif
endm

                ;; the back-ends' init/end procs. qgl_ prefixed where mgl
                ;; says mem_/ems_ for one reason only: qrender links
                ;; UGLV.LIB, whose own dctmem/dctems already define
                ;; mem_Init, ems_New and a dozen more, and LINK folds case.
                externdef       qgl_mem_Init:near, qgl_mem_End:far
                externdef       qgl_ems_Init:near, qgl_ems_End:far

                ;; the dispatch table itself. mgl keeps ul$dctTB in
                ;; uglmain.asm; qgl has no main module, so it lives in
                ;; sf.asm, which is already the layer's entry point.
                externdef       qgl$dctTB:SurfaceOps

;; THE TABLE IS INDEXED BY BYTE OFFSET, which is what makes the dispatch a
;; `mov bx, [Surface.typ]` and no multiply -- mgl's DC_MEM equ 0 * T DCT.
;; Surface.typ holds one of these, NOT the SURF_ enum below.
SF_MEM          equ     0 * T SurfaceOps
SF_EMS          equ     2 * T SurfaceOps
SF_TYPES        equ     3               ;; entries, kind 1 being nobody's

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
;; An exported enum must never be a SIZEOF. SF_MEM/SF_EMS above are the
;; layout numbers, and sf.asm converts between the two at the boundary --
;; the one place either name is spelled outside its own half.
SURF_CMEM       equ     0
SURF_EMS        equ     2

;; The dispatch table is indexed BY KIND, so it has a slot per kind value
;; and one of them is unused. One SurfaceOps to keep the exported enum and
;; the table layout from ever being the same number again.
SURF_KINDS      equ     3

SURF_SLOT_MAX   equ     3

;; The depth buffer's page, for the ONE caller that names a window: the
;; span filler writes depth through qglSfWrRowEx while its destination
;; row is already in hand, so it cannot use the plain write accessor.
;;
;; It is EMS_WRITEPAGE, deliberately. Every other qgl write lands there
;; too (mgl's wrAccess hardwires it), so naming it here shares one window
;; rather than claiming a second -- and slots 2 and 3 are mgl's, held by
;; PAGE_SLOT (luxels, geometry, nodes) and CM_SLOT (the colormap) across
;; a surface build.
QGL_Z_SLOT      equ     EMS_WRITEPAGE

;; The texture atlas's page, which is EMS_READPAGE: qgl reads the atlas
;; through the plain read accessor, so this is what that accessor uses.
;; Named because t20zems and qgl.bi still want to say it out loud.
QGL_TEX_SLOT    equ     EMS_READPAGE

;;
;; Which free figure qglMemAvail should report. LARGEST is what an
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

;; Paged array stores. 8, not mgl's UA_MAX of 4: leaves, faces, nodes
;; and clip take all four today, and d_mdl.bas records the model
;; vertices being refused a fifth and falling back to raw EMS.
QGL_AR_MAX      equ     8
QGL_AR_WIN      equ     16384           ;; one EMS page, and MEM's unit too
QGL_AR_MEM      equ     0
QGL_AR_EMS      equ     1

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

;; qgl has ONE colour format, so mgl's CFMT layer is not transcribed and
;; this is the whole of it. bpp and p2b are what ul$cfmtTB[FMT_8BIT] would
;; have answered; the transcribed modules use these constants where mgl
;; indexes that table.
FMT_8BIT        equ     0
FMT_8BIT_BPP    equ     8
FMT_8BIT_P2B    equ     0

CLIPRECT        struc                           ;; clipping rectangle
                xMin            dw      ?
                yMin            dw      ?
                xMax            dw      ?
                yMax            dw      ?
CLIPRECT        ends

;; mgl's DC, field for field, and for the stated reason: qgl is a
;; transcription of mgl and not a second design, so the struct the copied
;; code indexes has to be the struct mgl's code indexed. The row-address
;; table is back -- a Surface and a DC are equivalent now, and nothing is
;; computed where mgl looks something up.
;;
;; Names are mgl's (xRes, bps) rather than the x_res/stride this carried
;; while it was its own thing. MASM's reserved words still bite -- WIDTH
;; is an operator and ORG a directive -- but mgl's own names avoid them
;; already, which is why it could use them too.
        ifdef   _DEBUG_
                QGL_SIGN        equ     'QGLD'
        endif

MEM_SF          struc
fptr            dd      ?               ;; far pointer
MEM_SF          ends

EMS_SF          struc
hnd             dw      ?               ;; EMS handle
EMS_SF          ends

Surface         struc
fmt             dw      ?               ;; FMT_8BIT; qgl has the one
typ             dw      ?               ;; SURF_CMEM or SURF_EMS

bpp             db      ?               ;; bits per pixel
p2b             db      ?               ;; shift converting pixels to bytes
xRes            dw      ?
yRes            dw      ?
bps             dw      ?               ;; bytes per scanline
pages           dw      ?
startSL         dw      ?               ;; first scanline
_size           dd      ?               ;; bps * yRes * pages

xMin            dw      ?               ;; the clip rect is PER SURFACE, as
yMin            dw      ?               ;; mgl's is; qgl kept one global
xMax            dw      ?               ;; rect for the whole module, which
yMax            dw      ?               ;; is a divergence in its own right

                union
                                MEM_SF  <>
                                EMS_SF  <>
                ends

        ifdef   _DEBUG_
sign            dd      QGL_SIGN
        endif

SF_addrTB       equ     $               ;; scanlines' address table
Surface         ends

;;::::::::::::::
;; A SURFACE IS ITS TABLE. SF_addrTB is the offset of the scanline address
;; table, and the table is part of the object -- qglNew allocates
;; SIZEOF Surface + yRes*4 in one block, exactly as mgl's uglNew does.
;;
;; AND IT LIVES AT OFFSET 0 OF ITS OWN SEGMENT, which is mgl's rule and
;; not an accident of the allocator: every accessor reads gs:[Surface.f]
;; and gs:[SF_addrTB][si] with no base register, exactly as mgl's do.
;; Anything handing a Surface pointer around must therefore have got it
;; from qglNew/qglNewEx/qglNewView -- or be an mgl DC, which is the same
;; struct from the same allocator.

;;::::::::::::::
;; mgl's CHECKDC. A no-op unless _DEBUG_, which nothing here defines --
;; kept so the transcribed modules read as their originals do.
CHECKSF         macro   sf:req, exitlabel:req, msg
ifdef   _DEBUG_
        ifnb    <msg>
                cmp     D sf:[Surface.sign], QGL_SIGN
                je      @F
                LOGMSG  <msg>
                jmp     exitlabel
@@:
        else
                cmp     D sf:[Surface.sign], QGL_SIGN
                jne     exitlabel
        endif
endif
endm
