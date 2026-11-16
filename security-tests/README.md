# Security tests

`scripts/zero-trust-verify.sh` checks the machine it is running on:
listeners, compose publish addresses, non-root. It does not show that an
unauthorized user is rejected, that CI cannot open Grafana, or that a
Pod which is not cloudflared cannot reach the app.

This directory runs those checks and writes a PASS/FAIL report.

```bash
sudo ./security-tests/run.sh --lab
```

The report is `security-tests/reports/latest.md`. A rendering of the
lab run is `docs/evidence/lab-report.png`. The dual-plane drawing is
`docs/diagrams/dual-plane.svg` (rendered at
`docs/evidence/architecture-dual-plane.png`).

## What `--lab` actually is

Network namespaces, iptables, and the policy files in the repo:

| Check | Lab stand-in |
| --- | --- |
| External scan | `nmap` from a namespace at `203.0.113.10` (TEST-NET-3). Not a public VPS. |
| Unauthorized app access | A local proxy that applies `cloudflare/access/policy-github-mfa.json`. Not Cloudflare Access. |
| User SSH denied, CI Grafana denied, CI SSH allowed | `tailscale/acl.hujson` enforced on a lab router. Not a tailnet. |
| Non-cloudflared Pod denied | `k3s/manifests/10-network-policy.yaml` enforced with iptables. Not kube-router. |
| Privilege escalation fails | Deployment securityContext, plus `PR_SET_NO_NEW_PRIVS` against a setuid helper. |

SKIP is not PASS. The lab report does not contain production scan results.

Each lab report states whether `ip_set` and `vxlan` are present on the
kernel that just ran. The Pod check still uses iptables in a namespace.
That is not a kube-router result, including on a kernel that has the modules.

The setuid helper is built under `/var/lib/zte-priv` or
`/usr/local/lib/zte-priv`, and only when that mount is not `nosuid`.
`/tmp` is not used. If every candidate is `nosuid`, the check is SKIP
and the report says why. The deployment manifest is still checked.

## What the owner runs against a real edge

```bash
# Do not use sudo -E. Some Ubuntu sudo builds ignore it and drop ZTE_*.
sudo env \
  ZTE_NODE_PUBLIC_IP=203.0.113.50 \
  ZTE_APP_URL=https://app.example.com \
  ZTE_USER_SSH_TARGET=ubuntu@100.x.y.z \
  ZTE_CI_GRAFANA_URL=http://100.x.y.z:3000 \
  ZTE_CI_SSH_TARGET=ubuntu@100.x.y.z \
  ./security-tests/run.sh --production
```

Run the nmap from a machine that does not own `ZTE_NODE_PUBLIC_IP`.
If the address is configured on the host running the script, the scan
is refused: local delivery bypasses UFW and prints `closed` instead of
`filtered`.

Unset variables are SKIP. SKIP is not a pass for Cloudflare, Tailscale,
or kube-router.

A temporary public lab VPS (now shut down, or about to be) is documented
in [docs/evidence/lab-vps/README.md](../docs/evidence/lab-vps/README.md).
Port 22 was open there. That is not the finished design.

## MTU lab

Separate from the seven checks. It is the reproduction for
[docs/postmortem-example.md](../docs/postmortem-example.md).

```bash
sudo ./security-tests/lab/mtu-blackhole.sh
```

Output: `docs/evidence/mtu-lab/transcript.txt` and `pmtud-blackhole.pcap`.
