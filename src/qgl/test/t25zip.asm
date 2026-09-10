;; t25zip -- a stored ZIP member, read as a file.
;;
;; The sizes here are DERIVED, not read off a listing: colmap.bin is
;; Quake's colormap, 64 shades of 256 entries, and texofs.bld is one long
;; per (texture, mip) over dm3ish's 20 textures and 4 levels. Either one
;; changing means the assets changed, which is worth being told about.
;;
;; The CONTENT assertion is a round trip rather than a magic number: the
;; Makefile extracts the same member with a real unzip, and the bytes
;; this module hands back have to be those bytes. An offset that lands in
;; the local header, the extra field or the neighbouring member fails
;; here and cannot fail quietly.
;;
;; texofs.bld is deliberately the LAST member of the archive -- finding
;; it walks past every other one, which is the loop that a first-member
;; test would never enter.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglFileOpen   proto   far :dword
qglFileSize   proto   far :word
qglFileRead   proto   far :word, :dword, :dword
qglFileClose  proto   far :word

CMAP_LEN        equ     64 * 256        ;; shades x palette entries
TOFS_LEN        equ     20 * 4 * 4      ;; textures x mips x one long
CHUNK           equ     256

.data
n_open          db      'a stored member opens  $'
n_size          db      'colmap.bin is 64x256   $'
n_read          db      'and reads 256 bytes    $'
n_same          db      'byte for byte vs unzip $'
n_last          db      'the last member is 320 $'
n_clamp         db      'a read stops at its end$'
n_miss          db      'a member not there = 0 $'
n_plain         db      'no "::" is a plain file$'
n_psize         db      'and font.fnt is 2068   $'
n_two           db      'two members open at once$'
n_sysopen       db      'a foreign zip opens    $'
n_syssize       db      'and sizes its member   $'
n_sysread       db      'and reads 256 of it    $'
n_sys           db      'a foreign zip reads too$'

cmap            db      "assets.zip::colmap.bin",0
tofs            db      "assets.zip::texofs.bld",0
miss            db      "assets.zip::nope.bin",0
plain           db      "font.fnt",0
raw             db      "colmap.bin",0
sys             db      "sys.zip::colmap.bin",0

cmapp           dd      0
tofsp           dd      0
missp           dd      0
plainp          dd      0
rawp            dd      0
sysp            dd      0

zh              dw      0
zh2             dw      0
fh              dw      0
;; sized for the LARGEST read below, which is the clamped one: at CHUNK
;; the 320 bytes it returns ran over into ref, and the compare after it
;; failed for that rather than for anything the reader did.
buf             db      TOFS_LEN dup (0)
ref             db      CHUNK dup (0)
bufp            dd      0
refp            dd      0

.code

;;::::::::::::::
;; how many of the first CHUNK bytes differ
;;::::::::::::::
cmpbuf          proc    near private uses bx cx si di
                xor     bx, bx
                mov     si, offset buf
                mov     di, offset ref
                mov     cx, CHUNK
@@px:           mov     al, [si]
                cmp     al, [di]
                je      @F
                inc     bx
@@:             inc     si
                inc     di
                loop    @@px
                mov     ax, bx
                ret
cmpbuf          endp


tmain           proc    far public uses bx cx dx si di es

                mov     word ptr cmapp, offset cmap
                mov     word ptr cmapp+2, ds
                mov     word ptr tofsp, offset tofs
                mov     word ptr tofsp+2, ds
                mov     word ptr missp, offset miss
                mov     word ptr missp+2, ds
                mov     word ptr plainp, offset plain
                mov     word ptr plainp+2, ds
                mov     word ptr rawp, offset raw
                mov     word ptr rawp+2, ds
                mov     word ptr sysp, offset sys
                mov     word ptr sysp+2, ds
                mov     word ptr bufp, offset buf
                mov     word ptr bufp+2, ds
                mov     word ptr refp, offset ref
                mov     word ptr refp+2, ds

                ;;
                ;; 1. a member of the archive, by name
                ;;
                invoke  qglFileOpen, cmapp
                mov     zh, ax
                NZ      ax
                CHK     n_open, ax, 1

                invoke  qglFileSize, zh
                CHK     n_size, ax, CMAP_LEN

                invoke  qglFileRead, zh, bufp, CHUNK
                CHK     n_read, ax, CHUNK

                ;;
                ;; 2. against the same member through a real unzip
                ;;
                invoke  qglFileOpen, rawp
                mov     fh, ax
                invoke  qglFileRead, fh, refp, CHUNK
                invoke  qglFileClose, fh
                invoke  cmpbuf
                CHK     n_same, ax, 0

                ;;
                ;; 3. the last member, and a read that asks for more than
                ;;    it holds
                ;;
                invoke  qglFileOpen, tofsp
                mov     zh2, ax
                invoke  qglFileSize, zh2
                CHK     n_last, ax, TOFS_LEN

                NZ      zh                      ;; both still open
                mov     bx, ax
                NZ      zh2
                add     ax, bx
                CHK     n_two, ax, 2

                invoke  qglFileRead, zh2, bufp, 4096
                CHK     n_clamp, ax, TOFS_LEN

                invoke  qglFileClose, zh2
                invoke  qglFileClose, zh

                ;;
                ;; 4. the system zip's archive of the same member: its
                ;;    local headers carry an extra field, ours do not
                ;;
                invoke  qglFileOpen, sysp
                mov     zh, ax
                NZ      ax
                CHK     n_sysopen, ax, 1
                invoke  qglFileSize, zh
                CHK     n_syssize, ax, CMAP_LEN
                invoke  qglFileRead, zh, bufp, CHUNK
                CHK     n_sysread, ax, CHUNK
                invoke  qglFileClose, zh
                invoke  cmpbuf
                CHK     n_sys, ax, 0

                ;;
                ;; 5. a name the archive does not carry
                ;;
                invoke  qglFileOpen, missp
                NZ      ax
                CHK     n_miss, ax, 0

                ;;
                ;; 6. and no "::" at all is the file itself
                ;;
                invoke  qglFileOpen, plainp
                mov     zh, ax
                NZ      ax
                CHK     n_plain, ax, 1
                invoke  qglFileSize, zh
                CHK     n_psize, ax, 2068
                invoke  qglFileClose, zh

                ret
tmain           endp
                end
