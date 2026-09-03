# cport: e1m1 loads, but unlit and unculled

**New capability.** e1m1 renders under cport -- 5516 faces, 1531 leaves,
58 submodels, ~10 fps at the slipgate room. The BASIC-linked build has
never loaded this map; freeing the BASIC runtime and its far heap is what
made the difference, which was the port's original justification.

Two subsystems silently degrade on it, both from fixed caps sized when
dm3ish and e1m7 were the only maps:

- **`sc_init` fails**, so `-lm` has no surface cache and the map draws
  unlit. 5516 faces wants more far memory than `farmalloc` returns here.
- **Portal culling disables itself.** e1m1 has 1531 leaves against
  `PT_MAX_LEAVES` 1024, so `r_portal_mark` returns -2 and `r_bsp.c` falls
  back to the full PVS. `PT_MAX_REFS` (4096) is also under e1m1's 6624
  refs. Both constants carry a comment naming only dm3ish and e1m7.

Neither reports anything to the user beyond `sc_init FAILED` in the step
log -- the frame just comes back unlit and slow.

**Measured on the way in**: the `-comp` composite DC in conventional
memory (64,000 bytes) is on its own enough to stop e1m1 loading -- it dies
on `texinf.bld`, a 16 KB allocation, and loads without it. Reverted to EMS
in f02f86c; see cport-portal-overcull.md for why it was briefly MEM.
