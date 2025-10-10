# ROS-OCP Platform Guide

Platform-specific configuration and differences between Kubernetes and OpenShift deployments.

## Table of Contents
- [Platform Overview](#platform-overview)
- [Automatic Platform Detection](#automatic-platform-detection)
- [Kubernetes Deployment](#kubernetes-deployment)
- [OpenShift Deployment](#openshift-deployment)
- [Feature Comparison](#feature-comparison)
- [Migration Guide](#migration-guide)

## Platform Overview

The ROS-OCP Helm chart automatically adapts to different Kubernetes platforms, providing optimized configurations for both standard Kubernetes and OpenShift environments.

### Supported Platforms

| Platform | Version | Status | Use Case |
|----------|---------|--------|----------|
| **Kubernetes** | 1.24+ | ✅ Supported | Development, Testing |
| **KIND** | Latest | ✅ Supported | CI/CD, Local Dev |
| **OpenShift** | 4.12+ | ✅ Supported | Production |
| **Single Node OpenShift** | 4.12+ | ✅ Supported | Edge, Development |

---

## Automatic Platform Detection

The installation script automatically detects the platform and applies appropriate configurations.

### Detection Method

```bash
# Platform detection logic
if kubectl get routes.route.openshift.io >/dev/null 2>&1; then
    PLATFORM="openshift"
    echo "Detected OpenShift platform"
else
    PLATFORM="kubernetes"
    echo "Detected Kubernetes platform"
fi
```

### What Gets Configured Automatically

| Feature | Kubernetes | OpenShift |
|---------|-----------|-----------|
| **Routing** | Ingress resources | Route resources |
| **Storage** | MinIO (deployed) | ODF (existing) |
| **Access** | `localhost:32061` | Route hostnames |
| **TLS** | Optional | Edge termination |
| **Security Context** | Standard | Enhanced |

---

## Kubernetes Deployment

### Architecture

```
┌─────────────────────────────────────┐
│   nginx-ingress (port 32061)        │
├─────────────────────────────────────┤
│  Path Routing:                      │
│  /api/ros/*      → ROS API          │
│  /api/kruize/*   → Kruize API       │
│  /api/sources/*  → Sources API      │
│  /api/ingress/*  → Upload API       │
│  /minio          → MinIO Console    │
└─────────────────────────────────────┘
```

### Networking

**Ingress Configuration:**
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ros-ocp-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - path: /api/ros(/|$)(.*)
        pathType: ImplementationSpecific
        backend:
          service:
            name: ros-ocp-rosocp-api
            port:
              number: 8000
```

**Access URLs:**
```bash
# All services through single ingress
http://localhost:32061/ready
http://localhost:32061/status
http://localhost:32061/api/ros/*
http://localhost:32061/api/kruize/*
http://localhost:32061/api/sources/*
http://localhost:32061/api/ingress/*
http://localhost:32061/minio
```

### Storage

**MinIO Deployment:**
- Automatically deployed as StatefulSet
- S3-compatible object storage
- Web console included
- Default credentials: `minioaccesskey` / `miniosecretkey`

```yaml
minio:
  image:
    repository: quay.io/minio/minio
    tag: "RELEASE.2025-07-23T15-54-02Z"
  storage:
    size: 20Gi
  ports:
    api: 9000
    console: 9990
```

**Storage Class:**
```bash
# Uses default storage class or custom
global:
  storageClass: "standard"  # or empty for default
```

### KIND-Specific Features

**Cluster Setup:**
```bash
# Automated KIND cluster creation
./scripts/deploy-kind.sh
```

**Features:**
- Container runtime support (Docker/Podman)
- Automated ingress controller installation
- Fixed resource allocation (6GB memory)
- Port mapping to `localhost:32061`
- Perfect for CI/CD pipelines

**Configuration:**
```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30080
    hostPort: 32061
    protocol: TCP
```

### Kubernetes-Specific Values

```yaml
# values-kubernetes.yaml
serviceIngress:
  className: nginx
  enabled: true
  hosts:
    - host: localhost
      paths:
        - path: /
          pathType: Prefix

minio:
  enabled: true

serviceRoute:
  enabled: false

global:
  platform:
    openshift: false
```

---

## OpenShift Deployment

### Architecture

```
┌─────────────────────────────────────┐
│   OpenShift Router (HAProxy)        │
├─────────────────────────────────────┤
│  Routes (separate hostnames):       │
│  ros-ocp-main-ros-ocp.apps...       │
│  ros-ocp-ingress-ros-ocp.apps...    │
│  ros-ocp-kruize-ros-ocp.apps...     │
└─────────────────────────────────────┘
```

### Networking

**Route Configuration:**
```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: ros-ocp-main
  annotations:
    haproxy.router.openshift.io/timeout: "30s"
spec:
  host: ""  # Auto-generated: ros-ocp-main-namespace.apps.cluster.com
  to:
    kind: Service
    name: ros-ocp-rosocp-api
  port:
    targetPort: 8000
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
```

**Access URLs:**
```bash
# Get route hostnames
oc get routes -n ros-ocp

# Example routes
https://ros-ocp-main-ros-ocp.apps.cluster.com
https://ros-ocp-ingress-ros-ocp.apps.cluster.com
https://ros-ocp-kruize-ros-ocp.apps.cluster.com
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
oc create secret generic ros-ocp-odf-credentials \
  --from-literal=access-key=<key> \
  --from-literal=secret-key=<secret> \
  -n ros-ocp
```

**Configuration:**
```yaml
odf:
  endpoint: "s3.openshift-storage.svc.cluster.local"
  region: "us-east-1"
  bucket: "ros-data"
  pathStyle: true
  useSSL: true
  port: 443
  credentials:
    secretName: "ros-ocp-odf-credentials"
```

### Security

**Enhanced Security Context:**
```yaml
# OpenShift SCCs (Security Context Constraints)
securityContext:
  runAsNonRoot: true
  runAsUser: 1001
  fsGroup: 1001
  seccompProfile:
    type: RuntimeDefault

# Automatically uses restricted-v2 SCC
```

**Service Accounts:**
```bash
# View service accounts
oc get sa -n ros-ocp

# View assigned SCCs
oc get pod <pod-name> -n ros-ocp -o yaml | grep scc
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
    secretName: "ros-ocp-odf-credentials"

minio:
  enabled: false

serviceIngress:
  enabled: false

global:
  platform:
    openshift: true
    domain: "apps.cluster.example.com"
```

---

## Feature Comparison

### Routing & Access

| Feature | Kubernetes | OpenShift |
|---------|-----------|-----------|
| **Resource Type** | Ingress | Route |
| **Controller** | nginx-ingress | HAProxy (built-in) |
| **TLS** | Manual cert management | Automatic edge termination |
| **Path Routing** | Single ingress, path-based | Separate routes per service |
| **External Access** | `localhost:32061` (KIND) | Auto-generated hostnames |
| **Wildcard Support** | Yes (with cert) | Yes (cluster-wide) |

### Storage

| Feature | Kubernetes | OpenShift |
|---------|-----------|-----------|
| **Object Storage** | MinIO (deployed) | ODF/NooBaa (existing) |
| **Deployment** | StatefulSet | Uses existing installation |
| **Credentials** | Auto-generated | User-provided secret |
| **Console** | Included | OpenShift console |
| **S3 Compatibility** | Full | Full |
| **Enterprise Features** | Basic | Advanced (deduplication, etc.) |

### Security

| Feature | Kubernetes | OpenShift |
|---------|-----------|-----------|
| **Pod Security** | PSS/PSA | SCCs (more granular) |
| **RBAC** | Standard | Enhanced with SCCs |
| **Network Policy** | Optional | Recommended |
| **Service Mesh** | Optional (Istio) | Optional (Service Mesh) |
| **TLS** | Manual | Automatic (routes) |

### Operations

| Feature | Kubernetes | OpenShift |
|---------|-----------|-----------|
| **CLI** | `kubectl` | `oc` (+ kubectl compatibility) |
| **Web Console** | Dashboard (optional) | Built-in console |
| **Monitoring** | Manual setup | Built-in Prometheus |
| **Logging** | Manual setup | Built-in EFK/Loki |
| **Updates** | Manual | Automated operators |

---

## Migration Guide

### Kubernetes to OpenShift

**Prerequisites:**
1. Install ODF in OpenShift cluster
2. Create ODF credentials secret
3. Backup data from MinIO

**Migration Steps:**

```bash
# 1. Backup MinIO data
kubectl exec -n ros-ocp statefulset/ros-ocp-minio -- \
  mc mirror local/ros-data /tmp/backup

# 2. Export data
kubectl cp ros-ocp/ros-ocp-minio-0:/tmp/backup ./backup-data

# 3. Deploy to OpenShift
oc create secret generic ros-ocp-odf-credentials \
  --from-literal=access-key=<key> \
  --from-literal=secret-key=<secret> \
  -n ros-ocp

helm install ros-ocp ./ros-ocp \
  -f values-openshift.yaml \
  -n ros-ocp

# 4. Import data to ODF
# Use ODF console or mc client to upload backup data
```

### OpenShift to Kubernetes

**Steps:**

```bash
# 1. Backup ODF data
aws --endpoint-url https://s3-openshift-storage... \
  s3 sync s3://ros-data ./backup-data

# 2. Deploy to Kubernetes
helm install ros-ocp ./ros-ocp \
  -f values-kubernetes.yaml \
  -n ros-ocp

# 3. Restore to MinIO
kubectl exec -n ros-ocp statefulset/ros-ocp-minio -- \
  mc mirror /backup-data local/ros-data
```

---

## Platform-Specific Troubleshooting

### Kubernetes Issues

**Ingress not accessible:**
```bash
# Check ingress controller
kubectl get pods -n ingress-nginx
kubectl logs -n ingress-nginx deployment/ingress-nginx-controller

# Check ingress rules
kubectl describe ingress ros-ocp-ingress -n ros-ocp

# Verify port mapping (KIND)
docker port ros-ocp-cluster-control-plane
```

**MinIO issues:**
```bash
# Check MinIO pods
kubectl get pods -l app=minio -n ros-ocp

# Access MinIO logs
kubectl logs -n ros-ocp statefulset/ros-ocp-minio

# Verify PVC
kubectl get pvc -l app=minio -n ros-ocp
```

### OpenShift Issues

**Routes not accessible:**
```bash
# Check routes
oc get routes -n ros-ocp
oc describe route ros-ocp-main -n ros-ocp

# Check router pods
oc get pods -n openshift-ingress

# Test internal connectivity
oc rsh deployment/ros-ocp-rosocp-api
curl http://ros-ocp-rosocp-api:8000/status
```

**ODF issues:**
```bash
# Check ODF status
oc get noobaa -n openshift-storage
oc get cephcluster -n openshift-storage

# Check credentials secret
oc get secret ros-ocp-odf-credentials -n ros-ocp

# Test S3 connectivity
oc rsh deployment/ros-ocp-ingress
aws --endpoint-url https://s3.openshift-storage... s3 ls
```

---

## Best Practices

### Kubernetes

✅ **Do:**
- Use KIND for local development and CI/CD
- Set resource limits to prevent cluster issues
- Use LoadBalancer or NodePort for production ingress
- Monitor ingress controller logs
- Regular MinIO backups

❌ **Don't:**
- Expose services directly without ingress
- Use default MinIO credentials in production
- Skip resource limits (causes OOM issues)

### OpenShift

✅ **Do:**
- Use ODF for production workloads
- Leverage built-in monitoring and logging
- Use route TLS termination
- Follow SCC best practices
- Use dedicated service accounts for ODF access

❌ **Don't:**
- Use admin ODF credentials for applications
- Disable security contexts
- Skip route TLS in production
- Mix Ingress and Routes (use Routes only)

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

