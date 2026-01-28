# Run Tests

Run the pytest test suite against the connected OpenShift cluster.

## Prerequisites

Before running tests, ensure you have:
1. **Cluster access**: `oc whoami` returns your username
2. **Namespace exists**: `kubectl get namespace ${NAMESPACE:-cost-onprem}`
3. **Helm release deployed**: `helm list -n ${NAMESPACE:-cost-onprem}`

## Required Environment Variables

```bash
export NAMESPACE="cost-onprem"           # Target namespace (required)
export KEYCLOAK_NAMESPACE="keycloak"     # Keycloak namespace (optional)
export HELM_RELEASE_NAME="cost-onprem"   # Helm release name (optional)
```

## Commands

### Default CI Mode (~88 tests, ~3 minutes)
```bash
NAMESPACE=cost-onprem ./scripts/run-pytest.sh
```

### Extended Tests (requires ODF/S3, ~15 minutes)
```bash
NAMESPACE=cost-onprem ./scripts/run-pytest.sh --extended
```

### Specific Suites
```bash
./scripts/run-pytest.sh --helm           # Helm chart validation
./scripts/run-pytest.sh --auth           # JWT authentication
./scripts/run-pytest.sh --e2e            # End-to-end pipeline
./scripts/run-pytest.sh --infrastructure # DB, S3, Kafka health
./scripts/run-pytest.sh --ros            # ROS/Kruize health
```

### Smoke Tests (quick validation)
```bash
./scripts/run-pytest.sh --smoke
```

## Cleanup Options

```bash
E2E_CLEANUP_BEFORE=true   # Clean before tests (default)
E2E_CLEANUP_AFTER=true    # Clean after tests (default)
E2E_RESTART_SERVICES=false # Restart Redis/listener (optional)
```

## Output

- JUnit XML report: `tests/reports/junit.xml`
- Console output with test results
