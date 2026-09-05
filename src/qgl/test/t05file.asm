;; t05file -- the file module on its own, nothing else linked in front of
;;            it. Exists because a failure inside qgl_txt_load could not
;;            be told apart from a failure underneath it.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qgl_file_open   proto   far :dword
qgl_file_size   proto   far :word
qgl_file_read   proto   far :word, :dword, :dword
qgl_file_close  proto   far :word

.data
n_open          db      'open of a real file    $'
n_bad           db      'open of a missing file $'
n_size          db      'size is 2068           $'
n_read          db      'read returned 2068     $'
n_magic         db      'first four bytes FNT1  $'

good            db      "font.fnt",0
bad             db      "nope.fnt",0
goodp           dd      0
badp            dd      0

fh              dw      0
fsz             dd      0
buf             db      64 dup (0)
bufp            dd      0

.code
tmain           proc    far public uses bx cx dx si di es

                mov     word ptr goodp, offset good
                mov     word ptr goodp+2, ds
                mov     word ptr badp, offset bad
                mov     word ptr badp+2, ds
                mov     word ptr bufp, offset buf
                mov     word ptr bufp+2, ds

                ;; a name that is not there must fail, and this is the
                ;; assertion that has been red all along
                invoke  qgl_file_open, badp
                NZ      ax
                CHK     n_bad, ax, 0

                invoke  qgl_file_open, goodp
                mov     fh, ax
                NZ      ax
                CHK     n_open, ax, 1

                invoke  qgl_file_size, fh
                mov     word ptr fsz, ax
                mov     word ptr fsz+2, dx
                CHK     n_size, ax, 2068

                invoke  qgl_file_read, fh, bufp, 64
                CHK     n_read, ax, 64

                invoke  qgl_file_close, fh

                mov     ax, word ptr buf
                CHK     n_magic, ax, 4E46h      ;; "FN" little-endian
                ret
tmain           endp
                end
