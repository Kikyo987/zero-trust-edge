"""Evaluate tailscale/acl.hujson the way the lab cares about it.

This is not the Tailscale coordinator. It implements the grants and ssh
stanzas in this repository: a source matches a grant when one of the
grant's src selectors is one of the identity's selectors, same for dst,
and the port is listed (or '*').
"""

from __future__ import annotations

import json
from pathlib import Path

from hujson import loads

ROOT = Path(__file__).resolve().parents[2]
ACL_PATHS = (
    ROOT / "tailscale" / "acl.hujson",
    ROOT / "cloudflare" / "tailscale-acl.hujson",
)

# Selectors each lab identity is allowed to claim.
# A regular user is a tailnet member and a developer. They are not ops
# and they are not the CI tag. group:dev has no grant of its own.
IDENTITIES = {
    "user": frozenset({"group:dev", "autogroup:member"}),
    "ci": frozenset({"tag:ci"}),
    "ops": frozenset({"group:ops"}),
}


def load_acl() -> dict:
    parsed = [loads(path.read_text()) for path in ACL_PATHS]
    left = json.dumps(parsed[0], sort_keys=True)
    right = json.dumps(parsed[1], sort_keys=True)
    if left != right:
        raise SystemExit(
            "tailscale/acl.hujson and cloudflare/tailscale-acl.hujson "
            "differ once comments are removed"
        )
    return parsed[0]


def _port_ok(items: list, port: int) -> bool:
    for item in items:
        text = str(item)
        if text == "*":
            return True
        if text.isdigit() and int(text) == port:
            return True
        if "-" in text:
            a, b = text.split("-", 1)
            if a.isdigit() and b.isdigit() and int(a) <= port <= int(b):
                return True
    return False


def _src_ok(selectors: list, identity: frozenset) -> bool:
    return bool(set(selectors) & set(identity))


def grant_allows(acl: dict, identity: str, dst: str, port: int) -> bool:
    who = IDENTITIES[identity]
    for grant in acl.get("grants", []):
        if not _src_ok(grant.get("src", []), who):
            continue
        if dst not in grant.get("dst", []) and "*" not in grant.get("dst", []):
            continue
        if _port_ok(grant.get("ip", []), port):
            return True
    return False


def ssh_accepts(acl: dict, identity: str, dst: str, user: str) -> bool:
    who = IDENTITIES[identity]
    for rule in acl.get("ssh", []):
        if rule.get("action") != "accept":
            continue
        if not _src_ok(rule.get("src", []), who):
            continue
        if dst not in rule.get("dst", []):
            continue
        users = rule.get("users", [])
        if user in users or "autogroup:nonroot" in users:
            return True
    return False
