;; tfw.inc -- what every qgl test includes: the assertion macro and the
;;            protos for the framework and the layer under test.

W               textequ <word ptr>
D               textequ <dword ptr>

tchk            proto   far :word, :word, :word
tfill           proto   far :word, :word, :word, :word
tvrfy           proto   far :word, :word, :word, :word
tshow           proto   far :word, :dword

;; the layer under test
qglVgaScreen  proto   far
qglGemInit    proto   far
qglGemFrame   proto   far
qglGemAlloc   proto   far :dword
qglGemFree    proto   far :word
qglGemMap     proto   far :word, :word, :word
qglSfInit     proto   far
qglSfNew      proto   far :word, :word, :word
qglSfFree     proto   far :dword
qglSfRow      proto   far :dword, :word
qglSfRdRow   proto   far :dword, :word
qglSfWrRow   proto   far :dword, :word
qglSfViewNew  proto   far :dword, :word, :word, :word
qglSfViewAim  proto   far :dword, :dword
qglSfPget     proto   far :dword, :word, :word
qglSfPset     proto   far :dword, :word, :word, :word

CHK             macro   nam, got, want          ;; got == want -> ok
                invoke  tchk, offset nam, got, want
                endm

SAVEP           macro   dst                     ;; dx:ax -> a dd variable
                mov     W dst, ax
                mov     W dst+2, dx
                endm

NZ              macro   r                       ;; ax = (r != 0)
                cmp     r, 0
                mov     ax, 0
                setne   al
                endm
