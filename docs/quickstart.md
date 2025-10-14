# ROS-OCP Kubernetes Quick Start Guide

This guide walks you through deploying and testing the ROS-OCP backend services on both Kubernetes and OpenShift clusters using the Helm chart from the [ros-helm-chart repository](https://github.com/insights-onprem/ros-helm-chart).

## Helm Chart Location

The ROS-OCP Helm chart is maintained in a separate repository: **[insights-onprem/ros-helm-chart](https://github.com/insights-onprem/ros-helm-chart)**

### Deployment Methods

The deployment scripts provide flexible options for both Kubernetes and OpenShift:

1. **KIND Cluster Setup** (Development): The `deploy-kind.sh` script creates and configures a KIND cluster with ingress controller
2. **Helm Chart Deployment**: The `install-helm-chart.sh` script deploys the ROS-OCP services with automatic platform detection
3. **Development Mode**: Use `USE_LOCAL_CHART=true` to install from a local chart directory

### Chart Features

- **46 Kubernetes templates** for complete ROS-OCP stack deployment
- **Platform detection** (Kubernetes vs OpenShift) with appropriate resource selection
- **Automated CI/CD** with lint validation, version checking, and deployment testing
- **Comprehensive documentation** and troubleshooting guides

## Prerequisites

### System Resources
Ensure your system has adequate resources for the deployment:
- **Memory**: At least 8GB RAM (12GB+ recommended)
- **CPU**: 4+ cores
- **Storage**: 10GB+ free disk space

The deployment includes:
- 3 PostgreSQL databases (256Mi each)
- Kafka + Zookeeper (512Mi + 256Mi)
- Kruize optimization engine (1-2Gi - most memory intensive)
- Various application services (256-512Mi each)

### Required Tools
Install these tools on your system:

**For Kubernetes/KIND Development:**
```bash
# macOS
brew install kind kubectl helm podman

# Linux (Ubuntu/Debian)
# Install KIND
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
chmod +x ./kind && sudo mv ./kind /usr/local/bin/kind

# Install kubectl, helm, podman via package manager
sudo apt-get update
sudo apt-get install -y kubectl helm podman
```

**For OpenShift:**
```bash
# Install OpenShift CLI
# Download from: https://mirror.openshift.com/pub/openshift-v4/clients/ocp/
# Or use package manager
brew install openshift-cli  # macOS
```

### Verify Installation
```bash
# For Kubernetes/KIND
kind --version
kubectl version --client
helm version
podman --version

# For OpenShift
oc version
kubectl version --client
helm version
```

## Quick Deployment

### Option 1: Kubernetes/KIND Development

#### 1. Navigate to Scripts Directory
```bash
cd /path/to/ros-helm-chart/scripts/
```

#### 2. Setup KIND Cluster
```bash
# Create KIND cluster with ingress controller
./deploy-kind.sh
```

The script will:
- ✅ Check prerequisites (kubectl, kind, container runtime)
- ✅ Create KIND cluster with proper networking
- ✅ Install NGINX ingress controller
- ✅ Configure port mapping (32061 for HTTP access)

#### 3. Deploy ROS-OCP Services
```bash
# Deploy using latest GitHub release (recommended)
./install-helm-chart.sh
```

### Option 2: OpenShift Production

#### 1. Navigate to Scripts Directory
```bash
cd /path/to/ros-helm-chart/scripts/
```

#### 2. Deploy ROS-OCP Services
```bash
# Deploy directly to OpenShift (script auto-detects platform)
./install-helm-chart.sh
```

The script will:
- ✅ Download latest Helm chart release from GitHub
- ✅ Deploy all services with platform detection
- ✅ Run comprehensive health checks
- ✅ Verify connectivity and authentication

**Expected Output:**
```
[INFO] Running health checks...
[SUCCESS] ✓ Ingress API is accessible via http://localhost:32061/ready
[SUCCESS] ✓ ROS-OCP API is accessible via http://localhost:32061/status
[SUCCESS] ✓ Kruize API is accessible via http://localhost:32061/api/kruize/listPerformanceProfiles
[SUCCESS] All core services are healthy and operational!
```

#### 4. Verify Deployment
```bash
# Check deployment status
./install-helm-chart.sh status

# Run health checks
./install-helm-chart.sh health
```

### Alternative: Manual Helm Chart Installation

If you prefer to manually install the Helm chart or need a specific version:

#### 1. Create KIND Cluster
```bash
# Create KIND cluster with ingress support
./deploy-kind.sh
```

#### 2. Install Latest Chart Release
```bash
# Download and install latest chart release
LATEST_URL=$(curl -s https://api.github.com/repos/insights-onprem/ros-helm-chart/releases/latest | jq -r '.assets[] | select(.name | endswith(".tgz")) | .browser_download_url')
curl -L -o ros-ocp-latest.tgz "$LATEST_URL"
helm install ros-ocp ros-ocp-latest.tgz -n ros-ocp --create-namespace
```

#### 3. Install Specific Chart Version
```bash
# Install a specific version (e.g., v0.1.0)
VERSION="v0.1.0"
curl -L -o ros-ocp-${VERSION}.tgz "https://github.com/insights-onprem/ros-helm-chart/releases/download/${VERSION}/ros-ocp-${VERSION}.tgz"
helm install ros-ocp ros-ocp-${VERSION}.tgz -n ros-ocp --create-namespace
```

#### 4. Development Mode (Local Chart)
```bash
# Use local chart source for development
USE_LOCAL_CHART=true LOCAL_CHART_PATH=../ros-ocp ./install-helm-chart.sh

# Or direct Helm installation
helm install ros-ocp ./ros-ocp -n ros-ocp --create-namespace
```

## Access Points

After successful deployment, these services are available via the ingress controller on **port 32061**:

| Service | URL | Description |
|---------|-----|-------------|
| **Ingress Health** | http://localhost:32061/ready | Health check endpoint |
| **ROS-OCP API** | http://localhost:32061/status | Main REST API status |
| **ROS-OCP API** | http://localhost:32061/api/ros/* | Recommendations API |
| **Kruize API** | http://localhost:32061/api/kruize/* | Optimization engine |
| **Sources API** | http://localhost:32061/api/sources/* | Source management |
| **File Upload** | http://localhost:32061/api/ingress/* | Data upload endpoint |
| **MinIO Console** | http://localhost:32061/minio | Storage admin UI (minioaccesskey/miniosecretkey) |

### Quick Access Test
```bash
# Test Ingress health
curl http://localhost:32061/ready

# Test ROS-OCP API
curl http://localhost:32061/status

# Test Kruize API
curl http://localhost:32061/api/kruize/listPerformanceProfiles
```

## End-to-End Data Flow Testing

### 1. Run Complete Test
```bash
# This tests the full data pipeline
# Note: Run from ros-ocp-backend repository
git clone https://github.com/gciavarrini/ros-ocp-backend.git
cd ros-ocp-backend/deployment/kubernetes/scripts/
./test-k8s-dataflow.sh
```

The test will:
- ✅ Upload test CSV data via Ingress API
- ✅ Simulate Koku service processing
- ✅ Copy data to MinIO ros-data bucket
- ✅ Publish Kafka event for processor
- ✅ Verify data processing and database storage
- ✅ Check Kruize experiment creation

**Expected Output:**
```
[INFO] ROS-OCP Kubernetes Data Flow Test
==================================
[SUCCESS] Step 1: Upload completed successfully
[SUCCESS] Steps 2-3: Koku simulation and Kafka event completed successfully
[SUCCESS] Found 1 workload records in database
[SUCCESS] All health checks passed!
[SUCCESS] Data flow test completed!
```

### 2. View Service Logs
```bash
# List available services
# Note: Run from ros-ocp-backend repository
git clone https://github.com/gciavarrini/ros-ocp-backend.git
cd ros-ocp-backend/deployment/kubernetes/scripts/

# For Kubernetes/KIND deployments
./test-k8s-dataflow.sh logs

# For OpenShift deployments
./test-ocp-dataflow.sh logs

# View specific service logs
./test-k8s-dataflow.sh logs rosocp-processor    # Kubernetes
./test-ocp-dataflow.sh logs rosocp-processor    # OpenShift
```

### 3. Monitor Processing
```bash
# Watch pods in real-time
kubectl get pods -n ros-ocp -w

# Check persistent volumes
kubectl get pvc -n ros-ocp

# View all services
kubectl get svc -n ros-ocp
```

## Manual Testing

### Upload Test File
```bash
# Create test CSV file
cat > test-data.csv << 'EOF'
report_period_start,report_period_end,interval_start,interval_end,container_name,pod,owner_name,owner_kind,workload,workload_type,namespace,image_name,node,resource_id,cpu_request_container_avg,cpu_request_container_sum,cpu_limit_container_avg,cpu_limit_container_sum,cpu_usage_container_avg,cpu_usage_container_min,cpu_usage_container_max,cpu_usage_container_sum,cpu_throttle_container_avg,cpu_throttle_container_max,cpu_throttle_container_sum,memory_request_container_avg,memory_request_container_sum,memory_limit_container_avg,memory_limit_container_sum,memory_usage_container_avg,memory_usage_container_min,memory_usage_container_max,memory_usage_container_sum,memory_rss_usage_container_avg,memory_rss_usage_container_min,memory_rss_usage_container_max,memory_rss_usage_container_sum
2024-01-01,2024-01-01,2024-01-01 00:00:00 -0000 UTC,2024-01-01 00:15:00 -0000 UTC,test-container,test-pod-123,test-deployment,Deployment,test-workload,deployment,test-namespace,quay.io/test/image:latest,worker-node-1,resource-123,100,100,200,200,50,10,90,50,0,0,0,512,512,1024,1024,256,128,384,256,200,100,300,200
EOF

# Important: For Kruize compatibility, ensure:
# - report_period_start and report_period_end should match for short intervals
# - Use timezone format '-0000 UTC' instead of 'Z' for Go time parsing compatibility
# - Keep interval duration under 30 minutes for optimal Kruize validation

# Upload via Ingress API
curl -X POST \
  -F "file=@test-data.csv" \
  -H "x-rh-identity: eyJpZGVudGl0eSI6eyJhY2NvdW50X251bWJlciI6IjEyMzQ1IiwidHlwZSI6IlVzZXIiLCJpbnRlcm5hbCI6eyJvcmdfaWQiOiIxMjM0NSJ9fX0K" \
  -H "x-rh-request-id: manual-test-$(date +%s)" \
  http://localhost:32061/api/ingress/v1/upload
```

### Check Database
```bash
# Connect to ROS database
kubectl exec -it -n ros-ocp deployment/ros-ocp-db-ros -- \
  psql -U postgres -d postgres -c "SELECT COUNT(*) FROM workloads;"
```

### Monitor Kafka Topics
```bash
# List topics
kubectl exec -n ros-ocp deployment/ros-ocp-kafka -- \
  kafka-topics --list --bootstrap-server localhost:29092

# Monitor events
kubectl exec -n ros-ocp deployment/ros-ocp-kafka -- \
  kafka-console-consumer --bootstrap-server localhost:29092 \
  --topic hccm.ros.events --from-beginning
```

## Configuration

### Environment Variables
```bash
# Customize deployment
export KIND_CLUSTER_NAME=my-ros-cluster
export HELM_RELEASE_NAME=my-ros-ocp
export NAMESPACE=my-namespace

# Deploy with custom settings
./deploy-kind.sh
```

### Helm Values Override
```bash
# Create custom values file
cat > my-values.yaml << EOF
global:
  storageClass: "fast-ssd"

database:
  ros:
    storage:
      size: 20Gi

resources:
  application:
    requests:
      memory: "256Mi"
      cpu: "200m"
EOF

# Deploy with custom values (using latest release from ros-helm-chart repository)
LATEST_URL=$(curl -s https://api.github.com/repos/insights-onprem/ros-helm-chart/releases/latest | jq -r '.assets[] | select(.name | endswith(".tgz")) | .browser_download_url')
curl -L -o ros-ocp-latest.tgz "$LATEST_URL"
helm upgrade --install ros-ocp ros-ocp-latest.tgz \
  --namespace ros-ocp \
  --create-namespace \
  -f my-values.yaml
```

## Cleanup

### Remove Deployment Only
```bash
# Remove Helm release and namespace
./install-helm-chart.sh cleanup
```

### Remove Everything
```bash
# Delete entire KIND cluster
./deploy-kind.sh cleanup --all
```

### Manual Cleanup
```bash
# Delete Helm release
helm uninstall ros-ocp -n ros-ocp

# Delete namespace
kubectl delete namespace ros-ocp

# Delete KIND cluster
kind delete cluster --name ros-ocp-cluster
```

## Quick Status Check

Use this script to verify all services are working:

```bash
#!/bin/bash
echo "=== ROS-OCP Status Check ==="

# Check pod status
echo "Pod Status:"
kubectl get pods -n ros-ocp

# Check services with issues
echo -e "\nPods with issues:"
kubectl get pods -n ros-ocp --field-selector=status.phase!=Running

# Check Kafka connectivity
echo -e "\nKafka connectivity test:"
kubectl exec -n ros-ocp deployment/ros-ocp-rosocp-processor -- nc -zv ros-ocp-kafka 29092 2>/dev/null && echo "✓ Kafka accessible" || echo "✗ Kafka connection failed"

# Check API endpoints
echo -e "\nAPI Health Checks:"
curl -s http://localhost:32061/ready >/dev/null && echo "✓ Ingress API" || echo "✗ Ingress API failed"
curl -s http://localhost:32061/status >/dev/null && echo "✓ ROS-OCP API" || echo "✗ ROS-OCP API failed"
curl -s http://localhost:32061/api/kruize/listPerformanceProfiles >/dev/null && echo "✓ Kruize API" || echo "✗ Kruize API failed"

echo -e "\nFor detailed troubleshooting, run: ./test-k8s-dataflow.sh health"
```

## Next Steps

After successful deployment:

1. **Explore APIs**: Use the access points to interact with services
2. **Load Test Data**: Upload your own cost management files
3. **Monitor Metrics**: Check Kruize recommendations and optimizations
4. **Scale Services**: Modify Helm values to scale deployments
5. **Production Setup**: Adapt for real Kubernetes clusters

## Support

For issues or questions:
- Check [Troubleshooting Guide](troubleshooting.md)
- Review test output: Clone [ros-ocp-backend](https://github.com/gciavarrini/ros-ocp-backend) and run:
  - Kubernetes: `./deployment/kubernetes/scripts/test-k8s-dataflow.sh`
  - OpenShift: `./deployment/kubernetes/scripts/test-ocp-dataflow.sh`
- Check pod logs: `kubectl logs -n ros-ocp <pod-name>`
- Verify configuration: `helm get values ros-ocp -n ros-ocp`
