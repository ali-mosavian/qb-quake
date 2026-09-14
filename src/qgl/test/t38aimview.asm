;; t38aimview -- qglAimView aims row 0 exactly as qglSetView does.
;;
;; The surface cache aims its class view with it on every hit, and the
;; rasteriser reads a texture through row 0 alone. So row 0's entry must
;; be qglSetView's, and a pixel read through it must come from the new
;; offset, not the one the view was left at.
;;
;; The offset is past 16K and not a whole paragraph, so EMS's page add
;; and MEM's segment normalise both have something to get wrong; the EMS
;; parent is the second EMS surface, so its handle is not the first.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglNewView      proto   far :dword, :dword, :word, :word
qglSetView      proto   far :dword, :dword
qglAimView      proto   far :dword, :dword
qglDelView      proto   far :dword

PAR_W           equ     64
PAR_H           equ     512
VIEW_W          equ     16
SKEW            equ     5                       ;; bytes into the row
ROW_A           equ     300                     ;; 19,205: page 1
ROW_B           equ     32
OFS_A           equ     ROW_A*PAR_W + SKEW
OFS_B           equ     ROW_B*PAR_W + SKEW
PIX_X           equ     3
PIX_A           equ     5Ah
PIX_B           equ     0A5h

.data
n_first_new     db      'first ems surface made $'
n_mem_new       db      'mem parent made        $'
n_ems_new       db      'ems parent made        $'
n_view          db      'view made              $'
n_entry         db      'row 0 entry is SetView $'
n_pixel         db      'row 0 reads offset A   $'
n_refuse        db      'no view, no aim        $'

first           dd      0
par             dd      0
view            dd      0
ent_a           dd      0

.code

;;::::::::::::::
;; checks the parent in par, then frees it
;;::::::::::::::
aim_case        proc    near private uses bx cx dx si di es

                invoke  qglSfPset, par, PIX_X+SKEW, ROW_A, PIX_A
                invoke  qglSfPset, par, PIX_X+SKEW, ROW_B, PIX_B

                invoke  qglNewView, par, 0, VIEW_W, VIEW_W
                SAVEP   view
                mov     bx, dx
                or      bx, ax
                NZ      bx
                CHK     n_view, ax, 1

                invoke  qglSetView, view, OFS_A
                mov     es, W view+2
                mov     eax, es:[SF_addrTB]
                mov     ent_a, eax

                invoke  qglSetView, view, OFS_B
                invoke  qglAimView, view, OFS_A

                mov     es, W view+2
                mov     eax, es:[SF_addrTB]
                xor     cx, cx
                cmp     eax, ent_a
                je      @F
                inc     cx
@@:             CHK     n_entry, cx, 0

                invoke  qglSfPget, view, PIX_X, 0
                xor     ah, ah
                CHK     n_pixel, ax, PIX_A

                invoke  qglDelView, view
                invoke  qglSfFree, par
                ret
aim_case        endp

tmain           proc    far public uses bx cx dx si di es

                invoke  qglSfInit

                invoke  qglSfNew, PAR_W, PAR_H, SURF_CMEM
                SAVEP   par
                mov     bx, dx
                or      bx, ax
                NZ      bx
                CHK     n_mem_new, ax, 1
                invoke  aim_case

                invoke  qglSfNew, PAR_W, PAR_H, SURF_EMS
                SAVEP   first
                mov     bx, dx
                or      bx, ax
                NZ      bx
                CHK     n_first_new, ax, 1

                invoke  qglSfNew, PAR_W, PAR_H, SURF_EMS
                SAVEP   par
                mov     bx, dx
                or      bx, ax
                NZ      bx
                CHK     n_ems_new, ax, 1
                invoke  aim_case
                invoke  qglSfFree, first

                invoke  qglAimView, 0, OFS_A
                CHK     n_refuse, ax, 0

                ret
tmain           endp
                end
