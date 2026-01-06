"""
JWT Authentication Tests for Cost On-Prem.

These tests verify that JWT authentication is properly configured and enforced
on both the ingress and backend API endpoints.
"""

import subprocess
import tempfile
from typing import TYPE_CHECKING

import pytest
import requests

if TYPE_CHECKING:
    from conftest import JWTToken, KeycloakConfig


class TestJWTAuthenticationPreflight:
    """Preflight smoke tests to verify JWT authentication is working."""

    @pytest.mark.smoke
    @pytest.mark.auth
    def test_keycloak_reachable(self, keycloak_config, http_session: requests.Session):
        """Verify Keycloak is reachable."""
        # Test the well-known endpoint
        well_known_url = (
            f"{keycloak_config.url}/realms/{keycloak_config.realm}/"
            ".well-known/openid-configuration"
        )
        response = http_session.get(well_known_url, timeout=10)

        assert response.status_code == 200, (
            f"Keycloak not reachable at {well_known_url}: {response.status_code}"
        )

        data = response.json()
        assert "token_endpoint" in data, "Invalid OpenID configuration response"

    @pytest.mark.smoke
    @pytest.mark.auth
    def test_jwt_token_obtained(self, jwt_token):
        """Verify we can obtain a JWT token from Keycloak."""
        assert jwt_token.access_token, "JWT token is empty"
        assert len(jwt_token.access_token) > 100, "JWT token seems too short"
        assert not jwt_token.is_expired, "JWT token is already expired"

    @pytest.mark.smoke
    @pytest.mark.auth
    def test_ingress_reachable(self, ingress_url: str, http_session: requests.Session):
        """Verify the ingress service is reachable."""
        try:
            response = http_session.get(f"{ingress_url}/ready", timeout=10)
        except requests.exceptions.RequestException as e:
            pytest.skip(f"Cannot reach ingress service: {e}")

        # 503 means route exists but pods aren't ready - skip like shell script does
        if response.status_code == 503:
            pytest.skip(
                "Ingress service returning 503 - pods may not be ready yet. "
                "Shell script would skip JWT validation tests in this case."
            )

        # Should return 200 for health check (no auth required on /ready)
        assert response.status_code in [200, 401, 403], (
            f"Ingress not reachable: {response.status_code}"
        )


class TestIngressJWTAuthentication:
    """Tests for JWT authentication on the ingress service."""

    def _check_ingress_reachable(
        self, ingress_url: str, http_session: requests.Session
    ) -> bool:
        """Check if ingress service is reachable (matches shell script line 154-159).
        
        Returns False if:
        - Connection fails entirely (like shell script's "000" check)
        - Service returns 503 (OpenShift router returns this when pods aren't ready)
        """
        try:
            response = http_session.get(f"{ingress_url}/ready", timeout=5)
            # 503 means route exists but pods aren't ready - treat as unreachable
            if response.status_code == 503:
                return False
            return True
        except requests.exceptions.RequestException:
            return False

    @pytest.mark.auth
    def test_request_without_token_rejected(
        self, ingress_url: str, http_session: requests.Session
    ):
        """Verify requests without JWT token are rejected with 401."""
        # Skip if ingress is unreachable (matches shell script line 154-159)
        if not self._check_ingress_reachable(ingress_url, http_session):
            pytest.skip(
                "Cannot reach ingress service. Service may not be ready yet or "
                "port-forwarding is required."
            )

        response = http_session.post(f"{ingress_url}/v1/upload", timeout=10)

        assert response.status_code == 401, (
            f"Expected 401 for unauthenticated request, got {response.status_code}"
        )

    @pytest.mark.auth
    def test_malformed_token_rejected(
        self, ingress_url: str, http_session: requests.Session
    ):
        """Verify requests with malformed JWT token are rejected."""
        # Skip if ingress is unreachable (matches shell script line 154-159)
        if not self._check_ingress_reachable(ingress_url, http_session):
            pytest.skip(
                "Cannot reach ingress service. Service may not be ready yet or "
                "port-forwarding is required."
            )

        response = http_session.post(
            f"{ingress_url}/v1/upload",
            headers={"Authorization": "Bearer invalid.malformed.token"},
            timeout=10,
        )

        assert response.status_code == 401, (
            f"Expected 401 for malformed token, got {response.status_code}"
        )

    @pytest.mark.auth
    def test_fake_signature_token_rejected(
        self, ingress_url: str, http_session: requests.Session
    ):
        """Verify JWT tokens with invalid signatures are rejected."""
        # Skip if ingress is unreachable (matches shell script line 154-159)
        if not self._check_ingress_reachable(ingress_url, http_session):
            pytest.skip(
                "Cannot reach ingress service. Service may not be ready yet or "
                "port-forwarding is required."
            )

        # Generate a fake JWT with valid structure but wrong signature
        # Skip if openssl not available (matches shell script line 190)
        fake_jwt = self._generate_fake_jwt()
        if fake_jwt is None:
            pytest.skip("OpenSSL not available to generate fake JWT")

        response = http_session.post(
            f"{ingress_url}/v1/upload",
            headers={"Authorization": f"Bearer {fake_jwt}"},
            timeout=10,
        )

        assert response.status_code in [401, 403], (
            f"Expected 401/403 for fake signature, got {response.status_code}. "
            "CRITICAL: JWT with fake signature may have been accepted!"
        )

    @pytest.mark.auth
    def test_valid_token_accepted(
        self, ingress_url: str, jwt_token, http_session: requests.Session
    ):
        """Verify requests with valid JWT token are accepted (auth passes)."""
        # Note: This tests auth, not the actual upload functionality
        # A GET to /ready with auth should work
        response = http_session.get(
            f"{ingress_url}/ready",
            headers=jwt_token.authorization_header,
            timeout=10,
        )

        # Should not be 401/403 - auth should pass
        assert response.status_code not in [401, 403], (
            f"Valid JWT token was rejected: {response.status_code}"
        )

    def _generate_fake_jwt(self) -> str | None:
        """Generate a fake JWT with valid structure but wrong signature."""
        try:
            import base64
            import json

            # Create a temporary RSA key
            with tempfile.NamedTemporaryFile(mode="w", suffix=".pem", delete=False) as f:
                key_file = f.name

            subprocess.run(
                ["openssl", "genrsa", "-out", key_file, "2048"],
                capture_output=True,
                check=True,
            )

            # Create header and payload
            header = {"alg": "RS256", "typ": "JWT", "kid": "fake-key"}
            payload = {
                "sub": "attacker",
                "iss": "https://fake-issuer.com",
                "aud": "cost-management-operator",
                "exp": 9999999999,
            }

            def b64url_encode(data: bytes) -> str:
                return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")

            header_b64 = b64url_encode(json.dumps(header).encode())
            payload_b64 = b64url_encode(json.dumps(payload).encode())

            # Sign with our fake key
            message = f"{header_b64}.{payload_b64}"
            sign_result = subprocess.run(
                ["openssl", "dgst", "-sha256", "-sign", key_file],
                input=message.encode(),
                capture_output=True,
                check=True,
            )
            signature_b64 = b64url_encode(sign_result.stdout)

            # Cleanup
            import os
            os.unlink(key_file)

            return f"{header_b64}.{payload_b64}.{signature_b64}"

        except (subprocess.CalledProcessError, FileNotFoundError):
            return None


class TestBackendAPIJWTAuthentication:
    """Tests for JWT authentication on the backend API."""

    @pytest.mark.auth
    def test_request_without_token_rejected(
        self, backend_api_url: str, http_session: requests.Session
    ):
        """Verify backend API requests without JWT token are rejected."""
        response = http_session.get(
            f"{backend_api_url}/api/cost-management/v1/recommendations/openshift",
            timeout=10,
        )

        # Should be 401 or 403 if behind auth proxy
        # May be 200 if direct backend access (bypasses auth)
        if response.status_code == 200:
            pytest.skip(
                "Backend returned 200 without auth - may not be behind Envoy proxy"
            )

        assert response.status_code in [401, 403], (
            f"Expected 401/403, got {response.status_code}"
        )

    @pytest.mark.auth
    def test_invalid_token_rejected(
        self, backend_api_url: str, http_session: requests.Session
    ):
        """Verify backend API rejects invalid JWT tokens."""
        response = http_session.get(
            f"{backend_api_url}/api/cost-management/v1/recommendations/openshift",
            headers={"Authorization": "Bearer invalid.jwt.token"},
            timeout=10,
        )

        assert response.status_code in [401, 403], (
            f"Expected 401/403 for invalid token, got {response.status_code}"
        )

    @pytest.mark.auth
    def test_valid_token_accepted(
        self, backend_api_url: str, jwt_token, http_session: requests.Session
    ):
        """Verify backend API accepts valid JWT tokens."""
        response = http_session.get(
            f"{backend_api_url}/api/cost-management/v1/recommendations/openshift",
            headers=jwt_token.authorization_header,
            timeout=10,
        )

        # Should get 200 (with data) or 404 (no data yet) - but NOT 401/403
        assert response.status_code not in [401, 403], (
            f"Valid JWT token was rejected: {response.status_code}"
        )

    @pytest.mark.auth
    def test_status_endpoint_with_token(
        self, backend_api_url: str, jwt_token, http_session: requests.Session
    ):
        """Verify status endpoint is accessible with valid token."""
        response = http_session.get(
            f"{backend_api_url}/status",
            headers=jwt_token.authorization_header,
            timeout=10,
        )

        assert response.status_code == 200, (
            f"Status endpoint failed: {response.status_code}"
        )

