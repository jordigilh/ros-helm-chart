# ADR 0001: LDAP Organization ID Mapping to Keycloak Groups

## Status

**Accepted**

Date: 2025-12-04

## Context

Cost Management on-premises requires extracting organization IDs (`org_id`) for users authenticating through OpenShift OAuth integrated with Keycloak and LDAP.

### Current Architecture

1. Users authenticate via OpenShift console (OAuth flow)
2. OpenShift OAuth delegates to Keycloak (OIDC Identity Provider)
3. Keycloak federates users from LDAP
4. API requests go through Envoy → Authorino
5. Authorino validates tokens using Kubernetes TokenReview API
6. Authorino must extract `org_id` and inject it as `x-auth-request-org-id` header

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
- LDAP schema is under our control (greenfield deployment)

## Considered Options

### Option 1: Custom LDAP Attribute with Keycloak Group Mapper (RECOMMENDED)

**Architecture:**
```
LDAP Groups                    Keycloak               OpenShift          Authorino
─────────────                  ────────               ─────────          ─────────
cn=engineering                 Group: "1234567"       TokenReview:       org_id: "1234567"
├── cn: engineering            ↑                      groups:            (direct use)
├── organizationId: 1234567 ───┘                      - "1234567"
└── member: uid=test
```

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

**Authorino Configuration (Parse Group Paths):**
```yaml
apiVersion: authorino.kuadrant.io/v1beta2
kind: AuthConfig
metadata:
  name: cost-management-auth
spec:
  authentication:
    "k8s-tokenreview":
      kubernetesTokenReview:
        audiences: ["https://kubernetes.default.svc"]
  metadata:
    "parse-org-claims":
      opa:
        inlineRego: |
          package authz
          # Extract org_id from /organizations/ path
          org_id := substring(group, 16, -1) if {
            some group in input.auth.identity.groups
            startswith(group, "/organizations/")
          }
          # Extract account_number from /accounts/ path
          account_number := substring(group, 10, -1) if {
            some group in input.auth.identity.groups
            startswith(group, "/accounts/")
          }
  response:
    success:
      headers:
        "x-auth-request-org-id":
          json:
            selector: "auth.metadata.parse-org-claims.org_id"
        "x-auth-request-account-number":
          json:
            selector: "auth.metadata.parse-org-claims.account_number"
```

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
- ⚠️ Requires LDAP schema extension (acceptable for greenfield)
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

**Authorino Configuration:**
```yaml
metadata:
  "parse-org-id":
    opa:
      inlineRego: |
        package authz
        org_id := substring(group, 4, -1) if {  # Remove "org_" prefix
          some i
          group := input.auth.identity.user.groups[i]
          startswith(group, "org_")
        }
response:
  success:
    headers:
      "x-auth-request-org-id":
        json:
          selector: "auth.metadata.parse-org-id.org_id"
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

**Authorino Configuration:**
```yaml
metadata:
  "parse-org-id":
    opa:
      inlineRego: |
        package authz
        org_id := split(group, "_")[1] if {
          some i
          group := input.auth.identity.user.groups[i]
          startswith(group, "org_")
          count(split(group, "_")) >= 2
        }
response:
  success:
    headers:
      "x-auth-request-org-id":
        json:
          selector: "auth.metadata.parse-org-id.org_id"
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

## Decision Outcome

**Chosen Option: Option 1 - Custom LDAP Attribute with Keycloak Group Mapper**

### Rationale

1. **Clean Architecture**: Clear separation between display names (`cn`) and technical identifiers (`organizationId`)
2. **No Parsing Overhead**: Authorino can use group values directly without string manipulation
3. **Extensibility**: Easy to add more custom attributes (e.g., `accountPrefix`, `customerType`) in the future
4. **Standard Approach**: LDAP schema extensions are well-supported and documented
5. **Maintainability**: Explicit schema makes intent clear to operators
6. **Zero Credentials in Data Plane**: Authorino has no Keycloak or LDAP credentials
7. **Performance**: No additional HTTP calls or parsing logic

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
- [ ] Test header injection: `x-auth-request-org-id`
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

