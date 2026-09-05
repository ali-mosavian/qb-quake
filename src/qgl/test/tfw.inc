;; tfw.inc -- what every qgl test includes: the assertion macro and the
;;            protos for the framework and the layer under test.

W               textequ <word ptr>
D               textequ <dword ptr>

tchk            proto   far :word, :word, :word
tfill           proto   far :word, :word, :word, :byte
tvrfy           proto   far :word, :word, :word, :byte

;; the layer under test
qgl_vga_screen  proto   far
qgl_gem_init    proto   far
qgl_gem_frame   proto   far
qgl_gem_alloc   proto   far :dword
qgl_gem_free    proto   far :word
qgl_gem_map     proto   far :word, :word, :word
qgl_sf_init     proto   far
qgl_sf_new      proto   far :word, :word, :word, :word
qgl_sf_free     proto   far :dword
qgl_sf_row      proto   far :dword, :word
qgl_sf_view     proto   far :dword, :dword, :dword, :word, :word, :word
qgl_sf_pget     proto   far :dword, :word, :word
qgl_sf_pset     proto   far :dword, :word, :word, :word

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
