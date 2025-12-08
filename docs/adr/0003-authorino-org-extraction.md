# ADR 0003: Extracting org_id and account_number in Authorino

## Status

**Draft** - Exploring options

Date: 2025-12-05

---

## Context

After Keycloak maps LDAP attributes to JWT claims/groups, Authorino must extract `org_id` and `account_number` from the OpenShift TokenReview response and pass them to the backend via headers.

**Constraint:** OpenShift TokenReview returns (verified from k8s.io/api/authentication/v1/types.go):
- `username` - string
- `uid` - string
- `groups` - []string
- `extra` - map[string][]string (but only contains OpenShift scopes)

**Verified TokenReview Response:**
```yaml
status:
  user:
    username: "test"
    uid: "9001a806-34bc-49c6-83ed-975afce983f3"
    groups: ["cost-mgmt-org-1234567", "cost-mgmt-account-9876543", ...]
    extra:
      scopes.authorization.openshift.io: ["user:full"]  # ← Only scopes, not custom fields
```

It does **NOT** return:
- `email` - Not part of UserInfo struct
- Custom `extra` fields - OpenShift only populates with OAuth scopes, not Keycloak/LDAP attributes

This document explores different encoding strategies for passing org_id and account_number through TokenReview.

---

## What TokenReview Returns

**Kubernetes Source (k8s.io/api/authentication/v1/types.go):**
```go
type UserInfo struct {
    Username string                `json:"username,omitempty"`
    UID      string                `json:"uid,omitempty"`
    Groups   []string              `json:"groups,omitempty"`
    Extra    map[string]ExtraValue `json:"extra,omitempty"`
}
```

**Actual OpenShift TokenReview Response (Verified):**
```yaml
status:
  authenticated: true
  user:
    username: "test"
    uid: "9001a806-34bc-49c6-83ed-975afce983f3"
    groups:
      - "cost-mgmt-org-1234567"      # ← We can encode data here
      - "cost-mgmt-account-9876543"  # ← We can encode data here
      - "system:authenticated:oauth"
      - "system:authenticated"
    extra:
      scopes.authorization.openshift.io:   # ← Only OAuth scopes
        - "user:full"
```

**Available fields for encoding:**
- ✅ `groups` - Array of strings, can contain any value we put in JWT
- ⚠️ `username` - Single string, but used for display/audit
- ❌ `uid` - System-generated UUID, not controllable
- ❌ `extra` - Only contains OAuth scopes, not custom fields from IDP
- ❌ `email` - Not part of UserInfo struct
- ❌ Custom claims - Not supported by TokenReview API

---

## Option 1: Synthetic Groups (Current Implementation) ✅

**Encoding:** Create group names that contain the values.

```
Groups: ["cost-mgmt-org-1234567", "cost-mgmt-account-9876543"]
                      └────────┘                   └────────┘
                       org_id                    account_number
```

### Authorino CEL Extraction

```yaml
response:
  success:
    headers:
      "X-Auth-Org-Id":
        plain:
          expression: |
            auth.identity.user.groups.filter(g, g.startsWith("cost-mgmt-org-")).size() > 0
              ? auth.identity.user.groups.filter(g, g.startsWith("cost-mgmt-org-"))[0].substring(14)
              : ""
      "X-Auth-Account-Number":
        plain:
          expression: |
            auth.identity.user.groups.filter(g, g.startsWith("cost-mgmt-account-")).size() > 0
              ? auth.identity.user.groups.filter(g, g.startsWith("cost-mgmt-account-"))[0].substring(18)
              : ""
```

### Characteristics

| Aspect | Assessment |
|--------|------------|
| **Encoding** | Clean prefix-based naming |
| **Extraction** | Simple CEL string operations |
| **OpenShift Impact** | Creates persistent Group objects |
| **Stale Data** | Groups persist after attribute change |
| **Cleanup Required** | ✅ Yes - CronJob needed |

### The Stale Group Problem

```
Timeline:
─────────────────────────────────────────────────────────────────────────
T0: User logs in, org_id=1234567
    → Group created: cost-mgmt-org-1234567 [members: test]

T1: LDAP admin changes user's org_id to 9999999

T2: User logs in again
    → New group created: cost-mgmt-org-9999999 [members: test]
    → Old group still exists: cost-mgmt-org-1234567 [members: test]  ← STALE

T3: TokenReview returns BOTH groups
    → CEL takes [0] → might return wrong org_id
─────────────────────────────────────────────────────────────────────────
```

### Mitigation: Reconciliation CronJob

```yaml
# Runs every 15 minutes
# 1. Queries Keycloak for current user attributes
# 2. Compares with OpenShift groups
# 3. Removes stale memberships
# 4. Deletes empty groups
```

See: `scripts/reconcile-groups-cronjob.yaml`

---

## Option 2: Email Encoding (Explored)

**Idea:** Encode org_id and account_number in the email field.

```
email: "jgil@redhat.com[org_id=1234567|account_number=9876543]"
```

### Analysis

**Problem:** TokenReview does **NOT** return email.

```yaml
# What we'd need:
status:
  user:
    email: "jgil@redhat.com[org_id=1234567|account_number=9876543]"  # ❌ NOT AVAILABLE

# What we actually get:
status:
  user:
    username: "test"
    groups: [...]
    # No email field
```

### Could We Map Email to Username?

```yaml
# Keycloak OIDC claim mapping
claims:
  preferredUsername:
    - email  # Map email to username
```

**Problems:**
1. Username would show encoded string in UI: `jgil@redhat.com[org_id=1234567|...]`
2. Breaks username-based lookups
3. Email validation might reject the format
4. Non-standard, confusing for users

### Verdict

❌ **Not viable** - TokenReview doesn't expose email, and workarounds break UX.

---

## Option 3: Username Suffix Encoding (Explored)

**Idea:** Append org_id/account_number to username.

```
username: "test::org=1234567::account=9876543"
```

### Analysis

**Technically possible** but severely impacts UX:

| Impact | Description |
|--------|-------------|
| UI Display | User sees `test::org=1234567::account=9876543` everywhere |
| Logs | All audit logs show encoded username |
| `oc whoami` | Returns encoded string |
| User confusion | High |

### Verdict

❌ **Not recommended** - Severely degrades user experience.

---

## Option 4: Extra Field Encoding (Explored)

**Idea:** Use TokenReview's `extra` field.

```yaml
# What we'd want:
status:
  user:
    extra:
      org_id: ["1234567"]
      account_number: ["9876543"]

# What we actually get (verified):
status:
  user:
    extra:
      scopes.authorization.openshift.io: ["user:full"]  # Only this!
```

### Analysis

**Problem:** OpenShift OAuth only populates `extra` with OAuth scopes (`scopes.authorization.openshift.io`). There's no mechanism to pass custom fields from Keycloak/LDAP through to `extra`.

**Verified:** TokenReview response shows `extra` contains only:
- `scopes.authorization.openshift.io: ["user:full"]`

To add custom extra fields would require:
1. Modifying OpenShift OAuth server code (not feasible)
2. A mutating webhook on TokenReview responses (complex, security implications)

### Verdict

❌ **Not viable** - OpenShift OAuth hardcodes `extra` to only contain scopes.

---

## Comparison Summary

| Option | Viable | Stale Data | Cleanup | UX Impact | Notes |
|--------|--------|------------|---------|-----------|-------|
| **1: Synthetic Groups** | ✅ Yes | ⚠️ Yes | CronJob | None | **Recommended** |
| **2: Email Encoding** | ❌ No | N/A | N/A | N/A | TokenReview doesn't return email |
| **3: Username Suffix** | ⚠️ Possible | ❌ No | None | High | Breaks UX |
| **4: Extra Fields** | ❌ No | N/A | N/A | N/A | Only contains OAuth scopes |

**Bottom line:** Only `groups` is a viable encoding mechanism given TokenReview's limited response fields.

---

## Recommended Approach

**Option 1: Synthetic Groups** remains the best choice because:

1. **TokenReview compatibility** - Groups are the only flexible field available
2. **Clean extraction** - Simple prefix-based CEL parsing
3. **Standard mechanism** - Uses OpenShift's native group system
4. **No UX impact** - Users see normal usernames
5. **Manageable downside** - Stale groups handled by CronJob

### Implementation

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Keycloak Protocol Mapper                                               │
│  - Reads user LDAP attributes                                           │
│  - Generates: cost-mgmt-org-{org_id}, cost-mgmt-account-{account}      │
│  - Adds to JWT groups claim                                             │
└─────────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────────┐
│  OpenShift OAuth                                                        │
│  - Imports groups from JWT                                              │
│  - Creates Group objects (persistent)                                   │
│  - Adds user to groups                                                  │
└─────────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────────┐
│  TokenReview                                                            │
│  - Returns: username, uid, groups                                       │
│  - Groups include: cost-mgmt-org-1234567, cost-mgmt-account-9876543    │
└─────────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────────┐
│  Authorino CEL                                                          │
│  - Filters groups by prefix                                             │
│  - Extracts numeric values                                              │
│  - Sets X-Auth-Org-Id, X-Auth-Account-Number headers                   │
└─────────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────────┐
│  Reconciliation CronJob (every 15 min)                                  │
│  - Compares Keycloak attributes with OpenShift groups                   │
│  - Removes stale memberships                                            │
│  - Deletes empty groups                                                 │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Future Considerations

### If OpenShift Adds Custom TokenReview Fields

If OpenShift OAuth ever supports custom fields in TokenReview response, we could:
1. Pass org_id/account_number directly (no encoding)
2. Eliminate synthetic groups
3. Remove reconciliation CronJob

### If Using Service Mesh with JWT

If the architecture moves to JWT-based authentication (not opaque tokens):
1. Authorino can read JWT claims directly
2. No TokenReview needed
3. No persistent groups
4. But requires UI token lifecycle management

---

## Related Documents

- [ADR 0001: LDAP Organization ID Mapping](./0001-ldap-organization-id-mapping.md) - Original comprehensive ADR
- [ADR 0002: LDAP-Keycloak Attribute Mapping](./0002-ldap-keycloak-attribute-mapping.md) - How attributes flow to Keycloak
- `scripts/reconcile-groups-cronjob.yaml` - Group cleanup implementation

---

**Last updated:** 2025-12-05

