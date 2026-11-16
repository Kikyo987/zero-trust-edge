# Before and after: a small-team Zero Trust edge

This is a short case write-up, not a customer war story. It compares the
default shape of a small production with the design in this repository,
states what was actually measured, and walks through one overlay problem
(an MTU black hole) that the lab can reproduce.

Numbers in the cost table are the model in [finops.md](finops.md)
(AWS `us-east-1` list prices, 2026, rounded). They are not a bill from
this lab. The temporary VPS used for the port scan did not run
Cloudflare, Tailscale, or k3s. Do not read the "after" column as a
claim about that machine.

## Before: the default small-production edge

A common one-node rollout still looks like this:

| Surface | What is exposed | Why it shows up |
| --- | --- | --- |
| Public `:22` | SSH on the origin IP, often brute-forced around the clock | It is the way in before anyone sets up a mesh or SSM |
| Public `:443` on the origin | The origin IP is in DNS, or is discoverable behind a proxy | A load balancer or a direct A record points at the node |
| A load balancer in front of a single node | Another public listener, plus the cost of the LB | "We might scale later" |
| Optional NAT Gateway on AWS | About a 3× multiplier on a small account (~$32/mo hourly, plus data) | A private subnet was requested, even though an empty security group already drops unsolicited inbound |

The attack surface is the public listeners and the origin IP itself. A
network path becomes a credential: anyone who can reach `:22` or `:443`
gets to try.

## After: the design in this repository

Users never reach the origin IP. Operators do not share that path.

| Plane | Path | What is no longer on the path |
| --- | --- | --- |
| Users | Cloudflare Access → named tunnel (dialing out) → `cloudflared` → Kubernetes Service / Compose DNS → `edge-echo` | Public `:443` on the node, Tailscale, an A/AAAA record for the origin |
| Operators and CI | Tailscale ACL to `100.x` (`:22` for CI; ops also get kubectl and Grafana) | The tunnel, and a public SSH listener on a finished node |

DNS for the product hostname is a CNAME to `*.cfargotunnel.com`. The
node security group (or UFW) stays deny-all on the public address. The
tunnel and the mesh replace the public load balancer and, on the AWS
path, the NAT Gateway.

### Monthly cost model

| Path | Monthly floor | What you stop paying for |
| --- | --- | --- |
| One VPS (Hetzner / DigitalOcean / Lightsail) | **~$8–20** | A public load balancer in front of one node |
| AWS, this repo's default (no NAT Gateway) | **~$18–28** | NAT Gateway (~$32/mo hourly plus data) and a public LB |
| Same AWS VPC, NAT Gateway added "because private subnet" | **~$60** | — |

The NAT Gateway buys "no public IP on the ENI." It does not buy a closed
inbound posture; the empty security group already did that. Quote the
source before a contract: [finops.md](finops.md).

## What was actually verified

### Local Compose and lab harness

On a local clone, with nothing published on `0.0.0.0`:

- `make dev-up` binds service ports to `127.0.0.1`
- `./scripts/zero-trust-verify.sh --compose` checks that publish address, `/healthz`, and the non-root UID
- Grafana is provisioned with **Edge overview** (`uid: edge-overview`) on `http://127.0.0.1:3000`
- `sudo ./security-tests/run.sh --lab` is the isolation report (Access-style 403, Tailscale-style SSH/Grafana grants, NetworkPolicy). It is a netns/iptables stand-in, not a live Cloudflare or Tailscale tenant
- `sudo ./security-tests/lab/mtu-blackhole.sh` is the MTU reproduction below

Commands: [demo.md](demo.md), [Local reproduction](../README.md#local-reproduction).

### Temporary VPS, 16 Nov 2026

A different host scanned a short-lived Vultr machine at `45.32.107.245`.
UFW allowed only SSH. Cloudflare, Tailscale, and k3s were **not**
installed. The owner was going to shut the machine down after the test.
This is an honest public-address scan, not a finished dual-plane node.

| Port | On that VPS |
| --- | --- |
| 22/tcp | **Open.** SSH was the only way in. A finished node binds sshd to `100.x` and does not leave 22 on the public address. |
| 80/tcp, 443/tcp | **Not open on the VPS.** A scanner intercept can make `connect()` look instant. No SYN for those ports arrived, and nothing was listening. |
| 3000, 6443, 8080, 9090 | **Filtered** by UFW. |

The `--production` script on that box is not a pass for Cloudflare,
Tailscale, or kube-router. Those checks were SKIP. Detail:
[evidence/lab-vps/README.md](evidence/lab-vps/README.md).

## Problem and fix: the MTU black hole

Overlays own the MTU. With a 1280-byte hop and ICMP fragmentation-needed
dropped, a small GET still returns 200 and an 8 KB POST stalls. Restoring
that ICMP message makes the same POST return `ready`.

That is the class of incident a tunnel or a mesh can hide: the
control-plane health check stays green, and a slightly larger request
never completes.

```bash
sudo ./security-tests/lab/mtu-blackhole.sh
```

The narrative timestamps in [postmortem-example.md](postmortem-example.md)
are invented. The lab commands are not. The script also passed on the
temporary VPS; the packet capture checked into
[evidence/mtu-lab/](evidence/mtu-lab/) is from a different lab machine,
not from that VPS.

## What this case does not claim

- A standing public app URL, or a live Cloudflare Access login
- That `45.32.107.245` was a finished Zero Trust edge
- That port 22 was closed on that VPS
- A measured cloud bill; use the FinOps model and re-quote
