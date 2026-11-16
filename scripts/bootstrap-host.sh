#!/usr/bin/env bash
# First-boot hardening for a Ubuntu 24.04 VPS or the AWS node.
# - deny inbound on the host firewall
# - pin MTU 1500
# - install Tailscale + cloudflared
# - sysctl for rp_filter, bbr, mtu probing
#
# Does NOT install k3s (see k3s/install.sh) so you can stop at compose.
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "run as root" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates curl jq ufw iptables ethtool traceroute iputils-ping \
  gnupg lsb-release

DEFAULT_IF="$(ip -o -4 route show to default | awk '{print $5}' | head -1)"
ip link set dev "${DEFAULT_IF}" mtu 1500 || true
cat >/etc/netplan/99-mtu.yaml <<EOF
# Pin 1500 so overlays (Tailscale, Cloudflare Tunnel) do not black-hole.
network:
  version: 2
  ethernets:
    ${DEFAULT_IF}:
      mtu: 1500
EOF
netplan apply 2>/dev/null || true

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
net.ipv4.icmp_echo_ignore_all = 0
SYSCTL
sysctl --system

# Host firewall: deny inbound, allow outbound, allow tailscale0.
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow in on tailscale0
# ICMP dest-unreach / time-exceeded are not first-class ufw rules;
# they ride with 'allow outgoing' return state. Keep ping-from-world denied.
ufw --force enable

# Tailscale
if ! command -v tailscale >/dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi

# cloudflared
if ! command -v cloudflared >/dev/null; then
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
    | gpg --dearmor -o /usr/share/keyrings/cloudflare-main.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" \
    >/etc/apt/sources.list.d/cloudflared.list
  apt-get update -y
  apt-get install -y cloudflared
fi

id cloudflared >/dev/null 2>&1 || useradd --system --home /var/lib/cloudflared --shell /usr/sbin/nologin cloudflared
install -d -o cloudflared -g cloudflared -m 0750 /etc/cloudflared /etc/edge /var/lib/cloudflared

if [[ ! -f /etc/systemd/system/cloudflared.service ]]; then
  cat >/etc/systemd/system/cloudflared.service <<'UNIT'
[Unit]
Description=Cloudflare Tunnel
After=network-online.target
Wants=network-online.target
ConditionPathExists=/etc/edge/cloudflared.token

[Service]
Type=simple
User=cloudflared
Group=cloudflared
Environment=TUNNEL_TOKEN_FILE=/etc/edge/cloudflared.token
ExecStart=/usr/bin/cloudflared tunnel --no-autoupdate --config /etc/cloudflared/config.yml run --token-file /etc/edge/cloudflared.token
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
MemoryMax=128M
CPUQuota=25%

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
fi

# sshd: will rebind to Tailscale IP once it exists (see scripts/bind-ssh-tailscale.sh).
if [[ -f /etc/ssh/sshd_config ]]; then
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
  sed -i 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' /etc/ssh/sshd_config
fi

echo
echo "bootstrap done."
echo "  1. tailscale up --ssh --advertise-tags=tag:node --auth-key=tskey-..."
echo "  2. put the Cloudflare tunnel token in /etc/edge/cloudflared.token (mode 600)"
echo "  3. copy cloudflare/config.yml to /etc/cloudflared/config.yml"
echo "  4. systemctl enable --now cloudflared"
echo "  5. ./scripts/bind-ssh-tailscale.sh && ./k3s/install.sh"
echo "  6. ./scripts/zero-trust-verify.sh"
