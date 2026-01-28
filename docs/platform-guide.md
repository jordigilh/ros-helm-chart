# Cost Management On-Premise Platform Guide

Platform-specific configuration and details for OpenShift deployments.

## Table of Contents
- [Platform Overview](#platform-overview)
- [OpenShift Deployment](#openshift-deployment)
- [Platform-Specific Troubleshooting](#platform-specific-troubleshooting)

## Platform Overview

The Cost Management On-Premise Helm chart is designed for OpenShift environments, providing optimized configurations for production deployments.

### Supported Platforms

| Platform | Version | Status | Use Case |
|----------|---------|--------|----------|
| **OpenShift** | 4.18+ | ✅ Supported | Production |
| **Single Node OpenShift** | 4.18+ | ✅ Supported | Edge, Development |

> **Note**: Tested with OpenShift 4.18.24 (Kubernetes 1.31.12)

---

## OpenShift Deployment

### Architecture

```mermaid
graph TB
    Client["Client"] --> Router

    subgraph Router["OpenShift Router (HAProxy)"]
        direction TB
        Routes["Routes (separate hostnames)"]
    end

    Routes -->|"cost-onprem-main-cost-onprem.apps..."| Main["ROS Main Service"]
    Routes -->|"cost-onprem-ingress-cost-onprem.apps..."| Ingress["Ingress Service"]
    Routes -->|"cost-onprem-ui-cost-onprem.apps..."| UI["UI Service<br/>(OAuth Proxy + App)"]
    Routes -->|"cost-onprem-kruize-cost-onprem.apps..."| Kruize["Kruize Service"]

    style Router fill:#e57373,stroke:#333,stroke-width:2px,color:#000
    style Main fill:#a5d6a7,stroke:#333,stroke-width:2px,color:#000
    style Ingress fill:#a5d6a7,stroke:#333,stroke-width:2px,color:#000
    style UI fill:#a5d6a7,stroke:#333,stroke-width:2px,color:#000
    style Kruize fill:#a5d6a7,stroke:#333,stroke-width:2px,color:#000
```

### Networking

**Route Configuration:**
```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: cost-onprem-main
  annotations:
    haproxy.router.openshift.io/timeout: "30s"
spec:
  host: ""  # Auto-generated: cost-onprem-main-namespace.apps.cluster.com
  to:
    kind: Service
    name: cost-onprem-ros-api
  port:
    targetPort: 8000
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
```

**Access URLs:**
```bash
# Get route hostnames
oc get routes -n cost-onprem

# Example routes
https://cost-onprem-main-cost-onprem.apps.cluster.com      # ROS API
https://cost-onprem-ingress-cost-onprem.apps.cluster.com   # Ingress API (file upload)
https://cost-onprem-ui-cost-onprem.apps.cluster.com        # UI (web interface)
https://cost-onprem-kruize-cost-onprem.apps.cluster.com    # Kruize API
```

### Storage

**ODF (OpenShift Data Foundation):**
- Uses existing ODF installation
- NooBaa S3 service
- Enterprise-grade storage
- Requires credentials secret

**Prerequisites:**
```bash
# Verify ODF installation
oc get noobaa -n openshift-storage
oc get storagecluster -n openshift-storage

# Create credentials secret
oc create secret generic cost-onprem-odf-credentials \
  --from-literal=access-key=<key> \
  --from-literal=secret-key=<secret> \
  -n cost-onprem
```

**Configuration:**
```yaml
odf:
  endpoint: "s3.openshift-storage.svc.cluster.local"
  s3:
    region: "onprem"  # Default for NooBaa/MinIO; use "us-east-1" for AWS S3
  bucket: "ros-data"
  pathStyle: true
  useSSL: true
  port: 443
  credentials:
    secretName: "cost-onprem-odf-credentials"
```

### Security

**Enhanced Security Context:**
```yaml
# OpenShift SCCs (Security Context Constraints)
securityContext:
  runAsNonRoot: true
  seccompProfile:
    type: RuntimeDefault

# Automatically uses restricted-v2 SCC
```

**Service Accounts:**
```bash
# View service accounts
oc get sa -n cost-onprem

# View assigned SCCs
oc get pod <pod-name> -n cost-onprem -o yaml | grep scc
```

### TLS Configuration

**Automatic TLS Termination:**
```yaml
serviceRoute:
  tls:
    termination: edge                # TLS at router
    insecureEdgeTerminationPolicy: Redirect  # Redirect HTTP to HTTPS
```

**Options:**
- `edge`: TLS termination at router
- `passthrough`: TLS to pod
- `reencrypt`: TLS at router and pod

### UI Component

**Availability:**
- ✅ **OpenShift**: Fully supported with Keycloak OAuth proxy authentication

**Architecture:**
The UI component consists of two containers in a single pod:
- **OAuth2 Proxy**: Handles Keycloak OIDC authentication flow (port 8443)
- **Application**: Serves the Koku UI micro-frontend (port 8080, internal)

**Access:**
```bash
# Get UI route
oc get route cost-onprem-ui -n cost-onprem -o jsonpath='{.spec.host}'

# Access UI (requires Keycloak authentication)
# Browser will redirect to Keycloak login, then back to UI
https://cost-onprem-ui-cost-onprem.apps.cluster.example.com
```

**Configuration:**
```yaml
ui:
  replicaCount: 1
  oauthProxy:
    image:
      repository: quay.io/oauth2-proxy/oauth2-proxy
      tag: "v7.7.1"
  keycloak:
    client:
      id: "cost-management-ui"
      secret: "<client-secret>"
  app:
    image:
      repository: quay.io/insights-onprem/koku-ui-mfe-on-prem
      tag: "0.0.14"
    port: 8080
```

**Features:**
- Automatic TLS certificate management via OpenShift service serving certificates
- Cookie-based session management
- Seamless Keycloak OIDC authentication integration
- Connects to ROS API backend for data

**Documentation:**
- **Templates**: See [Helm Templates Reference - UI Templates](helm-templates-reference.md#ui-templates) for resource definitions
- **Authentication**: See [UI OAuth Authentication](ui-oauth-authentication.md) for OAuth proxy setup and troubleshooting

### OpenShift-Specific Values

```yaml
# values-openshift.yaml
serviceRoute:
  enabled: true
  annotations:
    haproxy.router.openshift.io/timeout: "30s"
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect

odf:
  endpoint: "s3.openshift-storage.svc.cluster.local"
  bucket: "ros-data"
  credentials:
    secretName: "cost-onprem-odf-credentials"

global:
  platform:
    openshift: true
    domain: "apps.cluster.example.com"
```

---

## Platform-Specific Troubleshooting

### OpenShift Issues

**Routes not accessible:**
```bash
# Check routes
oc get routes -n cost-onprem
oc describe route cost-onprem-main -n cost-onprem

# Check router pods
oc get pods -n openshift-ingress

# Test internal connectivity
oc rsh deployment/cost-onprem-ros-api
curl http://cost-onprem-ros-api:8000/status
```

**ODF issues:**
```bash
# Check ODF status
oc get noobaa -n openshift-storage
oc get cephcluster -n openshift-storage

# Check credentials secret
oc get secret cost-onprem-odf-credentials -n cost-onprem

# Test S3 connectivity
oc rsh deployment/cost-onprem-ingress
aws --endpoint-url https://s3.openshift-storage... s3 ls
```

**Security Context Constraints:**
```bash
# Check which SCC is being used
oc get pod <pod-name> -n cost-onprem -o yaml | grep scc

# List available SCCs
oc get scc

# Check if service account has required permissions
oc adm policy who-can use scc restricted-v2
```

---

## Next Steps

- **Installation**: See [Installation Guide](installation.md)
- **Configuration**: See [Configuration Guide](configuration.md)
- **Troubleshooting**: See [Troubleshooting Guide](troubleshooting.md)

---

**Related Documentation:**
- [Installation Guide](installation.md)
- [Configuration Guide](configuration.md)
- [Quick Start Guide](quickstart.md)
