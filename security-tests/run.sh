#!/usr/bin/env bash
# Security checks for the dual-plane edge.
#
#   sudo ./security-tests/run.sh --lab
#   sudo env ZTE_NODE_PUBLIC_IP=203.0.113.50 ./security-tests/run.sh --production
#
# --lab builds network namespaces on this machine and writes
# security-tests/reports/latest.md. It does not scan a public address
# and it does not call Cloudflare or Tailscale.
#
# --production runs only what ZTE_* variables point at. Missing
# variables are SKIP, not PASS. See security-tests/README.md.
#
# Do not use `sudo -E`. Some Ubuntu sudo builds ignore -E and drop the
# variables. This script passes each set ZTE_* value on the sudo command
# line via `env`, and refuses production mode if one of them disappears.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="lab"
for arg in "$@"; do
  case "${arg}" in
    --lab) MODE="lab" ;;
    --production) MODE="production" ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      echo "unknown argument: ${arg}" >&2
      exit 2
      ;;
  esac
done

# Names the production path reads. KUBECONFIG is included because a
# dropped kubeconfig would turn a live cluster check into a silent SKIP.
ZTE_NAMES=(
  ZTE_NODE_PUBLIC_IP
  ZTE_APP_URL
  ZTE_USER_SSH_TARGET
  ZTE_CI_GRAFANA_URL
  ZTE_CI_SSH_TARGET
  ZTE_APPLY_NETPOL
  KUBECONFIG
)

if [[ "${EUID}" -ne 0 ]]; then
  env_args=()
  expect=""
  for name in "${ZTE_NAMES[@]}"; do
    if [[ -n "${!name:-}" ]]; then
      env_args+=("${name}=${!name}")
      expect="${expect:+${expect},}${name}"
    fi
  done
  if [[ -n "${expect}" ]]; then
    env_args+=("ZTE_EXPECT_VARS=${expect}")
  fi
  exec sudo -- env "${env_args[@]}" "$0" "$@"
fi

if [[ "${MODE}" == "production" && -n "${ZTE_EXPECT_VARS:-}" ]]; then
  IFS=',' read -ra _zte_expected <<< "${ZTE_EXPECT_VARS}"
  missing=0
  for name in "${_zte_expected[@]}"; do
    if [[ -z "${!name:-}" ]]; then
      echo "production mode refused: ${name} was set before privilege escalation and is empty now." >&2
      missing=1
    fi
  done
  if [[ "${missing}" -ne 0 ]]; then
    echo "Re-run with: sudo env ZTE_NODE_PUBLIC_IP=<ip> $0 --production" >&2
    echo "Do not rely on sudo -E. This Ubuntu family can ignore it." >&2
    exit 2
  fi
fi

cd "${ROOT}"
python3 security-tests/lab/run_lab.py --mode "${MODE}" --out security-tests/reports/latest.md
