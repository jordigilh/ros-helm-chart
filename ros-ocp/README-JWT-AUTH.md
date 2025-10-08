# ROS Helm Chart - JWT Authentication Setup

This document provides complete instructions for deploying the ROS Helm chart with JWT authentication via Authorino and Keycloak.

## Prerequisites

### 1. Authorino Operator (Required)

**⚠️ IMPORTANT**: The Authorino Operator must be installed **before** deploying this Helm chart.

#### Quick Installation

```bash
# Install the operator
oc apply -f scripts/install-authorino-operator.yaml

# Wait 2-3 minutes, then verify installation
./scripts/check-authorino-operator.sh
```

#### Detailed Instructions

See [docs/authorino-operator-prerequisites.md](docs/authorino-operator-prerequisites.md) for:
- Multiple installation methods (Console, CLI, Ansible)
- Verification steps
- Troubleshooting guide

### 2. Keycloak (Optional - Auto-detected)

The chart can automatically detect Keycloak installations via:
- Keycloak Custom Resources (`keycloaks.keycloak.org`)
- OpenShift Routes or Kubernetes Ingresses
- Manual URL configuration

## Quick Deployment

### 1. Install Prerequisites

```bash
# Install Authorino Operator
oc apply -f scripts/install-authorino-operator.yaml

# Wait and verify
./scripts/check-authorino-operator.sh
```

### 2. Deploy with JWT Authentication

```bash
# Auto-detect Keycloak and deploy with JWT auth
helm install ros-ocp . --set jwt_auth.enabled=true

# Or specify Keycloak URL manually
helm install ros-ocp . \
  --set jwt_auth.enabled=true \
  --set jwt_auth.keycloak.issuer.baseUrl=https://keycloak.mydomain.com
```

## Configuration Options

### Basic Configuration

```yaml
jwt_auth:
  enabled: true
  
  # Keycloak configuration (auto-detected if empty)
  keycloak:
    issuer:
      baseUrl: ""  # Auto-detect or specify URL
      realm: kubernetes
    audiences:
      - cost-management-operator
      - openshift-oidc

  # Authorino deployment (same namespace)
  authorino:
    deploy:
      enabled: true
      name: ros-authorino
      image:
        repository: registry.redhat.io/rhosak/authorino-rhel8
        tag: "1.0.0"
```

### Production Configuration

```yaml
jwt_auth:
  enabled: true
  
  # Red Hat enterprise images
  envoy:
    image:
      repository: registry.redhat.io/openshift-service-mesh/proxyv2-rhel9
      tag: "2.4.3"
      pullPolicy: Always
  
  authorino:
    deploy:
      enabled: true
      image:
        repository: registry.redhat.io/rhosak/authorino-rhel8
        tag: "1.0.0"
        pullPolicy: Always
      logLevel: warn
      tls:
        enabled: true
```

## Architecture

The JWT authentication architecture includes:

```
Client Request (with JWT) 
    ↓
Envoy Proxy (Port 8080)
    ↓ External Authorization
Authorino (gRPC Port 50051)
    ↓ JWT Validation
Keycloak JWKS Endpoint
    ↓ If Valid
ROS Ingress (Port 8081)
```

### Components

1. **Envoy Proxy**: Intercepts requests, forwards to Authorino for validation
2. **Authorino**: Validates JWT tokens against Keycloak JWKS
3. **ROS Ingress**: Processes authenticated requests (auth disabled)
4. **Keycloak**: Issues JWT tokens and provides JWKS endpoint

## Verification

### 1. Check Deployments

```bash
# Check all components are running
oc get pods -n ros-ocp

# Expected pods:
# - ros-ocp-ingress-* (with envoy + ros-ingress containers)
# - ros-authorino-* (authorino instance)
```

### 2. Test JWT Authentication

```bash
# Generate a Keycloak token
TOKEN=$(curl -s -X POST "https://keycloak.example.com/auth/realms/kubernetes/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials" \
  -d "client_id=cost-management-operator" \
  -d "client_secret=YOUR_SECRET" | jq -r '.access_token')

# Test authenticated request
curl -X POST "https://ros-ingress.example.com/api/cost-management/v1/upload" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/vnd.redhat.hccm.upload" \
  -d @test-payload.json
```

### 3. Debug Information

```bash
# Get debug information
oc get configmap RELEASE-NAME-keycloak-debug -o yaml

# Check Authorino logs
oc logs -l app=ros-authorino -f

# Check Envoy logs
oc logs -l app.kubernetes.io/name=ros-ocp -c envoy-proxy -f
```

## Troubleshooting

### Common Issues

1. **"no matches for kind Authorino"**
   - Authorino Operator not installed
   - Run: `./scripts/check-authorino-operator.sh`

2. **Keycloak not detected**
   - Check debug ConfigMap for detection results
   - Manually set `jwt_auth.keycloak.issuer.baseUrl`

3. **JWT validation fails**
   - Verify token audience matches `jwt_auth.keycloak.audiences`
   - Check Authorino logs for validation errors
   - Ensure Keycloak JWKS endpoint is accessible

4. **Envoy connection errors**
   - Verify Authorino service is running
   - Check service names and ports in Envoy config

### Support

- **Documentation**: [Authorino Docs](https://docs.kuadrant.io/authorino/)
- **Red Hat Support**: For enterprise customers with valid subscriptions
- **Community**: [Kuadrant Community](https://github.com/kuadrant)

## Files Reference

- `docs/authorino-operator-prerequisites.md` - Detailed operator installation
- `scripts/install-authorino-operator.yaml` - Operator subscription
- `scripts/check-authorino-operator.sh` - Verification script
- `values-jwt-auth-example.yaml` - Example configuration
- `values-production.yaml` - Production configuration
