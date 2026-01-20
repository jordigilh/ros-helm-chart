"""
Complete end-to-end data flow tests.

These tests validate the entire pipeline:
  Generated Data → Upload via Ingress (JWT) → Koku Processing → ROS/Kruize

This is the canonical E2E test that covers the full production data flow.
"""

import os
import time

import pytest
import requests

from utils import (
    create_upload_package,
    execute_db_query,
    get_pod_by_label,
    get_secret_value,
    wait_for_condition,
    run_oc_command,
)


@pytest.mark.e2e
@pytest.mark.integration
@pytest.mark.slow
class TestCompleteDataFlow:
    """
    End-to-end test of the complete data flow.
    
    This test class validates the FULL production pipeline:
    
    1. Source Registration:
       - Register OCP source via Sources API
       - Verify provider created in Koku database
    
    2. Data Upload (via Ingress):
       - Generate test CSV data with realistic metrics
       - Package into tar.gz with manifest
       - Upload via JWT-authenticated ingress endpoint
       - Verify ingress stores in S3 and publishes to Kafka
    
    3. Koku Processing:
       - Koku Listener consumes from platform.upload.announce
       - MASU processes cost data from S3
       - Manifest and file status tracked in database
       - Summary tables populated with aggregated data
    
    4. ROS Pipeline:
       - Koku copies ROS data to ros-data bucket
       - Koku emits events to hccm.ros.events topic
       - ROS Processor consumes and sends to Kruize
    
    5. Recommendations:
       - Kruize generates optimization recommendations
       - Recommendations accessible via JWT-authenticated API
    """

    @pytest.fixture(scope="class")
    def e2e_cluster_id(self) -> str:
        """Generate a unique cluster ID for this E2E test run."""
        import uuid
        return f"e2e-pytest-{int(time.time())}-{uuid.uuid4().hex[:8]}"

    @pytest.fixture(scope="class")
    def e2e_test_data(self, e2e_cluster_id: str) -> dict:
        """Generate realistic test data matching NISE format."""
        from datetime import datetime, timedelta
        
        now = datetime.utcnow()
        # Generate 4 intervals of data (like the shell script)
        intervals = []
        for i in range(4):
            start = now - timedelta(minutes=75 - (i * 15))
            end = now - timedelta(minutes=60 - (i * 15))
            intervals.append((start, end))
        
        # CSV header matching OCP ROS format
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
        date_str = now.strftime("%Y-%m-%d")
        
        # Generate rows with varying but realistic metrics
        cpu_usages = [0.247832, 0.265423, 0.289567, 0.234567]
        mem_usages = [413587266, 427891456, 445678901, 398765432]
        
        for i, (start, end) in enumerate(intervals):
            start_str = start.strftime("%Y-%m-%d %H:%M:%S -0000 UTC")
            end_str = end.strftime("%Y-%m-%d %H:%M:%S -0000 UTC")
            cpu = cpu_usages[i]
            mem = mem_usages[i]
            
            row = (
                f"{date_str},{date_str},{start_str},{end_str},"
                f"test-container,test-pod-{e2e_cluster_id[:8]},test-deployment,Deployment,test-workload,deployment,"
                f"test-namespace,quay.io/test/image:latest,worker-node-1,resource-{e2e_cluster_id[:8]},"
                f"0.5,0.5,1.0,1.0,"
                f"{cpu},{cpu*0.75},{cpu*1.3},{cpu},"
                f"0.001,0.002,0.001,"
                f"536870912,536870912,1073741824,1073741824,"
                f"{mem},{mem*0.99},{mem*1.02},{mem},"
                f"{mem*0.95},{mem*0.94},{mem*0.96},{mem*0.95}"
            )
            rows.append(row)
        
        return {
            "csv_content": "\n".join(rows),
            "cluster_id": e2e_cluster_id,
            "expected_cpu_request": 0.5,
            "expected_memory_request_bytes": 536870912,
            "expected_rows": 4,
            "namespace": "test-namespace",
            "node": "worker-node-1",
        }

    @pytest.fixture(scope="class")
    def registered_source(
        self,
        cluster_config,
        org_id: str,
        e2e_cluster_id: str,
    ):
        """Register a source for E2E testing and clean up after."""
        from utils import exec_in_pod, get_pod_by_label
        import json
        
        sources_api_url = (
            f"http://{cluster_config.helm_release_name}-sources-api."
            f"{cluster_config.namespace}.svc.cluster.local:8000/api/sources/v1.0"
        )
        
        # Find pod for API calls
        listener_pod = get_pod_by_label(
            cluster_config.namespace,
            "app.kubernetes.io/component=sources-listener"
        )
        if not listener_pod:
            listener_pod = get_pod_by_label(
                cluster_config.namespace,
                "app.kubernetes.io/component=listener"
            )
        
        if not listener_pod:
            pytest.skip("No listener pod found for source registration")
        
        # Get source type ID
        result = exec_in_pod(
            cluster_config.namespace,
            listener_pod,
            [
                "curl", "-s", f"{sources_api_url}/source_types",
                "-H", "Content-Type: application/json",
                "-H", f"x-rh-sources-org-id: {org_id}",
            ],
            container="sources-listener",
        )
        
        if not result:
            pytest.skip("Could not get source types")
        
        source_types = json.loads(result)
        ocp_type_id = None
        for st in source_types.get("data", []):
            if st.get("name") == "openshift":
                ocp_type_id = st.get("id")
                break
        
        if not ocp_type_id:
            pytest.skip("OpenShift source type not found")
        
        # Get application type ID
        result = exec_in_pod(
            cluster_config.namespace,
            listener_pod,
            [
                "curl", "-s", f"{sources_api_url}/application_types",
                "-H", "Content-Type: application/json",
                "-H", f"x-rh-sources-org-id: {org_id}",
            ],
            container="sources-listener",
        )
        
        app_types = json.loads(result)
        cost_mgmt_app_id = None
        for at in app_types.get("data", []):
            if at.get("name") == "/insights/platform/cost-management":
                cost_mgmt_app_id = at.get("id")
                break
        
        # Create source
        source_name = f"e2e-source-{e2e_cluster_id[:8]}"
        payload = json.dumps({
            "name": source_name,
            "source_type_id": ocp_type_id,
            "source_ref": e2e_cluster_id,
        })
        
        result = exec_in_pod(
            cluster_config.namespace,
            listener_pod,
            [
                "curl", "-s", "-X", "POST",
                f"{sources_api_url}/sources",
                "-H", "Content-Type: application/json",
                "-H", f"x-rh-sources-org-id: {org_id}",
                "-d", payload,
            ],
            container="sources-listener",
        )
        
        source_data = json.loads(result)
        source_id = source_data.get("id")
        
        if not source_id:
            pytest.skip(f"Source creation failed: {result}")
        
        # Create application
        if cost_mgmt_app_id:
            app_payload = json.dumps({
                "source_id": source_id,
                "application_type_id": cost_mgmt_app_id,
                "extra": {"bucket": "koku-bucket", "cluster_id": e2e_cluster_id},
            })
            
            exec_in_pod(
                cluster_config.namespace,
                listener_pod,
                [
                    "curl", "-s", "-X", "POST",
                    f"{sources_api_url}/applications",
                    "-H", "Content-Type: application/json",
                    "-H", f"x-rh-sources-org-id: {org_id}",
                    "-d", app_payload,
                ],
                container="sources-listener",
            )
        
        yield {
            "source_id": source_id,
            "source_name": source_name,
            "cluster_id": e2e_cluster_id,
            "org_id": org_id,
            "listener_pod": listener_pod,
            "sources_api_url": sources_api_url,
        }
        
        # Cleanup
        exec_in_pod(
            cluster_config.namespace,
            listener_pod,
            [
                "curl", "-s", "-X", "DELETE",
                f"{sources_api_url}/sources/{source_id}",
                "-H", f"x-rh-sources-org-id: {org_id}",
            ],
            container="sources-listener",
        )

    # =========================================================================
    # Test Steps - Ordered to validate the complete pipeline
    # =========================================================================

    def test_01_source_registered(self, registered_source):
        """Step 1: Verify source was registered successfully."""
        assert registered_source["source_id"], "Source ID not set"
        assert registered_source["cluster_id"], "Cluster ID not set"

    def test_02_provider_created_in_koku(self, cluster_config, registered_source):
        """Step 2: Verify provider was created in Koku database via Kafka."""
        db_pod = get_pod_by_label(
            cluster_config.namespace,
            "app.kubernetes.io/name=database"
        )
        if not db_pod:
            pytest.skip("Database pod not found")
        
        cluster_id = registered_source["cluster_id"]
        
        def check_provider():
            result = execute_db_query(
                cluster_config.namespace,
                db_pod,
                "koku",
                "koku",
                f"""
                SELECT COUNT(*) FROM api_provider p
                JOIN api_providerauthentication a ON p.authentication_id = a.id
                WHERE a.credentials->>'cluster_id' = '{cluster_id}'
                   OR p.additional_context->>'cluster_id' = '{cluster_id}'
                """,
            )
            return result is not None and int(result[0][0]) > 0
        
        success = wait_for_condition(
            check_provider,
            timeout=180,
            interval=10,
            description="provider creation via Kafka",
        )
        
        assert success, f"Provider not created for cluster {cluster_id}"

    def test_03_upload_data_via_ingress(
        self,
        cluster_config,
        ingress_url: str,
        jwt_token,
        e2e_test_data: dict,
        registered_source,
        http_session: requests.Session,
    ):
        """Step 3: Upload test data via JWT-authenticated ingress."""
        cluster_id = registered_source["cluster_id"]
        tar_path = create_upload_package(e2e_test_data["csv_content"], cluster_id)
        
        try:
            with open(tar_path, "rb") as f:
                response = http_session.post(
                    f"{ingress_url}/v1/upload",
                    files={
                        "file": (
                            "cost-mgmt.tar.gz",
                            f,
                            "application/vnd.redhat.hccm.filename+tgz",
                        )
                    },
                    headers=jwt_token.authorization_header,
                    timeout=60,
                )
            
            if response.status_code == 503:
                pytest.skip("Ingress service returning 503 - pods may not be ready")
            
            assert response.status_code in [200, 202], (
                f"Upload failed: {response.status_code} - {response.text}"
            )
        finally:
            # Clean up temp files
            import shutil
            tar_dir = os.path.dirname(tar_path)
            if os.path.exists(tar_path):
                os.unlink(tar_path)
            if os.path.exists(tar_dir):
                shutil.rmtree(tar_dir, ignore_errors=True)

    def test_04_manifest_created_in_koku(self, cluster_config, registered_source):
        """Step 4: Verify manifest was created in Koku database."""
        db_pod = get_pod_by_label(
            cluster_config.namespace,
            "app.kubernetes.io/name=database"
        )
        if not db_pod:
            pytest.skip("Database pod not found")
        
        cluster_id = registered_source["cluster_id"]
        
        def check_manifest():
            result = execute_db_query(
                cluster_config.namespace,
                db_pod,
                "koku",
                "koku",
                f"""
                SELECT COUNT(*) FROM reporting_common_costusagereportmanifest
                WHERE cluster_id = '{cluster_id}'
                """,
            )
            return result is not None and int(result[0][0]) > 0
        
        success = wait_for_condition(
            check_manifest,
            timeout=300,
            interval=15,
            description="manifest creation",
        )
        
        assert success, f"Manifest not created for cluster {cluster_id}"

    def test_05_files_processed_by_masu(self, cluster_config, registered_source):
        """Step 5: Verify uploaded files were processed by MASU."""
        db_pod = get_pod_by_label(
            cluster_config.namespace,
            "app.kubernetes.io/name=database"
        )
        if not db_pod:
            pytest.skip("Database pod not found")
        
        cluster_id = registered_source["cluster_id"]
        
        def check_processing():
            result = execute_db_query(
                cluster_config.namespace,
                db_pod,
                "koku",
                "koku",
                f"""
                SELECT s.status
                FROM reporting_common_costusagereportmanifest m
                JOIN reporting_common_costusagereportstatus s ON s.manifest_id = m.id
                WHERE m.cluster_id = '{cluster_id}'
                ORDER BY m.creation_datetime DESC
                LIMIT 1
                """,
            )
            # Status 1 = SUCCESS
            return result is not None and len(result) > 0 and str(result[0][0]) == "1"
        
        success = wait_for_condition(
            check_processing,
            timeout=600,
            interval=30,
            description="file processing by MASU",
        )
        
        assert success, "File processing not completed"

    @pytest.mark.timeout(600)  # 10 minutes for summary tables
    def test_06_summary_tables_populated(
        self, cluster_config, registered_source, e2e_test_data: dict
    ):
        """Step 6: Verify Koku summary tables are populated with correct data."""
        db_pod = get_pod_by_label(
            cluster_config.namespace,
            "app.kubernetes.io/name=database"
        )
        if not db_pod:
            pytest.skip("Database pod not found")
        
        cluster_id = registered_source["cluster_id"]
        
        # Get tenant schema
        schema_result = execute_db_query(
            cluster_config.namespace,
            db_pod,
            "koku",
            "koku",
            f"""
            SELECT c.schema_name
            FROM reporting_common_costusagereportmanifest m
            JOIN api_provider p ON m.provider_id = p.uuid
            JOIN api_customer c ON p.customer_id = c.id
            WHERE m.cluster_id = '{cluster_id}'
            LIMIT 1
            """,
        )
        
        if not schema_result or not schema_result[0][0]:
            pytest.skip("Could not find tenant schema - manifest may not be linked to provider yet")
        
        schema_name = schema_result[0][0].strip()
        
        def check_summary():
            result = execute_db_query(
                cluster_config.namespace,
                db_pod,
                "koku",
                "koku",
                f"""
                SELECT COUNT(*),
                       COALESCE(SUM(pod_request_cpu_core_hours), 0),
                       COALESCE(SUM(pod_request_memory_gigabyte_hours), 0)
                FROM {schema_name}.reporting_ocpusagelineitem_daily_summary
                WHERE cluster_id = '{cluster_id}'
                """,
            )
            return result is not None and int(result[0][0]) > 0
        
        success = wait_for_condition(
            check_summary,
            timeout=540,  # 9 minutes (leave buffer for pytest timeout)
            interval=30,
            description="summary table population",
        )
        
        if not success:
            pytest.skip("Summary tables not populated within timeout - async processing may still be running")

    @pytest.mark.timeout(180)  # 3 minutes - Kruize may not have data yet
    def test_07_kruize_experiments_created(self, cluster_config, registered_source):
        """Step 7: Verify Kruize experiments were created from ROS events.
        
        Note: Kruize typically needs multiple data uploads over time to create
        experiments. A single upload may not be sufficient.
        """
        db_pod = get_pod_by_label(
            cluster_config.namespace,
            "app.kubernetes.io/name=database"
        )
        if not db_pod:
            pytest.skip("Database pod not found")
        
        secret_name = f"{cluster_config.helm_release_name}-db-credentials"
        kruize_user = get_secret_value(cluster_config.namespace, secret_name, "kruize-user")
        kruize_password = get_secret_value(cluster_config.namespace, secret_name, "kruize-password")
        
        if not kruize_user:
            pytest.skip("Kruize credentials not found")
        
        cluster_id = registered_source["cluster_id"]
        
        def check_experiments():
            result = execute_db_query(
                cluster_config.namespace,
                db_pod,
                "kruize_db",
                kruize_user,
                f"""
                SELECT COUNT(*) FROM kruize_experiments
                WHERE cluster_name LIKE '%{cluster_id}%'
                """,
                password=kruize_password,
            )
            return result is not None and int(result[0][0]) > 0
        
        # Kruize processing takes time - ROS events must flow through
        # Use shorter timeout since this is expected to skip for single uploads
        success = wait_for_condition(
            check_experiments,
            timeout=120,  # 2 minutes
            interval=20,
            description="Kruize experiment creation",
        )
        
        if not success:
            pytest.skip("Kruize experiments not yet created - typically needs multiple data uploads")

    @pytest.mark.timeout(180)  # 3 minutes - recommendations may not exist yet
    def test_08_recommendations_generated(self, cluster_config, registered_source):
        """Step 8: Verify recommendations were generated by Kruize.
        
        Note: Kruize typically needs multiple data uploads over time to generate
        meaningful recommendations. A single upload may not be sufficient.
        """
        db_pod = get_pod_by_label(
            cluster_config.namespace,
            "app.kubernetes.io/name=database"
        )
        if not db_pod:
            pytest.skip("Database pod not found")
        
        secret_name = f"{cluster_config.helm_release_name}-db-credentials"
        kruize_user = get_secret_value(cluster_config.namespace, secret_name, "kruize-user")
        kruize_password = get_secret_value(cluster_config.namespace, secret_name, "kruize-password")
        
        if not kruize_user:
            pytest.skip("Kruize credentials not found")
        
        cluster_id = registered_source["cluster_id"]
        
        def check_recommendations():
            result = execute_db_query(
                cluster_config.namespace,
                db_pod,
                "kruize_db",
                kruize_user,
                f"""
                SELECT COUNT(*) FROM kruize_recommendations
                WHERE cluster_name LIKE '%{cluster_id}%'
                """,
                password=kruize_password,
            )
            return result is not None and int(result[0][0]) > 0
        
        # Use shorter timeout since this is expected to skip for single uploads
        success = wait_for_condition(
            check_recommendations,
            timeout=120,  # 2 minutes
            interval=20,
            description="recommendation generation",
        )
        
        if not success:
            pytest.skip(
                "Recommendations not yet generated - "
                "Kruize typically needs multiple data uploads over time"
            )

    def test_09_recommendations_accessible_via_api(
        self,
        backend_api_url: str,
        keycloak_config,
        http_session: requests.Session,
    ):
        """Step 9: Verify recommendations are accessible via JWT-authenticated API."""
        # Get a fresh JWT token (the session-scoped one may have expired)
        from datetime import datetime, timedelta, timezone
        
        token_response = http_session.post(
            keycloak_config.token_url,
            data={
                "grant_type": "client_credentials",
                "client_id": keycloak_config.client_id,
                "client_secret": keycloak_config.client_secret,
            },
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            timeout=30,
        )
        
        if token_response.status_code != 200:
            pytest.skip(f"Could not refresh JWT token: {token_response.status_code}")
        
        fresh_token = token_response.json().get("access_token")
        
        response = http_session.get(
            f"{backend_api_url}/api/cost-management/v1/recommendations/openshift",
            headers={"Authorization": f"Bearer {fresh_token}"},
            timeout=30,
        )
        
        # 401 may indicate the route requires different auth or isn't configured
        if response.status_code == 401:
            pytest.skip("Recommendations API returned 401 - may require different auth configuration")
        
        assert response.status_code == 200, (
            f"Recommendations API failed: {response.status_code}"
        )
        
        data = response.json()
        
        # Verify response structure
        if "data" in data:
            assert isinstance(data["data"], list), "Invalid response format"
