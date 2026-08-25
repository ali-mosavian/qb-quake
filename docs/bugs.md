# Open bugs

## e1m7: freeze/crash on load, interactive only

**Symptom**: running `qrender.exe e1m7.bsp -lm` in a real (windowed,
`dosbox-dyn.conf`) DOSBox-X session froze once, then crashed on the load
screen on a second attempt. Both were user-observed, live.

**Confirmed**

- Headless, `-ticks 120`, same exe/map/assets: completes cleanly,
  `sctest 1`, screenshot captures a normal render (with a separate,
  already-known red-streak artifact -- see below).
- One live debugger attach mid-run: CPU was actively executing (register
  state differed across two samples a moment apart) -- not a hard hang
  at that point in time.
- A later debugger attach (headless, `catch_exceptions` armed) showed the
  process reaching `process_exit` within ~3s of launch, exit_code 0,
  `abnormal:false`, no exception caught, empty screen-tail capture, and
  the disassembly context differed between repeated attempts (not a
  stable/reproducible stop point).

**Ruled out**

- **Not map-specific in the way first suspected.** dm3ish showed the same
  "no completion file after N seconds" signature under the same test.
  But see next point -- that test was invalid for both maps.
- **The "hang" test methodology was wrong.** Without `-ticks`, qrender's
  main loop runs forever by design (waits for a keypress). A batch file's
  `echo DONE > ran.txt` only runs after qrender.exe *returns*, which only
  happens on quit. "No completion file after 30s" is indistinguishable
  from "running correctly, idle" -- it is not evidence of a hang. Every
  test built on this check (several, including a 4-commit bisection back
  to `e3e76ce`) is inconclusive and should not be trusted.
- **Not sound-related.** `sound.enabled = false` in `stuff.ini` already;
  `s_init`/`s_start_music`'s bodies never execute past the `if` guard.
- **Not the mgl trim (B15/B16/B32 stub, 2DFX drop).** The first "exit
  code 1" interactive failure (glass-panels launch) predates that work.

**Still open / not yet tried**

- A real reproduction with a *valid* check: `tools/dosbox.sh run`'s own
  method (default template, `core=normal`/`cycles=max`, `autotype`
  sending `s` after a delay to trigger `scr_screenshot`) is the right
  tool, proven earlier this session -- but the two attempts made here
  either hit a self-inflicted asset-staging mistake (deleted the staged
  texture BMPs with an overly broad `rm -f *.bmp` right before running)
  or produced no output/screenshot at all (unexplained; not chased
  further).
- Never got a clean visual capture of the actual failure. The debugger's
  `process_exit` observations may or may not be the same event the user
  saw -- unconfirmed either way.

**Test-harness lessons for next time**

- Never `rm -f *.bmp` in a staged run directory -- texture assets and
  screenshot output share the glob.
- Don't use "did a DOS-side completion file appear" to judge a run with
  no `-ticks`. Use `scr_screenshot` (via the `s` key / `autotype`) or a
  hard `timeout` kill plus a screenshot taken just before the kill.
- `-ticks`-bounded runs exercise load + N sim steps only; they cannot
  rule out anything that only manifests over a long real interactive
  session.

## e1m7: red streak near spawn

Thin horizontal red sliver with a bright fleck, floating over the floor,
visible in the `-ticks 120` headless capture. Likely a degenerate/edge-on
polygon from one of this map's movers (e1m7 has plats). Not investigated
beyond the initial screenshot observation.
