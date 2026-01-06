# Cost On-Prem Test Suite

Pytest-based test suite for validating Cost On-Prem deployments on OpenShift.

## Prerequisites

- Python 3.9+
- OpenShift CLI (`oc`) installed and logged in
- Cost On-Prem deployed with JWT authentication enabled
- Keycloak (RHBK) deployed with the `cost-management-operator` client

## Quick Start

```bash
# Run all tests
./scripts/run-pytest.sh

# Run smoke tests only
./scripts/run-pytest.sh --smoke

# Run authentication tests
./scripts/run-pytest.sh --auth

# Run end-to-end tests
./scripts/run-pytest.sh --e2e
```

## Test Categories

| Marker | Description |
|--------|-------------|
| `smoke` | Quick smoke tests for basic functionality |
| `auth` | JWT authentication tests |
| `upload` | Data upload tests |
| `recommendations` | Recommendation verification tests |
| `e2e` | End-to-end data flow tests |
| `slow` | Tests that take longer to run |

## Configuration

Environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `NAMESPACE` | `cost-onprem` | Target namespace for Cost On-Prem |
| `HELM_RELEASE_NAME` | `cost-onprem` | Helm release name |
| `KEYCLOAK_NAMESPACE` | `keycloak` | Keycloak namespace |

## Test Reports

JUnit XML reports are generated at `tests/reports/junit.xml` for CI integration.

## Running Specific Tests

```bash
# Run tests matching a pattern
./scripts/run-pytest.sh -k "test_jwt"

# Run a specific test file
./scripts/run-pytest.sh tests/test_jwt_authentication.py

# Run with verbose output
./scripts/run-pytest.sh -v

# Run without virtual environment (use system Python)
./scripts/run-pytest.sh --no-venv
```

## Manual Setup

If you prefer to manage the environment manually:

```bash
cd tests
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

# Run tests
pytest -v --junit-xml=reports/junit.xml
```

## Test Structure

```
tests/
├── conftest.py              # Shared fixtures and configuration
├── test_jwt_authentication.py   # JWT auth tests
├── test_data_flow.py        # Upload and recommendation tests
├── pytest.ini               # Pytest configuration
├── requirements.txt         # Python dependencies
└── README.md               # This file
```

