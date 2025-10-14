# ROS Helm Chart Scripts

Automation scripts for deploying, configuring, and testing the Resource Optimization Service (ROS) with JWT authentication and TLS certificate handling.

## 📋 Available Scripts

| Script | Purpose | Environment |
|--------|---------|-------------|
| `install-helm-chart.sh` | Deploy ROS Helm chart | All environments |
| `deploy-rhsso.sh` | Deploy Keycloak/RHSSO | OpenShift |
| `setup-cost-mgmt-tls.sh` | Configure TLS certificates | OpenShift |
| `test-ocp-dataflow-jwt.sh` | Test JWT authentication | JWT-enabled clusters |
| `deploy-kind.sh` | Create test cluster | CI/CD, Local dev |
| `cleanup-kind-artifacts.sh` | Cleanup test environment | CI/CD, Local dev |

## 🚀 Quick Start

### Standard OpenShift Deployment
```bash
# 1. Deploy Cost Management Operator with TLS support
./setup-cost-mgmt-tls.sh

# 2. Deploy ROS
./install-helm-chart.sh

# 3. Test the deployment (if JWT enabled)
./test-ocp-dataflow-jwt.sh
```

### JWT Authentication Setup
```bash
# 1. Deploy Keycloak/RHSSO
./deploy-rhsso.sh

# 2. Deploy ROS with JWT authentication
export JWT_AUTH_ENABLED=true
./install-helm-chart.sh

# 3. Configure TLS certificates
./setup-cost-mgmt-tls.sh

# 4. Test JWT flow
./test-ocp-dataflow-jwt.sh
```

### Local Development (KIND)
```bash
# 1. Create KIND cluster
./deploy-kind.sh

# 2. Deploy ROS from local chart
export USE_LOCAL_CHART=true
./install-helm-chart.sh

# 3. Cleanup when done
./cleanup-kind-artifacts.sh
```

## 📖 Script Documentation

### `install-helm-chart.sh`
Deploy or upgrade the ROS Helm chart with automatic configuration.

**Key features:**
- Installs from GitHub releases or local chart
- Auto-detects OpenShift and configures JWT authentication
- Manages namespace and deployment lifecycle
- **Automatically applies Cost Management Operator label** to namespace

**Namespace Labeling:**
The script automatically applies the `insights-cost-management-optimizations=true` label to the deployment namespace. This label is **required** by the Cost Management Metrics Operator to collect resource optimization data from the namespace.

To remove the label (if needed):
```bash
kubectl label namespace ros-ocp insights-cost-management-optimizations-
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

---

### `deploy-rhsso.sh`
Deploy Red Hat Single Sign-On (Keycloak) with ROS integration.

**What it creates:**
- RHSSO Operator in target namespace
- Keycloak instance with `kubernetes` realm
- `cost-management-operator` client
- OpenShift OIDC integration

**Usage:**
```bash
# Deploy to default namespace (rhsso)
./deploy-rhsso.sh

# Deploy to custom namespace
./deploy-rhsso.sh --namespace my-keycloak

# Skip OIDC integration
./deploy-rhsso.sh --skip-oidc
```

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
- Keycloak/RHSSO with `cost-management-operator` client

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
