#!/usr/bin/env bash
# Bind sshd to the Tailscale IP only. After this, even a mistaken host
# firewall hole on :22 does not expose SSH on the public address.
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "run as root" >&2
  exit 1
fi

TS_IP="$(ip -4 addr show tailscale0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 || true)"
if [[ -z "${TS_IP}" ]]; then
  echo "tailscale0 has no IPv4. Run tailscale up first." >&2
  exit 1
fi

CONF=/etc/ssh/sshd_config
if grep -qE '^ListenAddress ' "${CONF}"; then
  sed -i "s/^ListenAddress .*/ListenAddress ${TS_IP}/" "${CONF}"
else
  echo "ListenAddress ${TS_IP}" >>"${CONF}"
fi

# Keep a loopback listener so local scripts and cloud-init still work.
if ! grep -q 'ListenAddress 127.0.0.1' "${CONF}"; then
  echo "ListenAddress 127.0.0.1" >>"${CONF}"
fi

sshd -t
systemctl reload ssh || systemctl reload sshd
echo "sshd now listens on ${TS_IP} and 127.0.0.1"
ss -lnt | grep ':22' || true
