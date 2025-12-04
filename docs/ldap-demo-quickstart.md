# LDAP Integration Demo - Quick Start Guide

This guide provides step-by-step instructions to deploy and test the complete LDAP → Keycloak → OpenShift → Authorino integration for extracting `org_id` and `account_number` from user groups.

## Overview

```
┌─────────────────────────────┐   Federation   ┌────────────────────────┐   OAuth    ┌────────────┐
│   LDAP (Clean Values)       │───────────────>│  Keycloak (Adds Paths) │───────────>│ OpenShift  │
│                             │                 │                        │            │   OAuth    │
│ cn=engineering              │                 │ Group:                 │            │ groups:    │
│ organizationId: 1234567 ────┼────────────────>│ /organizations/1234567 │───────────>│ - /org.../│
│ accountNumber: 9876543 ─────┼────────────────>│ /accounts/9876543      │            │ - /acc.../│
│ member: test                │                 │                        │            │            │
└─────────────────────────────┘                 └────────────────────────┘            └────────────┘
                                                                                              │
                                                           TokenReview                        │
                                                                ↓                             ↓
                                                         ┌───────────┐              ┌─────────────┐
                                                         │ Authorino │              │    Envoy    │
                                                         │  Parses:  │─────────────>│   Builds    │
                                                         │  org_id   │   Headers    │X-Rh-Identity│
                                                         │  account  │              │             │
                                                         └───────────┘              └─────────────┘
```

**Key Points:**
- LDAP stores **clean numeric values** (just "1234567", not "org_1234567")
- OU structure provides semantic meaning (ou=organizations vs ou=accounts)
- Keycloak adds path context ("/organizations/" and "/accounts/")
- Authorino parses paths to extract values
- Backend gets separate org_id and account_number

## Prerequisites

- OpenShift cluster access with admin privileges
- `oc` CLI installed and logged in
- Keycloak deployed (via `scripts/deploy-rhbk.sh`)
- Cost Management Helm chart deployed
- `curl` and `jq` installed

## Step 1: Deploy OpenLDAP Demo Server

The LDAP server contains the test organization structure with users and groups.

```bash
cd /path/to/ros-helm-chart
./scripts/deploy-ldap-demo.sh keycloak
```

**What it does:**
- Deploys OpenLDAP server in the `keycloak` namespace
- Creates directory structure: `dc=cost-mgmt,dc=local`
- Adds test users: `test` (password: test), `admin` (password: admin)
- Creates organization groups with `businessCategory` attribute:
  - `cn=org-1234567` (businessCategory: 1234567)
  - `cn=org-7890123` (businessCategory: 7890123)
- Creates account groups:
  - `cn=account_9876543` (for test user)
  - `cn=account_7890123` (for admin user)

**Expected output:**
```
✓ OpenLDAP Demo Server Deployed Successfully

LDAP Server Details:
  Namespace:        keycloak
  Service:          openldap-demo.keycloak.svc.cluster.local
  Port:             1389
  Base DN:          dc=cost-mgmt,dc=local
  Admin Password:   admin123

Test Users:
  User: test
    Expected Mapping:
      org_id: 1234567
      account_number: 9876543
```

**Verification:**
```bash
# Get LDAP pod name
POD=$(oc get pod -n keycloak -l app=openldap-demo -o jsonpath='{.items[0].metadata.name}')

# Test LDAP search for test user
oc exec -n keycloak $POD -- \
  ldapsearch -x -H ldap://localhost:1389 \
  -D "cn=admin,dc=cost-mgmt,dc=local" \
  -w "admin123" \
  -b "ou=users,dc=cost-mgmt,dc=local" \
  "(uid=test)" dn cn mail

# Expected output:
# dn: uid=test,ou=users,dc=cost-mgmt,dc=local
# cn: cost mgmt test
# mail: cost@mgmt.net

# Test LDAP search for organization groups
oc exec -n keycloak $POD -- \
  ldapsearch -x -H ldap://localhost:1389 \
  -D "cn=admin,dc=cost-mgmt,dc=local" \
  -w "admin123" \
  -b "ou=groups,dc=cost-mgmt,dc=local" \
  "(cn=org-*)" dn businessCategory member

# Expected output:
# dn: cn=org-1234567,ou=groups,dc=cost-mgmt,dc=local
# businessCategory: 1234567
# member: uid=test,ou=users,dc=cost-mgmt,dc=local
```

## Step 2: Configure Keycloak LDAP Federation

This script configures Keycloak to import users from LDAP and map groups.

```bash
./scripts/configure-keycloak-ldap.sh keycloak kubernetes
```

**What it does:**
- Creates LDAP User Federation in Keycloak
- Configures connection to `openldap-demo` service
- Creates two LDAP Group Mappers:
  1. **Organization Groups Mapper**: Maps `businessCategory` → Keycloak group name
     - Filter: `(cn=org-*)`
     - Result: Group "1234567" (from businessCategory)
  2. **Account Groups Mapper**: Maps `cn` → Keycloak group name
     - Filter: `(cn=account_*)`
     - Result: Group "account_9876543" (from cn)
- Synchronizes users from LDAP to Keycloak

**Expected output:**
```
✓ Keycloak LDAP Federation Configured Successfully

LDAP Mappers:
  1. Organization Groups Mapper
     - Maps LDAP attribute: businessCategory → Keycloak group name
     - Example: businessCategory=1234567 → Group "1234567"

  2. Account Groups Mapper
     - Maps LDAP attribute: cn → Keycloak group name
     - Example: cn=account_9876543 → Group "account_9876543"

User "test" should have groups:
  - 1234567
  - account_9876543
```

**Verification:**
```bash
# Get Keycloak URL
KEYCLOAK_URL=$(oc get route keycloak -n keycloak -o jsonpath='{.spec.host}')

# Open Keycloak Admin Console
echo "https://${KEYCLOAK_URL}/admin/master/console/#/kubernetes/users"

# Login with admin credentials:
# Username: admin
# Password: (get from secret)
oc get secret keycloak-initial-admin -n keycloak -o jsonpath='{.data.password}' | base64 -d

# In Keycloak Admin Console:
# 1. Go to Users
# 2. Search for "test"
# 3. Click on the user
# 4. Go to "Groups" tab
# 5. Verify user has groups: "1234567" and "account_9876543"
```

## Step 3: Test OpenShift OAuth Integration

Now test that groups flow through to OpenShift after user login.

```bash
# 1. Get OpenShift Console URL
CONSOLE_URL=$(oc whoami --show-console)
echo "OpenShift Console: $CONSOLE_URL"

# 2. Login to OpenShift Console
# - Navigate to console URL
# - Click "keycloak" login option
# - Username: test
# - Password: test

# 3. Check OpenShift User object (as admin)
oc get user test -o yaml

# Expected output:
# apiVersion: user.openshift.io/v1
# fullName: cost mgmt test
# groups:
# - "1234567"
# - "account_9876543"
# identities:
# - keycloak:xxxx-xxxx-xxxx
# kind: User
# metadata:
#   name: test
```

**If groups are null:**

Check OpenShift OAuth logs:
```bash
oc logs -n openshift-authentication deployment/oauth-openshift | grep -i group
```

Common issues:
- Missing groups mapper in Keycloak "openshift" client
- Groups not included in userinfo token
- OAuth pods need restart

**Fix:**
```bash
# Restart OAuth pods to pick up new groups
oc delete pod -n openshift-authentication -l app=oauth-openshift

# Wait for pods to restart
oc wait --for=condition=ready pod -l app=oauth-openshift -n openshift-authentication --timeout=120s

# Delete and recreate user to force re-sync
oc delete user test
oc delete identity $(oc get identity -o name | grep keycloak | grep test)

# Login again via console
```

## Step 4: Deploy Updated Cost Management with LDAP Integration

Deploy the Cost Management chart with the updated Authorino and Envoy configurations.

```bash
# If chart is already deployed, upgrade it
helm upgrade cost-onprem ./cost-onprem \
  --namespace cost-mgmt \
  --reuse-values

# Or install fresh
helm install cost-onprem ./cost-onprem \
  --namespace cost-mgmt \
  --values cost-onprem/values.yaml

# Wait for pods to be ready
oc wait --for=condition=ready pod -l app.kubernetes.io/name=cost-onprem -n cost-mgmt --timeout=300s
```

## Step 5: Test End-to-End Flow

Now test the complete flow from user login to API request with proper `org_id` extraction.

### Test 1: Check Authorino Configuration

```bash
# Verify AuthConfig is applied
oc get authconfig -n cost-mgmt

# Expected output:
# NAME                           READY   STATUS
# cost-onprem-ros-api-auth      True    AuthConfig ready

# Check AuthConfig details
oc get authconfig cost-onprem-ros-api-auth -n cost-mgmt -o yaml

# Should see:
# metadata:
#   parse-org-claims:
#     opa:
#       inlineRego: |
#         # ... Rego policy for parsing groups ...
```

### Test 2: Make API Request with User Token

```bash
# Get user token (login as test user first via console)
TOKEN=$(oc whoami -t)

# Make API request to ROS API
curl -v -H "Authorization: Bearer $TOKEN" \
  https://$(oc get route ros-api -n cost-mgmt -o jsonpath='{.spec.host}')/api/cost-management/v1/status \
  2>&1 | tee /tmp/api-request.log

# Check the logs for X-Rh-Identity header
```

### Test 3: Check Authorino Logs

```bash
# View Authorino logs to see claim extraction
oc logs -n cost-mgmt deployment/cost-onprem-authorino -f | grep -A 10 "parse-org-claims"

# Expected log entries:
# - TokenReview successful for user "test"
# - Extracted org_id: "1234567"
# - Extracted account_number: "9876543"
```

### Test 4: Check Envoy Logs

```bash
# View Envoy sidecar logs in ROS API pod
POD=$(oc get pod -n cost-mgmt -l app.kubernetes.io/component=ros-api -o jsonpath='{.items[0].metadata.name}')

oc logs -n cost-mgmt $POD -c envoy -f | grep -i "x-rh-identity\|org_id"

# Expected log entries:
# - Built X-Rh-Identity for user=test, org_id=1234***
# - Request with valid org_id
```

### Test 5: Decode X-Rh-Identity Header

If you can capture the X-Rh-Identity header from the backend:

```bash
# Example header value (base64 encoded)
XRHID="eyJpZGVudGl0eSI6eyJvcmdfaWQiOiIxMjM0NTY3IiwiYWNjb3VudF9udW1iZXIiOiI5ODc2NTQzIiwidHlwZSI6IlVzZXIiLCJ1c2VyIjp7InVzZXJuYW1lIjoidGVzdCJ9fX0="

# Decode it
echo "$XRHID" | base64 -d | jq .

# Expected output:
# {
#   "identity": {
#     "org_id": "1234567",
#     "account_number": "9876543",
#     "type": "User",
#     "user": {
#       "username": "test",
#       ...
#     },
#     "internal": {
#       "org_id": "1234567",
#       "auth_type": "kubernetes-tokenreview",
#       ...
#     }
#   }
# }
```

## Troubleshooting

### Issue: User not found in Keycloak

**Check:**
```bash
# Resync users from LDAP
./scripts/configure-keycloak-ldap.sh keycloak kubernetes
```

### Issue: Groups are null in OpenShift User

**Check:**
1. Keycloak "openshift" client has groups mapper:
   ```bash
   # Via Keycloak Admin Console:
   # Clients → openshift → Client scopes → Dedicated scopes → openshift-dedicated
   # Check for "groups" mapper
   ```

2. OpenShift OAuth configuration includes groups claim:
   ```bash
   oc get oauth cluster -o yaml | grep -A 10 "groups:"
   ```

3. Restart OAuth pods:
   ```bash
   oc delete pod -n openshift-authentication -l app=oauth-openshift
   ```

### Issue: Authorino not extracting org_id

**Check:**
1. Authorino AuthConfig has OPA metadata section
2. User actually has numeric groups in OpenShift
3. Authorino logs for errors

**Debug:**
```bash
# Check user groups
oc get user test -o jsonpath='{.groups}'

# Expected: ["1234567", "account_9876543"]

# Check Authorino logs
oc logs -n cost-mgmt deployment/cost-onprem-authorino | grep -i "parse-org-claims\|error"
```

### Issue: Envoy returns 401 Unauthorized

**Check:**
1. Token is valid: `oc whoami`
2. Authorino is running: `oc get pod -n cost-mgmt -l app=authorino`
3. Envoy can reach Authorino: Check Envoy logs for connection errors

**Debug:**
```bash
# Check Envoy logs
oc logs -n cost-mgmt $POD -c envoy | grep -i "authorino\|ext_authz\|401"
```

## Expected Results

### Successful Flow

1. **LDAP**: User `test` is member of `cn=org-1234567` (businessCategory: 1234567) and `cn=account_9876543`
2. **Keycloak**: Imports user, creates groups "1234567" and "account_9876543"
3. **OpenShift**: User object has `groups: ["1234567", "account_9876543"]`
4. **Authorino**: Parses groups, extracts:
   - `org_id: "1234567"` (first numeric group)
   - `account_number: "9876543"` (from "account_9876543", removes prefix)
5. **Envoy**: Receives headers from Authorino, builds X-Rh-Identity with correct values
6. **Backend**: Receives request with X-Rh-Identity containing:
   ```json
   {
     "identity": {
       "org_id": "1234567",
       "account_number": "9876543",
       "type": "User",
       "user": {"username": "test"}
     }
   }
   ```

## Demonstration Points for Technical Lead

### 1. Show LDAP Structure
```bash
oc exec -n keycloak deployment/openldap-demo -- \
  ldapsearch -x -H ldap://localhost:1389 \
  -D "cn=admin,dc=cost-mgmt,dc=local" -w "admin123" \
  -b "dc=cost-mgmt,dc=local" "(objectClass=*)" dn | grep "^dn:"
```

### 2. Show Keycloak Group Mapping
- Open Keycloak Admin Console
- Navigate to Users → test → Groups
- Show groups: "1234567", "account_9876543"

### 3. Show OpenShift User Groups
```bash
oc get user test -o yaml
# Highlight groups field
```

### 4. Show Authorino OPA Policy
```bash
oc get authconfig cost-onprem-ros-api-auth -n cost-mgmt -o yaml
# Highlight metadata.parse-org-claims section
```

### 5. Show Envoy Lua Filter
```bash
oc get configmap cost-onprem-envoy-config-ros-api -n cost-mgmt -o yaml
# Highlight Lua code that reads x-auth-org-id header
```

### 6. Live API Request
```bash
# Login as test user, get token
TOKEN=$(oc whoami -t)

# Make request with verbose output
curl -v -H "Authorization: Bearer $TOKEN" \
  https://$(oc get route ros-api -n cost-mgmt -o jsonpath='{.spec.host}')/api/cost-management/v1/status \
  2>&1 | grep -i "< \|org_id"
```

## Cleanup

To remove the demo LDAP server:

```bash
# Delete LDAP deployment
oc delete deployment,service,configmap,secret -n keycloak -l app=openldap-demo

# Remove LDAP federation from Keycloak
# (Via Keycloak Admin Console: User Federation → openldap-demo → Remove)

# Delete test user from OpenShift
oc delete user test
oc delete identity $(oc get identity -o name | grep keycloak | grep test)
```

## Next Steps

After successful demonstration:

1. Deploy production LDAP server with actual organization data
2. Update LDAP schema to use custom attributes (see ADR 0001)
3. Configure Keycloak LDAP federation for production realm
4. Test with multiple users and organizations
5. Set up monitoring and alerting for authentication flow
6. Document operational procedures

## Related Documentation

- [ADR 0001: LDAP Organization ID Mapping](../docs/adr/0001-ldap-organization-id-mapping.md)
- [Authorino Integration Guide](../docs/authorino-ldap-integration.md)
- [Cost Management Installation Guide](../docs/installation.md)

