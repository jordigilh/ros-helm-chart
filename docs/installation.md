# Cost Management On-Premise Installation Guide

Complete installation methods, prerequisites, and upgrade procedures for the Cost Management On-Premise Helm chart.

## Table of Contents
- [Prerequisites](#prerequisites)
- [Installation Methods](#installation-methods)
- [OpenShift Prerequisites](#openshift-prerequisites)
- [Upgrade Procedures](#upgrade-procedures)
- [Verification](#verification)

## Prerequisites

### Required Tools

The installation scripts require the following tools:

```bash
# Required
curl    # For downloading releases from GitHub
jq      # For parsing JSON responses
helm    # For installing Helm charts (v3+)
kubectl # For Kubernetes cluster access
```

### Installation by Platform

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

### Cluster Access

Ensure you have:
- Valid kubeconfig with cluster admin or appropriate namespace permissions
- Ability to create namespaces (or existing target namespace)
- Sufficient cluster resources (see [Configuration Guide](configuration.md))

---

## Installation Methods

### Method 1: Automated Installation (Recommended)

The easiest way to install using the automation script:

```bash
# Install latest release with default settings
./scripts/install-helm-chart.sh

# Custom namespace
export NAMESPACE=ros-production
./scripts/install-helm-chart.sh

# Custom release name
export HELM_RELEASE_NAME=ros-prod
./scripts/install-helm-chart.sh

# Use local chart for development
export USE_LOCAL_CHART=true
./scripts/install-helm-chart.sh
```

**Features:**
- ✅ Always installs latest stable release
- ✅ Automatic upgrade detection
- ✅ Platform detection (Kubernetes/OpenShift)
- ✅ No version management required
- ✅ Perfect for CI/CD pipelines
- ✅ Automatic fallback to local chart if GitHub unavailable

**Environment Variables:**
- `HELM_RELEASE_NAME`: Helm release name (default: `cost-onprem`)
- `NAMESPACE`: Target namespace (default: `cost-onprem`)
- `VALUES_FILE`: Path to custom values file
- `USE_LOCAL_CHART`: Use local chart instead of GitHub release (default: `false`)
- `LOCAL_CHART_PATH`: Path to local chart directory (default: `../cost-onprem`)

**Note**: JWT authentication is automatically enabled on OpenShift and disabled on KIND/K8s via platform detection.

---

### Method 2: GitHub Release Installation

For CI/CD systems that prefer direct control:

```bash
# Get latest release URL dynamically
LATEST_URL=$(curl -s https://api.github.com/repos/insights-onprem/ros-helm-chart/releases/latest | \
  jq -r '.assets[] | select(.name | endswith(".tgz")) | .browser_download_url')

# Download and install
curl -L -o cost-onprem-latest.tgz "$LATEST_URL"
helm install cost-onprem cost-onprem-latest.tgz \
  --namespace cost-onprem \
  --create-namespace

# Verify installation
helm status cost-onprem -n cost-onprem
```

**With custom values:**
```bash
helm install cost-onprem cost-onprem-latest.tgz \
  --namespace cost-onprem \
  --create-namespace \
  --values my-values.yaml
```

---

### Method 3: Helm Repository (Future)

```bash
# Add Helm repository (once published)
helm repo add cost-onprem https://insights-onprem.github.io/ros-helm-chart
helm repo update

# Install from repository
helm install cost-onprem cost-onprem/cost-onprem \
  --namespace cost-onprem \
  --create-namespace
```

---

### Method 4: Local Source Installation

For development, testing, or custom modifications:

```bash
# Clone the repository
git clone https://github.com/insights-onprem/ros-helm-chart.git
cd ros-helm-chart

# Method A: Using installation script
export USE_LOCAL_CHART=true
./scripts/install-helm-chart.sh

# Method B: Direct Helm installation
helm install cost-onprem ./cost-onprem \
  --namespace cost-onprem \
  --create-namespace

# With custom values
helm install cost-onprem ./cost-onprem \
  --namespace cost-onprem \
  --create-namespace \
  --values custom-values.yaml
```

---

### Method 5: KIND Development Environment

Complete local development setup:

```bash
# Step 1: Create KIND cluster with ingress
./scripts/deploy-kind.sh

# Step 2: Deploy Cost Management On-Premise services
./scripts/install-helm-chart.sh

# Access: All services at http://localhost:32061
```

**KIND features:**
- Container runtime support (Docker/Podman)
- Automated ingress controller setup
- Fixed resource allocation (6GB)
- Perfect for CI/CD testing

**See [Scripts Reference](../scripts/README.md) for KIND details**

---

## OpenShift Prerequisites

### 1. OpenShift Data Foundation (ODF)

ODF must be installed and operational:

```bash
# Verify ODF installation
oc get noobaa -n openshift-storage
oc get storagecluster -n openshift-storage

# Check S3 service availability
oc get route s3 -n openshift-storage
```

**ODF endpoints:**
- Internal: `s3.openshift-storage.svc.cluster.local:443`
- External: Check routes in `openshift-storage` namespace

### 2. ODF S3 Credentials Secret

Create credentials secret in deployment namespace:

```bash
# Create secret with ODF S3 credentials
kubectl create secret generic cost-onprem-odf-credentials \
  --namespace=cost-onprem \
  --from-literal=access-key=<your-access-key> \
  --from-literal=secret-key=<your-secret-key>

# Verify secret
kubectl get secret cost-onprem-odf-credentials -n cost-onprem
```

### Getting ODF Credentials

#### Method 1: OpenShift Console (Recommended)

1. Navigate to **Storage** → **Object Storage**
2. Create or select bucket (e.g., `ros-data`)
3. Go to **Access Keys** tab
4. Click **Create Access Key**
5. **Important**: Copy both keys immediately (secret key shown only once)

#### Method 2: NooBaa CLI

```bash
# Install NooBaa CLI
curl -LO https://github.com/noobaa/noobaa-operator/releases/download/v5.13.0/noobaa-linux
chmod +x noobaa-linux
sudo mv noobaa-linux /usr/local/bin/noobaa

# Create account and bucket
noobaa account create ros-account -n openshift-storage
noobaa bucket create ros-data -n openshift-storage
noobaa account attach ros-account --bucket ros-data -n openshift-storage

# Get credentials
noobaa account show ros-account -n openshift-storage
```

#### Method 3: Using Admin Credentials (Not Recommended)

```bash
# Get admin credentials from noobaa-admin secret
kubectl get secret noobaa-admin -n openshift-storage \
  -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d

kubectl get secret noobaa-admin -n openshift-storage \
  -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d

# ⚠️ Warning: These are admin credentials with full access
```

#### Method 4: External Secret Management

```bash
# Example with Vault
vault kv get -field=access_key secret/odf/ros-credentials
vault kv get -field=secret_key secret/odf/ros-credentials

# Example with Sealed Secrets
kubectl create secret generic cost-onprem-odf-credentials \
  --from-literal=access-key=<key> \
  --from-literal=secret-key=<secret> \
  --dry-run=client -o yaml | \
  kubeseal -o yaml > sealed-secret.yaml
```

**Security Best Practices:**
- ✅ Use dedicated service accounts (not admin credentials)
- ✅ Rotate credentials regularly
- ✅ Store in external secret management (Vault, Sealed Secrets)
- ✅ Use least-privilege access (specific buckets only)
- ❌ Never commit credentials to version control

### 3. Namespace Permissions

Ensure you have permissions to:
- Create secrets in target namespace
- Deploy Helm charts
- Access ODF resources
- Create routes (OpenShift)

```bash
# Verify permissions
oc auth can-i create secrets -n cost-onprem
oc auth can-i create deployments -n cost-onprem
oc auth can-i create routes -n cost-onprem
```

### 4. Authorino Setup for OAuth2 Authentication

**✅ Authorino is now automatically deployed by the Helm chart!**

As of Cost Management On-Premise Helm Chart v2.0, Authorino is deployed as a standalone pod directly by the Helm chart during the standard installation. No separate installation steps are required.

**What gets deployed automatically:**
- Authorino Deployment (no operator dependency)
- ServiceAccount and RBAC (ClusterRole/RoleBinding for TokenReview)
- Services (authorization, metrics, oidc)
- TLS certificates via OpenShift service-ca
- AuthConfig resources for OAuth2 TokenReview

**Security Features:**
- **TLS Encryption**: All communication between Envoy and Authorino is encrypted using TLS
- **Certificate Management**: Certificates are automatically generated and rotated by OpenShift's service-ca operator
- **NetworkPolicy**: Access to Authorino is restricted to authorized pods only
- **Namespace-Scoped**: Authorino operates within the deployment namespace to limit blast radius

**Verification:**

After Helm installation, verify Authorino deployment:

```bash
# Check Authorino pod
oc get pods -n cost-onprem -l app.kubernetes.io/component=authorino

# Check Authorino services
oc get svc -n cost-onprem -l app.kubernetes.io/component=authorino

# Check AuthConfig
oc get authconfig -n cost-onprem

# Check TLS certificate
oc get secret -n cost-onprem | grep authorino-server-cert
```

**What Authorino Does:**

Authorino provides OAuth2 TokenReview authentication for the backend API, enabling OpenShift Console UI users to access Cost Management On-Premise with their session tokens.

**Authentication Flow:**
1. User accesses Cost Management On-Premise via OpenShift Console UI
2. Console includes user's session token in request
3. Envoy proxy forwards request to Authorino for validation
4. Authorino validates token via Kubernetes TokenReview API
5. If valid, Authorino injects headers (username, UID)
6. Envoy transforms headers into rh-identity format
7. Backend receives authenticated request

**For more details, see [OAuth2 TokenReview Authentication Guide](oauth2-tokenreview-authentication.md)**

### 5. Resource Requirements

**Single Node OpenShift (SNO):**
- SNO cluster with ODF installed
- 30GB+ block devices for ODF
- Additional 6GB RAM for Cost Management On-Premise workloads
- Additional 2 CPU cores
- Authorino resources (minimal: ~100Mi RAM, 0.1 CPU)

**See [Configuration Guide](configuration.md) for detailed requirements**

---

## Upgrade Procedures

### Upgrade Using Scripts (Recommended)

```bash
# Upgrade to latest release automatically
./scripts/install-helm-chart.sh

# The script detects existing installations and performs upgrades
# Uses GitHub releases by default
```

### Manual Helm Upgrade

#### From GitHub Release

```bash
# Get latest release
LATEST_URL=$(curl -s https://api.github.com/repos/insights-onprem/ros-helm-chart/releases/latest | \
  jq -r '.assets[] | select(.name | endswith(".tgz")) | .browser_download_url')

# Download and upgrade
curl -L -o cost-onprem-latest.tgz "$LATEST_URL"
helm upgrade cost-onprem cost-onprem-latest.tgz -n cost-onprem

# With custom values
helm upgrade cost-onprem cost-onprem-latest.tgz -n cost-onprem --values my-values.yaml
```

#### From Local Source

```bash
# Using script
export USE_LOCAL_CHART=true
./scripts/install-helm-chart.sh

# Direct Helm command
helm upgrade cost-onprem ./cost-onprem -n cost-onprem
```

### Upgrade Considerations

**Before upgrading:**
1. Check release notes for breaking changes
2. Backup persistent data if needed
3. Verify cluster resources are sufficient
4. Test in non-production environment first

**During upgrade:**
- Helm performs rolling updates by default
- Some downtime may occur during database upgrades
- Monitor pod status: `kubectl get pods -n cost-onprem -w`

**After upgrade:**
```bash
# Verify upgrade
./scripts/install-helm-chart.sh status

# Run health checks
./scripts/install-helm-chart.sh health

# Check version
helm list -n cost-onprem
```

---

## Verification

### Deployment Status

```bash
# Check Helm release
helm status cost-onprem -n cost-onprem

# Check all pods
kubectl get pods -n cost-onprem

# Wait for all pods to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=cost-onprem -n cost-onprem --timeout=300s
```

### Service Health

```bash
# Run automated health checks
./scripts/install-helm-chart.sh health

# Test ingress endpoint
curl http://localhost:32061/ready  # KIND
curl http://<route-host>/ready      # OpenShift

# Check API endpoints
curl http://localhost:32061/api/ros/status
```

### Storage Verification

```bash
# Check persistent volume claims
kubectl get pvc -n cost-onprem

# Verify all PVCs are bound
kubectl get pvc -n cost-onprem | grep -v Bound && echo "ISSUE: Unbound PVCs found" || echo "OK: All PVCs bound"

# Check storage class
kubectl get pvc -n cost-onprem -o jsonpath='{.items[*].spec.storageClassName}' | tr ' ' '\n' | sort -u
```

### Service Connectivity

```bash
# Test database connections
kubectl exec -it deployment/cost-onprem-ros-api -n cost-onprem -- \
  env | grep DATABASE_URL

# Test Kafka connectivity
kubectl exec -it statefulset/cost-onprem-kafka -n cost-onprem -- \
  kafka-topics.sh --list --bootstrap-server localhost:29092

# Test MinIO/ODF access (Kubernetes)
kubectl exec -it statefulset/cost-onprem-minio -n cost-onprem -- \
  mc admin info local
```

---

## Troubleshooting Installation

### Script Execution Issues

**Missing prerequisites:**
```bash
# Check required tools
which curl jq helm kubectl

# Install missing tools
sudo apt-get install curl jq  # Ubuntu/Debian
brew install curl jq           # macOS
```

**GitHub API rate limiting:**
```bash
# Check rate limit
curl -s https://api.github.com/rate_limit

# Use authentication token
export GITHUB_TOKEN="your_personal_access_token"
./scripts/install-helm-chart.sh
```

**Script permissions:**
```bash
# Make executable
chmod +x scripts/install-helm-chart.sh

# Run with explicit bash
bash scripts/install-helm-chart.sh
```

### Network Issues

```bash
# Test GitHub connectivity
curl -s https://api.github.com/repos/insights-onprem/ros-helm-chart/releases/latest

# Verbose debugging
curl -v https://api.github.com/repos/insights-onprem/ros-helm-chart/releases/latest

# Manual download
LATEST_URL=$(curl -s https://api.github.com/repos/insights-onprem/ros-helm-chart/releases/latest | \
  jq -r '.assets[] | select(.name | endswith(".tgz")) | .browser_download_url')
curl -L -o cost-onprem-latest.tgz "$LATEST_URL"
```

### Resource Issues

```bash
# Check node resources
kubectl describe nodes | grep -A 5 "Allocated resources"

# Check available resources
kubectl top nodes  # requires metrics-server
```

**See [Troubleshooting Guide](troubleshooting.md) for comprehensive solutions**

---

## Next Steps

After successful installation:

1. **Set Up Authorino** (OpenShift only): See [Authorino Setup](#4-authorino-setup-for-oauth2-authentication)
2. **Configure Access**: See [Configuration Guide](configuration.md)
3. **Set Up JWT Auth**: See [JWT Authentication Guide](native-jwt-authentication.md)
4. **Configure TLS**: See [TLS Setup Guide](cost-management-operator-tls-setup.md)
5. **Run Tests**: See [Scripts Reference](../scripts/README.md)

---

**Related Documentation:**
- [Configuration Guide](configuration.md)
- [Platform Guide](platform-guide.md)
- [Quick Start Guide](quickstart.md)
- [Troubleshooting Guide](troubleshooting.md)

