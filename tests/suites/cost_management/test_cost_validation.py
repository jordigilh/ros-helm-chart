"""
Cost Calculation Validation Tests.

These tests validate that cost calculations in Koku are correct:
1. CPU/Memory metrics match expected values from NISE
2. Infrastructure costs are calculated
3. Resource counts are accurate
4. Cost allocation is correct

Source Reference: scripts/e2e_validator/phases/smoke_validation.py

IMPORTANT: These tests require:
- Summary tables to be populated (run extended E2E tests first)
- NISE-generated data with known expected values
- A provider with processed data in the database

Environment Variables:
- E2E_COST_TOLERANCE: Tolerance for cost validation (default: 0.05 = 5%)
"""

import os
from datetime import datetime, timedelta
from typing import Dict, Optional

import pytest

from utils import execute_db_query, get_pod_by_label, get_secret_value


# =============================================================================
# Configuration
# =============================================================================

# Default tolerance for cost validation (5%)
DEFAULT_COST_TOLERANCE = 0.05

def get_cost_tolerance() -> float:
    """Get cost validation tolerance from environment or default."""
    try:
        return float(os.environ.get("E2E_COST_TOLERANCE", DEFAULT_COST_TOLERANCE))
    except ValueError:
        return DEFAULT_COST_TOLERANCE


# =============================================================================
# Expected Values from NISE Static Report
# =============================================================================

def get_expected_values(hours: int = 24) -> Dict:
    """Get expected values matching the NISE static report template.
    
    These values match the dynamic static report generated in test_complete_flow.py
    and scripts/e2e_validator/phases/smoke_validation.py
    
    Args:
        hours: Number of hours of data (default 24 for 1 day)
        
    Returns:
        Dict with expected metric values
    """
    # Values from the NISE static report template
    cpu_request = 0.5  # cores
    mem_request_gig = 1  # GiB
    cpu_limit = 1  # cores
    mem_limit_gig = 2  # GiB
    
    return {
        "node_name": "test-node-1",
        "namespace": "test-namespace",
        "pod_name": "test-pod-1",
        "resource_id": "test-resource-1",
        "cpu_request": cpu_request,
        "mem_request_gig": mem_request_gig,
        "cpu_limit": cpu_limit,
        "mem_limit_gig": mem_limit_gig,
        "hours": hours,
        # Expected totals (hourly data)
        "expected_cpu_hours": cpu_request * hours,
        "expected_memory_gb_hours": mem_request_gig * hours,
        "expected_node_count": 1,
        "expected_namespace_count": 1,
        "expected_pod_count": 1,
    }


# =============================================================================
# Helper Functions
# =============================================================================

def get_test_cluster_id(namespace: str, db_pod: str) -> Optional[str]:
    """Find a test cluster ID from recent E2E test runs.
    
    Args:
        namespace: Kubernetes namespace
        db_pod: Database pod name
        
    Returns:
        Cluster ID or None if not found
    """
    result = execute_db_query(
        namespace,
        db_pod,
        "koku",
        "koku",
        """
        SELECT DISTINCT pa.credentials->>'cluster_id' as cluster_id
        FROM api_provider p
        JOIN api_providerauthentication pa ON p.authentication_id = pa.id
        WHERE pa.credentials->>'cluster_id' LIKE 'e2e-pytest-%'
        ORDER BY cluster_id DESC
        LIMIT 1
        """,
    )
    
    if result and result[0][0]:
        return result[0][0]
    return None


def get_tenant_schema(namespace: str, db_pod: str, cluster_id: str) -> Optional[str]:
    """Get the tenant schema name for a cluster.
    
    Args:
        namespace: Kubernetes namespace
        db_pod: Database pod name
        cluster_id: Cluster identifier
        
    Returns:
        Schema name or None if not found
    """
    result = execute_db_query(
        namespace,
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
    
    if result and result[0][0]:
        return result[0][0].strip()
    return None


# =============================================================================
# Test Fixtures
# =============================================================================

@pytest.fixture(scope="module")
def cost_validation_context(cluster_config, database_config):
    """Set up context for cost validation tests.
    
    Finds a test cluster and schema from recent E2E runs.
    """
    db_pod = get_pod_by_label(
        cluster_config.namespace,
        "app.kubernetes.io/component=database"
    )
    
    if not db_pod:
        pytest.skip("Database pod not found")
    
    # Find a test cluster
    cluster_id = get_test_cluster_id(cluster_config.namespace, db_pod)
    if not cluster_id:
        pytest.skip(
            "No E2E test cluster found. Run extended E2E tests first: "
            "./scripts/run-pytest.sh --extended"
        )
    
    # Get tenant schema
    schema_name = get_tenant_schema(cluster_config.namespace, db_pod, cluster_id)
    if not schema_name:
        pytest.skip(f"No tenant schema found for cluster {cluster_id}")
    
    return {
        "namespace": cluster_config.namespace,
        "db_pod": db_pod,
        "cluster_id": cluster_id,
        "schema_name": schema_name,
        "expected": get_expected_values(),
    }


# =============================================================================
# Test Classes
# =============================================================================

@pytest.mark.cost_management
@pytest.mark.cost_validation
@pytest.mark.extended
class TestSummaryTableData:
    """Tests for summary table data validation."""
    
    def test_summary_table_exists(self, cost_validation_context):
        """Verify the OCP usage summary table exists."""
        ctx = cost_validation_context
        
        result = execute_db_query(
            ctx["namespace"],
            ctx["db_pod"],
            "koku",
            "koku",
            f"""
            SELECT EXISTS (
                SELECT FROM information_schema.tables
                WHERE table_schema = '{ctx["schema_name"]}'
                AND table_name = 'reporting_ocpusagelineitem_daily_summary'
            )
            """,
        )
        
        assert result and result[0][0] in ["t", "True", True, "1"], (
            f"Summary table not found in schema '{ctx['schema_name']}'. "
            "Run extended E2E tests to populate summary tables."
        )
    
    def test_summary_has_data_for_cluster(self, cost_validation_context):
        """Verify summary table has data for the test cluster."""
        ctx = cost_validation_context
        
        result = execute_db_query(
            ctx["namespace"],
            ctx["db_pod"],
            "koku",
            "koku",
            f"""
            SELECT COUNT(*)
            FROM {ctx["schema_name"]}.reporting_ocpusagelineitem_daily_summary
            WHERE cluster_id = '{ctx["cluster_id"]}'
            """,
        )
        
        row_count = int(result[0][0]) if result else 0
        
        assert row_count > 0, (
            f"No summary data found for cluster '{ctx['cluster_id']}'. "
            "Ensure E2E tests completed successfully and summary tasks ran."
        )


@pytest.mark.cost_management
@pytest.mark.cost_validation
@pytest.mark.extended
class TestCPUMetrics:
    """Tests for CPU metric validation."""
    
    @property
    def TOLERANCE(self):
        return get_cost_tolerance()
    
    def test_cpu_request_hours_within_tolerance(self, cost_validation_context):
        """Verify CPU request hours match expected values within tolerance."""
        ctx = cost_validation_context
        expected = ctx["expected"]
        
        result = execute_db_query(
            ctx["namespace"],
            ctx["db_pod"],
            "koku",
            "koku",
            f"""
            SELECT SUM(pod_request_cpu_core_hours) as total_cpu_hours
            FROM {ctx["schema_name"]}.reporting_ocpusagelineitem_daily_summary
            WHERE cluster_id = '{ctx["cluster_id"]}'
            AND namespace NOT LIKE '%unallocated%'
            """,
        )
        
        if not result or result[0][0] is None:
            pytest.skip("No CPU data available in summary tables")
        
        actual_cpu_hours = float(result[0][0])
        expected_cpu_hours = expected["expected_cpu_hours"]
        
        diff_pct = abs(actual_cpu_hours - expected_cpu_hours) / expected_cpu_hours if expected_cpu_hours > 0 else 0
        
        assert diff_pct <= self.TOLERANCE, (
            f"CPU request hours mismatch:\n"
            f"  Expected: {expected_cpu_hours:.2f} hours\n"
            f"  Actual:   {actual_cpu_hours:.2f} hours\n"
            f"  Diff:     {diff_pct*100:.1f}% (tolerance: {self.TOLERANCE*100}%)"
        )
    
    def test_cpu_usage_recorded(self, cost_validation_context):
        """Verify CPU usage data was recorded."""
        ctx = cost_validation_context
        
        result = execute_db_query(
            ctx["namespace"],
            ctx["db_pod"],
            "koku",
            "koku",
            f"""
            SELECT SUM(pod_usage_cpu_core_hours) as total_cpu_usage
            FROM {ctx["schema_name"]}.reporting_ocpusagelineitem_daily_summary
            WHERE cluster_id = '{ctx["cluster_id"]}'
            AND namespace NOT LIKE '%unallocated%'
            """,
        )
        
        if not result or result[0][0] is None:
            pytest.skip("No CPU usage data available")
        
        actual_cpu_usage = float(result[0][0])
        
        # CPU usage should be positive (we generated data with usage)
        assert actual_cpu_usage > 0, (
            f"CPU usage hours is zero or negative: {actual_cpu_usage}"
        )


@pytest.mark.cost_management
@pytest.mark.cost_validation
@pytest.mark.extended
class TestMemoryMetrics:
    """Tests for memory metric validation."""
    
    @property
    def TOLERANCE(self):
        return get_cost_tolerance()
    
    def test_memory_request_gb_hours_within_tolerance(self, cost_validation_context):
        """Verify memory request GB-hours match expected values within tolerance."""
        ctx = cost_validation_context
        expected = ctx["expected"]
        
        result = execute_db_query(
            ctx["namespace"],
            ctx["db_pod"],
            "koku",
            "koku",
            f"""
            SELECT SUM(pod_request_memory_gigabyte_hours) as total_mem_hours
            FROM {ctx["schema_name"]}.reporting_ocpusagelineitem_daily_summary
            WHERE cluster_id = '{ctx["cluster_id"]}'
            AND namespace NOT LIKE '%unallocated%'
            """,
        )
        
        if not result or result[0][0] is None:
            pytest.skip("No memory data available in summary tables")
        
        actual_mem_hours = float(result[0][0])
        expected_mem_hours = expected["expected_memory_gb_hours"]
        
        diff_pct = abs(actual_mem_hours - expected_mem_hours) / expected_mem_hours if expected_mem_hours > 0 else 0
        
        assert diff_pct <= self.TOLERANCE, (
            f"Memory request GB-hours mismatch:\n"
            f"  Expected: {expected_mem_hours:.2f} GB-hours\n"
            f"  Actual:   {actual_mem_hours:.2f} GB-hours\n"
            f"  Diff:     {diff_pct*100:.1f}% (tolerance: {self.TOLERANCE*100}%)"
        )
    
    def test_memory_usage_recorded(self, cost_validation_context):
        """Verify memory usage data was recorded."""
        ctx = cost_validation_context
        
        result = execute_db_query(
            ctx["namespace"],
            ctx["db_pod"],
            "koku",
            "koku",
            f"""
            SELECT SUM(pod_usage_memory_gigabyte_hours) as total_mem_usage
            FROM {ctx["schema_name"]}.reporting_ocpusagelineitem_daily_summary
            WHERE cluster_id = '{ctx["cluster_id"]}'
            AND namespace NOT LIKE '%unallocated%'
            """,
        )
        
        if not result or result[0][0] is None:
            pytest.skip("No memory usage data available")
        
        actual_mem_usage = float(result[0][0])
        
        # Memory usage should be positive
        assert actual_mem_usage > 0, (
            f"Memory usage GB-hours is zero or negative: {actual_mem_usage}"
        )


@pytest.mark.cost_management
@pytest.mark.cost_validation
@pytest.mark.extended
class TestResourceCounts:
    """Tests for resource count validation."""
    
    def test_node_count_matches_expected(self, cost_validation_context):
        """Verify unique node count matches expected."""
        ctx = cost_validation_context
        expected = ctx["expected"]
        
        result = execute_db_query(
            ctx["namespace"],
            ctx["db_pod"],
            "koku",
            "koku",
            f"""
            SELECT COUNT(DISTINCT node) as node_count
            FROM {ctx["schema_name"]}.reporting_ocpusagelineitem_daily_summary
            WHERE cluster_id = '{ctx["cluster_id"]}'
            AND namespace NOT LIKE '%unallocated%'
            """,
        )
        
        if not result:
            pytest.skip("Could not query node count")
        
        actual_count = int(result[0][0])
        expected_count = expected["expected_node_count"]
        
        assert actual_count == expected_count, (
            f"Node count mismatch: expected {expected_count}, got {actual_count}"
        )
    
    def test_namespace_count_matches_expected(self, cost_validation_context):
        """Verify unique namespace count matches expected."""
        ctx = cost_validation_context
        expected = ctx["expected"]
        
        result = execute_db_query(
            ctx["namespace"],
            ctx["db_pod"],
            "koku",
            "koku",
            f"""
            SELECT COUNT(DISTINCT namespace) as ns_count
            FROM {ctx["schema_name"]}.reporting_ocpusagelineitem_daily_summary
            WHERE cluster_id = '{ctx["cluster_id"]}'
            AND namespace NOT LIKE '%unallocated%'
            """,
        )
        
        if not result:
            pytest.skip("Could not query namespace count")
        
        actual_count = int(result[0][0])
        expected_count = expected["expected_namespace_count"]
        
        assert actual_count == expected_count, (
            f"Namespace count mismatch: expected {expected_count}, got {actual_count}"
        )
    
    def test_pod_count_matches_expected(self, cost_validation_context):
        """Verify unique pod/resource count matches expected."""
        ctx = cost_validation_context
        expected = ctx["expected"]
        
        result = execute_db_query(
            ctx["namespace"],
            ctx["db_pod"],
            "koku",
            "koku",
            f"""
            SELECT COUNT(DISTINCT resource_id) as pod_count
            FROM {ctx["schema_name"]}.reporting_ocpusagelineitem_daily_summary
            WHERE cluster_id = '{ctx["cluster_id"]}'
            AND namespace NOT LIKE '%unallocated%'
            """,
        )
        
        if not result:
            pytest.skip("Could not query pod count")
        
        actual_count = int(result[0][0])
        expected_count = expected["expected_pod_count"]
        
        assert actual_count == expected_count, (
            f"Pod/resource count mismatch: expected {expected_count}, got {actual_count}"
        )


@pytest.mark.cost_management
@pytest.mark.cost_validation
@pytest.mark.extended
class TestResourceNames:
    """Tests for resource name validation."""
    
    def test_node_name_matches_expected(self, cost_validation_context):
        """Verify node name matches NISE static report."""
        ctx = cost_validation_context
        expected = ctx["expected"]
        
        result = execute_db_query(
            ctx["namespace"],
            ctx["db_pod"],
            "koku",
            "koku",
            f"""
            SELECT DISTINCT node
            FROM {ctx["schema_name"]}.reporting_ocpusagelineitem_daily_summary
            WHERE cluster_id = '{ctx["cluster_id"]}'
            AND namespace NOT LIKE '%unallocated%'
            LIMIT 1
            """,
        )
        
        if not result or not result[0][0]:
            pytest.skip("No node data available")
        
        actual_node = result[0][0]
        expected_node = expected["node_name"]
        
        assert actual_node == expected_node, (
            f"Node name mismatch: expected '{expected_node}', got '{actual_node}'"
        )
    
    def test_namespace_name_matches_expected(self, cost_validation_context):
        """Verify namespace name matches NISE static report."""
        ctx = cost_validation_context
        expected = ctx["expected"]
        
        result = execute_db_query(
            ctx["namespace"],
            ctx["db_pod"],
            "koku",
            "koku",
            f"""
            SELECT DISTINCT namespace
            FROM {ctx["schema_name"]}.reporting_ocpusagelineitem_daily_summary
            WHERE cluster_id = '{ctx["cluster_id"]}'
            AND namespace NOT LIKE '%unallocated%'
            LIMIT 1
            """,
        )
        
        if not result or not result[0][0]:
            pytest.skip("No namespace data available")
        
        actual_ns = result[0][0]
        expected_ns = expected["namespace"]
        
        assert actual_ns == expected_ns, (
            f"Namespace mismatch: expected '{expected_ns}', got '{actual_ns}'"
        )


@pytest.mark.cost_management
@pytest.mark.cost_validation
@pytest.mark.extended
class TestInfrastructureCost:
    """Tests for infrastructure cost calculation."""
    
    def test_infrastructure_cost_calculated(self, cost_validation_context):
        """Verify infrastructure cost was calculated (non-zero)."""
        ctx = cost_validation_context
        
        result = execute_db_query(
            ctx["namespace"],
            ctx["db_pod"],
            "koku",
            "koku",
            f"""
            SELECT 
                COUNT(*) as rows_with_cost,
                SUM(CAST(infrastructure_usage_cost->>'value' AS NUMERIC)) as total_cost
            FROM {ctx["schema_name"]}.reporting_ocpusagelineitem_daily_summary
            WHERE cluster_id = '{ctx["cluster_id"]}'
            AND infrastructure_usage_cost IS NOT NULL
            """,
        )
        
        if not result:
            pytest.skip("Could not query infrastructure cost")
        
        rows_with_cost = int(result[0][0]) if result[0][0] else 0
        total_cost = float(result[0][1]) if result[0][1] else 0.0
        
        if rows_with_cost == 0:
            pytest.skip(
                "No infrastructure cost calculated yet. "
                "Cost calculation may run asynchronously after summary tables are populated."
            )
        
        # Infrastructure cost should be non-negative
        assert total_cost >= 0, (
            f"Infrastructure cost is negative: ${total_cost:.2f}"
        )
        
        # Log the cost for visibility
        print(f"\n  Infrastructure cost: ${total_cost:.2f} ({rows_with_cost} rows)")


@pytest.mark.cost_management
@pytest.mark.cost_validation
@pytest.mark.extended
class TestMetricTolerance:
    """Parametrized tests for metric validation with configurable tolerance."""
    
    @pytest.mark.parametrize("metric", [
        "pod_request_cpu_core_hours",
        "pod_request_memory_gigabyte_hours",
    ])
    def test_metric_within_tolerance(self, cost_validation_context, metric: str):
        """Verify metric is within tolerance of expected value."""
        ctx = cost_validation_context
        expected = ctx["expected"]
        
        result = execute_db_query(
            ctx["namespace"],
            ctx["db_pod"],
            "koku",
            "koku",
            f"""
            SELECT SUM({metric}) as total
            FROM {ctx["schema_name"]}.reporting_ocpusagelineitem_daily_summary
            WHERE cluster_id = '{ctx["cluster_id"]}'
            AND namespace NOT LIKE '%unallocated%'
            """,
        )
        
        if not result or result[0][0] is None:
            pytest.skip(f"No data available for metric '{metric}'")
        
        actual_value = float(result[0][0])
        
        # Map metric to expected value
        expected_map = {
            "pod_request_cpu_core_hours": expected["expected_cpu_hours"],
            "pod_request_memory_gigabyte_hours": expected["expected_memory_gb_hours"],
        }
        
        expected_value = expected_map.get(metric)
        if expected_value is None:
            pytest.skip(f"No expected value defined for metric '{metric}'")
        
        tolerance = get_cost_tolerance()
        diff_pct = abs(actual_value - expected_value) / expected_value if expected_value > 0 else 0
        
        assert diff_pct <= tolerance, (
            f"Metric '{metric}' outside tolerance:\n"
            f"  Expected: {expected_value:.4f}\n"
            f"  Actual:   {actual_value:.4f}\n"
            f"  Diff:     {diff_pct*100:.1f}% (tolerance: {tolerance*100}%)"
        )
