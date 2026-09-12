"""Read a .qmp map container.

    tools/qmapread.py <file.qmp>                 list the members
    tools/qmapread.py <file.qmp> <member>        write the member to stdout

The format is mkassets.py's write_qmap and src/qgl/file.asm reads it by
seeking to an offset -- there is no driver, so this is the only other
reader and it exists to check the writer against the runtime.
"""

import struct
import sys

HEAD = struct.Struct("<4slHlL16s")
ENT = struct.Struct("<16sll")


def members(path: str) -> dict[str, tuple[int, int]]:
    d = open(path, "rb").read()
    magic, ver, n, dirofs, _sum, _name = HEAD.unpack_from(d, 0)
    if magic != b"QMAP":
        raise SystemExit(f"{path}: not a map container")
    if ver != 1:
        raise SystemExit(f"{path}: version {ver}, not 1")
    out = {}
    for k in range(n):
        name, ofs, size = ENT.unpack_from(d, dirofs + k * ENT.size)
        out[name.split(b"\0")[0].decode()] = (ofs, size)
    return out


def read(path: str, member: str) -> bytes:
    ofs, size = members(path)[member]
    d = open(path, "rb").read()
    return d[ofs:ofs + size]


def main() -> None:
    match sys.argv[1:]:
        case [path]:
            head = HEAD.unpack_from(open(path, "rb").read(), 0)
            name = head[5].split(b"\0")[0].decode()
            print(f"{name}  version {head[1]}  sum {head[4]:08x}")
            for name, (ofs, size) in members(path).items():
                print(f"  {name:16} {ofs:10} {size:10}")
        case [path, member]:
            sys.stdout.buffer.write(read(path, member))
        case _:
            raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
