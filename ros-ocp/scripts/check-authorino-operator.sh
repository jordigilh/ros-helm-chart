#!/bin/bash
#
# Check Authorino Operator Installation Status
# Usage: ./scripts/check-authorino-operator.sh
#

set -e

echo "🔍 Checking Authorino Operator Installation..."
echo "=============================================="
echo ""

# Check if subscription exists
echo "📋 Checking Operator Subscription..."
if oc get subscription authorino-operator -n openshift-operators >/dev/null 2>&1; then
    echo "✅ Subscription found"
    oc get subscription authorino-operator -n openshift-operators -o wide
else
    echo "❌ Subscription not found"
    echo "   Run: oc apply -f scripts/install-authorino-operator.yaml"
    exit 1
fi

echo ""

# Check operator pods
echo "📋 Checking Operator Pods..."
PODS=$(oc get pods -n openshift-operators -l name=authorino-operator --no-headers 2>/dev/null | wc -l)
if [ "$PODS" -gt 0 ]; then
    echo "✅ Operator pods found"
    oc get pods -n openshift-operators -l name=authorino-operator
else
    echo "❌ No operator pods found"
    echo "   Wait a few minutes for installation to complete"
    exit 1
fi

echo ""

# Check CRDs
echo "📋 Checking Custom Resource Definitions..."
if oc get crd authorinos.operator.authorino.kuadrant.io >/dev/null 2>&1; then
    echo "✅ Authorino CRD found"
else
    echo "❌ Authorino CRD not found"
    echo "   Operator may still be installing..."
    exit 1
fi

if oc get crd authconfigs.authorino.kuadrant.io >/dev/null 2>&1; then
    echo "✅ AuthConfig CRD found"
else
    echo "❌ AuthConfig CRD not found"
    echo "   Operator may still be installing..."
    exit 1
fi

echo ""

# Test Authorino instance creation (dry-run)
echo "📋 Testing Authorino Instance Creation..."
cat <<EOF | oc apply --dry-run=client -f - >/dev/null 2>&1
apiVersion: operator.authorino.kuadrant.io/v1beta1
kind: Authorino
metadata:
  name: test-dry-run
  namespace: default
spec:
  image: registry.redhat.io/rhosak/authorino-rhel8:1.0.0
  listener:
    tls:
      enabled: false
  log:
    level: info
EOF

if [ $? -eq 0 ]; then
    echo "✅ Authorino instance creation test passed"
else
    echo "❌ Authorino instance creation test failed"
    echo "   CRDs may not be fully ready yet"
    exit 1
fi

echo ""
echo "🎉 AUTHORINO OPERATOR READY!"
echo "==========================="
echo ""
echo "You can now deploy ROS with JWT authentication:"
echo "  helm install ros-ocp . --set jwt_auth.enabled=true"
echo ""
