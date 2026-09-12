;; t33cpi4 -- B$CPI4 orders longs whose low words straddle 8000h.
;;
;; The runtime's own version, run on DOSBox-X's dynamic core, said
;; 23760 >= 40843 and 40843 <= 32767: e1m1's 40,843-byte PVS took the
;; conventional-memory branch it could not afford. Each case pushes the
;; pair the way BC does and reads the flags with the signed jumps BC
;; emits; run1.sh's conf is core=dynamic, which is the point.

                .model  medium, pascal
                .386

                include tfw.inc

                extrn   B$CPI4:far
                extrn   B$CMI4:far
                extrn   B$MUI4:far
                extrn   B$DVI4:far
                extrn   B$RMI4:far

.data
n_lo            db      '23760 < 40843          $'
n_hi            db      '40843 > 32767          $'
n_neg           db      '-17083 < 0             $'
n_carry         db      '65536 > 65535          $'
n_eq            db      '40843 = 40843          $'
n_sign          db      '-1 < 1                 $'
n_mul           db      '9127 * 65536           $'
n_muln          db      '-26094 * 65536         $'
n_div           db      '1000000 \\ 7            $'
n_divn          db      '-1000000 \\ 7           $'
n_rem           db      '1000000 mod 7          $'
n_remn          db      '-1000000 mod 7          $'
n_cmi           db      'carry: -17083 < 0      $'

v23760          dd      23760
v40843          dd      40843
v32767          dd      32767
vneg            dd      -17083
v0              dd      0
v65536          dd      65536
v65535          dd      65535
vm1             dd      -1
v1              dd      1
v9127           dd      9127
v65536b         dd      65536
vseg            dd      -26094
vmil            dd      1000000
vmiln           dd      -1000000
v7              dd      7
got             dw      0
gotl            dd      0

.code

;; got = -1, 0 or 1 for a < b, a = b, a > b, read the way BC reads it
ORDER           macro   a, b
                local   store
                push    dword ptr a
                push    dword ptr b
                call    B$CPI4
                mov     ax, 0
                je      store
                mov     ax, -1
                jl      store
                mov     ax, 1
store:          mov     got, ax
                endm

;; a whole dword, which CHK cannot see
CHK32           macro   nam, got, want
                mov     eax, got
                cmp     eax, want
                mov     ax, 0
                sete    al
                CHK     nam, ax, 1
                endm

;; the long each helper hands back, dx:ax as BC reads it. BC pushes the
;; RIGHT operand first: `64 \ x` pushes x, then 64.
ARITH           macro   fn, a, b
                push    dword ptr b
                push    dword ptr a
                call    fn
                mov     word ptr gotl, ax
                mov     word ptr gotl+2, dx
                endm

;; carry, which is all B$CMI4 answers
CARRY           macro   a, b
                local   store
                push    dword ptr a
                push    dword ptr b
                call    B$CMI4
                mov     ax, 1
                jc      store
                xor     ax, ax
store:          mov     got, ax
                endm

tmain           proc    far public uses bx cx dx si di es

                ORDER   v23760, v40843
                CHK     n_lo, got, -1
                ORDER   v40843, v32767
                CHK     n_hi, got, 1
                ORDER   vneg, v0
                CHK     n_neg, got, -1
                ORDER   v65536, v65535
                CHK     n_carry, got, 1
                ORDER   v40843, v40843
                CHK     n_eq, got, 0
                ORDER   vm1, v1
                CHK     n_sign, got, -1

                CARRY   vneg, v0
                CHK     n_cmi, got, 1

                ARITH   B$MUI4, v9127, v65536b
                CHK32   n_mul, gotl, 9127 * 65536
                ARITH   B$MUI4, vseg, v65536b
                CHK32   n_muln, gotl, -26094 * 65536

                ARITH   B$DVI4, vmil, v7
                CHK32   n_div, gotl, 142857
                ARITH   B$DVI4, vmiln, v7
                CHK32   n_divn, gotl, -142857

                ARITH   B$RMI4, vmil, v7
                CHK32   n_rem, gotl, 1
                ARITH   B$RMI4, vmiln, v7
                CHK32   n_remn, gotl, -1
                ret
tmain           endp

                end
