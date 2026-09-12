"""pakget.py PAK member out -- one file out of a Quake PAK.

    python3 tools/pakget.py ~/dos/QUAKE_SW/ID1/PAK0.PAK maps/e1m2.bsp data/e1m2.bsp
"""

import struct
import sys


def member(pak: bytes, name: str) -> bytes:
    off, n = struct.unpack_from("<ii", pak, 4)
    for i in range(n // 64):
        entry, fo, fs = struct.unpack_from("<56sii", pak, off + i * 64)
        if entry.split(b"\0")[0].decode() == name:
            return pak[fo : fo + fs]
    raise SystemExit(f"{name} is not in the PAK")


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    data = member(open(sys.argv[1], "rb").read(), sys.argv[2])
    open(sys.argv[3], "wb").write(data)


if __name__ == "__main__":
    main()
