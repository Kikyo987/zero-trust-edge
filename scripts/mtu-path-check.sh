#!/usr/bin/env bash
# Probe path MTU with DF set. The first size that fails is the ceiling.
# 1472 payload + 28 byte ICMP/IP header = 1500. If 1472 fails and 1200
# works, you have an overlay or a filter dropping dest-unreach.
set -euo pipefail

TARGET="${1:-1.1.1.1}"
SIZES=(1200 1280 1372 1400 1452 1472)

echo "DF ping to ${TARGET} (payload sizes: ${SIZES[*]})"
echo "A timeout at 1472 with success at 1200 is the POST-hang signature."
echo

FAIL=0
for s in "${SIZES[@]}"; do
  if ping -M do -n -c 2 -W 2 -s "${s}" "${TARGET}" >/dev/null 2>&1; then
    printf '  %4d  OK\n' "${s}"
  else
    printf '  %4d  FAIL\n' "${s}"
    FAIL=1
  fi
done

echo
if [[ "${FAIL}" -ne 0 ]]; then
  echo "one or more sizes failed. If 1472 is among them:"
  echo "  ip link set <wan-if> mtu 1500"
  echo "  allow ICMP type 3 (dest-unreach) inbound on SG/NACL"
  echo "  see docs/postmortem-example.md"
  exit 1
fi
echo "path to ${TARGET} carries 1500-byte ICMP with DF. Good."
