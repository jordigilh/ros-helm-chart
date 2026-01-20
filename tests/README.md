# Cost On-Prem Test Suite

Pytest-based test suite for validating Cost On-Prem deployments on OpenShift.

## Test Architecture

The test suite is organized into **focused suites** that avoid redundancy:

```
tests/
├── conftest.py              # Root fixtures (cluster config, JWT, DB, etc.)
├── utils.py                 # Shared utility functions
├── pytest.ini               # Pytest configuration and markers
├── requirements.txt         # Python dependencies
├── reports/                 # JUnit XML reports (generated)
└── suites/                  # Test suites organized by subject
    ├── helm/                # Helm chart validation
    ├── auth/                # JWT authentication
    ├── infrastructure/      # Infrastructure health (DB, S3, Kafka)
    ├── cost_management/     # Koku component health
    ├── ros/                 # ROS/Kruize component health
    └── e2e/                 # Complete end-to-end pipeline
```

### Suite Responsibilities

| Suite | Purpose | What It Tests |
|-------|---------|---------------|
| **helm** | Chart validation | Lint, template rendering, deployment health |
| **auth** | Authentication | Keycloak, JWT ingress/backend auth |
| **infrastructure** | Infrastructure health | Database, S3, Kafka connectivity |
| **cost_management** | Koku health | Sources API, Listener, MASU health |
| **ros** | ROS health | Kruize, ROS Processor, API health |
| **e2e** | Complete pipeline | **Full flow: Data → Ingress → Koku → ROS** |

### E2E Test Coverage

The `e2e` suite validates the **complete production data flow**:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        E2E Test Pipeline                                │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  1. Source Registration                                                 │
│     └── Register OCP source via Sources API                            │
│     └── Verify provider created in Koku DB (via Kafka)                 │
│                                                                         │
│  2. Data Upload (via Ingress)                                          │
│     └── Generate test CSV with realistic metrics                       │
│     └── Package into tar.gz with manifest                              │
│     └── Upload via JWT-authenticated ingress                           │
│                                                                         │
│  3. Koku Processing                                                     │
│     └── Listener consumes from platform.upload.announce                │
│     └── MASU processes cost data from S3                               │
│     └── Manifest/file status tracked in DB                             │
│     └── Summary tables populated                                        │
│                                                                         │
│  4. ROS Pipeline                                                        │
│     └── Koku emits events to hccm.ros.events                           │
│     └── ROS Processor sends to Kruize                                  │
│                                                                         │
│  5. Recommendations                                                     │
│     └── Kruize generates recommendations                               │
│     └── Accessible via JWT-authenticated API                           │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

## Quick Start

```bash
# Run all tests
./scripts/run-pytest.sh

# Run smoke tests only (quick validation)
./scripts/run-pytest.sh --smoke

# Run the complete E2E pipeline test
./scripts/run-pytest.sh --e2e

# Run specific suite
./scripts/run-pytest.sh --helm
./scripts/run-pytest.sh --auth
```

## Running Tests

### Using the Runner Script

```bash
# All tests
./scripts/run-pytest.sh

# Single suite
./scripts/run-pytest.sh --helm
./scripts/run-pytest.sh --auth
./scripts/run-pytest.sh --infrastructure
./scripts/run-pytest.sh --cost-management
./scripts/run-pytest.sh --ros
./scripts/run-pytest.sh --e2e

# Multiple suites
./scripts/run-pytest.sh --auth --ros

# Smoke tests across all suites
./scripts/run-pytest.sh --smoke

# E2E smoke tests only
./scripts/run-pytest.sh --e2e --smoke

# Setup environment only (no tests)
./scripts/run-pytest.sh --setup-only
```

### Using Pytest Directly

```bash
cd tests

# All tests
pytest

# By marker
pytest -m helm
pytest -m "auth and smoke"
pytest -m "not slow"
pytest -m e2e

# By directory
pytest suites/helm/
pytest suites/e2e/

# By file
pytest suites/e2e/test_complete_flow.py

# By test name pattern
pytest -k "test_upload"

# Verbose output
pytest -v

# Stop on first failure
pytest -x
```

## Test Markers

| Marker | Description |
|--------|-------------|
| `helm` | Helm chart validation tests |
| `auth` | JWT authentication tests |
| `infrastructure` | Infrastructure health tests |
| `cost_management` | Koku component tests |
| `ros` | ROS/Kruize tests |
| `e2e` | End-to-end pipeline tests |
| `smoke` | Quick validation tests (~1 min) |
| `slow` | Long-running tests |

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NAMESPACE` | `cost-onprem` | Target Kubernetes namespace |
| `HELM_RELEASE_NAME` | `cost-onprem` | Helm release name |
| `KEYCLOAK_NAMESPACE` | `keycloak` | Keycloak namespace |
| `PLATFORM` | `openshift` | Platform type |
| `PYTHON` | `python3` | Python interpreter |

## Relationship to e2e_validator

The `scripts/e2e_validator/` module provides a **CLI-based** E2E validation tool that:
- Uses NISE to generate synthetic cost data
- Uploads directly to S3 (bypassing ingress)
- Validates Koku summary tables and cost calculations

The **pytest E2E suite** (`tests/suites/e2e/`) provides:
- The same validation as a **pytest test**
- Upload via **ingress** (production path)
- Integration with JUnit reporting
- Runnable alongside other test suites

Both tools validate the same pipeline, but:
- Use `e2e_validator` for standalone CLI validation with NISE data
- Use pytest E2E for CI/CD integration and combined test runs

## CI/CD Integration

### JUnit Reports

Tests automatically generate JUnit XML reports at `tests/reports/junit.xml`.

### GitHub Actions Example

```yaml
- name: Run Tests
  run: |
    ./scripts/run-pytest.sh --smoke
  env:
    NAMESPACE: cost-onprem-ocp
    KEYCLOAK_NAMESPACE: keycloak

- name: Upload Test Results
  uses: actions/upload-artifact@v4
  if: always()
  with:
    name: test-results
    path: tests/reports/junit.xml
```

## Troubleshooting

### Common Issues

**Tests skip with "route not found":**
- Verify the Helm release is deployed
- Check route names match expected patterns

**Authentication failures:**
- Verify Keycloak is deployed and accessible
- Check client secret exists in expected location

**E2E tests timeout:**
- Koku processing can take several minutes
- Kruize recommendations require multiple data points

### Debug Mode

```bash
# Verbose output with local variables
pytest -v -l

# Stop on first failure and drop to debugger
pytest -x --pdb

# Show print statements
pytest -s
```
