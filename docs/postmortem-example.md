# Blameless postmortem: Cloudflare Tunnel MTU black hole

**Status:** published (worked example)  
**Severity:** SEV-2  
**Customer impact window:** 47 minutes (16:02–16:49 UTC)  
**Time to mitigation:** 14 minutes from page  
**Date:** 2026-03-12  
**Author:** on-call network / platform  
**Reviewers:** none required for this example  

This is the template I send a founder. The timestamps are
illustrative. The packet behaviour is not. Fill every heading; leave
none as “n/a” without a sentence.

Blameless means we describe what the *system* allowed, not who to
blame. Names appear in the timeline as roles (on-call, change owner),
not as the cause.

---

## 1. Summary

Users could load the app (GET) but POST bodies larger than ~1400 bytes
hung until the browser timed out. Cloudflare showed `HTTP 524` on some
requests and `200` on others. SSH over Tailscale worked. A small `curl`
through the tunnel worked.

**Impact in one line:** writes failed for ~18% of authenticated
sessions; no data loss; operators were not locked out.

---

## 2. Customer impact

| Item | Value |
| --- | --- |
| Who | Authenticated users saving a form (POST ≥ ~1.4 KB) |
| What they saw | Spinner, then a Cloudflare 524 or a browser timeout |
| Start | 16:02 UTC |
| End | 16:49 UTC (15 minutes of clean dashboards after the hotfix) |
| Data loss | None — failed POSTs did not commit |
| Workaround | None for users. Operators could still SSH over Tailscale |
| Status page | Updated 16:18 UTC |

---

## 3. Timeline (UTC)

Times are when the event was *observed*, not when we wished it had
been. Gaps are called out in §6.

| Time | Event |
| --- | --- |
| 15:40 | Change owner applies Terraform raising VPC MTU to 9001 (“throughput”) |
| 15:41 | Nodes DHCP-renew. `eth0` MTU 9001. cloudflared is not restarted |
| 16:02 | First customer report: “Save spins forever” |
| 16:07 | Page. On-call sees 524s in Cloudflare analytics; origin looks up |
| 16:09 | `curl` GET `/healthz` through the tunnel: 200 in 40 ms |
| 16:11 | POST 200 bytes: 200. POST 8 KB: hang, then 524 |
| 16:14 | Hypothesis: MTU. `ping -M do -s 1472 1.1.1.1` from node: 100% loss. `-s 1200`: ok |
| 16:16 | NACL inbound ICMP dest-unreach is **deny**. PMTUD cannot complete |
| 16:18 | Status page: degraded, writes failing, investigating MTU |
| 16:22 | Hotfix: `ip link set eth0 mtu 1500`. POSTs recover |
| 16:28 | NACL: allow ICMP dest-unreach / time-exceeded |
| 16:35 | Terraform: pin `aws_vpc` path to MTU 1500, jumbo variable stays false |
| 16:49 | 15 minutes clean. Status = resolved |
| 17:30 | Follow-up: `scripts/mtu-path-check.sh` and an 8 KB POST synthetic |

---

## 4. Root cause

Three changes had to line up. Any two would have been a near miss.

1. **VPC jumbo frames (9001).** AWS will set this. Overlays (WireGuard,
   QUIC, VXLAN) do not carry a 9001-byte inner packet.
2. **Cloudflare Tunnel on QUIC.** Outer UDP has its own headers. Inner
   TCP MSS was never clamped to the tunnel path.
3. **ICMP dest-unreach dropped at the NACL.** Path MTU discovery is how
   TCP learns to shrink. Without it, the first DF packet that does not
   fit is a black hole. Cloudflare 524 = origin timeout.

GET requests with tiny bodies never left the safe inner size.
`/healthz` was green the entire incident.

**Five whys (short):**

1. Why did POSTs hang? TCP retransmits of a DF packet that did not fit.
2. Why did it not fit? Inner size > tunnel MTU, host MTU 9001.
3. Why 9001? A “throughput” change enabled jumbo on a node that speaks
   overlays.
4. Why did PMTUD not shrink MSS? ICMP type 3 denied on the NACL.
5. Why did we not page at 15:41? Synthetics were GET `/healthz` only.

---

## 5. Why Tailscale still worked

Tailscale forces an inner MTU of 1280 and clamps MSS. SSH is small.
The operator path was the wrong canary. The right canary is an **8 KB
POST through the user path**.

---

## 6. Detection and response gaps

- Prometheus probed `/healthz` only.
- Cloudflare 524s existed but we were not paging on them.
- No synthetic POST.
- No MTU black-hole alert (`ping -M do -s 1472` from the node).
- The jumbo change had no overlay checklist in the PR template.

What went well:

- On-call reached for MTU within seven minutes of the page.
- Tailscale gave a working operator path while the user path was dark.
- The hotfix (`ip link set mtu 1500`) was reversible and immediate.

---

## 7. Action items

Every row has an owner, a due date, and a done-when. Open items stay
on this page until they are done or explicitly dropped.

| # | Action | Owner | Due | Done when |
| --- | --- | --- | --- | --- |
| 1 | Pin VPC / ENI MTU at 1500 in Terraform; `jumbo_frames` validates false | platform | 2026-03-13 | merged, plan shows no 9001 |
| 2 | Allow ICMP dest-unreach + time-exceeded on public/private NACLs | platform | 2026-03-13 | SG/NACL rules in `modules/security` + `modules/vpc` |
| 3 | Add 8 KB POST `/readyz` to deploy health-check and to Prometheus synthetics | platform | 2026-03-20 | deploy.yml fails the job on hang; alert `PMTUDBroken` |
| 4 | Ship `scripts/mtu-path-check.sh` in CI / cron against `1.1.1.1` | platform | 2026-03-20 | cron or workflow green |
| 5 | Page on Cloudflare origin timeouts (`cloudflared` error counter) | platform | 2026-03-20 | `CloudflareOriginTimeouts` in Alertmanager |
| 6 | Runbook: “GET works, POST hangs” maps to MTU before the app | on-call | 2026-03-18 | this document linked from README |
| 7 | PR template: overlay + MTU checkbox on any VPC / NACL change | platform | 2026-03-27 | template in `.github/` |

Dropped on purpose:

- Re-enable jumbo “for performance” on overlay nodes — no.
- Drop all ICMP as a hardening fashion — no. Echo from the internet
  can stay denied; dest-unreach cannot.
- Add an ALB to “absorb MTU problems” — cost without a fix.

---

## 8. Lessons

1. Overlays own the MTU. The physical NIC is not the path.
2. Health checks must use the same size and verb as customers.
3. ICMP is part of TCP. Filtering it is a functional change.
4. Cheap canaries lie. Tailscale and `/healthz` were both up.

---

## 9. Appendix: commands that diagnosed it

```bash
ip link show eth0                          # mtu 9001  ← wrong
ping -M do -s 1472 -c 3 1.1.1.1            # fail
ping -M do -s 1200 -c 3 1.1.1.1            # ok

curl -sS -o /dev/null -w '%{http_code} %{time_total}\n' \
  https://app.example.com/healthz

dd if=/dev/zero bs=8192 count=1 | \
  curl -sS -o /dev/null -w '%{http_code} %{time_total}\n' \
  -X POST --data-binary @- https://app.example.com/readyz
```

The 8 KB POST is now the synthetic in deploy.yml and in Prometheus.
It would have paged at 15:41, not 16:02.

---

## Template (copy for the next incident)

```
# Blameless postmortem: <one-line title>

Status / Severity / Impact window / Time to mitigation / Date / Author

## 1. Summary
## 2. Customer impact
## 3. Timeline (UTC)
## 4. Root cause
## 5. What else was (or was not) affected
## 6. Detection and response gaps  (include what went well)
## 7. Action items  (owner, due, done-when)
## 8. Lessons
## 9. Appendix
```
