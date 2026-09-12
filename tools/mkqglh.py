#!/usr/bin/env python3
"""mkqglh.py -- generate cport/src/qgl.h from qgl.inc plus the asm.

    tools/mkqglh.py src/qgl cport/src/qgl.h
    tools/mkqglh.py src/qgl cport/src/qgl.h --check

The asm is the authority for everything it states, because the assembler
derives stack offsets from the `proc` directive and the body addresses
those names -- it cannot drift from the implementation the way a
hand-written declare does, and a drifted declare is this project's most
common build break.

  parameters   the `proc` directive: name and MASM type.
  return type  the signature comment above it, in either of the two
               spellings qgl uses -- `(...) :dword` or `-> far ptr`.
  constants    qgl.inc, through the same mkqglbi.EXPORT list qgl.bi
               uses, so the two bindings cannot disagree.

qgl.decl -- a snapshot of the BASIC declares -- is consulted for two
things only: to sharpen `far ptr` into the record type it really points
at, and to cross-check arity. A mismatch there is a build failure.

Entries taking a BASIC string or array descriptor are skipped with a
note. qgl keeps those behind `*Bas` wrappers, so the layer underneath is
already C-callable.
"""

import re
import sys
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import mkqglbi


# MASM parameter type -> C. `far ptr <x>` is sharpened from qgl.decl
# where that names a record; on its own it can only be a void far *.
MASM = {"word": "short", "dword": "long", "byte": "short",
        "real4": "float", "real8": "double"}

# The return may sit on the signature line or on a `;;` continuation
# under it -- qglArLoad puts it on the next line, and reading that as
# void hands the caller dx as half an answer with nothing to notice.
RET_DOC = re.compile(
    r";;\s*(qgl\w+)\s*\([^)]*\)\s*(?::\s*(\w+)\s*$|(?:[^\r\n]*\r?\n\s*;;\s*)?->\s*([^\r\n]*))",
    re.M)
DOC_SIG = re.compile(r";;\s*(qgl\w+)\s*\(([^)]*)\)")


def parse_asm(root: pathlib.Path) -> tuple[dict, dict, dict]:
    """(params, return types, doc-comment parameter types).

    The doc signature is kept because it says what the proc directive
    cannot: `path:far ptr to ASCIIZ` is a char far *, where the
    directive only knows it is four bytes. Passing those as long would
    put a cast at every call site, and a far-to-near cast compiles
    silently here and drops the segment.
    """
    params: dict[str, list[tuple[str, str]]] = {}
    rets: dict[str, str] = {}
    doc: dict[str, dict[str, str]] = {}
    for f in sorted(root.rglob("*.asm")):
        if "test" in f.parts:
            continue
        text = f.read_text(encoding="latin-1")

        for m in DOC_SIG.finditer(text):
            doc[m.group(1)] = {
                k.strip(): v.strip()
                for k, v in re.findall(r"([A-Za-z_]\w*)\s*:\s*([^,)]+)", m.group(2))}

        for m in RET_DOC.finditer(text):
            name, typ, prose = m.group(1), m.group(2), m.group(3)
            if typ:
                rets[name] = MASM.get(typ.lower(), "void")
            else:
                t = (prose or "").strip().lower()
                # Only the exact forms. A loose match here would hand a
                # caller dx as half an answer with nothing to notice it.
                if "far ptr" in t or "dx:ax" in t:
                    rets[name] = "long"
                elif re.match(r"ax\b", t):
                    rets[name] = "short"

        lines = text.splitlines()
        for i, raw in enumerate(lines):
            m = re.match(r"^([A-Za-z_][\w$]*)\s+proc\s+(.*)$", raw.split(";")[0])
            if not m:
                continue
            name, blob = m.group(1), m.group(2)
            j = i
            while blob.rstrip().endswith("\\") and j + 1 < len(lines):
                j += 1
                blob = blob.rstrip()[:-1] + " " + lines[j].split(";")[0].strip()
            if "private" in blob.lower() or not name.lower().startswith("qgl"):
                continue
            # The uses clause carries no colon, so the colon alone finds
            # the parameters -- and the type may be `real4` or
            # `far ptr real4`, never just word/dword.
            params[name] = [(p, t.strip())
                            for p, t in re.findall(r"([A-Za-z_]\w*)\s*:\s*([^,\\]+)", blob)]
    return params, rets, doc


RET_BAS = {"integer": "short", "long": "long", "single": "float"}


def parse_decls(path: pathlib.Path) -> tuple[dict, dict]:
    """(name -> raw BASIC parameters, name -> C return type).

    The return half matters as much as the parameters: the asm says what
    it leaves in ax or dx:ax only where someone wrote the signature
    comment that way, and reading a missing one as void turns a
    value-returning entry into a silent discard -- qglSfPget did exactly
    that here. BASIC had to declare the return to call it at all, so
    where a declare exists it is the authority.
    """
    args: dict[str, list[str]] = {}
    rets: dict[str, str] = {}
    for line in path.read_text(encoding="latin-1").splitlines():
        m = re.match(r"\s*declare\s+(function|sub)\s+(qgl\w*)\s*\((.*?)\)\s*(?:as\s+(\w+))?\s*$",
                     line, re.I)
        if not m:
            continue
        kind, name, blob, ret = m.groups()
        args.setdefault(name, [a.strip() for a in blob.split(",") if a.strip()])
        r = RET_BAS.get((ret or "").lower(), "void") if kind.lower() == "function" else "void"
        # A `sub` declare is a caller discarding the answer, not proof
        # there is none -- qglRsPoly is declared both ways.
        if r != "void" or name not in rets:
            rets[name] = r
    return args, rets


def sharpen(basic: str | None) -> str | None:
    """`seg m as Mat4` -> `Mat4 far *`. None when BASIC adds nothing."""
    if not basic:
        return None
    m = re.match(r"seg\s+\w+\s+as\s+(\w+)$", re.sub(r"\s+", " ", basic.strip()), re.I)
    if m:
        return "void far *" if m.group(1).lower() == "any" else f"{m.group(1)} far *"
    return None


def ctype(masm: str, basic: str | None, docty: str | None) -> str | None:
    # A surface handle IS a far pointer here, so a bare `far ptr` in the
    # doc says nothing about whether this is a handle or a pointer to a
    # record. Only sharpen when the doc NAMES what is pointed at --
    # handles stay long, which is what BASIC and d_faces.c both declare.
    d = (docty or "").lower()
    if "asciiz" in d:
        return "const char far *"
    if (sh := sharpen(basic)):
        return sh
    t = masm.lower()
    if t in MASM:
        return MASM[t]
    if "far ptr" in t or t == "far":
        return sharpen(basic) or "void far *"
    if "near ptr" in t:
        return "void *"
    return None


def render(vals, derived, params, rets, bas_rets, decls, doc) -> tuple[str, list[str], list[str]]:
    L = ["/*",
         " * qgl.h -- the qgl layer, for C callers.",
         " *",
         " * GENERATED by tools/mkqglh.py from src/qgl. Do not edit: the",
         " * build regenerates it and fails if this copy has drifted.",
         " */",
         "#ifndef QGL_H",
         "#define QGL_H",
         '#include "qgltypes.h"',
         ""]

    for note, names in mkqglbi.EXPORT:
        L.append(f"/* {note} */")
        w = max(len(n) for n in names)
        for n in names:
            src = mkqglbi.ALIAS.get(n, n)
            if src not in vals:
                raise SystemExit(f"mkqglh: {src} not found in qgl.inc")
            if src in derived:
                raise SystemExit(f"mkqglh: {src} is defined from SIZEOF; write it out")
            L.append(f"#define {n:<{w}} {vals[src]}")
        L.append("")

    L.append("/* far pascal, which is qgl.inc's own rule for every qgl_ entry. */")
    L.append("")
    skipped, unsure = [], []
    for name in sorted(params, key=str.lower):
        if not re.match(r"qgl[A-Z]", name):
            continue
        basic = decls.get(name)
        if basic is not None and len(basic) != len(params[name]):
            raise SystemExit(
                f"mkqglh: {name} takes {len(params[name])} in the asm and "
                f"{len(basic)} in qgl.decl. A drifted declare -- fix the source.")
        if basic and any(re.search(r"\bas string\b", a, re.I) or "()" in a for a in basic):
            skipped.append(name)
            continue
        # The asm's width and BASIC's type are two statements about one
        # parameter, and only the COUNT was ever checked -- so qglZScale
        # said dword in z.asm and `as single` in qgl.decl, the asm won,
        # and every C caller converted its float to an integer instead
        # of handing over the bit pattern the fillers multiply.
        for k, (pname, masm) in enumerate(params[name]):
            if not basic:
                continue
            bas_f = bool(re.search(r"\bas (single|double)\b", basic[k], re.I))
            asm_f = masm.strip().lower() in ("real4", "real8")
            if bas_f != asm_f:
                raise SystemExit(
                    f"mkqglh: {name}'s {pname} is {masm.strip()} in the asm and "
                    f"{basic[k]} in qgl.decl -- one of them is wrong.")
        args = []
        for k, (pname, masm) in enumerate(params[name]):
            c = ctype(masm, basic[k] if basic else None,
                      doc.get(name, {}).get(pname))
            if c is None:
                args = None
                break
            args.append(f"{c} {pname}")
        if args is None:
            unsure.append(name)
            continue
        # The asm states what it leaves in ax, and that is the fact.
        # BASIC fills the gap where no signature comment says: it had to
        # declare a return to call the entry at all, so `as integer` is
        # evidence, while `sub` is only this caller discarding the
        # answer -- qglTxtChar does return the glyph advance and BASIC
        # declares it a sub, and qglRsPoly is declared both ways.
        # Two non-void answers that differ is a real contradiction.
        ret = rets.get(name) or bas_rets.get(name, "void")
        a, b = rets.get(name, "void"), bas_rets.get(name, "void")
        if a != "void" and b != "void" and a != b:
            raise SystemExit(
                f"mkqglh: {name} returns {b} per qgl.decl and {a} per the "
                f"asm signature comment. One is wrong -- fix the source.")
        L.append(f"{ret} pascal far {name}( {', '.join(args) or 'void'} );")

    L.append("")
    for title, names in (("BASIC's own -- a string or array descriptor in the "
                          "signature.\n * qgl keeps these behind *Bas wrappers; C calls the "
                          "layer\n * under them instead.", skipped),
                         ("Parameter types the asm states in a form this tool does not\n"
                          " * map. Add them by hand in qgltypes.h if C needs them.", unsure)):
        if names:
            L.append(f"/* {title}")
            L.append(" *")
            for n in names:
                L.append(f" *   {n}")
            L.append(" */")
            L.append("")
    L.append("#endif")
    return "\n".join(L) + "\n", skipped, unsure


def main(argv: list[str]) -> int:
    root, out = pathlib.Path(argv[1]), pathlib.Path(argv[2])
    check = "--check" in argv
    vals, derived = mkqglbi.constants((root / "qgl.inc").read_text(encoding="latin-1"))
    params, rets, doc = parse_asm(root)
    decls, bas_rets = parse_decls(root / "qgl.decl")
    want, skipped, unsure = render(vals, derived, params, rets, bas_rets, decls, doc)
    have = out.read_text(encoding="latin-1") if out.exists() else ""
    if have == want:
        return 0
    if check:
        sys.stderr.write(f"mkqglh: {out} is stale -- run tools/mkqglh.py\n")
        return 1
    out.write_text(want, encoding="latin-1")
    n = sum(1 for l in want.splitlines() if " pascal far " in l)
    sys.stderr.write(f"{out}: {n} prototypes, {len(skipped)} BASIC-only, "
                     f"{len(unsure)} unmapped\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
