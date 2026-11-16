#!/usr/bin/env bash
# Hardened single-node k3s bootstrap.
# - Cluster / service CIDRs disjoint from VPC 10.42.0.0/16 and Tailscale 100.64.0.0/10
# - kube-apiserver advertised on the Tailscale IP so kubectl never needs a public listener
# - Traefik kept, LoadBalancer disabled (no public IP to announce)
# - Version pinned. Do not curl | sh the moving tag in production.
set -euo pipefail

K3S_VERSION="${K3S_VERSION:-v1.31.4+k3s1}"
CLUSTER_CIDR="${CLUSTER_CIDR:-10.43.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.44.0.0/16}"
INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ ${EUID} -ne 0 ]]; then
  echo "run as root" >&2
  exit 1
fi

# Tailscale IP is the only address we put on the API cert.
TAILSCALE_IP="$(ip -4 addr show tailscale0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 || true)"
if [[ -z "${TAILSCALE_IP}" ]]; then
  echo "tailscale0 has no IPv4. Join the tailnet before installing k3s:" >&2
  echo "  tailscale up --ssh --advertise-tags=tag:node" >&2
  exit 1
fi

# Pin host MTU before the overlay comes up.
DEFAULT_IF="$(ip -o -4 route show to default | awk '{print $5}' | head -1)"
ip link set dev "${DEFAULT_IF}" mtu 1500 || true

# Prefer kernel WireGuard for flannel; fall back to VXLAN.
FLANNEL_BACKEND="vxlan"
if [[ -d /sys/module/wireguard ]] || modprobe wireguard 2>/dev/null; then
  FLANNEL_BACKEND="wireguard-native"
fi

export INSTALL_K3S_VERSION="${K3S_VERSION}"
export INSTALL_K3S_EXEC="server \
  --cluster-cidr=${CLUSTER_CIDR} \
  --service-cidr=${SERVICE_CIDR} \
  --flannel-backend=${FLANNEL_BACKEND} \
  --tls-san=${TAILSCALE_IP} \
  --tls-san=127.0.0.1 \
  --advertise-address=${TAILSCALE_IP} \
  --node-ip=${TAILSCALE_IP} \
  --disable=servicelb \
  --disable=local-storage \
  --write-kubeconfig-mode=600 \
  --protect-kernel-defaults=true \
  --secrets-encryption"

curl -fsSL https://get.k3s.io | sh -

# kubeconfig for the installing user (root) and a copy ops can scp over Tailscale.
install -m 600 /etc/rancher/k3s/k3s.yaml /root/k3s.yaml
sed -i "s/127.0.0.1/${TAILSCALE_IP}/g" /root/k3s.yaml

# Apply manifests once the API answers.
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
for i in $(seq 1 30); do
  kubectl get nodes >/dev/null 2>&1 && break
  sleep 2
done

kubectl apply -f "${INSTALL_DIR}/manifests/"

echo
echo "k3s ${K3S_VERSION} is up. API: https://${TAILSCALE_IP}:6443"
echo "kubeconfig: /root/k3s.yaml  (use over Tailscale, never over the public IP)"
echo "next: kubectl -n edge get pods -w"
echo "      ./scripts/zero-trust-verify.sh"
