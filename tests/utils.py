"""
Utility functions for cost-onprem-chart tests.

These are helper functions that can be imported by test modules.
"""

import base64
import subprocess
from typing import Optional


def run_oc_command(args: list[str], check: bool = True) -> subprocess.CompletedProcess:
    """Run an oc command and return the result."""
    cmd = ["oc"] + args
    return subprocess.run(cmd, capture_output=True, text=True, check=check)


def get_route_url(namespace: str, route_name: str) -> Optional[str]:
    """Get the URL for an OpenShift route."""
    try:
        result = run_oc_command(
            ["get", "route", route_name, "-n", namespace, "-o", "jsonpath={.spec.host}"]
        )
        host = result.stdout.strip()
        if not host:
            return None

        # Check if TLS is enabled
        tls_result = run_oc_command(
            [
                "get",
                "route",
                route_name,
                "-n",
                namespace,
                "-o",
                "jsonpath={.spec.tls.termination}",
            ],
            check=False,
        )
        tls = tls_result.stdout.strip()

        scheme = "https" if tls else "http"
        return f"{scheme}://{host}"
    except subprocess.CalledProcessError:
        return None


def get_secret_value(namespace: str, secret_name: str, key: str) -> Optional[str]:
    """Get a decoded value from a Kubernetes secret."""
    try:
        result = run_oc_command(
            [
                "get",
                "secret",
                secret_name,
                "-n",
                namespace,
                "-o",
                f"jsonpath={{.data.{key}}}",
            ]
        )
        encoded = result.stdout.strip()
        if not encoded:
            return None
        return base64.b64decode(encoded).decode("utf-8")
    except (subprocess.CalledProcessError, ValueError):
        return None

