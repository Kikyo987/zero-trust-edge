#!/usr/bin/env python3
"""Lab cloudflared: dial the edge, and only then call the loopback origin."""

from __future__ import annotations

import socket
import sys

EDGE = sys.argv[1]
PORT = int(sys.argv[2])
ORIGIN = sys.argv[3] if len(sys.argv) > 3 else "127.0.0.1"


def fetch_origin() -> bytes:
    sock = socket.create_connection((ORIGIN, 8080), 3)
    try:
        sock.sendall(b"GET /healthz HTTP/1.0\r\nHost: app.example.com\r\n\r\n")
        data = b""
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            data += chunk
        return data
    finally:
        sock.close()


def main() -> None:
    end = 0
    while end < 40:
        try:
            sock = socket.create_connection((EDGE, PORT), 5)
        except OSError:
            end += 1
            continue
        try:
            sock.settimeout(20)
            line = b""
            while not line.endswith(b"\n"):
                chunk = sock.recv(16)
                if not chunk:
                    break
                line += chunk
            if line.strip() == b"REQ":
                body = fetch_origin()
                payload = f"RESP 200 {len(body)}\n".encode() + body
                sock.sendall(payload)
        except OSError:
            pass
        finally:
            sock.close()
        end += 1


if __name__ == "__main__":
    main()
