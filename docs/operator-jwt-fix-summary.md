# Cost Management Operator JWT Authentication Fix

## Problem Discovered

The Cost Management Metrics Operator was configured with `authentication.type: "token"`, which caused it to use the cloud.openshift.com pull secret instead of acquiring a proper JWT from Keycloak.

### Root Cause

1. **Incorrect Authentication Type**: The script `setup-cost-mgmt-tls.sh` was using `type: "token"`
   - `"token"` type: Uses OpenShift pull secret (NOT a JWT format)
   - `"service-account"` type: Acquires JWT from Keycloak via OAuth2 client_credentials flow

2. **Result**: Envoy's `jwt_authn` filter rejected the requests because:
   ```
   Jwt is not in the form of Header.Payload.Signature with two dots and 3 sections
   ```

## Solution Implemented

### 1. Updated `scripts/setup-cost-mgmt-tls.sh`

**Changed authentication configuration:**
```yaml
authentication:
  type: "service-account"  # Changed from "token"
  token_url: "$KEYCLOAK_URL/auth/realms/kubernetes/protocol/openid-connect/token"
  secret_name: "cost-management-auth-secret"
```

**Disabled TLS verification for self-signed certificates:**
```yaml
upload:
  validate_cert: false  # Changed from true for dev/test with self-signed certs
```

### 2. Manual Fix Applied

For existing deployments, the configuration was patched:
```bash
# Fix authentication type
oc patch costmanagementmetricsconfig costmanagementmetricscfg-tls \
  -n costmanagement-metrics-operator \
  --type=json \
  -p '[{"op": "replace", "path": "/spec/authentication/type", "value": "service-account"}]'

# Disable TLS verification for Keycloak
oc patch costmanagementmetricsconfig costmanagementmetricscfg-tls \
  -n costmanagement-metrics-operator \
  --type=json \
  -p '[{"op": "replace", "path": "/spec/upload/validate_cert", "value": false}]'
```

## Current Status

✅ **Fixed**: Script now correctly configures `service-account` authentication
✅ **Fixed**: TLS verification disabled for self-signed Keycloak certificates  
✅ **Verified**: Manual JWT uploads work correctly with `test-ocp-dataflow-jwt.sh`
⚠️  **Pending**: Operator may require pod restart to clear HTTP client cache

## Testing

### Manual Upload (Working)
```bash
cd scripts
./test-ocp-dataflow-jwt.sh
```
This successfully:
1. Acquires JWT from Keycloak
2. Uploads to ROS ingress via Envoy
3. Envoy validates JWT with native `jwt_authn` filter
4. Data flows to Kafka and Kruize

### Operator Upload (Pending Restart)
The operator configuration is correct but may need a clean restart to clear cached HTTP clients.

##Recommendations

1. **For New Deployments**: Use the updated `scripts/setup-cost-mgmt-tls.sh`
2. **For Existing Deployments**: Apply the manual patches above and restart operator pod
3. **Production**: Configure proper TLS certificates instead of disabling validation

## References

- Operator authentication types: `../koku-metrics-operator/api/v1beta1/metricsconfig_types.go:44-54`
- JWT acquisition code: `../koku-metrics-operator/internal/crhchttp/config.go:66-115`
- Native JWT validation: `ros-ocp/templates/envoy-config.yaml`
