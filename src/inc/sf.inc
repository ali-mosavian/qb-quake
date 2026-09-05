;;
;; sf.inc -- the surface, shared by every module that draws.
;;
;; A surface is pixels plus the two numbers needed to walk them, and it
;; does not say where it lives: sf_row hands back a far pointer either
;; way. Conventional memory answers with arithmetic; EMS answers with a
;; page map.
;;
;; ONE SLOT PER SURFACE, fixed at creation. mgl pools its four physical
;; pages and evicts the least recently used, which means a pointer handed
;; out by one surface stops being valid the moment ANY other surface asks
;; for a window -- the cause of the gv_dst bug, of uglBuildSurf's
;; corruption, and of the still-open "surface cache draws a different
;; picture every run". With a fixed slot the only thing that can
;; invalidate a row pointer is asking the SAME surface for a row in
;; another page. Two surfaces can never take each other's window.
;;
;; That costs the freedom to have more EMS surfaces live than there are
;; slots, which is the trade: four at once, and the placement policy
;; below keeps us inside it.
;;
;; PLACEMENT. Destination and depth in conventional memory, textures and
;; lightmaps in EMS. Every EMS surface is then a power of two (atlas
;; cells 4096/1024/256/64, font 2048) and divides the 16K page exactly,
;; so no row ever straddles a page and bps needs no padding.
;;

SF_CMEM         equ     0
SF_EMS          equ     1

;; EMS physical pages. 0 and 1 are not special to us the way they were to
;; mgl (its plain accessors hardwired them), but the numbering is the
;; hardware's: emsMapEx takes 0..3 and nothing else.
SF_SLOT_MAX     equ     3

SF              struc
sfWidth         dw      ?               ;; pixels
sfHeight        dw      ?
sfBps           dw      ?               ;; bytes per row
sfWhere         db      ?               ;; SF_CMEM or SF_EMS
sfSlot          db      ?               ;; EMS physical page, SF_EMS only
sfHnd           dw      ?               ;; EMS handle, or the segment if cmem
sfOfs           dd      ?               ;; byte offset of row 0 in the store
SF              ends
