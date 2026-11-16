# Cloudflare Zero Trust + Tailscale

Start here: **[tunnel-and-access.md](tunnel-and-access.md)**

| File | What it is |
| --- | --- |
| `config.yml` | Named tunnel, k3s Service DNS, catch-all 404 |
| `config.compose.yml` | Same tunnel for Docker Compose |
| `systemd/cloudflared.service` | Hardened unit, token-file, no extra caps |
| `access/app-product.json` | Self-hosted app for `app.example.com` |
| `access/policy-github-mfa.json` | GitHub org + MFA |
| `access/policy-google-mfa.json` | Google domain + MFA |
| `access/app-grafana.json` | Grafana hostname |
| `access/policy-ops-only.json` | Named ops emails + MFA |
| `tailscale-acl.hujson` | SSH for ops/CI only; DB for `tag:app` only |
