# Temporary lab VPS — 45.32.107.245

This directory is the record of one short-lived Vultr machine the owner
provided so the external-scan item in the review could be run for real.
The owner said the machine would be shut down after testing. It is not a
production edge, and it is not still a service anyone should depend on.

| Fact | Value |
| --- | --- |
| Address | `45.32.107.245` |
| When | 16 Nov 2026, about 07:21–07:31 UTC (15:21–15:31 Asia/Singapore) |
| OS | Ubuntu 26.10, kernel `7.3.0-10-generic`, about 1 GiB RAM |
| Repo commit on the box | `7ef8a2f` |
| Installed for the test | the repo, UFW, nmap, python3-yaml |
| Not installed | Cloudflare Access, Tailscale, cloudflared, Docker, k3s |

UFW allowed only `22/tcp` inbound. SSH was the only way onto the box, so
port 22 stayed open on purpose for this test. A finished dual-plane node
binds sshd to `100.x` and does not leave 22 on the public address.

## What an outside scanner saw

The scanner was a different host. It used a Python TCP connect, not nmap.
Full reading: [external-scan.md](external-scan.md). Raw connect results:
[tcp-connect-scan.json](tcp-connect-scan.json).

| Port | On this VPS |
| --- | --- |
| 22/tcp | **Open.** Banner `SSH-2.0-OpenSSH_10.5p1 Ubuntu-1ubuntu3.1`. Expected here. Not the finished design. |
| 80/tcp | **Not open on the VPS.** The scanner's `connect()` returned in about 0 ms because that scanner intercepts outbound 80/443. No SYN for port 80 arrived on the VPS NIC. Nothing was listening. UFW does not allow 80. |
| 443/tcp | **Not open on the VPS.** Same intercept as port 80. Nothing listening. UFW does not allow 443. |
| 3000/tcp | **Filtered.** SYN arrived and was `[UFW BLOCK]`. No SYN-ACK. |
| 6443/tcp | **Filtered.** Same UFW block. |
| 8080/tcp | **Filtered.** Same UFW block. |
| 9090/tcp | **Filtered.** No listener. UFW default deny. |

Do not read `status: open` for ports 80 and 443 in `tcp-connect-scan.json`
as listeners on the node. That file is the scanner's connect() result.
The VPS-side capture and the host configuration are the evidence those
two ports were not open.

## What the scripts printed on the VPS

| Run | Result | File |
| --- | --- | --- |
| `./security-tests/run.sh --lab` | **FAIL** (6 pass, 1 fail). Privilege-escalation control did not become root because `/tmp` is `nosuid`. | [lab-report.md](lab-report.md), [tmp-mount.txt](tmp-mount.txt) |
| `ZTE_NODE_PUBLIC_IP=45.32.107.245 ./security-tests/run.sh --production` | **FAIL** (0 pass, 1 fail, 6 skip). The scan ran on the node against its own address (0.00044 s). That bypasses UFW, so other ports look `closed` instead of `filtered`. | [production-report.md](production-report.md), [production-rerun.txt](production-rerun.txt) |

The first production attempt used `sudo -E`. This Ubuntu ignored `-E` and
dropped every `ZTE_*` variable, so that attempt is not evidence. The file
above is the rerun as root, with only the public IP set.

SKIP on that rerun is not a pass:

- No `ZTE_APP_URL` — Cloudflare Access was not configured.
- No `ZTE_USER_SSH_TARGET`, `ZTE_CI_SSH_TARGET`, or `ZTE_CI_GRAFANA_URL` — Tailscale was not installed.
- No kubeconfig — k3s was not installed. Do not claim kube-router passed.

The lab Pod check enforced the NetworkPolicy manifest with iptables in a
namespace. This kernel does have `ipset` and `vxlan` modules. The sentence
in `lab-report.md` that says those modules were unavailable was canned text
from an earlier machine. It was not a measurement of this VPS.

The MTU lab on this VPS exited 0 (`GET` ok, 8 KB POST stalled without ICMP
fragmentation-needed, POST recovered after restore). The packet capture
checked into `docs/evidence/mtu-lab/` is from the cloud-agent lab, not from
this VPS. This directory does not invent a second capture.

## What changed in the harness after this run

- The setuid helper is not built on `/tmp` when that mount is `nosuid`.
- `sudo -E` is not used. Variables are passed with `sudo env`, and production mode refuses to continue if they vanish.
- A scan of an address that belongs to the scanner host is refused, instead of being reported as an external result.
- The lab report measures whether `ip_set` and `vxlan` exist on the kernel it is running on.
