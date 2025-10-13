# ROS Helm Chart Scripts Documentation

This directory contains automation scripts for deploying, configuring, and testing the Resource Optimization Service (ROS) with JWT authentication and TLS certificate handling. Scripts support both production OpenShift environments and lightweight KIND (Kubernetes IN Docker) clusters for CI/CD testing and local development.

## 📋 Script Overview

| Script | Purpose | Environment | Complexity |
|--------|---------|-------------|-----------|
| `deploy-kind.sh` | 🧪 KIND cluster setup | CI/CD, Local Dev | Medium |
| `cleanup-kind-artifacts.sh` | 🧹 KIND cleanup | CI/CD, Local Dev | Low |
| `install-helm-chart.sh` | 📦 Helm deployment | All | Medium |
| `deploy-rhsso.sh` | 🔐 Keycloak/RHSSO setup | OCP with RHSSO | High |
| `test-ocp-dataflow-jwt.sh` | 🧪 JWT auth testing | JWT-enabled | Medium |
| `test-ocp-dataflow-cost-management.sh` | 🎯 Cost mgmt testing | Cost mgmt enabled | Medium |
| `validate-jwt-setup.sh` | ✅ JWT validation | JWT-enabled | Low |
| `setup-cost-mgmt-tls.sh` | 🛠️ Complete Cost Mgmt deployment with TLS | Any OCP | Medium |

## 🔐 Authentication & Security Scripts

### `deploy-rhsso.sh`
**Purpose**: Automated deployment of Red Hat Single Sign-On (Keycloak) with ROS integration.

**Features**:
- RHSSO Operator installation
- Keycloak instance creation
- Kubernetes realm configuration
- Cost Management client setup
- OpenShift OIDC integration

**Usage**:
```bash
# Deploy to rhsso namespace (default)
./deploy-rhsso.sh

# Deploy to custom namespace
./deploy-rhsso.sh --namespace my-keycloak

# Skip OIDC integration
./deploy-rhsso.sh --skip-oidc
```

**What it creates**:
- `rhsso` namespace with RHSSO Operator
- Keycloak instance with `kubernetes` realm
- `cost-management-operator` client
- Required users and service accounts

---

### `setup-cost-mgmt-tls.sh`
**Purpose**: Complete Cost Management Operator deployment with comprehensive CA certificate support for self-signed certificate environments.

**Extracts** (15+ methods):
- **Router CAs**: Ingress operator, default certs, controller config, console route
- **Keycloak CAs**: Route extraction, TLS secrets, service certs, StatefulSet config
- **System CAs**: Root CA, service CA, cluster bundle, API server, registry
- **Custom CAs**: ConfigMaps, live HTTPS connections, pod-level certs

**Usage**:
```bash
# Complete Cost Management Operator deployment
./setup-cost-mgmt-tls.sh

# Custom namespace and verbose output
./setup-cost-mgmt-tls.sh -n my-cost-mgmt -v

# Dry-run to see what would be done
./setup-cost-mgmt-tls.sh --dry-run
```

**Best for**:
- All OpenShift environments (standard to complex)
- Production and development clusters
- Custom Keycloak configurations
- Air-gapped/security-hardened clusters
- Any deployment requiring comprehensive certificate coverage

**Performance**: 2-3 minutes execution time

---

## 🧪 Testing & Validation Scripts

### `test-ocp-dataflow-jwt.sh`
**Purpose**: End-to-end testing of JWT authentication flow with sample data.

**Test flow**:
1. Auto-detects Keycloak configuration
2. Retrieves JWT token using client credentials
3. Creates sample cost management data
4. Uploads data using JWT authentication
5. Validates ingress processing
6. Checks for ML recommendations

**Usage**:
```bash
# Test JWT authentication
./test-ocp-dataflow-jwt.sh

# Custom namespace
./test-ocp-dataflow-jwt.sh --namespace ros-production

# Verbose output
./test-ocp-dataflow-jwt.sh --verbose
```

**Requirements**:
- JWT authentication enabled
- Keycloak configured with `cost-management-operator` client
- ROS ingress deployed with Authorino sidecar

---

### `test-ocp-dataflow-cost-management.sh`
**Purpose**: Tests the actual Cost Management Operator data upload and processing.

**Features**:
- Automatic namespace labeling for cost optimization
- Cost Management Operator pod management
- Upload monitoring and validation
- ML recommendation verification
- Comprehensive error reporting

**Test phases**:
1. **STEP 0**: Ensure cost optimization labels on namespaces
2. **STEP 1**: Trigger cost management operator upload
3. **STEP 2**: Validate data processing and storage
4. **STEP 3**: Check for ML recommendations

**Usage**:
```bash
# Test cost management data flow
./test-ocp-dataflow-cost-management.sh

# Monitor upload only
./test-ocp-dataflow-cost-management.sh --upload-only

# Skip recommendation checks
./test-ocp-dataflow-cost-management.sh --no-recommendations
```

**Key feature**: Automatically labels namespaces with `cost_management_optimizations=true` to enable ROS file generation.

---

### `validate-jwt-setup.sh`
**Purpose**: Validates JWT authentication infrastructure and configuration.

**Checks**:
- Authorino operator deployment
- AuthConfig resources
- Envoy sidecar configuration
- Keycloak connectivity
- Certificate trust chains

**Usage**:
```bash
# Validate JWT setup
./validate-jwt-setup.sh

# Quick health check
./validate-jwt-setup.sh --health-check
```

---

## 🎯 Usage Recommendations

### For Standard Deployments
```bash
# 1. Deploy Cost Management Operator with TLS support
./setup-cost-mgmt-tls.sh

# 2. Test the deployment
./test-ocp-dataflow-cost-management.sh
```

### For JWT Authentication
```bash
# 1. Deploy Keycloak
./deploy-rhsso.sh

# 2. Deploy ROS with JWT auth
export JWT_AUTH_ENABLED=true
./install-helm-chart.sh

# 3. Deploy Cost Management Operator with TLS support
./setup-cost-mgmt-tls.sh

# 4. Validate JWT setup
./validate-jwt-setup.sh

# 5. Test JWT authentication
./test-ocp-dataflow-jwt.sh
```

### For Production Environments
```bash
# 1. Deploy Cost Management Operator with comprehensive TLS setup
./setup-cost-mgmt-tls.sh --verbose

# 2. Deploy Keycloak for production
./deploy-rhsso.sh

# 3. Run full validation suite
./validate-jwt-setup.sh
./test-ocp-dataflow-cost-management.sh
./test-ocp-dataflow-jwt.sh
```

## 🔄 Deployment Approach

1. **Complete Solution**: Use comprehensive CA script for all environments
2. **Validate Everything**: Always run validation scripts after deployments
3. **Test End-to-End**: Use both JWT and cost management test scripts

## 🚨 Troubleshooting Guide

### Common Issues

**TLS Certificate Errors**:
```bash
# Deploy Cost Management Operator for all environments
./setup-cost-mgmt-tls.sh --verbose
```

**JWT Authentication Failures**:
```bash
# Check JWT setup
./validate-jwt-setup.sh

# Test with sample data
./test-ocp-dataflow-jwt.sh --verbose
```

**Cost Management Upload Issues**:
```bash
# Ensure namespace labeling
./test-ocp-dataflow-cost-management.sh --upload-only

# Check for missing ROS files
oc logs -n costmanagement-metrics-operator deployment/costmanagement-metrics-operator
```

## 📝 Script Maintenance

### Dependencies
- `oc` (OpenShift CLI)
- `helm` (Helm CLI)
- `jq` (JSON processor)
- `curl` (HTTP client)
- `openssl` (Certificate tools)

### Environment Variables
Most scripts support these environment variables:
- `NAMESPACE`: Target namespace override
- `VERBOSE`: Enable detailed logging
- `DRY_RUN`: Show actions without executing

### Logging
All scripts use consistent logging with color-coded output:
- 🟢 **SUCCESS**: Green text for successful operations
- 🔵 **INFO**: Blue text for informational messages
- 🟡 **WARNING**: Yellow text for warnings
- 🔴 **ERROR**: Red text for errors and failures

## 🎛️ Helm Templates & Manifests

The following Helm templates and manifests are included for JWT authentication and TLS certificate handling:

### JWT Authentication Templates

#### `ros-ocp/templates/authconfig.yaml`
**Purpose**: Configures Authorino AuthConfig for Keycloak JWT validation.

**Features**:
- Keycloak OIDC discovery configuration
- JWT token validation rules
- Host-based routing protection
- TLS bypass for self-signed certificates

**Usage**: Automatically deployed when `jwt_auth.enabled=true`

#### `ros-ocp/templates/deployment-ingress.yaml`
**Purpose**: Enhanced ingress deployment with Envoy sidecar for JWT authentication.

**Features**:
- Envoy proxy sidecar for external authentication
- Conditional authentication (JWT vs traditional)
- Port configuration for sidecar routing
- Health probe adjustments
- Custom ingress image support

**Key Environment Variables**:
- `AUTH_ENABLED`: Controls traditional auth (false when JWT enabled)
- `SERVER_PORT`: Ingress container port (8081 for JWT, 8080 for traditional)

#### `ros-ocp/templates/envoy-config.yaml`
**Purpose**: Envoy proxy configuration for routing and JWT validation.

**Features**:
- External authorization filter configuration
- Authorino service routing
- Request size limits (configurable)
- Access logging configuration

**Configuration Options**:
- `jwt_auth.envoy.maxRequestBytes`: Maximum request size (default: 100MB)
- `jwt_auth.authorino.service`: Authorino service endpoint

#### `ros-ocp/templates/service-ingress.yaml`
**Purpose**: Kubernetes service for ingress with Envoy proxy endpoints.

**Features**:
- Dual port configuration (Envoy + ingress)
- Service discovery for JWT routing
- Load balancer configuration

### Authorino Direct Deployment Templates

#### `ros-ocp/templates/authorino-direct-full.yaml`
**Purpose**: Complete direct deployment of Authorino without operator.

**Features**:
- ServiceAccount, ClusterRole, ClusterRoleBinding
- Authorino deployment with TLS bypass
- CA certificate mounting
- Service configuration

**Use Case**: When operator-based deployment doesn't support TLS bypass


### Security & Certificate Templates

#### `ros-ocp/templates/ca-configmap.yaml`
**Purpose**: ConfigMap for CA certificate bundle injection.

**Features**:
- Automatic CA certificate extraction
- Mount point for Authorino containers
- Support for multiple CA sources

#### `ros-ocp/templates/_helpers.tpl`
**Purpose**: Helm template helper functions.

**Functions**:
- JWT authentication conditionals
- Service name generation
- Namespace helpers
- Port configuration logic

## ⚙️ Configuration Files & Examples

### `ros-ocp/values-jwt-auth-complete.yaml`
**Purpose**: Complete JWT authentication configuration for production use.

**Features**:
- Full JWT authentication setup
- Authorino direct deployment configuration
- Envoy sidecar configuration
- TLS bypass settings for self-signed certificates
- Custom ingress image configuration

**Usage**:
```bash
helm upgrade ros-ocp ./ros-ocp -f values-jwt-auth-complete.yaml
```

**Key Sections**:
- `jwt_auth.enabled: true` - Enables JWT authentication
- `jwt_auth.authorino.deploy.enabled: true` - Direct Authorino deployment
- `jwt_auth.envoy.image` - Envoy proxy image configuration
- `ingress.image.repository` - Custom ingress image with conditional auth

### `examples/costmanagementmetricscfg-tls.yaml`
**Purpose**: Example CostManagementMetricsConfig with TLS certificate handling.

**Features**:
- Self-signed certificate support configuration
- Environment variable examples for CA bundles
- Volume mount examples for certificate trust
- Production-ready TLS settings

**Usage**:
```bash
oc apply -f examples/costmanagementmetricscfg-tls.yaml
```

**Key Configuration**:
- Custom CA bundle mounting
- TLS verification settings
- Certificate rotation support

## 📚 Related Documentation

- [Cost Management Operator TLS Setup](../docs/COST-MANAGEMENT-OPERATOR-TLS-SETUP.md)
- [JWT Authentication Guide](../docs/JWT-AUTHENTICATION.md)
- [JWT Authentication Values](../ros-ocp/values-jwt-auth-complete.yaml)
- [Troubleshooting Guide](../docs/TROUBLESHOOTING.md)

## 🎯 Complete Setup Flow

For a full deployment with JWT authentication and TLS support:

1. **Deploy Keycloak/RHSSO**:
   ```bash
   ./scripts/deploy-rhsso.sh
   ```

2. **Fix TLS certificates**:
   ```bash
   ./scripts/setup-cost-mgmt-tls.sh
   ```

3. **Deploy ROS with JWT**:
   ```bash
   helm upgrade ros-ocp ./ros-ocp -f values-jwt-auth-complete.yaml
   ```

4. **Validate setup**:
   ```bash
   ./scripts/validate-jwt-setup.sh
   ```

5. **Test end-to-end**:
   ```bash
   ./scripts/test-ocp-dataflow-jwt.sh
   ./scripts/test-ocp-dataflow-cost-management.sh
   ```

---

## 🧪 CI/CD & Development Testing

### Overview
These scripts enable end-to-end testing in CI/CD pipelines without requiring a full OpenShift cluster. Using KIND (Kubernetes IN Docker), they provide a lightweight testing environment for automated testing and local development.

### `deploy-kind.sh`
**Purpose**: Automated KIND cluster creation for CI/CD testing and local development.

**Features**:
- KIND cluster creation with optimized resource allocation
- Container runtime support (Docker/Podman)
- Fixed memory management (6GB allocation)
- Automated ingress controller setup
- Full ROS-OCP deployment capability
- CI/CD pipeline integration

**Usage**:
```bash
# Create default test cluster
./deploy-kind.sh

# Custom cluster name for parallel testing
export KIND_CLUSTER_NAME=ros-test-cluster
./deploy-kind.sh

# Use Docker instead of Podman
export CONTAINER_RUNTIME=docker
./deploy-kind.sh

# Enable ingress debugging
export INGRESS_DEBUG_LEVEL=2
./deploy-kind.sh
```

**Resource Requirements**:
- **Container Runtime**: Minimum 6GB memory allocation
- **KIND Node**: 6GB fixed memory limit
- **Allocatable**: ~5.2GB after system reservations
- **Full Deployment**: ~4.5GB for all ROS-OCP services

**CI/CD Integration Example**:
```yaml
# GitHub Actions
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - name: Setup KIND cluster
        run: ./scripts/deploy-kind.sh

      - name: Run E2E tests
        run: ./scripts/test-ocp-dataflow-jwt.sh

      - name: Cleanup
        if: always()
        run: ./scripts/cleanup-kind-artifacts.sh
```

---

### `cleanup-kind-artifacts.sh`
**Purpose**: Comprehensive cleanup of KIND clusters, containers, and artifacts between CI/CD runs.

**Features**:
- KIND cluster deletion
- Container cleanup (running and stopped)
- Image pruning
- Network cleanup
- Complete environment reset
- Container runtime detection (Docker/Podman)

**Usage**:
```bash
# Cleanup default cluster
./cleanup-kind-artifacts.sh

# Cleanup custom cluster
export KIND_CLUSTER_NAME=ros-test-cluster
./cleanup-kind-artifacts.sh

# Use Docker runtime
export CONTAINER_RUNTIME=docker
./cleanup-kind-artifacts.sh
```

**When to Use**:
- After CI/CD test runs (use `if: always()` in pipelines)
- Between test iterations
- Before creating a fresh test environment
- When troubleshooting cluster issues

---

### `install-helm-chart.sh`
**Purpose**: Automated Helm chart deployment with configuration management and lifecycle operations.

**Features**:
- Helm chart installation/upgrade automation
- GitHub release download or local chart support
- JWT authentication configuration
- Namespace management
- Deployment validation and health checks
- Complete lifecycle management (install, cleanup, status)
- OpenShift auto-detection

**Usage**:
```bash
# Basic installation (latest release from GitHub)
./install-helm-chart.sh

# Use local chart for development
export USE_LOCAL_CHART=true
./install-helm-chart.sh

# Custom namespace
export NAMESPACE=ros-production
./install-helm-chart.sh

# Use specific values file
export VALUES_FILE=values-production.yaml
./install-helm-chart.sh

# Enable JWT authentication (OpenShift only)
export JWT_AUTH_ENABLED=true
./install-helm-chart.sh

# Custom release name
export HELM_RELEASE_NAME=ros-prod
./install-helm-chart.sh
```

**Commands**:
```bash
# Install/upgrade ROS
./install-helm-chart.sh

# Check deployment status
./install-helm-chart.sh status

# Run health checks
./install-helm-chart.sh health

# Cleanup (preserve data volumes)
./install-helm-chart.sh cleanup

# Complete removal (including data)
./install-helm-chart.sh cleanup --complete

# Fix Kafka conflicts
./install-helm-chart.sh cleanup --kafka-conflicts

# Show help
./install-helm-chart.sh help
```

**Environment Variables**:
- `HELM_RELEASE_NAME`: Helm release name (default: `ros-ocp`)
- `NAMESPACE`: Target namespace (default: `ros-ocp`)
- `VALUES_FILE`: Path to custom values file
- `USE_LOCAL_CHART`: Use local chart instead of GitHub release (default: `false`)
- `LOCAL_CHART_PATH`: Path to local chart directory (default: `../ros-ocp`)
- `JWT_AUTH_ENABLED`: Enable JWT authentication (default: auto-detect)

**CI/CD Integration Example**:
```yaml
# GitLab CI
test-deployment:
  script:
    - export USE_LOCAL_CHART=true
    - ./scripts/install-helm-chart.sh
    - ./scripts/test-ocp-dataflow-jwt.sh
  after_script:
    - ./scripts/install-helm-chart.sh cleanup --complete
```

---

## 🔄 Complete CI/CD Workflow

### End-to-End Testing Pipeline
```bash
# 1. Create KIND test environment
./scripts/deploy-kind.sh

# 2. Deploy ROS using local chart
export USE_LOCAL_CHART=true
./scripts/install-helm-chart.sh

# 3. Deploy Keycloak for JWT testing (if needed)
./scripts/deploy-rhsso.sh

# 4. Validate JWT setup
./scripts/validate-jwt-setup.sh

# 5. Run E2E tests
./scripts/test-ocp-dataflow-jwt.sh
./scripts/test-ocp-dataflow-cost-management.sh

# 6. Cleanup (always run)
./scripts/cleanup-kind-artifacts.sh
```

### Local Development Iteration
```bash
# One-time setup
./scripts/deploy-kind.sh

# Deploy and iterate
export USE_LOCAL_CHART=true
./scripts/install-helm-chart.sh

# Make changes to chart, then upgrade
./scripts/install-helm-chart.sh

# Check status
./scripts/install-helm-chart.sh status

# When done, cleanup
./scripts/cleanup-kind-artifacts.sh
```

### Troubleshooting in CI/CD
```bash
# Check deployment health
./scripts/install-helm-chart.sh health

# View detailed status
./scripts/install-helm-chart.sh status

# Clean reinstall preserving data
./scripts/install-helm-chart.sh cleanup
./scripts/install-helm-chart.sh

# Complete fresh reinstall
./scripts/install-helm-chart.sh cleanup --complete
./scripts/install-helm-chart.sh
```

---

**Last Updated**: October 2025
**Maintainer**: ROS Engineering Team
**Environment**: OpenShift 4.12+ (Production), KIND (CI/CD Testing)
**JWT Authentication**: Supported with Keycloak/RHSSO
**TLS Support**: Self-signed and CA-signed certificates
