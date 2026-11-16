# FinOps for a zero-trust edge

Small teams do not fail because they picked the wrong instance family.
They fail because **networking defaults are priced for enterprises**.

This note is the cost model I walk a founder through before the first
`terraform apply`. Numbers are AWS `us-east-1` list prices, 2026, rounded
so they are useful in a conversation. Always re-quote before a contract.

## 1. Monthly floor (what “cheap and locked down” actually costs)

### Path A — one VPS (Hetzner CX22 / DO 2GB / Lightsail $5–12)

| Item | Monthly |
| --- | --- |
| 2 vCPU / 4 GB / 40 GB | $6–12 |
| IPv4 address | often included; +$2 if not |
| Cloudflare Tunnel + Access (Free / Zero Trust Free) | $0 |
| Tailscale (Personal / starter) | $0–6 |
| GitHub Actions (private, light CI) | $0 |
| **Total** | **~$8–20** |

This is the default I recommend for a five-person startup with one
product and one region.

### Path B — AWS, this repository’s default (no NAT Gateway)

| Item | Monthly | Notes |
| --- | --- | --- |
| `t4g.small` (2 vCPU, 2 GB, ARM) | ~$12 | or `t3.small` if you must be amd64 |
| 20 GB gp3 encrypted | ~$2 | |
| Public IPv4 (Elastic IP, associated) | ~$3.6 | AWS charged for public IPv4 since 2024 |
| NAT Gateway | **$0** | we do not create it |
| VPC endpoints (S3 gateway + ECR interface) | S3 gateway **$0**; ECR interface ~$7/AZ | S3 gateway is free; skip ECR interface on a single node and pull via GHCR over IGW |
| Cloudflare + Tailscale | $0–6 | |
| CloudWatch (flow logs → S3, light) | <$1 | |
| **Total** | **~$18–28** | |

### Path B′ — same VPC, NAT Gateway “because private subnet”

| Item | Monthly |
| --- | --- |
| Everything in Path B | ~$22 |
| NAT Gateway hourly | ~$32 |
| NAT Gateway data (50 GB mixed) | ~$4.50 |
| **Total** | **~$60** |

The NAT Gateway is a **3× multiplier** on a small account. It buys you
“no public IP on the ENI.” It does not buy you a closed inbound posture
— the empty security group already did that.

I do not enable NAT Gateway unless a written policy forbids public
addresses on compute.

## 2. Decision tree

```
Need a private ENI with no public IP?
  ├─ yes, auditor said so ──► NAT Gateway (or NAT instance, see §3)
  └─ no
       ├─ traffic < 1 TB/mo ──► public IP + deny-all SG   ◄── default
       └─ traffic > 1 TB/mo ──► still public IP; watch
                                 Cloudflare cache + GHCR pull-through
```

A public IPv4 with an empty inbound SG is **not** a listener. Unsolicited
SYN packets hit the hypervisor, fail the SG, and never reach the kernel.
That is the same inbound posture as a private subnet, with a cheaper
default route.

The honest caveat: the IP is still a **stable identifier** in someone
else’s logs, and it costs ~$3.6/mo. If a customer wants “no public
address at all,” we switch to Path B′ and put the $32 on the quote.

## 3. NAT instance vs NAT Gateway

| | NAT Gateway | NAT instance (`t4g.nano`) |
| --- | --- | --- |
| Hourly | ~$0.045 | ~$0.004 |
| Data | ~$0.045/GB | instance bandwidth (usually $0 extra inside AZ) |
| HA | managed, AZ-scoped | you + a script + maybe a second nano |
| Throughput | 5–100 Gbps | host NIC, ~up to 5 Gbps burstable |
| Patching | none | yes (this is the real cost) |
| Source/dest check | N/A | **must be disabled** |
| Conntrack | managed | `nf_conntrack` on a 512 MB box will melt at ~50k flows |

For a single-node k3s with a tunnel, peak flows are hundreds, not
hundreds of thousands. A NAT instance is technically enough. I still
default to **public IP + empty SG** because it is one fewer box to page
on.

If we do run a NAT instance:

- pin it in `10.42.0.0/24`
- disable source/dest check
- `sysctl net.ipv4.ip_forward=1`
- iptables `MASQUERADE` on `eth0`
- security group: inbound from `10.42.10.0/24` only, outbound as node
- monitor `nf_conntrack_count` vs `nf_conntrack_max` in Prometheus

## 4. Data path costs people forget

| Path | Who bills | How to avoid |
| --- | --- | --- |
| Image pull from ECR in another AZ / public | NAT GW data + ECR | GHCR or ECR in-region + S3/ECR gateway endpoint |
| Prometheus remote-write to Grafana Cloud | egress GB | keep Prometheus local; 15-day retention on gp3 is enough for this size |
| Cloudflare Tunnel | Cloudflare (free tier is generous) | do not also put an ALB in front |
| Tailscale DERP relay | Tailscale (free) + a bit of CPU | open UDP/41641 egress so peers go direct |
| Flow logs to CloudWatch Logs | **expensive** | send flow logs to S3 (Parquet) or skip until you have an incident |
| gp3 snapshots, daily, 7 retained | ~20 GB × 7 × $0.05 | ~$0.50 — keep them |
| IPv4 Elastic IP **unassociated** | same as associated, wasted | release it in `terraform destroy` |

## 5. Instance choice

| Need | Type | Why |
| --- | --- | --- |
| Default node | `t4g.small` | ARM, 2 GB is tight but works for k3s + Loki with retention limits |
| Comfortable node | `t4g.medium` | 4 GB; this is where Grafana + Loki stop fighting k3s |
| NAT instance | `t4g.nano` | forwarding only |
| “I must run amd64 images” | `t3.small` | do not cross-compile in production as a surprise |

k3s + Prometheus + Grafana + Loki + cloudflared + tailscaled on 2 GB
works if Loki retention is 3–7 days and Prometheus is 7–15 days. The
compose file and Helm values pin those.

Spot/preemptible is a poor fit for a single-node control plane. Save
spot for workers, once there are workers.

## 6. Idle-resource hunt (`scripts/cost-snapshot.sh`)

The script flags:

- Elastic IPs not associated
- gp3 volumes `available` (detached)
- NAT Gateways in this VPC
- Interface VPC endpoints in empty AZs
- Security groups with `0.0.0.0/0` inbound (this is a **security** finding
  that also usually means an unused ALB)
- Load balancers with zero targets
- CloudWatch Logs groups with `Never expire` and no subscription

Run it from CI weekly (`workflow_dispatch` + cron in the deploy file is
enough) and paste the output into the client’s Slack.

## 7. Cloudflare and Tailscale paid tiers

Stay on the free tiers until one of these is true:

- more than 50 Access seats
- you need Access per-app device posture that the free plan does not have
- Tailscale needs more than the free node count, or ACL GitOps with
  multiple admins and SSO enforced by contract

Do not buy Magic WAN, a Cloudflare Load Balancer, or Tailscale
subnet-router HA to impress a five-person team. The empty SG is the
feature.

## 8. Quote template I send

```
Zero-trust edge, single region
  compute + disk + IPv4 .............. $XX
  Cloudflare Tunnel + Access ......... $0 (free tier)
  Tailscale mesh + ACL ............... $0–6
  observability (self-hosted) ........ included in compute
  NAT Gateway ........................ $0 (not provisioned)
  estimated data egress .............. $Y  (usually ~$1–5)
  -------------------------------------------
  monthly run  ....................... $XX–YY
  one-time build (this design) ....... quoted separately
```

If the customer later requires private-only ENIs, the quote grows by
one NAT Gateway (or a NAT instance plus patching hours). That sentence
lives in the SOW so nobody is surprised.

## 9. What we measure after go-live

- AWS Cost Explorer, tag `Project=edge-zero`, daily
- Node disk (`/var/lib/rancher/k3s`, Loki chunks)
- Tunnel bytes (`cloudflared` metrics)
- NAT GW `BytesOutToDestination` — should not exist
- Public IPv4 count = 1 (or 0, if Path B′)
