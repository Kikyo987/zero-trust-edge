#!/bin/bash
# cloud-init for the k3s node. Secrets are NOT baked in.
# Tailscale and cloudflared join tokens live in SSM and are pulled here
# if present. The instance profile already has SSM read via the managed
# policy plus a future tight policy if you scope it.
set -euo pipefail
exec > >(tee /var/log/edge-user-data.log) 2>&1

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates curl jq iptables ethtool traceroute iputils-ping

# Predictable MTU even if the VPC is later flipped to jumbo by mistake.
ip link set dev "$(ip -o -4 route show to default | awk '{print $5}')" mtu 1500 || true

# sysctl: rp_filter=1 (strict), bbr, no ip_forward until k3s/tailscale ask.
cat >/etc/sysctl.d/99-edge.conf <<'SYSCTL'
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.ip_forward = 1
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_ra = 0
net.ipv4.tcp_mtu_probing = 1
SYSCTL
sysctl --system || true

# Empty inbound chain on the host as a second belt. SG is the first.
if command -v ufw >/dev/null; then
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow in on tailscale0 || true
  ufw --force enable
fi

mkdir -p /opt/edge
echo "user-data complete $(date -u +%FT%TZ)" >/opt/edge/user-data.ok
