;; t32m4 -- the camera's three matrices, on numbers a real4 holds exactly.
;;
;; Persp at fov 90, aspect 2, near 1, far 2: h is cos45/sin45, which
;; rounds to 1, so the diagonal is 0.5 1 2 with -2 below and the 1 that
;; makes w = z. LookAt from (1,2,3) towards +z with y up is the identity
;; over a translation of -eye. Conc against twice the identity doubles
;; every entry, with the output aliasing an input.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglM4Persp      proto   far :far ptr, :real4, :real4, :real4, :real4
qglM4LookAt     proto   far :far ptr, :far ptr, :far ptr, :far ptr
qglM4Conc       proto   far :far ptr, :far ptr, :far ptr

.data
n_persp         db      'persp 90/2/1/2         $'
n_look          db      'lookat is -eye row     $'
n_conc          db      'conc doubles, aliased  $'

m               real4   16 dup (0.0)
two             real4   2.0, 0.0, 0.0, 0.0
                real4   0.0, 2.0, 0.0, 0.0
                real4   0.0, 0.0, 2.0, 0.0
                real4   0.0, 0.0, 0.0, 2.0
eye             real4   1.0, 2.0, 3.0
at              real4   1.0, 2.0, 4.0
up              real4   0.0, 1.0, 0.0

w_persp         real4   0.5, 0.0, 0.0, 0.0
                real4   0.0, 1.0, 0.0, 0.0
                real4   0.0, 0.0, 2.0, 1.0
                real4   0.0, 0.0, -2.0, 0.0
w_look          real4   1.0, 0.0, 0.0, 0.0
                real4   0.0, 1.0, 0.0, 0.0
                real4   0.0, 0.0, 1.0, 0.0
                real4   -1.0, -2.0, -3.0, 1.0
w_conc          real4   2.0, 0.0, 0.0, 0.0
                real4   0.0, 2.0, 0.0, 0.0
                real4   0.0, 0.0, 2.0, 0.0
                real4   -2.0, -4.0, -6.0, 2.0

f_fov           real4   90.0
f_asp           real4   2.0
f_zn            real4   1.0
f_zf            real4   2.0
got             dw      0

.code

;; ax = 1 when m equals the 16 real4 at ds:si, bit for bit
same            proc    near private uses cx si di es
                push    ds
                pop     es
                lea     di, m
                mov     cx, 16
                repe    cmpsd
                mov     ax, 0
                sete    al
                ret
same            endp

tmain           proc    far public uses bx cx dx si di es

                invoke  qglM4Persp, addr m, f_fov, f_asp, f_zn, f_zf
                lea     si, w_persp
                call    same
                mov     got, ax
                CHK     n_persp, got, 1

                invoke  qglM4LookAt, addr m, addr eye, addr at, addr up
                lea     si, w_look
                call    same
                mov     got, ax
                CHK     n_look, got, 1

                invoke  qglM4Conc, addr m, addr m, addr two
                lea     si, w_conc
                call    same
                mov     got, ax
                CHK     n_conc, got, 1

                ret
tmain           endp
                end
