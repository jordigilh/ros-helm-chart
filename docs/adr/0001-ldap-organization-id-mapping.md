# ADR 0001: LDAP Organization ID Mapping to Keycloak Groups

## Status

**Proposed** - POC Verified ✅, Pending Tech Lead Approval

Date: 2025-12-04
POC Verified: 2025-12-05 (End-to-end flow tested successfully)

---

## Table of Contents

1. [Context](#context) - Problem statement and architecture
2. [Decision Drivers](#decision-drivers) - Key constraints
3. [Background: Enterprise LDAP Patterns](#background-enterprise-ldap-patterns) - Industry practices
   - [Schema Changes](#schema-changes)
   - [Standard Attributes](#standard-attributes)
   - [Keycloak LDAP Synchronization](#keycloak-ldap-synchronization) - Sync modes, READ_ONLY considerations
4. [Considered Options](#considered-options) - All evaluated approaches
5. [Decision Outcome](#decision-outcome) - Chosen solution and rationale
6. [Verified POC Implementation](#verified-poc-implementation-2025-12-05) - Test results
7. [Implementation Plan](#implementation-plan) - Deployment phases
8. [Consequences](#consequences) - Trade-offs
9. [References](#references) - External documentation

---

## Context

Cost Management on-premises requires extracting organization IDs (`org_id`) for users authenticating through OpenShift OAuth integrated with Keycloak and LDAP.

### Current Architecture

1. Users authenticate via OpenShift console (OAuth flow)
2. OpenShift OAuth delegates to Keycloak (OIDC Identity Provider)
3. Keycloak federates users from LDAP
4. API requests go through Envoy → Authorino
5. Authorino validates tokens using Kubernetes TokenReview API
6. Authorino extracts `org_id` and `account_number` from groups, returns as headers to Envoy
7. **Envoy Lua filter** constructs `X-Rh-Identity` header from Authorino's headers
8. Backend receives `X-Rh-Identity` with `org_id` and `account_number` for multi-tenant isolation

### Technical Constraint

**OpenShift's TokenReview API limitation**: When validating opaque OAuth tokens, the TokenReview API returns only:
- `username`
- `uid` (user ID)
- `groups` (array of group names)

It does **NOT** return:
- Custom OIDC claims (e.g., `org_id`, `account_number`)
- `identity.extra` fields from Keycloak

### The Challenge

We need to pass `org_id` from LDAP through Keycloak and OpenShift OAuth to Authorino, but TokenReview only exposes groups. Therefore, we must encode the `org_id` within the group membership structure.

### Non-Functional Requirements

1. **Credential-free data plane**: Authorino and the claims service must NOT hold Keycloak or LDAP credentials
2. **Scalability**: Solution must support thousands of organizations and users
3. **Automation**: No manual group management or hardcoded mappings
4. **Maintainability**: Avoid complex custom code or plugins
5. **Performance**: Minimal latency impact on API requests

## Decision Drivers

- LDAP is the source of truth for user attributes
- Keycloak acts as OIDC Identity Provider and LDAP federation layer
- OpenShift OAuth TokenReview API only returns groups
- Authorino needs `org_id` without querying external services with credentials
- **No LDAP Schema Changes Required**: Enterprises already have user attributes (e.g., `costCenter`, `departmentNumber`, `employeeNumber`) that can map to our `org_id` and `account_number`. The Protocol Mapper is configurable per customer to read their existing fields - no new LDAP attributes needed

---

## Background: Enterprise LDAP Patterns

> **References verified:** 2025-12-05 (All URLs return HTTP 200 with content matching claims)

Understanding how large enterprises structure their LDAP directories informs our solution design. The following patterns are documented in industry literature:

### Schema Changes

Large directory vendors treat schema extension as a normal, supported activity, but recommend that changes be controlled and that built-in or standard schema elements not be modified once deployed.

*"Interoperability of Directory Server with existing LDAP clients relies on the standard LDAP schema. If you change the standard schema, you will also have difficulties when upgrading your server."* – Oracle Directory Server

**Reference:** [Oracle: Managing Directory Schema](https://docs.oracle.com/cd/E49437_01/admin.111220/e22648/schema.htm)

### Standard Attributes

Enterprise directories typically expose standard or widely adopted attributes such as POSIX identifiers (`uidNumber`, `gidNumber`), employee identifiers, and organizational fields. Integration documentation like Azure NetApp Files explicitly uses RFC 2307bis schema with these POSIX attributes for identity mapping rather than custom definitions.

**Reference:** [Microsoft Azure NetApp Files: LDAP schemas](https://learn.microsoft.com/en-us/azure/azure-netapp-files/lightweight-directory-access-protocol-schemas)

### Stable Identifiers

Directory design requires stable, immutable identifiers as the canonical key for user entries to maintain referential integrity when mutable attributes like usernames or email addresses change. Common practice uses HR-assigned employee IDs, `objectGUID`, or `entryUUID` as the permanent identifier.

**References:**
- [Microsoft: objectGUID as immutable identifier](https://learn.microsoft.com/en-us/windows/win32/adschema/a-objectguid)
- [IBM WebSphere: LDAP mapping with stable identifiers](https://www.ibm.com/docs/en/was/9.0.5?topic=SS7K4U_9.0.5/com.ibm.websphere.base.doc/ae/rsec_ldapmapping.html)

### Role of Groups

LDAP groups serve primarily as authorization constructs for role-based access control (RBAC), expressing which users have specific permissions. User descriptive metadata (department, location, job title) belongs in user object attributes like `departmentNumber`, `l`, `title` per `inetOrgPerson` schema, not group membership.

**References:**
- [Microsoft: Security groups for authorization](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/manage/understand-security-groups)
- [RFC 2798: inetOrgPerson schema](https://datatracker.ietf.org/doc/html/rfc2798)

### Scale and Large Groups

Very large static groups create performance risks: Microsoft AD recommends maximum 5,000 members per group to avoid timeouts. IBM z/OS LDAP notes group evaluation cost grows proportionally with group count.

**References:**
- [Microsoft AD: Maximum limits](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/plan/active-directory-domain-services-maximum-limits)
- [IBM z/OS: LDAP tuning for large directories](https://www.ibm.com/docs/en/zos/3.2.0?topic=tuning-user-groups-considerations-in-large-directories)
- [Atlassian: Performance with large LDAP](https://support.atlassian.com/confluence/kb/performance-issues-with-large-ldap-repository-100-000-users-or-more/)

### Keycloak LDAP Synchronization

Understanding how Keycloak synchronizes with LDAP is critical for large enterprise deployments.

**Reference:** [Keycloak Server Administration Guide - LDAP User Federation](https://www.keycloak.org/docs/latest/server_admin/index.html#_ldap)

#### Sync Mechanisms

Keycloak uses **pull-based synchronization** (queries LDAP), not push:

| Mode | Description | Use Case |
|------|-------------|----------|
| **Periodic Full Sync** | Scans all LDAP users, updates local database | Initial sync, low-frequency updates |
| **Periodic Changed Users Sync** | Only pulls users created/modified since last sync | Large enterprises - reduces LDAP load |
| **On-Demand (Login)** | Imports user on first login, validates password against LDAP | Minimal storage, real-time validation |

> *"Keycloak imports users from LDAP into the local Keycloak user database. This copy of the user database synchronizes on-demand or through a periodic background task. An exception exists for synchronizing passwords. Keycloak never imports passwords."* – Keycloak Docs

#### Edit Modes

| Mode | Local Storage | LDAP Write-Back | Best For |
|------|---------------|-----------------|----------|
| **READ_ONLY** | Imports users | No writes to LDAP | Most enterprises (LDAP is authoritative) |
| **WRITABLE** | Imports users | Auto-sync changes to LDAP | Bi-directional sync |
| **UNSYNCED** | Imports users | Manual sync required | Local overrides without LDAP impact |

#### Passing org_id Through the OAuth Flow

**Challenge:** OpenShift TokenReview only returns `groups`, not user attributes. How do we get `costCenter` and `accountNumber` to Authorino?

**The complete flow:**
```
LDAP → Keycloak → JWT (groups claim) → OpenShift User object → Opaque Token → TokenReview → Authorino
                                              ↓
                                    groups stored here
```

API requests use **opaque OAuth tokens** (not JWT). Authorino validates via TokenReview, which returns groups from the OpenShift User object. The User object's groups come from the Keycloak JWT's `groups` claim during initial login.

**Available Solutions:**

| Approach | How It Works | LDAP Impact | Keycloak Impact | RHBK Compatible |
|----------|--------------|-------------|-----------------|-----------------|
| **Protocol Mapper** | Keycloak reads user attrs, adds to JWT `groups` claim → OpenShift imports to User | None | Script mapper config | ⚠️ Requires JAR |
| **LDAP Group Mapper** | Keycloak imports LDAP groups → adds to JWT `groups` claim → OpenShift imports | Groups in LDAP | Standard mapper | ✅ Yes |
| **Dynamic Groups** | LDAP auto-creates groups from user attrs | Requires support | Standard mapper | ✅ Yes |
| **Claims Service** | Separate service Authorino queries directly | None | None | ✅ Yes |

**Industry-aligned approach (Protocol Mapper):**
```
LDAP                     Keycloak                  OpenShift              Authorino
────                     ────────                  ─────────              ─────────
User: uid=test           Protocol Mapper:          User object:           TokenReview:
└── costCenter: 1234567  transforms attr →         groups: [              groups: [
                         JWT groups claim:           "org-1234567"          "org-1234567"
                         ["org-1234567"]           ]                      ]

                         (No LDAP modification)
```

This keeps metadata in user attributes (per [Role of Groups](#role-of-groups)) and transforms at the Keycloak layer before OpenShift imports the groups.

**RHBK Constraint:** Protocol Mappers with custom scripts require JAR packaging in RHBK (see [Protocol Mapper Implementation](#rhbk-implementation-pre-packaged-jar-with-configurable-attributes--recommended)).

### Key Insight

The **most compatible approach** for enterprises is to:
1. Read **existing** user attributes (no schema changes)
2. Use **stable, HR-synchronized identifiers**
3. Create groups in an **isolated OU** (doesn't affect existing infrastructure)
4. Use **standard LDAP operations** (works with any directory)

This aligns with the Protocol Mapper approach - reading existing attributes without LDAP changes.

---

## Considered Options

### Primary Option: Protocol Mapper (Recommended)

**Reality Check**: Large enterprises already have attributes like `employeeNumber`, `costCenter`, `division`, etc. stored on user objects.

```ldif
# Existing enterprise user structure
dn: CN=John Doe,OU=Cloud-Platform,OU=Engineering,OU=USA,OU=Americas,OU=Users,DC=company,DC=com
objectClass: user
objectClass: inetOrgPerson
cn: John Doe
sAMAccountName: jdoe
employeeID: 12345
department: Engineering
costCenter: 1001            ← Maps to org_id in X-Rh-Identity
departmentNumber: 9876543   ← Maps to account_number in X-Rh-Identity
accountExpires: 0
memberOf: CN=AWS-Admins,OU=Groups,DC=company,DC=com
memberOf: CN=Kubernetes-Developers,OU=Groups,DC=company,DC=com
```

**Challenge**: OpenShift TokenReview only returns groups, not user attributes. Keycloak can't directly map user attributes to groups that OpenShift will import.

**Solution**: Use a Protocol Mapper to transform user attributes into synthetic groups in the JWT token.

**Use Keycloak's protocol mapper to inject user attributes as groups in the OIDC token.**

This approach requires only Keycloak configuration - no external scripts, sync jobs, or LDAP group creation.

**How It Works:**
```
1. User logs in → Keycloak reads LDAP user attributes (costCenter, departmentNumber)
2. Protocol Mapper transforms: costCenter=1001 → groups=["/organizations/1001"]
3. OpenShift creates User object with those groups
4. TokenReview returns those groups → Authorino parses them
```

**Configuration:**

1. In Keycloak Admin Console: **Clients → "openshift" → Client Scopes → Add client scope → Create new**
   - Name: `cost-management-groups`
   - Protocol: `openid-connect`

2. **Add Mapper → Create Protocol Mapper → Script Mapper**:
   - Name: `user-attrs-to-groups`
   - Mapper Type: `Script Mapper`
   - Script:
     ```javascript
    // Read user LDAP attributes
    var costCenter = user.getFirstAttribute("costCenter");
    var departmentNumber = user.getFirstAttribute("departmentNumber");

    // Get existing groups
    var groups = token.getOtherClaims().get("groups");
    if (groups == null) {
        groups = new java.util.ArrayList();
    }

    // Add org_id and account_number as groups
    if (costCenter != null && !costCenter.isEmpty()) {
        groups.add("cost-mgmt-org-" + costCenter);
    }
    if (departmentNumber != null && !departmentNumber.isEmpty()) {
        groups.add("cost-mgmt-account-" + departmentNumber);
    }

     token.getOtherClaims().put("groups", groups);
     "OK";
     ```
   - Token Claim Name: `groups`
   - Add to ID token: **ON**
   - Add to access token: **ON**
   - Add to userinfo: **ON**

3. **Assign scope to client**: Clients → "openshift" → Client Scopes → Add client scope → `cost-management-groups` → Default

**Verification:**
```bash
# User logs out and back in
oc get user test -o yaml
# Should show:
# groups:
# - /organizations/1001
# - /accounts/CloudServices
```

**Pros:**
- ✅ **Simple**: Keycloak UI configuration only
- ✅ **No LDAP changes**: Uses existing user attributes
- ✅ **No sync scripts**: Real-time, works on login
- ✅ **Standard feature**: Built into Keycloak

**Cons:**
- ⚠️ **RHBK (Red Hat Build of Keycloak) disables script uploading by default** for security (CVE-2022-2668)
- ⚠️ Groups update on next login (not immediate)
- ⚠️ Requires packaging scripts as JAR file for RHBK (see below)

**RHBK Implementation: Pre-packaged JAR with Configurable Attributes** ⭐ **RECOMMENDED**

Since we control the RHBK deployment, we can deploy the Protocol Mapper JAR via volume mount. This provides:
- ✅ **Industry-aligned**: No LDAP modification (metadata stays in user attributes)
- ✅ **Single JAR for all customers**: Attribute names are configurable at runtime
- ✅ **Zero operational overhead**: JAR is baked into the image

**JAR Structure:**
```
cost-mgmt-mappers.jar
├── META-INF/
│   └── keycloak-scripts.json
└── mappers/
    └── user-attrs-to-groups.js
```

**keycloak-scripts.json:**
```json
{
  "mappers": [
    {
      "name": "cost-mgmt-attrs-to-groups",
      "fileName": "mappers/user-attrs-to-groups.js",
      "description": "Maps user LDAP attributes to cost management groups"
    }
  ]
}
```

**user-attrs-to-groups.js (Configurable Script):**
```javascript
// Read configuration from realm attributes (set per customer via Keycloak admin)
var realmAttrs = realm.getAttributes();

// These CONFIG KEYS are hardcoded, but VALUES are configurable per realm
var orgAttrName = realmAttrs.get("cost-mgmt-org-attr");
var accountAttrName = realmAttrs.get("cost-mgmt-account-attr");

// Provide defaults if not configured
if (orgAttrName == null || orgAttrName.isEmpty()) {
    orgAttrName = "costCenter";  // Default LDAP attribute for org_id
}
if (accountAttrName == null || accountAttrName.isEmpty()) {
    accountAttrName = "departmentNumber";  // Default LDAP attribute for account_number
}

// Read user's LDAP attributes using configured names
// Use getFirstAttribute() - the correct Keycloak API
var orgId = user.getFirstAttribute(orgAttrName);
var accountNumber = user.getFirstAttribute(accountAttrName);

// Get existing groups from token
var groups = token.getOtherClaims().get("groups");
if (groups == null) {
    groups = new java.util.ArrayList();
}

// Add synthetic groups for cost management
if (orgId != null && !orgId.isEmpty()) {
    groups.add("cost-mgmt-org-" + orgId);
}
if (accountNumber != null && !accountNumber.isEmpty()) {
    groups.add("cost-mgmt-account-" + accountNumber);
}

token.getOtherClaims().put("groups", groups);
"OK";
```

**RHBK Operator Deployment:**

The RHBK Operator manages the Keycloak Deployment - you cannot modify it directly. Use `spec.unsupported.podTemplate` to inject custom configurations. Keycloak requires `kc.sh build` after adding providers.

**Volume Mount via Operator (No Custom Image)** ⭐ **RECOMMENDED**

Use `spec.unsupported.podTemplate` - the Operator merges this with its managed Deployment:

```yaml
apiVersion: k8s.keycloak.org/v2alpha1
kind: Keycloak
metadata:
  name: example-kc
spec:
  instances: 1
  # ... database, hostname, tls config ...

  unsupported:
    podTemplate:
      spec:
        # Init container runs kc.sh build with the JAR
        initContainers:
          - name: install-providers
            image: registry.redhat.io/rhbk/keycloak-rhel9:24
            command: ["/bin/sh", "-c"]
            args:
              - |
                cp /mounted-providers/*.jar /opt/keycloak/providers/
                /opt/keycloak/bin/kc.sh build
            volumeMounts:
              - name: provider-jar
                mountPath: /mounted-providers
              - name: keycloak-providers
                mountPath: /opt/keycloak/providers
        # Main container uses the built providers
        containers:
          - volumeMounts:
              - name: keycloak-providers
                mountPath: /opt/keycloak/providers
        volumes:
          # JAR stored in ConfigMap (< 1MB) or mounted from PVC
          - name: provider-jar
            configMap:
              name: cost-mgmt-mapper-jar
          # Shared volume for built providers
          - name: keycloak-providers
            emptyDir: {}
```

**Why this approach:**
- ✅ No custom image to maintain
- ✅ Uses stock RHBK image (easier upgrades)
- ✅ JAR managed separately (ConfigMap/Secret/PVC)
- ✅ Operator-supported approach (`unsupported` is a misnomer - it means "advanced")
- ⚠️ Trade-off: ~30-60s added to pod startup for `kc.sh build`

**Per-Customer Configuration (No JAR Rebuild):**

| Customer | Realm Attribute | Value |
|----------|-----------------|-------|
| Customer A | `cost-mgmt-org-attr` | `costCenter` |
| Customer A | `cost-mgmt-account-attr` | `departmentNumber` |
| Customer B | `cost-mgmt-org-attr` | `departmentNumber` |
| Customer B | `cost-mgmt-account-attr` | `employeeType` |

Configure via Keycloak Admin API:
```bash
# Set which LDAP attributes to use for this customer's realm
curl -X POST "https://keycloak/admin/realms/openshift/attributes" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "cost-mgmt-org-attr": "departmentNumber",
    "cost-mgmt-account-attr": "employeeType"
  }'
```

**What's Hardcoded vs Dynamic:**

| Component | Hardcoded in JAR? | Changeable at Runtime? |
|-----------|-------------------|------------------------|
| JavaScript logic | ✅ Yes | ❌ No |
| Config key names (`cost-mgmt-org-attr`) | ✅ Yes | ❌ No |
| Config key values (`costCenter`, `departmentNumber`) | ❌ No | ✅ Yes (per realm) |
| Group prefix (`cost-mgmt-org-`) | ✅ Yes | ❌ No |

**Documentation**: [RHBK 22.0 Server Developer Guide - Deploying Scripts](https://docs.redhat.com/en/documentation/red_hat_build_of_keycloak/22.0/html-single/server_developer_guide/index#con-as-a-deployment_server_development)

**When to use this approach:**
- ✅ **Recommended for all RHBK deployments** - industry-aligned, no LDAP modification
- ✅ If using **upstream Keycloak** (scripts enabled by default, even simpler)

**Authorino Configuration (CEL Expressions - VERIFIED ✅):**

> **Note**: We use CEL instead of OPA/Rego because Rego is being deprecated in Authorino.

```yaml
apiVersion: authorino.kuadrant.io/v1beta3
kind: AuthConfig
metadata:
  name: cost-management-auth
spec:
  hosts:
    - "*"
  authentication:
    "kubernetes-tokens":
      kubernetesTokenReview:
        audiences:
          - "https://kubernetes.default.svc"
  response:
    success:
      headers:
        # Username from TokenReview (path: auth.identity.user.username)
        "X-Auth-Username":
          plain:
            selector: auth.identity.user.username
        # UID from TokenReview
        "X-Auth-Uid":
          plain:
            selector: auth.identity.user.uid
        # Extract org_id from cost-mgmt-org-{id} groups
        # "cost-mgmt-org-" is 14 characters (0-indexed)
        "X-Auth-Org-Id":
          plain:
            expression: |
              auth.identity.user.groups.filter(g, g.startsWith("cost-mgmt-org-")).size() > 0
                ? auth.identity.user.groups.filter(g, g.startsWith("cost-mgmt-org-"))[0].substring(14)
                : ""
        # Extract account_number from cost-mgmt-account-{id} groups
        # "cost-mgmt-account-" is 18 characters (0-indexed)
        "X-Auth-Account-Number":
          plain:
            expression: |
              auth.identity.user.groups.filter(g, g.startsWith("cost-mgmt-account-")).size() > 0
                ? auth.identity.user.groups.filter(g, g.startsWith("cost-mgmt-account-"))[0].substring(18)
                : ""
```

**Key Implementation Details:**
- Uses `auth.identity.user.groups` (not `auth.identity.groups`) because TokenReview returns groups under `user`
- CEL `substring(14)` for org_id because "cost-mgmt-org-" is 14 characters
- CEL `substring(18)` for account_number because "cost-mgmt-account-" is 18 characters
- Returns empty string if no matching group found (Envoy Lua will reject with 401)

**Pros:**
- ✅ No LDAP changes required - reads existing user attributes
- ✅ Configurable per customer via realm attributes
- ✅ Real-time on login (no sync delay)
- ✅ Single JAR works for all customers
- ✅ Zero credentials in data plane
- ✅ Industry-aligned (groups for authorization, attributes for metadata)

**Cons:**
- ⚠️ Requires JAR deployment via volume mount (one-time setup)
- ⚠️ ~30-60s added to pod startup for `kc.sh build`

---

## Decision Outcome

**Chosen Option: Protocol Mapper with JAR Deployment**

### Approach

Since we control the RHBK deployment, we use a **Protocol Mapper JAR** deployed via volume mount that:
- **Reads user LDAP attributes** (e.g., `costCenter`, `departmentNumber`, `employeeNumber`) at login time
- **Transforms them to synthetic groups** (`cost-mgmt-org-{id}`, `cost-mgmt-account-{id}`) in the JWT
- **Configurable per customer** via Keycloak realm attributes (no JAR rebuild needed)
- **No LDAP modification** - metadata stays in user attributes (industry best practice)

### Rationale

1. **Industry-aligned**: Groups are for authorization, not metadata. We don't modify LDAP.
2. **Single JAR for all customers**: Attribute names are configurable at runtime via realm settings
3. **Zero LDAP write access**: Protocol Mapper only reads existing user attributes
4. **Real-time**: Updates on login (no sync delay)
5. **CEL in Authorino**: Extracts values from group names
6. **Zero Credentials in Data Plane**: Authorino has no Keycloak or LDAP credentials

### POC Verified (2025-12-05)

The Protocol Mapper approach was tested end-to-end and verified working:
- LDAP user attributes → Keycloak Protocol Mapper → JWT groups → OpenShift User → TokenReview → Authorino → Backend
- CEL expressions correctly extract `org_id` and `account_number` from group names
- API returns expected response (404 = no data, but authentication/authorization passed)

### Complete Request Flow (End-to-End) - VERIFIED ✅

This section explains how `org_id` and `account_number` flow from LDAP to the backend, with special emphasis on **Envoy's critical role** in constructing the `X-Rh-Identity` header.

> **Verified**: This flow was tested end-to-end on 2025-12-05 with user `test`, org_id `1234567`, and account_number `9876543`.

#### 1. User Login (One-Time)
- User logs in via OpenShift Console
- OpenShift redirects to Keycloak (OIDC provider)
- Keycloak authenticates user against LDAP
- Keycloak reads user's group memberships (e.g., `cost-mgmt-org-1234567`, `cost-mgmt-account-9876543`)
- OpenShift creates User object with groups array

#### 2. API Request with Token
- Client makes request with `Authorization: Bearer <opaque-token>` header
- Request hits Envoy proxy (sidecar)

#### 3. Envoy → Authorino (External Authorization)
- Envoy calls Authorino's gRPC authorization service
- Passes the Bearer token and request headers

#### 4. Authorino Processing
- Calls Kubernetes TokenReview API to validate token
- Receives back: `username`, `uid`, `groups` (e.g., `["cost-mgmt-org-1234567", "cost-mgmt-account-9876543", "system:authenticated"]`)
- Runs **CEL expressions** to parse groups:
  - Extracts `org_id: "1234567"` from `cost-mgmt-org-1234567`
  - Extracts `account_number: "9876543"` from `cost-mgmt-account-9876543`
- Returns authorization decision with headers:
  - `X-Auth-Username: test`
  - `X-Auth-Uid: 8a86aea7-021d-4de2-a376-c6892e1503dd`
  - `X-Auth-Org-Id: 1234567`
  - `X-Auth-Account-Number: 9876543`

#### 5. Envoy Lua Filter (CRITICAL STEP)
This is where the `X-Rh-Identity` header is constructed:

```lua
-- 1. Read headers from Authorino
local username = request_handle:headers():get("x-auth-username")
local org_id = request_handle:headers():get("x-auth-org-id")
local account_number = request_handle:headers():get("x-auth-account-number")

-- 2. Validate ALL required claims (401 if any missing)
if not username or username == "" then return 401 end
if not org_id or org_id == "" then return 401 end
if not account_number or account_number == "" then return 401 end

-- 3. Build X-Rh-Identity JSON
local identity_json = {
  "identity": {
    "org_id": org_id,
    "account_number": account_number,
    "type": "User",
    "user": {"username": username, ...},
    "internal": {"org_id": org_id, "auth_type": "kubernetes-tokenreview", ...}
  }
}

-- 4. Base64 encode the JSON
local b64_identity = request_handle:base64Escape(identity_json)

-- 5. Set the X-Rh-Identity header
request_handle:headers():add("x-rh-identity", b64_identity)

-- 6. Remove temporary Authorino headers (cleanup)
request_handle:headers():remove("x-auth-username")
request_handle:headers():remove("x-auth-org-id")
request_handle:headers():remove("x-auth-account-number")
```

**Why Envoy and not Authorino?**
- Authorino returns headers, but the backend expects `X-Rh-Identity` (base64-encoded JSON)
- Envoy's Lua filter transforms Authorino's simple headers into the complex structure
- This separation keeps Authorino generic and Envoy handles backend-specific formats

#### 6. Backend Processing
- Backend receives request with `X-Rh-Identity` header
- Decodes base64 → parses JSON
- Extracts `identity.org_id` and `identity.account_number`
- Uses both for database queries: `WHERE org_id = '1234567' AND account_number = '7890123'`
- Returns filtered data (multi-tenant isolation enforced)

**Key Insight**: Both `org_id` and `account_number` are **REQUIRED** and must be **different** values. The backend uses them together for proper data isolation.

### Implementation Plan

#### Phase 1: LDAP Schema Extension (Week 1)
- [ ] Create LDAP schema extension file
- [ ] Add `organizationId` attribute type
- [ ] Define `costManagementGroup` object class
- [ ] Deploy schema to LDAP server
- [ ] Validate schema is active

#### Phase 2: LDAP Group Structure (Week 1)
- [ ] Create `ou=groups,dc=example,dc=com` organizational unit
- [ ] Define naming convention for groups
- [ ] Create initial test groups with `organizationId`
- [ ] Assign test users to groups
- [ ] Validate LDAP queries

#### Phase 3: Keycloak Configuration (Week 2)
- [ ] Configure LDAP User Federation in Keycloak
- [ ] Create LDAP Group Mapper with `organizationId` as group name attribute
- [ ] Test group import from LDAP
- [ ] Validate groups appear in Keycloak admin console
- [ ] Test user login and group membership

#### Phase 4: OpenShift OAuth Integration (Week 2)
- [ ] Verify groups appear in OpenShift User objects
- [ ] Test `oc get user <username>` shows correct groups
- [ ] Validate TokenReview API returns groups

#### Phase 5: Authorino Configuration (Week 3)
- [ ] Deploy AuthConfig for cost-management-auth
- [ ] Configure direct group-to-header mapping
- [ ] Test header injection: `X-Auth-Org-Id` and `X-Auth-Account-Number`
- [ ] Validate end-to-end flow

#### Phase 6: Documentation and Monitoring (Week 3)
- [ ] Document LDAP schema
- [ ] Create runbook for adding new organizations
- [ ] Set up monitoring for group sync
- [ ] Create troubleshooting guide

### Migration Path (If Needed Later)

If we need more claims than can fit in group names, we can migrate to a **Claims Service** without breaking changes:

1. Keep existing group-based org_id extraction (backward compatible)
2. Deploy claims service for additional attributes
3. Update Authorino to fetch from claims service
4. Gradually migrate clients to use new headers

This provides a clear upgrade path if requirements evolve.

## Verified POC Implementation (2025-12-05)

The following configuration was tested end-to-end and verified working:

### Group Naming Convention (Actual)
| Type | Pattern | Example |
|------|---------|---------|
| Organization | `cost-mgmt-org-{id}` | `cost-mgmt-org-1234567` |
| Account | `cost-mgmt-account-{id}` | `cost-mgmt-account-9876543` |

### CEL Expression Indices (Verified)
| Prefix | Length | substring() |
|--------|--------|-------------|
| `cost-mgmt-org-` | 14 chars | `substring(14)` |
| `cost-mgmt-account-` | 18 chars | `substring(18)` |

### Test Results
```
User: test
TokenReview groups: ["cost-mgmt-org-1234567", "cost-mgmt-account-9876543", "system:authenticated:oauth", "system:authenticated"]

Authorino extracted:
  X-Auth-Username: test
  X-Auth-Org-Id: 1234567
  X-Auth-Account-Number: 9876543

API Response: 404 Not Found (authentication passed, no data in DB)
```

### Key Learnings from POC

1. **TokenReview path**: Groups are at `auth.identity.user.groups`, not `auth.identity.groups`
2. **CEL over Rego**: Rego is being deprecated in Authorino; CEL is preferred
3. **Keycloak client scopes**: Must create `openid`, `profile`, `email`, `groups` scopes
4. **preferred_username mapper**: Required for OpenShift to use username instead of UUID
5. **RBAC protection**: Groups are cluster-scoped; regular users cannot list/read them

### Files Implementing This ADR
- `cost-onprem/templates/auth/authorino-authconfig.yaml` - CEL expressions
- `keycloak/cost-mgmt-mappers/` - Protocol Mapper JAR source
- `scripts/configure-keycloak-ldap.sh` - Keycloak configuration
- `scripts/deploy-ldap-demo.sh` - Demo LDAP with test users
- `scripts/reconcile-groups-cronjob.yaml` - Group lifecycle management
- `docs/ldap-rhbk-configuration-guide.md` - Configuration guide

---

## Group Lifecycle Management

### The Problem

When a user's `org_id` or `account_number` changes in LDAP:
1. **Next login** → Protocol Mapper generates NEW synthetic groups (e.g., `cost-mgmt-org-9999999`)
2. **OLD groups remain** in OpenShift (e.g., `cost-mgmt-org-1234567`) with user still a member
3. **TokenReview returns BOTH** → CEL expression may return the wrong value

OpenShift does **not** automatically remove users from groups when the JWT no longer contains them.

### Solution: Automatic Reconciliation CronJob

A Kubernetes CronJob runs every 15 minutes to reconcile OpenShift groups with Keycloak:

```
Keycloak (Source of Truth)     OpenShift Groups
────────────────────────────   ────────────────────
User: test                     cost-mgmt-org-1234567 [test] ← STALE
  employeeNumber: 9999999      cost-mgmt-org-9999999 [test] ← CURRENT
  employeeType: 5555555        cost-mgmt-account-9876543 [test] ← STALE
                               cost-mgmt-account-5555555 [test] ← CURRENT

After Reconciliation:
  - test removed from cost-mgmt-org-1234567
  - test removed from cost-mgmt-account-9876543
  - Empty groups deleted
```

### Deployment

```bash
# Deploy the reconciliation CronJob
oc apply -f scripts/reconcile-groups-cronjob.yaml
```

### How It Works

1. **Queries Keycloak** for all users and their current attributes
2. **Builds expected memberships** based on `employeeNumber` → `cost-mgmt-org-{id}`
3. **Compares with OpenShift** groups
4. **Removes stale memberships** (user in group but shouldn't be)
5. **Deletes empty groups** (no members remaining)

### Manual Cleanup (If Needed)

```bash
# Remove user from specific group
oc adm groups remove-users cost-mgmt-org-1234567 test

# Delete a group
oc delete group cost-mgmt-org-1234567

# Force user recreation (nuclear option)
oc delete user test
oc delete identity keycloak:<keycloak-user-id>
# User logs in again → fresh groups from current JWT
```

### Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `KEYCLOAK_URL` | (cluster-specific) | Keycloak endpoint |
| `KEYCLOAK_REALM` | `kubernetes` | Realm to query |
| `COST_MGMT_ORG_ATTR` | `employeeNumber` | LDAP attribute for org_id |
| `COST_MGMT_ACCOUNT_ATTR` | `employeeType` | LDAP attribute for account_number |

### Files

- `scripts/reconcile-groups-cronjob.yaml` - CronJob manifest
- `scripts/reconcile-cost-mgmt-groups.sh` - Standalone reconciliation script

---

## Consequences

### Positive

- **No LDAP Changes**: Reads existing user attributes, no schema modification needed
- **Automated**: LDAP → Keycloak → OpenShift → Authorino flow is fully automated
- **Scalable**: Supports thousands of organizations without performance impact
- **Secure**: No credentials stored in data plane services
- **Configurable**: Attribute names configurable per customer via Keycloak realm settings
- **Debuggable**: Groups visible in Keycloak, OpenShift, and logs
- **Real-time**: Updates on user login (no sync delay)

### Negative

- **JAR Deployment**: Requires deploying Protocol Mapper JAR via volume mount (one-time setup)
- **Startup Time**: ~30-60s added to Keycloak pod startup for `kc.sh build`
- **Group Cleanup**: Requires CronJob to remove stale groups when user attributes change

### Neutral

- **Keycloak Configuration**: Requires setting up LDAP attribute mappers and realm attributes
- **Testing**: Requires LDAP test environment for validation

## Alternatives for Future Consideration

If requirements change significantly (e.g., need for 10+ custom claims), consider:

- **Claims Service**: Separate service that Authorino queries for complex claim structures
- **Hybrid Approach**: Use groups for `org_id` + claims service for additional metadata

## References

- [Keycloak LDAP Integration Documentation](https://www.keycloak.org/docs/latest/server_admin/#_ldap)
- [OpenShift OAuth Configuration](https://docs.openshift.com/container-platform/latest/authentication/identity_providers/configuring-oidc-identity-provider.html)
- [Authorino Architecture](https://docs.kuadrant.io/authorino/)
- [LDAP Schema Extension Best Practices](https://ldap.com/schema-element-definitions/)
- [RFC 4519 - LDAP Schema for User Applications](https://www.rfc-editor.org/rfc/rfc4519)

## Related Decisions

- ADR 0002: Authorino Authentication Strategy (pending)
- ADR 0003: Claims Service Architecture for Extended Attributes (future)

---

**Decision made by:** Engineering Team
**Last updated:** 2025-12-05
**Review date:** 2026-03-05 (3 months)


