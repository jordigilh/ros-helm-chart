# Clean Installation Test - RHBK Admin Secret Issue

**Date**: November 10, 2025
**Purpose**: Reproduce the admin secret timing issue on fresh installations

## Issue Description

On first-time RHBK installations, the `keycloak-initial-admin` secret may not be created immediately by the RHBK operator, causing the `create_kubernetes_realm()` function to fail when trying to access the password at line 733.

**Current Behavior on Re-runs**: The issue doesn't appear because the secret already exists from previous installations.

## Test Plan

### Step 1: Complete Cleanup
Run comprehensive cleanup to ensure pristine environment:

```bash
cd /Users/jgil/go/src/github.com/insights-onprem/ros-helm-chart/scripts
./cleanup-all-components.sh
```

This will remove:
- All namespaces (keycloak, cost-mgmt, kruize, sources, authorino, kafka)
- All Helm releases
- All operator subscriptions, CSVs, InstallPlans
- All CRDs (Custom Resource Definitions)
- All ClusterRoles and ClusterRoleBindings
- All webhooks (Mutating and Validating)
- Container images from nodes (optional but recommended)

### Step 2: Verify Clean State
Check that everything is removed:

```bash
# Check namespaces
oc get namespace | grep -E "keycloak|cost-mgmt|kruize|sources|authorino|kafka"

# Check CRDs
oc get crd | grep -E "keycloak|kafka|strimzi|authorino|kruize"

# Check operators
oc get csv -A | grep -E "keycloak|rhbk|kafka|strimzi|authorino"

# Check PVCs
oc get pvc -A | grep -E "keycloak|postgres|kafka"
```

Expected output: No resources found (or empty)

### Step 3: Fresh RHBK Deployment
Run deploy-rhbk.sh and watch for the issue:

```bash
cd /Users/jgil/go/src/github.com/insights-onprem/ros-helm-chart/scripts
./deploy-rhbk.sh 2>&1 | tee rhbk-deployment-test.log
```

### Step 4: Monitor for Issue
Watch the logs for:

1. **Expected failure point**: Line 733 in `create_kubernetes_realm()`
   ```bash
   local ADMIN_PASSWORD=$(oc get secret keycloak-initial-admin -n "$NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
   ```

2. **Error message**:
   ```
   Error: secret "keycloak-initial-admin" not found
   ```
   or empty password variable causing subsequent failures

3. **Timeline**:
   - Keycloak CR marked as Ready
   - Script proceeds to create_kubernetes_realm()
   - Tries to access admin password at line 733
   - **Issue**: Secret not yet created by operator

## Current Wait Logic

The script has `wait_for_admin_secret()` function (lines 545-594) which is called at line 1058, but:

**Problem**: The function is called AFTER `deploy_keycloak()` completes.

Let's trace the execution:
1. Line 1056: `deploy_keycloak()` - Waits for Keycloak CR to be Ready
2. Line 1058: `wait_for_admin_secret()` - NEW: Waits for secret
3. Line 1059: `create_kubernetes_realm()` - Uses secret at line 733

**Question**: Is the wait at line 1058 sufficient, or is there a race condition?

## Hypothesis

The issue may occur if:
1. The `deploy_keycloak()` function completes when Keycloak CR is Ready
2. But the RHBK operator hasn't created the `keycloak-initial-admin` secret yet
3. The `wait_for_admin_secret()` function should catch this, but maybe there's a timing issue

## Alternative Hypothesis

Line 733 accesses the secret WITHIN `create_kubernetes_realm()` function:
- This is AFTER the `wait_for_admin_secret()` should have verified the secret exists
- So why would it fail?

**Possible reasons**:
1. Secret gets deleted/recreated between wait and usage?
2. Secret exists but is empty?
3. Race condition in reading the secret?
4. The wait function isn't being called in all code paths?

## Expected Outcome

After running this test, we should:
1. Reproduce the failure (if it exists)
2. See exactly where and when the secret access fails
3. Identify the root cause
4. Implement the correct fix

## Fix Strategy (After Reproducing)

Depending on what we find:

### Option A: Secret not ready after Keycloak CR Ready
- Increase timeout in `wait_for_admin_secret()`
- Add more robust checking

### Option B: Race condition in realm creation
- Add additional wait/check right before using password at line 733
- Retry logic for secret access

### Option C: Secret exists but empty
- Add validation in `wait_for_admin_secret()` to decode and verify password
- Add error handling for empty passwords

## Files Modified

1. **cleanup-all-components.sh** - Comprehensive cleanup script
   - Added CRD cleanup
   - Added ClusterRole/ClusterRoleBinding cleanup
   - Added webhook cleanup
   - Added operator resource cleanup (CSV, InstallPlan)
   - Added container image cleanup

2. **deploy-rhbk.sh** - RHBK deployment script
   - Added `wait_for_admin_secret()` function (lines 545-594)
   - Integrated into main() at line 1058

## Next Steps

1. ✅ Created comprehensive cleanup script
2. ✅ Updated deploy-rhbk.sh with wait function
3. ⏳ Need to run cleanup on actual cluster
4. ⏳ Need to run fresh deployment to reproduce issue
5. ⏳ Implement final fix based on observed behavior

---

**Status**: Ready for testing
**Requires**: Active OpenShift cluster connection







