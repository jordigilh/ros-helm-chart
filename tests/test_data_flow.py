"""
Data Flow Tests for Cost On-Prem.

These tests verify the end-to-end data flow:
1. Upload test data with JWT authentication
2. Verify data is processed
3. Check recommendations are generated
"""

import json
import subprocess
import tarfile
import tempfile
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

import pytest
import requests

from utils import get_secret_value, run_oc_command


class TestDataUpload:
    """Tests for data upload functionality."""

    def _check_ingress_available(
        self, ingress_url: str, http_session: requests.Session
    ) -> bool:
        """Check if ingress service is available (not returning 503)."""
        try:
            response = http_session.get(f"{ingress_url}/ready", timeout=5)
            return response.status_code != 503
        except requests.exceptions.RequestException:
            return False

    @pytest.mark.upload
    def test_upload_with_jwt_authentication(
        self,
        ingress_url: str,
        jwt_token,
        test_csv_data: str,
        unique_cluster_id: str,
        http_session: requests.Session,
    ):
        """Verify data can be uploaded with JWT authentication."""
        # Skip if ingress is not available (503 = pods not ready)
        if not self._check_ingress_available(ingress_url, http_session):
            pytest.skip(
                "Ingress service not available (503). Pods may not be ready yet."
            )

        # Create the upload package
        upload_file = self._create_upload_package(test_csv_data, unique_cluster_id)

        try:
            with open(upload_file, "rb") as f:
                response = http_session.post(
                    f"{ingress_url}/v1/upload",
                    files={
                        "file": (
                            "cost-mgmt.tar.gz",
                            f,
                            "application/vnd.redhat.hccm.filename+tgz",
                        )
                    },
                    headers={
                        **jwt_token.authorization_header,
                        "x-rh-request-id": f"test-request-{int(time.time())}",
                    },
                    timeout=60,
                )

            assert response.status_code in [200, 202], (
                f"Upload failed with {response.status_code}: {response.text}"
            )

        finally:
            Path(upload_file).unlink(missing_ok=True)

    @pytest.mark.upload
    def test_upload_without_token_rejected(
        self,
        ingress_url: str,
        test_csv_data: str,
        unique_cluster_id: str,
        http_session: requests.Session,
    ):
        """Verify upload without JWT token is rejected."""
        # Skip if ingress is not available (503 = pods not ready)
        if not self._check_ingress_available(ingress_url, http_session):
            pytest.skip(
                "Ingress service not available (503). Pods may not be ready yet."
            )

        upload_file = self._create_upload_package(test_csv_data, unique_cluster_id)

        try:
            with open(upload_file, "rb") as f:
                response = http_session.post(
                    f"{ingress_url}/v1/upload",
                    files={
                        "file": (
                            "cost-mgmt.tar.gz",
                            f,
                            "application/vnd.redhat.hccm.filename+tgz",
                        )
                    },
                    timeout=60,
                )

            assert response.status_code == 401, (
                f"Expected 401 for unauthenticated upload, got {response.status_code}"
            )

        finally:
            Path(upload_file).unlink(missing_ok=True)

    def _create_upload_package(self, csv_data: str, cluster_id: str) -> str:
        """Create a tar.gz upload package with CSV and manifest."""
        temp_dir = tempfile.mkdtemp()
        csv_file = Path(temp_dir) / "openshift_usage_report.csv"
        manifest_file = Path(temp_dir) / "manifest.json"
        tar_file = Path(temp_dir) / "cost-mgmt.tar.gz"

        # Write CSV
        csv_file.write_text(csv_data)

        # Write manifest
        manifest = {
            "uuid": str(uuid.uuid4()),
            "cluster_id": cluster_id,
            "cluster_alias": "test-cluster",
            "date": datetime.now(timezone.utc).isoformat(),
            "files": ["openshift_usage_report.csv"],
            "resource_optimization_files": ["openshift_usage_report.csv"],
            "certified": True,
            "operator_version": "1.0.0",
            "daily_reports": False,
        }
        manifest_file.write_text(json.dumps(manifest, indent=2))

        # Create tar.gz
        with tarfile.open(tar_file, "w:gz") as tar:
            tar.add(csv_file, arcname="openshift_usage_report.csv")
            tar.add(manifest_file, arcname="manifest.json")

        return str(tar_file)


class TestRecommendations:
    """Tests for recommendation generation and retrieval."""

    @pytest.mark.recommendations
    def test_recommendations_endpoint_accessible(
        self,
        backend_api_url: str,
        jwt_token,
        http_session: requests.Session,
    ):
        """Verify recommendations endpoint is accessible."""
        response = http_session.get(
            f"{backend_api_url}/api/cost-management/v1/recommendations/openshift",
            headers=jwt_token.authorization_header,
            timeout=30,
        )

        assert response.status_code in [200, 404], (
            f"Recommendations endpoint failed: {response.status_code}"
        )

    @pytest.mark.recommendations
    def test_recommendations_response_format(
        self,
        backend_api_url: str,
        jwt_token,
        http_session: requests.Session,
    ):
        """Verify recommendations response has expected format."""
        response = http_session.get(
            f"{backend_api_url}/api/cost-management/v1/recommendations/openshift",
            headers=jwt_token.authorization_header,
            timeout=30,
        )

        if response.status_code == 404:
            pytest.skip("No recommendations available yet")

        assert response.status_code == 200

        data = response.json()
        # Response should be either a list or have a 'data' key
        assert isinstance(data, (list, dict)), "Invalid response format"


class TestEndToEndDataFlow:
    """End-to-end tests for the complete data flow."""

    def _check_ingress_available(
        self, ingress_url: str, http_session: requests.Session
    ) -> bool:
        """Check if ingress service is available (not returning 503)."""
        try:
            response = http_session.get(f"{ingress_url}/ready", timeout=5)
            return response.status_code != 503
        except requests.exceptions.RequestException:
            return False

    @pytest.mark.e2e
    @pytest.mark.slow
    @pytest.mark.timeout(300)
    def test_complete_data_flow(
        self,
        cluster_config,
        ingress_url: str,
        backend_api_url: str,
        jwt_token,
        test_csv_data: str,
        http_session: requests.Session,
    ):
        """Test complete data flow from upload to recommendations."""
        # Skip if ingress is not available (503 = pods not ready)
        if not self._check_ingress_available(ingress_url, http_session):
            pytest.skip(
                "Ingress service not available (503). Pods may not be ready yet."
            )

        # Generate unique cluster ID for this test
        cluster_id = f"e2e-test-{int(time.time())}-{uuid.uuid4().hex[:8]}"

        # Step 1: Upload data
        upload_file = self._create_upload_package(test_csv_data, cluster_id)
        try:
            with open(upload_file, "rb") as f:
                response = http_session.post(
                    f"{ingress_url}/v1/upload",
                    files={
                        "file": (
                            "cost-mgmt.tar.gz",
                            f,
                            "application/vnd.redhat.hccm.filename+tgz",
                        )
                    },
                    headers={
                        **jwt_token.authorization_header,
                        "x-rh-request-id": f"e2e-test-{int(time.time())}",
                    },
                    timeout=60,
                )

            assert response.status_code in [200, 202], (
                f"Upload failed: {response.status_code}"
            )
        finally:
            Path(upload_file).unlink(missing_ok=True)

        # Step 2: Wait for processing
        time.sleep(45)

        # Step 3: Check for experiments in Kruize database
        # Skip if Kruize pod not found (matches shell script line 689-695)
        if not self._check_kruize_pod_exists(cluster_config):
            pytest.skip(
                "Kruize pod not found. Use './query-kruize.sh --cluster <id>' "
                "to check recommendations later."
            )

        # Skip if database pod not found (matches shell script line 701-707)
        if not self._check_database_pod_exists(cluster_config):
            pytest.skip(
                "Database pod not found. Use './query-kruize.sh --cluster <id>' "
                "to check recommendations later."
            )

        # Skip if Kruize DB credentials not found (matches shell script line 715-718)
        if not self._check_kruize_credentials_exist(cluster_config):
            pytest.skip(
                f"Unable to retrieve Kruize database credentials from secret "
                f"'{cluster_config.helm_release_name}-db-credentials'. "
                "Use './query-kruize.sh --cluster <id>' to check recommendations later."
            )

        experiments_found = self._check_kruize_experiments(cluster_config, cluster_id)
        assert experiments_found > 0, (
            f"No Kruize experiments found for cluster {cluster_id}"
        )

        # Step 4: Check for recommendations (with retries)
        recommendations_found = self._check_recommendations_with_retry(
            cluster_config, cluster_id, max_retries=3, retry_interval=60
        )

        assert recommendations_found > 0, (
            f"No recommendations generated for cluster {cluster_id}"
        )

    def _create_upload_package(self, csv_data: str, cluster_id: str) -> str:
        """Create a tar.gz upload package with CSV and manifest."""
        temp_dir = tempfile.mkdtemp()
        csv_file = Path(temp_dir) / "openshift_usage_report.csv"
        manifest_file = Path(temp_dir) / "manifest.json"
        tar_file = Path(temp_dir) / "cost-mgmt.tar.gz"

        csv_file.write_text(csv_data)

        manifest = {
            "uuid": str(uuid.uuid4()),
            "cluster_id": cluster_id,
            "cluster_alias": "test-cluster",
            "date": datetime.now(timezone.utc).isoformat(),
            "files": ["openshift_usage_report.csv"],
            "resource_optimization_files": ["openshift_usage_report.csv"],
            "certified": True,
            "operator_version": "1.0.0",
            "daily_reports": False,
        }
        manifest_file.write_text(json.dumps(manifest, indent=2))

        with tarfile.open(tar_file, "w:gz") as tar:
            tar.add(csv_file, arcname="openshift_usage_report.csv")
            tar.add(manifest_file, arcname="manifest.json")

        return str(tar_file)

    def _check_kruize_pod_exists(self, cluster_config) -> bool:
        """Check if Kruize pod exists (matches shell script line 689-695)."""
        try:
            result = run_oc_command([
                "get", "pods", "-n", cluster_config.namespace,
                "-l", "app.kubernetes.io/name=kruize",
                "-o", "jsonpath={.items[0].metadata.name}"
            ], check=False)
            return bool(result.stdout.strip())
        except subprocess.CalledProcessError:
            return False

    def _check_database_pod_exists(self, cluster_config) -> bool:
        """Check if database pod exists (matches shell script line 701-707)."""
        try:
            result = run_oc_command([
                "get", "pods", "-n", cluster_config.namespace,
                "-l", "app.kubernetes.io/name=database",
                "-o", "jsonpath={.items[0].metadata.name}"
            ], check=False)
            return bool(result.stdout.strip())
        except subprocess.CalledProcessError:
            return False

    def _check_kruize_credentials_exist(self, cluster_config) -> bool:
        """Check if Kruize DB credentials exist (matches shell script line 715-718)."""
        secret_name = f"{cluster_config.helm_release_name}-db-credentials"
        kruize_user = get_secret_value(
            cluster_config.namespace, secret_name, "kruize-user"
        )
        kruize_password = get_secret_value(
            cluster_config.namespace, secret_name, "kruize-password"
        )
        return bool(kruize_user and kruize_password)

    def _check_kruize_experiments(
        self, cluster_config, cluster_id: str
    ) -> int:
        """Check Kruize database for experiments matching the cluster ID."""
        try:
            # Get database pod
            result = run_oc_command([
                "get", "pods", "-n", cluster_config.namespace,
                "-l", "app.kubernetes.io/name=database",
                "-o", "jsonpath={.items[0].metadata.name}"
            ])
            db_pod = result.stdout.strip()
            if not db_pod:
                return 0

            # Get Kruize database credentials
            secret_name = f"{cluster_config.helm_release_name}-db-credentials"
            kruize_user = get_secret_value(
                cluster_config.namespace, secret_name, "kruize-user"
            )
            kruize_password = get_secret_value(
                cluster_config.namespace, secret_name, "kruize-password"
            )

            if not kruize_user or not kruize_password:
                return 0

            # Query for experiments
            query = (
                f"SELECT COUNT(*) FROM kruize_experiments "
                f"WHERE cluster_name LIKE '%{cluster_id}%';"
            )
            result = run_oc_command([
                "exec", "-n", cluster_config.namespace, db_pod, "--",
                "env", f"PGPASSWORD={kruize_password}",
                "psql", "-U", kruize_user, "-d", "kruize_db", "-t", "-c", query
            ], check=False)

            count = result.stdout.strip()
            return int(count) if count.isdigit() else 0

        except (subprocess.CalledProcessError, ValueError):
            return 0

    def _check_recommendations_with_retry(
        self,
        cluster_config,
        cluster_id: str,
        max_retries: int = 3,
        retry_interval: int = 60,
    ) -> int:
        """Check for recommendations with retries."""
        for attempt in range(max_retries):
            if attempt > 0:
                time.sleep(retry_interval)

            count = self._check_kruize_recommendations(cluster_config, cluster_id)
            if count > 0:
                return count

        return 0

    def _check_kruize_recommendations(
        self, cluster_config, cluster_id: str
    ) -> int:
        """Check Kruize database for recommendations matching the cluster ID."""
        try:
            # Get database pod
            result = run_oc_command([
                "get", "pods", "-n", cluster_config.namespace,
                "-l", "app.kubernetes.io/name=database",
                "-o", "jsonpath={.items[0].metadata.name}"
            ])
            db_pod = result.stdout.strip()
            if not db_pod:
                return 0

            # Get Kruize database credentials
            secret_name = f"{cluster_config.helm_release_name}-db-credentials"
            kruize_user = get_secret_value(
                cluster_config.namespace, secret_name, "kruize-user"
            )
            kruize_password = get_secret_value(
                cluster_config.namespace, secret_name, "kruize-password"
            )

            if not kruize_user or not kruize_password:
                return 0

            # Query for recommendations
            query = (
                f"SELECT COUNT(*) FROM kruize_recommendations "
                f"WHERE cluster_name LIKE '%{cluster_id}%';"
            )
            result = run_oc_command([
                "exec", "-n", cluster_config.namespace, db_pod, "--",
                "env", f"PGPASSWORD={kruize_password}",
                "psql", "-U", kruize_user, "-d", "kruize_db", "-t", "-c", query
            ], check=False)

            count = result.stdout.strip()
            return int(count) if count.isdigit() else 0

        except (subprocess.CalledProcessError, ValueError):
            return 0

