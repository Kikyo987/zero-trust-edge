# Security policy

## Reporting

Please **do not** open a public issue for a vulnerability in this reference stack
or in a deployment derived from it. Email the address on the GitHub profile, or
use GitHub Security Advisories on this repository.

I aim to acknowledge within two business days.

## What this repo will never contain

- Long-lived cloud access keys
- Cloudflare tunnel credentials (`*.json` from `cloudflared tunnel create`)
- Tailscale auth keys (use OAuth clients + tags, and expire them)
- Grafana / DB passwords
- Private keys of any kind

If you find one in git history, treat it as compromised: rotate, then `git
filter-repo` or BFG. Rotating is mandatory even if the repo is private.

## Baseline I hold deployments to

1. **No public inbound.** Security groups and host firewalls have empty ingress
   except (optionally) ICMP echo for PMTUD from the VPC itself. SSH, HTTP, and
   HTTPS are not reachable from `0.0.0.0/0`.
2. **Identity at the edge.** Human users pass Cloudflare Access. Operators pass
   Tailscale ACL tags. CI passes `tag:ci`. There is no shared SSH user.
3. **Least privilege on the wire.** Egress is allow-listed where the platform
   allows it (DNS, NTP, HTTPS, Tailscale STUN/DERP, Cloudflare).
4. **Workloads are not root.** Distroless, UID 65532, read-only root filesystem,
   dropped capabilities, no `NET_RAW` (so no in-pod spoofing / ping abuse).
5. **Secrets in the right store.** GitHub Environments, Cloudflare, Tailscale
   OAuth, AWS SSM/Secrets Manager — never Compose files committed with values.
6. **State is remote and locked.** Terraform state lives in encrypted S3 with
   DynamoDB locking and public access blocked.
7. **Supply chain.** Images are pinned by digest in production, scanned with
   Trivy in CI, and pulled over TLS. k3s install runs with a pinned version.

## Network-specific notes

- Do not reuse `100.64.0.0/10` (Tailscale CGNAT) or `100.96.0.0/12` (WARP) as
  VPC CIDRs. Overlap makes ACLs lie.
- Do not disable ICMP entirely. Path MTU discovery needs it; the 2024-style
  “drop all ICMP” hardening causes tunnel black holes. Allow established +
  destination-unreachable.
- Pin VPC MTU to 1500 unless every overlay has been measured. Jumbo frames
  plus WireGuard plus Cloudflare QUIC is how 1500-byte POSTs start hanging.
- IMDSv2 is required (`http_tokens = required`). The old IMDS hop limit of 1
  is not enough once a container runtime is in the path; we set hop limit 2
  and still require tokens.

## Rotating the tunnel

See `cloudflare/tunnel-and-access.md`. Token rotation does not require a DNS
change; the named tunnel UUID stays, the token does not.
