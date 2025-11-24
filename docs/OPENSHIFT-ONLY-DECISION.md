# OpenShift-Only Deployment Decision

**Date**: November 6, 2025
**Decision**: This chart will **ONLY** be deployed on OpenShift

---

## Impact on Implementation

### ✅ **Simplified: No Conditional Logic Needed**

#### Before (Multi-Platform):
```yaml
{{- if .Values.global.platform.openshift }}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: koku-api-reads
spec:
  # ... policy rules
{{- end }}
```

#### After (OpenShift-Only):
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: koku-api-reads
spec:
  # ... policy rules
```

**No conditionals needed!** NetworkPolicies are always deployed.

---

## Changes to Implementation Plan

### 1. **NetworkPolicy Templates**
- ❌ **Remove**: `{{- if .Values.global.platform.openshift }}` conditionals
- ✅ **Keep**: All 15 NetworkPolicy templates (always deployed)
- ✅ **Keep**: All NetworkPolicy logic (27 communication paths)

### 2. **values-koku.yaml**
- ❌ **Remove**: `global.platform.openshift: true/false` toggle
- ✅ **Assume**: Always OpenShift
- ✅ **Keep**: All NetworkPolicy configuration

### 3. **Helper Functions**
- ❌ **Remove**: Platform detection helpers (if any)
- ✅ **Simplify**: Assume OpenShift resources available
  - Routes (instead of Ingress)
  - SecurityContextConstraints
  - OpenShift-specific annotations

### 4. **Documentation**
- ✅ **Update**: All docs to state "OpenShift-only"
- ✅ **Remove**: Platform selection instructions
- ✅ **Add**: OpenShift version requirements

---

## Benefits

### ✅ **Simplified Templates**
- No conditional logic cluttering templates
- Easier to read and maintain
- Fewer edge cases to test

### ✅ **Reduced Complexity**
- No platform detection
- No multi-platform testing
- Clearer deployment requirements

### ✅ **Better Security**
- NetworkPolicies always enabled
- No accidental deployments without network isolation
- Consistent security posture

---

## OpenShift-Specific Features We Can Use

### 1. **Routes (Not Ingress)**
```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: koku-api
spec:
  to:
    kind: Service
    name: koku-api
  port:
    targetPort: 8000
  tls:
    termination: edge
```

### 2. **SecurityContextConstraints**
```yaml
apiVersion: security.openshift.io/v1
kind: SecurityContextConstraints
metadata:
  name: koku-restricted
# ... SCC configuration
```

### 3. **OpenShift Annotations**
```yaml
metadata:
  annotations:
    openshift.io/display-name: "Koku Cost Management"
    openshift.io/description: "Cost management and reporting"
```

---

## Updated values-koku.yaml Structure

### Before (Multi-Platform):
```yaml
global:
  platform:
    openshift: true      # Toggle for OCP features
    kubernetes: false

networkPolicies:
  enabled: true          # Conditional on platform
```

### After (OpenShift-Only):
```yaml
# No platform toggle needed - always OpenShift

networkPolicies:
  # Always deployed (no enabled toggle)
  ingress:
    # ... ingress rules
  egress:
    # ... egress rules
```

---

## Updated Implementation Checklist

### Phase 5: NetworkPolicies (Simplified)

**Before**:
- ~~Add platform detection conditionals~~
- ~~Test on Kubernetes (without NetworkPolicies)~~
- ~~Test on OpenShift (with NetworkPolicies)~~

**After**:
- ✅ Create 15 NetworkPolicy templates (no conditionals)
- ✅ Test on OpenShift only
- ✅ Verify all communication paths work

---

## Deployment Requirements

### Minimum OpenShift Version
- **OpenShift 4.10+** (recommended)
- Supports NetworkPolicy v1
- Supports StatefulSet apps/v1
- Supports standard Kubernetes resources

### Required OpenShift Features
- ✅ NetworkPolicy support (standard)
- ✅ Routes (OpenShift-specific)
- ✅ SecurityContextConstraints (OpenShift-specific)
- ✅ StorageClass support (standard)
- ✅ ServiceMonitor (Prometheus Operator)

---

## Documentation Updates

### README.md
```markdown
# Cost Management On-Premise Helm Chart

**Platform**: OpenShift 4.10+

This chart deploys the complete cost management platform, including:
- Resource Optimization Service (ROS)
- Koku Cost Management
- Trino Analytics Engine
- Shared Infrastructure

**Note**: This chart is designed for OpenShift only.
```

### Installation Guide
```bash
# OpenShift deployment (standard)
helm install cost-mgmt ./cost-management-onprem \
  --namespace cost-mgmt \
  --create-namespace \
  -f cost-management-onprem/values.yaml \
  -f cost-management-onprem/values-koku.yaml

# Kubernetes deployment: NOT SUPPORTED
```

---

## Summary

### ✅ **Simplified Approach**
- No platform conditionals
- Always deploy NetworkPolicies
- OpenShift-specific features available
- Cleaner, simpler templates

### 📋 **Updated Implementation**
- Remove all `{{- if .Values.global.platform.openshift }}` checks
- NetworkPolicies always deployed (no toggle)
- Can use OpenShift Routes, SCC, etc.
- Documentation updated to "OpenShift-only"

### 🎯 **Benefits**
- Simpler code
- Fewer test cases
- Better security (NetworkPolicies always on)
- Clearer requirements

---

**Status**: ✅ **DECISION CONFIRMED**
**Impact**: 🟢 **POSITIVE** (Simplifies implementation)
**Next Action**: Update templates to remove conditional logic

