# ROS-OCP Helm Chart

Kubernetes Helm chart for deploying the complete ROS-OCP backend stack.

## Quick Start

### Option 1: Install Latest Release (Recommended)
```bash
# Automated installation of the latest release from GitHub
./scripts/install-helm-chart.sh

# Or specify custom namespace and release name
NAMESPACE=my-namespace HELM_RELEASE_NAME=my-release ./scripts/install-helm-chart.sh
```

### Option 2: Manual Installation from Source
```bash
# Local Helm installation from source (development mode)
USE_LOCAL_CHART=true ./scripts/install-helm-chart.sh
```

### Option 3: Direct Helm Installation
```bash
# Download latest release manually and install
LATEST_URL=$(curl -s https://api.github.com/repos/insights-onprem/ros-helm-chart/releases/latest | jq -r '.assets[] | select(.name | endswith(".tgz")) | .browser_download_url')
curl -L -o ros-ocp-latest.tgz "$LATEST_URL"
helm install ros-ocp ros-ocp-latest.tgz -n ros-ocp --create-namespace
```

## Chart Structure

```
ros-helm-chart/
├── ros-ocp/                                 # Helm chart directory
│   ├── Chart.yaml                          # Chart metadata
│   ├── values.yaml                         # Default configuration values
│   └── templates/                          # Kubernetes resource templates (46 files)
│       ├── _helpers.tpl                    # Template helpers
│       ├── deployment-*.yaml               # Application deployments (8 files)
│       ├── statefulset-*.yaml              # Stateful services (6 files)
│       ├── service-*.yaml                  # Service definitions (12 files)
│       ├── configmap-*.yaml                # Configuration management (2 files)
│       ├── secret-*.yaml                   # Credential management (3 files)
│       ├── job-*.yaml                      # Initialization jobs (2 files)
│       ├── cronjob-*.yaml                  # Scheduled tasks (2 files)
│       ├── ingress*.yaml                   # Kubernetes ingress (2 files)
│       ├── routes.yaml                     # OpenShift routes
│       ├── *-serviceaccount.yaml           # Service accounts (2 files)
│       ├── clusterrole*.yaml               # RBAC cluster roles (2 files)
│       └── auth-cluster-roles-*.yaml       # Authentication roles (1 file)
├── scripts/                                # Installation and deployment scripts
│   ├── deploy-kind.sh                      # KIND cluster setup for development
│   ├── install-helm-chart.sh               # Install/upgrade from GitHub releases or local source
│   └── cleanup-kind-artifacts.sh           # Cleanup KIND cluster artifacts
└── .github/workflows/                      # CI/CD automation
    ├── lint-and-validate.yml               # Chart validation
    ├── version-check.yml                   # Semantic version validation
    ├── test-deployment.yml                 # Full deployment testing
    └── release.yml                         # Automated release creation
```

**Template Organization:**
- **Flat structure**: All templates in single directory with descriptive names
- **Naming convention**: `<resource-type>-<component-name>.yaml`
- **Platform support**: Includes both Kubernetes Ingress and OpenShift Routes

**Script Organization:**
- **Unified Installation**: Single script handles both GitHub releases and local development
- **Development Scripts**: KIND cluster setup and artifact cleanup
- **CI/CD Integration**: GitHub Actions workflows for automated testing and releases

## Services Deployed

### Stateful Services
- **PostgreSQL** (3 instances): ROS, Kruize, Sources databases
- **Kafka + Zookeeper**: Message streaming with persistent storage
- **MinIO/ODF**: Object storage (MinIO for Kubernetes, ODF for OpenShift)

### Application Services
- **Ingress**: File upload API and routing gateway
- **ROS-OCP API**: Main REST API for recommendations and status
- **ROS-OCP Processor**: Data processing service for cost optimization
- **ROS-OCP Recommendation Poller**: Kruize integration for recommendations
- **ROS-OCP Housekeeper**: Maintenance tasks and data cleanup
- **Kruize Autotune**: Optimization recommendation engine
- **Sources API**: Source management and integration
- **Redis**: Caching layer for performance optimization

## Configuration

### Default Values
The chart uses production-ready defaults but can be customized:

```yaml
# Custom values example
global:
  storageClass: "fast-ssd"

resources:
  kruize:
    requests:
      memory: "2Gi"
      cpu: "1000m"
    limits:
      memory: "4Gi"
      cpu: "2000m"
```

### Resource Requirements
Minimum recommended resources:
- **Memory**: 8GB+ (12GB+ recommended)
- **CPU**: 4+ cores
- **Storage**: 10GB+ free disk space

### OpenShift Minimum Requirements
For OpenShift deployments, the minimum requirements are:

#### Single Node OpenShift (SNO) Cluster
- **Cluster Type**: Single Node OpenShift (SNO) cluster
- **OpenShift Data Foundation (ODF)**: Must be installed with block devices
- **Storage**: Total of 30GB+ block devices for ODF (development environment)

#### Additional Resource Requirements
**Note**: These are additional resources required beyond SNO's minimum requirements:
- **Additional Memory**: At least 6GB RAM (for ROS-OCP workloads)
- **Additional CPU**: At least 2 cores (for ROS-OCP workloads)
- **Total Node Requirements**: SNO minimum + ROS-OCP requirements

#### Resource Breakdown
Based on the current deployment analysis:
- **CPU Requests**: ~2 cores total across all services
- **Memory Requests**: ~4.5GB total across all services
- **Storage Requirements**:
  - PostgreSQL databases: 3 × 5GB = 15GB
  - Kafka + Zookeeper: 5GB + 3GB = 8GB
  - MinIO: 10GB (Kubernetes) / ODF: Uses existing storage (OpenShift)
  - **Total**: ~33GB (recommended 30GB+ for development)

#### ODF Configuration
- **Storage Class**: `ocs-storagecluster-ceph-rbd` (automatically detected)
- **Volume Mode**: Filesystem (automatically selected for ODF)
- **Access Mode**: ReadWriteOnce (RWO)

## Storage Configuration

### Dual Storage Support
The chart supports two storage backends based on the deployment platform:

#### MinIO (Kubernetes/KinD - Development)
- **Purpose**: Development and testing environments
- **Deployment**: StatefulSet with persistent volumes
- **Console Access**: Available via ingress at `/minio`
- **Credentials**: `minioaccesskey` / `miniosecretkey`
- **API**: S3-compatible endpoint at `ros-ocp-minio:9000`

#### ODF (OpenShift - Production)
- **Purpose**: Production environments with enterprise-grade storage
- **Deployment**: Uses existing ODF installation
- **Console Access**: Managed via OpenShift console
- **Credentials**: User must create secret in deployment namespace
- **API**: S3-compatible endpoint at `s3.openshift-storage.svc.cluster.local:443`

### Automatic Detection
The installation script automatically detects the platform and configures the appropriate storage:
- **Kubernetes**: Deploys MinIO StatefulSet
- **OpenShift**: Uses existing ODF installation


## Access Points

### Kubernetes (KIND) Deployment
All services are accessible through the ingress controller on port **32061**:

- **Ingress Health Check**: http://localhost:32061/ready
- **ROS-OCP API Status**: http://localhost:32061/status
- **ROS-OCP API**: http://localhost:32061/api/ros/*
- **Kruize API**: http://localhost:32061/api/kruize/listPerformanceProfiles
- **Sources API**: http://localhost:32061/api/sources/*
- **File Upload (Ingress)**: http://localhost:32061/api/ingress/*
- **MinIO Console**: http://localhost:32061/minio (minioaccesskey/miniosecretkey) - Kubernetes only

### OpenShift Deployment
Services are accessible through OpenShift Routes:

- **Main Route**: `http://<route-host>/status`
- **Ingress Route**: `http://<ingress-route-host>/api/ingress/*`
- **Kruize Route**: `http://<kruize-route-host>/api/kruize/*`

Use `oc get routes -n <namespace>` to find the actual route hostnames.

### Port Forwarding (Alternative Access)
For direct service access without ingress:

```bash
# ROS-OCP API
kubectl port-forward svc/ros-ocp-rosocp-api 8000:8000 -n ros-ocp

# Kruize API
kubectl port-forward svc/ros-ocp-kruize 8080:8080 -n ros-ocp

# MinIO Console
kubectl port-forward svc/ros-ocp-minio 9001:9001 -n ros-ocp
```

## Installation Options

The deployment system provides multiple installation methods for different use cases:

### 1. GitHub Release Installation (Production Ready)

#### Automated Installation (Recommended)
The easiest way to install the latest stable release:

```bash
# Install latest release with default settings
./scripts/install-helm-chart.sh

# Install with custom namespace and release name
NAMESPACE=my-namespace HELM_RELEASE_NAME=my-release ./scripts/install-helm-chart.sh

# The script automatically:
# - Fetches the latest release from GitHub
# - Downloads the chart package
# - Installs or upgrades the deployment
# - Handles cleanup and platform detection
```

**Features:**
- ✅ Always installs the latest stable release
- ✅ Automatic upgrade detection
- ✅ Platform detection (Kubernetes/OpenShift)
- ✅ No version management required
- ✅ Perfect for CI/CD pipelines
- ✅ Automatic fallback to local chart if GitHub unavailable

#### Manual GitHub Release Installation
For CI/CD systems that prefer direct control:

```bash
# Get latest release URL dynamically
LATEST_URL=$(curl -s https://api.github.com/repos/insights-onprem/ros-helm-chart/releases/latest | jq -r '.assets[] | select(.name | endswith(".tgz")) | .browser_download_url')

# Download and install
curl -L -o ros-ocp-latest.tgz "$LATEST_URL"
helm install ros-ocp ros-ocp-latest.tgz --namespace ros-ocp --create-namespace

# Verify installation
helm status ros-ocp -n ros-ocp
```

### 2. Local Development (KIND-based)
For local development and testing using ephemeral KIND clusters:

```bash
# Setup: Create KIND cluster with ingress
scripts/deploy-kind.sh

# Deploy: Auto-detects platform and deploys chart
scripts/install-helm-chart.sh

# Access: All services available at http://localhost:32061
```

### 3. Local Source Installation
For development, testing, or custom modifications:

```bash
# Clone the repository first
git clone https://github.com/insights-onprem/ros-helm-chart.git
cd ros-helm-chart

# Use local chart source (development mode)
USE_LOCAL_CHART=true ./scripts/install-helm-chart.sh

# With custom values file
USE_LOCAL_CHART=true VALUES_FILE=custom-values.yaml ./scripts/install-helm-chart.sh

# Direct Helm installation (bypasses script automation)
helm install ros-ocp ./ros-ocp \
  --namespace ros-ocp \
  --create-namespace
```

### 4. Automated Testing (GitHub Actions)
Continuous integration with automated deployment testing:

- **Lint & Validate**: Fast Helm chart validation on every PR
- **Full Deployment Test**: Complete E2E testing with KIND cluster
- **Triggers**: Automatically runs on PR/push to main branch

See [GitHub Workflows](#github-workflows) section for details.

### Prerequisites for OpenShift Deployment

Before deploying to OpenShift, ensure the following prerequisites are met:

#### 1. OpenShift Data Foundation (ODF) Installation
- ODF must be installed and operational in the cluster
- S3 service should be available at `s3.openshift-storage.svc.cluster.local:443`
- NooBaa should be running and accessible

#### 2. ODF S3 Credentials Secret
Create the ODF credentials secret in the deployment namespace:

```bash
# Create the secret with your ODF S3 credentials
kubectl create secret generic ros-ocp-odf-credentials \
  --namespace=ros-ocp \
  --from-literal=access-key=<your-odf-access-key> \
  --from-literal=secret-key=<your-odf-secret-key>

# Verify the secret exists
kubectl get secret ros-ocp-odf-credentials -n ros-ocp
```

> **Note**: For development environments (Kubernetes/KIND), the installation script automatically creates this secret with default MinIO credentials.

**Getting ODF Credentials:**

There are several ways to obtain ODF S3 credentials:

#### Method 1: OpenShift Console (Recommended)
1. **Access OpenShift Console**: Log into your OpenShift web console
2. **Navigate to Storage**: Go to **Storage** → **Object Storage** in the left sidebar
3. **Create/Select Bucket**: 
   - If you don't have a bucket, click **Create Bucket** and name it (e.g., `ros-data`)
   - If you have an existing bucket, select it from the list
4. **Generate Credentials**:
   - Click on your bucket name
   - Go to the **Access Keys** tab
   - Click **Create Access Key**
   - **Important**: Copy both the **Access Key** and **Secret Key** immediately
   - The secret key will only be shown once and cannot be retrieved later

#### Method 2: NooBaa CLI
```bash
# Install NooBaa CLI (if not already installed)
curl -LO https://github.com/noobaa/noobaa-operator/releases/download/v5.13.0/noobaa-linux
chmod +x noobaa-linux
sudo mv noobaa-linux /usr/local/bin/noobaa

# Login to NooBaa
noobaa status -n openshift-storage

# Create credentials for a bucket
noobaa account create my-ros-account -n openshift-storage
noobaa bucket create ros-data -n openshift-storage
noobaa account attach my-ros-account --bucket ros-data -n openshift-storage

# Get the credentials
noobaa account show my-ros-account -n openshift-storage
```

#### Method 3: Using Existing Admin Credentials (Not Recommended)
```bash
# Get admin credentials from noobaa-admin secret
kubectl get secret noobaa-admin -n openshift-storage -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d
kubectl get secret noobaa-admin -n openshift-storage -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d

# Note: These are admin credentials with full access - use with caution
```

#### Method 4: External Secret Management (GitOps)
If using external secret management systems like Vault or Sealed Secrets:

```bash
# Example with Vault
vault kv get -field=access_key secret/odf/ros-credentials
vault kv get -field=secret_key secret/odf/ros-credentials

# Example with Sealed Secrets
kubectl create secret generic ros-ocp-odf-credentials \
  --from-literal=access-key=<vault-access-key> \
  --from-literal=secret-key=<vault-secret-key> \
  --dry-run=client -o yaml | kubeseal -o yaml > sealed-secret.yaml
```

**Security Best Practices:**
- Use dedicated service accounts instead of admin credentials
- Rotate credentials regularly
- Store credentials securely (Vault, Sealed Secrets, etc.)
- Use least-privilege access (only grant access to specific buckets)
- Never commit credentials to version control

#### 3. Namespace Permissions
Ensure you have the necessary permissions to:
- Create secrets in the target namespace
- Deploy Helm charts
- Access ODF resources

### Prerequisites for Script-based Installation

The installation scripts require the following tools to be installed:

```bash
# Required tools
curl    # For downloading releases from GitHub
jq      # For parsing JSON responses from GitHub API
helm    # For installing Helm charts
kubectl # For Kubernetes cluster access
```

**Installation on different systems:**

```bash
# Ubuntu/Debian
sudo apt-get update
sudo apt-get install curl jq

# RHEL/CentOS/Fedora
sudo dnf install curl jq

# macOS
brew install curl jq

# Install Helm (all platforms)
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

### Upgrade

#### Using Scripts (Recommended)
```bash
# Upgrade to latest release automatically
./scripts/install-helm-chart.sh

# The script detects existing installations and performs upgrades
# Uses GitHub releases by default, set USE_LOCAL_CHART=true for local source
```

#### Manual Upgrade
```bash
# From GitHub release
LATEST_URL=$(curl -s https://api.github.com/repos/insights-onprem/ros-helm-chart/releases/latest | jq -r '.assets[] | select(.name | endswith(".tgz")) | .browser_download_url')
curl -L -o ros-ocp-latest.tgz "$LATEST_URL"
helm upgrade ros-ocp ros-ocp-latest.tgz -n ros-ocp

# From local source
USE_LOCAL_CHART=true ./scripts/install-helm-chart.sh
# Or direct: helm upgrade ros-ocp ./ros-ocp -n ros-ocp
```

## GitHub Workflows

The repository includes automated workflows for continuous integration and deployment testing:

### 1. Lint and Validate (`lint-and-validate.yml`)
**Purpose**: Fast validation of Helm chart correctness
- **Runtime**: ~10 minutes
- **Triggers**: PRs and pushes to main/master (when `ros-ocp/**` changes)
- **Actions**:
  - `helm lint` - Chart structure and syntax validation
  - `helm template --validate` - Template validation against Kubernetes schemas
  - Dependency checking (if Chart.yaml has dependencies)

### 2. Version Check (`version-check.yml`)
**Purpose**: Validate chart version follows semantic versioning
- **Runtime**: ~5 minutes
- **Triggers**: PRs and pushes to main/master (when `ros-ocp/Chart.yaml` changes)
- **Actions**:
  - Validates current version is valid semantic version
  - Compares with latest GitHub release version
  - Ensures version is semantically higher than previous release
  - Provides suggestions for version bumps (patch/minor/major)
  - Comments on PRs with version fix suggestions

### 3. Test Deployment (`test-deployment.yml`)
**Purpose**: Complete end-to-end deployment testing
- **Runtime**: ~45 minutes
- **Triggers**: PRs and pushes to main/master (when `ros-ocp/**` or `scripts/**` change)
- **Actions**:
  - Creates ephemeral KIND cluster with ingress controller
  - Runs `scripts/deploy-kind.sh` to set up test environment
  - Runs `scripts/install-helm-chart.sh` to deploy chart
  - Performs health checks and connectivity tests
  - Automatic cleanup on success/failure

### 4. Create Release (`release.yml`)
**Purpose**: Automated release creation when version tags are pushed
- **Runtime**: ~10 minutes
- **Triggers**: Push of version tags (e.g., `v0.2.0`, `v1.0.0`)
- **Actions**:
  - Updates Chart.yaml version to match tag
  - Packages Helm chart into .tgz file
  - Creates GitHub release with both versioned and latest artifacts
  - Generates release notes with installation instructions

### Workflow Benefits
- **Early Detection**: Catches issues before merging
- **Automated Testing**: No manual intervention required
- **Comprehensive Coverage**: Tests both chart validity and deployment success
- **Resource Cleanup**: Prevents GitHub Actions quota issues

### Manual Workflow Triggers
Both workflows can be manually triggered via GitHub Actions UI using the "workflow_dispatch" event.

## Platform Differences

The chart automatically adapts to different Kubernetes platforms:

### Kubernetes vs OpenShift

| Feature | Kubernetes | OpenShift |
|---------|------------|-----------|
| **Routing** | Ingress resources | Route resources |
| **Access** | `http://localhost:32061/*` | `http://<route-host>/*` |
| **Storage** | MinIO with default storage class | ODF (OpenShift Data Foundation) |
| **Security** | Standard RBAC | Enhanced security contexts |
| **Detection** | `kubectl get routes` fails | `kubectl get routes` succeeds |

### Automatic Platform Detection
The `install-helm-chart.sh` script automatically detects the platform:

```bash
# Detection method
if kubectl get routes.route.openshift.io >/dev/null 2>&1; then
    PLATFORM="openshift"  # Uses OpenShift Routes
else
    PLATFORM="kubernetes" # Uses Kubernetes Ingress
fi
```

### Platform-Specific Features

**Kubernetes (KIND)**:
- Uses nginx-ingress controller
- All services accessible via single ingress on port 32061
- Path-based routing (`/api/ros`, `/api/kruize`, etc.)

**OpenShift**:
- Uses native OpenShift Routes
- Each service gets its own route with unique hostname
- Automatic SSL termination available

### Universal Deployment Management
**Purpose**: The `install-helm-chart.sh` script provides consistent deployment across platforms.

**Key Features**:
- **Platform Detection**: Automatically detects Kubernetes vs OpenShift
- **Dynamic Configuration**: Adapts chart templates based on platform
- **Storage Intelligence**: Selects optimal storage classes automatically
- **Conflict Resolution**: Handles Kafka cluster ID conflicts
- **Health Validation**: Comprehensive post-deployment verification

## Troubleshooting

### Basic Deployment Issues

**Check deployment status**:
```bash
helm status ros-ocp -n ros-ocp
kubectl get pods -n ros-ocp
```

**View pod logs**:
```bash
kubectl logs -n ros-ocp -l app.kubernetes.io/name=rosocp-processor
```

**Check persistent volumes**:
```bash
kubectl get pvc -n ros-ocp
```

### Script Installation Issues

**Script prerequisites missing**:
```bash
# Check if required tools are installed
which curl jq helm kubectl

# Install missing tools (Ubuntu/Debian example)
sudo apt-get install curl jq

# Verify Helm installation
helm version
```

**GitHub API rate limiting**:
```bash
# If you hit GitHub API rate limits, use authentication
export GITHUB_TOKEN="your_personal_access_token"

# Or wait for rate limit reset (usually 1 hour)
curl -s https://api.github.com/rate_limit
```

**Script execution permissions**:
```bash
# Make script executable if needed
chmod +x scripts/install-helm-chart.sh

# Run with explicit bash if needed
bash scripts/install-helm-chart.sh
```

**Network connectivity issues**:
```bash
# Test GitHub connectivity
curl -s https://api.github.com/repos/insights-onprem/ros-helm-chart/releases/latest

# Test with verbose output for debugging
curl -v https://api.github.com/repos/insights-onprem/ros-helm-chart/releases/latest
```

**Chart download failures**:
```bash
# Manual verification of latest release
curl -s https://api.github.com/repos/insights-onprem/ros-helm-chart/releases/latest | jq '.tag_name'

# Check available assets
curl -s https://api.github.com/repos/insights-onprem/ros-helm-chart/releases/latest | jq '.assets[].name'

# Download manually if script fails
LATEST_URL=$(curl -s https://api.github.com/repos/insights-onprem/ros-helm-chart/releases/latest | jq -r '.assets[] | select(.name | endswith(".tgz")) | .browser_download_url')
curl -L -o ros-ocp-latest.tgz "$LATEST_URL"
```

### Access Issues

**Kubernetes (KIND) - Port 32061 not accessible**:
```bash
# Check KIND cluster port mapping
docker port ros-ocp-cluster-control-plane

# Check ingress controller
kubectl get pods -n ingress-nginx
kubectl logs -n ingress-nginx deployment/ingress-nginx-controller
```

**OpenShift - Routes not accessible**:
```bash
# Check routes
oc get routes -n ros-ocp

# Check route status
oc describe route ros-ocp-main -n ros-ocp
```

### GitHub Workflow Issues

**Lint workflow failing**:
```bash
# Run locally to debug
cd ros-ocp
helm lint .
helm template test-release . --validate
```

**Deployment test workflow failing**:
```bash
# Check KIND cluster locally
scripts/deploy-kind.sh
kubectl get pods -A

# Check deployment
scripts/install-helm-chart.sh
```

### Common Issues

**Kafka cluster ID conflicts**:
```bash
# Clean up conflicting data
scripts/install-helm-chart.sh cleanup --kafka-conflicts
```

**Insufficient resources**:
```bash
# Check node resources
kubectl describe nodes
kubectl top nodes  # if metrics-server available
```

## Deployment Script Features

### Universal Installation (`install-helm-chart.sh`)
- **Automatic Platform Detection**: Kubernetes vs OpenShift detection
- **Dynamic Template Selection**: Adapts Ingress vs Routes based on platform
- **Intelligent Storage**: Auto-selects MinIO (Kubernetes) or ODF (OpenShift) per platform
- **Kafka Conflict Resolution**: Prevents cluster ID mismatches automatically
- **Comprehensive Health Checks**: Internal and external connectivity validation
- **Flexible Cleanup**: Standard cleanup (preserves data) or complete cleanup (removes all)

### KIND Cluster Setup (`deploy-kind.sh`)
- **Container Runtime Support**: Docker and Podman compatibility
- **Ingress Controller**: Automatic nginx-ingress installation
- **Port Mapping**: Configures port 32061 for external access
- **Resource Management**: 6GB memory limit for deterministic deployment
- **Authentication Setup**: Creates service accounts and tokens for testing

## Chart Features

- **Comprehensive ConfigMaps**: Environment variable management across all services
- **Health Checks**: Proper readiness and liveness probes for all services
- **Persistent Storage**: Configured for all stateful services with platform-specific defaults
- **Resource Management**: Appropriate limits and requests to prevent resource exhaustion
- **Platform Optimization**: OpenShift Routes vs Kubernetes Ingress automatically selected
- **RBAC Integration**: Service accounts and cluster roles for secure operation
- **Automated Jobs**: Kafka topic creation and storage bucket initialization (MinIO/ODF)
- **Flexible Configuration**: Extensive values.yaml for customization