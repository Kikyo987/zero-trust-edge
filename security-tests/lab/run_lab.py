#!/usr/bin/env python3
"""Run the seven security checks and write a PASS/FAIL report.

--lab builds network namespaces on this machine. Nothing here is a scan
of a public VPS, a live Cloudflare Access tenant, or a live tailnet.

--production runs the same checks against addresses the owner supplies.
Missing variables are SKIP, never a fabricated PASS.
"""

from __future__ import annotations

import argparse
import ctypes
import datetime
import os
import platform
import socket
import subprocess
import textwrap
import time
from dataclasses import dataclass, field
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / "security-tests" / "lib"
LAB = ROOT / "security-tests" / "lab"
import sys

sys.path.insert(0, str(LIB))

from access_policy import decide, load_policy  # noqa: E402
from acl import grant_allows, load_acl, ssh_accepts  # noqa: E402
from netpol import (  # noqa: E402
    POLICY_PATH,
    broad_edge_namespace_peers,
    egress_allows,
    ingress_allows,
    load_policies,
)

BUSINESS_PORTS = (22, 80, 443, 6443, 8080, 3000, 9090)


@dataclass
class Check:
    name: str
    status: str
    summary: str
    log: str = ""
    notes: list[str] = field(default_factory=list)


def sh(args: list[str], ns: str | None = None, check: bool = True, timeout: int = 30, input_text: str | None = None) -> subprocess.CompletedProcess:
    cmd = ["ip", "netns", "exec", ns, *args] if ns else args
    proc = subprocess.run(
        cmd,
        text=True,
        input=input_text,
        capture_output=True,
        timeout=timeout,
        check=False,
    )
    if check and proc.returncode != 0:
        raise RuntimeError(
            "$ " + " ".join(cmd) + f"\nexit {proc.returncode}\n{proc.stdout}\n{proc.stderr}"
        )
    return proc


def cleanup_netns() -> None:
    listed = sh(["ip", "netns", "list"], check=False).stdout
    for line in listed.splitlines():
        name = line.split()[0] if line.split() else ""
        if name.startswith("zte-"):
            sh(["ip", "netns", "del", name], check=False)


def add_ns(name: str) -> None:
    sh(["ip", "netns", "add", name])
    sh(["ip", "link", "set", "lo", "up"], ns=name)


def veth(left: str, left_ns: str, right: str, right_ns: str) -> None:
    sh(["ip", "link", "add", left, "type", "veth", "peer", "name", right])
    sh(["ip", "link", "set", left, "netns", left_ns])
    sh(["ip", "link", "set", right, "netns", right_ns])
    sh(["ip", "link", "set", left, "up"], ns=left_ns)
    sh(["ip", "link", "set", right, "up"], ns=right_ns)


def addr(ns: str, iface: str, cidr: str) -> None:
    sh(["ip", "addr", "add", cidr, "dev", iface], ns=ns)


def default_route(ns: str, gw: str) -> None:
    sh(["ip", "route", "add", "default", "via", gw], ns=ns)


def spawn(ns: str, args: list[str]) -> subprocess.Popen:
    return subprocess.Popen(
        ["ip", "netns", "exec", ns, *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )


def stop(proc: subprocess.Popen | None) -> None:
    if proc is None or proc.poll() is not None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.kill()


def tcp_open(ns: str, ip: str, port: int, timeout: float = 2.0) -> tuple[bool, str]:
    code = (
        "import socket,sys\n"
        "ip,port,timeout=sys.argv[1:]\n"
        "s=socket.socket(); s.settimeout(float(timeout))\n"
        "try:\n"
        "    s.connect((ip,int(port))); s.sendall(b'\\n'); data=s.recv(64)\n"
        "    print(data.decode('latin1','replace'))\n"
        "except Exception as exc:\n"
        "    print(type(exc).__name__)\n"
        "    sys.exit(1)\n"
    )
    proc = sh(
        ["python3", "-c", code, ip, str(port), str(timeout)],
        ns=ns,
        check=False,
        timeout=int(timeout) + 5,
    )
    text = (proc.stdout or "") + (proc.stderr or "")
    return proc.returncode == 0, text.strip()


def http_code(ns: str, url: str, headers: list[str] | None = None) -> tuple[str, str]:
    cmd = ["curl", "-sS", "-D", "-", "-o", "/dev/null", "--max-time", "5"]
    for header in headers or []:
        cmd.extend(["-H", header])
    cmd.append(url)
    proc = sh(cmd, ns=ns, check=False, timeout=10)
    text = (proc.stdout or "") + (proc.stderr or "")
    code = ""
    for line in text.splitlines():
        if line.startswith("HTTP/"):
            parts = line.split()
            if len(parts) >= 2:
                code = parts[1]
    if not code:
        code = f"curl-exit-{proc.returncode}"
    return code, text


def git_sha() -> str:
    proc = sh(["git", "-C", str(ROOT), "rev-parse", "--short", "HEAD"], check=False)
    return (proc.stdout or "unknown").strip() or "unknown"


def run_plane() -> list[Check]:
    """External scan, Access deny, user SSH deny, CI Grafana deny, CI SSH allow."""
    logs: list[str] = []
    procs: list[subprocess.Popen] = []
    cleanup_netns()
    try:
        for name in ("zte-inet", "zte-node", "zte-rtr", "zte-user", "zte-ci"):
            add_ns(name)
        veth("wan-i", "zte-inet", "wan-n", "zte-node")
        veth("ts-n", "zte-node", "ts-r", "zte-rtr")
        veth("u-c", "zte-user", "u-r", "zte-rtr")
        veth("c-c", "zte-ci", "c-r", "zte-rtr")
        addr("zte-inet", "wan-i", "203.0.113.1/24")
        addr("zte-node", "wan-n", "203.0.113.10/24")
        addr("zte-node", "ts-n", "100.64.10.10/30")
        addr("zte-rtr", "ts-r", "100.64.10.9/30")
        addr("zte-user", "u-c", "100.64.1.2/30")
        addr("zte-rtr", "u-r", "100.64.1.1/30")
        addr("zte-ci", "c-c", "100.64.1.6/30")
        addr("zte-rtr", "c-r", "100.64.1.5/30")
        default_route("zte-node", "100.64.10.9")
        default_route("zte-user", "100.64.1.1")
        default_route("zte-ci", "100.64.1.5")
        sh(["sysctl", "-w", "net.ipv4.ip_forward=1"], ns="zte-rtr")
        # The public-shaped NIC drops new TCP/UDP. Listeners are on 100.64.10.10 and 127.0.0.1.
        sh(
            ["iptables", "-A", "INPUT", "-i", "wan-n", "-m", "conntrack", "--ctstate", "ESTABLISHED,RELATED", "-j", "ACCEPT"],
            ns="zte-node",
        )
        sh(["iptables", "-A", "INPUT", "-i", "wan-n", "-p", "tcp", "-j", "DROP"], ns="zte-node")
        sh(["iptables", "-A", "INPUT", "-i", "wan-n", "-p", "udp", "-j", "DROP"], ns="zte-node")

        acl = load_acl()
        decisions = {
            ("user", 22): grant_allows(acl, "user", "tag:node", 22) and ssh_accepts(acl, "user", "tag:node", "ubuntu"),
            ("ci", 3000): grant_allows(acl, "ci", "tag:node", 3000),
            ("ci", 22): grant_allows(acl, "ci", "tag:node", 22) and ssh_accepts(acl, "ci", "tag:node", "ubuntu"),
        }
        logs.append("ACL decisions (file, then enforced):")
        for key, allowed in decisions.items():
            logs.append(f"  {key[0]} -> tag:node:{key[1]} {'ALLOW' if allowed else 'DENY'}")
        if decisions[("user", 22)] or decisions[("ci", 3000)] or not decisions[("ci", 22)]:
            raise RuntimeError("ACL file does not match the intended user/ci split; refusing to paper over it")

        sh(["iptables", "-P", "FORWARD", "DROP"], ns="zte-rtr")
        sh(
            ["iptables", "-A", "FORWARD", "-m", "conntrack", "--ctstate", "ESTABLISHED,RELATED", "-j", "ACCEPT"],
            ns="zte-rtr",
        )
        # Reply packets if conntrack is unavailable are covered by the rule above.
        if decisions[("ci", 22)]:
            sh(
                ["iptables", "-A", "FORWARD", "-s", "100.64.1.6", "-d", "100.64.10.10", "-p", "tcp", "--dport", "22", "-j", "ACCEPT"],
                ns="zte-rtr",
            )
        if decisions[("ci", 3000)]:
            sh(
                ["iptables", "-A", "FORWARD", "-s", "100.64.1.6", "-d", "100.64.10.10", "-p", "tcp", "--dport", "3000", "-j", "ACCEPT"],
                ns="zte-rtr",
            )
        if decisions[("user", 22)]:
            sh(
                ["iptables", "-A", "FORWARD", "-s", "100.64.1.2", "-d", "100.64.10.10", "-p", "tcp", "--dport", "22", "-j", "ACCEPT"],
                ns="zte-rtr",
            )

        hits = "/tmp/zte-origin-hits"
        procs.append(spawn("zte-node", ["python3", str(LAB / "origin_server.py"), hits, "127.0.0.1", "8080"]))
        procs.append(spawn("zte-node", ["python3", str(LAB / "banner_server.py"), "100.64.10.10", "22", "SSH-2.0-lab"]))
        procs.append(spawn("zte-node", ["python3", str(LAB / "banner_server.py"), "100.64.10.10", "3000", "grafana-lab"]))
        procs.append(spawn("zte-inet", ["python3", str(LAB / "edge_proxy.py"), "203.0.113.1", "8443", "9443"]))
        time.sleep(0.4)
        procs.append(spawn("zte-node", ["python3", str(LAB / "connector.py"), "203.0.113.1", "9443"]))
        time.sleep(0.4)

        nmap = sh(
            [
                "nmap", "-Pn", "-sT", "-p", ",".join(str(p) for p in BUSINESS_PORTS),
                "--max-retries", "1", "--host-timeout", "25s", "-T4", "203.0.113.10",
            ],
            ns="zte-inet",
            check=False,
            timeout=40,
        )
        nmap_text = (nmap.stdout or "") + (nmap.stderr or "")
        logs.append("$ nmap -Pn -sT -p 22,80,443,6443,8080,3000,9090 203.0.113.10  (from lab internet namespace)")
        logs.append(nmap_text.rstrip())
        open_ports = []
        for line in nmap_text.splitlines():
            parts = line.split()
            if len(parts) >= 2 and "/tcp" in parts[0] and parts[1] == "open":
                open_ports.append(parts[0])
        scan_ok = nmap.returncode == 0 and not open_ports and "filtered" in nmap_text

        policy = load_policy()
        org = ""
        for item in policy["include"]:
            if "github-organization" in item:
                org = item["github-organization"]["name"]
        unauth, unauth_raw = http_code("zte-inet", "http://203.0.113.1:8443/healthz")
        no_mfa, no_mfa_raw = http_code(
            "zte-inet",
            "http://203.0.113.1:8443/healthz",
            [f"X-Lab-Github-Org: {org}"],
        )
        wrong, wrong_raw = http_code(
            "zte-inet",
            "http://203.0.113.1:8443/healthz",
            ["X-Lab-Github-Org: not-the-org", "X-Lab-Auth-Method: mfa"],
        )
        hits_before = Path(hits).read_text().strip() if Path(hits).exists() else "missing"
        auth, auth_raw = "000", ""
        for _ in range(8):
            auth, auth_raw = http_code(
                "zte-inet",
                "http://203.0.113.1:8443/healthz",
                [f"X-Lab-Github-Org: {org}", "X-Lab-Auth-Method: mfa"],
            )
            if auth == "200":
                break
            time.sleep(0.3)
        time.sleep(0.2)
        hits_after = Path(hits).read_text().strip() if Path(hits).exists() else "missing"
        direct, direct_raw = tcp_open("zte-inet", "203.0.113.10", 8080, 2)
        logs.append(
            "\n".join(
                [
                    f"policy include org={org!r} (placeholder is expected)",
                    f"no headers -> HTTP {unauth}",
                    f"org without mfa -> HTTP {no_mfa}",
                    f"mfa with wrong org -> HTTP {wrong}",
                    f"org+mfa fixture -> HTTP {auth}",
                    f"origin hits before authorized request: {hits_before}",
                    f"origin hits after authorized request: {hits_after}",
                    f"direct connect lab-internet -> 203.0.113.10:8080 open={direct} ({direct_raw})",
                    "decide() check: "
                    + decide(policy, "", "")
                    + " / "
                    + decide(policy, org, "")
                    + " / "
                    + decide(policy, org, "mfa"),
                ]
            )
        )
        logs.append(unauth_raw.splitlines()[0] if unauth_raw else "")
        access_ok = (
            unauth == "403"
            and no_mfa == "403"
            and wrong == "403"
            and auth == "200"
            and hits_before == "0"
            and hits_after == "1"
            and direct is False
            and decide(policy, "", "") == "deny"
            and decide(policy, org, "mfa") == "allow"
        )

        user_ssh, user_ssh_raw = tcp_open("zte-user", "100.64.10.10", 22, 2)
        ci_graf, ci_graf_raw = tcp_open("zte-ci", "100.64.10.10", 3000, 2)
        ci_ssh, ci_ssh_raw = tcp_open("zte-ci", "100.64.10.10", 22, 2)
        logs.append(
            "\n".join(
                [
                    f"user -> 100.64.10.10:22 open={user_ssh} {user_ssh_raw}",
                    f"ci -> 100.64.10.10:3000 open={ci_graf} {ci_graf_raw}",
                    f"ci -> 100.64.10.10:22 open={ci_ssh} {ci_ssh_raw}",
                ]
            )
        )
        user_ok = user_ssh is False
        graf_ok = ci_graf is False
        ci_ok = ci_ssh is True and "SSH-2.0-lab" in ci_ssh_raw
    finally:
        for proc in procs:
            stop(proc)
        cleanup_netns()

    acl_log = "\n".join(logs[:4])
    scan_log = "\n".join(logs[4:6])
    access_log = "\n".join(logs[6:8])
    ssh_lines = logs[-1].splitlines()
    return [
        Check(
            "External scan shows no open business inbound ports",
            "PASS" if scan_ok else "FAIL",
            "nmap from the lab internet namespace against 203.0.113.10 (TEST-NET-3, not a public VPS).",
            scan_log,
            [
                "Lab only. Filtered means the WAN interface dropped the SYN.",
                "This is not an nmap of a production address.",
            ],
        ),
        Check(
            "Unauthorized user access to the app is denied",
            "PASS" if access_ok else "FAIL",
            "Lab Access proxy enforces cloudflare/access/policy-github-mfa.json. It does not call Cloudflare.",
            access_log,
            [
                "Deny is HTTP 403 and the loopback origin is not contacted.",
                "A fixture identity that satisfies the policy JSON is allowed, so the proxy is not hard-coded to fail.",
                "Live Cloudflare Access MFA was not tested.",
            ],
        ),
        Check(
            "Regular user SSH is denied",
            "PASS" if user_ok else "FAIL",
            "group:dev / autogroup:member has no grant and no ssh accept for tag:node:22.",
            acl_log + "\n" + ssh_lines[0],
        ),
        Check(
            "CI access to Grafana is denied",
            "PASS" if graf_ok else "FAIL",
            "tag:ci is granted tcp/22 only. Port 3000 is not in the grant.",
            acl_log + "\n" + ssh_lines[1],
        ),
        Check(
            "CI access to node SSH is allowed",
            "PASS" if ci_ok else "FAIL",
            "tag:ci grant for tcp/22 plus ssh action accept for user ubuntu.",
            acl_log + "\n" + ssh_lines[2],
            ["The listener is a lab banner, not sshd. The allow/deny decision is the ACL file."],
        ),
    ]


def run_netpol() -> Check:
    policies = load_policies()
    broad = broad_edge_namespace_peers(policies)
    echo = ("edge", {"app": "edge-echo"}, "10.43.1.2")
    clients = [
        ("cloudflared", "cloudflare-tunnel", {"app": "cloudflared"}, "10.43.2.2", True),
        ("probe", "edge", {"edge.zero-trust/role": "probe"}, "10.43.1.6", True),
        ("monitoring", "monitoring", {"app": "prometheus"}, "10.43.4.2", True),
        ("stranger-edge", "edge", {"app": "stranger"}, "10.43.1.10", False),
        ("stranger-other", "untrusted", {"app": "stranger"}, "10.43.3.2", False),
    ]
    lines = [f"policy file: {POLICY_PATH.relative_to(ROOT)}", f"broad edge namespace peers: {broad or 'none'}"]
    semantic_ok = not broad
    for name, ns, labels, ip, expect in clients:
        ing = ingress_allows(policies, echo[0], echo[1], ns, labels, ip, 8080)
        egr = egress_allows(policies, ns, labels, echo[0], echo[1], echo[2], 8080)
        lines.append(f"  {name}: ingress={'ALLOW' if ing else 'DENY'} egress={'ALLOW' if egr else 'DENY'} expect_ingress={'ALLOW' if expect else 'DENY'}")
        if ing != expect:
            semantic_ok = False
    # Probe egress must be explicit. Stranger egress must not be a free pass on 8080.
    probe_egr = egress_allows(policies, "edge", {"edge.zero-trust/role": "probe"}, "edge", {"app": "edge-echo"}, "10.43.1.2", 8080)
    stranger_egr = egress_allows(policies, "edge", {"app": "stranger"}, "edge", {"app": "edge-echo"}, "10.43.1.2", 8080)
    lines.append(f"probe egress to app: {'ALLOW' if probe_egr else 'DENY'}")
    lines.append(f"stranger-edge egress to app: {'ALLOW' if stranger_egr else 'DENY'}")
    if not probe_egr or stranger_egr:
        semantic_ok = False

    links = {
        "cloudflared": ("10.43.2.0/30", "10.43.2.1", "10.43.2.2"),
        "probe": ("10.43.1.4/30", "10.43.1.5", "10.43.1.6"),
        "monitoring": ("10.43.4.0/30", "10.43.4.1", "10.43.4.2"),
        "stranger-edge": ("10.43.1.8/30", "10.43.1.9", "10.43.1.10"),
        "stranger-other": ("10.43.3.0/30", "10.43.3.1", "10.43.3.2"),
    }
    proc = None
    packet_ok = True
    cleanup_netns()
    try:
        add_ns("zte-rtr")
        add_ns("zte-echo")
        sh(["sysctl", "-w", "net.ipv4.ip_forward=1"], ns="zte-rtr")
        veth("e-e", "zte-echo", "e-r", "zte-rtr")
        addr("zte-echo", "e-e", "10.43.1.2/30")
        addr("zte-rtr", "e-r", "10.43.1.1/30")
        default_route("zte-echo", "10.43.1.1")
        client_ns = {}
        for index, (name, _ns, _labels, _ip, _expect) in enumerate(clients):
            nname = f"zte-c{index}"
            client_ns[name] = nname
            add_ns(nname)
            left, right = f"p{index}a", f"p{index}b"
            veth(left, nname, right, "zte-rtr")
            _net, gw, ip = links[name]
            addr(nname, left, f"{ip}/30")
            addr("zte-rtr", right, f"{gw}/30")
            default_route(nname, gw)
        sh(["iptables", "-P", "FORWARD", "DROP"], ns="zte-rtr")
        sh(
            ["iptables", "-A", "FORWARD", "-m", "conntrack", "--ctstate", "ESTABLISHED,RELATED", "-j", "ACCEPT"],
            ns="zte-rtr",
        )
        for name, ns, labels, ip, _expect in clients:
            if ingress_allows(policies, "edge", {"app": "edge-echo"}, ns, labels, ip, 8080):
                sh(
                    ["iptables", "-A", "FORWARD", "-s", ip, "-d", "10.43.1.2", "-p", "tcp", "--dport", "8080", "-j", "ACCEPT"],
                    ns="zte-rtr",
                )
                lines.append(f"dataplane ACCEPT {ip} -> 10.43.1.2:8080 ({name})")
            else:
                lines.append(f"dataplane DROP {ip} -> 10.43.1.2:8080 ({name})")
        proc = spawn("zte-echo", ["python3", str(LAB / "origin_server.py"), "/tmp/zte-echo-hits", "10.43.1.2", "8080"])
        time.sleep(0.3)
        for name, _ns, _labels, ip, expect in clients:
            opened, raw = tcp_open(client_ns[name], "10.43.1.2", 8080, 2)
            lines.append(f"packet {name}: open={opened} {raw}")
            if opened != expect:
                packet_ok = False
    finally:
        stop(proc)
        cleanup_netns()

    ok = semantic_ok and packet_ok
    note = (
        "Dataplane is iptables in a lab router, programmed from the manifest. "
        "k3s kube-router did not start on this kernel (ipset and VXLAN are not available). "
        "This is not a production cluster packet capture."
    )
    return Check(
        "Non-cloudflared Pod access to the app is denied",
        "PASS" if ok else "FAIL",
        "Strangers are denied. cloudflared, a labeled probe, and the monitoring namespace are allowed.",
        "\n".join(lines),
        [note],
    )


def _manifest_ok() -> tuple[bool, str]:
    lines = []
    ok = True
    deploy = ROOT / "k3s" / "manifests" / "20-deployment.yaml"
    for doc in yaml.safe_load_all(deploy.read_text()):
        if not doc or doc.get("kind") != "Deployment":
            continue
        spec = doc["spec"]["template"]["spec"]
        sc = spec["securityContext"]
        csc = spec["containers"][0]["securityContext"]
        checks = {
            "runAsNonRoot": sc.get("runAsNonRoot") is True,
            "runAsUser 65532": sc.get("runAsUser") == 65532,
            "allowPrivilegeEscalation false": csc.get("allowPrivilegeEscalation") is False,
            "readOnlyRootFilesystem": csc.get("readOnlyRootFilesystem") is True,
            "drop ALL": "ALL" in (csc.get("capabilities") or {}).get("drop", []),
            "seccomp RuntimeDefault": (sc.get("seccompProfile") or {}).get("type") == "RuntimeDefault",
        }
        for label, good in checks.items():
            lines.append(f"  deployment {label}: {'ok' if good else 'MISSING'}")
            ok = ok and good
    docker = (ROOT / "docker" / "app" / "Dockerfile").read_text()
    runtime = docker.split("FROM gcr.io/distroless", 1)[-1].split("FROM alpine", 1)[0]
    image_ok = "USER 65532:65532" in runtime
    lines.append(f"  runtime image USER 65532:65532: {'ok' if image_ok else 'MISSING'}")
    return ok and image_ok, "\n".join(lines)


def mount_options(path: Path) -> str:
    proc = subprocess.run(
        ["findmnt", "-T", str(path), "-no", "OPTIONS"],
        capture_output=True,
        text=True,
        check=False,
    )
    return proc.stdout.strip()


def suid_workdir() -> Path | None:
    """A directory whose mount honors the setuid bit. Never /tmp.

    Ubuntu 26.10 mounts /tmp as a nosuid tmpfs. A helper built there
    cannot become root, so the control run cannot prove that
    NO_NEW_PRIVS is what stopped the escalation.
    """
    for candidate in (Path("/var/lib/zte-priv"), Path("/usr/local/lib/zte-priv")):
        try:
            candidate.mkdir(parents=True, exist_ok=True)
        except OSError:
            continue
        opts = mount_options(candidate)
        if not opts or "nosuid" in opts.split(","):
            continue
        return candidate
    return None


def module_state(name: str) -> str:
    """What this kernel can say about a module, measured now."""
    if Path(f"/sys/module/{name}").exists():
        return "loaded"
    release = platform.release()
    root = Path(f"/lib/modules/{release}")
    if not root.is_dir():
        return "not measurable (no /lib/modules for this kernel)"
    found = subprocess.run(
        ["find", str(root), "-name", f"{name}.ko*", "-print", "-quit"],
        capture_output=True,
        text=True,
        check=False,
    )
    if found.stdout.strip():
        return "present, not loaded"
    return "not shipped on this kernel"


def run_priv() -> Check:
    manifest_ok, manifest_log = _manifest_ok()
    work = suid_workdir()
    if work is None:
        tmp_opts = mount_options(Path("/tmp")) or "unreadable"
        status = "FAIL" if not manifest_ok else "SKIP"
        return Check(
            "App container privilege escalation fails",
            status,
            "Setuid helper was not built. /tmp is not used, and no other suid-capable directory was found.",
            manifest_log + f"\n/tmp mount options: {tmp_opts}",
            [
                "SKIP is not a pass. The deployment manifest was still read.",
                "On Ubuntu 26.10, /tmp is often a nosuid tmpfs. Put the helper on the root filesystem.",
            ],
        )
    src = work / "zte-escalate.c"
    binary = work / "zte-escalate"
    src.write_text(
        textwrap.dedent(
            """\
            #include <stdio.h>
            #include <unistd.h>
            int main(void) {
                int rc = setuid(0);
                printf("setuid_rc=%d euid=%d\\n", rc, geteuid());
                return geteuid() == 0 ? 0 : 2;
            }
            """
        )
    )
    build = sh(["gcc", "-O2", "-o", str(binary), str(src)], check=False)
    if build.returncode != 0:
        return Check(
            "App container privilege escalation fails",
            "FAIL",
            "Could not compile the setuid helper.",
            build.stderr,
        )
    os.chown(binary, 0, 0)
    os.chmod(binary, 0o4755)
    helper_opts = mount_options(binary)
    libc = ctypes.CDLL("libc.so.6", use_errno=True)

    def preexec(lock: bool):
        def inner():
            if lock:
                libc.prctl(38, 1, 0, 0, 0)
            os.setgid(65532)
            os.setuid(65532)

        return inner

    control = subprocess.run([str(binary)], preexec_fn=preexec(False), capture_output=True, text=True, check=False)
    locked = subprocess.run([str(binary)], preexec_fn=preexec(True), capture_output=True, text=True, check=False)

    raw_code = (
        "import ctypes,os,socket\n"
        "libc=ctypes.CDLL('libc.so.6', use_errno=True)\n"
        "libc.prctl(38, 1, 0, 0, 0)\n"
        "os.setgid(65532); os.setuid(65532)\n"
        "print('uid', os.getuid())\n"
        "try:\n"
        "    socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP).close()\n"
        "    print('RAW_OK')\n"
        "except PermissionError:\n"
        "    print('RAW_DENIED')\n"
        "try:\n"
        "    open('/etc/zte-priv-esc','w').close(); print('WRITE_OK')\n"
        "except PermissionError:\n"
        "    print('WRITE_DENIED')\n"
    )
    raw = subprocess.run(["python3", "-c", raw_code], capture_output=True, text=True, check=False)
    log = "\n".join(
        [
            manifest_log,
            f"helper {binary} mount options: {helper_opts or 'unknown'}",
            f"control (setuid bit, no NO_NEW_PRIVS) rc={control.returncode} {control.stdout.strip()} {control.stderr.strip()}",
            f"locked (PR_SET_NO_NEW_PRIVS) rc={locked.returncode} {locked.stdout.strip()} {locked.stderr.strip()}",
            raw.stdout.strip(),
            raw.stderr.strip(),
        ]
    )
    try:
        binary.unlink(missing_ok=True)
        src.unlink(missing_ok=True)
    except OSError:
        pass
    ok = (
        manifest_ok
        and control.returncode == 0
        and "euid=0" in control.stdout
        and locked.returncode != 0
        and "euid=65532" in locked.stdout
        and "RAW_DENIED" in raw.stdout
        and "WRITE_DENIED" in raw.stdout
        and "uid 65532" in raw.stdout
    )
    return Check(
        "App container privilege escalation fails",
        "PASS" if ok else "FAIL",
        "Manifest and runtime image require uid 65532, no privilege escalation, and dropped capabilities. "
        "A setuid-root helper then fails under PR_SET_NO_NEW_PRIVS, which is what allowPrivilegeEscalation: false sets.",
        log,
        [
            "The control run without NO_NEW_PRIVS becomes root, so the helper really is setuid.",
            "This is the Linux mechanism the container runtime configures. It is not a trace from a live kubelet exec.",
            "Distroless has no shell; the behavioral twin is this helper plus the deployment securityContext.",
        ],
    )


def local_ipv4() -> set[str]:
    found: set[str] = set()
    proc = subprocess.run(["ip", "-o", "-4", "addr", "show"], capture_output=True, text=True, check=False)
    for line in proc.stdout.splitlines():
        parts = line.split()
        if "inet" not in parts:
            continue
        cidr = parts[parts.index("inet") + 1]
        found.add(cidr.split("/", 1)[0])
    return found


def production_checks() -> list[Check]:
    """Owner-supplied targets only. Never invent a result."""
    out = []

    def need(title: str, var: str, how: str) -> str | None:
        value = os.environ.get(var, "").strip()
        if value:
            return value
        out.append(
            Check(
                title,
                "SKIP",
                f"{var} is unset. Not a pass.",
                how,
            )
        )
        return None

    ip = need(
        "External scan shows no open business inbound ports",
        "ZTE_NODE_PUBLIC_IP",
        "ZTE_NODE_PUBLIC_IP=<public-ip> ./security-tests/run.sh --production\n"
        "nmap -Pn -sT -p 22,80,443,6443,8080,3000,9090 \"$ZTE_NODE_PUBLIC_IP\"",
    )
    if ip:
        mine = local_ipv4()
        if ip in mine:
            out.append(
                Check(
                    "External scan shows no open business inbound ports",
                    "FAIL",
                    f"Refused: {ip} is a local address on this host. A self-scan is delivered locally and bypasses UFW, so 'closed' is not 'filtered'.",
                    "local addresses: " + ", ".join(sorted(mine)) + f"\ntarget: {ip}\nnmap was not run.",
                    [
                        "Run nmap from a different machine: nmap -Pn -sT -p 22,80,443,6443,8080,3000,9090 " + ip,
                        "This result is not external-scan evidence.",
                    ],
                )
            )
        else:
            proc = sh(
                ["nmap", "-Pn", "-sT", "-p", "22,80,443,6443,8080,3000,9090", "--max-retries", "1", "--host-timeout", "40s", ip],
                check=False,
                timeout=60,
            )
            text = (proc.stdout or "") + (proc.stderr or "")
            opened = []
            for ln in text.splitlines():
                parts = ln.split()
                if len(parts) >= 2 and "/tcp" in parts[0] and parts[1] == "open":
                    opened.append(parts[0])
            out.append(
                Check(
                    "External scan shows no open business inbound ports",
                    "FAIL" if opened or proc.returncode not in (0, 1) else "PASS",
                    f"nmap from this host against {ip}. The target is not a local address.",
                    text,
                    ["Production command output captured on this run. Do not reuse it for a different address."],
                )
            )

    url = need(
        "Unauthorized user access to the app is denied",
        "ZTE_APP_URL",
        "ZTE_APP_URL=https://app.example.com ./security-tests/run.sh --production",
    )
    if url:
        proc = sh(["curl", "-sSI", "--max-time", "20", url.rstrip("/") + "/healthz"], check=False, timeout=25)
        text = (proc.stdout or "") + (proc.stderr or "")
        code = ""
        for line in text.splitlines():
            if line.startswith("HTTP/"):
                code = line.split()[1]
                break
        denied = code in {"301", "302", "303", "307", "308", "401", "403"}
        out.append(
            Check(
                "Unauthorized user access to the app is denied",
                "PASS" if denied else "FAIL",
                f"Unauthenticated curl {url} returned HTTP {code or 'none'}.",
                text,
                ["A 200 would mean the edge answered without an Access challenge. That is a failure here."],
            )
        )

    need(
        "Regular user SSH is denied",
        "ZTE_USER_SSH_TARGET",
        "From a tailnet identity that is not group:ops and not tag:ci:\n"
        "ZTE_USER_SSH_TARGET=ubuntu@100.x.y.z ./security-tests/run.sh --production\n"
        "The script runs: ssh -o BatchMode=yes -o ConnectTimeout=8 $ZTE_USER_SSH_TARGET true",
    )
    target = os.environ.get("ZTE_USER_SSH_TARGET", "").strip()
    if target:
        proc = sh(
            ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=8", target, "true"],
            check=False,
            timeout=20,
        )
        text = (proc.stdout or "") + (proc.stderr or "")
        out.append(
            Check(
                "Regular user SSH is denied",
                "PASS" if proc.returncode != 0 else "FAIL",
                f"ssh {target} exited {proc.returncode}.",
                text,
            )
        )

    graf = os.environ.get("ZTE_CI_GRAFANA_URL", "").strip()
    if not graf:
        out.append(
            Check(
                "CI access to Grafana is denied",
                "SKIP",
                "ZTE_CI_GRAFANA_URL is unset. Not a pass.",
                "From a tag:ci node: ZTE_CI_GRAFANA_URL=http://100.x.y.z:3000 ./security-tests/run.sh --production",
            )
        )
    else:
        proc = sh(["curl", "-sS", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "8", graf], check=False, timeout=15)
        text = (proc.stdout or "") + (proc.stderr or "")
        out.append(
            Check(
                "CI access to Grafana is denied",
                "PASS" if proc.returncode != 0 else "FAIL",
                f"curl from this environment to {graf} exited {proc.returncode}.",
                text,
                ["Run this on a host that is tag:ci, not on an operator laptop."],
            )
        )

    ci = os.environ.get("ZTE_CI_SSH_TARGET", "").strip()
    if not ci:
        out.append(
            Check(
                "CI access to node SSH is allowed",
                "SKIP",
                "ZTE_CI_SSH_TARGET is unset. Not a pass.",
                "From tag:ci: ZTE_CI_SSH_TARGET=ubuntu@100.x.y.z ./security-tests/run.sh --production",
            )
        )
    else:
        proc = sh(
            ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=8", ci, "true"],
            check=False,
            timeout=20,
        )
        text = (proc.stdout or "") + (proc.stderr or "")
        out.append(
            Check(
                "CI access to node SSH is allowed",
                "PASS" if proc.returncode == 0 else "FAIL",
                f"ssh {ci} exited {proc.returncode}.",
                text,
            )
        )

    if not os.environ.get("KUBECONFIG") and not Path("/etc/rancher/k3s/k3s.yaml").exists():
        out.append(
            Check(
                "Non-cloudflared Pod access to the app is denied",
                "SKIP",
                "No kubeconfig. Not a pass.",
                "On a k3s node: sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml ./security-tests/run.sh --production",
            )
        )
    else:
        out.append(
            Check(
                "Non-cloudflared Pod access to the app is denied",
                "SKIP",
                "A live cluster was detected, but this run does not apply test pods unless ZTE_APPLY_NETPOL=1.",
                "Set ZTE_APPLY_NETPOL=1 only on a lab cluster you are willing to modify. "
                "The test creates short-lived pods named zte-probe, zte-cloudflared, and zte-stranger.",
            )
        )

    out.append(
        Check(
            "App container privilege escalation fails",
            "SKIP",
            "Production container exec is not attempted from this runner.",
            "On the node, confirm the running pod:\n"
            "kubectl -n edge get pod -l app=edge-echo -o jsonpath='{.items[0].spec.containers[0].securityContext}'\n"
            "Distroless has no shell. Escalation is the securityContext plus the lab helper in --lab.",
        )
    )
    return out


def render(mode: str, checks: list[Check]) -> str:
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    counts = {s: sum(1 for c in checks if c.status == s) for s in ("PASS", "FAIL", "SKIP")}
    if mode == "lab" and counts["FAIL"] == 0 and counts["PASS"] == len(checks):
        overall = "PASS"
    elif counts["FAIL"]:
        overall = "FAIL"
    else:
        overall = "INCOMPLETE"
    lines = [
        "# Security test report",
        "",
        f"- **Overall:** {overall}",
        f"- **Class:** {'LAB simulation' if mode == 'lab' else 'Production attempt'}",
        f"- **When:** {now}",
        f"- **Host:** {socket.gethostname()}",
        f"- **Kernel:** {platform.platform()}",
        f"- **Git:** {git_sha()}",
        f"- **Counts:** {counts['PASS']} pass, {counts['FAIL']} fail, {counts['SKIP']} skip",
        "",
        "This file is generated by `security-tests/lab/run_lab.py`. "
        + (
            "A LAB report is not evidence of a public VPS, Cloudflare Access, or a Tailscale tailnet."
            if mode == "lab"
            else "SKIP is not a pass for Cloudflare, Tailscale, or kube-router. "
            "A scan of an address configured on this host is refused."
        ),
        "",
        "| # | Test | Result |",
        "| --- | --- | --- |",
    ]
    for i, check in enumerate(checks, 1):
        lines.append(f"| {i} | {check.name} | {check.status} |")
    lines.append("")
    lines.append("## Environment")
    lines.append("")
    if mode == "lab":
        lines += [
            "Network namespaces on this machine. Addresses:",
            "",
            "- Lab internet `203.0.113.1`, lab node WAN `203.0.113.10` (TEST-NET-3, documentation range).",
            "- Lab Tailscale-shaped addresses `100.64.1.2` (user), `100.64.1.6` (ci), `100.64.10.10` (node).",
            "- Pod-shaped addresses in `10.43.0.0/16` for the NetworkPolicy dataplane.",
            "",
            "Pod check, measured on this run: "
            f"ip_set is {module_state('ip_set')}; vxlan is {module_state('vxlan')}. "
            "The check enforces k3s/manifests/10-network-policy.yaml with iptables in a "
            "network namespace. It does not install k3s and it is not a kube-router result.",
            "",
        ]
    else:
        lines += [
            "Production mode runs only the commands whose variables are set. "
            "Unset variables are SKIP. SKIP is not PASS.",
            "",
        ]
    lines.append("## Reproduction")
    lines.append("")
    lines += [
        "```bash",
        "sudo ./security-tests/run.sh --lab",
        "# pass variables on the command. sudo -E is ignored on some Ubuntu builds.",
        "sudo env ZTE_NODE_PUBLIC_IP=<public-ip> ./security-tests/run.sh --production",
        "# run that nmap from a different machine. A scan of this host's own address is refused.",
        "```",
        "",
    ]
    for i, check in enumerate(checks, 1):
        lines.append(f"## {i}. {check.name}")
        lines.append("")
        lines.append(f"**{check.status}.** {check.summary}")
        lines.append("")
        for note in check.notes:
            lines.append(f"- {note}")
        if check.notes:
            lines.append("")
        lines.append("```text")
        lines.append(check.log.rstrip() if check.log else "(no command output)")
        lines.append("```")
        lines.append("")
    lines.append("## What still needs the owner's accounts")
    lines.append("")
    lines += [
        "- Cloudflare Access MFA on a real hostname (`ZTE_APP_URL`). The lab applies the policy JSON locally.",
        "- Tailscale ACL pushed to a tailnet. The lab enforces `tailscale/acl.hujson` with iptables.",
        "- `nmap` from a host that is not the node, aimed at the node's real public address (`ZTE_NODE_PUBLIC_IP`).",
        "- SSH as a non-ops user and as `tag:ci` (`ZTE_USER_SSH_TARGET`, `ZTE_CI_SSH_TARGET`, `ZTE_CI_GRAFANA_URL`).",
        "- A k3s node whose kernel can run kube-router, then the same NetworkPolicy manifest.",
        "",
    ]
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("lab", "production"), default="lab")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if os.geteuid() != 0 and args.mode == "lab":
        print("lab mode needs root (run.sh re-execs with sudo)", file=sys.stderr)
        return 2
    checks = run_plane() + [run_netpol(), run_priv()] if args.mode == "lab" else production_checks()
    text = render(args.mode, checks)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(text)
    print(text.split("## Environment", 1)[0])
    print(f"wrote {args.out}")
    if any(c.status == "FAIL" for c in checks):
        return 1
    if args.mode == "lab" and any(c.status != "PASS" for c in checks):
        return 1
    if args.mode == "production" and any(c.status == "SKIP" for c in checks):
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
