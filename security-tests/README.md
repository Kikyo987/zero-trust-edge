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

On this kernel, k3s's network-policy controller does not start (`ipset` and
VXLAN are unavailable). A node with a normal kernel should re-run the Pod
check under kube-router; the manifest is the same file.

## What the owner runs against the real edge

```bash
export ZTE_NODE_PUBLIC_IP=203.0.113.50
export ZTE_APP_URL=https://app.example.com
# from a non-ops tailnet identity:
export ZTE_USER_SSH_TARGET=ubuntu@100.x.y.z
# from a tag:ci node:
export ZTE_CI_GRAFANA_URL=http://100.x.y.z:3000
export ZTE_CI_SSH_TARGET=ubuntu@100.x.y.z
sudo -E ./security-tests/run.sh --production
```

Unset variables are recorded as SKIP. Do not paste another environment's
output into this repository and call it the current run.

## MTU lab

Separate from the seven checks. It is the reproduction for
[docs/postmortem-example.md](../docs/postmortem-example.md).

```bash
sudo ./security-tests/lab/mtu-blackhole.sh
```

Output: `docs/evidence/mtu-lab/transcript.txt` and `pmtud-blackhole.pcap`.
