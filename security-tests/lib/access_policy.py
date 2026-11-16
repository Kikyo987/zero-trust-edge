"""Apply cloudflare/access/policy-github-mfa.json to lab headers.

This does not validate a Cloudflare JWT and it does not speak to the
Access API. A request is allowed only when the policy's include rule
matches the presented GitHub organization AND the require rule matches
the presented auth method. Anything else is deny.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
POLICY_PATH = ROOT / "cloudflare" / "access" / "policy-github-mfa.json"


def load_policy() -> dict:
    return json.loads(POLICY_PATH.read_text())


def _org_name(policy: dict) -> str:
    for item in policy.get("include") or []:
        org = item.get("github-organization") or {}
        if org.get("name"):
            return org["name"]
    raise SystemExit(f"no github-organization include in {POLICY_PATH}")


def _method_re(policy: dict) -> re.Pattern[str]:
    for item in policy.get("require") or []:
        raw = item.get("auth_method")
        if raw:
            return re.compile(rf"^({raw})$")
    raise SystemExit(f"no auth_method require in {POLICY_PATH}")


def decide(policy: dict, github_org: str, auth_method: str) -> str:
    """Return 'allow' or 'deny'. Default is deny."""
    if policy.get("decision") != "allow":
        return "deny"
    if github_org != _org_name(policy):
        return "deny"
    if not auth_method or _method_re(policy).match(auth_method) is None:
        return "deny"
    return "allow"
