"""Evaluate k3s/manifests/10-network-policy.yaml.

Enough of the NetworkPolicy spec to answer the questions this repo's
manifest actually uses: podSelector, namespaceSelector (AND when both
are set), ports, and an empty policyTypes entry meaning default deny.
ipBlock is honored for the probe Service-CIDR egress.
"""

from __future__ import annotations

import ipaddress
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
POLICY_PATH = ROOT / "k3s" / "manifests" / "10-network-policy.yaml"

PROBE_LABEL = "edge.zero-trust/role"


def load_policies() -> list[dict]:
    docs = list(yaml.safe_load_all(POLICY_PATH.read_text()))
    return [d for d in docs if d and d.get("kind") == "NetworkPolicy"]


def _labels_match(selector: dict | None, labels: dict) -> bool:
    if not selector:
        return True
    want = selector.get("matchLabels") or {}
    return all(labels.get(k) == v for k, v in want.items())


def _ns_match(selector: dict | None, namespace: str) -> bool:
    if not selector:
        return True
    want = selector.get("matchLabels") or {}
    name = want.get("kubernetes.io/metadata.name")
    if name is not None and name != namespace:
        return False
    return True


def _policy_selects(policy: dict, namespace: str, labels: dict) -> bool:
    if policy["metadata"].get("namespace") != namespace:
        return False
    return _labels_match(policy["spec"].get("podSelector") or {}, labels)


def _port_ok(rule: dict, port: int) -> bool:
    ports = rule.get("ports")
    if not ports:
        return True
    for item in ports:
        if item.get("protocol", "TCP") not in ("TCP", "tcp"):
            continue
        if int(item.get("port", port)) == port:
            return True
    return False


def _peer_ok(peer: dict, other_ns: str, other_labels: dict, other_ip: str, policy_ns: str) -> bool:
    if "ipBlock" in peer:
        block = peer["ipBlock"]
        ip = ipaddress.ip_address(other_ip)
        if ip not in ipaddress.ip_network(block["cidr"]):
            return False
        for exc in block.get("except") or []:
            if ip in ipaddress.ip_network(exc):
                return False
        return "namespaceSelector" not in peer and "podSelector" not in peer

    ns_sel = peer.get("namespaceSelector")
    pod_sel = peer.get("podSelector")
    if ns_sel is None and pod_sel is None:
        return False
    ns_ok = other_ns == policy_ns if ns_sel is None else _ns_match(ns_sel, other_ns)
    pod_ok = True if pod_sel is None else _labels_match(pod_sel, other_labels)
    return ns_ok and pod_ok


def _isolated(policies: list[dict], namespace: str, labels: dict, direction: str) -> bool:
    for policy in policies:
        if direction not in policy["spec"].get("policyTypes", []):
            continue
        if _policy_selects(policy, namespace, labels):
            return True
    return False


def _rules_allow(
    policies: list[dict],
    namespace: str,
    labels: dict,
    direction: str,
    other_ns: str,
    other_labels: dict,
    other_ip: str,
    port: int,
) -> bool:
    key = "ingress" if direction == "Ingress" else "egress"
    peer_key = "from" if direction == "Ingress" else "to"
    for policy in policies:
        if direction not in policy["spec"].get("policyTypes", []):
            continue
        if not _policy_selects(policy, namespace, labels):
            continue
        for rule in policy["spec"].get(key) or []:
            if not _port_ok(rule, port):
                continue
            peers = rule.get(peer_key)
            if not peers:
                return True
            policy_ns = policy["metadata"]["namespace"]
            for peer in peers:
                if _peer_ok(peer, other_ns, other_labels, other_ip, policy_ns):
                    return True
    return False


def ingress_allows(
    policies: list[dict],
    dst_ns: str,
    dst_labels: dict,
    src_ns: str,
    src_labels: dict,
    src_ip: str,
    port: int,
) -> bool:
    if not _isolated(policies, dst_ns, dst_labels, "Ingress"):
        return True
    return _rules_allow(
        policies, dst_ns, dst_labels, "Ingress", src_ns, src_labels, src_ip, port
    )


def egress_allows(
    policies: list[dict],
    src_ns: str,
    src_labels: dict,
    dst_ns: str,
    dst_labels: dict,
    dst_ip: str,
    port: int,
) -> bool:
    if not _isolated(policies, src_ns, src_labels, "Egress"):
        return True
    return _rules_allow(
        policies, src_ns, src_labels, "Egress", dst_ns, dst_labels, dst_ip, port
    )


def broad_edge_namespace_peers(policies: list[dict]) -> list[str]:
    """Ingress peers that select every Pod in `edge` and nothing narrower."""
    found = []
    for policy in policies:
        for rule in policy["spec"].get("ingress") or []:
            for peer in rule.get("from") or []:
                ns = (
                    (peer.get("namespaceSelector") or {})
                    .get("matchLabels", {})
                    .get("kubernetes.io/metadata.name")
                )
                if ns == "edge" and "podSelector" not in peer and "ipBlock" not in peer:
                    found.append(policy["metadata"]["name"])
    return found
