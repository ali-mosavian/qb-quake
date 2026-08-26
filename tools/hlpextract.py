#!/usr/bin/env python3
r"""Extract readable topic text from Microsoft QuickHelp ("LN") .HLP databases.

These are the DOS help databases produced by Microsoft's HELPMAKE.EXE and read
by QH.EXE / the QuickBASIC 4.5 "QB Advisor" -- QB45QCK.HLP, QB45ADVR.HLP,
BAS7*.HLP, CL.HLP, QBASIC.HLP and friends.  They are NOT WinHelp, and NOT the
"tsnFile" COW help format in 45/qb5/hdcw/cw/help.h (magic 0111213 octal).

No third-party dependencies; standard library only.

    python3 tools/hlpextract.py <file.hlp> [-o out.md]

--------------------------------------------------------------------------
HOW THE FORMAT WAS ESTABLISHED
--------------------------------------------------------------------------
No prose spec for this format exists in the MS-DOS 6.0 / QuickBASIC source
tree (~/work/ms/msdos_60).  Two things stood in for one:

  (a) HELPMAKE.EXE's own embedded strings.  helpmake.exe 1.04 (Oct 10 1989,
      /Users/alim/work/ms/msdos_60/45/qbkit/build/helpmake.exe) contains its
      /V size report, which names the file's parts *in file order*:

          File Header / Topic Index / Context Strings / Context Map /
          Keywords / Huffman Tree / Topic Text

      and its pass list, which names the three compression layers:

          Run-Length Encoding and Keyword Analysis pass
          Keyword Compression & Huffman Analysis pass
          Huffman Compression pass

  (b) HELPMAKE's own decoder, used as an oracle.  `HELPMAKE /DU` decodes a
      .HLP back to unformatted source text.  Run under DOSBox-X on
      QB45QCK.HLP it produced 3146 lines; the text this module extracts is
      byte-for-byte identical on all 3146 (HELPMAKE writes a lone space for
      an empty line, this writes an empty line -- the only difference).
      That match covers the header, topic index, Huffman tree, keyphrase
      table, run-length codes, quoting and line records, i.e. the whole
      decompression path.  QB45ADVR.HLP (17005 lines) and QB45ENER.HLP
      (2357 lines) match byte for byte as well.

As a smoke test this module also decodes, without a single warning, all 42 LN
databases found under ~/work/other/d32x/toolchains and ~/work/ms/msdos_60:
QuickBASIC 4.5, BASIC PDS 7.1, VB DOS, QuickPascal 1.0, C/C++ 7.0, QBASIC 1.1
and the third-party 386MAX set.

Individual field derivations are cited inline below as either
"HELPMAKE strings", "oracle" (matches HELPMAKE /DU or /D output), or
"inferred from bytes" with the check that pinned it down.

--------------------------------------------------------------------------
FILE HEADER (70 bytes)
--------------------------------------------------------------------------
Offsets verified against QB45QCK.HLP, QB45ADVR.HLP, QB45ENER.HLP.

  0x00  char[2]   magic, "LN"
  0x02  uint16    version; 2 in every file seen
  0x04  uint16    flags; 0 in every file seen.  HELPMAKE has /L ("Lock.
                  Disable decoding") and /E[n] compression levels, so this
                  most likely records those; unverified, we have no locked
                  or low-/E sample.
  0x06  uint16    0x003A in every LN file seen, including QH.HLP and
                  QBASIC.HLP.  Purpose unknown -- a constant, not a count.
  0x08  uint16    number of topics                (inferred: the topic index
                  is exactly this+1 dwords long, see below)
  0x0A  uint16    number of context strings       (inferred: the context map
                  is exactly this many words long)
  0x0C  uint16    formatting width HELPMAKE was given via /Wnn.  78 for
                  QB45QCK/QB45ADVR (make.src builds QBASIC.HLP with /W78),
                  60 for QB45ENER.  Confirmed by the 78-character run of
                  0xC4 rules inside QB45QCK topics.
  0x0E  uint16    0
  0x10  char[18]  the database's own filename, NUL padded ("qb45qck.hlp")
  0x22  uint32[6] file offsets of the six sections, in the order HELPMAKE's
                  /V report lists them:
                    [0] topic index      [1] context strings
                    [2] context map      [3] keyphrase ("Keywords") table
                    [4] Huffman tree     [5] topic text
  0x3A  byte[8]   0 (reserved)
  0x42  uint32    total file size        (verified == len(file) on all three)
  0x46            == sections[0]; end of header

SECTIONS

  Topic index      (nTopics+1) little-endian uint32 file offsets.  Topic i
                   occupies [idx[i], idx[i+1]); the extra final entry equals
                   the file size.  (inferred; verified monotonic, and
                   idx[-1] == filesize, on all three files.)

  Context strings  nContexts NUL-terminated ASCII strings, sorted.  These are
                   the `.context` names from the .qh source -- "h.pg1",
                   "-9995", "PRINT", ... (oracle: HELPMAKE /D prints exactly
                   these as `.context` lines above each topic.)

  Context map      nContexts little-endian uint16s, parallel to the context
                   string list: context i names topic map[i].  Non-decreasing.

  Keyphrase table  a packed list of <uint8 length><length bytes>.  Exactly
                   1024 entries in QB45QCK.HLP, which is what makes the
                   keyphrase escape a 10-bit index (see below).

  Huffman tree     512 uint16s (1024 bytes -- the same size in all three
                   files, which is what flagged it as a fixed table).
                   See _huffman_decode().

  Topic text       the compressed topics, addressed by the topic index.

--------------------------------------------------------------------------
TOPIC DECOMPRESSION
--------------------------------------------------------------------------
Each topic block is:

    uint16   size of the topic after decompression
    ...      Huffman bitstream

Layer 1 -- Huffman.  The tree is 512 words with an implicit left child:
entry i is a leaf if bit 0x8000 is set (the symbol is the low byte),
otherwise it is the *byte* offset of the node's second child, and the node's
first child is simply entry i+1.  511 entries + 1 pad word = 512.  Bits are
consumed MSB-first; a 1 bit takes the adjacent child (i+1), a 0 bit follows
the stored offset.  (inferred from bytes; verified: exactly 256 leaves
covering all 256 byte values, each reachable by exactly one code, Kraft sum
exactly 1 -- and then confirmed by the oracle.)

Layer 2 -- keyphrase + run-length, on the Huffman output.  Byte values
0x10..0x1A are escapes; everything else is literal.  (inferred from bytes;
the whole set is confirmed by the oracle.)

    0x10..0x13  <lo>   keyphrase ((c & 3) << 8) | lo   -- a 10-bit index,
                       which is why the table has 1024 entries
    0x14..0x17  <lo>   same keyphrase, plus a trailing space
    0x18        <n>    n spaces
    0x19        <c><n> byte c repeated n times (the 78-wide 0xC4 rules)
    0x1A        <c>    literal c -- quotes a byte that would otherwise be
                       read as one of these escapes

This matches HELPMAKE's "Keyword Compression" and "Run Length Compression"
savings counters, and the analogous cookie scheme documented for the sister
COW format in 45/qb5/hdcw/cw/help.h (C_KEYPHRASE0 / C_KEYPHRASE_SPACE0 /
C_RUNSPACE / C_RUN / C_QUOTE).

--------------------------------------------------------------------------
TOPIC LAYOUT (after decompression)
--------------------------------------------------------------------------
A flat sequence of records, each <uint8 length><length-1 bytes of payload>,
so the length counts its own byte and a length of 1 is an empty payload.
Records strictly alternate:

    text record, attribute record, text record, attribute record, ...

(inferred from bytes; verified: for all 200 topics of QB45QCK.HLP the records
tile the decompressed block exactly with an even count, the decompressed size
matches the uint16 header, and the text records equal HELPMAKE /DU's output.)

An attribute record describes the text record just before it:

    uint8       0x00        lead byte; 0 in all 22508 records across the
                            three files.  Purpose unknown.
    (uint8 attr, uint8 run)*  character attribute runs, left to right.
                            attr is the A_* bitmask from 45/qb5/hdcw/help.inc:
                            0 plain, 1 bold, 2 italics, 4 underline.  The runs
                            may stop short of the line; the remainder is plain.
    uint8       0xFF        present only when hotspots follow
    (uint8 col, uint8 ecol, target)*   cross-reference hotspots

col/ecol are 1-based, ecol exclusive, and bracket the label text -- which in
the stored line is itself surrounded by the application's two control
characters 0x11 and 0x10 (QB draws them as the highlight brackets; the
QuickHelp source writes them as \i^Q\p ... \i^P).  target is either a
NUL-terminated context string ("-9996", or a cross-file
"QB45ADVR.HLP!.cccp"), or a NUL byte followed by a uint16 with 0x8000 set,
whose low bits are a topic number in this file.  (oracle: HELPMAKE /D renders
the topic-0 hotspots as \v@L8004\v, \v@L8001\v, \v@L8002\v, \v@L8003\v --
exactly the 0x8004/0x8001/0x8002/0x8003 numeric targets found here.)

The first text record of a topic is usually the title line, written by the
QuickHelp source as ":n<title>" where ':' is the application control
character HELPMAKE was given with /A: (see 45/qbkit/build/make.src).  Some
topics carry a preceding ":l<n>" directive line.
"""

import argparse
import struct
import sys

HEADER_SIZE = 0x46
MAGIC = b'LN'

# CP437 glyphs for 0x01..0x1F.  Python's cp437 codec maps these to Unicode
# control characters, but help text uses them as pictures -- notably 0x11/0x10,
# the hotspot brackets.  Built from code points so this source stays 7-bit.
_CP437_LOW = ' ' + ''.join(chr(c) for c in (
    0x263A, 0x263B, 0x2665, 0x2666, 0x2663, 0x2660, 0x2022,
    0x25D8, 0x25CB, 0x25D9, 0x2642, 0x2640, 0x266A, 0x266B, 0x263C,
    0x25BA, 0x25C4, 0x2195, 0x203C, 0x00B6, 0x00A7, 0x25AC, 0x21A8,
    0x2191, 0x2193, 0x2192, 0x2190, 0x221F, 0x2194, 0x25B2, 0x25BC))


def cp437(data):
    """Decode help bytes to text, keeping the CP437 glyphs for 0x01-0x1F."""
    out = []
    for b in data:
        out.append(_CP437_LOW[b] if b < 0x20 else bytes([b]).decode('cp437'))
    return ''.join(out)


class HelpError(Exception):
    pass


class Hotspot:
    __slots__ = ('col', 'ecol', 'context', 'topic')

    def __init__(self, col, ecol, context=None, topic=None):
        self.col = col          # 1-based, first character of the label
        self.ecol = ecol        # 1-based, one past the last character
        self.context = context  # context string, or None for a numeric target
        self.topic = topic      # topic number, or None for a named target

    def label(self, text):
        return cp437(text[self.col - 1:self.ecol - 1])

    def target(self):
        return self.context if self.context is not None else '#%d' % self.topic


class Line:
    __slots__ = ('text', 'attrs', 'hotspots')

    def __init__(self, text, attrs, hotspots):
        self.text = text            # bytes, CP437
        self.attrs = attrs          # list of (attr_bitmask, run_length)
        self.hotspots = hotspots    # list of Hotspot


class Topic:
    __slots__ = ('number', 'lines', 'contexts', 'error')

    def __init__(self, number):
        self.number = number
        self.lines = []
        self.contexts = []
        self.error = None

    @property
    def title(self):
        """The ':n<title>' line, if this topic has one."""
        for line in self.lines[:3]:
            t = line.text
            # ':' is the /A application control character; accept any
            # punctuation there so files built with a different /A still work.
            if len(t) >= 2 and t[1:2] == b'n' and not t[0:1].isalnum():
                return cp437(t[2:]).strip()
        return None


class HelpFile:
    """One LN database.  `data` is that database's bytes; every offset it
    stores is relative to its own start, so a database appended to another is
    handled by slicing (see load_all)."""

    def __init__(self, data, path=None):
        self.path = path
        self.data = data
        self._parse_header()
        self._parse_tables()

    @staticmethod
    def load_all(path):
        """Yield every LN database in a .HLP file.

        HELPMAKE can append one database to another (its error table has
        HELPERR_BADAPPEND, and 45/qb5/hdcw/help.inc names it too), and shipped
        files do use it: pds71/HELP/BC.HLP is bc.hlp (10523 bytes) followed by
        pwbbc.hlp (6987).  The size word at 0x42 is what makes them walkable.
        """
        with open(path, 'rb') as fh:
            blob = fh.read()
        out, off = [], 0
        while off + HEADER_SIZE <= len(blob) and blob[off:off + 2] == MAGIC:
            size = struct.unpack_from('<I', blob, off + 0x42)[0]
            if not HEADER_SIZE < size <= len(blob) - off:
                size = len(blob) - off      # trust the file over the header
            out.append(HelpFile(blob[off:off + size], path))
            off += size
        if not out:
            raise HelpError('not a QuickHelp "LN" database (bad magic)')
        if off != len(blob):
            sys.stderr.write('warning: %d trailing bytes after the last '
                             'database\n' % (len(blob) - off))
        return out

    # -- header ------------------------------------------------------------

    def _parse_header(self):
        d = self.data
        if len(d) < HEADER_SIZE or d[:2] != MAGIC:
            raise HelpError('not a QuickHelp "LN" database (bad magic)')
        (self.version, self.flags, self.unknown06, self.n_topics,
         self.n_contexts, self.width, _pad) = struct.unpack_from('<7H', d, 2)
        if self.version != 2:
            raise HelpError('unsupported LN version %d' % self.version)
        self.name = d[0x10:0x22].split(b'\x00')[0].decode('cp437', 'replace')
        self.sections = list(struct.unpack_from('<6I', d, 0x22))
        self.stated_size = struct.unpack_from('<I', d, 0x42)[0]
        if self.stated_size != len(d):
            sys.stderr.write(
                'warning: %s: header says %d bytes, database is %d\n'
                % (self.name, self.stated_size, len(d)))
        for off in self.sections:
            if off > len(d):
                raise HelpError('section offset 0x%x past end of file' % off)

    # -- tables ------------------------------------------------------------

    def _parse_tables(self):
        d = self.data
        s = self.sections

        # Topic index: nTopics+1 offsets, the last equal to the file size.
        self.index = list(struct.unpack_from(
            '<%dI' % (self.n_topics + 1), d, s[0]))

        # Context strings, then the parallel context->topic map.
        self.contexts = []
        off = s[1]
        while off < s[2] and len(self.contexts) < self.n_contexts:
            end = d.find(b'\x00', off, s[2])
            if end < 0:
                break
            self.contexts.append(d[off:end].decode('cp437', 'replace'))
            off = end + 1
        self.context_map = list(struct.unpack_from(
            '<%dH' % self.n_contexts, d, s[2]))

        # Keyphrase table: <len><len bytes>, packed.
        self.keyphrases = []
        off = s[3]
        while off < s[4]:
            n = d[off]
            self.keyphrases.append(d[off + 1:off + 1 + n])
            off += n + 1

        # Huffman tree, or None when the section is empty (an /E0 build).
        self.huffman = None
        if s[5] > s[4]:
            count = (s[5] - s[4]) // 2
            self.huffman = list(struct.unpack_from('<%dH' % count, d, s[4]))

        # context strings grouped by the topic they name
        self.topic_contexts = {}
        for name, topic in zip(self.contexts, self.context_map):
            self.topic_contexts.setdefault(topic, []).append(name)

    # -- decompression -----------------------------------------------------

    def _huffman_decode(self, blob):
        """Huffman bitstream -> bytes.  See module docstring, layer 1.

        The bitstream is padded to a byte boundary and carries no end marker,
        so the padding bits can decode one spurious extra symbol; the caller
        trims using the topic's stated uncompressed size.  (In QB45ADVR.HLP
        this happens in 145 of 533 topics, in QB45QCK.HLP in none.)"""
        tree = self.huffman
        out = bytearray()
        node = 0
        for byte in blob:
            for shift in range(7, -1, -1):
                if (byte >> shift) & 1:
                    node += 1               # 1: adjacent (implicit) child
                else:
                    node = tree[node] >> 1  # 0: stored byte offset -> index
                if node >= len(tree):
                    raise HelpError('Huffman walk left the tree')
                v = tree[node]
                if v & 0x8000:
                    out.append(v & 0xFF)
                    node = 0
        return bytes(out)

    def _expand(self, s, want=None):
        """Keyphrase + run-length expansion.  See module docstring, layer 2.

        Stops at `want` output bytes so trailing Huffman padding is dropped."""
        kp = self.keyphrases
        out = bytearray()
        i, n = 0, len(s)
        while i < n and (want is None or len(out) < want):
            c = s[i]
            if 0x10 <= c <= 0x17 and i + 1 < n:
                j = ((c & 3) << 8) | s[i + 1]
                if j >= len(kp):
                    raise HelpError('keyphrase %d out of range' % j)
                out += kp[j]
                if c >= 0x14:
                    out += b' '
                i += 2
            elif c == 0x18 and i + 1 < n:
                out += b' ' * s[i + 1]
                i += 2
            elif c == 0x19 and i + 2 < n:
                out += bytes([s[i + 1]]) * s[i + 2]
                i += 3
            elif c == 0x1A and i + 1 < n:
                out.append(s[i + 1])
                i += 2
            else:
                out.append(c)
                i += 1
        if want is not None:
            del out[want:]
        return bytes(out)

    def decompress(self, number):
        """Return the fully decompressed bytes of one topic."""
        start, end = self.index[number], self.index[number + 1]
        if not 0 <= start <= end <= len(self.data):
            raise HelpError('topic %d has a bad index entry' % number)
        blob = self.data[start:end]
        if len(blob) < 2:
            raise HelpError('topic %d is truncated' % number)
        want = struct.unpack_from('<H', blob, 0)[0]
        body = blob[2:]
        if self.huffman:
            body = self._huffman_decode(body)
        body = self._expand(body, want)
        if len(body) != want:
            sys.stderr.write(
                'warning: topic %d decompressed to %d bytes, header said %d\n'
                % (number, len(body), want))
        return body

    # -- topic structure ---------------------------------------------------

    def topic(self, number):
        """Decode one topic into Line objects.  Never raises: on failure the
        returned Topic carries .error and whatever lines were recovered."""
        t = Topic(number)
        t.contexts = self.topic_contexts.get(number, [])
        try:
            body = self.decompress(number)
        except Exception as exc:                      # noqa: BLE001
            t.error = str(exc)
            return t
        try:
            records = []
            i = 0
            while i < len(body):
                n = body[i]
                if n == 0 or i + n > len(body):
                    raise HelpError(
                        'bad record length %d at offset %d' % (n, i))
                records.append(body[i + 1:i + n])
                i += n
            if len(records) % 2:
                raise HelpError('odd record count (%d)' % len(records))
            for j in range(0, len(records), 2):
                t.lines.append(self._line(records[j], records[j + 1]))
        except Exception as exc:                      # noqa: BLE001
            t.error = str(exc)
        return t

    @staticmethod
    def _line(text, rec):
        attrs, spots = [], []
        k, total = 1, 0                 # rec[0] is the always-zero lead byte
        while k + 1 < len(rec) and rec[k] != 0xFF and total < len(text):
            attrs.append((rec[k], rec[k + 1]))
            total += rec[k + 1]
            k += 2
        if k < len(rec) and rec[k] == 0xFF:
            k += 1
            while k + 1 < len(rec):
                col, ecol = rec[k], rec[k + 1]
                k += 2
                if k < len(rec) and rec[k] == 0:     # numeric (local) target
                    k += 1
                    if k + 1 >= len(rec):
                        break
                    num = rec[k] | (rec[k + 1] << 8)
                    k += 2
                    spots.append(Hotspot(col, ecol, topic=num & 0x7FFF))
                else:
                    end = rec.find(b'\x00', k)
                    if end < 0:
                        break
                    spots.append(Hotspot(
                        col, ecol,
                        context=rec[k:end].decode('cp437', 'replace')))
                    k = end + 1
        return Line(text, attrs, spots)

    def topics(self):
        for i in range(self.n_topics):
            yield self.topic(i)


# -- output ----------------------------------------------------------------

def emit_text(hf, out):
    """Plain text, one blank line between topics.  Closest to HELPMAKE /DU."""
    for t in hf.topics():
        if t.error:
            out.write('*** topic %d: could not decode: %s ***\n\n'
                      % (t.number, t.error))
            if not t.lines:
                continue
        for line in t.lines:
            out.write(cp437(line.text).rstrip() + '\n')
        out.write('\n')


def emit_markdown(hf, out):
    out.write('# %s\n\n' % hf.name)
    out.write('%d topics, %d context strings, formatted for %d columns.\n\n'
              % (hf.n_topics, hf.n_contexts, hf.width))
    out.write('Extracted by `tools/hlpextract.py` from a Microsoft QuickHelp '
              '(`LN`) database.\n')
    failed = 0
    for t in hf.topics():
        title = t.title
        out.write('\n\n## %d. %s\n\n' % (t.number, title or '(untitled)'))
        if t.contexts:
            out.write('*Contexts: %s*\n\n'
                      % ', '.join('`%s`' % c for c in t.contexts))
        if t.error:
            failed += 1
            out.write('> **Could not decode this topic: %s**\n\n' % t.error)
            if not t.lines:
                continue
            out.write('> Partial output follows.\n\n')
        # A fenced block: this text is column-aligned -- tables, dialog-box
        # diagrams and rules -- and reflowing it would destroy it.
        out.write('```text\n')
        for line in t.lines:
            s = cp437(line.text).rstrip()
            if s[:2] in (':n', ':l'):
                continue        # source directives, not body text
            out.write(s.replace('```', "'''") + '\n')
        out.write('```\n')
        links = [(h.label(l.text), h.target())
                 for l in t.lines for h in l.hotspots]
        if links:
            out.write('\nLinks: %s\n'
                      % ', '.join('%s -> `%s`' % (a or '?', b)
                                  for a, b in links))
    out.write('\n')
    if failed:
        sys.stderr.write('%d of %d topics could not be decoded\n'
                         % (failed, hf.n_topics))


def emit_list(hf, out):
    out.write('%-5s %-42s %s\n' % ('#', 'title', 'contexts'))
    for t in hf.topics():
        if t.error:
            label = '<undecoded: %s>' % t.error
        else:
            label = t.title or '(untitled)'
        out.write('%-5d %-42s %s\n'
                  % (t.number, label[:42], ' '.join(t.contexts)))


def main(argv=None):
    ap = argparse.ArgumentParser(
        description='Extract topic text from a Microsoft QuickHelp '
                    '("LN") .HLP database.')
    ap.add_argument('file')
    ap.add_argument('-o', '--output', help='write here instead of stdout')
    ap.add_argument('-f', '--format', default='md',
                    choices=('md', 'text', 'list'),
                    help='md: markdown sections (default); '
                         'text: plain text; list: one line per topic')
    ap.add_argument('--info', action='store_true',
                    help='print the header/section layout and exit')
    args = ap.parse_args(argv)

    try:
        dbs = HelpFile.load_all(args.file)
    except (HelpError, OSError, struct.error) as exc:
        sys.stderr.write('%s: %s\n' % (args.file, exc))
        return 1

    if args.info:
        names = ('topic index', 'context strings', 'context map',
                 'keyphrase table', 'huffman tree', 'topic text')
        print('file            %s' % args.file)
        for i, hf in enumerate(dbs):
            print('database %d      %s (%d bytes)' % (i, hf.name, len(hf.data)))
            print('  version %d  flags 0x%04x  word@0x06 0x%04x  width %d'
                  % (hf.version, hf.flags, hf.unknown06, hf.width))
            print('  topics %d  contexts %d  keyphrases %d  huffman entries %s'
                  % (hf.n_topics, hf.n_contexts, len(hf.keyphrases),
                     len(hf.huffman) if hf.huffman else 'none'))
            ends = hf.sections[1:] + [len(hf.data)]
            for nm, off, end in zip(names, hf.sections, ends):
                print('    %-16s 0x%06x  %7d bytes' % (nm, off, end - off))
        return 0

    if args.output:
        out = open(args.output, 'w', encoding='utf-8')
    else:
        out = sys.stdout
    emit = {'md': emit_markdown, 'text': emit_text, 'list': emit_list}[
        args.format]
    try:
        for i, hf in enumerate(dbs):
            if len(dbs) > 1 and args.format == 'md' and i:
                out.write('\n\n---\n')
            emit(hf, out)
    finally:
        if args.output:
            out.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
