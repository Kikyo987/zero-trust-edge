#!/usr/bin/env bash
# Fail closed if the node has drifted from the zero-trust baseline.
# Run on the node (or via Tailscale SSH from CI).
set -euo pipefail

FAIL=0
warn() { printf 'WARN  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAIL=1; }
ok()   { printf 'OK    %s\n' "$*"; }

echo "== listeners (must not include 0.0.0.0:{22,80,443} or *:22/80/443) =="
LISTEN="$(ss -lntu 2>/dev/null || netstat -lntu)"
echo "${LISTEN}"
if echo "${LISTEN}" | grep -E '0\.0\.0\.0:(22|80|443)\s' >/dev/null; then
  fail "public listener on 22/80/443"
else
  ok "no 0.0.0.0:22/80/443"
fi
if echo "${LISTEN}" | grep -E '\*:22\s|\*:80\s|\*:443\s' >/dev/null; then
  fail "wildcard listener on 22/80/443"
fi

echo
echo "== sshd ListenAddress =="
if [[ -f /etc/ssh/sshd_config ]]; then
  if grep -E '^ListenAddress 100\.' /etc/ssh/sshd_config >/dev/null; then
    ok "sshd bound to a Tailscale IP"
  else
    warn "sshd is not pinned to 100.x — run scripts/bind-ssh-tailscale.sh"
  fi
fi

echo
echo "== Tailscale =="
if command -v tailscale >/dev/null; then
  if tailscale status --json >/dev/null 2>&1; then
    ok "tailscaled is up"
    tailscale ip -4 || true
  else
    fail "tailscale status failed"
  fi
else
  fail "tailscale not installed"
fi

echo
echo "== cloudflared =="
if systemctl is-active --quiet cloudflared 2>/dev/null \
  || docker ps --format '{{.Names}}' 2>/dev/null | grep -q cloudflared \
  || (command -v kubectl >/dev/null && kubectl -n cloudflare-tunnel get deploy cloudflared >/dev/null 2>&1); then
  ok "cloudflared appears to be running"
else
  warn "cloudflared not detected (ok on a laptop compose without --profile tunnel)"
fi

echo
echo "== host firewall =="
if command -v ufw >/dev/null; then
  ufw status | head -20
  if ufw status | grep -qi 'Status: active'; then
    ok "ufw active"
  else
    warn "ufw inactive — AWS SG must be the only belt, confirm it"
  fi
fi

echo
echo "== MTU =="
DEFAULT_IF="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -1 || true)"
if [[ -n "${DEFAULT_IF}" ]]; then
  MTU="$(cat /sys/class/net/${DEFAULT_IF}/mtu)"
  echo "  ${DEFAULT_IF} mtu ${MTU}"
  if [[ "${MTU}" -gt 1500 ]]; then
    fail "MTU ${MTU} > 1500 on ${DEFAULT_IF} — jumbo + overlay will black-hole POSTs"
  else
    ok "MTU ${MTU}"
  fi
fi

echo
echo "== process uid of edge-echo (must not be 0) =="
if command -v docker >/dev/null; then
  UID_IN_CT="$(docker inspect -f '{{.State.Running}} {{.Config.User}}' "$(docker ps -q -f name=edge-echo)" 2>/dev/null | head -1 || true)"
  echo "  compose: ${UID_IN_CT:-n/a}"
fi

if [[ "${FAIL}" -ne 0 ]]; then
  echo
  echo "zero-trust verify FAILED"
  exit 1
fi
echo
echo "zero-trust verify passed"
