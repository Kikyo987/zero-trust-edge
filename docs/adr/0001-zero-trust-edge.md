# ADR 0001: Cloudflare Tunnel + Tailscale instead of a VPN or a public load balancer

- **Status:** accepted
- **Date:** 2026-11-16
- **Deciders:** platform / network

## Context

A five-person team needs HTTPS for users and SSH/kubectl for operators.
The usual two answers are:

1. A **public load balancer** (or NodePort / host `:443`) plus security
   group `:22` from “my IP”.
2. A **remote-access VPN** (concentrator on UDP/1194 or UDP/51820) that
   extends RFC1918 to every laptop.

Both put a listener on the internet. The VPN also treats “on the mesh”
as authorization: once the tunnel is up, the database CIDR is a route
away. NAT Gateway / NLB cost shows up on a bill that a founder has to
explain.

Constraints: no public inbound ports on the origin, identity per
actor, cost in the tens of dollars, one engineer can operate it.

## Decision

Split the job.

- **Users** reach the app through **Cloudflare Tunnel** (outbound
  connector) and **Zero Trust Access** (GitHub/Google + MFA) on the
  hostname. DNS is a CNAME to `*.cfargotunnel.com`. There is no A record
  for the node.
- **Operators and CI** reach SSH and the kube API through **Tailscale**,
  with tag-based ACL (`group:ops` / `tag:ci` → `tag:node:22`). `sshd`
  binds to `100.x` only.
- **The database** is not on the VPN. `tag:app → tag:db:5432` is the
  only grant. Laptops do not get `5432`.
- **Terraform** keeps the node security group free of `0.0.0.0/0` TCP.
  Workloads run on **k3s** (ClusterIP Traefik) or Compose bound to
  `127.0.0.1`.

We do not run a customer VPN appliance, an ALB/NLB, or hostNetwork `:443`
in front of the same origin.

## Why not the alternatives

| Option | Rejected because |
| --- | --- |
| Public NLB / ALB / NodePort | Inbound listener; IP in DNS; extra monthly networking bill |
| Allowlist Cloudflare IPv4 on `:443` | Still a public socket; the list drifts; a bind on `:22` is a separate incident |
| Traditional VPN concentrator | Public UDP/TCP port; “in the CIDR” = authorized; split-tunnel is optional and usually off |
| Homegrown WireGuard | PKI and a runbook we would own; Tailscale is WireGuard with coordination and ACL tags |
| Bastion with `:22` from my IP | The IP changes; the port is still in Shodan |

## Consequences

- Origin can have **no public IP**. Egress (IGW SNAT or NAT) is enough.
- A stolen SSH key without a live tailnet membership does not reach `sshd`.
- A user who is not in the Access policy never leaves Cloudflare; origin
  logs stay empty.
- Overlay MTU must be pinned (1500 on the NIC, ICMP dest-unreach allowed).
  See [postmortem-example.md](../postmortem-example.md).
- Cloudflare and Tailscale become production dependencies. That is
  accepted; both have free tiers that fit this size.

Packet path and SG/CIDR detail: [architecture.md](../architecture.md).
Operator runbook: [../cloudflare/tunnel-and-access.md](../../cloudflare/tunnel-and-access.md).
