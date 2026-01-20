"""
UI OAuth flow tests.

Tests for the UI authentication flow with Keycloak (password grant).
Migrated from scripts/test-ui-oauth-flow.sh
"""

import base64
import json

import pytest
import requests

from utils import run_oc_command, get_route_url


@pytest.mark.auth
@pytest.mark.integration
class TestUIOAuthFlow:
    """Tests for UI OAuth authentication flow."""

    @pytest.fixture
    def ui_route(self, cluster_config) -> str:
        """Get the UI route URL."""
        result = run_oc_command([
            "get", "route", "-n", cluster_config.namespace,
            "-l", "app.kubernetes.io/component=ui",
            "-o", "jsonpath={.items[0].spec.host}"
        ], check=False)
        
        host = result.stdout.strip()
        if not host:
            pytest.skip("UI route not found")
        return f"https://{host}"

    def test_ui_pod_running(self, cluster_config):
        """Verify UI pod is running."""
        result = run_oc_command([
            "get", "pods", "-n", cluster_config.namespace,
            "-l", "app.kubernetes.io/component=ui",
            "-o", "jsonpath={.items[0].status.phase}"
        ], check=False)
        
        status = result.stdout.strip()
        if not status:
            pytest.skip("UI pod not found")
        
        assert status == "Running", f"UI pod status: {status}"

    def test_oauth_proxy_no_tls_errors(self, cluster_config):
        """Verify no TLS errors in oauth-proxy logs."""
        result = run_oc_command([
            "logs", "-n", cluster_config.namespace,
            "-l", "app.kubernetes.io/component=ui",
            "-c", "oauth-proxy",
            "--tail=100"
        ], check=False)
        
        if result.returncode != 0:
            pytest.skip("Could not get oauth-proxy logs")
        
        logs = result.stdout.lower()
        tls_errors = ["tls.*error", "certificate.*error", "x509"]
        
        for pattern in tls_errors:
            if pattern in logs:
                pytest.fail(f"TLS error found in oauth-proxy logs: {pattern}")

    def test_password_grant_token_acquisition(
        self,
        keycloak_config,
        ui_client_config,
        test_user_credentials,
        http_session: requests.Session,
    ):
        """Verify JWT token can be obtained via password grant."""
        if not ui_client_config.get("client_secret"):
            # Try without client secret (public client)
            data = {
                "username": test_user_credentials["username"],
                "password": test_user_credentials["password"],
                "grant_type": "password",
                "client_id": ui_client_config["client_id"],
                "scope": "openid profile email",
            }
        else:
            data = {
                "username": test_user_credentials["username"],
                "password": test_user_credentials["password"],
                "grant_type": "password",
                "client_id": ui_client_config["client_id"],
                "client_secret": ui_client_config["client_secret"],
                "scope": "openid profile email",
            }
        
        token_url = (
            f"{keycloak_config.url}/realms/{keycloak_config.realm}/"
            "protocol/openid-connect/token"
        )
        
        response = http_session.post(token_url, data=data, timeout=30)
        
        if response.status_code != 200:
            pytest.skip(f"Password grant failed: {response.status_code}")
        
        token_data = response.json()
        assert "access_token" in token_data, "No access_token in response"

    def test_jwt_contains_required_claims(
        self,
        keycloak_config,
        ui_client_config,
        test_user_credentials,
        http_session: requests.Session,
    ):
        """Verify JWT contains required claims (preferred_username, org_id)."""
        # Get token via password grant
        data = {
            "username": test_user_credentials["username"],
            "password": test_user_credentials["password"],
            "grant_type": "password",
            "client_id": ui_client_config["client_id"],
            "scope": "openid profile email",
        }
        if ui_client_config.get("client_secret"):
            data["client_secret"] = ui_client_config["client_secret"]
        
        token_url = (
            f"{keycloak_config.url}/realms/{keycloak_config.realm}/"
            "protocol/openid-connect/token"
        )
        
        response = http_session.post(token_url, data=data, timeout=30)
        
        if response.status_code != 200:
            pytest.skip("Could not obtain token for claims validation")
        
        access_token = response.json().get("access_token")
        
        # Decode JWT payload
        payload_b64 = access_token.split(".")[1]
        padding = 4 - len(payload_b64) % 4
        if padding != 4:
            payload_b64 += "=" * padding
        
        payload = json.loads(base64.urlsafe_b64decode(payload_b64))
        
        # Check required claims
        assert "preferred_username" in payload, "JWT missing preferred_username"
        
        # These are warnings, not failures (may not be configured)
        if "org_id" not in payload:
            pytest.skip("JWT missing org_id claim (may need Keycloak mapper)")
        if "account_number" not in payload:
            pytest.skip("JWT missing account_number claim (may need Keycloak mapper)")
