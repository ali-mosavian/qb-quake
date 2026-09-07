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

qglSfAdoptDc proto   far :dword, :dword

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

;; mgl's DC, field for field, through row zero of DC_addrTB
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
                dd      0               ;; +28 raw allocation pointer
                dw      0               ;; +32 row-0 segment
                dw      0               ;; +34 row-0 offset

raw             db      PIX_BPS*PIX_H dup (0CCh)
pixels          db      PIX_BPS*PIX_H dup (0)

dcp             dd      0
sfp             dd      0
sf              Surface <>

.code
tmain           proc    far public uses bx cx dx si di es

                ;; The raw pointer is a decoy: adopting it was the bug.
                ;; MGL draws through the normalised address table.
                mov     word ptr fakedc+28, offset raw
                mov     word ptr fakedc+30, ds
                mov     word ptr fakedc+32, ds
                mov     word ptr fakedc+34, offset pixels

                mov     word ptr dcp, offset fakedc
                mov     word ptr dcp+2, ds
                mov     word ptr sfp, offset sf
                mov     word ptr sfp+2, ds

                invoke  qglSfAdoptDc, dcp, sfp
                CHK     n_adopt, ax, 1

                CHK     n_w,      sf.x_res,  PIX_W
                CHK     n_stride, sf.stride, PIX_BPS

                ;; write through the Surface, read back through the buffer
                invoke  qglSfPset, sfp, 3, 0, 0A5h
                mov     al, pixels+3
                xor     ah, ah
                CHK     n_write, ax, 0A5h

                ;; row 1 must land a whole stride along, not a width along
                invoke  qglSfPset, sfp, 0, 1, 05Ah
                mov     al, pixels+PIX_BPS
                xor     ah, ah
                CHK     n_row1, ax, 05Ah

                ;;
                ;; and the refusals
                ;;
                mov     word ptr fakedc+2, 2            ;; not DC_MEM
                invoke  qglSfAdoptDc, dcp, sfp
                CHK     n_ems, ax, 0
                mov     word ptr fakedc+2, 0

                mov     word ptr fakedc+10, PIX_W-1     ;; stride < width
                invoke  qglSfAdoptDc, dcp, sfp
                CHK     n_bad, ax, 0
                mov     word ptr fakedc+10, PIX_BPS

                invoke  qglSfAdoptDc, 0, sfp
                CHK     n_null, ax, 0

                ret
tmain           endp
                end
