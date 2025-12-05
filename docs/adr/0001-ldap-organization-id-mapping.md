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
- **LDAP Schema Influence**: We can request that 2 fields (`costCenter`/`org_id` and `accountNumber`) be populated as user attributes, but we cannot enforce whether they are implemented as user attributes or as group memberships - that decision lies with the customer's LDAP administrators

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

#### READ_ONLY Mode and Our Implementation

**Concern:** In READ_ONLY mode, Keycloak doesn't write to LDAP. How do we map user attributes (`costCenter`) to groups?

**Solution:** Our sync script creates groups **in LDAP**, not in Keycloak.

> ⚠️ **Trade-off Acknowledgment**
>
> This approach **contradicts** the industry best practice that "groups are for authorization, user attributes for metadata" (see [Role of Groups](#role-of-groups)). We are encoding user metadata (`org_id`, `account_number`) into group names.
>
> **Why we accept this trade-off:**
> - OpenShift TokenReview API only returns `groups` - not user attributes
> - This is the **only way** to pass `org_id` through the OAuth flow without credentials in the data plane
> - Groups are created in an **isolated OU** (`ou=CostMgmt`) to minimize impact on existing LDAP structure
> - Alternative (Claims Service) requires additional infrastructure

**How it works:**

```
┌─────────────────────────────────────────────────────────────────┐
│                           LDAP                                  │
│                                                                 │
│  User: uid=test                  Groups (created by sync):      │
│  └── costCenter: 1234567   ───►  └── cn=cost-mgmt-org-1234567  │
│                            sync      └── member: uid=test      │
│                            script                               │
│                                                                 │
│  Mapping happens HERE (in LDAP), not in Keycloak               │
└─────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼ Keycloak queries LDAP (READ_ONLY)
┌─────────────────────────────────────────────────────────────────┐
│                        Keycloak                                 │
│                                                                 │
│  On login (even in READ_ONLY mode):                            │
│  1. Query LDAP for user ✓                                      │
│  2. Query LDAP for user's group memberships ✓                  │
│  3. Include groups in JWT token ✓                              │
│                                                                 │
│  Result: groups=["cost-mgmt-org-1234567", ...]                 │
└─────────────────────────────────────────────────────────────────┘
```

**Why this works:**
- Sync script writes to LDAP (not Keycloak) → READ_ONLY mode irrelevant
- Group memberships exist in LDAP → Keycloak reads them on login
- No Keycloak customization required → Works with RHBK

#### If Sync Script Cannot Run in Customer Environment

| Constraint | Alternative Solution |
|------------|---------------------|
| Cannot run CronJobs in LDAP namespace | Option B1: LDAP Dynamic Groups (if supported) |
| Using upstream Keycloak | Option B0: Protocol Mapper (JavaScript in UI) |
| RHBK only, no external scripts | Option B0 with JAR packaging (complex) |
| Cannot modify LDAP at all | Option 4: Claims Service (additional infrastructure) |

### Key Insight

The **most compatible approach** for enterprises is to:
1. Read **existing** user attributes (no schema changes)
2. Use **stable, HR-synchronized identifiers**
3. Create groups in an **isolated OU** (doesn't affect existing infrastructure)
4. Use **standard LDAP operations** (works with any directory)

This is exactly what **[Option B2 (Automated Group Sync)](#option-b2-automated-group-sync-script--recommended-for-enterprise-10k-employees--rhbk)** implements.

---

## Considered Options

### Option 1: Custom Attributes on LDAP Groups with Keycloak Group Mapper

> ⚠️ **Enterprise Applicability Note**
>
> This option requires adding custom attributes (`organizationId`, `accountNumber`) to **LDAP group objects** - not user profiles. Users are then added as members of these groups, and Keycloak reads the group's custom attribute as the group name.
>
> Before choosing this approach, consider the organization's LDAP governance:
>
> | Factor | Implication |
> |--------|-------------|
> | **Schema change process** | Vendors support schema extension, but recommend changes be "controlled" ([Oracle](https://docs.oracle.com/cd/E49437_01/admin.111220/e22648/schema.htm)) |
> | **Existing attributes** | Enterprises typically have `costCenter`, `department`, `employeeID` already populated - prefer using these |
> | **Groups purpose** | Best practice: groups for authorization, user attributes for metadata ([Microsoft](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/manage/understand-security-groups)) |
>
> **If the organization has strict schema governance or prefers using existing attributes, see [Automated Group Sync](#option-b2-automated-group-sync-script--recommended-for-enterprise-10k-employees--rhbk).**

**Architecture (suitable for small deployments):**
```
LDAP Groups                         Keycloak                    OpenShift          Authorino
─────────────                       ────────                    ─────────          ─────────

Organization Group:                 Group: "/organizations/     TokenReview:       org_id: "1234567"
cn=engineering                              1234567"           groups:            account_number: "9876543"
ou=organizations                    ↑                           - "/organizations/ (parsed from groups)
├── cn: engineering                 │                             1234567"
├── organizationId: 1234567 ────────┘                          - "/accounts/
└── member: uid=test ───┐                                         9876543"
                        │
Account Group:          │           Group: "/accounts/
cn=account-9876543      │                   9876543"
ou=accounts             │           ↑
├── cn: account-9876543 │           │
├── accountNumber: 9876543 ─────────┘
└── member: uid=test ───┘
      (same user in both groups)
```

**Key Point**: The user `uid=test` is a **member of BOTH groups**:
1. Member of `cn=engineering,ou=organizations` → gets `organizationId: 1234567`
2. Member of `cn=account-9876543,ou=accounts` → gets `accountNumber: 9876543`

Keycloak imports both groups, and the user inherits membership in both, which appear in OpenShift's TokenReview response.

### Why Flat Group Membership Instead of Hierarchical Structure?

**Answer: Hierarchical OU structures are MORE common in enterprises**, but we chose flat group membership for this implementation due to technical constraints with Keycloak.

#### What Large Enterprises Actually Use (10k+ Employees)

**Standard Enterprise LDAP/Active Directory Structure:**
```
DC=company,DC=com
├── OU=Users
│   ├── OU=Americas
│   │   ├── OU=USA
│   │   │   ├── OU=Engineering
│   │   │   │   ├── OU=Cloud-Platform
│   │   │   │   │   └── CN=John Doe (employeeID: 12345, dept: ENG, costCenter: 1001)
│   │   │   │   └── OU=Data-Science
│   │   │   │       └── CN=Jane Smith (employeeID: 12346, dept: ENG, costCenter: 1001)
│   │   │   ├── OU=Finance
│   │   │   │   └── CN=Bob Manager (employeeID: 45678, dept: FIN, costCenter: 2001)
│   │   │   └── OU=Sales
│   │   └── OU=Canada
│   │       └── OU=Engineering
│   ├── OU=EMEA
│   │   ├── OU=UK
│   │   └── OU=Germany
│   └── OU=APAC
│       ├── OU=Japan
│       └── OU=Australia
├── OU=Groups
│   ├── OU=Security-Groups (access control)
│   │   ├── CN=VPN-Users
│   │   ├── CN=AWS-Admins
│   │   └── CN=Kubernetes-Developers
│   ├── OU=Distribution-Lists (email)
│   │   ├── CN=Engineering-All
│   │   └── CN=Finance-Team
│   └── OU=Application-Groups (app-specific)
│       ├── CN=SAP-Users
│       └── CN=Salesforce-Users
└── OU=Service-Accounts
    └── CN=svc-jenkins
```

**Key Characteristics of Large Enterprise LDAP (10k+ employees):**

1. **Geographic + Departmental Hierarchy**:
   - User DN: `CN=John Doe,OU=Cloud-Platform,OU=Engineering,OU=USA,OU=Americas,OU=Users,DC=company,DC=com`
   - 3-5 levels deep minimum
   - Location (continent → country → city) + Department + Team

2. **Attributes Over Structure for Metadata**:
   - `employeeID`: Unique identifier
   - `department`: "ENG", "FIN", "SALES"
   - `costCenter`: Billing/accounting code
   - `division`: Business unit
   - `manager`: DN of manager
   - **NOT** extracted from DN path, stored as explicit attributes

3. **Thousands of Groups**:
   - Security groups (10-50k groups in large orgs)
   - Nested groups (groups within groups)
   - Dynamic groups (auto-membership based on attributes)
   - Groups span OUs (not tied to OU hierarchy)

4. **Why This Structure?**
   - **GPO (Group Policy)**: Apply Windows policies by OU (location/department)
   - **Delegation**: IT admins get control over specific OU branches
   - **Scale**: 50k-500k users across multiple countries
   - **Compliance**: Audit trails show org structure
   - **Administration**: HR systems sync to specific OU paths

5. **Multi-Forest/Multi-Domain** (Fortune 500):
   - `DC=us,DC=company,DC=com` (North America)
   - `DC=emea,DC=company,DC=com` (Europe)
   - `DC=apac,DC=company,DC=com` (Asia-Pacific)
   - Trusts between forests for cross-region access

**Critical Insight for Cost Management:**
- **org_id and account_number would be LDAP attributes, NOT derived from OU structure**
- Example: `employeeNumber: 12345`, `costCenter: 1001`, `division: Cloud-Services`
- These attributes are populated by HR systems (Workday, SAP SuccessFactors)
- Groups are used for access control, not for storing user metadata

**We chose flat group membership (users are members of separate org and account groups) over hierarchical organization structure for this implementation. Here's why:**

#### Alternative: Hierarchical Structure (Not Chosen)
```
ou=organizations
  └── ou=1234567 (org as OU)
      └── ou=accounts
          └── ou=9876543 (account as OU)
              └── uid=test (user DN includes org/account path)
```

User DN: `uid=test,ou=9876543,ou=accounts,ou=1234567,ou=organizations,dc=example,dc=com`

**Why We Didn't Use This:**
1. **Keycloak Limitation**: Keycloak's LDAP User Federation doesn't easily extract attributes from parent OUs in the user's DN path
2. **User Mobility**: Moving a user between organizations requires changing their DN (destructive operation)
3. **Multi-org Membership**: A user can't belong to multiple organizations (DN is unique)
4. **Query Complexity**: Finding all users in an org requires recursive subtree searches
5. **Maintenance**: Requires custom LDAP parsing to extract org_id/account_number from DN

#### Chosen Approach: Flat Group Membership
```
Users:
  uid=test,ou=users,dc=example,dc=com  ← user DN is independent

Groups:
  cn=engineering,ou=organizations,dc=...  (has organizationId: 1234567, member: uid=test)
  cn=account-9876543,ou=accounts,dc=...  (has accountNumber: 9876543, member: uid=test)
```

**Benefits:**
1. **Keycloak Compatibility**: Standard LDAP group mapper works out of the box
2. **User Mobility**: Change group memberships without touching user DN
3. **Multi-org Support**: User can be member of multiple org/account groups
4. **Simple Queries**: Standard LDAP memberOf queries work
5. **Clear Semantics**: Group attributes (organizationId, accountNumber) are explicit, not derived from paths

**Trade-off:** Requires explicit group membership management instead of automatic DN-based inheritance. However, this is standard LDAP practice and aligns with how Keycloak expects to consume group data.

### Can We Support Enterprise Hierarchical Structures?

**Yes, but with additional work.** If you need to integrate with an existing enterprise LDAP where users are organized in hierarchical OUs, you have two options:

#### Option A: Parse User DN to Extract Org Info (Advanced)
```python
# Custom Authorino metadata evaluator or external service
user_dn = "CN=John Doe,OU=Account-9876543,OU=Accounts,OU=Org-1234567,OU=Organizations,DC=company,DC=com"

# Parse DN to extract org_id and account_number
import re
org_match = re.search(r'OU=Org-(\d+)', user_dn)
account_match = re.search(r'OU=Account-(\d+)', user_dn)

org_id = org_match.group(1)  # "1234567"
account_number = account_match.group(1)  # "9876543"
```

**Challenges:**
- Requires custom code (Authorino doesn't parse DNs natively)
- Need to deploy a metadata service that Authorino can call
- DN parsing is brittle (depends on OU naming conventions)

#### Option B: Use Existing LDAP Attributes (Recommended for Enterprise)

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
costCenter: 1001            ← This is your org_id
division: Cloud-Services
accountExpires: 0
memberOf: CN=AWS-Admins,OU=Groups,DC=company,DC=com
memberOf: CN=Kubernetes-Developers,OU=Groups,DC=company,DC=com
```

**Problem**: Keycloak can't map user attributes to group names that OpenShift will import.

**Solutions**: You have three options:

#### Option B0: Keycloak Protocol Mapper (SIMPLEST - Recommended!)

**Use Keycloak's protocol mapper to inject user attributes as groups in the OIDC token.**

This is a **2-minute configuration change** in Keycloak - no scripts, no sync jobs, no additional LDAP groups!

**How It Works:**
```
1. User logs in → Keycloak reads LDAP user attributes (costCenter, division)
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
     var costCenter = user.getAttribute("costCenter");
     var division = user.getAttribute("division");

     // Get existing groups
     var groups = token.getOtherClaims().get("groups");
     if (groups == null) {
         groups = new java.util.ArrayList();
     }

     // Add org_id and account_number as groups
     if (costCenter != null && costCenter.size() > 0) {
         groups.add("/organizations/" + costCenter.get(0));
     }
     if (division != null && division.size() > 0) {
         groups.add("/accounts/" + division.get(0));
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
- ✅ **Simple**: 2-minute Keycloak UI configuration
- ✅ **No LDAP changes**: Uses existing user attributes
- ✅ **No sync scripts**: Real-time, works on login
- ✅ **Standard feature**: Built into Keycloak

**Cons:**
- ⚠️ **RHBK (Red Hat Build of Keycloak) disables script uploading by default** for security (CVE-2022-2668)
- ⚠️ Groups update on next login (not immediate)
- ⚠️ Requires packaging scripts as JAR file for RHBK (see below)

**IMPORTANT for RHBK Users:**

Red Hat Build of Keycloak **disables script uploading through the admin console** by default. To use script mappers with RHBK, you must:

1. **Package the script as a JAR file**:
   ```
   my-scripts/
   ├── META-INF/
   │   └── keycloak-scripts.json
   └── mappers/
       └── user-attrs-to-groups.js
   ```

2. **Deploy JAR to Keycloak server**:
   - Add JAR to Keycloak `providers/` directory
   - Rebuild Keycloak: `kc.sh build`
   - Restart Keycloak pods

3. **Reference in mapper**: Use the script name from `keycloak-scripts.json`

**Documentation**: [RHBK 22.0 Server Developer Guide - Deploying Scripts](https://docs.redhat.com/en/documentation/red_hat_build_of_keycloak/22.0/html-single/server_developer_guide/index#con-as-a-deployment_server_development)

**Verdict for RHBK:** Script mappers work, but require JAR deployment instead of copy-paste in UI. This adds operational complexity.

**When to use this approach:**
- ✅ If using **upstream Keycloak** (scripts enabled by default)
- ⚠️ If using **RHBK** and comfortable with JAR packaging + pod restarts
- ❌ If using **RHBK** and want simple configuration → Use Option B1 or B2 instead (automated groups)

---

#### Option B1: Dynamic Groups (if LDAP supports it)

```ldif
# Option B1: Dynamic Groups (if your LDAP supports it)
dn: CN=cost-org-1001,OU=CostMgmt,OU=Groups,DC=company,DC=com
objectClass: group
description: Auto-membership for users with costCenter=1001
memberQueryURL: ldap:///OU=Users,DC=company,DC=com??sub?(costCenter=1001)

# Option B2: Shadow Groups with Automated Sync
dn: CN=cost-org-1001,OU=CostMgmt,OU=Groups,DC=company,DC=com
objectClass: group
member: CN=John Doe,OU=Cloud-Platform,OU=Engineering,OU=USA,OU=Americas,OU=Users,DC=company,DC=com
# ^ Populated by script that queries LDAP for costCenter=1001
```

**Implementation for Enterprises**:

1. **Read existing attributes**: `costCenter` → `org_id`, `division` or `employeeType` → `account_number`
2. **Automated sync script** (run daily via cron):
   ```bash
   # Pseudo-code
   for each unique costCenter in LDAP:
     create/update group "CN=cost-org-${costCenter},OU=CostMgmt,OU=Groups"
     add all users with that costCenter as members

   for each unique division in LDAP:
     create/update group "CN=cost-account-${division},OU=CostMgmt,OU=Groups"
     add all users with that division as members
   ```
3. **Keycloak imports** these groups using standard LDAP Group Mapper
4. **Result**: User's `costCenter` and `division` appear as groups in OpenShift

**Benefits:**
- Leverages existing HR-synchronized attributes
- No changes to user objects or OU structure
- Standard enterprise LDAP practice (dynamic/automated groups)
- Single source of truth (HR system → LDAP attributes → Groups → Keycloak)

**Recommendation for 10k+ Employee Enterprises:**

**For Upstream Keycloak:**
- **Priority 1**: Use Protocol Mapper (Option B0) - simplest, 2-minute config

**For RHBK (Red Hat Build of Keycloak) - What We're Using:**
- **Priority 1**: Use Automated Group Sync (Option B1/B2) - simpler than JAR packaging
- **Priority 2**: If you have DevOps resources, use Protocol Mapper with JAR deployment (Option B0)

**Why?** RHBK disables script uploading via UI by default. While you CAN use script mappers by packaging as JAR + deploying to pods, **automated group sync is actually simpler** for RHBK deployments:
- No pod restarts or custom JAR builds
- Standard LDAP operations
- Easier to audit and maintain

**If Protocol Mappers are disabled or you're using RHBK, use Automated Groups (Option B1/B2)**
- **DO NOT** create manual groups for each user
- **DO** use existing LDAP attributes (`costCenter`, `division`, `department`)
- **AUTOMATE** group creation/membership based on those attributes
- This is how large enterprises already manage application access (e.g., SAP, Salesforce)

**LDAP Schema Extension:**
```ldif
# Define custom attributes for clean numeric values
attributeTypes: ( 1.3.6.1.4.1.99999.1.1
  NAME 'organizationId'
  DESC 'Organization ID - clean numeric value'
  EQUALITY caseIgnoreMatch
  SYNTAX 1.3.6.1.4.1.1466.115.121.1.15
  SINGLE-VALUE )

attributeTypes: ( 1.3.6.1.4.1.99999.1.2
  NAME 'accountNumber'
  DESC 'Account number - clean numeric value'
  EQUALITY caseIgnoreMatch
  SYNTAX 1.3.6.1.4.1.1466.115.121.1.15
  SINGLE-VALUE )

# Define custom object class
objectClasses: ( 1.3.6.1.4.1.99999.2.1
  NAME 'costManagementGroup'
  DESC 'Group with cost management attributes'
  SUP groupOfNames
  STRUCTURAL
  MAY ( organizationId $ accountNumber ) )
```

**LDAP Group Structure (Separate OUs for Semantic Distinction):**
```ldif
# Organization groups (under ou=organizations)
dn: cn=engineering,ou=organizations,ou=groups,dc=example,dc=com
objectClass: costManagementGroup
cn: engineering                    # Display name (preserved)
organizationId: 1234567           # Clean numeric value
description: Engineering Team
member: uid=test,ou=users,dc=example,dc=com

# Account groups (under ou=accounts)
dn: cn=account-9876543,ou=accounts,ou=groups,dc=example,dc=com
objectClass: costManagementGroup
cn: account-9876543               # Display name
accountNumber: 9876543            # Clean numeric value
description: Account 9876543
member: uid=test,ou=users,dc=example,dc=com
```

**Keycloak LDAP Group Mappers (2 Mappers for Path Distinction):**
```yaml
Mapper 1: Organizations
  Name: organization-groups-mapper
  LDAP Groups DN: ou=organizations,ou=groups,dc=example,dc=com
  Group Name LDAP Attribute: organizationId  # Reads this field
  Preserve Group Inheritance: true           # Creates /organizations/ path
  Member Attribute: member
  Mode: READ_ONLY
  Result: Keycloak group "/organizations/1234567"

Mapper 2: Accounts
  Name: account-groups-mapper
  LDAP Groups DN: ou=accounts,ou=groups,dc=example,dc=com
  Group Name LDAP Attribute: accountNumber   # Reads this field
  Preserve Group Inheritance: true           # Creates /accounts/ path
  Member Attribute: member
  Mode: READ_ONLY
  Result: Keycloak group "/accounts/9876543"
```

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
- ✅ Clean separation: `cn` preserved for display name, custom attributes for IDs
- ✅ Simple LDAP management: Just 2 extra fields with clean numeric values
- ✅ No prefixes in values: Store "1234567" not "organization_id_1234567"
- ✅ Semantic from structure: OU paths distinguish org_id vs account_number
- ✅ Supports multiple metadata fields: Easy to add more custom attributes
- ✅ Groups remain human-readable in Keycloak UI (path-based)
- ✅ Standard LDAP schema extension (well-supported)
- ✅ Always different values: Two separate fields enforce org_id ≠ account_number
- ✅ Zero credentials in data plane

**Cons:**
- ⚠️ Requires specific LDAP fields to be populated (requires coordination with customer's LDAP administrators)
- ⚠️ Initial schema setup complexity (one-time cost)
- ⚠️ Requires separate OUs for organizations vs accounts

---

### Option 2: Standard LDAP Attribute Repurposing

**Architecture:**
```
LDAP Groups                         Keycloak               OpenShift
─────────────                       ────────               ─────────
cn=Engineering Team                 Group: "org_1234567"   TokenReview:
├── cn: Engineering Team                                   groups:
├── businessCategory: org_1234567 ──┘                      - "org_1234567"
└── member: uid=test
```

**LDAP Group Structure:**
```ldif
dn: cn=Engineering Team,ou=groups,dc=example,dc=com
objectClass: groupOfNames
cn: Engineering Team              # Human-readable name
businessCategory: org_1234567     # Repurposed for org_id
member: uid=test,ou=users,dc=example,dc=com
```

**Keycloak LDAP Group Mapper:**
```yaml
Group Name LDAP Attribute: businessCategory
```

**Authorino Configuration (CEL):**
```yaml
response:
  success:
    headers:
      "X-Auth-Org-Id":
        plain:
          expression: |
            auth.identity.user.groups.filter(g, g.startsWith("org_")).size() > 0
              ? auth.identity.user.groups.filter(g, g.startsWith("org_"))[0].substring(4)
              : ""
```

**Alternative standard attributes:**
- `businessCategory`
- `description`
- `displayName`
- `ou` (organizational unit)
- `departmentNumber`

**Pros:**
- ✅ No LDAP schema changes required
- ✅ Uses standard LDAP attributes
- ✅ Quick to implement
- ✅ Zero credentials in data plane

**Cons:**
- ⚠️ Semantic mismatch (abusing attribute purpose)
- ⚠️ Requires parsing in Authorino if using prefix pattern
- ⚠️ Limited to single repurposed attribute
- ⚠️ May conflict with actual use of that attribute
- ⚠️ Less maintainable (unclear intent)

---

### Option 3: Encoded Group Names (Pattern in `cn`)

**Architecture:**
```
LDAP Groups                              Keycloak                    Authorino
─────────────                            ────────                    ─────────
cn=org_1234567_engineering               Group:                      Parse: extract
└── member: uid=test                     "org_1234567_engineering"   org_id: "1234567"
```

**LDAP Group Structure:**
```ldif
dn: cn=org_1234567_engineering,ou=groups,dc=example,dc=com
objectClass: groupOfNames
cn: org_1234567_engineering    # Pattern: org_{id}_{team}
member: uid=test,ou=users,dc=example,dc=com
```

**Keycloak LDAP Group Mapper:**
```yaml
Group Name LDAP Attribute: cn  # Default
```

**Authorino Configuration (CEL):**
```yaml
response:
  success:
    headers:
      "X-Auth-Org-Id":
        plain:
          expression: |
            auth.identity.user.groups.filter(g, g.startsWith("org_")).size() > 0
              ? auth.identity.user.groups.filter(g, g.startsWith("org_"))[0].split("_")[1]
              : ""
```

**Pros:**
- ✅ No LDAP schema changes
- ✅ Simple to implement
- ✅ Groups still somewhat readable
- ✅ Pattern can be validated
- ✅ Zero credentials in data plane

**Cons:**
- ⚠️ Group names less human-readable in UIs
- ⚠️ Requires string parsing in Authorino (complexity)
- ⚠️ Pattern must be enforced in LDAP (no validation)
- ⚠️ Harder to debug/troubleshoot
- ⚠️ Doesn't scale to multiple metadata fields

---

### Option 4: LDAP Attributes with Claims Service

**Architecture:**
```
LDAP                    Keycloak              PostgreSQL           Claims Service    Authorino
────                    ────────              ──────────           ──────────────    ─────────
uid=test                User Attribute:       user_claims          GET /claims/test  org_id: 1234567
├── orgId: 1234567      orgId: 1234567        ├── test             ↓
└── accountNumber: 789  accountNumber: 789    ├── 1234567          { org_id: 1234567,
                                              └── 789                account: 789 }
                        ↑
                   Sync CronJob
                   (has credentials)
```

**LDAP User Structure:**
```ldif
dn: uid=test,ou=users,dc=example,dc=com
objectClass: inetOrgPerson
uid: test
cn: Test User
orgId: 1234567              # Stored as user attribute
accountNumber: 7890123
```

**Components:**

1. **Keycloak LDAP Attribute Mapper**: Imports `orgId` → user attribute
2. **Sync Service** (isolated namespace with credentials):
   ```python
   # Reads Keycloak Admin API
   # Writes to PostgreSQL
   # Runs every 5 minutes (CronJob)
   ```
3. **Claims Service** (data plane, no credentials):
   ```python
   @app.route('/claims/<username>')
   def get_claims(username):
       # Read-only database access
       return {"org_id": ..., "account_number": ...}
   ```
4. **Authorino Metadata**:
   ```yaml
   metadata:
     "custom-claims":
       http:
         url: "http://claims-service:8080/claims/{auth.identity.user.username}"
         cache:
           ttl: 300
   ```

**Pros:**
- ✅ Supports unlimited custom claims
- ✅ No group name manipulation
- ✅ Clean separation of concerns
- ✅ Credentials isolated in sync service
- ✅ Claims service has zero credentials
- ✅ Cacheable and performant
- ✅ Scales to complex attribute structures

**Cons:**
- ⚠️ Additional infrastructure (database, two services)
- ⚠️ Sync latency (up to 5 minutes for changes)
- ⚠️ More complex operational model
- ⚠️ Requires database backup/management
- ⚠️ Additional network hop on cold cache

---

### Option 5: Keycloak Custom Event Listener (Not Recommended)

**Architecture:**
```
LDAP                    Keycloak Plugin            Keycloak
────                    ───────────────            ────────
uid=test                Event Listener:            Group: "org_1234567"
└── orgId: 1234567      - Listen to user import    User: test
                        - Read orgId attribute         ├── member of ↑
                        - Create/assign group
```

**Implementation:**
- Custom Java plugin for Keycloak
- Listens to `USER_IMPORTED` events
- Reads user attributes
- Creates groups dynamically

**Pros:**
- ✅ Automatic group creation
- ✅ Works with user attributes

**Cons:**
- ❌ Custom code in Keycloak (maintenance burden)
- ❌ Plugin updates required for Keycloak upgrades
- ❌ Debugging complexity
- ❌ Not supported by Red Hat Build of Keycloak
- ❌ Violates simplicity principle
- ❌ Harder to test and deploy

---

### Summary: Enterprise LDAP Integration Options

For customers with existing enterprise LDAP where users have `costCenter` and `division` attributes, here are all available options:

| Option | Description | Complexity | RHBK Compatible | Best For |
|--------|-------------|------------|-----------------|----------|
| **B0: Protocol Mapper** | Keycloak script mapper reads user attrs, injects as groups in token | Low (upstream)<br>High (RHBK) | ⚠️ Yes, but requires JAR packaging | Upstream Keycloak |
| **B1: Dynamic Groups** | LDAP server auto-creates groups from user attrs | Low | ✅ Yes | LDAP with dynamic group support |
| **B2: Sync Script** | CronJob reads user attrs, creates/updates LDAP groups | Medium | ✅ Yes | **RHBK deployments (Recommended)** |

#### Detailed Comparison

**Option B0: Keycloak Protocol Mapper (Script Mapper)**
- **Upstream Keycloak**: ✅ Simple (2-minute config, paste JavaScript in UI)
- **RHBK**: ⚠️ Complex (requires JAR packaging, pod restarts, custom builds)
- **Pros**: No LDAP changes, real-time on login
- **Cons**: RHBK requires JAR deployment (CVE-2022-2668 mitigation)
- **When to use**: Upstream Keycloak deployments only

**Option B1: LDAP Dynamic Groups**
- **Prerequisites**: LDAP server supports `memberQueryURL` (e.g., OpenLDAP with dynlist overlay)
- **Pros**: No external scripts, native LDAP feature, automatic updates
- **Cons**: Not supported by all LDAP servers (Active Directory doesn't support it)
- **When to use**: If your LDAP server supports dynamic groups

**Option B2: Automated Group Sync Script** ⭐ **RECOMMENDED for Enterprise (>10k employees) & RHBK**
- **Implementation**: Kubernetes CronJob runs daily, queries LDAP user attributes, creates/updates groups
- **Why this matches enterprise patterns**:
  - Reads existing HR-synced attributes (`costCenter`, `division`) - no schema changes required
  - Creates groups in isolated OU (`ou=CostMgmt`) - doesn't pollute existing group structure
  - Standard LDAP operations - works with AD, OpenLDAP, Oracle Directory, etc.
  - Auditable and reversible - groups can be inspected/deleted without affecting users
- **Pros**:
  - Works with any LDAP server (AD, OpenLDAP, etc.)
  - Standard LDAP operations
  - No Keycloak customization
  - Auditable (groups visible in LDAP)
  - Simple to maintain
- **Cons**: Groups update daily (not real-time)
- **When to use**: RHBK deployments, enterprise LDAP with standard features

#### Implementation Resources

**For Option B2 (Automated Sync Script):**
1. **Script**: `scripts/ldap-user-attrs-to-groups-sync.sh`
   - Production-ready bash script
   - Reads `costCenter` and `division` from users
   - Creates `CN=org-{value}` and `CN=account-{value}` groups
   - Configurable via environment variables
   - Full logging and error handling

2. **Deployment**: `scripts/ldap-sync-cronjob.yaml`
   - Kubernetes CronJob (runs daily at 2 AM)
   - Secret for LDAP credentials
   - ConfigMap for script
   - Resource limits and security context
   - Network policy template

3. **Configuration**:
   ```bash
   # Edit ldap-sync-cronjob.yaml
   # Update Secret with your LDAP settings:
   LDAP_HOST: "ldap://ldap.company.com:389"
   LDAP_BIND_DN: "CN=svc-keycloak,OU=ServiceAccounts,DC=company,DC=com"
   LDAP_BIND_PASSWORD: "your-password"
   ORG_ID_ATTR: "costCenter"      # Your org_id attribute
   ACCOUNT_ATTR: "division"       # Your account_number attribute

   # Deploy
   kubectl apply -f scripts/ldap-sync-cronjob.yaml

   # Manual run for testing
   kubectl create job --from=cronjob/ldap-user-attrs-sync test-sync-1 -n keycloak
   ```

4. **Monitoring**:
   ```bash
   # Check CronJob status
   kubectl get cronjob ldap-user-attrs-sync -n keycloak

   # View last job logs
   kubectl logs -n keycloak -l app=ldap-sync --tail=100

   # Check created groups in LDAP
   ldapsearch -x -H ldap://ldap.company.com \
     -b "OU=CostMgmt,OU=Groups,DC=company,DC=com" "(cn=org-*)"
   ```

#### Decision Guide for Customers

**Choose Option B0 (Protocol Mapper) if:**
- ✅ Using upstream Keycloak (not RHBK)
- ✅ Want real-time updates on login
- ✅ Don't want to manage LDAP groups
- ❌ Using RHBK (too complex with JAR packaging)

**Choose Option B1 (Dynamic Groups) if:**
- ✅ LDAP server supports dynamic groups (OpenLDAP with dynlist)
- ✅ Want native LDAP solution
- ✅ Can't run external sync scripts
- ❌ Using Active Directory (doesn't support memberQueryURL)

**Choose Option B2 (Sync Script) if:** ⭐
- ✅ Using RHBK (Red Hat Build of Keycloak)
- ✅ Using Active Directory or standard LDAP
- ✅ Want simple, maintainable solution
- ✅ Can run Kubernetes CronJobs
- ✅ Daily sync frequency is acceptable
- ✅ This is **recommended for production RHBK deployments**

---

## Decision Outcome

**Chosen Option: Automated Group Sync with CEL-based Extraction (Option B2 variant)**

### Actual Implementation (POC Verified)

We implemented a variant that combines:
- **LDAP user attributes** (`costCenter`, `accountNumber`) as the source of truth
- **Sync script** that creates `cost-mgmt-org-{id}` and `cost-mgmt-account-{id}` groups
- **Keycloak Group Mapper** to sync groups to JWT tokens
- **CEL expressions** in Authorino to extract values from group names

### Rationale

1. **CEL over Rego**: Rego is being deprecated in Authorino; CEL is the recommended approach
2. **Flat Group Names**: `cost-mgmt-org-1234567` is simpler than hierarchical paths like `/organizations/1234567`
3. **User Attributes as Source**: Enterprise LDAPs typically have `costCenter`/`division` as user attributes, not group attributes
4. **Sync Script Flexibility**: Works with any LDAP (AD, OpenLDAP) without requiring dynamic group support
5. **Zero Credentials in Data Plane**: Authorino has no Keycloak or LDAP credentials
6. **RHBK Compatible**: No script mappers required (avoids JAR packaging complexity)

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

If we need more claims than can fit in group names, we can migrate to **Option 4 (Claims Service)** without breaking changes:

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
- `scripts/configure-keycloak-ldap.sh` - Keycloak configuration
- `scripts/deploy-ldap-demo.sh` - Demo LDAP with test users
- `docs/ldap-rhbk-configuration-guide.md` - Configuration guide

---

## Consequences

### Positive

- **Automated**: LDAP → Keycloak → OpenShift → Authorino flow is fully automated
- **Scalable**: Supports thousands of organizations without performance impact
- **Secure**: No credentials stored in data plane services
- **Maintainable**: Clear schema and explicit intent
- **Debuggable**: Groups visible in Keycloak, OpenShift, and logs
- **Future-proof**: Easy to add more attributes to the schema

### Negative

- **Schema Management**: Requires LDAP administrator access for initial setup
- **One-time Complexity**: Schema extension requires careful planning
- **Dependency**: Solution depends on LDAP schema capabilities

### Neutral

- **LDAP Expertise Required**: Team needs LDAP schema extension knowledge (one-time learning)
- **Testing**: Requires LDAP test environment for validation
- **Documentation**: Must document schema for operations team

## Alternatives for Future Consideration

If requirements change significantly (e.g., need for 10+ custom claims), consider migrating to:

- **Option 4 (Claims Service)**: For complex claim structures
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
**Last updated:** 2025-12-04
**Review date:** 2026-03-04 (3 months)

