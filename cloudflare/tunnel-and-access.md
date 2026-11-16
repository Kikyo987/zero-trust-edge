# Cloudflare Tunnel + Access

Users never see the origin IP. DNS for the product hostname is a CNAME
to the named tunnel, Access sits in front, and `cloudflared` dials
Cloudflare outbound. The node security group stays empty.

## 1. Named tunnel (not a quick tunnel)

Quick tunnels (`cloudflared tunnel --url`) get a random `trycloudflare.com`
hostname and die with the process. Named tunnels survive restarts, take
a token, and bind to DNS you control.

```bash
# one-time, on a laptop that is already logged in to the Cloudflare account
cloudflared tunnel login
cloudflared tunnel create edge-zero
# → UUID, credentials JSON. The JSON is a secret. Do not commit it.

# preferred on servers: token auth, no JSON on disk
# Zero Trust → Networks → Tunnels → edge-zero → Install connector → token
```

Store the token in:

- GitHub Environment `production` as `CLOUDFLARE_TUNNEL_TOKEN`, or
- a Kubernetes Secret (`k3s/manifests/40-cloudflared.yaml`), or
- systemd `EnvironmentFile=/etc/edge/cloudflared.env` with `0600`

Rotate by issuing a new token in the dashboard and rolling the
Deployment. The UUID and DNS records stay. Clients do not notice.

## 2. DNS

```
app.example.com      CNAME  <TUNNEL-UUID>.cfargotunnel.com   proxied
grafana.example.com  CNAME  <TUNNEL-UUID>.cfargotunnel.com   proxied
```

Do **not** create an A record to the node’s Elastic IP. That IP is an
egress identifier, not an origin.

Orange-cloud (proxied) is required. Grey-cloud would point clients at
`cfargotunnel.com` without WAF / Access, and still would not reach your
node, so it only hurts.

## 3. `config.yml`

See `config.yml` next to this file. Two details that are easy to get
wrong:

1. **`protocol: auto`** lets cloudflared pick QUIC, then fall back to
   HTTP/2. After an MTU incident, pin `protocol: http2` for a day.
2. **Catch-all `http_status:404`.** Without it, a mistyped hostname on
   the same tunnel can be routed to the first ingress rule.

Ingress order is first-match. Put the most specific hostnames at the
top.

## 4. Access policies

Tunnel makes the origin private. Access decides *which humans* may
reach it. They are independent controls; run both.

Recommended apps:

| Application | Domain | Policy |
| --- | --- | --- |
| Product | `app.example.com` | allow `email` in `*@customer.com` (or IdP group) |
| Grafana | `grafana.example.com` | allow `group:ops` only, 24h session |
| Prometheus | do **not** publish | Tailscale only, `127.0.0.1:9090` |

Policy skeleton (Zero Trust → Access → Applications → Self-hosted):

```
Action: Allow
Include:
  - Emails ending in: @customer.com
Require:
  - Country is not in { sanctioned list }     # optional
  - Passed MFA
Session duration: 8 hours (app), 24 hours (grafana)
```

For a public marketing page you can skip Access on that hostname and
still keep the origin off the internet. Do not skip Access on Grafana.

IdP: GitHub or Google is enough for a five-person team. Okta when the
customer already has it. Do not invent a second password store.

## 5. WAF / TLS

- SSL/TLS mode: **Full (strict)** once you terminate inside the tunnel
  with HTTP to the ClusterIP. Cloudflare ↔ cloudflared is already mTLS.
  Origin certs on the node are optional and usually noise.
- Minimum TLS: 1.2, prefer 1.3.
- Always Use HTTPS: on.
- Bot Fight: on for the product hostname.
- Managed WAF: Cloudflare Free is fine; the tunnel is the real control.

## 6. What the node must allow outbound

cloudflared needs:

- `TCP/443` to Cloudflare anycast
- `UDP/443` if QUIC is enabled
- DNS

It does **not** need inbound 7844, 443, or 80. Older blog posts that
open `7844/udp` are for a different topology (`cloudflared` as a
server). We are a client.

## 7. systemd (VPS path, no k3s)

```
# /etc/systemd/system/cloudflared.service
[Unit]
Description=Cloudflare Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=cloudflared
Group=cloudflared
ExecStart=/usr/bin/cloudflared tunnel --no-autoupdate --config /etc/cloudflared/config.yml run --token-file /etc/edge/cloudflared.token
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
CapabilityBoundingSet=
LockPersonality=true
MemoryMax=128M
CPUQuota=25%

[Install]
WantedBy=multi-user.target
```

`scripts/bootstrap-host.sh` installs this unit.

## 8. Verification

```bash
# from a laptop that is NOT on the tailnet
curl -sSI https://app.example.com | head
# expect: 302 to Cloudflare Access, or 200 if you are already authed

# origin IP must not appear
dig +short app.example.com
# expect: Cloudflare anycast, never the Elastic IP

# from the node
ss -lntu | grep -E ':80|:443|:7844' || echo "good: no public listeners"
curl -sS http://127.0.0.1:8080/healthz
```

`scripts/zero-trust-verify.sh` wraps the node side.

## 9. Failure modes (short)

| Symptom | Likely cause |
| --- | --- |
| 1033 | cloudflared down or token revoked |
| 502 / 1033 flapping | one replica of two is bad; PDB / rollout |
| 524 | origin timeout — MTU or app hang (see postmortem) |
| Access loop | clock skew (NTP egress blocked) or cookie domain mismatch |
| Works on GET, fails on POST | MTU. Pin 1500, allow ICMP dest-unreach |
