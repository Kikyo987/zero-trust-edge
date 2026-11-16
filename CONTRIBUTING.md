# Contributing

This is a reference edge, not a product. Small, reviewable changes are
welcome. Security reports go through [SECURITY.md](SECURITY.md), not a
public issue.

## Run locally

Requires Docker 24+ and Compose v2.

```bash
git clone https://github.com/Kikyo987/zero-trust-edge.git
cd zero-trust-edge
cp docker/compose/.env.example docker/compose/.env
make dev-up
curl -sS http://127.0.0.1:8080/healthz   # ok
```

All compose ports bind to `127.0.0.1`. Grafana is `http://127.0.0.1:3000`.
`make dev-down` stops the stack.

Terraform fmt / validate (no cloud credentials):

```bash
make tf-fmt
cd terraform/environments/dev && terraform init -backend=false && terraform validate
```

## Commit convention

Imperative subject, ≤ 72 characters. Body explains *why* when the diff
is not obvious.

```
Pin VPC MTU at 1500 so overlays do not black-hole POSTs
```

Prefixes that match the tree, when useful:

| Prefix | Use for |
| --- | --- |
| `terraform:` | modules, env, cloud-init |
| `k3s:` | manifests, install.sh |
| `ci:` | `.github/workflows` |
| `docs:` | README, adr, runbooks |

Do not commit `.env`, `terraform.tfvars`, tunnel tokens, Tailscale auth
keys, or Alertmanager webhook files. See `.gitignore`.

PRs should keep `ci` green (fmt, `go test`, Trivy, kubeconform). Deploy
is manual and is not part of the PR check.

## Security

Vulnerabilities, leaked credentials, and anything that would open an
inbound port: **[SECURITY.md](SECURITY.md)**. Do not file a public issue.
