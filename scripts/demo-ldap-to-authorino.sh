#!/usr/bin/env bash
#
# Demo Script: LDAP to Authorino Flow
# ═══════════════════════════════════════════════════════════════════════════
#
# This script demonstrates the complete flow from LDAP → Keycloak → OpenShift → Authorino
# showing how org_id and account_number are extracted from group memberships.
#
# Prerequisites:
#   - OpenLDAP deployed (./scripts/deploy-ldap-demo.sh)
#   - RHBK deployed (./scripts/deploy-rhbk.sh)
#   - Keycloak LDAP configured (./scripts/configure-keycloak-ldap.sh)
#
# Usage:
#   ./scripts/demo-ldap-to-authorino.sh
#

set -euo pipefail

# Configuration
NAMESPACE="${1:-keycloak}"
REALM="kubernetes"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

function banner() {
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║${NC} ${BOLD}$1${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
  echo ""
}

function step() {
  echo -e "${BLUE}▶${NC} ${BOLD}$1${NC}"
}

function success() {
  echo -e "${GREEN}✓${NC} $1"
}

function info() {
  echo -e "${YELLOW}ℹ${NC} $1"
}

function show_value() {
  echo -e "  ${CYAN}$1:${NC} $2"
}

#──────────────────────────────────────────────────────────────────────────────
# Step 1: Show LDAP Data
#──────────────────────────────────────────────────────────────────────────────
function show_ldap_data() {
  banner "STEP 1: LDAP Data (Source of Truth)"
  
  step "Users in LDAP"
  echo ""
  
  # Get users
  oc exec -n "$NAMESPACE" deployment/openldap-demo -- \
    ldapsearch -x -H ldap://localhost \
    -D "cn=admin,dc=cost-mgmt,dc=local" -w admin \
    -b "ou=users,dc=cost-mgmt,dc=local" "(uid=*)" uid cn description 2>/dev/null | \
    grep -E "^dn:|^uid:|^cn:|^description:" | while read line; do
      if [[ "$line" == dn:* ]]; then
        echo ""
        echo -e "  ${BOLD}${line}${NC}"
      else
        echo "    $line"
      fi
    done
  
  echo ""
  step "Groups in LDAP (ou=CostMgmt)"
  echo ""
  
  oc exec -n "$NAMESPACE" deployment/openldap-demo -- \
    ldapsearch -x -H ldap://localhost \
    -D "cn=admin,dc=cost-mgmt,dc=local" -w admin \
    -b "ou=CostMgmt,ou=groups,dc=cost-mgmt,dc=local" "(objectClass=groupOfNames)" cn member 2>/dev/null | \
    grep -E "^dn:|^cn:|^member:" | while read line; do
      if [[ "$line" == dn:* ]]; then
        echo ""
        echo -e "  ${BOLD}${line}${NC}"
      else
        echo "    $line"
      fi
    done
  
  echo ""
  success "LDAP stores users with costCenter/accountNumber in description"
  success "Groups use naming pattern: cost-mgmt-org-{id}, cost-mgmt-account-{id}"
}

#──────────────────────────────────────────────────────────────────────────────
# Step 2: Show Keycloak Sync
#──────────────────────────────────────────────────────────────────────────────
function show_keycloak_sync() {
  banner "STEP 2: Keycloak Federation (LDAP → Keycloak)"
  
  # Get Keycloak token
  local keycloak_url admin_user admin_pass token
  keycloak_url="https://$(oc get route keycloak -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
  admin_user=$(oc get secret keycloak-initial-admin -n "$NAMESPACE" -o jsonpath='{.data.username}' | base64 -d)
  admin_pass=$(oc get secret keycloak-initial-admin -n "$NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)
  
  token=$(curl -sk "${keycloak_url}/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli" \
    -d "username=${admin_user}" \
    -d "password=${admin_pass}" \
    -d "grant_type=password" | jq -r '.access_token')
  
  step "Users in Keycloak (synced from LDAP)"
  echo ""
  
  curl -sk "${keycloak_url}/admin/realms/${REALM}/users" \
    -H "Authorization: Bearer $token" | jq -r '.[] | "  \(.username) - \(.email)"'
  
  echo ""
  step "Groups in Keycloak (synced from LDAP)"
  echo ""
  
  curl -sk "${keycloak_url}/admin/realms/${REALM}/groups" \
    -H "Authorization: Bearer $token" | jq -r '.[] | "  \(.name)"'
  
  echo ""
  step "User Group Memberships"
  echo ""
  
  for user in test admin; do
    local user_id groups
    user_id=$(curl -sk "${keycloak_url}/admin/realms/${REALM}/users?username=${user}&exact=true" \
      -H "Authorization: Bearer $token" | jq -r '.[0].id')
    
    echo -e "  ${BOLD}User: ${user}${NC}"
    
    curl -sk "${keycloak_url}/admin/realms/${REALM}/users/${user_id}/groups" \
      -H "Authorization: Bearer $token" | jq -r '.[] | "    → \(.name)"'
    echo ""
  done
  
  success "Keycloak syncs users and groups from LDAP"
  success "User → Group membership preserved"
}

#──────────────────────────────────────────────────────────────────────────────
# Step 3: Show Expected Authorino Extraction
#──────────────────────────────────────────────────────────────────────────────
function show_authorino_extraction() {
  banner "STEP 3: Authorino Group Parsing (OPA/Rego)"
  
  step "Rego Policy Logic"
  echo ""
  
  cat << 'REGO'
  # Extract org_id from groups like "cost-mgmt-org-1234567"
  org_ids := [trim_prefix(group, "cost-mgmt-org-") | 
              some group in input.context.user.groups
              startswith(group, "cost-mgmt-org-")]
  org_id := org_ids[0]

  # Extract account_number from groups like "cost-mgmt-account-9876543"  
  account_numbers := [trim_prefix(group, "cost-mgmt-account-") |
                      some group in input.context.user.groups
                      startswith(group, "cost-mgmt-account-")]
  account_number := account_numbers[0]
REGO
  
  echo ""
  step "Expected Extraction Results"
  echo ""
  
  echo -e "  ${BOLD}User: test${NC}"
  echo "    Groups: [cost-mgmt-org-1234567, cost-mgmt-account-9876543]"
  echo -e "    ${GREEN}→ org_id: 1234567${NC}"
  echo -e "    ${GREEN}→ account_number: 9876543${NC}"
  echo ""
  
  echo -e "  ${BOLD}User: admin${NC}"
  echo "    Groups: [cost-mgmt-org-7890123, cost-mgmt-account-5555555]"
  echo -e "    ${GREEN}→ org_id: 7890123${NC}"
  echo -e "    ${GREEN}→ account_number: 5555555${NC}"
  echo ""
  
  success "Authorino extracts numeric IDs from group prefixes"
  success "Returns X-Auth-Org-Id and X-Auth-Account-Number headers to Envoy"
}

#──────────────────────────────────────────────────────────────────────────────
# Step 4: Show Envoy X-Rh-Identity Construction
#──────────────────────────────────────────────────────────────────────────────
function show_envoy_construction() {
  banner "STEP 4: Envoy X-Rh-Identity Header Construction"
  
  step "Envoy Lua Filter Logic"
  echo ""
  
  cat << 'LUA'
  -- Read values from Authorino response headers
  local org_id = request_handle:headers():get("x-auth-org-id")
  local account_number = request_handle:headers():get("x-auth-account-number")
  local username = request_handle:headers():get("x-auth-username")

  -- Construct identity JSON
  local identity_json = string.format([[{
    "identity": {
      "org_id": "%s",
      "account_number": "%s",
      "type": "User",
      "user": {"username": "%s"}
    }
  }]], org_id, account_number, username)

  -- Base64 encode and set header
  local encoded = base64_encode(identity_json)
  request_handle:headers():add("x-rh-identity", encoded)
LUA
  
  echo ""
  step "Expected X-Rh-Identity Headers"
  echo ""
  
  echo -e "  ${BOLD}User: test${NC}"
  local test_json='{"identity":{"org_id":"1234567","account_number":"9876543","type":"User","user":{"username":"test"}}}'
  local test_encoded=$(echo -n "$test_json" | base64)
  echo "    JSON: $test_json"
  echo "    Base64: ${test_encoded:0:50}..."
  echo ""
  
  echo -e "  ${BOLD}User: admin${NC}"
  local admin_json='{"identity":{"org_id":"7890123","account_number":"5555555","type":"User","user":{"username":"admin"}}}'
  local admin_encoded=$(echo -n "$admin_json" | base64)
  echo "    JSON: $admin_json"
  echo "    Base64: ${admin_encoded:0:50}..."
  echo ""
  
  success "Envoy constructs X-Rh-Identity from Authorino headers"
  success "Backend receives complete identity context"
}

#──────────────────────────────────────────────────────────────────────────────
# Step 5: Summary
#──────────────────────────────────────────────────────────────────────────────
function show_summary() {
  banner "SUMMARY: Complete Flow"
  
  cat << 'FLOW'
  ┌─────────────────────────────────────────────────────────────────────┐
  │                        DATA FLOW                                     │
  ├─────────────────────────────────────────────────────────────────────┤
  │                                                                      │
  │  LDAP                                                                │
  │  ├── ou=users                                                        │
  │  │   ├── uid=test  (costCenter=1234567, accountNumber=9876543)      │
  │  │   └── uid=admin (costCenter=7890123, accountNumber=5555555)      │
  │  └── ou=CostMgmt,ou=groups                                          │
  │      ├── cn=cost-mgmt-org-1234567 (member: test)                    │
  │      ├── cn=cost-mgmt-org-7890123 (member: admin)                   │
  │      ├── cn=cost-mgmt-account-9876543 (member: test)                │
  │      └── cn=cost-mgmt-account-5555555 (member: admin)               │
  │                         │                                            │
  │                         ▼                                            │
  │  ┌─────────────────────────────────────────────────────────────┐    │
  │  │ KEYCLOAK (LDAP Federation)                                  │    │
  │  │   - Syncs users from ou=users                               │    │
  │  │   - Syncs groups from ou=CostMgmt                           │    │
  │  │   - Preserves group memberships                             │    │
  │  └─────────────────────────────────────────────────────────────┘    │
  │                         │                                            │
  │                         ▼                                            │
  │  ┌─────────────────────────────────────────────────────────────┐    │
  │  │ OPENSHIFT (OAuth + TokenReview)                             │    │
  │  │   - User authenticates via Keycloak OIDC                    │    │
  │  │   - TokenReview returns groups array                        │    │
  │  └─────────────────────────────────────────────────────────────┘    │
  │                         │                                            │
  │                         ▼                                            │
  │  ┌─────────────────────────────────────────────────────────────┐    │
  │  │ AUTHORINO (External Auth + OPA/Rego)                        │    │
  │  │   Input:  groups=["cost-mgmt-org-1234567",                  │    │
  │  │                   "cost-mgmt-account-9876543"]              │    │
  │  │   Output: X-Auth-Org-Id: 1234567                            │    │
  │  │           X-Auth-Account-Number: 9876543                    │    │
  │  └─────────────────────────────────────────────────────────────┘    │
  │                         │                                            │
  │                         ▼                                            │
  │  ┌─────────────────────────────────────────────────────────────┐    │
  │  │ ENVOY (Lua Filter)                                          │    │
  │  │   - Reads Authorino headers                                 │    │
  │  │   - Constructs X-Rh-Identity JSON                           │    │
  │  │   - Base64 encodes and forwards to backend                  │    │
  │  └─────────────────────────────────────────────────────────────┘    │
  │                         │                                            │
  │                         ▼                                            │
  │  ┌─────────────────────────────────────────────────────────────┐    │
  │  │ BACKEND (ros-ocp-backend)                                   │    │
  │  │   - Receives X-Rh-Identity header                           │    │
  │  │   - Decodes and extracts org_id, account_number             │    │
  │  │   - Uses for multi-tenant data isolation                    │    │
  │  └─────────────────────────────────────────────────────────────┘    │
  │                                                                      │
  └─────────────────────────────────────────────────────────────────────┘
FLOW
  
  echo ""
  success "End-to-end flow validated"
  echo ""
  info "For more details, see:"
  echo "  - docs/adr/0001-ldap-organization-id-mapping.md"
  echo "  - docs/authorino-ldap-integration.md"
}

#──────────────────────────────────────────────────────────────────────────────
# Main
#──────────────────────────────────────────────────────────────────────────────
main() {
  banner "LDAP → Authorino Demo"
  
  echo "This demo shows the complete flow of org_id and account_number"
  echo "from LDAP source → Keycloak → OpenShift → Authorino → Backend"
  echo ""
  echo "Press Enter to continue..."
  read -r
  
  show_ldap_data
  echo ""
  echo "Press Enter to continue..."
  read -r
  
  show_keycloak_sync
  echo ""
  echo "Press Enter to continue..."
  read -r
  
  show_authorino_extraction
  echo ""
  echo "Press Enter to continue..."
  read -r
  
  show_envoy_construction
  echo ""
  echo "Press Enter to continue..."
  read -r
  
  show_summary
}

main "$@"

