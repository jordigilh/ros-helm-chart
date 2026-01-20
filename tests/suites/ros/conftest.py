"""
ROS (Resource Optimization Service) suite fixtures.
"""

import pytest

from utils import get_pod_by_label, get_secret_value, get_route_url


@pytest.fixture(scope="module")
def kruize_pod(cluster_config) -> str:
    """Get Kruize pod name."""
    pod = get_pod_by_label(cluster_config.namespace, "app.kubernetes.io/name=kruize")
    if not pod:
        pytest.skip("Kruize pod not found")
    return pod


@pytest.fixture(scope="module")
def kruize_credentials(cluster_config) -> dict:
    """Get Kruize database credentials."""
    secret_name = f"{cluster_config.helm_release_name}-db-credentials"
    user = get_secret_value(cluster_config.namespace, secret_name, "kruize-user")
    password = get_secret_value(cluster_config.namespace, secret_name, "kruize-password")
    
    if not user or not password:
        pytest.skip("Kruize database credentials not found")
    
    return {"user": user, "password": password, "database": "kruize_db"}


@pytest.fixture(scope="module")
def ros_api_url(cluster_config) -> str:
    """Get ROS API URL."""
    # Try different route name patterns
    for route_suffix in ["main", "ros-api"]:
        route_name = f"{cluster_config.helm_release_name}-{route_suffix}"
        url = get_route_url(cluster_config.namespace, route_name)
        if url:
            return url
    
    pytest.skip("ROS API route not found")
