#!/usr/bin/env bash
#
# Configure Keycloak LDAP Federation for Cost Management Demo
# ═══════════════════════════════════════════════════════════════════════════
#
# This script configures Keycloak to federate users from the OpenLDAP demo
# server and maps LDAP groups to Keycloak groups using the businessCategory
# attribute for organization IDs.
#
# Prerequisites:
#   - OpenLDAP demo server deployed (run deploy-ldap-demo.sh first)
#   - Keycloak deployed and accessible
#
# Usage:
#   ./configure-keycloak-ldap.sh [keycloak-namespace]
#
# Default namespace: keycloak
#

set -euo pipefail

# Configuration
NAMESPACE="${1:-keycloak}"
REALM="${2:-kubernetes}"
LDAP_URL="ldap://openldap-demo.${NAMESPACE}.svc.cluster.local:1389"
LDAP_BASE_DN="dc=cost-mgmt,dc=local"
LDAP_BIND_DN="cn=admin,${LDAP_BASE_DN}"
LDAP_BIND_PASSWORD="admin123"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

function echo_header() {
  echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}  $1${NC}"
  echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
}

function echo_info() {
  echo -e "${GREEN}✓${NC} $1"
}

function echo_warn() {
  echo -e "${YELLOW}⚠${NC} $1"
}

function echo_error() {
  echo -e "${RED}✗${NC} $1"
}

function check_prerequisites() {
  echo_header "Checking Prerequisites"

  if ! command -v oc &> /dev/null; then
    echo_error "oc CLI not found"
    exit 1
  fi
  echo_info "oc CLI found"

  if ! command -v curl &> /dev/null; then
    echo_error "curl not found"
    exit 1
  fi
  echo_info "curl found"

  if ! command -v jq &> /dev/null; then
    echo_error "jq not found. Please install jq for JSON processing"
    exit 1
  fi
  echo_info "jq found"

  if ! oc whoami &> /dev/null; then
    echo_error "Not logged into OpenShift"
    exit 1
  fi
  echo_info "Logged into OpenShift as $(oc whoami)"
}

function get_keycloak_url() {
  echo_header "Getting Keycloak URL"

  local route_name="keycloak"
  KEYCLOAK_URL=$(oc get route "$route_name" -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

  if [ -z "$KEYCLOAK_URL" ]; then
    echo_error "Keycloak route not found in namespace $NAMESPACE"
    exit 1
  fi

  KEYCLOAK_URL="https://${KEYCLOAK_URL}"
  echo_info "Keycloak URL: $KEYCLOAK_URL"
}

function get_admin_token() {
  echo_header "Getting Admin Token"

  # Get admin credentials from secret
  local admin_user admin_password
  admin_user=$(oc get secret keycloak-initial-admin -n "$NAMESPACE" -o jsonpath='{.data.username}' | base64 -d)
  admin_password=$(oc get secret keycloak-initial-admin -n "$NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)

  if [ -z "$admin_user" ] || [ -z "$admin_password" ]; then
    echo_error "Failed to get admin credentials"
    exit 1
  fi

  # Get access token
  local token_response
  token_response=$(curl -sk -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli" \
    -d "username=${admin_user}" \
    -d "password=${admin_password}" \
    -d "grant_type=password" 2>/dev/null)

  ACCESS_TOKEN=$(echo "$token_response" | jq -r '.access_token')

  if [ -z "$ACCESS_TOKEN" ] || [ "$ACCESS_TOKEN" = "null" ]; then
    echo_error "Failed to get access token"
    echo "Response: $token_response"
    exit 1
  fi

  echo_info "Access token obtained"
}

function create_ldap_federation() {
  echo_header "Creating LDAP User Federation"

  # Check if LDAP federation already exists
  local existing_id
  existing_id=$(curl -sk -X GET "${KEYCLOAK_URL}/admin/realms/${REALM}/components" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" | \
    jq -r '.[] | select(.name == "openldap-demo" and .providerId == "ldap") | .id' | head -1)

  if [ -n "$existing_id" ] && [ "$existing_id" != "null" ]; then
    echo_warn "LDAP federation 'openldap-demo' already exists (ID: $existing_id)"
    LDAP_COMPONENT_ID="$existing_id"
    return 0
  fi

  # Create LDAP federation
  local response
  response=$(curl -sk -X POST "${KEYCLOAK_URL}/admin/realms/${REALM}/components" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{
      "name": "openldap-demo",
      "providerId": "ldap",
      "providerType": "org.keycloak.storage.UserStorageProvider",
      "parentId": "'"${REALM}"'",
      "config": {
        "enabled": ["true"],
        "priority": ["1"],
        "fullSyncPeriod": ["-1"],
        "changedSyncPeriod": ["-1"],
        "cachePolicy": ["DEFAULT"],
        "evictionDay": [],
        "evictionHour": [],
        "evictionMinute": [],
        "maxLifespan": [],
        "batchSizeForSync": ["1000"],
        "editMode": ["READ_ONLY"],
        "syncRegistrations": ["false"],
        "vendor": ["other"],
        "usernameLDAPAttribute": ["uid"],
        "rdnLDAPAttribute": ["uid"],
        "uuidLDAPAttribute": ["entryUUID"],
        "userObjectClasses": ["inetOrgPerson, posixAccount"],
        "connectionUrl": ["'"${LDAP_URL}"'"],
        "usersDn": ["ou=users,'"${LDAP_BASE_DN}"'"],
        "authType": ["simple"],
        "bindDn": ["'"${LDAP_BIND_DN}"'"],
        "bindCredential": ["'"${LDAP_BIND_PASSWORD}"'"],
        "searchScope": ["1"],
        "useTruststoreSpi": ["ldapsOnly"],
        "connectionPooling": ["true"],
        "pagination": ["true"],
        "allowKerberosAuthentication": ["false"],
        "debug": ["false"],
        "useKerberosForPasswordAuthentication": ["false"]
      }
    }' -w "\n%{http_code}" 2>/dev/null)

  local http_code
  http_code=$(echo "$response" | tail -n1)

  if [ "$http_code" != "201" ]; then
    echo_error "Failed to create LDAP federation (HTTP $http_code)"
    echo "Response: $(echo "$response" | head -n-1)"
    exit 1
  fi

  echo_info "LDAP user federation created"

  # Get the created component ID
  LDAP_COMPONENT_ID=$(curl -sk -X GET "${KEYCLOAK_URL}/admin/realms/${REALM}/components" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" | \
    jq -r '.[] | select(.name == "openldap-demo" and .providerId == "ldap") | .id' | head -1)

  echo_info "LDAP Component ID: $LDAP_COMPONENT_ID"
}

function create_orgid_group_mapper() {
  echo_header "Creating LDAP Organization ID Group Mapper"

  if [ -z "$LDAP_COMPONENT_ID" ]; then
    echo_error "LDAP Component ID not found"
    exit 1
  fi

  # Check if mapper already exists
  local existing_id
  existing_id=$(curl -sk -X GET "${KEYCLOAK_URL}/admin/realms/${REALM}/components" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" | \
    jq -r '.[] | select(.name == "organization-groups-mapper" and .providerId == "group-ldap-mapper") | .id' | head -1)

  if [ -n "$existing_id" ] && [ "$existing_id" != "null" ]; then
    echo_warn "Org groups mapper already exists (ID: $existing_id)"
    return 0
  fi

  # Create group mapper for organizations (imports as /organizations/1234567)
  local response
  response=$(curl -sk -X POST "${KEYCLOAK_URL}/admin/realms/${REALM}/components" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{
      "name": "organization-groups-mapper",
      "providerId": "group-ldap-mapper",
      "providerType": "org.keycloak.storage.ldap.mappers.LDAPStorageMapper",
      "parentId": "'"${LDAP_COMPONENT_ID}"'",
      "config": {
        "mode": ["READ_ONLY"],
        "membership.attribute.type": ["DN"],
        "user.roles.retrieve.strategy": ["LOAD_GROUPS_BY_MEMBER_ATTRIBUTE"],
        "group.name.ldap.attribute": ["cn"],
        "membership.ldap.attribute": ["member"],
        "membership.user.ldap.attribute": ["uid"],
        "groups.dn": ["ou=organizations,ou=groups,'"${LDAP_BASE_DN}"'"],
        "group.object.classes": ["groupOfNames"],
        "preserve.group.inheritance": ["true"],
        "ignore.missing.groups": ["false"],
        "memberof.ldap.attribute": ["memberOf"],
        "drop.non.existing.groups.during.sync": ["false"]
      }
    }' -w "\n%{http_code}" 2>/dev/null)

  local http_code
  http_code=$(echo "$response" | tail -n1)

  if [ "$http_code" != "201" ]; then
    echo_error "Failed to create org groups mapper (HTTP $http_code)"
    echo "Response: $(echo "$response" | head -n-1)"
    exit 1
  fi

  echo_info "Org groups mapper created (ou=organizations → /organizations/ID)"
}

function create_account_group_mapper() {
  echo_header "Creating LDAP Account Number Group Mapper"

  if [ -z "$LDAP_COMPONENT_ID" ]; then
    echo_error "LDAP Component ID not found"
    exit 1
  fi

  # Check if account mapper already exists
  local existing_id
  existing_id=$(curl -sk -X GET "${KEYCLOAK_URL}/admin/realms/${REALM}/components" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" | \
    jq -r '.[] | select(.name == "account-groups-mapper" and .providerId == "group-ldap-mapper") | .id' | head -1)

  if [ -n "$existing_id" ] && [ "$existing_id" != "null" ]; then
    echo_warn "Account groups mapper already exists (ID: $existing_id)"
    return 0
  fi

  # Create group mapper for accounts (imports as /accounts/9876543)
  local response
  response=$(curl -sk -X POST "${KEYCLOAK_URL}/admin/realms/${REALM}/components" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{
      "name": "account-groups-mapper",
      "providerId": "group-ldap-mapper",
      "providerType": "org.keycloak.storage.ldap.mappers.LDAPStorageMapper",
      "parentId": "'"${LDAP_COMPONENT_ID}"'",
      "config": {
        "mode": ["READ_ONLY"],
        "membership.attribute.type": ["DN"],
        "user.roles.retrieve.strategy": ["LOAD_GROUPS_BY_MEMBER_ATTRIBUTE"],
        "group.name.ldap.attribute": ["cn"],
        "membership.ldap.attribute": ["member"],
        "membership.user.ldap.attribute": ["uid"],
        "groups.dn": ["ou=accounts,ou=groups,'"${LDAP_BASE_DN}"'"],
        "group.object.classes": ["groupOfNames"],
        "preserve.group.inheritance": ["true"],
        "ignore.missing.groups": ["false"],
        "memberof.ldap.attribute": ["memberOf"],
        "drop.non.existing.groups.during.sync": ["false"]
      }
    }' -w "\n%{http_code}" 2>/dev/null)

  local http_code
  http_code=$(echo "$response" | tail -n1)

  if [ "$http_code" != "201" ]; then
    echo_error "Failed to create account groups mapper (HTTP $http_code)"
    echo "Response: $(echo "$response" | head -n-1)"
    exit 1
  fi

  echo_info "Account groups mapper created (ou=accounts → /accounts/ID)"
}

function sync_users() {
  echo_header "Synchronizing Users from LDAP"

  if [ -z "$LDAP_COMPONENT_ID" ]; then
    echo_error "LDAP Component ID not found"
    exit 1
  fi

  # Trigger full sync
  local response
  response=$(curl -sk -X POST "${KEYCLOAK_URL}/admin/realms/${REALM}/user-storage/${LDAP_COMPONENT_ID}/sync?action=triggerFullSync" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" 2>/dev/null)

  echo_info "User sync triggered"
  echo "Response: $response"

  # Wait a bit for sync to complete
  sleep 5
}

function verify_configuration() {
  echo_header "Verifying Configuration"

  # Check if test user was imported
  local user_id
  user_id=$(curl -sk -X GET "${KEYCLOAK_URL}/admin/realms/${REALM}/users?username=test&exact=true" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" | \
    jq -r '.[0].id' 2>/dev/null)

  if [ -z "$user_id" ] || [ "$user_id" = "null" ]; then
    echo_error "Test user not found in Keycloak"
    return 1
  fi

  echo_info "Test user found (ID: $user_id)"

  # Get user's groups
  local groups
  groups=$(curl -sk -X GET "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${user_id}/groups" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" | \
    jq -r '.[].name' 2>/dev/null)

  echo_info "User's groups:"
  echo "$groups" | while read -r group; do
    echo "  - $group"
  done

  # Check for expected groups (with hierarchy paths)
  if echo "$groups" | grep -q "^/organizations/1234567$"; then
    echo_info "✓ Organization group found: /organizations/1234567"
  else
    echo_warn "⚠ Organization group /organizations/1234567 not found"
  fi

  if echo "$groups" | grep -q "^/accounts/9876543$"; then
    echo_info "✓ Account group found: /accounts/9876543"
  else
    echo_warn "⚠ Account group /accounts/9876543 not found"
  fi
}

function display_summary() {
  echo_header "Keycloak LDAP Configuration Summary"

  cat <<EOF

${GREEN}✓ Keycloak LDAP Federation Configured Successfully${NC}

Configuration Details:
─────────────────────────────────────────────────────────
  Keycloak URL:     $KEYCLOAK_URL
  Realm:            $REALM
  LDAP URL:         $LDAP_URL
  LDAP Base DN:     $LDAP_BASE_DN
  LDAP Bind DN:     $LDAP_BIND_DN

LDAP Mappers:
─────────────────────────────────────────────────────────
  1. Organizations Mapper
     - Maps LDAP path: ou=organizations → Keycloak group hierarchy
     - Preserves hierarchy: true
     - Example: cn=1234567,ou=organizations → "/organizations/1234567"

  2. Accounts Mapper
     - Maps LDAP path: ou=accounts → Keycloak group hierarchy
     - Preserves hierarchy: true
     - Example: cn=9876543,ou=accounts → "/accounts/9876543"

Expected Mappings:
─────────────────────────────────────────────────────────
  User "test" should have groups:
    - /organizations/1234567 (numeric org ID with path)
    - /accounts/9876543      (numeric account with path)

  Authorino will extract:
    - org_id: "1234567" (parses /organizations/ path)
    - account_number: "9876543" (parses /accounts/ path)

Benefits:
  ✓ Clean numeric values in LDAP (no prefixes)
  ✓ Group paths provide semantic meaning
  ✓ Standard LDAP structure (ou-based hierarchy)

Next Steps:
─────────────────────────────────────────────────────────
  1. Verify user import in Keycloak Admin Console:
     ${KEYCLOAK_URL}/admin/master/console/#/${REALM}/users

  2. Check OpenShift User object after login:
     oc get user test -o yaml

  3. Test end-to-end authentication:
     - Login to OpenShift Console as "test" user
     - Make API request with user token
     - Verify X-Rh-Identity header contains correct org_id

Troubleshooting:
─────────────────────────────────────────────────────────
  View LDAP users:
    oc exec -n $NAMESPACE deployment/openldap-demo -- \\
      ldapsearch -x -H ldap://localhost:1389 \\
      -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PASSWORD" \\
      -b "ou=users,$LDAP_BASE_DN" "(uid=test)" dn cn mail

  View LDAP organization groups:
    oc exec -n $NAMESPACE deployment/openldap-demo -- \\
      ldapsearch -x -H ldap://localhost:1389 \\
      -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PASSWORD" \\
      -b "ou=organizations,ou=groups,$LDAP_BASE_DN" \\
      "(objectClass=groupOfNames)" dn cn member

  View LDAP account groups:
    oc exec -n $NAMESPACE deployment/openldap-demo -- \\
      ldapsearch -x -H ldap://localhost:1389 \\
      -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PASSWORD" \\
      -b "ou=accounts,ou=groups,$LDAP_BASE_DN" \\
      "(objectClass=groupOfNames)" dn cn member

  Resync users from LDAP:
    curl -X POST "${KEYCLOAK_URL}/admin/realms/${REALM}/user-storage/${LDAP_COMPONENT_ID}/sync?action=triggerFullSync" \\
      -H "Authorization: Bearer ${ACCESS_TOKEN}"

Documentation:
─────────────────────────────────────────────────────────
  - ADR: docs/adr/0001-ldap-organization-id-mapping.md
  - Integration Guide: docs/authorino-ldap-integration.md

EOF
}

# Main execution
main() {
  echo_header "Keycloak LDAP Configuration Script"
  echo "Configuring LDAP federation in realm: $REALM"
  echo ""

  check_prerequisites
  get_keycloak_url
  get_admin_token
  create_ldap_federation
  create_orgid_group_mapper
  create_account_group_mapper
  sync_users
  verify_configuration
  display_summary
}

main "$@"

