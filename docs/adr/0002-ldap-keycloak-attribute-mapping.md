# ADR 0002: LDAP to Keycloak Attribute Mapping for org_id and account_number

## Status

**Draft** - Exploring scenarios

Date: 2025-12-05

---

## Context

Cost Management requires `org_id` and `account_number` to identify users' organizational context. These values originate in customer LDAP directories and must flow through Keycloak to the application.

**We don't control customer LDAP schemas.** Customers will have their own attribute names (e.g., `costCenter`, `departmentNumber`, `employeeNumber`, `division`) that map to our required `org_id` and `account_number`.

This document explores the different Keycloak-LDAP synchronization scenarios we may encounter and how to ensure correct attribute mapping in each.

---

## Keycloak LDAP Synchronization Modes

Keycloak offers different modes for LDAP integration. The customer's choice affects how we retrieve attributes.

### Storage Modes

| Mode | Description | LDAP Queried When | Use Case |
|------|-------------|-------------------|----------|
| **READ_ONLY** | Keycloak caches users, reads from LDAP | On sync schedule + login | Most enterprises |
| **WRITABLE** | Bi-directional sync | On sync + login | Self-service scenarios |
| **UNSYNCED** | Import once, local changes only | Initial import only | Migration scenarios |

### Sync Mechanisms

| Mechanism | When It Runs | What It Does |
|-----------|--------------|--------------|
| **Periodic Full Sync** | Scheduled (e.g., daily) | Imports all LDAP users to Keycloak |
| **Periodic Changed Users Sync** | Scheduled (e.g., hourly) | Imports only changed users |
| **On-Demand (Login)** | User login | Fetches user from LDAP if not cached |

---

## Scenarios

### Scenario A: Cacheless / On-Demand Only

**Customer Configuration:**
- No periodic sync configured
- Users imported on first login only
- Keycloak queries LDAP on each login

**Characteristics:**
```
User Login → Keycloak → LDAP Query → Fresh attributes → Protocol Mapper → JWT
```

**Pros:**
- Always fresh data from LDAP
- No stale cache concerns
- Simpler configuration

**Cons:**
- LDAP must be available for every login
- Slightly higher login latency
- No offline user management in Keycloak

**Protocol Mapper Behavior:**
- ✅ Works correctly - attributes are fresh from LDAP at login time

---

### Scenario B: Cached with Periodic Sync

**Customer Configuration:**
- Periodic Full Sync: Daily at 2 AM
- Periodic Changed Users Sync: Every 4 hours
- Users cached in Keycloak database

**Characteristics:**
```
LDAP Change → (wait up to 4 hours) → Keycloak Sync → Cache Updated → Next Login → Protocol Mapper
```

**Pros:**
- Faster logins (no LDAP query)
- Works if LDAP temporarily unavailable
- User management in Keycloak UI

**Cons:**
- Stale data possible (up to sync interval)
- User attribute changes not immediate

**Protocol Mapper Behavior:**
- ⚠️ Reads from Keycloak cache, not live LDAP
- ⚠️ Attribute changes delayed until next sync
- ✅ Still works, but with sync delay

**Mitigation for Cached Scenario:**

If customer uses cached mode and needs faster attribute updates:

1. **Reduce sync interval** (e.g., hourly instead of daily)
2. **Force user re-sync on demand:**
   ```bash
   # Trigger sync via Keycloak Admin API
   POST /admin/realms/{realm}/user-storage/{ldap-federation-id}/sync?action=triggerChangedUsersSync
   ```
3. **Invalidate specific user cache:**
   ```bash
   # Remove user from Keycloak to force re-import
   DELETE /admin/realms/{realm}/users/{user-id}
   # User re-imported from LDAP on next login
   ```

---

### Scenario C: LDAP Attribute Changes Mid-Session

**Situation:**
- User logged in with `org_id: 1234567`
- LDAP admin changes user's `costCenter` to `9999999`
- User's existing session/token still has old value

**Impact:**
- Active tokens contain old `org_id` until token expires
- New logins get new `org_id`
- No way to invalidate existing tokens automatically

**Mitigation:**
1. **Token expiration**: Set reasonable token lifetime (e.g., 5-15 minutes)
2. **Session invalidation**: Keycloak admin can terminate user sessions
3. **Application-level**: Backend could validate against live source (adds latency)

---

## Recommended Solution: Protocol Mapper

The Protocol Mapper approach works for all scenarios because it reads attributes at **token generation time**.

### How It Works

```
                    Scenario A (Cacheless)           Scenario B (Cached)
                    ─────────────────────           ───────────────────
User Login    →     LDAP Query                      Keycloak Cache
                         ↓                               ↓
Keycloak      →     User attributes loaded          User attributes loaded
                         ↓                               ↓
Token Gen     →     Protocol Mapper reads           Protocol Mapper reads
                    user.getFirstAttribute()        user.getFirstAttribute()
                         ↓                               ↓
JWT           →     groups: [cost-mgmt-org-X]       groups: [cost-mgmt-org-X]
```

**Key Point:** Protocol Mapper reads from Keycloak's user model, regardless of whether that data came from live LDAP query or cache.

### Configuration

**Keycloak Realm Attributes (per customer):**

| Customer | LDAP Attribute for org_id | LDAP Attribute for account_number |
|----------|---------------------------|-----------------------------------|
| Customer A | `costCenter` | `departmentNumber` |
| Customer B | `employeeNumber` | `employeeType` |
| Customer C | `division` | `businessUnit` |

```bash
# Set via Keycloak Admin API
curl -X PUT "https://keycloak/admin/realms/{realm}" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
    "attributes": {
      "cost-mgmt-org-attr": "costCenter",
      "cost-mgmt-account-attr": "departmentNumber"
    }
  }'
```

### Protocol Mapper Script (Universal)

```javascript
// Reads attribute names from realm config - works for any customer
var realmAttrs = realm.getAttributes();
var orgAttrName = realmAttrs.get("cost-mgmt-org-attr") || "costCenter";
var accountAttrName = realmAttrs.get("cost-mgmt-account-attr") || "departmentNumber";

var orgId = user.getFirstAttribute(orgAttrName);
var accountNumber = user.getFirstAttribute(accountAttrName);

var groups = token.getOtherClaims().get("groups") || new java.util.ArrayList();

if (orgId) groups.add("cost-mgmt-org-" + orgId);
if (accountNumber) groups.add("cost-mgmt-account-" + accountNumber);

token.getOtherClaims().put("groups", groups);
```

---

## Alternative: LDAP Group Sync (for Cached Scenarios)

If customer prefers not to use Protocol Mapper JAR, they can create actual LDAP groups that Keycloak syncs.

### Approach

1. **Create groups in LDAP** matching the naming convention:
   ```ldif
   dn: cn=cost-mgmt-org-1234567,ou=CostMgmt,ou=Groups,dc=example,dc=com
   objectClass: groupOfNames
   cn: cost-mgmt-org-1234567
   member: uid=user1,ou=Users,dc=example,dc=com
   member: uid=user2,ou=Users,dc=example,dc=com
   ```

2. **Configure Keycloak LDAP Group Mapper:**
   ```yaml
   Name: cost-mgmt-groups
   LDAP Groups DN: ou=CostMgmt,ou=Groups,dc=example,dc=com
   Group Name LDAP Attribute: cn
   Membership LDAP Attribute: member
   Mode: READ_ONLY
   ```

3. **Keycloak syncs groups** → Users get group memberships → OpenShift imports

### Trade-offs

| Aspect | Protocol Mapper | LDAP Group Sync |
|--------|-----------------|-----------------|
| LDAP changes required | ❌ None | ✅ Create groups |
| Keycloak JAR required | ✅ Yes | ❌ No |
| Attribute flexibility | ✅ Any user attribute | ❌ Must create groups |
| Sync delay | Login-time only | Full sync cycle |
| Management | Keycloak config | LDAP + Keycloak |

---

## Decision Matrix

| Scenario | Recommended Approach | Notes |
|----------|---------------------|-------|
| Cacheless Keycloak | Protocol Mapper | Fresh data on every login |
| Cached, short sync interval | Protocol Mapper | Acceptable delay |
| Cached, long sync interval | Protocol Mapper + reduce interval | Or force sync on attribute change |
| Customer won't deploy JAR | LDAP Group Sync | Requires LDAP admin cooperation |
| Customer has existing org groups | LDAP Group Sync | Leverage existing structure |

---

## Verification Steps

### For Cached Scenario

1. **Check sync settings:**
   ```bash
   curl -s "$KEYCLOAK_URL/admin/realms/$REALM/components?type=org.keycloak.storage.UserStorageProvider" \
     -H "Authorization: Bearer $TOKEN" | jq '.[0].config'
   ```

2. **Verify user attributes are current:**
   ```bash
   curl -s "$KEYCLOAK_URL/admin/realms/$REALM/users?username=test" \
     -H "Authorization: Bearer $TOKEN" | jq '.[0].attributes'
   ```

3. **Force sync if needed:**
   ```bash
   curl -X POST "$KEYCLOAK_URL/admin/realms/$REALM/user-storage/$LDAP_ID/sync?action=triggerFullSync" \
     -H "Authorization: Bearer $TOKEN"
   ```

---

## Related Documents

- [ADR 0001: LDAP Organization ID Mapping](./0001-ldap-organization-id-mapping.md) - Original comprehensive ADR
- [ADR 0003: Authorino org_id Extraction](./0003-authorino-org-extraction.md) - How Authorino extracts values

---

**Last updated:** 2025-12-05


