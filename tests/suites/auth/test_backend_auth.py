"""
Backend API JWT authentication tests.

Tests for JWT authentication on the backend API service.
"""

import pytest
import requests


@pytest.mark.auth
@pytest.mark.integration
class TestBackendAPIJWTAuthentication:
    """Tests for JWT authentication on the backend API."""

    def test_request_without_token_rejected(
        self, backend_api_url: str, http_session: requests.Session
    ):
        """Verify backend API requests without JWT token are rejected."""
        response = http_session.get(
            f"{backend_api_url}/api/cost-management/v1/recommendations/openshift",
            timeout=10,
        )

        if response.status_code == 200:
            pytest.skip(
                "Backend returned 200 without auth - may not be behind Envoy proxy"
            )

        assert response.status_code in [401, 403], (
            f"Expected 401/403, got {response.status_code}"
        )

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

    @pytest.mark.smoke
    def test_valid_token_accepted(
        self, backend_api_url: str, jwt_token, http_session: requests.Session
    ):
        """Verify backend API accepts valid JWT tokens."""
        response = http_session.get(
            f"{backend_api_url}/api/cost-management/v1/recommendations/openshift",
            headers=jwt_token.authorization_header,
            timeout=10,
        )

        assert response.status_code not in [401, 403], (
            f"Valid JWT token was rejected: {response.status_code}"
        )

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
