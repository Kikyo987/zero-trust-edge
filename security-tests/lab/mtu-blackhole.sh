#!/usr/bin/env bash
# Reproduce a path-MTU black hole in network namespaces.
#
# A 1280-byte hop sits between two 1500-byte endpoints. ICMP
# fragmentation-needed is dropped on the router, so a small GET completes
# and an 8 KB POST stalls. Restoring the ICMP message lets the POST through.
#
# This is a lab. It is not a record of a production outage.
#
#   sudo ./security-tests/lab/mtu-blackhole.sh
#
# Writes docs/evidence/mtu-lab/transcript.txt and pmtud-blackhole.pcap.
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo -E -- "$0" "$@"
fi

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ROOT}/docs/evidence/mtu-lab"
mkdir -p "${OUT}"
TRANSCRIPT="${OUT}/transcript.txt"
PCAP="${OUT}/pmtud-blackhole.pcap"
: > "${TRANSCRIPT}"

log() {
  printf '%s\n' "$*" | tee -a "${TRANSCRIPT}"
}

ns() {
  local name="$1"
  shift
  log "$ ip netns exec ${name} $*"
  # set -e is global. Restore whatever the caller had, so a ping that
  # is expected to fail does not abort the lab.
  local errexit=0 rc
  case $- in *e*) errexit=1 ;; esac
  set +e
  ip netns exec "${name}" "$@" 2>&1 | tee -a "${TRANSCRIPT}"
  rc="${PIPESTATUS[0]}"
  if [[ "${errexit}" -eq 1 ]]; then
    set -e
  fi
  return "${rc}"
}

cleanup() {
  ip netns del mtu-c 2>/dev/null || true
  ip netns del mtu-r 2>/dev/null || true
  ip netns del mtu-s 2>/dev/null || true
}
trap cleanup EXIT
cleanup

log "lab reproduction: PMTUD black hole"
log "host: $(hostname) kernel: $(uname -r)"
log "class: LAB. Not a production incident."
log "utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log

ip netns add mtu-c
ip netns add mtu-r
ip netns add mtu-s
ip link add c-v type veth peer name c-r
ip link add s-v type veth peer name s-r
ip link set c-v netns mtu-c
ip link set c-r netns mtu-r
ip link set s-v netns mtu-s
ip link set s-r netns mtu-r

ip netns exec mtu-c ip link set lo up
ip netns exec mtu-r ip link set lo up
ip netns exec mtu-s ip link set lo up
ip netns exec mtu-c ip addr add 10.88.0.2/24 dev c-v
ip netns exec mtu-c ip link set c-v mtu 1500 up
ip netns exec mtu-c ip route add default via 10.88.0.1
ip netns exec mtu-r ip addr add 10.88.0.1/24 dev c-r
ip netns exec mtu-r ip link set c-r mtu 1500 up
ip netns exec mtu-r ip addr add 10.88.1.1/24 dev s-r
ip netns exec mtu-r ip link set s-r mtu 1280 up
ip netns exec mtu-r sysctl -w net.ipv4.ip_forward=1 >/dev/null
ip netns exec mtu-s ip addr add 10.88.1.2/24 dev s-v
ip netns exec mtu-s ip link set s-v mtu 1500 up
ip netns exec mtu-s ip route add default via 10.88.1.1

# Server reads the POST body, then answers. A black-holed body never returns.
ip netns exec mtu-s python3 - <<'PY' &
import socket
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("10.88.1.2", 8080))
s.listen(8)
s.settimeout(40)
while True:
    try:
        c, _ = s.accept()
    except socket.timeout:
        break
    c.settimeout(8)
    try:
        data = b""
        while b"\r\n\r\n" not in data and len(data) < 65536:
            chunk = c.recv(4096)
            if not chunk:
                break
            data += chunk
        head, _, rest = data.partition(b"\r\n\r\n")
        length = 0
        for line in head.split(b"\r\n"):
            if line.lower().startswith(b"content-length:"):
                length = int(line.split(b":", 1)[1].strip())
        while len(rest) < length:
            chunk = c.recv(length - len(rest))
            if not chunk:
                break
            rest += chunk
        body = b"ready"
        c.sendall(b"HTTP/1.0 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\n" + body)
    except OSError:
        pass
    finally:
        c.close()
PY
SERVER_PID=$!
sleep 0.3

log
log "== link MTUs =="
ns mtu-c ip link show c-v
ns mtu-r ip link show c-r
ns mtu-r ip link show s-r
ns mtu-s ip link show s-v

log
log "== black hole: drop ICMP fragmentation-needed on the router =="
ip netns exec mtu-r iptables -I OUTPUT -p icmp --icmp-type fragmentation-needed -j DROP
ip netns exec mtu-r iptables -I FORWARD -p icmp --icmp-type fragmentation-needed -j DROP
ns mtu-r iptables -S

log
log "== DF pings while ICMP is dropped =="
log "(1200+28 fits in 1280; 1400+28 does not, and the sender never hears why)"
set +e
ns mtu-c ping -M do -n -c 2 -W 2 -s 1200 10.88.1.2
ns mtu-c ping -M do -n -c 2 -W 2 -s 1400 10.88.1.2
set -e

log
log "== small GET (should complete) =="
ns mtu-c curl -sS -m 4 -D - -o /dev/null http://10.88.1.2:8080/healthz

log
log "== 8 KB POST while ICMP is dropped (should stall) =="
dd if=/dev/zero bs=8192 count=1 of=/tmp/zte-post.bin status=none
rm -f "${PCAP}"
ip netns exec mtu-r timeout 8 tcpdump -ni c-r -w "${PCAP}" -c 40 >/tmp/zte-mtu-tcpdump.txt 2>&1 &
TCPDUMP_PID=$!
sleep 0.4
set +e
ns mtu-c curl -sS -m 4 -D - -o /tmp/zte-mtu-post-body --data-binary @/tmp/zte-post.bin http://10.88.1.2:8080/readyz
POST_RC=$?
set -e
log "curl exit ${POST_RC} (28 is the curl timeout)"
wait "${TCPDUMP_PID}" 2>/dev/null || true
log
log "== tcpdump during the stalled POST (lab capture) =="
if [[ -s "${PCAP}" ]]; then
  tcpdump -n -r "${PCAP}" >> "${TRANSCRIPT}" 2>&1 || true
else
  log "pcap was empty"
  cat /tmp/zte-mtu-tcpdump.txt >> "${TRANSCRIPT}" || true
fi

log
log "== restore ICMP fragmentation-needed =="
ip netns exec mtu-r iptables -D OUTPUT -p icmp --icmp-type fragmentation-needed -j DROP
ip netns exec mtu-r iptables -D FORWARD -p icmp --icmp-type fragmentation-needed -j DROP
log
log "== DF ping 1400 after ICMP is restored (expect 'Frag needed' or a reply, not a silent timeout) =="
set +e
ns mtu-c ping -M do -n -c 1 -W 2 -s 1400 10.88.1.2
set -e
log
log "== 8 KB POST after ICMP is restored (should complete) =="
set +e
ns mtu-c curl -sS -m 8 -D - -o /tmp/zte-mtu-post-body2 --data-binary @/tmp/zte-post.bin http://10.88.1.2:8080/readyz
POST2_RC=$?
set -e
log "curl exit ${POST2_RC}"
log "body: $(cat /tmp/zte-mtu-post-body2 2>/dev/null || true)"

kill "${SERVER_PID}" 2>/dev/null || true
wait "${SERVER_PID}" 2>/dev/null || true

log
log "pcap: ${PCAP}"
log "transcript: ${TRANSCRIPT}"
if [[ "${POST_RC}" -eq 0 ]]; then
  log "UNEXPECTED: the black-holed POST completed. The lab did not reproduce the stall."
  exit 1
fi
if [[ "${POST2_RC}" -ne 0 ]]; then
  log "UNEXPECTED: the POST still failed after ICMP was restored."
  exit 1
fi
log "RESULT PASS  GET ok, 8KB POST stalled without ICMP frag-needed, POST recovered after restore"
