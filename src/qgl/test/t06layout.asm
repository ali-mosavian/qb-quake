;; t06layout -- the Surface header, written out, and the table right after it.
;;
;; It used to assert that a Surface IS an mgl DC byte for byte, which is
;; what let the renderer hand an mgl DC straight to qglRsPoly and
;; qglDrBlitScl. That premise is dead: nothing hands qgl an mgl DC any
;; more, and the depth fields a Surface now carries -- zsf and zmode,
;; which a DC has no room for -- put the scanline table at 38 where
;; DC_addrTB is 32. Keeping the old numbers would have meant refusing
;; depth-on-the-surface to preserve a compatibility nobody uses.
;;
;; What is left is worth having for two different reasons.
;;
;; The offsets below are a TRIPWIRE. Every accessor reaches its fields
;; through the struct, so reordering them breaks nothing on its own --
;; but the layout is also what qgl.bi mirrors and what a debugger session
;; reads by hand, so a change to it should be a decision and not a
;; side effect. A failure here means: say so out loud, then update these.
;;
;; The second half is a REAL TEST. It reads row 0's address-table entry at
;; a literal offset and requires it to be the pointer qglSfRow hands back.
;; A field added anywhere above moves the table, and every accessor --
;; which finds it as SF_addrTB, symbolically -- moves with it, so nothing
;; else in the library would notice. This does.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglSfFree     proto   far :dword

SF_FMT          equ     0
SF_TYP          equ     2
SF_BPP          equ     4
SF_P2B          equ     5
SF_XRES         equ     6
SF_YRES         equ     8
SF_BPS          equ     10
SF_PAGES        equ     12
SF_STARTSL      equ     14
SF_SIZE         equ     16
SF_XMIN         equ     20
SF_YMIN         equ     22
SF_XMAX         equ     24
SF_YMAX         equ     26
SF_FPTR         equ     28              ;; MEM_SF.fptr / EMS_SF.hnd, the union
SF_ZSF          equ     32              ;; the depth Surface made for this one
SF_ZMODE        equ     36
SF_TBL          equ     38
SF_BYTES        equ     38              ;; T Surface, header only

SFW             equ     32
SFH             equ     4

.data
n_fmt           db      'fmt     at 0          $'
n_typ           db      'typ     at 2          $'
n_bpp           db      'bpp     at 4          $'
n_p2b           db      'p2b     at 5          $'
n_xres          db      'xRes    at 6          $'
n_yres          db      'yRes    at 8          $'
n_bps           db      'bps     at 10         $'
n_pages         db      'pages   at 12         $'
n_startsl       db      'startSL at 14         $'
n_size          db      '_size   at 16         $'
n_xmin          db      'xMin    at 20         $'
n_ymin          db      'yMin    at 22         $'
n_xmax          db      'xMax    at 24         $'
n_ymax          db      'yMax    at 26         $'
n_fptr          db      'fptr    at 28         $'
n_hnd           db      'hnd     at 28         $'
n_zsf           db      'zsf     at 32         $'
n_zmode         db      'zmode   at 36         $'
n_tbl           db      'addrTB  at 38         $'
n_size_of       db      'T Surface is 38       $'
n_row_seg       db      'addrTB[0] seg is row 0$'
n_row_ofs       db      'addrTB[0] ofs is row 0$'

sf              dd      0
row             dd      0

.code
tmain           proc    far public uses bx es

                CHK     n_fmt,     Surface.fmt,     SF_FMT
                CHK     n_typ,     Surface.typ,     SF_TYP
                CHK     n_bpp,     Surface.bpp,     SF_BPP
                CHK     n_p2b,     Surface.p2b,     SF_P2B
                CHK     n_xres,    Surface.xRes,    SF_XRES
                CHK     n_yres,    Surface.yRes,    SF_YRES
                CHK     n_bps,     Surface.bps,     SF_BPS
                CHK     n_pages,   Surface.pages,   SF_PAGES
                CHK     n_startsl, Surface.startSL, SF_STARTSL
                CHK     n_size,    Surface._size,   SF_SIZE
                CHK     n_xmin,    Surface.xMin,    SF_XMIN
                CHK     n_ymin,    Surface.yMin,    SF_YMIN
                CHK     n_xmax,    Surface.xMax,    SF_XMAX
                CHK     n_ymax,    Surface.yMax,    SF_YMAX
                CHK     n_fptr,    Surface.fptr,    SF_FPTR
                CHK     n_hnd,     Surface.hnd,     SF_FPTR
                CHK     n_zsf,     Surface.zsf,     SF_ZSF
                CHK     n_zmode,   Surface.zmode,   SF_ZMODE
                CHK     n_tbl,     SF_addrTB,       SF_TBL
                CHK     n_size_of, T Surface,       SF_BYTES

                ;;
                ;; and the offset itself, not the symbol
                ;;
                invoke  qglSfInit
                invoke  qglSfNew, SFW, SFH, SURF_CMEM
                SAVEP   sf

                invoke  qglSfRow, sf, 0
                SAVEP   row

                les     bx, sf
                CHK     n_row_seg, W es:[bx+SF_TBL+0], W row+2
                CHK     n_row_ofs, W es:[bx+SF_TBL+2], W row+0

                invoke  qglSfFree, sf
                ret
tmain           endp
                end
