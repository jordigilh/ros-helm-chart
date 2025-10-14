# Native JWT Authentication

## Overview

The ROS Helm Chart uses **Envoy's native JWT authentication filter** for validating JWT tokens from Keycloak/RHSSO. This provides secure, low-latency authentication for file uploads and API requests.

## Architecture

```
┌─────────────┐
│   Client    │
│ (with JWT)  │
└──────┬──────┘
       │ Authorization: Bearer <JWT>
       ▼
┌─────────────────────────────────┐
│     Envoy Sidecar (Port 8080)   │
│                                  │
│  1. jwt_authn filter             │
│     - Fetches JWKS from Keycloak│
│     - Validates JWT signature    │
│     - Extracts claims to metadata│
│                                  │
│  2. Lua filter                   │
│     - Reads JWT claims           │
│     - Injects X-ROS-* headers    │
│                                  │
│  3. Routes to backend            │
└──────┬──────────────────────────┘
       │ X-ROS-Authenticated: true
       │ X-ROS-User-ID: <sub>
       │ X-Bearer-Token: <token>
       ▼
┌─────────────────────────────────┐
│  ROS Ingress Service (Port 8081)│
│                                  │
│  - Trusts X-ROS headers          │
│  - Processes authenticated upload│
└─────────────────────────────────┘
```

## Why Native JWT?

### Previous Approach: Authorino + ext_authz

The original implementation used Authorino (an external authorization service) with Envoy's `ext_authz` filter:

**Issues:**
- ❌ **Multipart uploads failed** - `ext_authz` doesn't forward response headers for multipart-encoded requests
- ❌ **Higher latency** - External gRPC call to Authorino (~5ms overhead)
- ❌ **Complex architecture** - Required separate Authorino deployment
- ❌ **Harder debugging** - Two components to troubleshoot

### Current Approach: Native JWT

**Benefits:**
- ✅ **Works with multipart uploads** - Inline validation, no body buffering issues
- ✅ **Lower latency** - Inline validation (<1ms)
- ✅ **Simpler architecture** - One less component to manage
- ✅ **Easier debugging** - All configuration in one place

## Configuration

### Helm Values

```yaml
jwt_auth:
  enabled: true  # Auto-enabled on OpenShift

  envoy:
    image:
      repository: registry.redhat.io/openshift-service-mesh/proxyv2-rhel9
      tag: "2.6"
    port: 8080
    adminPort: 9901

  keycloak:
    url: ""  # Auto-detected from cluster
    realm: kubernetes
    audiences:
      - account
      - cost-management-operator
```

### JWT Claims to Headers Mapping

The Lua filter extracts JWT claims and injects these headers:

| JWT Claim            | HTTP Header         | Description                |
|----------------------|---------------------|----------------------------|
| `sub`                | `X-ROS-User-ID`     | User/service account ID    |
| `preferred_username` | `X-ROS-User-Name`   | Username                   |
| `azp` or `client_id` | `X-Client-ID`       | Client ID                  |
| (authentication)     | `X-ROS-Authenticated` | Always "true" when valid   |
| (method)             | `X-ROS-Auth-Method` | "Envoy-Native-JWT"         |
| Authorization header | `X-Bearer-Token`    | JWT token without "Bearer" |

## Testing

### Upload with JWT

```bash
# Get JWT token from Keycloak
TOKEN=$(curl -s -k -X POST \
  "https://keycloak-rhsso.apps.example.com/auth/realms/kubernetes/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials" \
  -d "client_id=cost-management-operator" \
  -d "client_secret=$CLIENT_SECRET" \
  | jq -r '.access_token')

# Upload file with JWT
curl -F "file=@payload.tar.gz;type=application/vnd.redhat.hccm.filename+tgz" \
  -H "Authorization: Bearer $TOKEN" \
  "http://ros-ocp-ingress-ros-ocp.apps.example.com/api/ingress/v1/upload"
```

### Automated Test Script

Use the provided test script to verify end-to-end JWT authentication:

```bash
cd scripts
./test-ocp-dataflow-jwt.sh
```

This script:
1. Auto-detects Keycloak configuration
2. Obtains JWT token using client credentials
3. Creates test payload with `manifest.json` and CSV data
4. Uploads using JWT Bearer authentication
5. Verifies processing in ingress and backend services

## Payload Requirements

The ROS ingress service expects tar.gz archives with:

1. **manifest.json** (required):
```json
{
  "uuid": "<unique-id>",
  "cluster_id": "<cluster-id>",
  "cluster_alias": "test-cluster",
  "date": "2025-10-14T00:00:00Z",
  "files": ["openshift_usage_report.csv"],
  "resource_optimization_files": ["openshift_usage_report.csv"],
  "certified": true,
  "operator_version": "1.0.0"
}
```

2. **CSV file(s)**: Listed in `resource_optimization_files`

## Troubleshooting

### Check Envoy logs

```bash
oc logs -n ros-ocp -l app.kubernetes.io/name=ingress -c envoy-proxy
```

Look for:
- `JWT authenticated: <user-id>` - Successful authentication
- `Jwt verification fails` - Invalid token or signature
- `Jwks remote fetch is failed` - Cannot reach Keycloak JWKS endpoint

### Check ingress logs

```bash
oc logs -n ros-ocp -l app.kubernetes.io/name=ingress -c ingress
```

Look for:
- `"account":"<id>","org_id":"<id>"` - Authentication headers received
- `"X-ROS-Authenticated header missing"` - Envoy didn't inject headers
- `"no JWT token found"` - Token not forwarded

### Verify JWKS connectivity

```bash
# Port-forward to Envoy admin
oc port-forward -n ros-ocp deployment/ros-ocp-ingress 9901:9901

# Check cluster status
curl http://localhost:9901/clusters | grep keycloak_jwks
```

Should show `cx_active` connections to Keycloak.

### Test JWT manually

```bash
# Decode JWT to check claims
echo "$TOKEN" | cut -d'.' -f2 | base64 -d | jq

# Verify audience matches configuration
# Should contain "account" or "cost-management-operator"
```

## Security Considerations

### Production Deployments

1. **Use proper TLS certificates** - Don't skip certificate verification
2. **Restrict audiences** - Only allow expected client IDs
3. **Monitor token expiry** - Default is 5 minutes (300 seconds)
4. **Rotate client secrets** - Regularly update Keycloak client credentials

### Development/Testing

- The current configuration accepts self-signed certificates from Keycloak
- In production, use properly signed certificates from your PKI

## Migration from Authorino

If you previously used Authorino, the migration is automatic:

1. **Update Helm chart** - Pull latest changes
2. **Redeploy** - `helm upgrade ros-ocp ./ros-ocp`
3. **Verify** - Authorino pods will be removed, Envoy sidecar remains

**No changes required to:**
- Backend services (still receive same X-ROS headers)
- Client applications (still send same JWT tokens)
- Keycloak configuration

## References

- [Envoy JWT Authentication](https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/filters/http/jwt_authn/v3/config.proto)
- [Envoy Lua Filter](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/lua_filter)
- [Keycloak Client Credentials Flow](https://www.keycloak.org/docs/latest/securing_apps/index.html#_client_credentials_grant)

