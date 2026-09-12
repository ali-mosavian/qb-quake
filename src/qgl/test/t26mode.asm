;; t26mode -- qglVgaShutdown goes back to the mode that was up before the
;; FIRST qglVgaInit.
;;
;; The renderer inits TWICE: scr_begin_loading brings 13h up for the
;; loading screen and vid_init brings it up again for the run. An init
;; that records the current mode every time saves 13h as the mode to
;; restore, and the program exits into a graphics screen -- where BASIC's
;; error text is drawn as pixels and a failed run looks like a slow one.
;;
;; Read back from the BIOS data area rather than from qgl's own byte: the
;; observable fact is which mode the adapter is left in, and 0040:0049 is
;; where INT 10h/00 records that.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglVgaInit      proto   far
qglVgaShutdown  proto   far

BIOS_MODE       equ     49h             ;; 0040:0049, current video mode

.data
n_back          db      'shutdown restores mode 3$'

got             dw      0

.code

tmain           proc    far public uses bx cx dx si di es

                mov     ax, 0003h
                int     10h                     ;; a known mode to go back to

                invoke  qglVgaInit
                invoke  qglVgaInit              ;; loader, then vid_init
                invoke  qglVgaShutdown

                mov     ax, 40h
                mov     es, ax
                mov     al, es:[BIOS_MODE]
                xor     ah, ah
                mov     got, ax

                ;; whatever the reading was, leave a text mode behind: the
                ;; framework's own output goes through DOS after this.
                mov     ax, 0003h
                int     10h

                CHK     n_back, got, 3

                ret
tmain           endp
                end
