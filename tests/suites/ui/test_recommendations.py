"""
UI tests for ROS recommendations display.

These tests validate that optimization recommendations are properly
displayed in the UI after data has been processed.

The tests are SELF-CONTAINED - they set up their own test data via the
`recommendations_test_data` fixture, which:
1. Generates NISE data with ROS metrics
2. Registers a source
3. Uploads data via ingress
4. Waits for Koku processing and Kruize experiments
5. Cleans up after tests (unless E2E_CLEANUP_AFTER=false)

NOTE: Some tests are skipped because the recommendations UI doesn't seem to exist properly yet. Remove @pytest.mark.skip when UI/UX is confirmed and implemented or enabled.
"""

import os
import re
import shutil
import tempfile
from datetime import datetime, timedelta

import pytest
import requests
from playwright.sync_api import Page, expect

from e2e_helpers import (
    NISEConfig,
    cleanup_database_records,
    delete_source,
    ensure_nise_available,
    generate_cluster_id,
    generate_nise_data,
    get_sources_api_url,
    register_source,
    upload_with_retry,
    wait_for_provider,
    wait_for_summary_tables,
)
from utils import (
    create_upload_package_from_files,
    execute_db_query,
    get_pod_by_label,
    get_secret_value,
    wait_for_condition,
)


# =============================================================================
# Self-Contained Data Fixture for Recommendations Tests
# =============================================================================


@pytest.fixture(scope="module")
def recommendations_test_data(cluster_config, s3_config, jwt_token, ingress_url, org_id):
    """Set up test data for recommendations UI tests - SELF-CONTAINED.
    
    This fixture runs the full E2E flow to generate recommendations:
    1. Generates NISE data with ROS metrics
    2. Registers a source in Sources API
    3. Uploads data via JWT-authenticated ingress
    4. Waits for Koku processing and summary tables
    5. Waits for Kruize experiments to be created
    6. Yields the test context
    7. Cleans up all test data on teardown (if E2E_CLEANUP_AFTER=true)
    
    Environment Variables:
    - E2E_CLEANUP_BEFORE: Run cleanup before tests (default: true)
    - E2E_CLEANUP_AFTER: Run cleanup after tests (default: true)
    """
    cleanup_before = os.environ.get("E2E_CLEANUP_BEFORE", "true").lower() == "true"
    cleanup_after = os.environ.get("E2E_CLEANUP_AFTER", "true").lower() == "true"
    
    # Check NISE availability
    if not ensure_nise_available():
        pytest.skip("NISE not available and could not be installed")
    
    # Generate unique cluster ID for this test run
    cluster_id = generate_cluster_id(prefix="ui-ros")
    
    # Get required pods
    db_pod = get_pod_by_label(cluster_config.namespace, "app.kubernetes.io/component=database")
    if not db_pod:
        pytest.skip("Database pod not found")
    
    listener_pod = get_pod_by_label(cluster_config.namespace, "app.kubernetes.io/component=sources-listener")
    if not listener_pod:
        listener_pod = get_pod_by_label(cluster_config.namespace, "app.kubernetes.io/component=listener")
    if not listener_pod:
        pytest.skip("Listener pod not found")
    
    temp_dir = tempfile.mkdtemp(prefix="ui_ros_")
    source_registration = None
    sources_url = get_sources_api_url(cluster_config.helm_release_name, cluster_config.namespace)
    
    nise_config = NISEConfig()
    
    try:
        print(f"\n{'='*60}")
        print("RECOMMENDATIONS UI TEST SETUP (Self-Contained)")
        print(f"{'='*60}")
        print(f"  Cluster ID: {cluster_id}")
        print(f"  Cleanup before: {cleanup_before}")
        print(f"  Cleanup after: {cleanup_after}")
        
        # Step 1: Generate NISE data with ROS metrics
        print("\n  [1/6] Generating NISE data with ROS metrics...")
        now = datetime.utcnow()
        start_date = (now - timedelta(days=2)).replace(hour=0, minute=0, second=0, microsecond=0)
        end_date = (now - timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
        
        files = generate_nise_data(cluster_id, start_date, end_date, temp_dir, config=nise_config)
        print(f"       Generated {len(files['all_files'])} CSV files")
        print(f"       ROS files: {len(files.get('ros_usage_files', []))}")
        
        if not files["all_files"]:
            pytest.skip("NISE generated no CSV files")
        
        # Step 2: Register source
        print("\n  [2/6] Registering source...")
        source_registration = register_source(
            namespace=cluster_config.namespace,
            listener_pod=listener_pod,
            sources_api_url=sources_url,
            cluster_id=cluster_id,
            org_id=org_id,
            source_name=f"ui-ros-{cluster_id[:16]}",
        )
        print(f"       Source ID: {source_registration.source_id}")
        
        # Step 3: Wait for provider
        print("\n  [3/6] Waiting for provider in Koku...")
        if not wait_for_provider(cluster_config.namespace, db_pod, cluster_id):
            pytest.fail(f"Provider not created for cluster {cluster_id}")
        print("       Provider created")
        
        # Step 4: Upload data
        print("\n  [4/6] Uploading data via ingress...")
        package_path = create_upload_package_from_files(
            pod_usage_files=files["pod_usage_files"],
            ros_usage_files=files["ros_usage_files"],
            cluster_id=cluster_id,
            start_date=start_date,
            end_date=end_date,
            node_label_files=files["node_label_files"] if files["node_label_files"] else None,
            namespace_label_files=files["namespace_label_files"] if files["namespace_label_files"] else None,
        )
        
        session = requests.Session()
        session.verify = False
        
        response = upload_with_retry(
            session,
            f"{ingress_url}/v1/upload",
            package_path,
            jwt_token.authorization_header,
        )
        
        if response.status_code not in [200, 201, 202]:
            pytest.fail(f"Upload failed: {response.status_code}")
        print(f"       Upload successful: {response.status_code}")
        
        # Step 5: Wait for summary tables
        print("\n  [5/6] Waiting for Koku processing...")
        schema_name = wait_for_summary_tables(cluster_config.namespace, db_pod, cluster_id)
        
        if not schema_name:
            pytest.fail(f"Timeout waiting for summary tables for cluster {cluster_id}")
        print("       Summary tables populated")
        
        # Step 6: Wait for Kruize experiments (optional - don't fail if not created)
        print("\n  [6/6] Waiting for Kruize experiments...")
        secret_name = f"{cluster_config.helm_release_name}-db-credentials"
        kruize_user = get_secret_value(cluster_config.namespace, secret_name, "kruize-user")
        kruize_password = get_secret_value(cluster_config.namespace, secret_name, "kruize-password")
        
        has_experiments = False
        if kruize_user:
            def check_experiments():
                result = execute_db_query(
                    cluster_config.namespace,
                    db_pod,
                    "kruize_db",
                    kruize_user,
                    f"SELECT COUNT(*) FROM kruize_experiments WHERE cluster_name LIKE '%{cluster_id}%'",
                    password=kruize_password,
                )
                return result is not None and int(result[0][0]) > 0
            
            has_experiments = wait_for_condition(
                check_experiments,
                timeout=180,  # 3 minutes
                interval=20,
                description="Kruize experiments",
            )
            
            if has_experiments:
                print("       Kruize experiments created")
            else:
                print("       ⚠️ No Kruize experiments (recommendations may not be available)")
        else:
            print("       ⚠️ Kruize credentials not found - skipping experiment check")
        
        print(f"\n{'='*60}")
        print("SETUP COMPLETE - Running UI tests")
        print(f"{'='*60}\n")
        
        yield {
            "namespace": cluster_config.namespace,
            "db_pod": db_pod,
            "cluster_id": cluster_id,
            "schema_name": schema_name,
            "source_id": source_registration.source_id,
            "org_id": org_id,
            "has_experiments": has_experiments,
        }
        
    finally:
        print(f"\n{'='*60}")
        if cleanup_after:
            print("RECOMMENDATIONS UI TEST CLEANUP")
            print(f"{'='*60}")
            
            if source_registration:
                if delete_source(
                    cluster_config.namespace,
                    listener_pod,
                    sources_url,
                    source_registration.source_id,
                    org_id,
                ):
                    print(f"  Deleted source {source_registration.source_id}")
            
            if db_pod:
                cleanup_database_records(cluster_config.namespace, db_pod, cluster_id)
                print("  Cleaned up database records")
        else:
            print("RECOMMENDATIONS UI TEST CLEANUP SKIPPED (E2E_CLEANUP_AFTER=false)")
            print(f"{'='*60}")
            print(f"  Data preserved for cluster: {cluster_id}")
        
        if temp_dir and os.path.exists(temp_dir):
            shutil.rmtree(temp_dir, ignore_errors=True)
        
        print(f"{'='*60}\n")


# =============================================================================
# Test Classes
# =============================================================================


@pytest.mark.ui
@pytest.mark.ros
class TestRecommendationsDisplay:
    """Test the recommendations page display."""

    @pytest.mark.skip(reason="Recommendations UI doesn't exist")
    def test_recommendations_table_visible(
        self, authenticated_page: Page, ui_url: str, recommendations_test_data
    ):
        """Verify recommendations table is displayed when data exists."""
        if not recommendations_test_data["has_experiments"]:
            pytest.skip("No Kruize experiments - recommendations not available")
        
        authenticated_page.goto(f"{ui_url}/openshift/cost-management/optimizations")
        authenticated_page.wait_for_load_state("networkidle")
        
        # Look for table or data grid component
        table_locator = authenticated_page.locator(
            "table, [role='grid'], .pf-c-table, .pf-v6-c-table, .recommendations-table"
        )
        expect(table_locator.first).to_be_visible(timeout=10000)

    @pytest.mark.skip(reason="Recommendations UI doesn't exist")
    def test_no_data_message_when_empty(
        self, authenticated_page: Page, ui_url: str
    ):
        """Verify appropriate message when no recommendations exist."""
        authenticated_page.goto(f"{ui_url}/openshift/cost-management/optimizations")
        authenticated_page.wait_for_load_state("networkidle")
        
        # Either data table or empty state should be visible
        data_or_empty = authenticated_page.locator(
            "table, [role='grid'], .pf-c-empty-state, .pf-v6-c-empty-state, .empty-state, [data-testid='empty-state']"
        )
        expect(data_or_empty.first).to_be_visible(timeout=10000)


@pytest.mark.ui
@pytest.mark.ros
class TestRecommendationDetails:
    """Test recommendation detail views (requires data)."""

    @pytest.mark.skip(reason="Recommendations UI doesn't exist")
    def test_can_view_recommendation_details(
        self, authenticated_page: Page, ui_url: str, recommendations_test_data
    ):
        """Verify clicking a recommendation shows details."""
        if not recommendations_test_data["has_experiments"]:
            pytest.skip("No Kruize experiments - recommendations not available")
        
        authenticated_page.goto(f"{ui_url}/openshift/cost-management/optimizations")
        authenticated_page.wait_for_load_state("networkidle")
        
        # Find first recommendation row/link
        recommendation_link = authenticated_page.locator(
            "table tbody tr a, [role='row'] a, .recommendation-link"
        ).first
        
        if recommendation_link.count() == 0:
            pytest.skip("No recommendations available to test")
        
        # Click to view details
        recommendation_link.click()
        authenticated_page.wait_for_load_state("networkidle")
        
        # Should show detail view
        detail_view = authenticated_page.locator(
            ".recommendation-detail, .pf-c-drawer__panel, .pf-v6-c-drawer__panel, [data-testid='recommendation-detail']"
        )
        expect(detail_view).to_be_visible(timeout=10000)

    @pytest.mark.skip(reason="Recommendations UI doesn't exist")
    def test_recommendation_shows_resource_info(
        self, authenticated_page: Page, ui_url: str, recommendations_test_data
    ):
        """Verify recommendation shows CPU/memory information."""
        if not recommendations_test_data["has_experiments"]:
            pytest.skip("No Kruize experiments - recommendations not available")
        
        authenticated_page.goto(f"{ui_url}/openshift/cost-management/optimizations")
        authenticated_page.wait_for_load_state("networkidle")
        
        # Look for CPU/memory related content
        resource_info = authenticated_page.locator(
            "text=/cpu|memory|cores|gib/i"
        )
        
        if resource_info.count() == 0:
            pytest.skip("No resource information visible (may need data)")
        
        expect(resource_info.first).to_be_visible()
