#!/usr/bin/env python3
"""Bind an existing self-signed macOS candidate to its two checkout commits.

The original three-input dispatch remains supported. Operator dispatches supply
both optional pins and must run from main; the server checkout always uses main,
so a requested arbitrary PR commit cannot reach the privileged build steps.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess


def commit(value: str, label: str) -> str:
    if not re.fullmatch(r"[0-9a-f]{40}", value):
        raise ValueError(f"{label} requires a full lowercase commit SHA")
    return value


def head(root: Path) -> str:
    result = subprocess.run(["git", "-C", str(root), "rev-parse", "HEAD"],
                            check=True, capture_output=True, text=True)
    return commit(result.stdout.strip(), "checkout")


def verify(root: Path) -> dict:
    workflow = commit(os.environ.get("GITHUB_SHA", ""), "workflow")
    client_pin = os.environ.get("VEX_NATIVE_SOURCE_COMMIT", "")
    server_pin = os.environ.get("VEX_VPN_SOURCE_COMMIT", "")
    if (client_pin or server_pin) and os.environ.get("GITHUB_REF") != "refs/heads/main":
        raise ValueError("Pinned operator releases require the main workflow")
    if client_pin and commit(client_pin, "client pin") != workflow:
        raise ValueError("Client pin differs from the dispatched workflow")
    client, server = head(root), head(root / "vpn-main")
    if client != workflow:
        raise ValueError("Client checkout differs from the dispatched workflow")
    if server_pin and commit(server_pin, "VPN pin") != server:
        raise ValueError("VPN main moved; create a fresh source-bound release plan")
    return {"schemaVersion": 1, "clientRepository": "ibotpafos/vex-client",
            "clientCommit": client, "vpnRepository": "ibotpafos/VPN",
            "vpnCommit": server, "workflowCommit": workflow,
            "clientPinExplicit": bool(client_pin), "vpnPinExplicit": bool(server_pin),
            "workflowRunId": os.environ.get("GITHUB_RUN_ID", ""),
            "workflowRunAttempt": os.environ.get("GITHUB_RUN_ATTEMPT", ""),
            "version": os.environ.get("VEX_NATIVE_VERSION", ""),
            "build": os.environ.get("VEX_NATIVE_BUILD", "")}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    evidence = verify(Path.cwd())
    if args.output:
        args.output.write_text(json.dumps(evidence, sort_keys=True, indent=2) + "\n")
    print("macOS release checkout commits verified")


if __name__ == "__main__":
    main()
