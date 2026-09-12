#!/usr/bin/env python3
"""Structural checks over the BASIC sources, run before every build.

Each check exists because its absence cost a build:

  CRLF      -- an insertion with bare \\n newlines compiled as
               "SUB/FUNCTION without END SUB/FUNCTION", pointing at a blank
               line, in a file whose sub/end-sub counts were perfectly balanced.
  nesting   -- sub/function and end sub/end function must pair.
  explicit  -- every module needs OPTION EXPLICIT; defint a-z hides typos.
  uses      -- a MASM proc must not `uses` the register it returns in; the
               epilogue pops it back after the body set it, so a far pointer
               comes home with the caller's segment. Cost three sessions in
               one day before anything checked for it.
"""
import glob, re, sys, os

PROC_RE = re.compile(r'^(\w+)\s+proc\b(.*)$', re.I)
ENDP_RE = re.compile(r'^(\w+)\s+endp\b', re.I)
USES_RE = re.compile(r'\buses\b([^,]*)', re.I)
RET_RE  = re.compile(r'^\s*(?:@@?\w+:)?\s*ret\b', re.I)
SETRET  = re.compile(r'^\s*mov\s+(ax|dx)\s*,', re.I)


def check_asm_uses(text):
    """Flag `uses <reg>` where <reg> holds the return value at `ret`."""
    bad, lines = [], text.replace('\r\n', '\n').split('\n')
    i = 0
    while i < len(lines):
        m = PROC_RE.match(lines[i])
        if not m:
            i += 1
            continue
        name, hdr, start = m.group(1), m.group(2), i
        while hdr.rstrip().endswith('\\') and i + 1 < len(lines):
            i += 1
            hdr = hdr.rstrip()[:-1] + lines[i]
        u = USES_RE.search(hdr)
        uses = set(u.group(1).lower().split()) if u else set()
        body, i = [], i + 1
        while i < len(lines) and not ENDP_RE.match(lines[i]):
            body.append(lines[i])
            i += 1
        # The instruction before each `ret`, skipping blanks, comments and
        # bare labels: `mov dx, x` there is the high half of a dword return.
        for j, line in enumerate(body):
            if not RET_RE.match(line.split(';')[0]):
                continue
            for prev in reversed(body[:j]):
                code = prev.split(';')[0].strip()
                if not code or re.fullmatch(r'@@?\w+:', code):
                    continue
                r = SETRET.match(code)
                if r and r.group(1).lower() in uses:
                    bad.append(f"line {start+1}: {name} `uses "
                               f"{r.group(1).lower()}` but returns in it")
                break
    return bad


def check(path):
    raw  = open(path, 'rb').read()
    text = raw.decode('latin-1')
    bad  = []

    lone = raw.count(b'\n') - raw.count(b'\r\n')
    if lone:
        bad.append(f"{lone} bare LF newlines (BC needs CRLF)")

    # BASIC-only from here. An .asm file has no SUB/FUNCTION, but it does
    # have the x86 SUB instruction, which this would otherwise count as an
    # unclosed procedure the first time anyone writes one.
    if not (path.endswith('.bas') or path.endswith('.bi')):
        if path.endswith('.asm'):
            bad += check_asm_uses(text)
        return bad

    depth = 0
    for i, line in enumerate(text.replace('\r\n', '\n').split('\n'), 1):
        code = line.split("''")[0]
        if re.match(r'\s*(sub|function)\s+[A-Za-z_]', code, re.I) \
           and not re.match(r'\s*declare\b', code, re.I):
            depth += 1
        elif re.match(r'\s*end\s+(sub|function)\b', code, re.I):
            depth -= 1
            if depth < 0:
                bad.append(f"line {i}: end without a matching sub/function")
                depth = 0
    if depth:
        bad.append(f"{depth} sub/function left unclosed")

    if path.endswith('.bas') and not text.lstrip().lower().startswith('option explicit'):
        bad.append("missing OPTION EXPLICIT")

    return bad

if __name__ == '__main__':
    root = os.path.join(os.path.dirname(__file__), '..', 'src')
    # The subsystem directories the Makefile builds, and the headers.
    # NOT a recursive walk: src/test holds standalone mgl programs that
    # are not part of this build and never carried OPTION EXPLICIT.
    dirs = ['host', 'render', 'game', 'qgl', 'qgl/test']
    pats = ['*.bas', '*.bi', '*.asm', '*.inc']
    files = sorted(f for d in dirs for pat in pats
                     for f in glob.glob(os.path.join(root, d, pat)))
    fail = 0
    for f in files:
        for msg in check(f):
            print(f"{os.path.basename(f)}: {msg}")
            fail = 1
    print("qblint: clean" if not fail else "qblint: problems found")
    sys.exit(fail)
