# LDAP and RHBK Configuration Guide for Cost Management

This guide explains how to configure LDAP and Red Hat Build of Keycloak (RHBK) to enable `org_id` and `account_number` extraction from user profiles for the Cost Management on-premise deployment.

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Prerequisites](#prerequisites)
4. [LDAP Configuration](#ldap-configuration)
5. [RHBK Configuration](#rhbk-configuration)
6. [OpenShift OAuth Configuration](#openshift-oauth-configuration)
7. [Verification](#verification)
8. [Troubleshooting](#troubleshooting)

---

## Overview

Cost Management requires `org_id` and `account_number` to identify tenants and isolate data. In on-premise deployments, these values come from your enterprise LDAP directory through the following flow:

```
LDAP → Keycloak → OpenShift OAuth → Authorino → Envoy → Backend
```

### Key Concepts

| Concept | Description |
|---------|-------------|
| `org_id` | Organization identifier (e.g., cost center, department ID) |
| `account_number` | Account identifier (e.g., division, billing account) |
| Group Naming | Groups follow pattern: `cost-mgmt-org-{id}`, `cost-mgmt-account-{id}` |
| CEL Extraction | Authorino uses CEL expressions to parse group names |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           DATA FLOW                                      │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌──────────────┐                                                        │
│  │    LDAP      │  Users have costCenter and accountNumber attributes    │
│  │  (OpenLDAP,  │  Groups: cost-mgmt-org-{id}, cost-mgmt-account-{id}   │
│  │  AD, etc.)   │                                                        │
│  └──────┬───────┘                                                        │
│         │ LDAP Federation                                                │
│         ▼                                                                │
│  ┌──────────────┐                                                        │
│  │   Keycloak   │  Syncs users and groups from LDAP                      │
│  │    (RHBK)    │  Groups mapper imports ou=CostMgmt groups              │
│  │              │  Protocol mapper adds groups to JWT tokens             │
│  └──────┬───────┘                                                        │
│         │ OpenID Connect (Identity Provider)                             │
│         ▼                                                                │
│  ┌──────────────┐                                                        │
│  │  OpenShift   │  User authenticates via Keycloak                       │
│  │    OAuth     │  Creates opaque OAuth access token                     │
│  │              │  Groups flow via OIDC claims                           │
│  └──────┬───────┘                                                        │
│         │ Bearer Token                                                   │
│         ▼                                                                │
│  ┌──────────────┐                                                        │
│  │    Envoy     │  Intercepts API request                                │
│  │   (Sidecar)  │  Forwards to Authorino for validation                  │
│  └──────┬───────┘                                                        │
│         │ ext_authz                                                      │
│         ▼                                                                │
│  ┌──────────────┐                                                        │
│  │  Authorino   │  TokenReview validates OpenShift token                 │
│  │              │  CEL extracts org_id from cost-mgmt-org-* groups       │
│  │              │  CEL extracts account_number from cost-mgmt-account-*  │
│  │              │  Returns X-Auth-Org-Id, X-Auth-Account-Number headers  │
│  └──────┬───────┘                                                        │
│         │                                                                │
│         ▼                                                                │
│  ┌──────────────┐                                                        │
│  │ Envoy Lua    │  Reads Authorino headers                               │
│  │   Filter     │  Constructs X-Rh-Identity JSON                         │
│  │              │  Base64 encodes and sets header                        │
│  └──────┬───────┘                                                        │
│         │                                                                │
│         ▼                                                                │
│  ┌──────────────┐                                                        │
│  │   Backend    │  Receives X-Rh-Identity header                         │
│  │ (ros-ocp-    │  Decodes and extracts org_id, account_number           │
│  │  backend)    │  Uses for multi-tenant data queries                    │
│  └──────────────┘                                                        │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

Before starting, ensure you have:

1. **OpenShift Cluster** (4.12+) with cluster-admin access
2. **RHBK Operator** installed (Red Hat Build of Keycloak v22+)
3. **Authorino Operator** installed
4. **LDAP Server** (OpenLDAP, Active Directory, or compatible)
5. **Network connectivity** between Keycloak and LDAP

### Required Tools

```bash
# Verify tools are available
oc version          # OpenShift CLI
curl --version      # For API calls
jq --version        # JSON processing
base64 --version    # Token decoding
```

---

## LDAP Configuration

### Option A: Existing Enterprise LDAP

If you have an existing LDAP with user attributes for organization/account:

#### Step 1: Identify User Attributes

Common enterprise patterns:

| Attribute | Maps To | Example |
|-----------|---------|---------|
| `costCenter` | `org_id` | `1234567` |
| `departmentNumber` | `org_id` | `7890123` |
| `division` | `account_number` | `9876543` |
| `employeeNumber` | `account_number` | `5555555` |

#### Step 2: Create Cost Management Groups OU

Create a dedicated OU for Cost Management groups:

```ldif
# Create the CostMgmt OU
dn: ou=CostMgmt,ou=groups,dc=example,dc=com
objectClass: organizationalUnit
ou: CostMgmt
description: Auto-managed groups for Cost Management
```

#### Step 3: Set Up Group Sync

You have two options for creating groups from user attributes:

**Option 1: Manual Group Creation**

Create groups manually based on your org_id/account_number values:

```ldif
# Organization group
dn: cn=cost-mgmt-org-1234567,ou=CostMgmt,ou=groups,dc=example,dc=com
objectClass: groupOfNames
cn: cost-mgmt-org-1234567
description: Cost Management Organization 1234567
member: uid=user1,ou=users,dc=example,dc=com
member: uid=user2,ou=users,dc=example,dc=com

# Account group
dn: cn=cost-mgmt-account-9876543,ou=CostMgmt,ou=groups,dc=example,dc=com
objectClass: groupOfNames
cn: cost-mgmt-account-9876543
description: Cost Management Account 9876543
member: uid=user1,ou=users,dc=example,dc=com
```

**Option 2: Automated Sync Script (Recommended)**

Use the provided sync script to automatically create groups from user attributes:

```bash
# Deploy the sync CronJob
kubectl apply -f scripts/ldap-sync-cronjob.yaml -n keycloak
```

The sync script:
- Reads `costCenter` and `accountNumber` from each user
- Creates corresponding `cost-mgmt-org-{id}` and `cost-mgmt-account-{id}` groups
- Manages membership automatically
- Runs on a schedule (default: every 5 minutes)

### Option B: Demo LDAP Setup

For testing or demos, deploy our pre-configured OpenLDAP:

```bash
# Deploy OpenLDAP with test data
./scripts/deploy-ldap-demo.sh

# This creates:
# - User 'test' with org_id=1234567, account_number=9876543
# - User 'admin' with org_id=7890123, account_number=5555555
# - Corresponding cost-mgmt-* groups
```

---

## RHBK Configuration

### Step 1: Deploy RHBK

If not already deployed:

```bash
./scripts/deploy-rhbk.sh
```

This deploys:
- RHBK Operator
- PostgreSQL database
- Keycloak instance with `kubernetes` realm
- Cost Management client

### Step 2: Configure LDAP Federation

Run the configuration script:

```bash
./scripts/configure-keycloak-ldap.sh
```

Or configure manually via Keycloak Admin Console:

#### 2.1 Create LDAP User Federation

1. Navigate to **Realm Settings** → **User Federation**
2. Add provider: **ldap**
3. Configure connection:

| Setting | Value |
|---------|-------|
| Vendor | Other (or your LDAP type) |
| Connection URL | `ldap://your-ldap-server:389` |
| Bind DN | `cn=admin,dc=example,dc=com` |
| Bind Credential | Your LDAP admin password |
| Users DN | `ou=users,dc=example,dc=com` |
| Username LDAP attribute | `uid` |
| RDN LDAP attribute | `uid` |
| UUID LDAP attribute | `entryUUID` |
| User Object Classes | `inetOrgPerson, posixAccount` |
| Edit Mode | READ_ONLY |

#### 2.2 Create Group Mapper

1. In the LDAP Federation, go to **Mappers**
2. Create mapper:

| Setting | Value |
|---------|-------|
| Name | `cost-mgmt-groups` |
| Mapper Type | `group-ldap-mapper` |
| Groups DN | `ou=CostMgmt,ou=groups,dc=example,dc=com` |
| Group Name LDAP Attribute | `cn` |
| Group Object Classes | `groupOfNames` |
| Membership LDAP Attribute | `member` |
| Membership Attribute Type | DN |
| Mode | READ_ONLY |

#### 2.3 Sync Users and Groups

1. Go to **User Federation** → your LDAP provider
2. Click **Sync all users**
3. Go to the group mapper and click **Sync LDAP groups to Keycloak**

### Step 3: Create OpenShift Client

The script creates an `openshift` client for OAuth integration:

```bash
# Already done by configure-keycloak-ldap.sh
# Manual creation via Admin Console:

# Client ID: openshift
# Client Protocol: openid-connect
# Access Type: confidential
# Direct Access Grants: ON
# Valid Redirect URIs:
#   - https://oauth-openshift.apps.your-cluster.com/oauth2callback/keycloak
#   - https://oauth-openshift.apps.your-cluster.com/*
#   - https://console-openshift-console.apps.your-cluster.com/*
#   - https://*.apps.your-cluster.com/*
```

### Step 4: Create Required Client Scopes

OpenShift OAuth requires specific scopes. Create these client scopes:

| Scope | Purpose |
|-------|---------|
| `openid` | Required for OIDC |
| `profile` | User profile information |
| `email` | Email address |
| `groups` | Group membership (with groups mapper) |

```bash
# The configure-keycloak-ldap.sh script creates these automatically
# Manual creation: Realm Settings → Client Scopes → Create

# After creating, assign to the 'openshift' client:
# Clients → openshift → Client Scopes → Add default scopes
```

### Step 5: Add Protocol Mappers

**Groups Mapper** (required for group membership in tokens):

| Setting | Value |
|---------|-------|
| Name | `groups` |
| Mapper Type | `Group Membership` |
| Token Claim Name | `groups` |
| Full group path | OFF |
| Add to ID token | ON |
| Add to access token | ON |

**Preferred Username Mapper** (required for OpenShift to use username instead of UUID):

| Setting | Value |
|---------|-------|
| Name | `preferred_username` |
| Mapper Type | `User Property` |
| Property | `username` |
| Token Claim Name | `preferred_username` |
| Add to ID token | ON |
| Add to access token | ON |

> **Important:** Without the `preferred_username` mapper, OpenShift will create users with UUID names instead of actual usernames.

### Step 6: Add Groups Protocol Mapper

Ensure groups are included in tokens:

1. Go to **Clients** → `openshift` → **Client Scopes**
2. Add **Dedicated Scope** or use existing
3. Create mapper:

| Setting | Value |
|---------|-------|
| Name | `groups` |
| Mapper Type | `Group Membership` |
| Token Claim Name | `groups` |
| Full group path | OFF |
| Add to ID token | ON |
| Add to access token | ON |
| Add to userinfo | ON |

---

## OpenShift OAuth Configuration

### Step 1: Create Client Secret

```bash
# Get the client secret from Keycloak
CLIENT_SECRET=$(oc get secret keycloak-client-secret-cost-management-operator \
  -n keycloak -o jsonpath='{.data.CLIENT_SECRET}' | base64 -d)

# Create secret in openshift-config namespace
oc create secret generic keycloak-client-secret \
  --from-literal=clientSecret="$CLIENT_SECRET" \
  -n openshift-config
```

### Step 2: Configure OAuth Identity Provider

```bash
# Get Keycloak URL
KEYCLOAK_URL="https://$(oc get route keycloak -n keycloak -o jsonpath='{.spec.host}')"

# Apply OAuth configuration
cat << EOF | oc apply -f -
apiVersion: config.openshift.io/v1
kind: OAuth
metadata:
  name: cluster
spec:
  identityProviders:
  - name: keycloak
    type: OpenID
    mappingMethod: claim
    openID:
      clientID: openshift
      clientSecret:
        name: keycloak-client-secret
      issuer: ${KEYCLOAK_URL}/realms/kubernetes
      claims:
        preferredUsername:
        - preferred_username
        name:
        - name
        email:
        - email
        groups:
        - groups
      extraScopes:
      - email
      - profile
EOF
```

### Step 3: Wait for OAuth Pods to Restart

```bash
# Monitor OAuth server rollout
oc get pods -n openshift-authentication -w
```

---

## Verification

### Step 1: Verify LDAP Data

```bash
# Check users exist
ldapsearch -x -H ldap://your-ldap:389 \
  -D "cn=admin,dc=example,dc=com" -w password \
  -b "ou=users,dc=example,dc=com" "(uid=*)" uid cn

# Check groups exist
ldapsearch -x -H ldap://your-ldap:389 \
  -D "cn=admin,dc=example,dc=com" -w password \
  -b "ou=CostMgmt,ou=groups,dc=example,dc=com" "(cn=cost-mgmt-*)" cn member
```

### Step 2: Verify Keycloak Sync

```bash
# Get admin token
KEYCLOAK_URL="https://$(oc get route keycloak -n keycloak -o jsonpath='{.spec.host}')"
ADMIN_TOKEN=$(curl -sk "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" \
  -d "username=admin" \
  -d "password=$(oc get secret keycloak-initial-admin -n keycloak -o jsonpath='{.data.password}' | base64 -d)" \
  -d "grant_type=password" | jq -r '.access_token')

# List users
curl -sk "${KEYCLOAK_URL}/admin/realms/kubernetes/users" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | jq '.[].username'

# List groups
curl -sk "${KEYCLOAK_URL}/admin/realms/kubernetes/groups" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | jq '.[].name'
```

### Step 3: Verify Groups in Token

```bash
# Get token for a user (requires direct grant)
USER_TOKEN=$(curl -sk "${KEYCLOAK_URL}/realms/kubernetes/protocol/openid-connect/token" \
  -d "client_id=openshift" \
  -d "client_secret=openshift-secret" \
  -d "username=test" \
  -d "password=test" \
  -d "grant_type=password" | jq -r '.access_token')

# Decode and check groups
echo "$USER_TOKEN" | cut -d'.' -f2 | base64 -d | jq '.groups'

# Expected output:
# [
#   "cost-mgmt-org-1234567",
#   "cost-mgmt-account-9876543"
# ]
```

### Step 4: Test End-to-End Flow

```bash
# 1. Login to OpenShift via Keycloak
#    Open: https://console-openshift-console.apps.your-cluster.com
#    Select: "Log in with keycloak"
#    Username: test
#    Password: test

# 2. Get your token
oc login --web  # or copy token from console
TOKEN=$(oc whoami -t)

# 3. Test the ROS API
curl -v http://ros-api-route.apps.your-cluster.com/api/ros/v1/recommendations \
  -H "Authorization: Bearer $TOKEN"

# Expected: 200 OK (or appropriate response with data)
# Check Envoy logs for X-Rh-Identity header construction
```

### Step 5: Verify X-Rh-Identity Header

Check Envoy logs to see the constructed identity:

```bash
oc logs -n cost-mgmt -l app.kubernetes.io/name=ros-api -c envoy-proxy | \
  grep "X-Rh-Identity"

# Expected log:
# Built X-Rh-Identity for user=test, org_id=1234***
```

---

## Troubleshooting

### Issue: Users Not Syncing from LDAP

**Symptoms:** Users don't appear in Keycloak

**Solutions:**
1. Check LDAP connection in Keycloak Federation settings
2. Verify Users DN path is correct
3. Check user object class matches your LDAP schema
4. Test LDAP bind credentials:
   ```bash
   ldapsearch -x -H ldap://your-ldap:389 \
     -D "cn=admin,dc=example,dc=com" -w password \
     -b "ou=users,dc=example,dc=com" "(uid=*)"
   ```

### Issue: Groups Not Appearing in Token

**Symptoms:** Token has empty `groups` claim

**Solutions:**
1. Verify group mapper is configured on the client
2. Check group mapper settings (Add to access token = ON)
3. Ensure user is a member of the LDAP groups
4. Re-sync groups: Federation → Mappers → Sync

### Issue: "Missing organization ID" Error

**Symptoms:** API returns 401 with "Missing organization ID"

**Solutions:**
1. Verify user has `cost-mgmt-org-*` group membership
2. Check group naming follows pattern: `cost-mgmt-org-{numeric_id}`
3. Verify groups flow to OpenShift token:
   ```bash
   oc get user $(oc whoami) -o yaml | grep groups
   ```

### Issue: CEL Expression Not Extracting Values

**Symptoms:** org_id or account_number is empty

**Solutions:**
1. Check Authorino AuthConfig is deployed:
   ```bash
   oc get authconfig -n your-namespace
   ```
2. Verify CEL expressions match your group naming (note: TokenReview returns groups at `auth.identity.user.groups`):
   ```yaml
   expression: |
     auth.identity.user.groups.filter(g, g.startsWith("cost-mgmt-org-")).size() > 0
       ? auth.identity.user.groups.filter(g, g.startsWith("cost-mgmt-org-"))[0].substring(14)
       : ""
   ```
3. Check Authorino logs for debug output:
   ```bash
   oc logs -n ros-demo deployment/ros-demo-cost-onprem-authorino --tail=50 | grep "response built"
   ```

### Issue: OpenShift OAuth Not Showing Keycloak Option

**Symptoms:** Login page doesn't show "keycloak" provider

**Solutions:**
1. Verify OAuth config:
   ```bash
   oc get oauth cluster -o yaml
   ```
2. Check client secret exists:
   ```bash
   oc get secret keycloak-client-secret -n openshift-config
   ```
3. Verify Keycloak is accessible:
   ```bash
   curl -sk https://keycloak-url/realms/kubernetes/.well-known/openid-configuration
   ```

### Issue: "Invalid parameter: redirect_uri" Error

**Symptoms:** Keycloak rejects OAuth redirect

**Solutions:**
1. Add exact OAuth callback URL to Keycloak client:
   ```
   https://oauth-openshift.apps.your-cluster.com/oauth2callback/keycloak
   ```
2. Update the openshift client redirect URIs in Keycloak Admin Console

### Issue: "Invalid parameter value for: scope" Error

**Symptoms:** Keycloak rejects OAuth request with scope error

**Solutions:**
1. Create missing client scopes (openid, profile, email, groups)
2. Assign scopes to the openshift client as default scopes
3. Verify scopes are assigned:
   ```bash
   # Using Keycloak Admin API
   curl -sk "${KEYCLOAK_URL}/admin/realms/kubernetes/clients/${CLIENT_ID}/default-client-scopes" \
     -H "Authorization: Bearer $ADMIN_TOKEN" | jq '.[].name'
   ```

### Issue: "Could not create user" Error on Login

**Symptoms:** Keycloak login succeeds but OpenShift fails to create user

**Solutions:**
1. Delete orphaned user/identity objects:
   ```bash
   oc delete user <username>
   oc delete identity keycloak:<keycloak-user-id>
   ```
2. Ensure `preferred_username` mapper is configured in Keycloak
3. Try logging in again

### Issue: Client Secret Mismatch

**Symptoms:** "An authentication error occurred" after Keycloak login

**Solutions:**
1. Verify secrets match:
   ```bash
   # OpenShift secret
   oc get secret keycloak-client-secret -n openshift-config -o jsonpath='{.data.clientSecret}' | base64 -d

   # Keycloak client secret (via Admin API)
   curl -sk "${KEYCLOAK_URL}/admin/realms/kubernetes/clients?clientId=openshift" \
     -H "Authorization: Bearer $ADMIN_TOKEN" | jq -r '.[0].secret'
   ```
2. Update Keycloak client secret to match OpenShift, or vice versa
3. Restart OAuth server pods:
   ```bash
   oc delete pods -n openshift-authentication -l app=oauth-openshift
   ```

---

## Quick Reference

### Group Naming Convention

| Type | Pattern | Example |
|------|---------|---------|
| Organization | `cost-mgmt-org-{id}` | `cost-mgmt-org-1234567` |
| Account | `cost-mgmt-account-{id}` | `cost-mgmt-account-9876543` |

### CEL Extraction Logic

```cel
# Extract org_id (14 = length of "cost-mgmt-org-")
# Note: TokenReview returns groups at auth.identity.user.groups
auth.identity.user.groups.filter(g, g.startsWith("cost-mgmt-org-"))[0].substring(14)

# Extract account_number (18 = length of "cost-mgmt-account-")
auth.identity.user.groups.filter(g, g.startsWith("cost-mgmt-account-"))[0].substring(18)
```

### Verified End-to-End Flow

The following flow has been tested and verified:

```
1. User 'test' logs in via Keycloak IDP
2. OpenShift creates user with groups from JWT claims
3. TokenReview returns: ["cost-mgmt-org-1234567", "cost-mgmt-account-9876543", ...]
4. CEL extracts: org_id="1234567", account_number="9876543"
5. Envoy Lua constructs X-Rh-Identity header
6. Backend receives authenticated request (404 = no data, not auth failure)
```

### X-Rh-Identity Structure

```json
{
  "identity": {
    "org_id": "1234567",
    "account_number": "9876543",
    "type": "User",
    "user": {
      "username": "test",
      "email": "test@example.com"
    }
  }
}
```

---

## Related Documentation

- [ADR 0001: LDAP Organization ID Mapping](adr/0001-ldap-organization-id-mapping.md)
- [Authorino LDAP Integration](authorino-ldap-integration.md)
- [RHBK Deployment Guide](../scripts/deploy-rhbk.sh)

---

## Support

For issues or questions:
1. Check the troubleshooting section above
2. Review Authorino and Envoy logs
3. Verify each step in the flow independently
4. Contact the Cost Management team with:
   - LDAP structure (anonymized)
   - Keycloak Federation configuration
   - Sample token (with sensitive data removed)
   - Error messages and logs

