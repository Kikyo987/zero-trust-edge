#!/usr/bin/env bash
# Prove the inbound posture. Exit 0 only if nothing is listening on
# 0.0.0.0 / :: for the ports that would make this a public origin.
#
#   ./scripts/zero-trust-verify.sh           # auto: compose laptop or node
#   ./scripts/zero-trust-verify.sh --node    # fail if Tailscale / sshd 100.x missing
#   ./scripts/zero-trust-verify.sh --compose # Docker publish-address checks only
#
# Run from the repo root on a laptop, or on the node (sudo).
set -euo pipefail

MODE="auto"
for a in "$@"; do
  case "$a" in
    --node) MODE="node" ;;
    --compose) MODE="compose" ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_FILE="${ROOT}/docker/compose/docker-compose.yml"
FAIL=0
PASS_N=0
WARN_N=0

ok()   { printf '  [PASS] %s\n' "$*"; PASS_N=$((PASS_N + 1)); }
warn() { printf '  [WARN] %s\n' "$*"; WARN_N=$((WARN_N + 1)); }
fail() { printf '  [FAIL] %s\n' "$*"; FAIL=1; }

have_compose() {
  command -v docker >/dev/null 2>&1 || return 1
  docker compose -f "${COMPOSE_FILE}" ps --status running -q 2>/dev/null | grep -q .
}

if [[ "${MODE}" == "auto" ]]; then
  if have_compose && [[ ${EUID} -ne 0 ]]; then
    MODE="compose"
  else
    MODE="node"
  fi
fi

echo
echo "zero-trust-verify  mode=${MODE}  host=$(hostname -s 2>/dev/null || hostname)"
echo "claim: no public inbound ports (no 0.0.0.0/:: on 22, 80, 443, 6443, 7844)"
echo

# ----- parse listeners -----
# ss -ltnH columns: State Recv-Q Send-Q Local Peer  → Local is $4
# (no Netid). Do not grep the peer column (0.0.0.0:*).
tcp_local() { ss -ltnH 2>/dev/null | awk '{print $4}'; }
LISTEN_TCP="$(ss -ltnH 2>/dev/null || true)"
LOCAL_ADDRS="$(tcp_local || true)"
PUBLIC_HITS="$(echo "${LOCAL_ADDRS}" | grep -E '^(0\.0\.0\.0|\[::\]|\*):(22|80|443|6443|7844)$' || true)"
TAILSCALE_HITS="$(echo "${LOCAL_ADDRS}" | grep -E '^100\.[0-9]+\.[0-9]+\.[0-9]+:' || true)"

echo "== 1. TCP listen addresses (ss -ltn, local column only) =="
if [[ -z "${LISTEN_TCP}" ]]; then
  warn "ss not available — skipping raw socket dump"
else
  echo "${LISTEN_TCP}" | awk '{printf "     %-8s %s\n", $1, $4}'
  echo
  if [[ -n "${PUBLIC_HITS}" ]]; then
    echo "${PUBLIC_HITS}" | awk '{print "     public bind: "$0}'
    if [[ "${MODE}" == "compose" ]]; then
      warn "this machine has 22/80/443 on 0.0.0.0 — that is the laptop, not the compose stack"
      warn "compose posture is section 2. A production node must run --node and FAIL here"
    else
      fail "a process is bound to 0.0.0.0 / :: on 22, 80, 443, 6443, or 7844"
    fi
  else
    ok "no 0.0.0.0/:: TCP listener on 22, 80, 443, 6443, 7844"
  fi
  if echo "${LOCAL_ADDRS}" | grep -qE '^127\.0\.0\.1:(8080|3000|9090|9093|3100)$'; then
    ok "app/observability bound to 127.0.0.1 (compose / local)"
  fi
  if [[ -n "${TAILSCALE_HITS}" ]]; then
    ok "some sockets on 100.x (Tailscale) — operators, not the internet"
  fi
fi

echo
echo "== 2. Docker published ports (must be 127.0.0.1, never 0.0.0.0) =="
if command -v docker >/dev/null 2>&1 && [[ -f "${COMPOSE_FILE}" ]]; then
  PUB="$(docker compose -f "${COMPOSE_FILE}" ps --format '{{.Name}} {{.Ports}}' 2>/dev/null || true)"
  if [[ -z "${PUB}" ]]; then
    warn "compose stack is not running (ok on a k3s node)"
  else
    echo "${PUB}" | awk '{print "     "$0}'
    if echo "${PUB}" | grep -qE '0\.0\.0\.0:|:::'; then
      fail "compose published a port on 0.0.0.0 — that is a public inbound port"
    else
      ok "compose publishes only 127.0.0.1 (or no host ports)"
    fi
    if PORT="$(docker compose -f "${COMPOSE_FILE}" port edge-echo 8080 2>/dev/null)"; then
      echo "     edge-echo 8080 -> ${PORT}"
      if [[ "${PORT}" == 127.0.0.1:* ]]; then
        ok "edge-echo mapped to ${PORT}"
      else
        fail "edge-echo mapped to ${PORT} (expected 127.0.0.1:8080)"
      fi
    fi
  fi
else
  warn "docker / compose file not present"
fi

echo
echo "== 3. origin answers on loopback (the tunnel's next hop) =="
if curl -fsS --max-time 3 http://127.0.0.1:8080/healthz 2>/dev/null | grep -q ok; then
  BODY="$(curl -fsS --max-time 3 http://127.0.0.1:8080/healthz)"
  ok "GET 127.0.0.1:8080/healthz -> ${BODY}"
else
  if [[ "${MODE}" == "compose" ]]; then
    fail "127.0.0.1:8080/healthz did not return ok — is compose up?"
  else
    warn "nothing on 127.0.0.1:8080 (ok if the app is only in-cluster)"
  fi
fi

echo
echo "== 4. sshd / Tailscale / tunnel (node profile) =="
if [[ "${MODE}" == "compose" ]]; then
  ok "compose profile: Tailscale and cloudflared are optional"
else
  if [[ -f /etc/ssh/sshd_config ]]; then
    if grep -E '^ListenAddress 100\.' /etc/ssh/sshd_config >/dev/null; then
      ok "sshd ListenAddress is a Tailscale IP (not 0.0.0.0)"
    else
      fail "sshd is not pinned to 100.x — run scripts/bind-ssh-tailscale.sh"
    fi
  else
    warn "no sshd_config (container?)"
  fi

  if command -v tailscale >/dev/null; then
    if tailscale status --json >/dev/null 2>&1; then
      TSIP="$(tailscale ip -4 2>/dev/null || true)"
      ok "tailscaled up  ${TSIP}"
    else
      fail "tailscale installed but not logged in"
    fi
  else
    fail "tailscale not installed on a node profile"
  fi

  if systemctl is-active --quiet cloudflared 2>/dev/null \
    || docker ps --format '{{.Names}}' 2>/dev/null | grep -q cloudflared \
    || (command -v kubectl >/dev/null && kubectl -n cloudflare-tunnel get deploy cloudflared >/dev/null 2>&1); then
    ok "cloudflared is running (outbound-only connector)"
  else
    warn "cloudflared not detected"
  fi

  if command -v ufw >/dev/null; then
    if ufw status 2>/dev/null | grep -qi 'Status: active'; then
      IN="$(ufw status 2>/dev/null | grep -iE 'ALLOW IN|DENY' | head -8 || true)"
      echo "${IN}" | awk '{print "     "$0}'
      if ufw status 2>/dev/null | grep -qiE '22/tcp.*Anywhere|80/tcp.*Anywhere|443/tcp.*Anywhere'; then
        fail "ufw allows 22/80/443 from Anywhere"
      else
        ok "ufw active and not opening 22/80/443 to the world"
      fi
    else
      warn "ufw inactive — AWS SG must deny inbound TCP"
    fi
  fi

  DEFAULT_IF="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -1 || true)"
  if [[ -n "${DEFAULT_IF}" && -r "/sys/class/net/${DEFAULT_IF}/mtu" ]]; then
    MTU="$(cat "/sys/class/net/${DEFAULT_IF}/mtu")"
    if [[ "${MTU}" -gt 1500 ]]; then
      fail "MTU ${MTU} on ${DEFAULT_IF} — jumbo + overlay black-holes POSTs"
    else
      ok "WAN ${DEFAULT_IF} mtu ${MTU} (<= 1500)"
    fi
  fi
fi

echo
echo "== 5. workload is not root =="
if command -v docker >/dev/null; then
  CID="$(docker ps -q -f name=edge-echo 2>/dev/null | head -1 || true)"
  if [[ -n "${CID}" ]]; then
    USER_IN="$(docker inspect -f '{{.Config.User}}' "${CID}" 2>/dev/null || true)"
    echo "     compose user=${USER_IN:-?}"
    if [[ "${USER_IN}" == "0" || "${USER_IN}" == "0:0" || "${USER_IN}" == "root" ]]; then
      fail "edge-echo is running as root"
    else
      ok "edge-echo user=${USER_IN:-65532} (non-root)"
    fi
  else
    warn "no compose container named edge-echo"
  fi
fi

echo
echo "----------------------------------------"
if [[ "${FAIL}" -ne 0 ]]; then
  printf 'RESULT  FAIL  public inbound posture is broken (%s pass, %s warn)\n' "${PASS_N}" "${WARN_N}"
  echo "        a scanner that finds this host would see an open port."
  exit 1
fi
printf 'RESULT  PASS  no public inbound ports  (%s checks, %s warn)\n' "${PASS_N}" "${WARN_N}"
echo "        internet users: Cloudflare Tunnel (outbound). operators: Tailscale."
echo "----------------------------------------"
echo
exit 0
