# Native macOS assembler/linker for µGL

`jwasm` + `jwlink` + `jwlib`, built as native ARM64 Mach-O binaries, replace
`ml.exe`/`link16`/`lib16` under DOSBox-X for assembling and archiving µGL's
16-bit real-mode DOS object code. No DOS emulation is involved in the
assemble/archive/link step; DOSBox-X is still how the resulting binaries get
*run* and tested.

Why: MASM 6.11d is the last MASM that runs *on* DOS at all -- 6.12 onward
needs Windows NT/95 to host the assembler, even though its *output* can still
target DOS. `mscopmov.asm`'s `.mmx` directive and MMX opcodes need a MASM
newer than that, which no DOS-hosted MASM can ever provide. JWasm is a
MASM-syntax-compatible, actively maintained, source-available assembler
(Sybase Open Watcom Public License) with full MMX support and a native Unix
build. JWlink is the matching linker (a modified Open Watcom Wlink), JWlib
the matching archiver.

Source: `github.com/JWasm/JWasm` and `github.com/JWasm/JWlink`, commit
`a5c4ea03cc0545a15d81a354251b5f534bef7a1b` (JWasm) at the time these patches
were cut. Sybase Open Watcom Public License v1.0.

## -Zg is mandatory

Not cosmetic, and not a patch -- jwasm already has the right behaviour, it is
just gated. Without `-Zg`, an `externdef X:far` issued *inside* a segment binds
X to that segment (`extern.c`, `case MT_FAR`), so `OFFSET X` / `SEG X` get a
fixup frame of the *referencing* segment instead of `FRAME_TARG`. MS LINK then
reports `L2002: fixup overflow` for every `SET_FMT` in `cfmt/*/*main.asm`.
MASM 6.11 emits `FRAME_TARG` there; jwasm matches it only under `-Zg`, which is
exactly what "Masm compatible code generation" is supposed to mean. Verified by
decoding both objects' FIXUPP records at identical offsets -- MASM's from the
shipped `uglv.lib`, jwasm's from a fresh build of the same source.

## Three real bugs found and fixed, not compatibility shims

Both are 64-bit-pointer-truncation bugs: a pointer gets written into a
32-bit-wide slot, and something downstream reads it back full-width. Same
bug shape in two different tools, in two different files.

**`jwasm-farptr-invoke.patch`** -- `invoke.c`, `PushInvokeParam()`. Sizing a
`far ptr <T>`-typed argument at an INVOKE call site fell back to
`SizeFromMemtype(MT_PTR, ...)`, which sizes by the *memory model's default*
pointer distance (`SIZE_DATAPTR`), not the specific symbol's own `isfar`
flag -- unlike every other `SizeFromMemtype` call site in the codebase
(`proc.c`, `types.c`, `expreval.c`), which all resolve `MT_PTR` to
`MT_FAR`/`MT_NEAR` via `sym->isfar` first. In `.model medium` (near data by
default), a parameter explicitly declared `far ptr T`, passed to a PROTO
expecting the same `far ptr T`, sized 2 bytes against a correctly-sized
4-byte PROTO parameter -- always failing `INVOKE_ARGUMENT_TYPE_MISMATCH`,
even though both sides declared the identical type. Isolated in a 17-line
repro before touching mgl's source at all; fixed by applying the same
`isfar`-first pattern already used elsewhere.

**`jwlink-frameptr-truncation.patch`** -- `obj2supp.c`. `StoreFixup()` saves
a fixup's frame data (a `segdata*`/`group_entry*`/`symbol*`, sharing one
pointer-sized union) via `PermSaveFixup(&frame->u.abs, sizeof(unsigned_32))`
-- 4 bytes. `IncExecRelocs()` reads it back with
`frame.u.ptr = *((void **)(save + 1))` -- a full 8-byte pointer on a 64-bit
host. The upper 4 bytes are whatever heap memory follows, and
`GetFrameAddr()` segfaults dereferencing the garbage `frame->u.group`. The
`FIX_CHANGE_SEG` case immediately above already had correct 64-bit handling
(the pointer split across two 32-bit words); this second, general path was
simply never given the same fix. Confirmed with `lldb` against a debug
build: `EXC_BAD_ACCESS` at `obj2supp.c:255`, `frame->u.group->grp_addr`.

**`jwasm-omf-header-overflow.patch`** -- `omf.c`, `omf_write_module()`, plus a
one-line mode change in `assemble.c`. jwasm writes the OMF header after pass
one, records `seg_pos`/`public_pos`/`end_of_header`, streams LEDATA/FIXUPP/
MODEND after it, then seeks back and rewrites SEGDEF and PUBDEF *in place* --
assuming they still fit the space reserved for them. They need not: an
`EXTERNDEF` naming a PROC defined further down leaves the symbol external
during pass one, so it is not queued as public until pass two, and the PUBDEF
section grows. The surplus bytes ran straight over the first LEDATA record.
jwasm reported "0 errors" and produced an object whose record stream desynced a
few hundred bytes in -- the raw instruction bytes were read back as a record
type. All four `src/dct/*.asm` hit it (dctbnk's header overran by 134 bytes,
leaving 68 bytes of orphaned code). Fixed by saving everything past the header,
rewriting the header at whatever size it now needs, and appending the saved
part; OMF records store no absolute file offsets, so relocating them is safe.
The object file also had to move from `fopen(...,"wb")` to `"w+b"` so it can be
read back. Upstream master (== the pinned commit) has no fix for this.
Regression-checked: `8main.obj` is byte-identical before and after.

Worth knowing before trusting the *rest* of a 64-bit JWlink build blindly:
this specific bug only reproduces on a link that actually stores and later
reads back a `FRAME_HAS_DATA` fixup record outside incremental-link mode --
exactly what a normal, non-incremental 16-bit DOS link does. It was silent
corruption, not an immediate crash, on some invocations (a truncated .EXE
that still passed `file`'s format check and even printed a correct string
before hitting the corrupted region) -- confirmed via `-noincremental`... no,
via a plain link with no `SYSTEM` directive at all producing garbage on
screen before this fix, and clean output after. Don't trust "it linked
without error" alone; run the result.

## Building

```
git clone https://github.com/JWasm/JWasm.git
git clone https://github.com/JWasm/JWlink.git
patch -p1 -d JWasm  < jwasm-farptr-invoke.patch
patch -p1 -d JWlink < jwlink-frameptr-truncation.patch

cd JWasm  && make -f GccUnix.mak CC=clang   # -> GccUnixR/jwasm

cd JWlink/dwarf/dw     && make -f GccUnix.mak CC=clang   # -> dwarf.a
cd JWlink/orl          && make -f GccUnix.mak CC=clang   # -> orl.a
cd JWlink/sdk/rc/wres  && make -f GccUnix.mak CC=clang   # -> wres.a
cd JWlink              && make -f GccUnix.mak CC=clang   # -> GccUnixR/jwlink

# jwlib has no GccUnix.mak of its own (only a Watcom-hosted OWLinux.mak);
# built ad hoc against the same orl.a:
cd JWlink/jwlib
clang -c -Ih -I../orl/h -I../lib_misc/h -I../watcom/h -D__UNIX__ \
      -D_BSD_SOURCE -DLONG_IS_64BITS -DNDEBUG -O2 -D_WCUNALIGNED= \
      -o GccUnixR/<name>.o c/<name>.c
# for each of: wlib libio symtable omfproc writelib convert wlibutil
# libwalk symlist proclib cmdline error implib elfobjs orlrtns memfuncs
# ideentry idedrv idemsgfm idemsgpr maindrv omfutil coffwrt inlib
# plus demangle.c from ../lib_misc/c, plus clibext.c from ../c (provides
# itoa/ultoa/tell/filelength -- DOS/Watcom CRT extensions absent from
# macOS's BSD libc)
clang -o GccUnixR/jwlib GccUnixR/*.o ../orl/GccUnixR/orl.a
```

Installed binaries: `~/work/other/d32x/toolchains/native/bin/{jwasm,jwlink,jwlib}`.

## The C sub-libraries

`music/`, `xsnd/` and `xsnd/snddrv/` are 15 C files, not assembler, so jwasm
cannot build them. They are compiled by `tools/bcc.sh` with Borland C++ 3.1
under DOSBox-X -- the compiler they were written for, which is what makes the
`far pascal` ABI match by construction rather than by hope. One DOSBox process
per file, so `make -j` still parallelises them; a single shared session would
serialise the whole set.

Three things that are easy to get wrong there:

- **Compile from inside the source directory.** These sources use quoted
  includes relative to their own dir (`#include "inc/modcmn.h"`), which bcc
  resolves against the current directory, not the source file's.
- **mgl's `inc/` must precede Borland's.** They do `#include "dos.h"` meaning
  *mgl's* `inc/dos.h`; `C:\INCLUDE\DOS.H` otherwise shadows it and `DOSFILE`
  and `BFILE` come out undefined in `arch.h`.
- **Compile as C, not C++ (no `-P`).** The exports are `far pascal`; C++ would
  mangle them to `@MODINIT$QV` and the BASIC side would never find `MODINIT`.

Compiling as C then requires one source fix: `music/inc/modload.h` had an
*anonymous* union, which is a C++ feature bcc rejects in C mode. It is now
named (`u`), with the 12 accesses in `modmem.c`/`modload.c` updated. Four other
files needed a stray `const` dropped or an explicit cast added, all
semantically neutral -- that tree had drifted into a state where it compiled
under neither mode.
