# ROS-OCP Helm Chart

Kubernetes Helm chart for deploying the complete Resource Optimization Service (ROS-OCP) backend stack.

---

## 🆕 Cost Management On-Premise Deployment

Full **Cost Management (Koku)** deployment with OCP cost analysis, Parquet processing, and Trino analytics.

📖 **[Complete Installation Guide](INSTALLATION_GUIDE.md)** | 
✅ **[E2E Test Results](E2E_TEST_SUCCESS.md)** |
🧪 **[Clean Installation Test](CLEAN_INSTALLATION_TEST_RESULTS.md)**

### Quick Start

**Prerequisites:**
- OpenShift 4.18+
- ODF/NooBaa with 150GB+ storage
- Kafka/Strimzi cluster

**Automated installation:**
```bash
./scripts/install-cost-management-complete.sh
```

**E2E validation:**
```bash
cd scripts && ./cost-mgmt-ocp-dataflow.sh --force
```

### Architecture

**Two-chart deployment:**
1. **Infrastructure** (`cost-management-infrastructure/`)
   - PostgreSQL (Koku database)
   - Trino (Parquet analytics)
   - Hive Metastore (table metadata)
   - Redis (Celery result backend)

2. **Application** (`cost-management-onprem/`)
   - Koku API (reads/writes)
   - MASU (data processor)
   - Kafka Listener (auto-ingestion)
   - 17 Celery workers (download, OCP, summary, etc.)
   - Sources API (provider management)

**Resources:** 37 pods, ~10 CPU cores, ~19GB RAM (development)

**Data Flow:** Kafka → CSV → Parquet → Trino → PostgreSQL → Cost Reports

---

## 🚀 Quick Start (Legacy ROS-OCP)

### Automated Deployment (Recommended)

```bash
# Step 1: Create KIND cluster (development/testing)
./scripts/deploy-kind.sh

# Step 2: Deploy ROS-OCP services
./scripts/install-helm-chart.sh

# Access services at http://localhost:32061
```

### Production Deployment

```bash
# Install latest release from GitHub
./scripts/install-helm-chart.sh

# Or use local chart for development
USE_LOCAL_CHART=true LOCAL_CHART_PATH=../ros-ocp ./scripts/install-helm-chart.sh

# Or specify custom namespace and release name
NAMESPACE=my-namespace HELM_RELEASE_NAME=my-release ./scripts/install-helm-chart.sh

# Or use Helm directly
helm repo add ros-ocp https://insights-onprem.github.io/ros-helm-chart
helm install ros-ocp ros-ocp/ros-ocp --namespace ros-ocp --create-namespace
```

**Note for OpenShift:** See [Authentication Setup](#-authentication-setup) section for required prerequisites (Authorino and Keycloak)

📖 **See [Installation Guide](docs/installation.md) for detailed installation options**

## 📚 Documentation

> **📖 [Complete Documentation Index →](docs/README.md)**
> Comprehensive guides organized by use case, with detailed descriptions and navigation.

### Essential Guides

| 🚀 Getting Started | 🏭 Production Setup | 🔧 Operations |
|-------------------|-------------------|---------------|
| [Quick Start](docs/quickstart.md)<br/>*Fast deployment walkthrough* | [Installation Guide](docs/installation.md)<br/>*Detailed installation instructions* | [Troubleshooting](docs/troubleshooting.md)<br/>*Common issues & solutions* |
| [Platform Guide](docs/platform-guide.md)<br/>*Kubernetes vs OpenShift* | [**Cost Management Install**](docs/cost-management-installation.md)<br/>*Two-chart architecture (NEW)* | [Force Upload](docs/force-operator-upload.md)<br/>*Testing & validation* |
| | [JWT Authentication](docs/native-jwt-authentication.md)<br/>*Ingress authentication (Keycloak)* | [Scripts Reference](scripts/README.md)<br/>*Automation scripts* |
| | [OAuth2 TokenReview](docs/oauth2-tokenreview-authentication.md)<br/>*Backend authentication (Authorino)* | |
| | [Keycloak Setup](docs/keycloak-jwt-authentication-setup.md)<br/>*SSO configuration* | |

**Need more?** Configuration, security, templates, and specialized guides are available in the [Complete Documentation Index](docs/README.md).

## 🏗️ Chart Structure

```
ros-helm-chart/
├── ros-ocp/                    # Helm chart directory
│   ├── Chart.yaml             # Chart metadata
│   ├── values.yaml            # Default configuration
│   └── templates/             # Kubernetes resource templates (46 files)
├── docs/                      # Documentation
├── scripts/                   # Installation and automation scripts
└── .github/workflows/         # CI/CD automation
```

## 📦 Services Deployed

### Stateful Services
- **PostgreSQL** (3 instances): ROS, Kruize, Sources databases
- **MinIO/ODF**: Object storage (MinIO for Kubernetes, ODF for OpenShift)

### Kafka Infrastructure (Managed by Install Script)
- **Strimzi Operator**: Deploys and manages Kafka clusters
- **Kafka 3.8.0**: Message streaming with persistent storage (deployed via Strimzi CRDs)

### Application Services
- **Ingress**: File upload API and routing gateway (with Envoy sidecar for JWT authentication on OpenShift)
- **ROS-OCP API**: Main REST API for recommendations and status (with Envoy sidecar for authentication on OpenShift)
- **ROS-OCP Processor**: Data processing service for cost optimization
- **ROS-OCP Recommendation Poller**: Kruize integration for recommendations
- **ROS-OCP Housekeeper**: Maintenance tasks and data cleanup
- **Kruize Autotune**: Optimization recommendation engine (direct authentication, protected by network policies)
- **Sources API**: Source management and integration (middleware-based authentication for protected endpoints, unauthenticated metadata endpoints for internal use)
- **Redis**: Caching layer for performance

**Security Architecture (OpenShift)**:
- **Ingress Authentication**: Envoy sidecar with JWT validation (Keycloak) for external uploads
- **Backend Authentication**: Envoy sidecar with OAuth2 TokenReview (Authorino) for OpenShift Console UI access
- **Network Policies**: Restrict direct access to backend services (Kruize, Sources API) while allowing Prometheus metrics scraping
- **Multi-tenancy**: `org_id` and `account_number` from authentication enable data isolation across organizations and accounts

**See [JWT Authentication Guide](docs/native-jwt-authentication.md) and [OAuth2 TokenReview Guide](docs/oauth2-tokenreview-authentication.md) for detailed architecture**

## ⚙️ Configuration

### Resource Requirements
- **Memory**: 8GB+ (12GB+ recommended)
- **CPU**: 4+ cores
- **Storage**: 30GB+ persistent storage

### Storage Options
- **Kubernetes/KIND**: MinIO (automatically deployed)
- **OpenShift**: ODF (OpenShift Data Foundation required)

**See [Configuration Guide](docs/configuration.md) for detailed requirements**

## 🌐 Access Points

### Kubernetes (KIND)
All services accessible at **http://localhost:32061**:
- Health Check: `/ready`
- ROS API: `/api/ros/*`
- Kruize API: `/api/kruize/*`
- Sources API: `/api/sources/*`
- Upload API: `/api/ingress/*`

### OpenShift
Services accessible via OpenShift Routes:
```bash
oc get routes -n ros-ocp
```

**See [Platform Guide](docs/platform-guide.md) for platform-specific details**

## 🔐 Authentication Setup

### JWT Authentication (OpenShift/Production)

For OpenShift deployments, JWT authentication is **automatically enabled** and requires Keycloak and Authorino configuration:

```bash
# Step 1: Deploy Red Hat Build of Keycloak (RHBK)
./scripts/deploy-rhbk.sh

# Step 2: Install Authorino for OAuth2 authentication
./scripts/install-authorino.sh

# Step 3: Configure Cost Management Operator with JWT credentials
./scripts/setup-cost-mgmt-tls.sh
```

**📖 See [Keycloak Setup Guide](docs/keycloak-jwt-authentication-setup.md) for detailed configuration instructions**

Key requirements:
- ✅ Keycloak realm with `org_id` and `account_number` claims
- ✅ Service account client credentials
- ✅ Self-signed CA certificate bundle (auto-configured)
- ✅ Cost Management Operator configured with JWT token URL

**Operator Support:**
- ✅ Red Hat Build of Keycloak (RHBK) v22+ - `k8s.keycloak.org/v2alpha1`

**Architecture**: [JWT Authentication Overview](docs/native-jwt-authentication.md)

## 🔧 Common Operations

### Deployment
```bash
# Install/upgrade to latest release
./scripts/install-helm-chart.sh

# Check deployment status
./scripts/install-helm-chart.sh status

# Run health checks
./scripts/install-helm-chart.sh health
```

### Cleanup
```bash
# Cleanup preserving data volumes
./scripts/install-helm-chart.sh cleanup

# Complete removal including data
./scripts/install-helm-chart.sh cleanup --complete
```

## 🧪 Testing & CI/CD

The chart includes comprehensive CI/CD automation:
- **Lint & Validate**: Chart validation on every PR
- **Full Deployment Test**: E2E testing with KIND cluster
- **Automated Releases**: Version-tagged releases with packaged charts

### OCP Smoke Testing
Fast validation using nise-generated data for financial correctness:
```bash
# Quick smoke test (~30-60 seconds)
./scripts/cost-mgmt-ocp-dataflow.sh --smoke-test --force

# Full validation (~1-3 minutes)
./scripts/cost-mgmt-ocp-dataflow.sh --force
```

**📖 See [OCP Smoke Test Guide](OCP_SMOKE_TEST_GUIDE.md) for detailed testing approach**

## 🚨 Troubleshooting

**Quick diagnostics:**
```bash
# Check pods
kubectl get pods -n ros-ocp

# View logs
kubectl logs -n ros-ocp -l app.kubernetes.io/name=rosocp-api

# Check storage
kubectl get pvc -n ros-ocp
```

**See [Troubleshooting Guide](docs/troubleshooting.md) for comprehensive solutions**

## 📄 License

This project is licensed under the terms specified in the [LICENSE](LICENSE) file.

## 🤝 Contributing

See [Quick Start Guide](docs/quickstart.md) for development environment setup.

## 📞 Support

For issues and questions:
- **Issues**: [GitHub Issues](https://github.com/insights-onprem/ros-helm-chart/issues)
- **Documentation**: [Complete Documentation Index](docs/README.md)
- **Scripts**: [Automation Scripts Reference](scripts/README.md)
