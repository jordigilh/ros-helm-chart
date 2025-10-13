# Envoy → Authorino Configuration Explained

This document shows exactly where and how Envoy is configured to use Authorino for external authorization in the enhanced ROS ingress template.

## 🎯 Overview

Envoy uses the **External Authorization** pattern to call Authorino:
1. **HTTP Filter** intercepts requests and calls ext_authz
2. **gRPC Service** defines how to reach Authorino
3. **Cluster Definition** specifies Authorino's network location

## 🔍 Configuration Section 1: External Authorization Filter

**Location**: In the Envoy ConfigMap, under `http_filters`

```yaml
# File: templates/enhanced-ros-ingress-authorino.yaml
# ConfigMap: envoy-authorino-enhanced-config
# Path: data.envoy.yaml → static_resources → listeners → filter_chains → filters → http_filters

http_filters:
# 🚨 THIS IS WHERE ENVOY CALLS AUTHORINO 🚨
- name: envoy.filters.http.ext_authz
  typed_config:
    "@type": type.googleapis.com/envoy.extensions.filters.http.ext_authz.v3.ExtAuthz
    transport_api_version: V3

    # 🎯 GRPC CONNECTION TO AUTHORINO
    grpc_service:
      envoy_grpc:
        cluster_name: authorino-service  # ← References cluster definition below
      timeout: 5s

    # 🚫 SECURITY: Fail closed if Authorino is unavailable
    failure_mode_allow: false

    # 📦 SEND REQUEST BODY TO AUTHORINO (up to 8KB)
    with_request_body:
      max_request_bytes: 8192

    # 🔄 CLEAR ROUTE CACHE AFTER AUTH (for dynamic routing)
    clear_route_cache: true

    # 📤 HEADERS TO PASS TO AUTHORINO
    allowed_headers:
      patterns:
      - exact: authorization        # ← JWT token
      - prefix: x-                 # ← Custom headers

    # 📥 HEADERS TO FORWARD TO BACKEND AFTER AUTH
    allowed_upstream_headers:
      patterns:
      - prefix: x-ros-             # ← All our enriched headers
      - prefix: x-jwt-             # ← JWT token headers
      - prefix: x-client-          # ← Client ID headers
      - prefix: x-token-           # ← Token metadata
      - prefix: x-user-            # ← User context
      - prefix: x-bearer-          # ← Bearer token
      - prefix: x-original-        # ← Original token
      - exact: authorization       # ← Original auth header
```

**What this does:**
- 🛑 **Intercepts EVERY request** before it reaches ROS ingress
- 📞 **Calls Authorino via gRPC** on cluster `authorino-service`
- ⏱️ **Waits up to 5 seconds** for Authorino's response
- 🚫 **Denies request** if Authorino is unavailable (fail closed)
- 📋 **Passes headers** starting with `x-` and `authorization` to Authorino
- ✅ **Forwards enriched headers** to ROS ingress if auth succeeds

## 🔍 Configuration Section 2: Authorino Service Cluster

**Location**: In the Envoy ConfigMap, under `clusters`

```yaml
# File: templates/enhanced-ros-ingress-authorino.yaml
# ConfigMap: envoy-authorino-enhanced-config
# Path: data.envoy.yaml → static_resources → clusters

clusters:
# 🚨 THIS DEFINES HOW TO REACH AUTHORINO 🚨
- name: authorino-service                    # ← Referenced by ext_authz filter above
  connect_timeout: 5s
  type: LOGICAL_DNS                          # ← Use Kubernetes DNS resolution
  lb_policy: ROUND_ROBIN                     # ← Load balancing (single instance)
  http2_protocol_options: {}                 # ← Enable HTTP/2 for gRPC

  # 🎯 AUTHORINO SERVICE LOCATION
  load_assignment:
    cluster_name: authorino-service
    endpoints:
    - lb_endpoints:
      - endpoint:
          address:
            socket_address:
              # 🏠 KUBERNETES SERVICE DNS NAME
              address: authorino-authorino-authorization.costmanagement-metrics-operator.svc.cluster.local
              port_value: 50051          # ← Authorino gRPC port
```

**What this does:**
- 🌐 **Defines network location** of Authorino service
- 🔗 **Uses Kubernetes DNS** to resolve service name
- 📡 **Connects via gRPC** (HTTP/2) on port 50051
- ⚖️ **Load balances** requests (though typically single instance)
- ⏱️ **5 second connection timeout** for reliability

## 🔍 Configuration Section 3: Request Flow Integration

**Location**: Throughout the Envoy configuration

```yaml
# REQUEST FLOW CONFIGURATION:

# 1️⃣ LISTENER - Where Envoy receives client requests
listeners:
- name: listener_0
  address:
    socket_address:
      address: 0.0.0.0
      port_value: 8080              # ← External clients connect here

# 2️⃣ HTTP CONNECTION MANAGER - Processes HTTP requests
filter_chains:
- filters:
  - name: envoy.filters.network.http_connection_manager
    typed_config:
      # ... configuration ...

      # 🔄 FILTER ORDER IS CRITICAL:
      http_filters:
      - name: envoy.filters.http.ext_authz     # ← FIRST: Check auth via Authorino
        # ... ext_authz config shown above ...
      - name: envoy.filters.http.router        # ← SECOND: Route to backend
        # ... router config ...

# 3️⃣ ROUTING - Where requests go after authorization
route_config:
  virtual_hosts:
  - name: ros_ingress_enhanced
    domains: ["*"]
    routes:
    - match: { prefix: "/" }
      route:
        cluster: ros-ingress-backend          # ← ROS ingress backend

# 4️⃣ BACKEND CLUSTER - ROS ingress destination
- name: ros-ingress-backend
  # ... config ...
  load_assignment:
    endpoints:
    - lb_endpoints:
      - endpoint:
          address:
            socket_address:
              address: localhost              # ← Same pod
              port_value: 8081               # ← ROS ingress port
```

## 🔄 Complete Request Flow

Here's exactly what happens when a request comes in:

```
1. 📥 CLIENT REQUEST
   curl -H "Authorization: Bearer JWT" http://envoy:8080/api/upload
   ↓

2. 🚪 ENVOY LISTENER (port 8080)
   listener_0 receives the HTTP request
   ↓

3. 🛡️ EXTERNAL AUTHORIZATION FILTER
   envoy.filters.http.ext_authz intercepts request
   ↓

4. 📞 GRPC CALL TO AUTHORINO
   gRPC request to: authorino-authorino-authorization.costmanagement-metrics-operator.svc.cluster.local:50051
   Message: "Check authorization for this JWT and path"
   ↓

5. 🧠 AUTHORINO PROCESSES REQUEST
   • Validates JWT against Keycloak JWKS
   • Applies AuthConfig policies
   • Returns: ALLOW + headers to inject
   ↓

6. ✅ ENVOY RECEIVES AUTHORIZATION RESPONSE
   Response: "ALLOW" + headers like X-User-ID, X-Client-ID, etc.
   ↓

7. 📤 ENVOY FORWARDS TO ROS INGRESS
   Adds all enriched headers and forwards to localhost:8081
   ↓

8. 🎯 ROS INGRESS RECEIVES ENRICHED REQUEST
   Request now has all authentication context in headers
```

## 🧪 Testing the Configuration

You can verify this is working by checking:

### 1. Envoy Admin Interface
```bash
# Port forward to Envoy admin
oc port-forward deployment/ros-ingress-authorino-enhanced 9901:9901 -n ros-ocp

# Check cluster status
curl http://localhost:9901/clusters | grep authorino-service

# Check if Authorino is healthy
curl http://localhost:9901/clusters | grep authorino-service | grep healthy
```

### 2. Envoy Access Logs
```bash
# Watch Envoy logs to see ext_authz calls
oc logs deployment/ros-ingress-authorino-enhanced -c envoy-proxy -n ros-ocp -f

# Look for lines like:
# ext_authz: calling authorization service
# ext_authz: authorization response: ALLOW
```

### 3. Authorino Logs
```bash
# Watch Authorino logs to see gRPC requests
oc logs deployment/authorino -n costmanagement-metrics-operator -f

# Look for gRPC authorization requests and responses
```

## 🔧 Key Configuration Points

| Configuration Item | Purpose | Location |
|-------------------|---------|----------|
| `cluster_name: authorino-service` | Links filter to cluster | ext_authz config |
| `address: authorino-authorino-...` | Authorino service DNS | cluster config |
| `port_value: 50051` | Authorino gRPC port | cluster config |
| `timeout: 5s` | Max wait for auth decision | ext_authz config |
| `failure_mode_allow: false` | Fail closed security | ext_authz config |
| `allowed_upstream_headers` | Headers to forward | ext_authz config |

## 🚨 Critical Dependencies

For this configuration to work:

1. **✅ Authorino must be deployed** in `costmanagement-metrics-operator` namespace
2. **✅ Authorino service** must be named `authorino-authorino-authorization`
3. **✅ Authorino gRPC port** must be 50051
4. **✅ AuthConfig CRD** must exist for JWT validation rules
5. **✅ Network policies** must allow Envoy → Authorino communication

## 💡 Troubleshooting

If Envoy → Authorino isn't working:

```bash
# Check if Authorino service exists
oc get svc -n costmanagement-metrics-operator | grep authorino

# Check if Authorino is ready
oc get pods -n costmanagement-metrics-operator | grep authorino

# Test Authorino gRPC directly
grpcurl -plaintext authorino-authorino-authorization.costmanagement-metrics-operator.svc.cluster.local:50051 list

# Check Envoy configuration loaded correctly
oc exec deployment/ros-ingress-authorino-enhanced -c envoy-proxy -- curl localhost:9901/config_dump | jq '.configs[].dynamic_active_clusters'
```

This configuration creates a robust, enterprise-grade authentication system using Red Hat's Authorino with industry-standard Envoy proxy integration! 🎯






