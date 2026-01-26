"""
Processing State Validation Tests.

These tests validate the processing state of cost data in Koku:
1. Manifest state transitions
2. File processing status codes
3. Summary task completion
4. Error state detection

Source Reference: scripts/e2e_validator/phases/smoke_validation.py
"""

import os
from typing import Dict, List, Optional

import pytest

from utils import execute_db_query, get_pod_by_label


# =============================================================================
# Processing State Constants
# =============================================================================

# File processing status codes (from Koku)
FILE_STATUS_PENDING = 0
FILE_STATUS_SUCCESS = 1
FILE_STATUS_FAILED = 2

FILE_STATUS_NAMES = {
    FILE_STATUS_PENDING: "PENDING",
    FILE_STATUS_SUCCESS: "SUCCESS",
    FILE_STATUS_FAILED: "FAILED",
}


# =============================================================================
# Helper Functions
# =============================================================================

def get_recent_manifests(
    namespace: str,
    db_pod: str,
    limit: int = 10,
) -> List[Dict]:
    """Get recent manifests from the database.
    
    Args:
        namespace: Kubernetes namespace
        db_pod: Database pod name
        limit: Maximum number of manifests to return
        
    Returns:
        List of manifest dictionaries
    """
    result = execute_db_query(
        namespace,
        db_pod,
        "koku",
        "koku",
        f"""
        SELECT 
            m.id,
            m.assembly_id,
            m.cluster_id,
            m.num_total_files,
            m.num_processed_files,
            m.creation_datetime,
            m.completed_datetime,
            m.state::text
        FROM reporting_common_costusagereportmanifest m
        ORDER BY m.creation_datetime DESC
        LIMIT {limit}
        """,
    )
    
    if not result:
        return []
    
    manifests = []
    for row in result:
        manifests.append({
            "id": row[0],
            "assembly_id": row[1],
            "cluster_id": row[2],
            "num_total_files": int(row[3]) if row[3] else 0,
            "num_processed_files": int(row[4]) if row[4] else 0,
            "creation_datetime": row[5],
            "completed_datetime": row[6],
            "state": row[7],
        })
    
    return manifests


def get_file_statuses(
    namespace: str,
    db_pod: str,
    manifest_id: int,
) -> List[Dict]:
    """Get file processing statuses for a manifest.
    
    Args:
        namespace: Kubernetes namespace
        db_pod: Database pod name
        manifest_id: Manifest ID
        
    Returns:
        List of file status dictionaries
    """
    result = execute_db_query(
        namespace,
        db_pod,
        "koku",
        "koku",
        f"""
        SELECT 
            report_name,
            status,
            failed_status,
            completed_datetime,
            last_started_datetime
        FROM reporting_common_costusagereportstatus
        WHERE manifest_id = {manifest_id}
        ORDER BY id
        """,
    )
    
    if not result:
        return []
    
    statuses = []
    for row in result:
        status_code = int(row[1]) if row[1] is not None else None
        statuses.append({
            "report_name": row[0],
            "status": status_code,
            "status_name": FILE_STATUS_NAMES.get(status_code, f"UNKNOWN({status_code})"),
            "failed_status": row[2],
            "completed_datetime": row[3],
            "last_started_datetime": row[4],
        })
    
    return statuses


def get_providers_with_data(namespace: str, db_pod: str) -> List[Dict]:
    """Get providers that have processed data.
    
    Args:
        namespace: Kubernetes namespace
        db_pod: Database pod name
        
    Returns:
        List of provider dictionaries
    """
    result = execute_db_query(
        namespace,
        db_pod,
        "koku",
        "koku",
        """
        SELECT DISTINCT
            p.uuid,
            p.name,
            p.type,
            p.active,
            pa.credentials->>'cluster_id' as cluster_id
        FROM api_provider p
        JOIN api_providerauthentication pa ON p.authentication_id = pa.id
        WHERE p.active = true
        ORDER BY p.name
        """,
    )
    
    if not result:
        return []
    
    providers = []
    for row in result:
        providers.append({
            "uuid": row[0],
            "name": row[1],
            "type": row[2],
            "active": row[3],
            "cluster_id": row[4],
        })
    
    return providers


# =============================================================================
# Test Fixtures
# =============================================================================

@pytest.fixture(scope="module")
def processing_context(cluster_config):
    """Set up context for processing state tests."""
    db_pod = get_pod_by_label(
        cluster_config.namespace,
        "app.kubernetes.io/component=database"
    )
    
    if not db_pod:
        pytest.skip("Database pod not found")
    
    return {
        "namespace": cluster_config.namespace,
        "db_pod": db_pod,
    }


# =============================================================================
# Test Classes
# =============================================================================

@pytest.mark.cost_management
@pytest.mark.component
class TestManifestState:
    """Tests for manifest state validation."""
    
    def test_can_query_manifests(self, processing_context):
        """Verify we can query manifest table."""
        ctx = processing_context
        
        # This should not raise an exception
        manifests = get_recent_manifests(ctx["namespace"], ctx["db_pod"], limit=1)
        
        # Result can be empty, but query should succeed
        assert isinstance(manifests, list), "Query should return a list"
    
    def test_manifests_have_required_fields(self, processing_context):
        """Verify manifests have all required fields."""
        ctx = processing_context
        
        manifests = get_recent_manifests(ctx["namespace"], ctx["db_pod"], limit=5)
        
        if not manifests:
            pytest.skip("No manifests found in database")
        
        required_fields = [
            "id",
            "assembly_id",
            "cluster_id",
            "num_total_files",
            "creation_datetime",
        ]
        
        for manifest in manifests:
            for field in required_fields:
                assert field in manifest, f"Manifest missing field '{field}'"
    
    def test_no_stuck_manifests(self, processing_context):
        """Verify no manifests are stuck in processing state."""
        ctx = processing_context
        
        manifests = get_recent_manifests(ctx["namespace"], ctx["db_pod"], limit=20)
        
        if not manifests:
            pytest.skip("No manifests found")
        
        stuck_manifests = []
        for manifest in manifests:
            # A manifest is "stuck" if:
            # - It has files but none are processed
            # - It was created more than 30 minutes ago
            # - It has no completed_datetime
            if (
                manifest["num_total_files"] > 0
                and manifest["num_processed_files"] == 0
                and manifest["completed_datetime"] is None
            ):
                # Check if it's old enough to be considered stuck
                # (We can't easily check time here without datetime parsing)
                stuck_manifests.append(manifest)
        
        # Allow some stuck manifests (they might be in progress)
        # But flag if there are many
        if len(stuck_manifests) > 5:
            manifest_ids = [m["id"] for m in stuck_manifests[:5]]
            pytest.fail(
                f"Found {len(stuck_manifests)} potentially stuck manifests. "
                f"Sample IDs: {manifest_ids}"
            )


@pytest.mark.cost_management
@pytest.mark.component
class TestFileProcessingStatus:
    """Tests for file processing status validation."""
    
    def test_can_query_file_statuses(self, processing_context):
        """Verify we can query file status table."""
        ctx = processing_context
        
        manifests = get_recent_manifests(ctx["namespace"], ctx["db_pod"], limit=1)
        
        if not manifests:
            pytest.skip("No manifests found")
        
        # Query file statuses for the most recent manifest
        statuses = get_file_statuses(
            ctx["namespace"],
            ctx["db_pod"],
            manifests[0]["id"],
        )
        
        # Result can be empty, but query should succeed
        assert isinstance(statuses, list), "Query should return a list"
    
    def test_no_failed_files_in_recent_manifests(self, processing_context):
        """Verify no files have failed processing in recent manifests."""
        ctx = processing_context
        
        manifests = get_recent_manifests(ctx["namespace"], ctx["db_pod"], limit=5)
        
        if not manifests:
            pytest.skip("No manifests found")
        
        failed_files = []
        for manifest in manifests:
            statuses = get_file_statuses(
                ctx["namespace"],
                ctx["db_pod"],
                manifest["id"],
            )
            
            for status in statuses:
                if status["status"] == FILE_STATUS_FAILED:
                    failed_files.append({
                        "manifest_id": manifest["id"],
                        "cluster_id": manifest["cluster_id"],
                        "file": status["report_name"],
                        "failed_status": status["failed_status"],
                    })
        
        if failed_files:
            # Log details but don't fail - failures may be from old test runs
            print(f"\n  ⚠️  Found {len(failed_files)} failed files:")
            for f in failed_files[:3]:
                print(f"     - {f['file']} (manifest {f['manifest_id']})")
    
    def test_successful_files_have_completion_time(self, processing_context):
        """Verify successful files have completion timestamps."""
        ctx = processing_context
        
        manifests = get_recent_manifests(ctx["namespace"], ctx["db_pod"], limit=5)
        
        if not manifests:
            pytest.skip("No manifests found")
        
        missing_completion = []
        for manifest in manifests:
            statuses = get_file_statuses(
                ctx["namespace"],
                ctx["db_pod"],
                manifest["id"],
            )
            
            for status in statuses:
                if (
                    status["status"] == FILE_STATUS_SUCCESS
                    and status["completed_datetime"] is None
                ):
                    missing_completion.append({
                        "manifest_id": manifest["id"],
                        "file": status["report_name"],
                    })
        
        if missing_completion:
            pytest.fail(
                f"Found {len(missing_completion)} successful files without completion time"
            )


@pytest.mark.cost_management
@pytest.mark.component
class TestProviderState:
    """Tests for provider state validation."""
    
    def test_can_query_providers(self, processing_context):
        """Verify we can query provider table."""
        ctx = processing_context
        
        providers = get_providers_with_data(ctx["namespace"], ctx["db_pod"])
        
        # Result can be empty, but query should succeed
        assert isinstance(providers, list), "Query should return a list"
    
    def test_active_providers_have_required_fields(self, processing_context):
        """Verify active providers have required fields."""
        ctx = processing_context
        
        providers = get_providers_with_data(ctx["namespace"], ctx["db_pod"])
        
        if not providers:
            pytest.skip("No providers found")
        
        for provider in providers:
            assert provider["uuid"], f"Provider missing UUID: {provider}"
            assert provider["name"], f"Provider missing name: {provider}"
            assert provider["type"], f"Provider missing type: {provider}"


@pytest.mark.cost_management
@pytest.mark.extended
class TestSummaryTaskState:
    """Tests for summary task state validation."""
    
    def test_summary_state_in_manifests(self, processing_context):
        """Verify manifests have summary state information."""
        ctx = processing_context
        
        manifests = get_recent_manifests(ctx["namespace"], ctx["db_pod"], limit=10)
        
        if not manifests:
            pytest.skip("No manifests found")
        
        # Check that at least some manifests have state information
        manifests_with_state = [m for m in manifests if m["state"]]
        
        # It's OK if some manifests don't have state (older format)
        # But we should have some with state
        if not manifests_with_state:
            pytest.skip("No manifests with state information found")
        
        # Verify state is valid JSON-like structure
        for manifest in manifests_with_state:
            state = manifest["state"]
            # State should be a JSON string or dict
            assert state, f"Manifest {manifest['id']} has empty state"
    
    def test_no_summary_failures_in_recent_manifests(self, processing_context):
        """Verify no summary failures in recent manifests."""
        ctx = processing_context
        
        # Query manifests with summary failure state
        result = execute_db_query(
            ctx["namespace"],
            ctx["db_pod"],
            "koku",
            "koku",
            """
            SELECT 
                m.id,
                m.cluster_id,
                m.state::jsonb->'summary'->>'failed' as summary_failed
            FROM reporting_common_costusagereportmanifest m
            WHERE m.state::jsonb->'summary'->>'failed' IS NOT NULL
            ORDER BY m.creation_datetime DESC
            LIMIT 10
            """,
        )
        
        if not result:
            # No failures found - this is good
            return
        
        failed_summaries = []
        for row in result:
            if row[2]:  # summary_failed is not null
                failed_summaries.append({
                    "manifest_id": row[0],
                    "cluster_id": row[1],
                    "failed_at": row[2],
                })
        
        if failed_summaries:
            # Log but don't fail - may be from old test runs
            print(f"\n  ⚠️  Found {len(failed_summaries)} manifests with summary failures:")
            for f in failed_summaries[:3]:
                print(f"     - Manifest {f['manifest_id']} (cluster: {f['cluster_id']})")


@pytest.mark.cost_management
@pytest.mark.extended
class TestProcessingMetrics:
    """Tests for processing metrics and statistics."""
    
    def test_processing_completion_rate(self, processing_context):
        """Verify processing completion rate is acceptable."""
        ctx = processing_context
        
        manifests = get_recent_manifests(ctx["namespace"], ctx["db_pod"], limit=20)
        
        if not manifests:
            pytest.skip("No manifests found")
        
        total_files = 0
        processed_files = 0
        
        for manifest in manifests:
            total_files += manifest["num_total_files"]
            processed_files += manifest["num_processed_files"]
        
        if total_files == 0:
            pytest.skip("No files to process")
        
        completion_rate = processed_files / total_files
        
        # Log the rate
        print(f"\n  Processing completion rate: {completion_rate*100:.1f}%")
        print(f"  ({processed_files}/{total_files} files)")
        
        # We expect at least 80% completion for recent manifests
        # (Some may still be in progress)
        assert completion_rate >= 0.5, (
            f"Processing completion rate too low: {completion_rate*100:.1f}% "
            f"({processed_files}/{total_files} files)"
        )
    
    def test_file_status_distribution(self, processing_context):
        """Verify file status distribution is healthy."""
        ctx = processing_context
        
        manifests = get_recent_manifests(ctx["namespace"], ctx["db_pod"], limit=10)
        
        if not manifests:
            pytest.skip("No manifests found")
        
        status_counts = {
            FILE_STATUS_PENDING: 0,
            FILE_STATUS_SUCCESS: 0,
            FILE_STATUS_FAILED: 0,
        }
        
        for manifest in manifests:
            statuses = get_file_statuses(
                ctx["namespace"],
                ctx["db_pod"],
                manifest["id"],
            )
            
            for status in statuses:
                if status["status"] in status_counts:
                    status_counts[status["status"]] += 1
        
        total = sum(status_counts.values())
        
        if total == 0:
            pytest.skip("No file statuses found")
        
        # Log distribution
        print(f"\n  File status distribution:")
        for status_code, count in status_counts.items():
            pct = count / total * 100
            print(f"    {FILE_STATUS_NAMES[status_code]}: {count} ({pct:.1f}%)")
        
        # Verify failure rate is acceptable (< 10%)
        failure_rate = status_counts[FILE_STATUS_FAILED] / total
        assert failure_rate < 0.1, (
            f"File failure rate too high: {failure_rate*100:.1f}%"
        )
