# Simulated incident: Cloudflare Tunnel MTU black hole

> **Document class: Simulated Incident and Lab Reproduction.**
> **This is not a Production Incident.** No customer was paged, no status
> page was updated, and the clock times below were not observed.
> Section 3 is a teaching timeline. Section 10 is a lab that was actually
> run; the commands and the packet capture there are real, and they are
> labeled LAB.

**Status:** simulated write-up, with a local reproduction  
**Severity used in the narrative:** SEV-2 (illustrative)  
**Narrative window:** 47 minutes, invented for the timeline exercise  
**Date of the narrative:** 2026-03-12 (not an outage date)  
**Author:** platform / network, as a worked example  
**Lab evidence:** [transcript](evidence/mtu-lab/transcript.txt), [pcap](evidence/mtu-lab/pmtud-blackhole.pcap), [summary screenshot](evidence/lab-report.png)

The packet behaviour in the narrative is the behaviour the lab
reproduces: a small GET completes, an 8 KB POST stalls when ICMP
fragmentation-needed is dropped, and the POST completes after that
ICMP message is allowed through. The timestamps are not a record of
anything that happened.

Blameless means the narrative describes what the *system* would have
allowed, not who to blame. Names in the timeline are roles.

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

## 2. Hypothetical impact (illustrative — not observed)

Nothing in this table was measured. It is the shape of the impact the
failure mode would have, so the write-up has somewhere to put a
customer sentence. Do not quote it as an outage.

| Item | Value in the narrative |
| --- | --- |
| Who | Authenticated users saving a form (POST ≥ ~1.4 KB) |
| What they would see | Spinner, then a Cloudflare 524 or a browser timeout |
| Start | 16:02 UTC (invented) |
| End | 16:49 UTC (invented) |
| Data loss | None in the story — failed POSTs would not commit |
| Workaround | None for users. Operators could still SSH over Tailscale |
| Status page | Not updated. There was no incident. |

---

## 3. Illustrative timeline (not an observed outage)

Every clock time in this table is made up, so the write-up can show
what a real timeline looks like. Gaps in a real timeline would be
called out in §6. Do not treat 15:40 or 16:49 as something that
happened.

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

The 8 KB POST is the synthetic in deploy.yml and in Prometheus.
In the illustrative timeline, that check would have fired at 15:41
instead of waiting for a person. Those clock times are still invented.

---

## 10. Lab reproduction (this one was actually run)

Ran on 2026-11-16 against network namespaces on the machine that
produced this commit. Not a production path, not a Cloudflare 524,
not a customer. Full command log:
[evidence/mtu-lab/transcript.txt](evidence/mtu-lab/transcript.txt).
Packet capture of the stalled POST:
[evidence/mtu-lab/pmtud-blackhole.pcap](evidence/mtu-lab/pmtud-blackhole.pcap).

Topology: client and server at MTU 1500, router hop toward the server
at MTU 1280, forwarding on. While the failure is in place, the router
drops ICMP type 3 code 4 (fragmentation needed).

What the commands showed:

```text
# 1200-byte DF ping fits (1200 + 28 = 1228 < 1280)
2 packets transmitted, 2 received, 0% packet loss

# 1400-byte DF ping does not, and the drop hides the reason
2 packets transmitted, 0 received, 100% packet loss

# small GET
HTTP/1.0 200 OK

# 8 KB POST while ICMP is dropped
curl: (28) Operation timed out after 4002 milliseconds with 0 bytes received

# tcpdump on the router, client side, during that POST
Flags [S], ... options [mss 1460, ...]
Flags [P.], seq 1:7241, ... length 7240: HTTP: POST /readyz
Flags [.], seq 1:1449, ... length 1448: HTTP: POST /readyz
(retransmitted; the ack never moves past byte 1)

# after the ICMP drop is removed
From 10.88.0.1 icmp_seq=1 Frag needed and DF set (mtu = 1280)

# same 8 KB POST
HTTP/1.0 200 OK
body: ready
```

The capture is the black hole: TCP negotiated MSS 1460 from the local
1500-byte NICs, then retransmitted a 1448-byte segment that cannot
cross the 1280-byte hop, with no ICMP coming back. Restoring ICMP
type 3 code 4 is what lets the next POST shrink and finish.

Replay:

```bash
sudo ./security-tests/lab/mtu-blackhole.sh
```

---

## Template (copy for the next real incident)

```
# Blameless postmortem: <one-line title>

Document class: Production Incident | Simulated Incident | Lab Reproduction
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
