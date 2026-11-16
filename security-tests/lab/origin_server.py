#!/usr/bin/env python3
"""Loopback origin used by the lab tunnel. Counts accepted requests."""

from __future__ import annotations

import socket
import sys

HITS = sys.argv[1]
BIND = sys.argv[2] if len(sys.argv) > 2 else "127.0.0.1"
PORT = int(sys.argv[3]) if len(sys.argv) > 3 else 8080


def main() -> None:
    with open(HITS, "w", encoding="utf-8") as fh:
        fh.write("0\n")
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
        conn.settimeout(5)
        try:
            conn.recv(65536)
            with open(HITS, encoding="utf-8") as fh:
                n = int(fh.read().strip() or "0") + 1
            with open(HITS, "w", encoding="utf-8") as fh:
                fh.write(f"{n}\n")
            body = b"ok"
            conn.sendall(
                b"HTTP/1.0 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n" + body
            )
        except OSError:
            pass
        finally:
            conn.close()


if __name__ == "__main__":
    main()
