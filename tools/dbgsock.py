#!/usr/bin/env python3
"""dbgsock.py -- drive a DOSBox-X debug socket on a port of your choosing.

    tools/dbgsock.py launch <conf> [--port N]      start a guest on that port
    tools/dbgsock.py send <json> [<json> ...] [--port N]
    tools/dbgsock.py sym <name> [--port N]
    tools/dbgsock.py where [--port N]

The MCP's dosbox tools are pinned to one port for the life of the server
(DOSBOX_MCP_PORT, default 2159), so a second session in another worktree
takes it and every later launch here comes back "debug socket did not
open". The guest itself reads DOSBOX_DEBUG_PORT, so launching it from
here gets a socket nobody else can claim. Default 2170, not 2159, so this
never fights the MCP.

Protocol is newline-delimited JSON, documented at the top of
src/debug/debug_socket.cpp in the dosbox-x-debug tree. The useful ones:

    {"cmd":"sym","name":"d_draw_faces"}   name -> linear, segment, module
    {"cmd":"resolve","spec":"d_faces.c:712"}
    {"cmd":"bp_set","seg":X,"off":Y}
    {"cmd":"where"} / {"cmd":"regs"} / {"cmd":"locals"}
    {"cmd":"mem_dump","seg":X,"off":Y,"len":Z,"file":"/host/path"}
    {"cmd":"continue"} / {"cmd":"break"} / {"cmd":"step"}

Symbols come from the EXE itself -- see DEBUGINFO in the Makefile. The
emulator reads them at EXEC; nothing here loads them.
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
import time

DOSBOX = os.environ.get("DOSBOX_BIN") or os.path.expanduser(
    "~/work/other/dosbox-x-debug/mcp/bin/dosbox-x"
)
DEFAULT_PORT = 2170


class Dbg:
    def __init__(self, port: int, timeout: float = 20.0) -> None:
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=5)
        self.sock.settimeout(timeout)
        self.buf = b""

    def recv(self) -> dict:
        while b"\n" not in self.buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise EOFError("debug socket closed")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def send(self, cmd: dict) -> dict:
        self.sock.sendall((json.dumps(cmd) + "\n").encode())
        # The first line after connecting is an unsolicited "connected"
        # event; anything with an "event" key is a notification, not our
        # reply, and the reply is whatever comes after it.
        while True:
            msg = self.recv()
            if "event" not in msg:
                return msg


def port_open(port: int) -> bool:
    try:
        socket.create_connection(("127.0.0.1", port), timeout=1).close()
        return True
    except OSError:
        return False


def wait_port(port: int, secs: float = 25.0) -> bool:
    end = time.time() + secs
    while time.time() < end:
        if port_open(port):
            return True
        time.sleep(0.4)
    return False


def launch(conf: str, port: int) -> int:
    if port_open(port):
        raise SystemExit(f"port {port} is already in use -- pick another with --port")
    proc = subprocess.Popen(
        [DOSBOX, "-conf", conf],
        env=dict(os.environ, DOSBOX_DEBUG_PORT=str(port)),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    ok = wait_port(port)
    print(f"pid {proc.pid} on :{port} -- {'socket up' if ok else 'SOCKET DID NOT OPEN'}")
    return 0 if ok else 1


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("op", choices=("launch", "send", "sym", "where"))
    ap.add_argument("args", nargs="*")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ns = ap.parse_args(argv[1:])

    match ns.op:
        case "launch":
            return launch(ns.args[0], ns.port)
        case "send":
            dbg = Dbg(ns.port)
            for raw in ns.args:
                print(json.dumps(dbg.send(json.loads(raw))))
        case "sym":
            print(json.dumps(Dbg(ns.port).send({"cmd": "sym", "name": ns.args[0]})))
        case "where":
            print(json.dumps(Dbg(ns.port).send({"cmd": "where"})))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
