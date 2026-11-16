# k3s

Single-node (HA-ready CIDRs) Kubernetes with Traefik as ClusterIP.

cloud-init on the AWS node already runs this. Use `install.sh` on a VPS
or to re-apply after a rebuild.

```
k3s/
  install.sh
  manifests/
    00-namespace.yaml      edge, cloudflare-tunnel, monitoring + PSA
    10-network-policy.yaml default-deny + DNS + cloudflared → app + labeled probes
    20-deployment.yaml     edge-echo, non-root, probes, limits
    21-service.yaml        ClusterIP :8080
    30-ingress.yaml        Traefik Ingress + HelmChartConfig (no host bind)
    40-cloudflared.yaml    named tunnel connector
    50-pdb.yaml
```

## Why Traefik is ClusterIP

k3s defaults to a ServiceLB that would publish :80/:443 on the host.
That is a public listener. We `--disable=servicelb` and set Traefik
`service.type=ClusterIP` plus `hostNetwork: false`.

Users: Cloudflare Tunnel → cloudflared → Service or Ingress.
Operators: Tailscale → `kubectl`.

## Apply

```bash
sudo ./k3s/install.sh
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n edge get deploy,svc,ingress
```
