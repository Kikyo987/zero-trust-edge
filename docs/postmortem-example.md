# Postmortem: Cloudflare Tunnel MTU black hole (intermittent 1500-byte POST hang)

**Status:** published as a worked example  
**Severity:** SEV-2 (customers could log in, could not save)  
**Duration:** 47 minutes user-visible; 14 minutes from page to fix  
**Date:** 2026-03-12  
**Author:** on-call network / platform

This is a real failure mode, written the way I would send it to a
founder. The timestamps are illustrative. The packet behaviour is not.

## 1. Summary

Users could load the app (GET) but POST bodies larger than ~1400 bytes
hung until the browser timed out. Cloudflare showed `HTTP 524` on some
requests and `200` on others. SSH over Tailscale worked. `curl` of a
small payload from the laptop through the tunnel worked.

**Root cause:** the k3s node had been given an MTU of **9001** (AWS
instance default when the VPC is set to jumbo) while Cloudflare Tunnel
was encapsulating inner TCP in QUIC. Inner packets with DF set and size
> ~1280 never fit. Small GETs survived. POSTs of JSON blobs did not.
Path MTU discovery failed because a well-meaning “drop all ICMP”
NACL rule had been added the week before.

## 2. Impact

- ~18% of authenticated sessions failed on save, 16:02–16:49 UTC
- No data loss: failed POSTs did not commit
- Operators were not locked out (Tailscale MTU 1280, coincidentally safe)
- Status page updated at 16:18

## 3. Timeline (UTC)

| Time | Event |
| --- | --- |
| 15:40 | VPC MTU changed to 9001 in a “throughput” ticket, Terraform applied |
| 15:41 | Nodes DHCP-renewed, `eth0` MTU 9001. No restart of cloudflared. |
| 16:02 | First customer report: “Save spins forever.” |
| 16:07 | Page: on-call sees 524s in Cloudflare analytics, origin looks up |
| 16:09 | `curl` GET `/healthz` through the tunnel: 200 in 40 ms |
| 16:11 | `curl` POST 200 bytes: 200. POST 8 KB: hang, then 524 |
| 16:14 | Hypothesis: MTU / MSS. `ping -M do -s 1472 1.1.1.1` from node: 100% loss. `-s 1200`: ok |
| 16:16 | NACL inbound ICMP dest-unreach is **deny**. PMTUD cannot complete |
| 16:18 | Public status: “degraded, writes failing, investigating MTU” |
| 16:22 | Hotfix: `ip link set eth0 mtu 1500` on the node. POSTs recover |
| 16:28 | NACL: allow ICMP dest-unreach / time-exceeded |
| 16:35 | Terraform: pin `aws_vpc.mtu = 1500`, revert jumbo |
| 16:49 | 15 minutes of clean dashboards, status = resolved |
| 17:30 | Follow-up: `scripts/mtu-path-check.sh` in CI against the tunnel hostname |

## 4. Root cause

Three changes had to line up. Any two would have been a near miss.

1. **VPC jumbo frames (9001).** AWS will happily set this. Overlays
   (WireGuard, QUIC, VXLAN) do not.
2. **Cloudflare Tunnel on QUIC.** Outer UDP packet has its own headers.
   Inner TCP MSS was never clamped to the tunnel path.
3. **ICMP dest-unreach dropped at the NACL.** PMTUD is how TCP learns to
   shrink. Without it, the first DF packet that does not fit is a black
   hole. The connection sits in retransmission until the proxy gives up
   (Cloudflare 524 = origin timeout).

GET requests with tiny bodies never left the safe inner size. That is
why `/healthz` was green the entire incident.

## 5. Why Tailscale still worked

Tailscale forces an inner MTU of 1280 and clamps MSS. SSH is also
interactive and small. The operator path was the wrong canary for this
failure. The right canary is **an 8 KB POST through the user path**.

## 6. Detection gaps

- Prometheus had `probe_http_status_code` on `/healthz` only.
- Cloudflare analytics had 524s, but we were not paging on
  `cloudflare_requests{status="524"}`.
- No synthetic POST.
- No MTU black-hole alert (`ping -M do -s 1472` from the node).

## 7. What we changed

| Item | Change |
| --- | --- |
| VPC | `mtu = 1500` pinned in `terraform/modules/vpc`. Jumbo is a variable defaulting to **false**. |
| NACL | ICMP dest-unreach and time-exceeded allowed. Comment in HCL explains PMTUD. |
| cloudflared | `warp-routing` off; `protocol: http2` available as a fallback if QUIC misbehaves (`cloudflare/config.yml`) |
| Synthetics | blackbox exporter: GET `/healthz` **and** POST `/readyz` with 8 KB |
| Script | `scripts/mtu-path-check.sh` — fail CI / cron if 1472 DF does not pass to `1.1.1.1` |
| Runbook | “GET works, POST hangs” maps to MTU before it maps to the app |
| Alert | `CloudflareOriginTimeouts` and `PMTUDBroken` in `monitoring/prometheus/alerts.yml` |

## 8. What we will not do

- Re-enable jumbo “for performance” on any node that speaks an overlay.
- Drop all ICMP as a hardening fashion. ICMP echo from the internet can
  stay denied; dest-unreach cannot.
- Add an ALB “to absorb MTU problems.” An ALB would have cost more than
  the incident and would still have needed a correct MTU.

## 9. Lessons

1. **Overlays own the MTU.** The physical NIC is not the path.
2. **Health checks must use the same size and verb as customers.**
3. **ICMP is part of TCP.** Filtering it is a functional change, not just
   a security change.
4. **Cheap canaries lie.** Tailscale and `/healthz` were both up.

## 10. Appendix: commands that diagnosed it

```bash
# from the node
ip link show eth0
# mtu 9001   ← wrong

ping -M do -s 1472 -c 3 1.1.1.1     # fail
ping -M do -s 1200 -c 3 1.1.1.1     # ok

# inner path through the tunnel, from a laptop
curl -o /dev/null -sS -w '%{http_code} %{time_total}\n' \
  https://app.example.com/healthz

dd if=/dev/zero bs=8192 count=1 | \
  curl -o /dev/null -sS -w '%{http_code} %{time_total}\n' \
  -X POST --data-binary @- https://app.example.com/readyz
```

The 8 KB POST is now the synthetic in Prometheus. It would have paged
at 15:41, not 16:02.
