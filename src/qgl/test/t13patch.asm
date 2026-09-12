;; t13patch -- every self-patched site addresses its own instruction.
;;
;; The fillers write their per-polygon constants into their own code
;; through cs:[label-N]. If a site is relocated out from under the code
;; that patches it -- which happens when the module's contribution to
;; QGL_CODE no longer starts where the assembler thought -- the patch
;; lands on a neighbouring instruction and the filler draws a plausible
;; wrong picture with nothing to say so.
;;
;; So each site is checked against its own placeholder BEFORE anything
;; patches it: 0DEh for a byte, 0DEADh for a word, 0DEADBEEFh for a
;; dword. They were chosen to be conspicuous and this is what makes them
;; worth it.
;;
;; This must be the first thing the program does. After one fixup the
;; placeholders are gone and there is nothing left to compare against.

                .model  medium, pascal
                .386

                include qgl.inc
                include tfw.inc

qglB8Selftest proto   far

.data
n_sites         db      'patch sites addressable$'

.code
tmain           proc    far public uses bx cx dx si di es

                invoke  qglB8Selftest
                CHK     n_sites, ax, 0
                ret
tmain           endp
                end
