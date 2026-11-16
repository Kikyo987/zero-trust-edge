#!/usr/bin/env python3
"""Lab stand-in for Cloudflare Access in front of a connector.

Listens on the internet-side address. Forwards to the origin only after
the Access policy allows the lab headers. Does not validate a real
Cf-Access-Jwt-Assertion.
"""

from __future__ import annotations

import socket
import sys
import threading
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from access_policy import decide, load_policy  # noqa: E402

BIND = sys.argv[1]
HTTP_PORT = int(sys.argv[2])
TUNNEL_PORT = int(sys.argv[3])
POLICY = load_policy()

_conn: dict[str, socket.socket | None] = {"sock": None}
_lock = threading.Lock()


def _read_headers(conn: socket.socket) -> tuple[str, dict[str, str]]:
    data = b""
    conn.settimeout(5)
    while b"\r\n\r\n" not in data and len(data) < 8192:
        chunk = conn.recv(1024)
        if not chunk:
            break
        data += chunk
    head = data.split(b"\r\n\r\n", 1)[0].decode("latin1", "replace")
    lines = head.split("\r\n")
    headers: dict[str, str] = {}
    for line in lines[1:]:
        if ":" in line:
            k, v = line.split(":", 1)
            headers[k.strip().lower()] = v.strip()
    return lines[0] if lines else "", headers


def _send(conn: socket.socket, code: int, body: bytes) -> None:
    reason = {200: "OK", 403: "Forbidden", 502: "Bad Gateway"}.get(code, "Error")
    conn.sendall(
        f"HTTP/1.0 {code} {reason}\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n".encode()
        + body
    )


def _forward() -> tuple[int, bytes]:
    with _lock:
        sock = _conn["sock"]
        if sock is None:
            return 502, b"tunnel down"
        try:
            sock.sendall(b"REQ\n")
            sock.settimeout(5)
            # The connector writes "RESP <code> <len>\\n" and then exactly
            # <len> bytes. Read the header line only, then the body.
            buf = b""
            while b"\n" not in buf and len(buf) < 128:
                chunk = sock.recv(32)
                if not chunk:
                    break
                buf += chunk
            line, _, rest = buf.partition(b"\n")
            parts = line.decode().split()
            if len(parts) != 3 or parts[0] != "RESP":
                return 502, b"bad tunnel response"
            length = int(parts[2])
            while len(rest) < length:
                chunk = sock.recv(length - len(rest))
                if not chunk:
                    break
                rest += chunk
            return int(parts[1]), rest[:length]
        except OSError:
            _conn["sock"] = None
            return 502, b"tunnel reset"


def _http_loop() -> None:
    sock = socket.socket()
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((BIND, HTTP_PORT))
    sock.listen(16)
    sock.settimeout(90)
    while True:
        try:
            conn, _addr = sock.accept()
        except socket.timeout:
            return
        try:
            _request, headers = _read_headers(conn)
            org = headers.get("x-lab-github-org", "")
            method = headers.get("x-lab-auth-method", "")
            if decide(POLICY, org, method) != "allow":
                _send(conn, 403, b"access denied")
                continue
            code, body = _forward()
            _send(conn, code, body)
        except OSError:
            pass
        finally:
            conn.close()


def _tunnel_loop() -> None:
    sock = socket.socket()
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((BIND, TUNNEL_PORT))
    sock.listen(4)
    sock.settimeout(90)
    while True:
        try:
            conn, _addr = sock.accept()
        except socket.timeout:
            return
        with _lock:
            old = _conn["sock"]
            _conn["sock"] = conn
        if old is not None:
            try:
                old.close()
            except OSError:
                pass


def main() -> None:
    threading.Thread(target=_tunnel_loop, daemon=True).start()
    _http_loop()


if __name__ == "__main__":
    main()
