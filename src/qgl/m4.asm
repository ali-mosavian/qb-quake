;; m4.asm -- the three 4x4 matrix routines the camera needs.
;;
;; name: qglM4Persp / qglM4LookAt / qglM4Conc
;; desc: Row-major 4x4 of real4, sixteen in a row. Persp is D3D's
;;       perspective (w = h/aspect, a = zf/(zf-zn), b = zn*zf/(zn-zf),
;;       m34 = 1), LookAt the left-handed view matrix, Conc the product
;;       a*b. mgl's mdu3d.asm, the FPU sequence kept instruction for
;;       instruction: the bench picture is a byte-for-byte reference and
;;       a rounding that moves by an ulp moves it.

                .model  medium, pascal
                .386

                include qgl.inc

.const
_1_0            real4   1.0
_2piOver180     real8   0.00872664626

.code

;; fpu compare: jump if st(0) != 0 after ftst
FJNE            macro   lbl:req
                fnstsw  ax
                test    ah, 01000000b
                jz      lbl
endm

;; c = a * b, 4x4 row-major
_mtrx_axb_      macro   c:req, a:req, b:req
                        local   i, j
                i       = 0
                j       = 0
                repeat  4
                        repeat  4
                        fld     D &a[i*16+0*4]
                        fmul    D &b[0*16+j*4]
                        fld     D &a[i*16+1*4]
                        fmul    D &b[1*16+j*4]
                        fld     D &a[i*16+2*4]
                        fmul    D &b[2*16+j*4]
                        fld     D &a[i*16+3*4]
                        fmul    D &b[3*16+j*4]
                        fxch    st(3)
                        faddp   st(2), st(0)
                        faddp   st(1), st(0)
                        faddp   st(1), st(0)
                        fstp    D &c[i*16+j*4]
                        j = j + 1
                        endm
                        j = 0
                        i = i + 1
                endm
endm


;;::::::::::::::
;; qglM4Persp ( pOut, fov:deg, asp, zn, zf )
;;::::::::::::::
qglM4Persp    proc    public uses bx cx dx si di es,\
                        pOut: far ptr real4,\
                        fov : real4, asp : real4,\
                        zn  : real4, zf  : real4
                local   a:real4, b:real4
                local   x:real4, y:real4

                les     di, pOut

                fld     fov                 ;; fov
                fmul    _2piOver180         ;; fov/2 in radians
                fsincos                     ;; cos sin
                fdivrp  st(1), st(0)        ;; h = cos/sin
                fld     st(0)               ;; h h
                fdiv    asp                 ;; w h

                fld     zf                  ;; zf w h
                fsub    zn                  ;; (zf-zn) w h
                fld     zn                  ;; zn (zf-zn) w h
                fsub    zf                  ;; (zn-zf) (zf-zn) w h
                fld     zn                  ;; zn (zn-zf) (zf-zn) w h
                fmul    zf                  ;; (zn*zf) (zn-zf) (zf-zn) w h
                fld     zf                  ;; zf (zn*zf) (zn-zf) (zf-zn) w h
                fdivrp  st(3), st(0)        ;; (zn*zf) (zn-zf) a w h
                fdivrp  st(1), st(0)        ;; b a w h
                fxch    st(3)               ;; h a w b
                fstp    y                   ;; a w b
                fxch    st(1)               ;; w a b
                fstp    x                   ;; a b
                fstp    a                   ;; b
                fstp    b                   ;; empty

                push    di
                xor     eax, eax
                mov     ecx, 16
                cld
                rep     stosd
                pop     di
                mov     eax, x
                mov     ebx, y
                mov     ecx, a
                mov     edx, b
                mov     esi, _1_0
                mov     es:[di+0*16+0*4], eax
                mov     es:[di+1*16+1*4], ebx
                mov     es:[di+2*16+2*4], ecx
                mov     es:[di+3*16+2*4], edx
                mov     es:[di+2*16+3*4], esi
                ret
qglM4Persp    endp


;;::::::::::::::
;; qglM4LookAt ( pOut, pEye, pAt, pUp ) -- each a real4 x y z
;;::::::::::::::
qglM4LookAt   proc    public uses bx cx dx si di es fs gs,\
                        pOut: far ptr real4,\
                        pEye: far ptr real4,\
                        pAt : far ptr real4,\
                        pUp : far ptr real4
                local   xaxis[3] :real4
                local   yaxis[3] :real4
                local   zaxis[3] :real4

                les     di, pEye
                lfs     bx, pAt
                lgs     si, pUp

                ;; zaxis = normal(At - Eye)
                fld     D fs:[bx+0*4]
                fsub    D es:[di+0*4]
                fld     D fs:[bx+1*4]
                fsub    D es:[di+1*4]
                fld     D fs:[bx+2*4]
                fsub    D es:[di+2*4]
                fxch    st(2)                 ;; z.x z.y z.z
                fld     st(0)
                fmul    st(0), st(0)
                fld     st(2)
                fmul    st(0), st(0)
                fld     st(4)
                fmul    st(0), st(0)
                fxch    st(2)
                faddp   st(1), st(0)
                faddp   st(1), st(0)
                fsqrt                         ;; mag z.x z.y z.z
                ftst
                FJNE    @@normz
                fstp    st(0)
                jmp     @@storz
@@normz:        fld1
                fdivrp  st(1), st(0)          ;; 1/mag z.x z.y z.z
                fmul    st(1), st(0)
                fmul    st(2), st(0)
                fmulp   st(3), st(0)
@@storz:        fstp    zaxis[0*4]
                fstp    zaxis[1*4]
                fstp    zaxis[2*4]

                ;; xaxis = normal(cross(Up, zaxis))
                fld     D gs:[si+2*4]
                fmul    D zaxis[1*4]
                fld     D gs:[si+1*4]
                fmul    D zaxis[2*4]
                fsubrp  st(1), st(0)            ;; x.x
                fld     D gs:[si+0*4]
                fmul    D zaxis[2*4]
                fld     D gs:[si+2*4]
                fmul    D zaxis[0*4]
                fsubrp  st(1), st(0)            ;; x.y x.x
                fld     D gs:[si+1*4]
                fmul    D zaxis[0*4]
                fld     D gs:[si+0*4]
                fmul    D zaxis[1*4]
                fsubrp  st(1), st(0)            ;; x.z x.y x.x
                fxch    st(2)                   ;; x.x x.y x.z
                fld     st(0)
                fmul    st(0), st(0)
                fld     st(2)
                fmul    st(0), st(0)
                fld     st(4)
                fmul    st(0), st(0)
                fxch    st(2)
                faddp   st(1), st(0)
                faddp   st(1), st(0)
                fsqrt
                ftst
                FJNE    @@normx
                fstp    st(0)
                jmp     @@storx
@@normx:        fld1
                fdivrp  st(1), st(0)
                fmul    st(1), st(0)
                fmul    st(2), st(0)
                fmulp   st(3), st(0)
@@storx:        fstp    xaxis[0*4]
                fstp    xaxis[1*4]
                fstp    xaxis[2*4]

                ;; yaxis = cross(zaxis, xaxis)
                fld     zaxis[2*4]
                fmul    xaxis[1*4]
                fld     zaxis[1*4]
                fmul    xaxis[2*4]
                fsubrp  st(1), st(0)            ;; y.x
                fld     zaxis[0*4]
                fmul    xaxis[2*4]
                fld     zaxis[2*4]
                fmul    xaxis[0*4]
                fsubrp  st(1), st(0)            ;; y.y y.x
                fld     zaxis[1*4]
                fmul    xaxis[0*4]
                fld     zaxis[0*4]
                fmul    xaxis[1*4]
                fsubrp  st(1), st(0)            ;; y.z y.y y.x
                fxch    st(2)
                fstp    yaxis[0*4]
                fstp    yaxis[1*4]
                fstp    yaxis[2*4]

                ;;  x.x  y.x  z.x  0
                ;;  x.y  y.y  z.y  0
                ;;  x.z  y.z  z.z  0
                ;; -x.e -y.e -z.e  1
                lgs     si, pOut
                mov     eax, xaxis[0*4]
                mov     ecx, yaxis[0*4]
                mov     edx, zaxis[0*4]
                mov     gs:[si+0*16+0*4], eax
                mov     gs:[si+0*16+1*4], ecx
                mov     gs:[si+0*16+2*4], edx
                mov     D gs:[si+0*16+3*4], 0
                mov     eax, xaxis[1*4]
                mov     ecx, yaxis[1*4]
                mov     edx, zaxis[1*4]
                mov     gs:[si+1*16+0*4], eax
                mov     gs:[si+1*16+1*4], ecx
                mov     gs:[si+1*16+2*4], edx
                mov     D gs:[si+1*16+3*4], 0
                mov     eax, xaxis[2*4]
                mov     ecx, yaxis[2*4]
                mov     edx, zaxis[2*4]
                mov     gs:[si+2*16+0*4], eax
                mov     gs:[si+2*16+1*4], ecx
                mov     gs:[si+2*16+2*4], edx
                mov     D gs:[si+2*16+3*4], 0

                fld     xaxis[0*4]
                fmul    D es:[di+0*4]
                fld     xaxis[1*4]
                fmul    D es:[di+1*4]
                fld     xaxis[2*4]
                fmul    D es:[di+2*4]
                fxch    st(2)
                faddp   st(1), st(0)
                faddp   st(1), st(0)
                fchs                            ;; a = -dot(x, eye)
                fld     yaxis[0*4]
                fmul    D es:[di+0*4]
                fld     yaxis[1*4]
                fmul    D es:[di+1*4]
                fld     yaxis[2*4]
                fmul    D es:[di+2*4]
                fxch    st(2)
                fadd
                fadd
                fchs                            ;; b a
                fld     zaxis[0*4]
                fmul    D es:[di+0*4]
                fld     zaxis[1*4]
                fmul    D es:[di+1*4]
                fld     zaxis[2*4]
                fmul    D es:[di+2*4]
                fxch    st(2)
                faddp   st(1), st(0)
                faddp   st(1), st(0)
                fchs                            ;; c b a
                mov     eax, _1_0
                fxch    st(2)                   ;; a b c
                fstp    D gs:[si+3*16+0*4]
                fstp    D gs:[si+3*16+1*4]
                fstp    D gs:[si+3*16+2*4]
                mov     gs:[si+3*16+3*4], eax
                ret
qglM4LookAt   endp


;;::::::::::::::
;; qglM4Conc ( pOut, a, b ) -- out = a * b; out may alias either
;;::::::::::::::
qglM4Conc     proc    public uses bx cx si di es fs,\
                        pOut: far ptr real4,\
                        pIna: far ptr real4,\
                        pInb: far ptr real4
                local   mtmp[16]:real4

                les     di, pIna
                lfs     si, pInb
                _mtrx_axb_  mtmp, es:[di], fs:[si]

                les     di, pOut
                push    ds
                push    ss
                pop     ds                      ;; mtmp is on the stack
                lea     si, mtmp
                mov     cx, 16
                cld
                rep     movsd
                pop     ds
                ret
qglM4Conc     endp

                end
