# Building dmake 4.13.1 for DOS

mgl's makefiles are dmake's dialect -- `.IF`, `:=`, `{list}.obj`,
`$(mktmp ...)`, `.IMPORT` -- and neither NMAKE nor Borland MAKE can parse
them. `tools/mglbuild.sh` sidesteps dmake entirely and is enough for
rebuilding uGL modules; dmake is only needed for a genuine from-scratch mgl
build, which also covers the `.QLB` target and the Borland C sub-libraries.

Source: https://jimjag.github.io/dmake/ (Jim Jagielski's, the maintained
upstream). Source only, no binaries -- 4.13.1, sha256
`816664f5299b2c0ddbb717e9dcbd15f15438a724a174256b5eba0c6a6d15be6f`.

## The DOS build is broken upstream, and has been since 2004

Nothing here is local breakage. `msdos/borland/bcc30/config.h` is
hand-written, stands in for what autoconf generates on Unix, and stopped
being maintained long before 4.13.1. Four things are missing:

1. **`SIZEOF_SHORT` / `SIZEOF_INT` / `SIZEOF_LONG`.** `itypes.h` was added in
   2004 and needs them. Without them every single module dies on
   `"No 2 byte type, you lose."` -- on a compiler whose `int` is famously two
   bytes.
2. **The `HAVE_*` feature macros.** Borland C++ 3.1 has `getcwd`, `tzset`,
   `setvbuf`, `tempnam`, `strlwr` and the headers; nothing tells dmake so, and
   `extern.h` stops with `"You have no supported way of getting working
   directory"`.
3. **`PACKAGE` / `VERSION` / `BUILDINFO`.** `win95/microsft/config.h` carries
   them; the msdos one never got them, so `dmake.c` and `imacs.c` fail on an
   undefined `VERSION`.
4. **`sys/stat.h`.** Borland flattens it to the include root, so `struct stat`
   is undefined in `sysintf.c`. `sys-stat-h-shim.h` goes in the source root as
   `sys/stat.h`; `-I.` finds it.

    cd dmake-4.13.1
    patch -p1 < tools/dmake/config-h-msdos.patch
    mkdir sys && cp tools/dmake/sys-stat-h-shim.h sys/stat.h

## Building

`make.bat` only offers the `bccXXswp` (swapping) targets, which need TASM for
`msdos/exec.asm`. Both variants build here:

- **non-swapping** -- module list in `msdos/borland/bcc30/obj.rsp`, no
  assembler needed. `mkswp.bat` has no non-swapping counterpart, so the batch
  has to be generated from `obj.rsp`.
- **swapping** -- `objswp.rsp`, plus `tasm -t -mx -dmlarge msdos\exec.asm`.
  Swapping matters for 640K memory pressure, which DOSBox does not have.

Do not run `mkswp.bat` as shipped. It has hardcoded `e:\cc\borland\bcc30\lib`
paths in the response files and a Unix `mv` that DOS has no command for.
Generate the batch from the `.rsp` module list instead, and note the `.rsp`
files are CRLF -- parsing them without stripping `\r` silently produces one
module named after the whole file.

Toolchains used: `toolchains/bcpp31` (BCC, TLINK, `C0L.OBJ`, `CL.LIB` -- large
model) and `toolchains/tasm50/TASM/BIN` for the swapping build. Put the
compiler options in a `TURBOC.CFG` in the source root rather than on the
command line; DOS caps a command line at 127 characters.
