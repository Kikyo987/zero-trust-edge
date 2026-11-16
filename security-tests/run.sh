#!/usr/bin/env bash
# Security checks for the dual-plane edge.
#
#   sudo ./security-tests/run.sh --lab
#   sudo ./security-tests/run.sh --production
#
# --lab builds network namespaces on this machine and writes
# security-tests/reports/latest.md. It does not scan a public address
# and it does not call Cloudflare or Tailscale.
#
# --production runs only what ZTE_* variables point at. Missing
# variables are SKIP, not PASS. See security-tests/README.md.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="lab"
for arg in "$@"; do
  case "${arg}" in
    --lab) MODE="lab" ;;
    --production) MODE="production" ;;
    -h|--help)
      sed -n '2,16p' "$0"
      exit 0
      ;;
    *)
      echo "unknown argument: ${arg}" >&2
      exit 2
      ;;
  esac
done

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo -E -- "$0" "$@"
fi

cd "${ROOT}"
python3 security-tests/lab/run_lab.py --mode "${MODE}" --out security-tests/reports/latest.md
