;; t06layout -- a Surface IS an mgl DC, byte for byte.
;;
;; That is what lets the renderer hand an mgl DC straight to qglRsPoly,
;; qglDrBlitScl and qglZNew with nothing in between. It used not to be
;; true: a Surface carried two extra bytes (rd_slot, wr_slot) after the
;; union, so SF_addrTB was 34 where mgl's DC_addrTB is 32, and a whole
;; module existed to copy one struct into the other.
;;
;; THE NUMBERS ARE mgl's, WRITTEN OUT. They come from
;; mgl/src/inc/ugl.inc's DC, built without _DEBUG_ (the shipped UGLV.LIB
;; carries no UGL_SIGN, so there is no sign field and the table starts at
;; 32). Reading them out of qgl.inc instead would compare the header with
;; itself and pass whatever it said.
;;
;; The second half checks the offset rather than the symbol: row 0's
;; address-table entry is read at a literal 32, and must be the pointer
;; qglSfRow hands back. A field added anywhere above moves the table and
;; that read returns whatever now sits there.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglSfFree     proto   far :dword

DC_FMT          equ     0
DC_TYP          equ     2
DC_BPP          equ     4
DC_P2B          equ     5
DC_XRES         equ     6
DC_YRES         equ     8
DC_BPS          equ     10
DC_PAGES        equ     12
DC_STARTSL      equ     14
DC_SIZE         equ     16
DC_XMIN         equ     20
DC_YMIN         equ     22
DC_XMAX         equ     24
DC_YMAX         equ     26
DC_FPTR         equ     28              ;; MEM_DC.fptr / EMS_DC.hnd, the union
DC_ADDRTB       equ     32
DC_BYTES        equ     32              ;; T DC, header only

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
n_tbl           db      'addrTB  at 32         $'
n_size_of       db      'T Surface is 32       $'
n_row_seg       db      'addrTB[0] seg is row 0$'
n_row_ofs       db      'addrTB[0] ofs is row 0$'

sf              dd      0
row             dd      0

.code
tmain           proc    far public uses bx es

                CHK     n_fmt,     Surface.fmt,     DC_FMT
                CHK     n_typ,     Surface.typ,     DC_TYP
                CHK     n_bpp,     Surface.bpp,     DC_BPP
                CHK     n_p2b,     Surface.p2b,     DC_P2B
                CHK     n_xres,    Surface.xRes,    DC_XRES
                CHK     n_yres,    Surface.yRes,    DC_YRES
                CHK     n_bps,     Surface.bps,     DC_BPS
                CHK     n_pages,   Surface.pages,   DC_PAGES
                CHK     n_startsl, Surface.startSL, DC_STARTSL
                CHK     n_size,    Surface._size,   DC_SIZE
                CHK     n_xmin,    Surface.xMin,    DC_XMIN
                CHK     n_ymin,    Surface.yMin,    DC_YMIN
                CHK     n_xmax,    Surface.xMax,    DC_XMAX
                CHK     n_ymax,    Surface.yMax,    DC_YMAX
                CHK     n_fptr,    Surface.fptr,    DC_FPTR
                CHK     n_hnd,     Surface.hnd,     DC_FPTR
                CHK     n_tbl,     SF_addrTB,       DC_ADDRTB
                CHK     n_size_of, T Surface,       DC_BYTES

                ;;
                ;; and the offset itself, not the symbol
                ;;
                invoke  qglSfInit
                invoke  qglSfNew, SFW, SFH, SURF_CMEM
                SAVEP   sf

                invoke  qglSfRow, sf, 0
                SAVEP   row

                les     bx, sf
                CHK     n_row_seg, W es:[bx+DC_ADDRTB+0], W row+2
                CHK     n_row_ofs, W es:[bx+DC_ADDRTB+2], W row+0

                invoke  qglSfFree, sf
                ret
tmain           endp
                end
