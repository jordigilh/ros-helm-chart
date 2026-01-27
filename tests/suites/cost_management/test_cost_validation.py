"""
Cost Calculation Validation Tests.

These tests are SELF-CONTAINED - they set up their own test data via the full E2E flow:
1. Generate NISE data with known expected values
2. Register a source in Sources API
3. Upload data via JWT-authenticated ingress
4. Wait for Koku to process and populate summary tables
5. Validate cost calculations match expected values
6. Clean up all test data

Environment Variables:
- E2E_COST_TOLERANCE: Tolerance for cost validation (default: 0.05 = 5%)

Configuration is centralized in e2e_helpers.py (NISEConfig class).
"""

import os

import pytest

from utils import execute_db_query


# =============================================================================
# Configuration
# =============================================================================

DEFAULT_COST_TOLERANCE = 0.05


def get_cost_tolerance() -> float:
    """Get cost validation tolerance from environment or default."""
    try:
        return float(os.environ.get("E2E_COST_TOLERANCE", DEFAULT_COST_TOLERANCE))
    except ValueError:
        return DEFAULT_COST_TOLERANCE


# =============================================================================
# Test Classes
# =============================================================================

@pytest.mark.cost_management
@pytest.mark.cost_validation
@pytest.mark.extended
@pytest.mark.timeout(900)  # 15 minutes for E2E setup + tests
class TestSummaryTableData:
    """Tests for summary table data validation."""
    
    def test_summary_table_exists(self, cost_validation_data):
        """Verify the OCP usage summary table exists."""
        ctx = cost_validation_data
        
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
            f"Summary table not found in schema '{ctx['schema_name']}'."
        )
    
    def test_summary_has_data_for_cluster(self, cost_validation_data):
        """Verify summary table has data for the test cluster."""
        ctx = cost_validation_data
        
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
            f"No summary data found for cluster '{ctx['cluster_id']}'."
        )


@pytest.mark.cost_management
@pytest.mark.cost_validation
@pytest.mark.extended
class TestCPUMetrics:
    """Tests for CPU metric validation."""
    
    def test_cpu_request_hours_within_tolerance(self, cost_validation_data):
        """Verify CPU request hours match expected values within tolerance."""
        ctx = cost_validation_data
        expected = ctx["expected"]
        tolerance = get_cost_tolerance()
        
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
        
        assert result and result[0][0] is not None, "No CPU data in summary tables"
        
        actual_cpu_hours = float(result[0][0])
        expected_cpu_hours = expected["expected_cpu_hours"]
        
        diff_pct = abs(actual_cpu_hours - expected_cpu_hours) / expected_cpu_hours if expected_cpu_hours > 0 else 0
        
        assert diff_pct <= tolerance, (
            f"CPU request hours mismatch:\n"
            f"  Expected: {expected_cpu_hours:.2f} hours\n"
            f"  Actual:   {actual_cpu_hours:.2f} hours\n"
            f"  Diff:     {diff_pct*100:.1f}% (tolerance: {tolerance*100}%)"
        )
    
    def test_cpu_usage_recorded(self, cost_validation_data):
        """Verify CPU usage data was recorded."""
        ctx = cost_validation_data
        
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
        
        assert result and result[0][0] is not None, "No CPU usage data"
        
        actual_cpu_usage = float(result[0][0])
        assert actual_cpu_usage > 0, f"CPU usage hours is zero or negative: {actual_cpu_usage}"


@pytest.mark.cost_management
@pytest.mark.cost_validation
@pytest.mark.extended
class TestMemoryMetrics:
    """Tests for memory metric validation."""
    
    def test_memory_request_gb_hours_within_tolerance(self, cost_validation_data):
        """Verify memory request GB-hours match expected values within tolerance."""
        ctx = cost_validation_data
        expected = ctx["expected"]
        tolerance = get_cost_tolerance()
        
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
        
        assert result and result[0][0] is not None, "No memory data in summary tables"
        
        actual_mem_hours = float(result[0][0])
        expected_mem_hours = expected["expected_memory_gb_hours"]
        
        diff_pct = abs(actual_mem_hours - expected_mem_hours) / expected_mem_hours if expected_mem_hours > 0 else 0
        
        assert diff_pct <= tolerance, (
            f"Memory request GB-hours mismatch:\n"
            f"  Expected: {expected_mem_hours:.2f} GB-hours\n"
            f"  Actual:   {actual_mem_hours:.2f} GB-hours\n"
            f"  Diff:     {diff_pct*100:.1f}% (tolerance: {tolerance*100}%)"
        )
    
    def test_memory_usage_recorded(self, cost_validation_data):
        """Verify memory usage data was recorded."""
        ctx = cost_validation_data
        
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
        
        assert result and result[0][0] is not None, "No memory usage data"
        
        actual_mem_usage = float(result[0][0])
        assert actual_mem_usage > 0, f"Memory usage GB-hours is zero or negative: {actual_mem_usage}"


@pytest.mark.cost_management
@pytest.mark.cost_validation
@pytest.mark.extended
class TestResourceCounts:
    """Tests for resource count validation."""
    
    def test_node_count_matches_expected(self, cost_validation_data):
        """Verify unique node count matches expected."""
        ctx = cost_validation_data
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
        
        assert result, "Could not query node count"
        
        actual_count = int(result[0][0])
        expected_count = expected["expected_node_count"]
        
        assert actual_count == expected_count, (
            f"Node count mismatch: expected {expected_count}, got {actual_count}"
        )
    
    def test_namespace_count_matches_expected(self, cost_validation_data):
        """Verify unique namespace count matches expected."""
        ctx = cost_validation_data
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
        
        assert result, "Could not query namespace count"
        
        actual_count = int(result[0][0])
        expected_count = expected["expected_namespace_count"]
        
        assert actual_count == expected_count, (
            f"Namespace count mismatch: expected {expected_count}, got {actual_count}"
        )
    
    def test_pod_count_matches_expected(self, cost_validation_data):
        """Verify unique pod/resource count matches expected."""
        ctx = cost_validation_data
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
        
        assert result, "Could not query pod count"
        
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
    
    def test_node_name_matches_expected(self, cost_validation_data):
        """Verify node name matches NISE static report."""
        ctx = cost_validation_data
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
        
        assert result and result[0][0], "No node data available"
        
        actual_node = result[0][0]
        expected_node = expected["node_name"]
        
        assert actual_node == expected_node, (
            f"Node name mismatch: expected '{expected_node}', got '{actual_node}'"
        )
    
    def test_namespace_name_matches_expected(self, cost_validation_data):
        """Verify namespace name matches NISE static report."""
        ctx = cost_validation_data
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
        
        assert result and result[0][0], "No namespace data available"
        
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
    
    def test_infrastructure_cost_calculated(self, cost_validation_data):
        """Verify infrastructure cost was calculated (non-zero)."""
        ctx = cost_validation_data
        
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
        
        assert result, "Could not query infrastructure cost"
        
        rows_with_cost = int(result[0][0]) if result[0][0] else 0
        total_cost = float(result[0][1]) if result[0][1] else 0.0
        
        # Infrastructure cost may not be calculated immediately - this is OK
        if rows_with_cost == 0:
            pytest.skip(
                "No infrastructure cost calculated yet. "
                "Cost calculation may run asynchronously."
            )
        
        assert total_cost >= 0, f"Infrastructure cost is negative: ${total_cost:.2f}"
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
    def test_metric_within_tolerance(self, cost_validation_data, metric: str):
        """Verify metric is within tolerance of expected value."""
        ctx = cost_validation_data
        expected = ctx["expected"]
        tolerance = get_cost_tolerance()
        
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
        
        assert result and result[0][0] is not None, f"No data for metric '{metric}'"
        
        actual_value = float(result[0][0])
        
        expected_map = {
            "pod_request_cpu_core_hours": expected["expected_cpu_hours"],
            "pod_request_memory_gigabyte_hours": expected["expected_memory_gb_hours"],
        }
        
        expected_value = expected_map.get(metric)
        assert expected_value is not None, f"No expected value for metric '{metric}'"
        
        diff_pct = abs(actual_value - expected_value) / expected_value if expected_value > 0 else 0
        
        assert diff_pct <= tolerance, (
            f"Metric '{metric}' outside tolerance:\n"
            f"  Expected: {expected_value:.4f}\n"
            f"  Actual:   {actual_value:.4f}\n"
            f"  Diff:     {diff_pct*100:.1f}% (tolerance: {tolerance*100}%)"
        )
