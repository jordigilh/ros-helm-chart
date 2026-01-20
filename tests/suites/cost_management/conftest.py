"""
Cost Management (Koku) suite fixtures.
"""

import pytest

from utils import get_pod_by_label


@pytest.fixture(scope="module")
def sources_api_url(cluster_config) -> str:
    """Get Sources API internal URL."""
    return (
        f"http://{cluster_config.helm_release_name}-sources-api."
        f"{cluster_config.namespace}.svc.cluster.local:8000/api/sources/v1.0"
    )


@pytest.fixture(scope="module")
def sources_listener_pod(cluster_config) -> str:
    """Get sources-listener pod name for executing API calls."""
    pod = get_pod_by_label(
        cluster_config.namespace,
        "app.kubernetes.io/component=sources-listener"
    )
    if not pod:
        pod = get_pod_by_label(
            cluster_config.namespace,
            "app.kubernetes.io/component=listener"
        )
    if not pod:
        pytest.skip("Sources listener pod not found")
    return pod
