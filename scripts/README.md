# ROS Helm Chart Scripts

Automation scripts for deploying, configuring, and testing the Resource Optimization Service (ROS) with JWT authentication and TLS certificate handling.

## 📋 Available Scripts

| Script | Purpose | Environment |
|--------|---------|-------------|
| **`install-cost-management-complete.sh`** | **Complete automated installation (NEW)** | **OpenShift** |
| **`verify-cost-management.sh`** | **Comprehensive health checks (NEW)** | **OpenShift** |
| `bootstrap-infrastructure.sh` | Deploy infrastructure chart | OpenShift |
| `deploy-strimzi.sh` | Deploy Kafka infrastructure | All environments |
| `install-helm-chart.sh` | Deploy ROS Helm chart | All environments |
| `install-cost-helm-chart.sh` | Deploy cost management chart | OpenShift |
| `install-authorino.sh` | Deploy Authorino for OAuth2 | OpenShift |
| `deploy-rhbk.sh` | Deploy Red Hat Build of Keycloak | OpenShift |
| `setup-cost-mgmt-tls.sh` | Configure TLS certificates | OpenShift |
| `test-ocp-dataflow-jwt.sh` | Test JWT + recommendations | JWT-enabled clusters |
| `cost-mgmt-ocp-dataflow.sh` | OCP dataflow validation | OpenShift |
| `query-kruize.sh` | Query Kruize database | All environments |
| `deploy-kind.sh` | Create test cluster | CI/CD, Local dev |
| `cleanup-kind-artifacts.sh` | Cleanup test environment | CI/CD, Local dev |

## 🚀 Quick Start

### Cost Management (Two-Chart Architecture) ⭐ NEW
```bash
# Complete automated installation
./install-cost-management-complete.sh --namespace cost-mgmt

# That's it! The script handles:
# - Kafka deployment
# - S3 credentials setup
# - Infrastructure chart (PostgreSQL, Trino, Redis)
# - Application chart (Koku API, MASU, Celery, Sources)
# - Comprehensive verification
# - E2E testing

# Run verification anytime
./verify-cost-management.sh --namespace cost-mgmt
```

See [Cost Management Installation Guide](../docs/cost-management-installation.md) for detailed documentation.

---

### Standard OpenShift Deployment
```bash
# 1. Deploy Cost Management Operator with TLS support
./setup-cost-mgmt-tls.sh

# 2. Deploy Kafka infrastructure
./deploy-strimzi.sh

# 3. Deploy Authorino for OAuth2 authentication
./install-authorino.sh

# 4. Deploy ROS
./install-helm-chart.sh

# 5. Test the deployment (if JWT enabled)
./test-ocp-dataflow-jwt.sh
```

### JWT Authentication Setup
```bash
# 1. Deploy Red Hat Build of Keycloak
./deploy-rhbk.sh

# 2. Deploy Kafka infrastructure
./deploy-strimzi.sh

# 3. Deploy Authorino for OAuth2 authentication
./install-authorino.sh

# 4. Deploy ROS with JWT authentication
export JWT_AUTH_ENABLED=true
./install-helm-chart.sh

# 5. Configure TLS certificates
./setup-cost-mgmt-tls.sh

# 6. Test JWT flow
./test-ocp-dataflow-jwt.sh
```

### Local Development (KIND)
```bash
# 1. Create KIND cluster
./deploy-kind.sh

# 2. Deploy Kafka infrastructure
./deploy-strimzi.sh

# 3. Deploy ROS from local chart
export USE_LOCAL_CHART=true
./install-helm-chart.sh

# 4. Cleanup when done
./cleanup-kind-artifacts.sh
```

## 📖 Script Documentation

### `install-cost-management-complete.sh` ⭐ NEW
Complete automated installation of Cost Management with two-chart architecture.

**Key features:**
- ✅ **End-to-end automation**: Orchestrates all installation phases
- ✅ **Prerequisites check**: Validates tools, cluster access, and ODF
- ✅ **Kafka deployment**: Deploys Strimzi Operator and Kafka cluster
- ✅ **S3 credentials**: Interactive or parameter-based credential setup
- ✅ **Infrastructure deployment**: PostgreSQL, Trino, Redis, Hive Metastore
- ✅ **Application deployment**: Koku API, MASU, Celery, Sources
- ✅ **Comprehensive verification**: Automated health checks
- ✅ **E2E testing**: Optional smoke tests with nise

**Usage:**
```bash
# Interactive installation (recommended)
./install-cost-management-complete.sh --namespace cost-mgmt

# Non-interactive with credentials
./install-cost-management-complete.sh \
  --namespace cost-mgmt \
  --s3-access-key <key> \
  --s3-secret-key <secret>

# Skip optional phases
./install-cost-management-complete.sh \
  --namespace cost-mgmt \
  --skip-kafka \
  --skip-verification \
  --skip-e2e
```

**Options:**
- `--namespace <name>`: Kubernetes namespace (default: `cost-mgmt`)
- `--s3-access-key <key>`: S3 access key (prompts if not provided)
- `--s3-secret-key <key>`: S3 secret key (prompts if not provided)
- `--skip-kafka`: Skip Kafka deployment
- `--skip-verification`: Skip verification checks
- `--skip-e2e`: Skip E2E tests
- `--chart-path <path>`: Custom chart directory path
- `--help`: Show help message

**What it does:**
1. **Prerequisites Check**: Validates `oc`, `helm`, cluster access, ODF
2. **Kafka Deployment**: Deploys Strimzi and creates Kafka cluster
3. **S3 Credentials**: Creates `odf-s3-credentials` secret
4. **Infrastructure**: Deploys PostgreSQL, Trino, Redis via Helm chart
5. **Application**: Deploys Koku, MASU, Celery, Sources via Helm chart
6. **Verification**: Runs comprehensive health checks
7. **E2E Tests**: Runs OCP smoke tests with nise (optional)

**See**: [Cost Management Installation Guide](../docs/cost-management-installation.md)

---

### `verify-cost-management.sh` ⭐ NEW
Comprehensive verification and health checks for Cost Management deployments.

**Key features:**
- ✅ **Pod health**: Checks all 23+ pods are running
- ✅ **Database verification**: Tests PostgreSQL connectivity and migrations
- ✅ **API health check**: Tests Koku API endpoint
- ✅ **Kafka connectivity**: Validates application can connect to Kafka
- ✅ **Storage verification**: Checks PVC binding and S3 credentials
- ✅ **Celery workers**: Validates 12+ workers are operational
- ✅ **Sources API**: Checks Sources components are healthy
- ✅ **Detailed reporting**: Shows pass/fail with statistics
- ✅ **E2E tests**: Optional smoke tests (included by default)

**Usage:**
```bash
# Run all checks
./verify-cost-management.sh --namespace cost-mgmt

# Verbose mode (detailed output)
./verify-cost-management.sh --namespace cost-mgmt --verbose

# Skip E2E tests
./verify-cost-management.sh --namespace cost-mgmt --skip-e2e
```

**Options:**
- `--namespace <name>`: Kubernetes namespace (required)
- `--skip-e2e`: Skip E2E tests
- `--verbose`: Show detailed output
- `--help`: Show help message

**Verification Phases:**
- **Phase 3.1**: Pod Health Check (23+ running pods)
- **Phase 3.2**: Database Verification (tenants, migrations, extensions)
- **Phase 3.3**: API Health Check (status endpoint)
- **Phase 3.4**: Kafka Connectivity (application to Kafka)
- **Phase 3.5**: Storage Verification (PVCs, S3 credentials)
- **Phase 3.6**: Celery Workers Check (12+ workers)
- **Phase 3.7**: Sources API Check (API + database)
- **Phase 3.8**: Complete Health Summary
- **Phase 4**: E2E Testing (optional, included by default)

**Exit Codes:**
- `0`: All checks passed (with or without warnings)
- `1`: One or more checks failed

---

### `install-helm-chart.sh`
Deploy or upgrade the ROS Helm chart with automatic configuration.

**Key features:**
- Installs from GitHub releases or local chart
- Auto-detects OpenShift and configures JWT authentication
- Manages namespace and deployment lifecycle
- **Automatically applies Cost Management Operator label** to namespace

**Namespace Labeling:**
The script automatically applies the `cost_management_optimizations=true` label to the deployment namespace. This label is **required** by the Cost Management Metrics Operator to collect resource optimization data from the namespace.

To remove the label (if needed):
```bash
kubectl label namespace ros-ocp cost_management_optimizations-
```

**Usage:**
```bash
# Basic installation
./install-helm-chart.sh

# Use local chart for development
export USE_LOCAL_CHART=true
./install-helm-chart.sh

# Custom namespace
export NAMESPACE=ros-production
./install-helm-chart.sh

# Check deployment status
./install-helm-chart.sh status

# Cleanup
./install-helm-chart.sh cleanup
```

**Environment variables:**
- `NAMESPACE`: Target namespace (default: `ros-ocp`)
- `USE_LOCAL_CHART`: Use local chart instead of GitHub (default: `false`)
- `JWT_AUTH_ENABLED`: Enable JWT authentication (default: auto-detect)
- `VALUES_FILE`: Custom values file path
- `KAFKA_BOOTSTRAP_SERVERS`: Use external Kafka (skips verification)

---

### `deploy-rhbk.sh`
Deploy Red Hat Build of Keycloak (RHBK) with ROS integration.

**What it creates:**
- RHBK Operator in target namespace
- Keycloak instance with `kubernetes` realm
- `cost-management-operator` client
- OpenShift OIDC integration

**Usage:**
```bash
# Deploy to default namespace (keycloak)
./deploy-rhbk.sh

# Deploy to custom namespace
RHBK_NAMESPACE=my-keycloak ./deploy-rhbk.sh

# Validate existing deployment
./deploy-rhbk.sh validate

# Clean up deployment
./deploy-rhbk.sh cleanup
```

---

### `install-authorino.sh`
Deploy Authorino Operator and configure OAuth2 TokenReview authentication for the ROS-OCP backend API.

**What it does:**
- Installs Authorino Operator (Red Hat certified catalog)
- Creates Authorino instance in target namespace
- Configures RBAC for Kubernetes TokenReview API access
- Validates installation and service availability

**Authentication flow:**
1. User accesses ROS-OCP via OpenShift Console UI
2. Console includes user's session token in request
3. Envoy proxy forwards request to Authorino
4. Authorino validates token via Kubernetes TokenReview API
5. If valid, Authorino injects headers (username, UID)
6. Envoy transforms headers into rh-identity format
7. Backend receives authenticated request

**Usage:**
```bash
# Install to default namespace (ros-ocp)
./install-authorino.sh

# Install to custom namespace
NAMESPACE=ros-production ./install-authorino.sh

# Verify existing installation
./install-authorino.sh --verify-only

# Update RBAC only
./install-authorino.sh --rbac-only

# Show help
./install-authorino.sh --help
```

**Environment variables:**
- `NAMESPACE`: Target namespace (default: `ros-ocp`)
- `AUTHORINO_OPERATOR_NAMESPACE`: Operator namespace (default: `openshift-operators`)

**What gets installed:**
- Authorino Operator (Red Hat catalog, tech-preview-v1 channel)
- Authorino CR with gRPC authorization service
- ClusterRole for TokenReview API access
- ClusterRoleBinding for Authorino ServiceAccount
- Authorino service on port 50051 (gRPC)

**Verification:**
```bash
# Check Operator
oc get csv -n openshift-operators | grep authorino

# Check Authorino instance
oc get authorino -n ros-ocp

# Check Authorino pods
oc get pods -n ros-ocp | grep authorino

# Check Authorino service
oc get svc -n ros-ocp | grep authorino
```

**See [OAuth2 TokenReview Authentication Guide](../docs/oauth2-tokenreview-authentication.md) for architecture details**

---

### `setup-cost-mgmt-tls.sh`
Configure Cost Management Operator with comprehensive CA certificate support.

**Features:**
- Extracts CA certificates from 15+ sources (routers, Keycloak, system CAs, custom CAs)
- Creates consolidated CA bundle for self-signed certificate environments
- Configures Cost Management Operator with proper TLS settings

**Usage:**
```bash
# Complete setup (recommended for all environments)
./setup-cost-mgmt-tls.sh

# Custom namespace with verbose output
./setup-cost-mgmt-tls.sh -n my-cost-mgmt -v

# Dry-run to preview actions
./setup-cost-mgmt-tls.sh --dry-run
```

**Best for:** All OpenShift environments, especially those with self-signed certificates

---

### `deploy-strimzi.sh`
Deploy Strimzi operator and Kafka cluster.

**What it creates:**
- Strimzi Operator (Kafka cluster management)
- Kafka 3.8.0 cluster with persistent storage
- Required Kafka topics for ROS-OCP

**Usage:**
```bash
# Basic deployment
./deploy-strimzi.sh

# Deploy for OpenShift with custom storage
KAFKA_ENVIRONMENT=ocp ./deploy-strimzi.sh

# Use existing Strimzi operator
STRIMZI_NAMESPACE=existing-strimzi ./deploy-strimzi.sh

# Use existing external Kafka
KAFKA_BOOTSTRAP_SERVERS=my-kafka:9092 ./deploy-strimzi.sh

# Validate existing deployment
./deploy-strimzi.sh validate

# Cleanup
./deploy-strimzi.sh cleanup
```

**Environment variables:**
- `KAFKA_NAMESPACE`: Target namespace (default: `kafka`)
- `KAFKA_CLUSTER_NAME`: Kafka cluster name (default: `ros-ocp-kafka`)
- `KAFKA_VERSION`: Kafka version (default: `3.8.0`)
- `STRIMZI_VERSION`: Strimzi operator version (default: `0.45.1`)
- `KAFKA_ENVIRONMENT`: Environment type - `dev` or `ocp` (default: `dev`)
- `STORAGE_CLASS`: Storage class name (auto-detected if empty)
- `KAFKA_BOOTSTRAP_SERVERS`: Use external Kafka (skips deployment)

**Platform detection:**
- **Kubernetes/KIND**: Single-node Kafka with minimal resources
- **OpenShift**: 3-node HA Kafka with production configuration

---

### `test-ocp-dataflow-jwt.sh`
End-to-end test of JWT authentication flow with sample cost data.

**Test flow:**
1. Auto-detects Keycloak configuration
2. Obtains JWT token using client credentials
3. Creates test payload (CSV + manifest.json)
4. Uploads data via JWT-authenticated endpoint
5. Validates ingress processing
6. Checks for ML recommendations

**Usage:**
```bash
# Test JWT authentication
./test-ocp-dataflow-jwt.sh

# Custom namespace
./test-ocp-dataflow-jwt.sh --namespace ros-production

# Verbose output for troubleshooting
./test-ocp-dataflow-jwt.sh --verbose
```

**Requirements:**
- JWT authentication enabled in ROS deployment
- Red Hat Build of Keycloak (RHBK) with `cost-management-operator` client

**Best for:** CI/CD pipelines, complete E2E validation including ML recommendations

---

### `query-kruize.sh`
Query Kruize database for experiments and ML recommendations.

**What it does:**
- Connects to Kruize PostgreSQL database directly
- Lists experiments and their status
- Shows generated ML recommendations
- Supports custom SQL queries
- Displays database schema

**Usage:**
```bash
# List all experiments
./query-kruize.sh --experiments

# List all recommendations
./query-kruize.sh --recommendations

# Find experiments by pattern
./query-kruize.sh --experiment "test-cluster"

# Query by cluster ID
./query-kruize.sh --cluster "757b6bf6-9e91-486a-8a99-6d3e6d0f485c"

# Get detailed recommendation info
./query-kruize.sh --detail 5

# Run custom SQL query
./query-kruize.sh --query "SELECT COUNT(*) FROM kruize_experiments WHERE status='IN_PROGRESS';"

# Show database schema
./query-kruize.sh --schema

# Custom namespace
./query-kruize.sh --namespace ros-production --experiments
```

**Requirements:**
- Kruize deployed and running
- Database pod accessible via `oc exec`

**Best for:** Debugging, validating data flow, checking recommendation generation status

---

## 🧪 Test Strategy

### For CI/CD Pipelines
Use the JWT test script for comprehensive E2E validation:

**Recommended CI/CD workflow:**
```bash
# 1. Deploy Kafka infrastructure
./deploy-strimzi.sh

# 2. Deploy environment
./install-helm-chart.sh

# 3. Validate full E2E with ML (quick synthetic test)
./test-ocp-dataflow-jwt.sh || exit 1
```

The `test-ocp-dataflow-jwt.sh` script validates:
- ✅ JWT authentication
- ✅ Full data flow (ingress → processor → Kruize)
- ✅ ML recommendation generation
- ✅ Complete E2E functionality in ~2 minutes

---

### `deploy-kind.sh`
Create KIND (Kubernetes IN Docker) cluster for testing and development.

**Features:**
- Lightweight Kubernetes cluster in Docker
- Fixed 6GB memory allocation
- Automated ingress controller setup
- Suitable for CI/CD pipelines

**Usage:**
```bash
# Create default cluster
./deploy-kind.sh

# Custom cluster name
export KIND_CLUSTER_NAME=ros-test
./deploy-kind.sh

# Use Docker instead of Podman
export CONTAINER_RUNTIME=docker
./deploy-kind.sh
```

**Resource requirements:** 6GB+ memory for container runtime

---

### `cleanup-kind-artifacts.sh`
Clean up KIND clusters and related resources.

**Usage:**
```bash
# Cleanup default cluster
./cleanup-kind-artifacts.sh

# Cleanup custom cluster
export KIND_CLUSTER_NAME=ros-test
./cleanup-kind-artifacts.sh
```

**When to use:**
- After CI/CD test runs (use `if: always()`)
- Between test iterations
- When troubleshooting cluster issues

---

## 🔧 Common Environment Variables

Most scripts support these variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `NAMESPACE` | Target namespace | `ros-ocp` |
| `VERBOSE` | Enable detailed logging | `false` |
| `DRY_RUN` | Preview without executing | `false` |
| `JWT_AUTH_ENABLED` | Enable JWT authentication | Auto-detect |
| `USE_LOCAL_CHART` | Use local chart for testing | `false` |

## 🚨 Troubleshooting

### Common Issues

**TLS Certificate Errors**
```bash
# Run comprehensive TLS setup
./setup-cost-mgmt-tls.sh --verbose
```

**JWT Authentication Failures**
```bash
# Test with verbose logging
./test-ocp-dataflow-jwt.sh --verbose

# Check Envoy sidecar logs
oc logs -n ros-ocp -l app.kubernetes.io/name=ingress -c envoy-proxy
```

**Cost Management Operator Issues**
```bash
# Check operator logs
oc logs -n costmanagement-metrics-operator deployment/costmanagement-metrics-operator

# Verify namespace labeling
oc label namespace <namespace> cost_management_optimizations=true
```

For detailed troubleshooting, see [Troubleshooting Guide](../docs/troubleshooting.md)

## 📚 Related Documentation

- **[Installation Guide](../docs/installation.md)** - Complete installation instructions
- **[JWT Authentication](../docs/native-jwt-authentication.md)** - JWT setup and configuration
- **[TLS Setup Guide](../docs/cost-management-operator-tls-setup.md)** - Detailed TLS configuration
- **[Configuration Reference](../docs/configuration.md)** - Helm values and configuration options
- **[Helm Templates Reference](../docs/helm-templates-reference.md)** - Technical chart details
- **[Troubleshooting](../docs/troubleshooting.md)** - Detailed troubleshooting guide

## 📝 Script Maintenance

### Dependencies
- `oc` (OpenShift CLI)
- `helm` (Helm CLI v3+)
- `jq` (JSON processor)
- `curl` (HTTP client)
- `openssl` (Certificate tools)

### Logging Conventions
All scripts use color-coded output:
- 🟢 **SUCCESS**: Green for successful operations
- 🔵 **INFO**: Blue for informational messages
- 🟡 **WARNING**: Yellow for warnings
- 🔴 **ERROR**: Red for errors and failures

---

**Last Updated**: October 2025
**Maintainer**: ROS Engineering Team
**Supported Platforms**: OpenShift 4.18+ (Kubernetes 1.31+), KIND (CI/CD)
**Tested With**: OpenShift 4.18.24
