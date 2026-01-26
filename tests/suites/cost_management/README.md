# Cost Management Test Suite

Tests for validating Koku cost processing pipeline and data integrity.

## Cost Calculation Validation (`test_cost_validation.py`)

Validates that cost calculations in Koku match expected values from NISE-generated data.

| Test Class | Test | Description |
|------------|------|-------------|
| `TestSummaryTableData` | `test_summary_table_exists` | Verifies OCP usage summary table exists |
| | `test_summary_has_data_for_cluster` | Verifies summary table has data for test cluster |
| `TestCPUMetrics` | `test_cpu_request_hours_within_tolerance` | CPU request hours match expected (±5%) |
| | `test_cpu_usage_recorded` | CPU usage data was recorded (non-zero) |
| `TestMemoryMetrics` | `test_memory_request_gb_hours_within_tolerance` | Memory GB-hours match expected (±5%) |
| | `test_memory_usage_recorded` | Memory usage data was recorded (non-zero) |
| `TestResourceCounts` | `test_node_count_matches_expected` | Unique node count matches NISE config |
| | `test_namespace_count_matches_expected` | Unique namespace count matches |
| | `test_pod_count_matches_expected` | Unique pod/resource count matches |
| `TestResourceNames` | `test_node_name_matches_expected` | Node name matches NISE static report |
| | `test_namespace_name_matches_expected` | Namespace name matches |
| `TestInfrastructureCost` | `test_infrastructure_cost_calculated` | Infrastructure cost was calculated |
| `TestMetricTolerance` | `test_metric_within_tolerance[cpu]` | Parametrized CPU tolerance check |
| | `test_metric_within_tolerance[memory]` | Parametrized memory tolerance check |

**Expected Values** (from NISE static report):
- Node: `test-node-1`
- Namespace: `test-namespace`
- Pod: `test-pod-1`
- CPU request: 0.5 cores → 12 CPU-hours/day
- Memory request: 1 GiB → 24 GB-hours/day

**Tolerance**: 5% (matches IQE validation pattern)

**Markers**: `@pytest.mark.cost_management`, `@pytest.mark.cost_validation`, `@pytest.mark.extended`

**Prerequisites**: Requires E2E tests to have run with `E2E_CLEANUP_AFTER=false` to preserve data.

**Environment Variables**:
| Variable | Default | Description |
|----------|---------|-------------|
| `E2E_COST_TOLERANCE` | `0.05` | Tolerance for cost validation (5% = 0.05) |

---

### Processing State Validation (`test_processing_state.py`)

Validates the health of Koku's data processing pipeline by examining database state.

| Test Class | Test | Description |
|------------|------|-------------|
| `TestManifestState` | `test_can_query_manifests` | Verifies manifest table is queryable |
| | `test_manifests_have_required_fields` | Manifests have id, assembly_id, cluster_id, etc. |
| | `test_no_stuck_manifests` | No manifests stuck with 0 processed files |
| `TestFileProcessingStatus` | `test_can_query_file_statuses` | File status table is queryable |
| | `test_no_failed_files_in_recent_manifests` | No files with status=FAILED |
| | `test_successful_files_have_completion_time` | Successful files have timestamps |
| `TestProviderState` | `test_can_query_providers` | Provider table is queryable |
| | `test_active_providers_have_required_fields` | Providers have uuid, name, type |
| `TestSummaryTaskState` | `test_summary_state_in_manifests` | Manifests have state JSON |
| | `test_no_summary_failures_in_recent_manifests` | No summary failures in state |
| `TestProcessingMetrics` | `test_processing_completion_rate` | ≥50% files processed |
| | `test_file_status_distribution` | <10% failure rate |

**File Status Codes**:
| Code | Name | Meaning |
|------|------|---------|
| 0 | PENDING | Not yet processed |
| 1 | SUCCESS | Successfully processed |
| 2 | FAILED | Processing failed |

**What These Tests Detect**:
- **Stuck manifests** → Kafka/listener issues
- **Failed files** → MASU processing bugs
- **Summary failures** → Celery worker issues
- **Low completion rate** → Systemic problems

**Markers**: `@pytest.mark.cost_management`, `@pytest.mark.component`, `@pytest.mark.extended`

---

## Running Cost Management Tests

```bash
# Run component tests (no extended)
./scripts/run-pytest.sh -- -m cost_management

# Run all cost management tests including extended
pytest tests/suites/cost_management/ -v -m ""

# Run only cost validation tests
pytest tests/suites/cost_management/test_cost_validation.py -v -m extended

# Run cost validation with custom tolerance (10%)
E2E_COST_TOLERANCE=0.10 pytest -m cost_validation -v

# Run only processing state tests
pytest tests/suites/cost_management/test_processing_state.py -v
```

## Related Files

- `test_processing.py` - Koku listener and MASU worker health tests
- `test_sources_api.py` - Sources API health and configuration tests
- `conftest.py` - Shared fixtures for cost management tests
