# Architecture

This document is the packet-level source of truth for the edge. If a change
alters CIDR, MTU, NAT, or who is allowed to initiate a flow, it belongs here
before it belongs in Terraform.

## 1. Design goals

1. **Zero public inbound ports.** No SSH, no HTTP, no HTTPS listener on any
   public address. Users arrive through Cloudflare. Operators arrive through
   Tailscale. CI arrives through Tailscale with a narrower ACL than operators.
2. **Explainable packet path.** Every hop has a CIDR, an MTU, and a security
   control. “The tunnel is down” is a diagnosis, not a mystery.
3. **Cost that a founder can read.** NAT Gateway is opt-in, not default. See
   [finops.md](finops.md).
4. **One engineer can operate it.** Single-node k3s is acceptable for the first
   production. The CIDR and Terraform modules already have a second AZ so HA
   is a scale-up, not a redesign.

## 2. Logical packet path

### User request (HTTPS)

```
client
  │  TLS 1.3, SNI = app.example.com
  ▼
Cloudflare anycast (WAF, Bot Fight, HTTP/2 or HTTP/3)
  │  Access policy (IdP / OTP / mTLS / device posture)
  │  origin = named tunnel UUID, not an IP
  ▼
cloudflared  (connects OUTBOUND to Cloudflare on TCP/443 or QUIC/7844)
  │  connects to the local Ingress on the pod network or 127.0.0.1
  ▼
Traefik Ingress (k3s) / Caddy (compose)
  │  NetworkPolicy: ingress only from the cloudflared pod / compose net
  ▼
edge-echo (non-root, :8080)
```

The origin never presents a public A/AAAA record that points at the node.
DNS for `app.example.com` is a CNAME to `*.cfargotunnel.com`. If someone
scans the node’s public IPv4, they get **no open ports**.

### Operator session (SSH / kubectl / Grafana)

```
operator laptop (tailscaled)
  │  WireGuard UDP, inner MTU 1280
  ▼
Tailscale coordination + DERP (if NAT traversal fails)
  │  ACL: group:ops → tag:node:22, :6443, :3000, :9090
  ▼
node tailscale0 (100.x.y.z)
  │  sshd ListenAddress = 100.x.y.z
  │  kube-apiserver bind = 127.0.0.1 + tailscale0 (not 0.0.0.0)
  ▼
host namespaces / kubectl via local kubeconfig
```

SSH keys still exist. They are a second factor on top of Tailscale identity
and ACL, not the perimeter.

### CI deploy

GitHub Actions joins the tailnet with an OAuth client tagged `tag:ci`.
ACL allows `tag:ci` → `tag:node:22` and the container registry, nothing else.
The runner never receives a long-lived SSH private key for a user in
`group:ops`.

## 3. CIDR plan

| Name | CIDR | Routed? | Notes |
| --- | --- | --- | --- |
| VPC | `10.42.0.0/16` | yes, AWS | Avoids the `10.0.0.0/16` cliché and most office LANs |
| Public AZ-a | `10.42.0.0/24` | IGW | Default route for egress; no inbound SG |
| Public AZ-b | `10.42.1.0/24` | IGW | Spare for a NAT instance later |
| Private AZ-a | `10.42.10.0/24` | local + egress | k3s node ENI lives here when `assign_public_ip = false` |
| Private AZ-b | `10.42.11.0/24` | local + egress | Second node |
| Pod | `10.43.0.0/16` | k3s only | Must not overlap VPC, or kube-proxy hairpin bugs appear |
| Service | `10.44.0.0/16` | k3s only | ClusterIP. Do not advertise to the VPC |
| Tailscale | `100.64.0.0/10` | overlay | CGNAT (RFC 6598). **Never** allocate this in the VPC |
| Cloudflare WARP | `100.96.0.0/12` | overlay | Disjoint from Tailscale; keep it that way |
| Cloudflare Tunnel virtual | `198.18.0.0/15` (when WARP/private net enabled) | overlay | Benchmark range; do not route it in the VPC |

Host addresses on a single-node install:

| Interface | Address | Purpose |
| --- | --- | --- |
| `eth0` (VPC) | `10.42.10.10/24` (private path) or a public Elastic IP (cost path) | Default route |
| `tailscale0` | `100.x.y.z/32` | Operator + CI |
| `lo` | `127.0.0.1` | cloudflared → Ingress, kube-apiserver, node-exporter |
| `cni0` / flannel | `10.43.0.1/16` | Pods |
| kube-ipvs0 / ClusterIP | `10.44.0.0/16` | Services |

`10.42.10.10` is reserved in Terraform (`private_fixed_ip`) so runbooks can
name it. DHCP is fine; a stable address is kinder to humans.

## 4. Security groups and NACLs

Security groups are stateful. NACLs are stateless. We use both, for
different jobs.

### Node security group (`sg-node`)

Ingress: **empty.**

That is not a placeholder. There is no `22`, no `80`, no `443`, no
`41641`. Tailscale and Cloudflare are outbound-initiated. Return traffic
is allowed by SG state, not by an inbound rule.

Egress (explicit, not `-1` to `0.0.0.0/0` in the strict profile):

| Port | Proto | Destination | Why |
| --- | --- | --- | --- |
| 443 | TCP | `0.0.0.0/0` | Cloudflare Tunnel, container registry, GitHub, IdP |
| 53 | UDP/TCP | VPC resolver + `0.0.0.0/0` | DNS. Pin to VPC resolver (`.2`) if you can |
| 123 | UDP | `0.0.0.0/0` | NTP. Chrony will not survive a blocked 123 |
| 41641 | UDP | `0.0.0.0/0` | Tailscale direct path |
| 3478 | UDP | `0.0.0.0/0` | Tailscale STUN |
| 443 | UDP | `0.0.0.0/0` | HTTP/3 + Tailscale DERP-over-HTTPS, Cloudflare QUIC |
| 80 | TCP | `0.0.0.0/0` | ACME HTTP-01 only if you terminate locally (we do not); keep for `apt` mirrors that still redirect |
| ICMP | dest-unreach, time-exceeded | `0.0.0.0/0` | PMTUD |

The default Terraform env ships the **strict egress** list above. A
`egress_unrestricted = true` variable exists for the first four hours of a
bring-up, when you have not yet enumerated apt, GHCR, and DERP. Turn it
off before the client demo.

### NACL on public subnets

Stateless, so ephemeral ports must be allowed inbound for return traffic:

- Inbound: ephemeral `1024-65535` from `0.0.0.0/0`, plus ICMP dest-unreach.
- Inbound: **deny** `22`, `80`, `443`, `3389` from `0.0.0.0/0` at a lower
  rule number so a mistaken SG rule still fails closed.
- Outbound: `80`, `443`, `53`, `123`, `41641`, `3478`, ephemeral.

NACLs are a seatbelt. They are not a substitute for the empty SG.

## 5. NAT behaviour

Three valid egress designs. Pick one; do not mix them on the same node.

### A. Public IP, deny-all ingress (default, cheapest)

The ENI has a public IPv4. The route table of the subnet points at the
IGW. The SG has no inbound rules. Outbound SYN packets are rewritten with
the public IP by the IGW; return packets match SG state and are accepted.

This is **source NAT at the IGW**, not a NAT Gateway. There is no
per-GB NAT charge. The node is still not reachable inbound.

Caveat: the public IP appears in Cloudflare and registry logs as the
origin. That is fine. Do not put that IP in DNS.

### B. Private IP + NAT Gateway (strictest, most expensive)

Subnet route `0.0.0.0/0 → nat-…`. The node has no public IP. You pay
hourly + per-GB. Use this when a customer’s policy forbids public
addresses on compute, even with empty SGs.

### C. Private IP + NAT instance (middle)

A small `t4g.nano` in `10.42.0.0/24` with `net.ipv4.ip_forward=1` and
`MASQUERADE`. Source/dest check disabled. One-tenth the cost of a NAT
Gateway, and you own the failure domain. Documented in Terraform comments;
not applied by default because it is another box to patch.

VPC endpoints for S3 and ECR are always created. Image pulls should not
traverse NAT.

## 6. MTU and MSS

| Segment | MTU | MSS (IPv4 TCP) |
| --- | --- | --- |
| VPC path (we pin) | 1500 | 1460 |
| Internet to Cloudflare | 1500 typical | 1460 |
| Cloudflare Tunnel over HTTP/2 | inner ~1420 | clamp 1380 |
| Cloudflare Tunnel over QUIC | inner ~1280–1350 | clamp 1240 |
| Tailscale WireGuard | 1280 default | 1240 |
| k3s flannel VXLAN (if used) | 1450 | 1410 |

k3s in this repo is installed with `--flannel-backend=wireguard-native`
when the host has kernel WireGuard, otherwise `vxlan`. Either way we set:

```
--kube-proxy-arg=iptables-min-sync-period=1s
# and on the node:
ip link set eth0 mtu 1500
```

**Never enable jumbo frames (9001) on a node that also runs an overlay.**
The first 1500-byte inner packet that cannot fragment (DF bit is set on
almost all TCP) will black-hole. That incident is written up in
[postmortem-example.md](postmortem-example.md).

`scripts/mtu-path-check.sh` sends ICMP with DF set at 1280, 1400, 1472,
1500 and reports the first failure. Run it from the node toward
`1.1.1.1` and from a laptop toward the Tailscale IP.

## 7. k3s networking

```
k3s install flags we care about:

  --disable=traefik          # we re-apply a pinned Traefik with our values
                             # (actually we KEEP traefik and pin via HelmChartConfig)
  --flannel-backend=wireguard-native
  --cluster-cidr=10.43.0.0/16
  --service-cidr=10.44.0.0/16
  --tls-san=${TAILSCALE_IP}
  --tls-san=127.0.0.1
  --advertise-address=${TAILSCALE_IP}
  --kube-apiserver-arg=bind-address=0.0.0.0
        # bind all, but SG + host firewall drop non-tailscale
  --disable=servicelb          # no LoadBalancer that would want a public IP
  --disable=metrics-server     # optional; we scrape with Prometheus
```

Ingress:

- Traefik listens on `127.0.0.1:80` and `127.0.0.1:443` (hostNetwork or a
  hostPort bound to loopback via `spec.template.spec.hostNetwork` +
  firewall). cloudflared `ingress` points at `https://127.0.0.1:443` or
  the in-cluster Service DNS.
- We prefer in-cluster Service DNS (`http://edge-echo.edge.svc:8080`) so
  the tunnel sidecar and the app can be scheduled independently.

NetworkPolicy (namespace `edge`): default-deny ingress and egress, then:

- allow ingress to `app=edge-echo` from `app=cloudflared`
- allow egress from `app=cloudflared` to `443/tcp` and DNS
- allow egress from `app=edge-echo` to in-namespace + DNS (no arbitrary
  internet unless the app needs it)

## 8. Identity

| Actor | Proves identity with | Authorized by |
| --- | --- | --- |
| End user | Cloudflare Access (Google / GitHub / OTP) | Access policy on the hostname |
| Operator | Tailscale node + GitHub / Google on the tailnet | `group:ops` in `tailscale/acl.hujson` |
| CI | Tailscale OAuth client | `tag:ci` |
| Node | Tailscale auth key (ephemeral, tagged `tag:node`) | ACL destination |
| Terraform | GitHub OIDC → AWS IAM role | `sts:AssumeRoleWithWebIdentity` |

There is no bastion. A bastion is a public listener with extra steps.

## 9. Failure domains

| Failure | User impact | Operator impact | Recovery |
| --- | --- | --- | --- |
| Cloudflare regional outage | Users in that region fail over with anycast | none | wait / status.cloudflare.com |
| cloudflared process down | Users 1033 / 502 | Tailscale still works | systemd restart, k3s reschedule |
| Tailscale coordination down | none (users on CF) | DERP fallback, slower SSH | wait; SSH will limp on DERP |
| Node kernel panic | everything | everything | cloud-init + k3s install is idempotent; RPO = PVC / sqlite snapshots |
| NAT Gateway (if used) | image pulls fail, tunnel may still run until conn dies | same | this is why we default off NAT GW |
| Wrong MTU | POST bodies hang, GET works | SSH works, `scp` of large files hangs | `scripts/mtu-path-check.sh` |

Single-node k3s is a **deliberate** RPO/RTO choice for teams under 20
people. etcd/sqlite lives on an encrypted gp3 volume with daily snapshots
(`scripts` + AWS DLM in Terraform). Adding a second node is a CIDR and
install-flag change, not a new architecture.

## 10. What we explicitly do not run

- Public Network Load Balancer in front of k3s
- MetalLB announcing a public IP
- `hostPort: 443` on `0.0.0.0`
- WireGuard “homegrown” in addition to Tailscale (one overlay)
- Calico + flannel at the same time
- IPv6 dual-stack until the Cloudflare and Tailscale v6 paths are measured
  (v6 is on the roadmap; silent dual-stack is how you leak an AAAA)

## 11. Related docs

- [finops.md](finops.md) — cost of each NAT choice
- [postmortem-example.md](postmortem-example.md) — MTU black hole
- [../cloudflare/tunnel-and-access.md](../cloudflare/tunnel-and-access.md)
- [../tailscale/acl.hujson](../tailscale/acl.hujson)
