;; t05file -- the file module on its own, nothing else linked in front of
;;            it. Exists because a failure inside qglTxtLoad could not
;;            be told apart from a failure underneath it.
;;
;; And the handle table and the driver bracket: a handle is a slot that
;; a close gives back, the walk finds the one driver this suite links,
;; a "::" name no driver claims is refused, a plain file takes a write
;; and a zip member refuses one. The link-order contract is NOT provable
;; here: jwlink sorts the class by name, so a driver linked ahead of
;; file.obj still lands inside the bracket. MS LINK does not -- see
;; file.asm's header for the map that shows it.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglFileOpen   proto   far :dword
qglFileSize   proto   far :word
qglFileRead   proto   far :word, :dword, :dword
qglFileClose  proto   far :word
qglFileWrite  proto   far :word, :dword, :dword
qglFileDrivers proto  far

.data
n_open          db      'open of a real file    $'
n_bad           db      'open of a missing file $'
n_size          db      'size is 2068           $'
n_read          db      'read returned 2068     $'
n_magic         db      'first four bytes FNT1  $'
n_drv           db      'one driver linked      $'
n_nodrv         db      'font.fnt::x refused    $'
n_full          db      'a fifth open refused   $'
n_again         db      'and one after a close  $'
n_wr            db      'plain write took 4     $'
n_wrbk          db      'and reads back         $'
n_mwr           db      'member write refused   $'

nodrv           db      "font.fnt::x",0
cmap            db      "colmap.bin",0
memb            db      "assets.zip::colmap.bin",0
pat             db      "QGLF"
nodrvp          dd      0
cmapp           dd      0
membp           dd      0
patp            dd      0
hs              dw      QGL_FILE_MAX dup (0)

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
                invoke  qglFileOpen, badp
                NZ      ax
                CHK     n_bad, ax, 0

                invoke  qglFileOpen, goodp
                mov     fh, ax
                NZ      ax
                CHK     n_open, ax, 1

                invoke  qglFileSize, fh
                mov     word ptr fsz, ax
                mov     word ptr fsz+2, dx
                CHK     n_size, ax, 2068

                invoke  qglFileRead, fh, bufp, 64
                CHK     n_read, ax, 64

                invoke  qglFileClose, fh

                mov     ax, word ptr buf
                CHK     n_magic, ax, 4E46h      ;; "FN" little-endian

                mov     word ptr nodrvp, offset nodrv
                mov     word ptr nodrvp+2, ds
                mov     word ptr cmapp, offset cmap
                mov     word ptr cmapp+2, ds
                mov     word ptr membp, offset memb
                mov     word ptr membp+2, ds
                mov     word ptr patp, offset pat
                mov     word ptr patp+2, ds

                invoke  qglFileDrivers
                CHK     n_drv, ax, 1

                invoke  qglFileOpen, nodrvp
                CHK     n_nodrv, ax, 0

                ;; every slot, then one more, then one back
                xor     si, si
@@fill:         invoke  qglFileOpen, goodp
                mov     hs[si], ax
                add     si, 2
                cmp     si, QGL_FILE_MAX * 2
                jb      @@fill
                invoke  qglFileOpen, goodp
                CHK     n_full, ax, 0
                invoke  qglFileClose, hs[0]
                invoke  qglFileOpen, goodp
                mov     hs[0], ax
                NZ      ax
                CHK     n_again, ax, 1
                xor     si, si
@@drain:        invoke  qglFileClose, hs[si]
                add     si, 2
                cmp     si, QGL_FILE_MAX * 2
                jb      @@drain

                ;; a plain file takes a write, and it is there afterwards
                invoke  qglFileOpen, cmapp
                mov     fh, ax
                invoke  qglFileWrite, fh, patp, 4
                CHK     n_wr, ax, 4
                invoke  qglFileClose, fh
                invoke  qglFileOpen, cmapp
                mov     fh, ax
                invoke  qglFileRead, fh, bufp, 4
                invoke  qglFileClose, fh
                mov     ax, word ptr buf
                CHK     n_wrbk, ax, 4751h       ;; "QG"

                ;; a zip member refuses one
                invoke  qglFileOpen, membp
                mov     fh, ax
                invoke  qglFileWrite, fh, patp, 4
                CHK     n_mwr, ax, 0
                invoke  qglFileClose, fh
                ret
tmain           endp
                end
