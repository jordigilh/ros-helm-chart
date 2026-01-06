"""
Pytest fixtures and configuration for cost-onprem-chart tests.

These fixtures provide shared resources for testing JWT authentication,
data uploads, and recommendation verification on OpenShift.
"""

import os
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

import pytest
import requests
import urllib3

from utils import get_route_url, get_secret_value

# Disable SSL warnings for self-signed certificates
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)


@dataclass
class ClusterConfig:
    """Configuration for the target cluster."""

    namespace: str
    helm_release_name: str
    keycloak_namespace: str
    platform: str = "openshift"


@dataclass
class KeycloakConfig:
    """Keycloak authentication configuration."""

    url: str
    client_id: str
    client_secret: str
    realm: str = "kubernetes"

    @property
    def token_url(self) -> str:
        """Get the token endpoint URL."""
        return f"{self.url}/realms/{self.realm}/protocol/openid-connect/token"


@dataclass
class JWTToken:
    """JWT token with expiry tracking."""

    access_token: str
    expires_at: datetime
    token_type: str = "Bearer"

    @property
    def is_expired(self) -> bool:
        """Check if the token has expired."""
        return datetime.now(timezone.utc) >= self.expires_at

    @property
    def authorization_header(self) -> dict:
        """Get the Authorization header dict."""
        return {"Authorization": f"{self.token_type} {self.access_token}"}


# --- Fixtures ---


@pytest.fixture(scope="session")
def cluster_config() -> ClusterConfig:
    """Get cluster configuration from environment variables."""
    return ClusterConfig(
        namespace=os.environ.get("NAMESPACE", "cost-onprem"),
        helm_release_name=os.environ.get("HELM_RELEASE_NAME", "cost-onprem"),
        keycloak_namespace=os.environ.get("KEYCLOAK_NAMESPACE", "keycloak"),
        platform=os.environ.get("PLATFORM", "openshift"),
    )


@pytest.fixture(scope="session")
def keycloak_config(cluster_config: ClusterConfig) -> KeycloakConfig:
    """Detect and return Keycloak configuration."""
    # Try to find Keycloak route
    keycloak_url = get_route_url(cluster_config.keycloak_namespace, "keycloak")
    if not keycloak_url:
        pytest.skip(
            f"Keycloak route not found in namespace {cluster_config.keycloak_namespace}"
        )

    # Get client credentials from secret
    client_id = "cost-management-operator"
    client_secret = None

    # Try different secret name patterns
    secret_patterns = [
        "keycloak-client-secret-cost-management-operator",
        "keycloak-client-secret-cost-management-service-account",
        f"credential-{client_id}",
        f"keycloak-client-{client_id}",
        f"{client_id}-secret",
    ]

    for secret_name in secret_patterns:
        client_secret = get_secret_value(
            cluster_config.keycloak_namespace, secret_name, "CLIENT_SECRET"
        )
        if client_secret:
            break

    if not client_secret:
        pytest.skip(
            f"Client secret not found in namespace {cluster_config.keycloak_namespace}"
        )

    return KeycloakConfig(
        url=keycloak_url,
        client_id=client_id,
        client_secret=client_secret,
    )


@pytest.fixture(scope="session")
def jwt_token(keycloak_config: KeycloakConfig) -> JWTToken:
    """Obtain a JWT token from Keycloak using client credentials flow."""
    response = requests.post(
        keycloak_config.token_url,
        data={
            "grant_type": "client_credentials",
            "client_id": keycloak_config.client_id,
            "client_secret": keycloak_config.client_secret,
        },
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        verify=False,
        timeout=30,
    )

    if response.status_code != 200:
        pytest.fail(f"Failed to obtain JWT token: {response.status_code} - {response.text}")

    token_data = response.json()
    expires_in = token_data.get("expires_in", 300)

    return JWTToken(
        access_token=token_data["access_token"],
        expires_at=datetime.now(timezone.utc) + timedelta(seconds=expires_in),
    )


@pytest.fixture(scope="session")
def ingress_url(cluster_config: ClusterConfig) -> str:
    """Get the ingress service URL."""
    route_name = f"{cluster_config.helm_release_name}-ingress"
    url = get_route_url(cluster_config.namespace, route_name)
    if not url:
        pytest.skip(f"Ingress route '{route_name}' not found")
    return url


@pytest.fixture(scope="session")
def backend_api_url(cluster_config: ClusterConfig) -> str:
    """Get the backend API URL."""
    # Try different route name patterns
    for route_suffix in ["main", "ros-api"]:
        route_name = f"{cluster_config.helm_release_name}-{route_suffix}"
        url = get_route_url(cluster_config.namespace, route_name)
        if url:
            return url

    pytest.skip("Backend API route not found")


@pytest.fixture
def unique_cluster_id() -> str:
    """Generate a unique cluster ID for test uploads."""
    return f"test-cluster-{int(time.time())}-{uuid.uuid4().hex[:8]}"


@pytest.fixture
def test_csv_data() -> str:
    """Generate test CSV data with current timestamps."""
    now = datetime.now(timezone.utc)
    now_date = now.strftime("%Y-%m-%d")

    def format_timestamp(minutes_ago: int) -> str:
        ts = now - timedelta(minutes=minutes_ago)
        return ts.strftime("%Y-%m-%d %H:%M:%S -0000 UTC")

    intervals = [
        (75, 60),
        (60, 45),
        (45, 30),
        (30, 15),
    ]

    header = (
        "report_period_start,report_period_end,interval_start,interval_end,"
        "container_name,pod,owner_name,owner_kind,workload,workload_type,"
        "namespace,image_name,node,resource_id,"
        "cpu_request_container_avg,cpu_request_container_sum,"
        "cpu_limit_container_avg,cpu_limit_container_sum,"
        "cpu_usage_container_avg,cpu_usage_container_min,cpu_usage_container_max,cpu_usage_container_sum,"
        "cpu_throttle_container_avg,cpu_throttle_container_max,cpu_throttle_container_sum,"
        "memory_request_container_avg,memory_request_container_sum,"
        "memory_limit_container_avg,memory_limit_container_sum,"
        "memory_usage_container_avg,memory_usage_container_min,memory_usage_container_max,memory_usage_container_sum,"
        "memory_rss_usage_container_avg,memory_rss_usage_container_min,memory_rss_usage_container_max,memory_rss_usage_container_sum"
    )

    rows = [header]
    cpu_usages = [0.247832, 0.265423, 0.289567, 0.234567]
    memory_usages = [413587266, 427891456, 445678901, 398765432]

    for i, (start_ago, end_ago) in enumerate(intervals):
        row = (
            f"{now_date},{now_date},"
            f"{format_timestamp(start_ago)},{format_timestamp(end_ago)},"
            "test-container,test-pod-123,test-deployment,Deployment,test-workload,deployment,"
            "test-namespace,quay.io/test/image:latest,worker-node-1,resource-123,"
            f"0.5,0.5,1.0,1.0,{cpu_usages[i]},0.185671,0.324131,{cpu_usages[i]},"
            "0.001,0.002,0.001,"
            f"536870912,536870912,1073741824,1073741824,"
            f"{memory_usages[i]},410009344,420900544,{memory_usages[i]},"
            f"{memory_usages[i] - 20000000},390293568,396371392,{memory_usages[i] - 20000000}"
        )
        rows.append(row)

    return "\n".join(rows)


@pytest.fixture
def http_session() -> requests.Session:
    """Create a requests session with SSL verification disabled."""
    session = requests.Session()
    session.verify = False
    return session

