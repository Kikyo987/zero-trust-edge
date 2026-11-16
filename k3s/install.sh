#!/usr/bin/env bash
# Manual / re-run k3s bootstrap. cloud-init already does this on first
# boot; this script is for a VPS path or a node that was rebuilt.
#
# CIDRs are disjoint from VPC 10.42.0.0/16 and Tailscale 100.64.0.0/10.
# kube-apiserver is advertised on Tailscale if present, else the primary
# private IPv4. Traefik stays ClusterIP (servicelb disabled).
set -euo pipefail

K3S_VERSION="${K3S_VERSION:-v1.31.4+k3s1}"
CLUSTER_CIDR="${CLUSTER_CIDR:-10.43.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.44.0.0/16}"
INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ ${EUID} -ne 0 ]]; then
  echo "run as root" >&2
  exit 1
fi

DEFAULT_IF="$(ip -o -4 route show to default | awk '{print $5}' | head -1)"
ip link set dev "${DEFAULT_IF}" mtu 1500 || true
PRIVATE_IP="$(ip -4 addr show "${DEFAULT_IF}" | awk '/inet / {print $2}' | cut -d/ -f1)"

TAILSCALE_IP="$(ip -4 addr show tailscale0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 || true)"
ADVERTISE="${TAILSCALE_IP:-$PRIVATE_IP}"

FLANNEL_BACKEND="vxlan"
if [[ -d /sys/module/wireguard ]] || modprobe wireguard 2>/dev/null; then
  FLANNEL_BACKEND="wireguard-native"
fi

if command -v k3s >/dev/null && systemctl is-active --quiet k3s; then
  echo "k3s already running — applying manifests only"
else
  export INSTALL_K3S_VERSION="${K3S_VERSION}"
  curl -fsSL https://get.k3s.io | sh -s - server \
    --cluster-cidr="${CLUSTER_CIDR}" \
    --service-cidr="${SERVICE_CIDR}" \
    --flannel-backend="${FLANNEL_BACKEND}" \
    --advertise-address="${ADVERTISE}" \
    --node-ip="${PRIVATE_IP}" \
    --tls-san="${ADVERTISE}" \
    --tls-san=127.0.0.1 \
    --disable=servicelb \
    --disable=local-storage \
    --write-kubeconfig-mode=600 \
    --protect-kernel-defaults=true \
    --secrets-encryption
fi

install -m 600 /etc/rancher/k3s/k3s.yaml /root/k3s.yaml
sed -i "s/127.0.0.1/${ADVERTISE}/g" /root/k3s.yaml

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
for i in $(seq 1 30); do
  kubectl get nodes >/dev/null 2>&1 && break
  sleep 2
done

kubectl apply -f "${INSTALL_DIR}/manifests/"

echo
echo "k3s ${K3S_VERSION}  advertise=${ADVERTISE}  flannel=${FLANNEL_BACKEND}"
echo "kubeconfig: /root/k3s.yaml  (use over Tailscale / SSM, never the public IP)"
echo "kubectl -n edge get deploy,svc,ingress"
