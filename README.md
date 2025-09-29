# ROS-OCP Helm Chart

Kubernetes Helm chart for deploying the complete ROS-OCP backend stack.

## Quick Start

```bash
# Or manual Helm installation
helm install ros-ocp ./ros-ocp -n ros-ocp --create-namespace
```

## Chart Structure

```
ros-ocp/
├── Chart.yaml           # Chart metadata
├── values.yaml          # Default configuration values
└── templates/           # Kubernetes resource templates (46 files)
    ├── _helpers.tpl                           # Template helpers
    ├── deployment-*.yaml                     # Application deployments (8 files)
    ├── statefulset-*.yaml                    # Stateful services (6 files)
    ├── service-*.yaml                        # Service definitions (12 files)
    ├── configmap-*.yaml                      # Configuration management (2 files)
    ├── secret-*.yaml                         # Credential management (3 files)
    ├── job-*.yaml                            # Initialization jobs (2 files)
    ├── cronjob-*.yaml                        # Scheduled tasks (2 files)
    ├── ingress*.yaml                         # Kubernetes ingress (2 files)
    ├── routes.yaml                           # OpenShift routes
    ├── *-serviceaccount.yaml                 # Service accounts (2 files)
    ├── clusterrole*.yaml                     # RBAC cluster roles (2 files)
    └── auth-cluster-roles-*.yaml             # Authentication roles (1 file)
```

**Template Organization:**
- **Flat structure**: All templates in single directory with descriptive names
- **Naming convention**: `<resource-type>-<component-name>.yaml`
- **Platform support**: Includes both Kubernetes Ingress and OpenShift Routes

## Services Deployed

### Stateful Services
- **PostgreSQL** (3 instances): ROS, Kruize, Sources databases
- **Kafka + Zookeeper**: Message streaming with persistent storage
- **MinIO**: Object storage with persistent volumes

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
  - MinIO: 10GB
  - **Total**: ~33GB (recommended 30GB+ for development)

#### ODF Configuration
- **Storage Class**: `ocs-storagecluster-ceph-rbd` (automatically detected)
- **Volume Mode**: Filesystem (automatically selected for ODF)
- **Access Mode**: ReadWriteOnce (RWO)

## Access Points

### Kubernetes (KIND) Deployment
All services are accessible through the ingress controller on port **32061**:

- **Ingress Health Check**: http://localhost:32061/ready
- **ROS-OCP API Status**: http://localhost:32061/status
- **ROS-OCP API**: http://localhost:32061/api/ros/*
- **Kruize API**: http://localhost:32061/api/kruize/listPerformanceProfiles
- **Sources API**: http://localhost:32061/api/sources/*
- **File Upload (Ingress)**: http://localhost:32061/api/ingress/*
- **MinIO Console**: http://localhost:32061/minio (minioaccesskey/miniosecretkey)

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

The deployment system provides distinct workflows for different use cases:

### 1. Automated Testing (GitHub Actions)
Continuous integration with automated deployment testing:

- **Lint & Validate**: Fast Helm chart validation on every PR
- **Full Deployment Test**: Complete E2E testing with KIND cluster
- **Triggers**: Automatically runs on PR/push to main branch

See [GitHub Workflows](#github-workflows) section for details.

### 2. Local Development (KIND-based)
For local development and testing using ephemeral KIND clusters:

```bash
# Setup: Create KIND cluster with ingress
scripts/deploy-kind.sh

# Deploy: Auto-detects platform and deploys chart
scripts/install-helm-chart.sh

# Access: All services available at http://localhost:32061
```

### 3. Manual Helm Installation
For advanced use cases or custom configurations:

```bash
# Kubernetes with default values
helm install ros-ocp ./ros-ocp \
  --namespace ros-ocp \
  --create-namespace

# Kubernetes with custom values
helm install ros-ocp ./ros-ocp \
  --namespace ros-ocp \
  --create-namespace \
  --values custom-values.yaml

# OpenShift (auto-detected by chart)
helm install ros-ocp ./ros-ocp \
  --namespace ros-ocp \
  --create-namespace
```

### Upgrade
```bash
helm upgrade ros-ocp ./ros-ocp -n ros-ocp
```

## GitHub Workflows

The repository includes automated workflows for continuous integration and deployment testing:

### 1. Lint and Validate (`lint-and-validate.yml`)
**Purpose**: Fast validation of Helm chart correctness
- **Runtime**: ~10 minutes
- **Triggers**: PRs and pushes to main/master (when `ros-ocp/**` changes)
- **Actions**:
  - `helm lint` - Chart structure and syntax validation
  - `helm template --validate --strict` - Template validation against Kubernetes schemas
  - Dependency checking (if Chart.yaml has dependencies)

### 2. Test Deployment (`test-deployment.yml`)
**Purpose**: Complete end-to-end deployment testing
- **Runtime**: ~45 minutes
- **Triggers**: PRs and pushes to main/master (when `ros-ocp/**` or `scripts/**` change)
- **Actions**:
  - Creates ephemeral KIND cluster with ingress controller
  - Runs `scripts/deploy-kind.sh` to set up test environment
  - Runs `scripts/install-helm-chart.sh` to deploy chart
  - Performs health checks and connectivity tests
  - Automatic cleanup on success/failure

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
| **Storage** | Default storage class | `ocs-storagecluster-ceph-rbd` (ODF) |
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
helm template test-release . --validate --strict
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
- **Intelligent Storage**: Auto-selects optimal storage classes per platform
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
- **Automated Jobs**: Kafka topic creation and MinIO bucket initialization
- **Flexible Configuration**: Extensive values.yaml for customization