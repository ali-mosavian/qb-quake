#!/usr/bin/env python3
"""Structural checks over the BASIC sources, run before every build.

Each check exists because its absence cost a build:

  CRLF      -- an insertion with bare \\n newlines compiled as
               "SUB/FUNCTION without END SUB/FUNCTION", pointing at a blank
               line, in a file whose sub/end-sub counts were perfectly balanced.
  nesting   -- sub/function and end sub/end function must pair.
  explicit  -- every module needs OPTION EXPLICIT; defint a-z hides typos.
"""
import glob, re, sys, os

def check(path):
    raw  = open(path, 'rb').read()
    text = raw.decode('latin-1')
    bad  = []

    lone = raw.count(b'\n') - raw.count(b'\r\n')
    if lone:
        bad.append(f"{lone} bare LF newlines (BC needs CRLF)")

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
    files = sorted(glob.glob(os.path.join(root, '*.bas')) +
                   glob.glob(os.path.join(root, '*.bi')))
    fail = 0
    for f in files:
        for msg in check(f):
            print(f"{os.path.basename(f)}: {msg}")
            fail = 1
    print("qblint: clean" if not fail else "qblint: problems found")
    sys.exit(fail)
