"""
Sources API tests.

Tests for the Sources API service health and configuration.
Note: Source registration flow is tested in suites/e2e/ as part of the complete pipeline.
"""

import json

import pytest

from utils import exec_in_pod, check_pod_ready


@pytest.mark.cost_management
@pytest.mark.component
class TestSourcesAPIHealth:
    """Tests for Sources API health and availability."""

    @pytest.mark.smoke
    def test_sources_api_pod_ready(self, cluster_config):
        """Verify Sources API pod is ready."""
        assert check_pod_ready(
            cluster_config.namespace,
            "app.kubernetes.io/name=sources-api"
        ), "Sources API pod is not ready"

    def test_sources_api_responds(
        self, cluster_config, sources_api_url: str, sources_listener_pod: str, org_id: str
    ):
        """Verify Sources API responds to requests."""
        result = exec_in_pod(
            cluster_config.namespace,
            sources_listener_pod,
            [
                "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                f"{sources_api_url}/source_types",
                "-H", f"x-rh-sources-org-id: {org_id}",
            ],
            container="sources-listener",
        )
        
        assert result is not None, "Could not reach Sources API"
        assert result.strip() == "200", f"Sources API returned {result}"


@pytest.mark.cost_management
@pytest.mark.integration
class TestSourceTypes:
    """Tests for source type configuration."""

    def test_openshift_source_type_exists(
        self, cluster_config, sources_api_url: str, sources_listener_pod: str, org_id: str
    ):
        """Verify OpenShift source type is configured."""
        result = exec_in_pod(
            cluster_config.namespace,
            sources_listener_pod,
            [
                "curl", "-s", f"{sources_api_url}/source_types",
                "-H", "Content-Type: application/json",
                "-H", f"x-rh-sources-org-id: {org_id}",
            ],
            container="sources-listener",
        )
        
        assert result is not None, "Could not get source types"
        
        data = json.loads(result)
        source_types = [st.get("name") for st in data.get("data", [])]
        
        assert "openshift" in source_types, "OpenShift source type not found"

    def test_cost_management_app_type_exists(
        self, cluster_config, sources_api_url: str, sources_listener_pod: str, org_id: str
    ):
        """Verify Cost Management application type is configured."""
        result = exec_in_pod(
            cluster_config.namespace,
            sources_listener_pod,
            [
                "curl", "-s", f"{sources_api_url}/application_types",
                "-H", "Content-Type: application/json",
                "-H", f"x-rh-sources-org-id: {org_id}",
            ],
            container="sources-listener",
        )
        
        assert result is not None, "Could not get application types"
        
        data = json.loads(result)
        app_types = [at.get("name") for at in data.get("data", [])]
        
        assert "/insights/platform/cost-management" in app_types, (
            "Cost Management application type not found"
        )
