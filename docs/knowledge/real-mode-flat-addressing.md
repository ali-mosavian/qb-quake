---
type: investigation
title: Flat 32-bit addressing in real and V86 mode, and why DOSBox lies about it
tags: [dosbox-x, bochs, real-mode, v86, dpmi, addressing, emulator-fidelity, negative-result]
---

# Flat 32-bit addressing in real and V86 mode, and why DOSBox lies about it

**Question**: on a 386+, can `segment 0` plus a 32-bit offset reach the whole
megabyte in real mode, without any protected-mode trip?

**Answer**: no — and DOSBox-X says yes, which is the part worth writing down.
Four independent bochs configurations, including a genuine V86 one, all fault.
Anything in this project built on flat reach would work under our emulator and
die on the hardware it imitates.

## The results

| environment | mode | seg 0 + 32-bit offset past 64K |
|---|---|---|
| DOSBox-X | — | **works** — 7,168 bytes over 7 regions, zero mismatches |
| bochs, boot sector (no DOS at all) | real | **#GP** |
| bochs, FreeDOS | real (`PE=0`) | **#GP** |
| bochs, `CWSDPMI -P` resident | real (`PE=0`) | **#GP** |
| bochs, DPMI client activated the host | real (`PE=0`) | **#GP** |
| bochs, HIMEM + EMM386 | **V86 (`PE=1`)** | **#GP** |

The address-size override changes the *width of the offset*, not the *reach of
the segment*. A real-mode segment load sets the cached limit to `0xFFFF`; every
byte must land inside 64K of the base. That is exactly why unreal mode exists —
if it were this easy nobody would bother with the descriptor-cache trick.

What 32-bit addressing *does* buy without any mode change is the richer
addressing forms — `[ebx + esi*4 + disp32]`, any general register as base or
index — against 16-bit's restriction to `bx/bp + si/di`. Useful for index
arithmetic, useless for reach.

## V86 cannot be made to do it

In V86 the limit is imposed by the mode, not by a cached attribute you can
subvert. While `VM=1`, every segment load forces `base = sel<<4, limit =
0xFFFF`, and *entering* V86 reloads all six segment registers from the task
state — so oversized limits arranged beforehand are destroyed on the way in.
That is the mechanism behind `flat_real_mode_demo`'s "Works with EMM386: No".

The routes that do work once a V86 monitor is running all amount to leaving
V86: become a **DPMI** client and get a flat selector (what that project's
`dpmi/gradient.asm` does), or use **VCPI** to switch to protected mode
yourself. Or don't run a memory manager, and unreal mode works — at the cost of
EMS and UMBs.

None is viable for this renderer: qrender is VBDOS real-mode BASIC and cannot
be a DPMI client. Asm helpers could switch modes per access, which costs far
more than the 54 segment reloads it would save. And the premise was weak
anyway — EMS mapping measures 0.09 ms/frame, under 0.4% of raster.

## A DPMI host does not put you in V86

This was the assumption going in, and it is wrong twice over:

- **`CWSDPMI -P` alone leaves the CPU in real mode** (`PE=0`). The host goes
  resident; it does not switch modes.
- **Neither does activating it.** After a real DPMI client (`VBE32.COM`)
  switched to protected mode and exited, the next DOS program still reported
  `PE=0`.

CWSDPMI is a DPMI *server*: it enters protected mode for its client and drops
back. What creates a persistent V86 monitor is a *memory manager*. Only the
HIMEM+EMM386 arm reported `PE=1`.

## Three ways this test was vacuous before it wasn't

Each of these produced a confident PASS that meant nothing:

1. **Target under 64K.** The first probe read a BASIC array at linear 51,078 —
   below the limit, so a successful read proved nothing. The test now reports
   whether the address is past 64K.
2. **Uniform region.** Reading BIOS ROM at `0xFE000` returned `0` both ways and
   declared a match. Two zeros agreeing is not evidence. The probe now tracks
   whether the region held more than one distinct byte and says so when it
   didn't.
3. **Both arms secretly identical.** The plain and DPMI runs produced
   byte-identical output, and were one step from being reported as "V86 also
   faults" — until an `SMSW` check showed both were `PE=0`, i.e. the same test
   run twice. `SMSW` is unprivileged and readable in V86, and its `PE` bit
   distinguishes the modes. **Two of the three DPMI arms would have been
   meaningless without it.**

A fourth, avoided by construction: a checksum-per-region approach was rejected
because live memory (the text buffer, the BIOS data area) can change between
the two passes and fake a mismatch. Comparing **per byte, both ways back to
back** closes that window.

## Method

The probe prints a marker *before* the risky read, so a fault is visible by
where output stops rather than needing a fault handler. Output goes to port
`0xE9` (bochs's debug console) so nothing depends on the video BIOS and it can
be captured headlessly.

Artefacts, all in the session scratchpad: `boot.asm` (bare-metal boot sector,
no DOS), `v86.asm` (DOS `.COM` with the `SMSW` mode check), and the FreeDOS
images built with `mtools` from `voodoo-pmode`'s bochs harness.

## Emulator fidelity

**bochs is the instrument for CPU semantics.** PCem and 86Box optimise for
timing and peripheral fidelity — 86Box is installed here but ships no machine
BIOS ROMs and cannot boot unaided. bochs is a reference interpreter that models
segment limits and exceptions architecturally, and it agreed with the
documented architecture in every configuration.

The general lesson is larger than this question: **DOSBox-X permits things the
hardware refuses.** Any low-level assumption verified only under DOSBox is
unverified. Where it matters, boot it under bochs — a boot sector plus port
`0xE9` is a 30-second test with no DOS, no ROMs and no image building.
