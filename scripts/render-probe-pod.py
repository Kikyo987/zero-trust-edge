#!/usr/bin/env python3
"""Render the deploy health-check Pod.

The Pod carries edge.zero-trust/role=probe, which is the only label
allow-from-probes admits, and it satisfies the restricted Pod Security
level on the edge namespace.
"""

from __future__ import annotations

import json
import sys


def pod(name: str, script: str) -> dict:
    return {
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {
            "name": name,
            "namespace": "edge",
            "labels": {"edge.zero-trust/role": "probe"},
        },
        "spec": {
            "restartPolicy": "Never",
            "automountServiceAccountToken": False,
            "securityContext": {
                "runAsNonRoot": True,
                "runAsUser": 65532,
                "runAsGroup": 65532,
                "seccompProfile": {"type": "RuntimeDefault"},
            },
            "containers": [
                {
                    "name": "probe",
                    "image": "alpine:3.21",
                    "command": ["/bin/sh", "-c", script],
                    "securityContext": {
                        "allowPrivilegeEscalation": False,
                        "readOnlyRootFilesystem": True,
                        "runAsNonRoot": True,
                        "runAsUser": 65532,
                        "capabilities": {"drop": ["ALL"]},
                    },
                    "volumeMounts": [{"name": "tmp", "mountPath": "/tmp"}],
                }
            ],
            "volumes": [{"name": "tmp", "emptyDir": {"sizeLimit": "4Mi"}}],
        },
    }


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[1] == "--self-test":
        body = pod("healthz-ci", "wget -qO- http://edge-echo.edge.svc:8080/healthz")
        assert body["metadata"]["labels"]["edge.zero-trust/role"] == "probe"
        sec = body["spec"]["containers"][0]["securityContext"]
        assert sec["allowPrivilegeEscalation"] is False
        assert sec["capabilities"]["drop"] == ["ALL"]
        assert body["spec"]["securityContext"]["runAsNonRoot"] is True
        print("render-probe-pod self-test PASS")
        return 0
    if len(argv) != 3:
        print("usage: render-probe-pod.py <pod-name> <shell-script>", file=sys.stderr)
        return 2
    json.dump(pod(argv[1], argv[2]), sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
