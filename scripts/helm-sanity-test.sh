#!/bin/bash
# Helm Sanity Test - Verifies basic Helm functionality before deploying complex charts
# This helps isolate rate limiting issues by testing with a minimal chart

set -euo pipefail

echo "========== Helm Sanity Test =========="
echo "Testing basic Helm functionality with minimal chart..."
echo ""

# Create minimal test chart
TEMP_CHART="/tmp/helm-sanity-test"
rm -rf "${TEMP_CHART}"
mkdir -p "${TEMP_CHART}/templates"

# Chart.yaml
cat > "${TEMP_CHART}/Chart.yaml" << 'CHART_EOF'
apiVersion: v2
name: helm-sanity-test
description: Minimal chart to test Helm functionality
version: 0.1.0
appVersion: "1.0"
CHART_EOF

# Simple ConfigMap template (no lookups, no complexity)
cat > "${TEMP_CHART}/templates/configmap.yaml" << 'TEMPLATE_EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: helm-sanity-test
  namespace: {{ .Release.Namespace }}
data:
  test: "Helm is working"
  version: "{{ .Chart.Version }}"
  release: "{{ .Release.Name }}"
TEMPLATE_EOF

echo "✓ Created minimal test chart at ${TEMP_CHART}"
echo ""

# Test with dry-run
echo "Running: helm install --dry-run..."
if helm install helm-sanity-test "${TEMP_CHART}" \
  --namespace "${NAMESPACE:-default}" \
  --create-namespace \
  --dry-run \
  --timeout=60s; then
  echo "✅ SUCCESS: Helm dry-run works!"
  echo ""
else
  echo "❌ FAILED: Helm dry-run failed!"
  echo "This suggests a fundamental Helm or cluster issue."
  exit 1
fi

# Test actual deployment (if not in dry-run mode)
if [[ "${DRY_RUN_ONLY:-false}" != "true" ]]; then
  echo "Running: helm install (actual deployment)..."
  if helm install helm-sanity-test "${TEMP_CHART}" \
    --namespace "${NAMESPACE:-default}" \
    --create-namespace \
    --timeout=60s \
    --wait; then
    echo "✅ SUCCESS: Helm install works!"
    echo ""
    
    # Cleanup
    echo "Cleaning up test release..."
    helm uninstall helm-sanity-test --namespace "${NAMESPACE:-default}" || true
  else
    echo "❌ FAILED: Helm install failed!"
    echo "This confirms the rate limiting issue is real."
    exit 1
  fi
fi

echo "========== Helm Sanity Test Complete =========="
echo "Helm is functional - proceeding with main chart deployment..."
echo ""
