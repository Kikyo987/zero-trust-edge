# External TCP scan of temporary lab VPS 45.32.107.245

- **Target:** `45.32.107.245`, a temporary Vultr lab machine. The owner will shut it down after testing.
- **Scanner:** a different host. Python TCP connect. nmap was not installed on the scanner.
- **When:** 16 Nov 2026, about 15:21–15:27 Asia/Singapore (07:21–07:27 UTC).
- **VPS at scan time:** Ubuntu 26.10, kernel `7.3.0-10-generic`. UFW active, default deny incoming, only `22/tcp` allowed. `sshd` listened on `0.0.0.0:22` and `[::]:22`. Nothing listened on 80, 443, 3000, 6443, 8080, or 9090. No Docker, k3s, cloudflared, or Tailscale.

| Port | Review name | Result that belongs in the write-up | What reached the VPS |
| --- | --- | --- | --- |
| 22/tcp | SSH | **Open.** Banner `SSH-2.0-OpenSSH_10.5p1 Ubuntu-1ubuntu3.1`. Handshake about 160–350 ms. | SYN arrived. The VPS sent SYN-ACK. Expected, because Tailscale was not set up and SSH was the only access path. A finished node does not leave 22 on the public address. |
| 80/tcp | HTTP | **Not open on the VPS.** | No SYN to port 80 during the controlled scan. The scanner host intercepts outbound TCP 80/443 (a local egress proxy). `connect()` can succeed in about 0 ms and then return no HTTP body. UFW does not allow 80. Nothing is listening. |
| 443/tcp | HTTPS | **Not open on the VPS.** | No SYN to port 443. Same scanner intercept. A TLS ClientHello got no reply. UFW does not allow 443. Nothing is listening. |
| 3000/tcp | Grafana | **Filtered** (connect timeout about 3 s). | SYNs arrived and were logged `[UFW BLOCK]`. No SYN-ACK. |
| 6443/tcp | Kubernetes API | **Filtered.** | SYNs arrived and were `[UFW BLOCK]`. No SYN-ACK. |
| 8080/tcp | App | **Filtered.** | SYNs arrived and were `[UFW BLOCK]`. No SYN-ACK. |
| 9090/tcp | Prometheus | **Filtered.** | No listener. UFW default deny. |

## Why 80 and 443 can look open from the scanner

A bare `socket.connect()` to `45.32.107.245:80` and `:443` from this
scanner completed in about 0 ms. A real SSH handshake to the same address
took about 200–350 ms. `curl` to those ports then timed out with an empty
body. A packet capture on the VPS NIC during a controlled probe showed no
SYN to 80 or 443 for those connects.

The raw file [tcp-connect-scan.json](tcp-connect-scan.json) records the
scanner's connect() status. For ports 80 and 443 that status is `open`.
That is the intercept, not a listener. Do not quote those two JSON rows
as open services on the node.

## What this scan is not

It is not a scan of a deployed dual-plane edge. Cloudflare Access and
Tailscale were not installed. The repository's `--production` nmap, when
run on the node against `45.32.107.245`, is a self-scan: latency was
0.00044 s and the other ports printed `closed` rather than `filtered`,
because local delivery bypasses UFW. That output is in
[production-report.md](production-report.md). It is not a substitute for
this external scan.
