#!/bin/bash

# UI OAuth Flow Test Script
# Tests the UI authentication flow with Keycloak on OpenShift
#
# Usage:
#   ./test-ui-oauth-flow.sh                    # Use default test user
#   ./test-ui-oauth-flow.sh -u user -p pass    # Custom credentials
#   ./test-ui-oauth-flow.sh -v                 # Verbose output
#
# Environment Variables:
#   LOG_LEVEL - Control output verbosity (ERROR|WARN|INFO|DEBUG, default: WARN)

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging configuration
LOG_LEVEL=${LOG_LEVEL:-WARN}

# Configuration
NAMESPACE=${NAMESPACE:-cost-onprem}
KEYCLOAK_NAMESPACE=${KEYCLOAK_NAMESPACE:-keycloak}
KEYCLOAK_REALM=${KEYCLOAK_REALM:-kubernetes}
CLIENT_ID=${CLIENT_ID:-cost-management-ui}
TEST_USER=${TEST_USER:-test}
TEST_PASSWORD=${TEST_PASSWORD:-test}
VERBOSE=false

# Test results
TESTS_PASSED=0
TESTS_FAILED=0

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -u, --user USERNAME      Keycloak username (default: test)"
    echo "  -p, --password PASSWORD  Keycloak password (default: test)"
    echo "  -n, --namespace NS       Deployment namespace (default: cost-onprem)"
    echo "  -v, --verbose            Verbose output"
    echo "  -h, --help               Show this help"
}

# Logging functions with level-based filtering
log_debug() {
    [[ "$LOG_LEVEL" == "DEBUG" ]] && echo -e "${BLUE}[DEBUG]${NC} $1"
    return 0
}

log_info() {
    [[ "$LOG_LEVEL" =~ ^(INFO|DEBUG)$ ]] && echo -e "${BLUE}[INFO]${NC} $1"
    return 0
}

log_pass() {
    [[ "$LOG_LEVEL" =~ ^(WARN|INFO|DEBUG)$ ]] && echo -e "${GREEN}[PASS]${NC} $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

log_warn() {
    [[ "$LOG_LEVEL" =~ ^(WARN|INFO|DEBUG)$ ]] && echo -e "${YELLOW}[WARN]${NC} $1"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -u|--user) TEST_USER="$2"; shift 2 ;;
        -p|--password) TEST_PASSWORD="$2"; shift 2 ;;
        -n|--namespace) NAMESPACE="$2"; shift 2 ;;
        -v|--verbose) VERBOSE=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

echo ""
echo "=============================================="
echo " UI OAuth Flow Test"
echo "=============================================="
echo ""
log_info "Namespace: $NAMESPACE"
log_info "Keycloak: $KEYCLOAK_NAMESPACE"
log_info "Test User: $TEST_USER"

# Check prerequisites
echo ""
echo "--- Prerequisites ---"

if ! command -v oc &> /dev/null; then
    log_fail "oc command not found"
    exit 1
fi

if ! oc whoami &> /dev/null; then
    log_fail "Not logged into OpenShift"
    exit 1
fi
log_pass "Logged into OpenShift as $(oc whoami)"

# Get routes
UI_ROUTE=$(oc get route -n "$NAMESPACE" -l app.kubernetes.io/component=ui -o jsonpath='{.items[0].spec.host}' 2>/dev/null)
KEYCLOAK_ROUTE=$(oc get route -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.items[0].spec.host}' 2>/dev/null)

if [ -z "$UI_ROUTE" ]; then
    log_fail "UI route not found in namespace $NAMESPACE"
    exit 1
fi
log_info "UI Route: https://$UI_ROUTE"

if [ -z "$KEYCLOAK_ROUTE" ]; then
    log_fail "Keycloak route not found in namespace $KEYCLOAK_NAMESPACE"
    exit 1
fi
log_info "Keycloak Route: https://$KEYCLOAK_ROUTE"

KEYCLOAK_URL="https://$KEYCLOAK_ROUTE"

# Test 1: UI Pod Health
echo ""
echo "--- Test 1: UI Pod Health ---"

UI_POD_STATUS=$(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/component=ui -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
if [ "$UI_POD_STATUS" = "Running" ]; then
    log_pass "UI pod is Running"
else
    log_fail "UI pod status: $UI_POD_STATUS"
fi

# Test 2: OAuth Proxy TLS Health
echo ""
echo "--- Test 2: OAuth Proxy TLS ---"

PROXY_LOGS=$(oc logs -n "$NAMESPACE" -l app.kubernetes.io/component=ui -c oauth-proxy --tail=100 2>/dev/null)
if echo "$PROXY_LOGS" | grep -qi "tls.*error\|certificate.*error\|x509"; then
    log_fail "TLS errors found in oauth-proxy logs"
    echo "$PROXY_LOGS" | grep -i "tls\|certificate\|x509" | head -3
else
    log_pass "No TLS errors in oauth-proxy logs"
fi

# Test 3: Keycloak OIDC Discovery
echo ""
echo "--- Test 3: Keycloak OIDC Discovery ---"

OIDC_CONFIG=$(curl -sk "$KEYCLOAK_URL/realms/$KEYCLOAK_REALM/.well-known/openid-configuration" 2>/dev/null)
if echo "$OIDC_CONFIG" | grep -q "authorization_endpoint"; then
    log_pass "Keycloak OIDC discovery accessible"
else
    log_fail "Keycloak OIDC discovery failed"
fi

# Test 4: Get JWT Token
echo ""
echo "--- Test 4: Token Acquisition ---"

CLIENT_SECRET=$(oc get secret -n "$KEYCLOAK_NAMESPACE" keycloak-client-secret-cost-management-ui -o jsonpath='{.data.CLIENT_SECRET}' 2>/dev/null | base64 -d)

if [ -n "$CLIENT_SECRET" ]; then
    TOKEN_RESPONSE=$(curl -sk -X POST "$KEYCLOAK_URL/realms/$KEYCLOAK_REALM/protocol/openid-connect/token" \
        -d "username=$TEST_USER" \
        -d "password=$TEST_PASSWORD" \
        -d "grant_type=password" \
        -d "client_id=$CLIENT_ID" \
        -d "client_secret=$CLIENT_SECRET" \
        -d "scope=openid profile email" 2>/dev/null)
else
    TOKEN_RESPONSE=$(curl -sk -X POST "$KEYCLOAK_URL/realms/$KEYCLOAK_REALM/protocol/openid-connect/token" \
        -d "username=$TEST_USER" \
        -d "password=$TEST_PASSWORD" \
        -d "grant_type=password" \
        -d "client_id=$CLIENT_ID" \
        -d "scope=openid profile email" 2>/dev/null)
fi

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | grep -o '"access_token":"[^"]*' | cut -d'"' -f4)

if [ -n "$ACCESS_TOKEN" ]; then
    log_pass "JWT token acquired from Keycloak"
else
    log_fail "Failed to get JWT token"
    if $VERBOSE; then
        echo "Response: $TOKEN_RESPONSE"
    fi
fi

# Test 5: JWT Claims Validation
echo ""
echo "--- Test 5: JWT Claims ---"

if [ -n "$ACCESS_TOKEN" ]; then
    # Decode JWT payload with proper padding
    PAYLOAD=$(echo "$ACCESS_TOKEN" | cut -d'.' -f2)
    case $((${#PAYLOAD} % 4)) in
        2) PAYLOAD="${PAYLOAD}==" ;;
        3) PAYLOAD="${PAYLOAD}=" ;;
    esac
    JWT_PAYLOAD=$(echo "$PAYLOAD" | base64 -d 2>/dev/null)

    # Get user attributes from Keycloak Admin API for comparison
    ADMIN_PASS=$(oc get secret keycloak-initial-admin -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
    ADMIN_TOKEN=""
    KC_USER_DATA=""
    if [ -n "$ADMIN_PASS" ]; then
        ADMIN_TOKEN=$(curl -sk -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
            -d "username=admin" \
            -d "password=$ADMIN_PASS" \
            -d "grant_type=password" \
            -d "client_id=admin-cli" 2>/dev/null | grep -o '"access_token":"[^"]*' | cut -d'"' -f4)
        if [ -n "$ADMIN_TOKEN" ]; then
            KC_USER_DATA=$(curl -sk -H "Authorization: Bearer $ADMIN_TOKEN" \
                "$KEYCLOAK_URL/admin/realms/$KEYCLOAK_REALM/users?username=$TEST_USER" 2>/dev/null)
        fi
    fi

    # Format JSONs side by side (Keycloak first - smaller, JWT second - filtered)
    echo ""
    KC_FMT=$(echo "$KC_USER_DATA" | jq '.[0] | {username, email, attributes}' 2>/dev/null || echo "$KC_USER_DATA")
    JWT_FMT=$(echo "$JWT_PAYLOAD" | jq '{preferred_username, email, org_id, account_number}' 2>/dev/null || echo "$JWT_PAYLOAD")

    echo "┌───────────────────────────────┐  ┌───────────────────────────────┐"
    echo "│       Keycloak User           │  │        JWT Token              │"
    echo "└───────────────────────────────┘  └───────────────────────────────┘"
    paste <(echo "$KC_FMT") <(echo "$JWT_FMT") | while IFS=$'\t' read -r left right; do
        printf "%-32s  %s\n" "$left" "$right"
    done
    echo ""

    if echo "$JWT_PAYLOAD" | grep -q "preferred_username"; then
        log_pass "JWT contains preferred_username"
    else
        log_fail "JWT missing preferred_username"
    fi

    if echo "$JWT_PAYLOAD" | grep -q "email"; then
        log_pass "JWT contains email"
    else
        log_warn "JWT missing email claim"
    fi

    if echo "$JWT_PAYLOAD" | grep -q "org_id"; then
        log_pass "JWT contains org_id"
    else
        log_warn "JWT missing org_id claim"
    fi

    if echo "$JWT_PAYLOAD" | grep -q "account_number"; then
        log_pass "JWT contains account_number"
    else
        log_warn "JWT missing account_number claim"
    fi
else
    log_warn "Skipping JWT claims - no token"
fi

# Summary
echo ""
echo "=============================================="
echo " Summary"
echo "=============================================="
echo ""
echo -e "  ${GREEN}Passed:${NC} $TESTS_PASSED"
echo -e "  ${RED}Failed:${NC} $TESTS_FAILED"
echo ""

if [ $TESTS_FAILED -gt 0 ]; then
    echo -e "${RED}Some tests failed${NC}"
    exit 1
else
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
fi
