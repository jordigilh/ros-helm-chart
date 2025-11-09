#!/bin/bash
# Script to force the Cost Management Operator to package and upload metrics immediately
# This bypasses the 6-hour packaging/upload cycle timers

set -euo pipefail

NAMESPACE="costmanagement-metrics-operator"
CONFIG_NAME="costmanagementmetricscfg-tls"

echo "🚀 Force Packaging & Upload to Ingress"
echo "========================================"
echo ""

# Check if metrics were collected recently
echo "📊 Checking last metrics collection time..."
LAST_QUERY=$(kubectl get costmanagementmetricsconfig -n "$NAMESPACE" "$CONFIG_NAME" \
  -o jsonpath='{.status.prometheus.last_query_success_time}')
echo "   Last collection: $LAST_QUERY"
echo ""

# Step 1: Manipulate packaging timestamp to bypass 360-minute timer
echo "⏰ Step 1: Resetting packaging timestamp..."
kubectl patch costmanagementmetricsconfig -n "$NAMESPACE" "$CONFIG_NAME" \
  --type='json' \
  -p='[{"op": "replace", "path": "/status/packaging/last_successful_packaging_time", "value": "2020-01-01T00:00:00Z"}]' \
  --subresource=status
echo "   ✅ Timestamp reset to 2020-01-01 (forces repackaging)"
echo ""

# Step 2: Trigger reconciliation with force-collection annotation
echo "🔄 Step 2: Triggering operator reconciliation..."
kubectl annotate -n "$NAMESPACE" costmanagementmetricsconfig "$CONFIG_NAME" \
  clusterconfig.openshift.io/force-collection="$(date +%s)" --overwrite
echo "   ✅ Reconciliation triggered"
echo ""

# Wait for operator to process
echo "⏳ Waiting 60 seconds for operator to package and upload..."
sleep 60
echo ""

# Check upload status
echo "📋 Checking upload status..."
UPLOAD_STATUS=$(kubectl get costmanagementmetricsconfig -n "$NAMESPACE" "$CONFIG_NAME" \
  -o jsonpath='{.status.upload.last_upload_status}' 2>/dev/null || echo "Unknown")
LAST_UPLOAD_TIME=$(kubectl get costmanagementmetricsconfig -n "$NAMESPACE" "$CONFIG_NAME" \
  -o jsonpath='{.status.upload.last_successful_upload_time}' 2>/dev/null || echo "Unknown")

echo "   Last upload status: $UPLOAD_STATUS"
echo "   Last successful upload: $LAST_UPLOAD_TIME"
echo ""

if [[ "$UPLOAD_STATUS" == *"202"* ]]; then
  echo "✅ SUCCESS! Operator successfully packaged and uploaded metrics."
  echo ""
  echo "Next steps:"
  echo "  1. Check ingress logs: kubectl logs -n cost-onprem -l app.kubernetes.io/component=ingress -c ingress --tail=50"
  echo "  2. Check processor logs: kubectl logs -n cost-onprem -l app.kubernetes.io/component=processor --tail=50"
  echo "  3. Check Kruize logs: kubectl logs -n cost-onprem -l app.kubernetes.io/name=kruize --tail=50"
else
  echo "⚠️  Upload may have failed or is still in progress."
  echo ""
  echo "Check operator logs for details:"
  echo "  kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=costmanagement-metrics-operator --tail=100"
fi
echo ""
echo "════════════════════════════════════════════════════════"

