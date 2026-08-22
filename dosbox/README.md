# DOSBox-X harness

`template.conf` is the only config here. `tools/dosbox.sh` fills in its four
placeholders — the three mount points and which `.bat` to run — and writes the
result into `build/<target>/` alongside the generated batch file, so that
directory is entirely disposable.

Sources come from `src/`, runtime data from `data/`; both are staged into
`build/<target>/` so the DOS side sees a flat directory.

```bash
tools/dosbox.sh build          # VBDOS 1.0 -- the toolchain that works
tools/dosbox.sh run            # run the built exe against dm3ish.bsp
tools/dosbox.sh run e1m1.bsp   # or another map
```

`build qb45` and `build pds` are also accepted. Both fail, and that is the
point: they reproduce the evidence behind the top-level README's claim that
VBDOS is required rather than merely preferred. QB 4.5 exhausts `BC.EXE`'s
workspace before it parses the program body; PDS 7.1 rejects the underscore
line continuations in `bsp_pvs.bi`.

Paths come from the environment, so nothing here is machine-specific:

| | |
|---|---|
| `MGL`        | µGL tree (default `~/work/badlogic/mgl`) |
| `TOOLCHAINS` | compiler collection (default `~/work/other/d32x/toolchains`) |
| `DOSBOX_BIN` | dosbox-x binary |
| `TIMEOUT`    | seconds; 300 build, 900 run |

The run target presses `s` on a timer, which is the program's screenshot key,
so a run leaves `scrn0.bmp` in `build/vbd/` for inspection on the host. The
first press is 60 s in because the texture converter does a 256-entry palette
search per pixel per mip level and the loading screen lasts a while.
