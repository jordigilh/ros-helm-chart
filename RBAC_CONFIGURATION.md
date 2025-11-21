# RBAC Configuration for On-Prem Koku

## Current Configuration

The on-prem deployment already has RBAC bypass configured in `values-koku.yaml`:

### 1. Development Mode
```yaml
DEVELOPMENT: "True"  # Enable on-prem mode (bypass RBAC service)
```

**What this does:**
- ✅ Disables calls to external RBAC service
- ✅ Uses local identity header processing
- ✅ Enables `DevelopmentIdentityHeaderMiddleware`
- ❌ **Does NOT bypass permission checks** (still checks `user.access`)

### 2. Enhanced Org Admin
```yaml
ENHANCED_ORG_ADMIN: "True"  # Allow org admins to bypass RBAC checks
```

**What this does:**
- ✅ Bypasses RBAC permission checks for users with `"is_org_admin": true`
- ✅ Works in all permission classes (`AwsAccessPermission`, `GcpAccessPermission`, etc.)
- ✅ Production-safe approach

**Code Reference** (`api/common/permissions/aws_access.py:17-18`):
```python
if settings.ENHANCED_ORG_ADMIN and request.user.admin:
    return True
```

---

## Why IQE Tests Still Fail with 403

Despite `ENHANCED_ORG_ADMIN=True`, the IQE tests are still getting 403 Forbidden errors.

### Possible Root Causes

#### 1. Pod Environment Not Reflecting Helm Values
**Check if the setting is actually applied:**
```bash
kubectl exec -n cost-mgmt deploy/koku-koku-api-reads -- env | grep ENHANCED_ORG_ADMIN
```

**Expected:** `ENHANCED_ORG_ADMIN=True`  
**If missing:** Helm values not applied or pods not restarted

**Solution:**
```bash
# Force pod restart to pick up new env vars
kubectl rollout restart deployment/koku-koku-api-reads -n cost-mgmt
kubectl rollout restart deployment/koku-koku-api-writes -n cost-mgmt
```

#### 2. Identity Header Not Being Processed Correctly
The `x-rh-identity` header might not be parsed correctly, causing `request.user.admin` to be `False`.

**Check API logs:**
```bash
kubectl logs -n cost-mgmt deploy/koku-koku-api-reads -f | grep -i "identity\|admin\|403"
```

**Look for:**
- `"is_org_admin": True` in the log
- Permission denial messages
- Identity parsing errors

#### 3. Port-Forward Bypassing Middleware
If the E2E tests use `kubectl port-forward`, the request might not go through all middleware layers.

**Workaround:** Use direct service access:
```bash
# Instead of localhost:8000
# Use the service DNS:
http://koku-koku-api-reads.cost-mgmt.svc:8080/api/cost-management/v1/...
```

#### 4. Development Mode Interfering
The `DEVELOPMENT=True` setting enables `DevelopmentIdentityHeaderMiddleware` which might override the x-rh-identity header.

**Check if `FORCE_HEADER_OVERRIDE` is set:**
```bash
kubectl exec -n cost-mgmt deploy/koku-koku-api-reads -- env | grep FORCE_HEADER_OVERRIDE
```

**If set to "True":** It will override all incoming headers with `DEVELOPMENT_IDENTITY` from settings

**Solution:** Ensure `FORCE_HEADER_OVERRIDE` is `False` or unset

---

## Alternative: Fully Disable RBAC (Not Recommended for Production)

If you want to **completely bypass all RBAC checks** for testing:

### Option 1: Mock All Permission Classes
Create a custom middleware that sets `request.user.access` to wildcard permissions:

```python
# In Koku settings.py or custom middleware
class MockRBACMiddleware:
    def process_request(self, request):
        if hasattr(request, 'user'):
            request.user.access = {
                "aws.account": {"read": ["*"]},
                "azure.subscription_guid": {"read": ["*"]},
                "gcp.account": {"read": ["*"]},
                "gcp.project": {"read": ["*"]},
                "openshift.cluster": {"read": ["*"]},
                "openshift.project": {"read": ["*"]},
                "openshift.node": {"read": ["*"]},
            }
```

### Option 2: Patch Permission Classes
Temporarily modify all permission classes to always return `True`:

```python
# NOT RECOMMENDED - Only for debugging
from api.common.permissions import aws_access, gcp_access, azure_access, openshift_access

def bypass_all_permissions(request, view):
    return True

aws_access.AwsAccessPermission.has_permission = bypass_all_permissions
gcp_access.GcpAccessPermission.has_permission = bypass_all_permissions
azure_access.AzureAccessPermission.has_permission = bypass_all_permissions
openshift_access.OpenShiftAccessPermission.has_permission = bypass_all_permissions
```

---

## Recommended Debugging Steps

### Step 1: Verify Environment Variables
```bash
kubectl exec -n cost-mgmt deploy/koku-koku-api-reads -- env | grep -E "ENHANCED_ORG_ADMIN|DEVELOPMENT|FORCE_HEADER_OVERRIDE"
```

**Expected output:**
```
DEVELOPMENT=True
ENHANCED_ORG_ADMIN=True
FORCE_HEADER_OVERRIDE=False  # or unset
```

### Step 2: Test Identity Header Manually
```bash
# Create test identity (org admin with wildcard access)
IDENTITY=$(echo -n '{"identity":{"account_number":"10001","org_id":"1234567","type":"User","user":{"username":"test-admin","email":"test@example.com","is_org_admin":true,"access":{"aws.account":{"read":["*"]}}}},"entitlements":{"cost_management":{"is_entitled":true}}}' | base64)

# Test API call
kubectl exec -n cost-mgmt deploy/koku-koku-api-reads -- curl -s -H "x-rh-identity: $IDENTITY" http://localhost:8080/api/cost-management/v1/status/ | jq
```

**Expected:** 200 OK with status response  
**Actual:** 403 Forbidden (current issue)

### Step 3: Check API Logs for RBAC Checks
```bash
kubectl logs -n cost-mgmt deploy/koku-koku-api-reads --tail=100 | grep -A 5 -B 5 "AwsAccessPermission\|has_permission\|RBAC"
```

### Step 4: Verify Middleware Order
The `IdentityHeaderMiddleware` must run **before** permission checks.

**Check middleware configuration:**
```bash
kubectl exec -n cost-mgmt deploy/koku-koku-api-reads -- python -c "
from koku import settings
for mw in settings.MIDDLEWARE:
    print(mw)
"
```

**Expected order:**
1. `koku.middleware.IdentityHeaderMiddleware` (parses header)
2. `koku.dev_middleware.DevelopmentIdentityHeaderMiddleware` (if DEVELOPMENT=True)
3. ... other middleware ...
4. (Permission checks happen in views, not middleware)

---

## IQE Test Configuration

The IQE tests currently use `conftest_onprem.py` which creates an `x-rh-identity` header with:

```python
identity = {
    "identity": {
        "account_number": "10001",
        "org_id": "1234567",
        "type": "User",
        "user": {
            "username": "cost-mgmt-user",
            "email": "test@example.com",
            "is_org_admin": True,  # ← Should bypass RBAC with ENHANCED_ORG_ADMIN
            "access": {
                "aws.account": {"read": ["*"]},
                "azure.subscription_guid": {"read": ["*"]},
                "gcp.account": {"read": ["*"]},
                # ... all providers with wildcard
            }
        }
    },
    "entitlements": {
        "cost_management": {"is_entitled": True}
    }
}
```

**This should work** with `ENHANCED_ORG_ADMIN=True`, but it's not. Something is preventing the setting from taking effect.

---

## Next Steps

1. **Verify pod environment:** Ensure `ENHANCED_ORG_ADMIN=True` is set in running pods
2. **Restart pods:** Force restart to pick up any missed environment variables
3. **Check logs:** Look for identity parsing and permission check logs
4. **Test manually:** Use the curl command above to isolate the issue
5. **Consider Django shell:** Use `manage.py shell` to check settings directly:
   ```bash
   kubectl exec -n cost-mgmt deploy/koku-koku-api-reads -it -- python koku/manage.py shell
   >>> from django.conf import settings
   >>> settings.ENHANCED_ORG_ADMIN
   >>> settings.DEVELOPMENT
   ```

---

## Production Recommendation

For production on-prem deployments:

✅ **Keep:** `ENHANCED_ORG_ADMIN=True`  
✅ **Keep:** `DEVELOPMENT=True` (for on-prem without RBAC service)  
❌ **Never set:** `FORCE_HEADER_OVERRIDE=True` (breaks authentication)  
✅ **Ensure:** All API users have `"is_org_admin": true` in their identity header

This provides the best balance of security and functionality for on-prem environments without an external RBAC service.

