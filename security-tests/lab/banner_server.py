#!/usr/bin/env python3
"""Accept TCP and write a one-line banner. Lab stand-in for sshd or Grafana."""

from __future__ import annotations

import socket
import sys

BIND = sys.argv[1]
PORT = int(sys.argv[2])
BANNER = sys.argv[3].encode()


def main() -> None:
    sock = socket.socket()
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((BIND, PORT))
    sock.listen(16)
    sock.settimeout(90)
    while True:
        try:
            conn, _addr = sock.accept()
        except socket.timeout:
            return
        try:
            conn.sendall(BANNER + b"\n")
        except OSError:
            pass
        finally:
            conn.close()


if __name__ == "__main__":
    main()
