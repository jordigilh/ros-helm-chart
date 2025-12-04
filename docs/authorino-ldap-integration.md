# Authorino Integration with LDAP-Based Organization ID Mapping

## Overview

This document explains how to extract `org_id` and `account_number` from LDAP-mapped Keycloak groups using Authorino and inject them into the request flow via Envoy.

**Architecture Flow:**
```
LDAP Groups                Keycloak              OpenShift OAuth        Authorino              Envoy                Backend
─────────────              ────────              ───────────────        ─────────              ─────                ───────
organizationId: 1234567 →  Group: "1234567"  →  TokenReview:      →  Parse groups:     →  Lua filter:     →  X-Rh-Identity:
accountNumber: 7890123                           groups: ["1234567"]   org_id: 1234567      Use headers         org_id: 1234567
                                                                       account: 7890123                         account: 7890123
```

## Current Implementation (Hardcoded)

### Current Authorino Configuration

```yaml:36:42:cost-onprem/templates/auth/authorino-authconfig.yaml
        "X-Auth-Username":
          plain:
            selector: auth.identity.username
        "X-Auth-Uid":
          plain:
            selector: auth.identity.uid
```

Authorino currently returns only:
- `X-Auth-Username` (e.g., "test")
- `X-Auth-Uid` (e.g., "17b8bf47-cb05-44fc-a3cc-93eb9a89180a")

### Current Envoy Lua Filter (Hardcoded)

```yaml:142:164:cost-onprem/templates/ros/api/envoy-config.yaml
                        -- Build rh-identity JSON structure
                        local identity_json = string.format([[{
                          "identity": {
                            "org_id": "1",
                            "account_number": "1",
                            "type": "User",
                            "user": {
                              "username": "%s",
                              "email": "",
                              "first_name": "",
                              "last_name": "",
                              "is_active": true,
                              "is_org_admin": false,
                              "is_internal": false,
                              "locale": "en_US"
                            },
                            "internal": {
                              "org_id": "1",
                              "auth_type": "kubernetes-tokenreview",
                              "auth_time": 0
                            }
                          }
                        }]], username_escaped)
```

**Problem:** `org_id` and `account_number` are hardcoded to `"1"`.

## Solution Architecture

### Component Responsibilities

1. **LDAP**: Stores groups with custom attributes (`organizationId`, `accountNumber`)
2. **Keycloak**: Imports LDAP groups, maps `organizationId` → Keycloak group name
3. **OpenShift OAuth**: Returns groups in TokenReview API response
4. **Authorino**: Parses groups to extract `org_id` and `account_number`, returns as headers
5. **Envoy Lua Filter**: Reads headers from Authorino, builds `X-Rh-Identity`

### Integration Points

```
┌─────────────────────────────────────────────────────────────────────┐
│  LDAP Group                                                          │
│  dn: cn=engineering,ou=groups,dc=example,dc=com                     │
│  organizationId: 1234567                                            │
│  accountNumber: 7890123                                             │
│  member: uid=test,ou=users,dc=example,dc=com                        │
└─────────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────────┐
│  Keycloak LDAP Group Mapper                                         │
│  Group Name LDAP Attribute: organizationId                          │
│  Result: Keycloak group "1234567"                                   │
│  User "test" is member of group "1234567"                           │
└─────────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────────┐
│  OpenShift OAuth Login                                              │
│  User logs in via OpenShift Console → Keycloak OIDC                │
│  OpenShift creates User object with groups: ["1234567"]            │
└─────────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────────┐
│  API Request with OAuth Token                                       │
│  Authorization: Bearer sha256~xxxxxxxxxxxxxxxxxxxxx                 │
└─────────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────────┐
│  Envoy (External Authorization Request)                             │
│  Forwards token to Authorino via gRPC                               │
└─────────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────────┐
│  Authorino (Kubernetes TokenReview)                                 │
│  1. Validates token via TokenReview API                             │
│  2. Receives: username="test", groups=["1234567"]                   │
│  3. Parses group "1234567" → org_id                                 │
│  4. Returns headers:                                                │
│     - X-Auth-Username: test                                         │
│     - X-Auth-Org-Id: 1234567                                        │
│     - X-Auth-Account-Number: 7890123                                │
└─────────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────────┐
│  Envoy Lua Filter                                                   │
│  1. Reads headers from Authorino                                    │
│  2. Builds X-Rh-Identity JSON:                                      │
│     {                                                               │
│       "identity": {                                                 │
│         "org_id": "1234567",                                        │
│         "account_number": "7890123",                                │
│         "user": {"username": "test"}                                │
│       }                                                             │
│     }                                                               │
│  3. Base64 encodes and injects header                               │
└─────────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────────┐
│  Backend Service                                                    │
│  Receives X-Rh-Identity with correct org_id and account_number     │
└─────────────────────────────────────────────────────────────────────┘
```

## Implementation

### Step 1: Update Authorino AuthConfig

Modify the AuthConfig to extract and parse groups from TokenReview.

#### Option A: Single Group Pattern (Simplest)

Assumes users belong to exactly one organization group.

**File:** `cost-onprem/templates/auth/authorino-authconfig.yaml`

```yaml
{{- if eq (include "cost-onprem.jwt.shouldEnable" .) "true" }}
apiVersion: authorino.kuadrant.io/v1beta3
kind: AuthConfig
metadata:
  name: {{ include "cost-onprem.fullname" . }}-ros-api-auth
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "cost-onprem.labels" . | nindent 4 }}
    app.kubernetes.io/component: authorino-authconfig
spec:
  hosts:
    - "*"

  # Authentication: Validate Kubernetes tokens via TokenReview
  authentication:
    "kubernetes-tokens":
      kubernetesTokenReview:
        audiences:
          - "https://kubernetes.default.svc"

  # Metadata: Extract org_id and account_number from groups
  metadata:
    "extract-claims":
      http:
        url: "http://localhost:8080/parse-groups"  # Internal helper endpoint
        method: POST
        body:
          selector: |
            {
              "username": auth.identity.username,
              "groups": auth.identity.groups
            }
        contentType: application/json
        cache:
          key:
            selector: auth.identity.username
          ttl: 300  # Cache for 5 minutes

  # Response: Inject extracted claims as headers
  response:
    success:
      headers:
        "X-Auth-Username":
          plain:
            selector: auth.identity.username
        "X-Auth-Uid":
          plain:
            selector: auth.identity.uid
        "X-Auth-Org-Id":
          json:
            selector: auth.metadata.extract-claims.org_id
        "X-Auth-Account-Number":
          json:
            selector: auth.metadata.extract-claims.account_number
{{- end }}
```

#### Option B: OPA/Rego Inline Processing (Self-Contained)

Use Open Policy Agent (OPA) Rego to parse groups directly in Authorino (no external service).

**File:** `cost-onprem/templates/auth/authorino-authconfig.yaml`

```yaml
{{- if eq (include "cost-onprem.jwt.shouldEnable" .) "true" }}
apiVersion: authorino.kuadrant.io/v1beta3
kind: AuthConfig
metadata:
  name: {{ include "cost-onprem.fullname" . }}-ros-api-auth
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "cost-onprem.labels" . | nindent 4 }}
    app.kubernetes.io/component: authorino-authconfig
spec:
  hosts:
    - "*"

  # Authentication: Validate Kubernetes tokens via TokenReview
  authentication:
    "kubernetes-tokens":
      kubernetesTokenReview:
        audiences:
          - "https://kubernetes.default.svc"

  # Metadata: Parse groups using OPA/Rego
  metadata:
    "parse-org-claims":
      opa:
        inlineRego: |
          package authz

          import future.keywords.if
          import future.keywords.in

          # Extract org_id from groups
          # Looks for first group that matches numeric pattern
          org_id := group if {
            some group in input.auth.identity.groups
            # Numeric group names are org IDs
            regex.match(`^[0-9]+$`, group)
          }

          # Default org_id if no numeric group found
          default org_id := ""

          # Extract account_number from groups
          # Looks for groups with pattern "account_<number>"
          account_number := substring(group, 8, -1) if {
            some group in input.auth.identity.groups
            startswith(group, "account_")
          }

          # Fallback: Use org_id as account_number if no specific account group
          default account_number := org_id

  # Response: Inject extracted claims as headers
  response:
    success:
      headers:
        "X-Auth-Username":
          plain:
            selector: auth.identity.username
        "X-Auth-Uid":
          plain:
            selector: auth.identity.uid
        "X-Auth-Org-Id":
          json:
            selector: auth.metadata.parse-org-claims.org_id
        "X-Auth-Account-Number":
          json:
            selector: auth.metadata.parse-org-claims.account_number
{{- end }}
```

**Rego Policy Explanation:**

```rego
# This policy extracts org_id and account_number from user groups

# org_id: First numeric group (e.g., "1234567")
org_id := group if {
  some group in input.auth.identity.groups
  regex.match(`^[0-9]+$`, group)  # Pure numeric = org_id
}

# account_number: Group with "account_" prefix (e.g., "account_7890123")
# Extract the number after the prefix
account_number := substring(group, 8, -1) if {
  some group in input.auth.identity.groups
  startswith(group, "account_")
}

# Fallback: If no account group, use org_id
default account_number := org_id
```

#### Option C: Multiple Groups with Priority (Production-Ready)

Supports users with multiple organization memberships.

**LDAP Structure:**
```ldif
# User belongs to multiple organizations
dn: uid=test,ou=users,dc=example,dc=com
memberOf: cn=org1,ou=groups,dc=example,dc=com      # organizationId: 1234567
memberOf: cn=org2,ou=groups,dc=example,dc=com      # organizationId: 7890123
memberOf: cn=admins,ou=groups,dc=example,dc=com    # Not an org group
```

**Authorino Configuration:**

```yaml
metadata:
  "parse-org-claims":
    opa:
      inlineRego: |
        package authz

        import future.keywords.if
        import future.keywords.in

        # Extract all numeric groups (organization IDs)
        org_ids := [group |
          some group in input.auth.identity.groups
          regex.match(`^[0-9]+$`, group)
        ]

        # Primary org_id: First in list (or from X-Requested-Org-Id header)
        org_id := requested_org if {
          requested_org := input.context.request.http.headers["x-requested-org-id"]
          requested_org in org_ids
        } else := org_ids[0] if {
          count(org_ids) > 0
        }

        default org_id := ""

        # Extract account_number groups
        account_numbers := [substring(group, 8, -1) |
          some group in input.auth.identity.groups
          startswith(group, "account_")
        ]

        # Use first account number or fallback to org_id
        account_number := account_numbers[0] if {
          count(account_numbers) > 0
        } else := org_id

        # Export all available org_ids for auditing
        available_orgs := org_ids
```

**Features:**
- ✅ Supports multiple organization memberships
- ✅ Client can specify desired org via `X-Requested-Org-Id` header
- ✅ Validates that requested org is in user's groups
- ✅ Falls back to first org if no preference specified
- ✅ Returns all available orgs for frontend display

### Step 2: Update Envoy Lua Filter

Modify the Lua filter to use headers from Authorino instead of hardcoded values.

**File:** `cost-onprem/templates/ros/api/envoy-config.yaml`

Replace the existing Lua filter (lines 114-176) with:

```yaml
              # Lua filter to build rh-identity header from Authorino claims
              - name: envoy.filters.http.lua
                typed_config:
                  "@type": type.googleapis.com/envoy.extensions.filters.http.lua.v3.Lua
                  inline_code: |
                    -- Escape special characters for JSON strings
                    function escape_json(str)
                      if str == nil then
                        return ""
                      end
                      str = string.gsub(str, '\\', '\\\\')
                      str = string.gsub(str, '"', '\\"')
                      str = string.gsub(str, '\n', '\\n')
                      str = string.gsub(str, '\r', '\\r')
                      str = string.gsub(str, '\t', '\\t')
                      return str
                    end

                    function envoy_on_request(request_handle)
                      -- Get claims from Authorino headers
                      local username = request_handle:headers():get("x-auth-username")
                      local org_id = request_handle:headers():get("x-auth-org-id")
                      local account_number = request_handle:headers():get("x-auth-account-number")

                      -- Validation: Ensure required claims are present
                      if username == nil or username == "" then
                        request_handle:logWarn("Missing x-auth-username from Authorino")
                        request_handle:respond(
                          {[":status"] = "401"},
                          "Unauthorized: Missing username"
                        )
                        return
                      end

                      if org_id == nil or org_id == "" then
                        request_handle:logWarn("Missing x-auth-org-id from Authorino")
                        request_handle:respond(
                          {[":status"] = "401"},
                          "Unauthorized: Missing organization ID"
                        )
                        return
                      end

                      -- Fallback: Use org_id if account_number is missing
                      if account_number == nil or account_number == "" then
                        account_number = org_id
                        request_handle:logInfo("Using org_id as account_number (no separate account group)")
                      end

                      -- Escape values for safe JSON embedding
                      local username_escaped = escape_json(username)
                      local org_id_escaped = escape_json(org_id)
                      local account_number_escaped = escape_json(account_number)

                      -- Build rh-identity JSON structure
                      local identity_json = string.format([[{
                        "identity": {
                          "org_id": "%s",
                          "account_number": "%s",
                          "type": "User",
                          "user": {
                            "username": "%s",
                            "email": "",
                            "first_name": "",
                            "last_name": "",
                            "is_active": true,
                            "is_org_admin": false,
                            "is_internal": false,
                            "locale": "en_US"
                          },
                          "internal": {
                            "org_id": "%s",
                            "auth_type": "kubernetes-tokenreview",
                            "auth_time": 0
                          }
                        }
                      }]], org_id_escaped, account_number_escaped, username_escaped, org_id_escaped)

                      -- Base64 encode the JSON
                      local b64_identity = request_handle:base64Escape(identity_json)

                      -- Set the X-Rh-Identity header
                      request_handle:headers():add("x-rh-identity", b64_identity)

                      -- Remove temporary Authorino headers (cleanup)
                      request_handle:headers():remove("x-auth-username")
                      request_handle:headers():remove("x-auth-uid")
                      request_handle:headers():remove("x-auth-org-id")
                      request_handle:headers():remove("x-auth-account-number")

                      -- Log for debugging (redact sensitive data)
                      local masked_org = string.sub(org_id, 1, 4) .. "***"
                      request_handle:logInfo(string.format(
                        "Built X-Rh-Identity for user=%s, org_id=%s",
                        username, masked_org
                      ))
                    end
```

**Key Changes:**
1. **Read from Headers**: `request_handle:headers():get("x-auth-org-id")` instead of hardcoded value
2. **Validation**: Check that org_id is present before proceeding
3. **Fallback**: Use org_id as account_number if separate account group is missing
4. **Cleanup**: Remove temporary Authorino headers after use
5. **Logging**: Enhanced logging for debugging

### Step 3: LDAP Group Structure

Ensure your LDAP groups follow the expected structure.

#### For org_id Only (Simplest)

```ldif
dn: cn=engineering,ou=groups,dc=example,dc=com
objectClass: costManagementGroup
cn: engineering
organizationId: 1234567        # Keycloak maps this to group name
member: uid=test,ou=users,dc=example,dc=com

dn: cn=finance,ou=groups,dc=example,dc=com
objectClass: costManagementGroup
cn: finance
organizationId: 7890123
member: uid=admin,ou=users,dc=example,dc=com
```

**Keycloak Result:**
- User "test" has group: `["1234567"]`
- Authorino extracts: `org_id: "1234567"`, `account_number: "1234567"`

#### For org_id + account_number (Production)

```ldif
# Organization group
dn: cn=engineering,ou=groups,dc=example,dc=com
objectClass: costManagementGroup
cn: engineering
organizationId: 1234567
member: uid=test,ou=users,dc=example,dc=com

# Account group (if different from org)
dn: cn=account_7890123,ou=groups,dc=example,dc=com
objectClass: groupOfNames
cn: account_7890123
member: uid=test,ou=users,dc=example,dc=com
```

**Keycloak Result:**
- User "test" has groups: `["1234567", "account_7890123"]`
- Authorino extracts: `org_id: "1234567"`, `account_number: "7890123"`

### Step 4: Configure Keycloak LDAP Mappers

1. **LDAP User Federation**:
   ```
   Connection URL: ldap://ldap-server:389
   Users DN: ou=users,dc=example,dc=com
   Bind Type: simple
   Bind DN: cn=admin,dc=example,dc=com
   ```

2. **LDAP Group Mapper**:
   ```
   Mapper Type: group-ldap-mapper
   Name: Organization Groups
   LDAP Groups DN: ou=groups,dc=example,dc=com
   Group Name LDAP Attribute: organizationId    ← Key setting
   Member Attribute: member
   Membership LDAP Attribute: member
   Mode: READ_ONLY
   User Groups Retrieve Strategy: LOAD_GROUPS_BY_MEMBER_ATTRIBUTE
   ```

3. **Test Import**:
   - Go to User Federation → Your LDAP → Synchronize all users
   - Check Users → View user "test" → Groups
   - Should see group: "1234567"

## Testing

### Test 1: Verify LDAP → Keycloak Import

```bash
# In Keycloak Admin Console
# Users → test → Groups
# Expected: "1234567"
```

### Test 2: Verify OpenShift User Groups

```bash
# Login as test user via OpenShift Console
# Then as admin:
oc get user test -o yaml

# Expected output:
# groups:
# - "1234567"
```

### Test 3: Verify Authorino Headers

```bash
# Add debug logging to Authorino
kubectl logs -n cost-mgmt deployment/cost-onprem-authorino -f

# Make API request with test user token
# Check Authorino logs for extracted claims
```

### Test 4: Verify X-Rh-Identity Header

```bash
# Add debug logging to backend
kubectl logs -n cost-mgmt deployment/ros-api -f

# Make API request
# Check backend receives correct X-Rh-Identity with:
# - org_id: "1234567"
# - account_number: "1234567" or "7890123"
```

### Test 5: End-to-End Verification

```bash
# Get OAuth token for test user
TOKEN=$(oc whoami -t)

# Make API request
curl -H "Authorization: Bearer $TOKEN" \
     https://cost-mgmt.apps.example.com/api/cost-management/v1/status \
     -v 2>&1 | grep -i x-rh-identity

# Expected: Base64-encoded JSON with correct org_id
```

## Troubleshooting

### Issue: `X-Auth-Org-Id` header is empty

**Cause:** Authorino's Rego policy didn't find a numeric group.

**Debug:**
```bash
# Check what groups the user has
oc get user test -o jsonpath='{.groups}'

# Check Authorino logs
kubectl logs -n cost-mgmt deployment/cost-onprem-authorino | grep "parse-org-claims"
```

**Solutions:**
- Verify LDAP groups have `organizationId` attribute
- Verify Keycloak Group Mapper uses `organizationId` as Group Name Attribute
- Check user is member of the group in LDAP
- Force sync in Keycloak: User Federation → Sync all users

### Issue: `Unauthorized: Missing organization ID`

**Cause:** Envoy Lua filter didn't receive `x-auth-org-id` header.

**Debug:**
```bash
# Check Envoy logs
kubectl logs -n cost-mgmt deployment/ros-api -c envoy

# Check Authorino AuthConfig is applied
kubectl get authconfig -n cost-mgmt
kubectl describe authconfig cost-onprem-ros-api-auth -n cost-mgmt
```

**Solutions:**
- Verify AuthConfig `metadata` section is configured
- Verify AuthConfig `response.success.headers` includes `X-Auth-Org-Id`
- Restart Authorino: `kubectl rollout restart deployment/cost-onprem-authorino -n cost-mgmt`

### Issue: Groups are null in OpenShift User

**Cause:** OpenShift OAuth didn't receive groups from Keycloak.

**Debug:**
```bash
# Check OAuth logs
oc logs -n openshift-authentication deployment/oauth-openshift

# Check Keycloak "openshift" client has groups mapper
# In Keycloak: Clients → openshift → Client scopes → Evaluate
# Test with user "test", check if "groups" claim is present
```

**Solutions:**
- Add `oidc-group-membership-mapper` to "openshift" client in Keycloak
- Configure mapper to include groups in userinfo: `userinfo.token.claim: true`
- Restart OAuth pods: `oc delete pod -n openshift-authentication -l app=oauth-openshift`

### Issue: Performance - Slow Response Times

**Cause:** Authorino re-evaluating OPA policy on every request.

**Solutions:**
1. **Enable Authorino Caching**:
   ```yaml
   metadata:
     "parse-org-claims":
       opa:
         inlineRego: |
           # ... policy ...
       cache:
         key:
           selector: auth.identity.username
         ttl: 300  # Cache for 5 minutes
   ```

2. **Use External Cache** (Redis):
   ```yaml
   spec:
     metadata:
       "parse-org-claims":
         opa:
           externalRegistry:
             url: "redis://redis:6379"
             ttl: 300
   ```

## Production Considerations

### Security

1. **Group Name Validation**:
   ```rego
   # Add validation in OPA policy
   org_id := group if {
     some group in input.auth.identity.groups
     regex.match(`^[0-9]{7}$`, group)  # Exactly 7 digits
     to_number(group) > 0              # Positive number
   }
   ```

2. **Rate Limiting**:
   - Configure Envoy rate limits to prevent abuse
   - Use Authorino's DDoS protection features

3. **Audit Logging**:
   ```yaml
   # Add to Authorino AuthConfig
   response:
     success:
       headers:
         "X-Auth-Audit-Id":
           plain:
             selector: context.request.http.id
   ```

### Monitoring

1. **Metrics to Track**:
   - Authorino authentication success/failure rate
   - OPA policy evaluation time
   - Cache hit rate
   - Token validation latency

2. **Alerts to Configure**:
   - High authentication failure rate (> 5%)
   - Authorino pod restarts
   - TokenReview API errors

### Scalability

1. **Authorino Horizontal Scaling**:
   ```yaml
   # In Helm values
   authorino:
     replicas: 3
     resources:
       requests:
         cpu: 200m
         memory: 256Mi
       limits:
         cpu: 500m
         memory: 512Mi
   ```

2. **Connection Pooling**:
   - Envoy already configured with circuit breakers
   - Tune `max_connections` based on load

## Migration Path

### Phase 1: Parallel Running (Validation)
- Deploy updated Authorino config
- Keep hardcoded values in Envoy as fallback
- Log both values for comparison
- Verify they match

### Phase 2: Gradual Rollout
- Enable dynamic values for 10% of traffic
- Monitor for errors
- Increase to 50%, then 100%

### Phase 3: Cleanup
- Remove hardcoded fallback
- Remove debug logging

## Related Documentation

- [ADR 0001: LDAP Organization ID Mapping](./adr/0001-ldap-organization-id-mapping.md)
- [Authorino Documentation](https://docs.kuadrant.io/authorino/)
- [Keycloak LDAP Federation](https://www.keycloak.org/docs/latest/server_admin/#_ldap)
- [OpenShift OAuth Configuration](https://docs.openshift.com/container-platform/latest/authentication/configuring-oauth-clients.html)

## Summary

This integration provides:
- ✅ **Automated**: No manual group management
- ✅ **Secure**: No credentials in data plane
- ✅ **Scalable**: Caching and efficient parsing
- ✅ **Maintainable**: Standard LDAP + Keycloak + Authorino
- ✅ **Observable**: Comprehensive logging and monitoring
- ✅ **Flexible**: Supports single or multiple organizations per user

The solution eliminates hardcoded `org_id` values and dynamically extracts them from LDAP-backed Keycloak groups via Authorino's OPA integration.

