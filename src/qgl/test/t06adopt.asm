;; t06adopt -- a Surface laid over an mgl MEM DC.
;;
;; The DC here is synthetic: a byte array shaped like mgl's struct. That
;; is the point -- it pins the field offsets this module depends on, in a
;; test that needs no mgl linked, so a layout drift shows up here rather
;; than as a wrong pointer inside the renderer.
;;
;; The pixels are a real buffer, so adoption is checked the only way that
;; means anything: write through the Surface, read back through the raw
;; pointer, and require the same bytes.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qgl_sf_adopt_dc proto   far :dword, :dword

PIX_W           equ     40
PIX_H           equ     10
PIX_BPS         equ     48              ;; deliberately > width: padded rows

.data
n_adopt         db      'adopts a MEM dc        $'
n_w             db      'took its width         $'
n_stride        db      'took its stride not w  $'
n_write         db      'write lands in the dc  $'
n_row1          db      'row 1 honours stride   $'
n_ems           db      'refuses a non-MEM dc   $'
n_bad           db      'refuses a broken dc    $'
n_null          db      'refuses a null dc      $'

;; mgl's DC, field for field, up to the pointer we need
fakedc          label   byte
                dw      0               ;; +0  fmt
                dw      0               ;; +2  typ = DC_MEM
                db      8, 0            ;; +4  bpp, p2b
                dw      PIX_W           ;; +6  xRes
                dw      PIX_H           ;; +8  yRes
                dw      PIX_BPS         ;; +10 bps
                dw      1               ;; +12 pages
                dw      0               ;; +14 startSL
                dd      0               ;; +16 _size
                dw      0,0,0,0         ;; +20 clip rect
                dd      0               ;; +28 MEM_DC.fptr -- filled below

pixels          db      PIX_BPS*PIX_H dup (0)

dcp             dd      0
sfp             dd      0
sf              Surface <>

.code
tmain           proc    far public uses bx cx dx si di es

                ;; point the fake dc at the real buffer
                mov     word ptr fakedc+28, offset pixels
                mov     word ptr fakedc+30, ds

                mov     word ptr dcp, offset fakedc
                mov     word ptr dcp+2, ds
                mov     word ptr sfp, offset sf
                mov     word ptr sfp+2, ds

                invoke  qgl_sf_adopt_dc, dcp, sfp
                CHK     n_adopt, ax, 1

                CHK     n_w,      sf.x_res,  PIX_W
                CHK     n_stride, sf.stride, PIX_BPS

                ;; write through the Surface, read back through the buffer
                invoke  qgl_sf_pset, sfp, 3, 0, 0A5h
                mov     al, pixels+3
                xor     ah, ah
                CHK     n_write, ax, 0A5h

                ;; row 1 must land a whole stride along, not a width along
                invoke  qgl_sf_pset, sfp, 0, 1, 05Ah
                mov     al, pixels+PIX_BPS
                xor     ah, ah
                CHK     n_row1, ax, 05Ah

                ;;
                ;; and the refusals
                ;;
                mov     word ptr fakedc+2, 2            ;; not DC_MEM
                invoke  qgl_sf_adopt_dc, dcp, sfp
                CHK     n_ems, ax, 0
                mov     word ptr fakedc+2, 0

                mov     word ptr fakedc+10, PIX_W-1     ;; stride < width
                invoke  qgl_sf_adopt_dc, dcp, sfp
                CHK     n_bad, ax, 0
                mov     word ptr fakedc+10, PIX_BPS

                invoke  qgl_sf_adopt_dc, 0, sfp
                CHK     n_null, ax, 0

                ret
tmain           endp
                end
