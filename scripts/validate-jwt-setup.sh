#!/bin/bash

# Validation script for JWT authentication setup
# Usage: ./scripts/validate-jwt-setup.sh [namespace]

set -e

NAMESPACE=${1:-ros-ocp}

echo "🔍 JWT Authentication Setup Validation"
echo "======================================"
echo ""
echo "Namespace: $NAMESPACE"
echo ""

# Check if custom image exists
echo "1. Checking custom ingress image..."
if oc get imagestream insights-ros-ingress-auth-disabled -n "$NAMESPACE" &>/dev/null; then
    echo "   ✅ Custom ingress image exists"
    IMAGE_TAG=$(oc get imagestream insights-ros-ingress-auth-disabled -n "$NAMESPACE" -o jsonpath='{.status.tags[0].tag}')
    echo "   📋 Image tag: $IMAGE_TAG"
else
    echo "   ❌ Custom ingress image not found"
    echo "   🔧 Run: ./scripts/build-custom-ingress.sh $NAMESPACE"
fi

# Check if Authorino operator is installed
echo ""
echo "2. Checking Authorino operator..."
if oc get csv -n openshift-operators | grep -q authorino; then
    echo "   ✅ Authorino operator installed"
else
    echo "   ❌ Authorino operator not found"
    echo "   🔧 Install: oc apply -f scripts/install-authorino-operator.yaml"
fi

# Check if Keycloak is available
echo ""
echo "3. Checking Keycloak availability..."
if oc get keycloak -A &>/dev/null; then
    KEYCLOAK_NAMESPACE=$(oc get keycloak -A -o jsonpath='{.items[0].metadata.namespace}')
    KEYCLOAK_NAME=$(oc get keycloak -A -o jsonpath='{.items[0].metadata.name}')
    echo "   ✅ Keycloak found: $KEYCLOAK_NAME in $KEYCLOAK_NAMESPACE"
else
    echo "   ⚠️  Keycloak not found via CR - checking for RH SSO pods..."
    if oc get pods -A | grep -q keycloak; then
        echo "   ✅ Keycloak pods found"
    else
        echo "   ❌ Keycloak not available"
        echo "   🔧 Install Red Hat SSO or Keycloak in the cluster"
    fi
fi

# Check deployment status if JWT auth is enabled
echo ""
echo "4. Checking current deployment..."
if oc get deployment ros-ocp-ingress -n "$NAMESPACE" &>/dev/null; then
    # Check if using custom image
    CURRENT_IMAGE=$(oc get deployment ros-ocp-ingress -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[?(@.name=="ingress")].image}')
    if [[ "$CURRENT_IMAGE" == *"auth-disabled"* ]]; then
        echo "   ✅ Using custom authentication-disabled image"
        echo "   📋 Image: $CURRENT_IMAGE"
        
        # Check if JWT auth is working
        POD_STATUS=$(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/component=ingress -o jsonpath='{.items[0].status.phase}')
        CONTAINER_COUNT=$(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/component=ingress -o jsonpath='{.items[0].status.containerStatuses[*].ready}' | wc -w)
        READY_COUNT=$(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/component=ingress -o jsonpath='{.items[0].status.containerStatuses[?(@.ready==true)]}' | jq -s length 2>/dev/null || echo "0")
        
        echo "   📊 Pod status: $POD_STATUS ($READY_COUNT/$CONTAINER_COUNT ready)"
        
        if [ "$POD_STATUS" = "Running" ] && [ "$READY_COUNT" = "$CONTAINER_COUNT" ]; then
            echo "   ✅ JWT authentication deployment is healthy"
        else
            echo "   ⚠️  JWT authentication deployment has issues"
        fi
    else
        echo "   📋 Using standard image: $CURRENT_IMAGE"
        echo "   ℹ️  Deploy with jwt_auth.enabled=true to use JWT authentication"
    fi
    
    # Check for Authorino resources
    echo ""
    echo "5. Checking Authorino resources..."
    if oc get authorino -n "$NAMESPACE" &>/dev/null; then
        echo "   ✅ Authorino instance found"
    else
        echo "   ℹ️  No Authorino instance in $NAMESPACE"
    fi
    
    if oc get authconfig -n "$NAMESPACE" &>/dev/null; then
        AUTHCONFIG_COUNT=$(oc get authconfig -n "$NAMESPACE" -o name | wc -l)
        echo "   ✅ AuthConfig resources found: $AUTHCONFIG_COUNT"
    else
        echo "   ℹ️  No AuthConfig resources in $NAMESPACE"
    fi
else
    echo "   ℹ️  ROS deployment not found in $NAMESPACE"
fi

echo ""
echo "📋 SUMMARY"
echo "=========="
echo "To enable JWT authentication:"
echo "1. Ensure all components above show ✅"
echo "2. Use values file: ros-ocp/values-jwt-auth-complete.yaml"  
echo "3. Deploy: helm upgrade ros-ocp ./ros-ocp -f values-jwt-auth-complete.yaml"
echo "4. Test: ./scripts/test-ocp-dataflow-cost-management.sh"
echo ""
