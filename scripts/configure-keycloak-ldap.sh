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
# Port 389 for osixia/openldap (standard LDAP port)
LDAP_URL="ldap://openldap-demo.${NAMESPACE}.svc.cluster.local:389"
LDAP_BASE_DN="dc=cost-mgmt,dc=local"
LDAP_BIND_DN="cn=admin,${LDAP_BASE_DN}"
LDAP_BIND_PASSWORD="admin"

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

function create_cost_mgmt_group_mapper() {
  echo_header "Creating Cost Management Group Mapper"

  if [ -z "$LDAP_COMPONENT_ID" ]; then
    echo_error "LDAP Component ID not found"
    exit 1
  fi

  # Check if mapper already exists
  local existing_id
  existing_id=$(curl -sk -X GET "${KEYCLOAK_URL}/admin/realms/${REALM}/components" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" | \
    jq -r '.[] | select(.name == "cost-mgmt-groups" and .providerId == "group-ldap-mapper") | .id' | head -1)

  if [ -n "$existing_id" ] && [ "$existing_id" != "null" ]; then
    echo_warn "Cost Management groups mapper already exists (ID: $existing_id), deleting..."
    curl -sk -X DELETE "${KEYCLOAK_URL}/admin/realms/${REALM}/components/${existing_id}" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}"
  fi

  # Also clean up old org/account mappers if they exist
  for mapper_name in "organization-groups-mapper" "account-groups-mapper"; do
    local old_mapper_id
    old_mapper_id=$(curl -sk -X GET "${KEYCLOAK_URL}/admin/realms/${REALM}/components" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "Content-Type: application/json" | \
      jq -r '.[] | select(.name == "'"${mapper_name}"'" and .providerId == "group-ldap-mapper") | .id' | head -1)
    if [ -n "$old_mapper_id" ] && [ "$old_mapper_id" != "null" ]; then
      echo_warn "Removing old mapper: $mapper_name"
      curl -sk -X DELETE "${KEYCLOAK_URL}/admin/realms/${REALM}/components/${old_mapper_id}" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}"
    fi
  done

  # Create single group mapper for all Cost Management groups in ou=CostMgmt
  # Groups: cost-mgmt-org-{orgId}, cost-mgmt-account-{accountNumber}
  local response
  response=$(curl -sk -X POST "${KEYCLOAK_URL}/admin/realms/${REALM}/components" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{
      "name": "cost-mgmt-groups",
      "providerId": "group-ldap-mapper",
      "providerType": "org.keycloak.storage.ldap.mappers.LDAPStorageMapper",
      "parentId": "'"${LDAP_COMPONENT_ID}"'",
      "config": {
        "groups.dn": ["ou=CostMgmt,ou=groups,'"${LDAP_BASE_DN}"'"],
        "group.name.ldap.attribute": ["cn"],
        "group.object.classes": ["groupOfNames"],
        "preserve.group.inheritance": ["false"],
        "membership.ldap.attribute": ["member"],
        "membership.attribute.type": ["DN"],
        "membership.user.ldap.attribute": ["uid"],
        "groups.ldap.filter": [""],
        "mode": ["READ_ONLY"],
        "user.roles.retrieve.strategy": ["LOAD_GROUPS_BY_MEMBER_ATTRIBUTE"],
        "memberof.ldap.attribute": ["memberOf"],
        "ignore.missing.groups": ["false"],
        "drop.non.existing.groups.during.sync": ["false"]
      }
    }' -w "\n%{http_code}" 2>/dev/null)

  local http_code
  http_code=$(echo "$response" | tail -n1)

  if [ "$http_code" != "201" ]; then
    echo_error "Failed to create cost-mgmt groups mapper (HTTP $http_code)"
    echo "Response: $(echo "$response" | head -n-1)"
    exit 1
  fi

  echo_info "✓ Cost Management groups mapper created"
  echo_info "  Groups DN: ou=CostMgmt,ou=groups,$LDAP_BASE_DN"
  echo_info "  Imports: cost-mgmt-org-*, cost-mgmt-account-*"
}

function sync_groups() {
  echo_header "Synchronizing Groups from LDAP"

  if [ -z "$LDAP_COMPONENT_ID" ]; then
    echo_error "LDAP Component ID not found"
    exit 1
  fi

  # Get the group mapper ID
  local mapper_id
  mapper_id=$(curl -sk -X GET "${KEYCLOAK_URL}/admin/realms/${REALM}/components?parent=${LDAP_COMPONENT_ID}" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" | \
    jq -r '.[] | select(.name == "cost-mgmt-groups") | .id' | head -1)

  if [ -z "$mapper_id" ] || [ "$mapper_id" = "null" ]; then
    echo_warn "Group mapper not found, skipping group sync"
    return 0
  fi

  echo_info "Group mapper ID: $mapper_id"

  # Trigger group sync (fedToKeycloak direction)
  local response
  response=$(curl -sk -X POST "${KEYCLOAK_URL}/admin/realms/${REALM}/user-storage/${LDAP_COMPONENT_ID}/mappers/${mapper_id}/sync?direction=fedToKeycloak" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" 2>/dev/null)

  echo_info "Group sync triggered"
  echo "Response: $response"

  # Wait for sync
  sleep 3
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

  # List all groups in Keycloak
  echo ""
  echo_info "Groups in Keycloak:"
  local all_groups
  all_groups=$(curl -sk -X GET "${KEYCLOAK_URL}/admin/realms/${REALM}/groups" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" | \
    jq -r '.[].name' 2>/dev/null)

  echo "$all_groups" | while read -r group; do
    [ -n "$group" ] && echo "  - $group"
  done

  # Get user's groups
  echo ""
  echo_info "Test user's group memberships:"
  local groups
  groups=$(curl -sk -X GET "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${user_id}/groups" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" | \
    jq -r '.[].name' 2>/dev/null)

  echo "$groups" | while read -r group; do
    [ -n "$group" ] && echo "  - $group"
  done

  # Check for expected groups (cost-mgmt-org-* and cost-mgmt-account-*)
  if echo "$groups" | grep -q "cost-mgmt-org-1234567"; then
    echo_info "✓ Organization group found: cost-mgmt-org-1234567"
  else
    echo_warn "⚠ Organization group cost-mgmt-org-1234567 not found"
  fi

  if echo "$groups" | grep -q "cost-mgmt-account-9876543"; then
    echo_info "✓ Account group found: cost-mgmt-account-9876543"
  else
    echo_warn "⚠ Account group cost-mgmt-account-9876543 not found"
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

LDAP Group Mapper:
─────────────────────────────────────────────────────────
  Cost Management Groups Mapper:
     - Groups DN: ou=CostMgmt,ou=groups,$LDAP_BASE_DN
     - Imports all groups in the CostMgmt OU
     - Pattern: cost-mgmt-org-{orgId}, cost-mgmt-account-{accountNumber}

Expected Mappings:
─────────────────────────────────────────────────────────
  User "test" should have groups:
    - cost-mgmt-org-1234567     (organization ID)
    - cost-mgmt-account-9876543 (account number)

  User "admin" should have groups:
    - cost-mgmt-org-7890123     (organization ID)
    - cost-mgmt-account-5555555 (account number)

  Authorino OPA/Rego will extract:
    - org_id: "1234567" (parses cost-mgmt-org- prefix)
    - account_number: "9876543" (parses cost-mgmt-account- prefix)

Benefits:
  ✓ Clean numeric values extracted from group names
  ✓ Namespaced prefixes prevent collisions (cost-mgmt-*)
  ✓ OU isolation (ou=CostMgmt) for managed groups

Next Steps:
─────────────────────────────────────────────────────────
  1. Verify user import in Keycloak Admin Console:
     ${KEYCLOAK_URL}/admin/master/console/#/${REALM}/users

  2. Verify groups in Keycloak Admin Console:
     ${KEYCLOAK_URL}/admin/master/console/#/${REALM}/groups

  3. Test end-to-end flow with demo script:
     ./scripts/demo-ldap-to-authorino.sh

Troubleshooting:
─────────────────────────────────────────────────────────
  View LDAP users:
    oc exec -n $NAMESPACE deployment/openldap-demo -- \\
      ldapsearch -x -H ldap://localhost \\
      -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PASSWORD" \\
      -b "ou=users,$LDAP_BASE_DN" "(uid=*)" dn cn mail

  View Cost Management groups:
    oc exec -n $NAMESPACE deployment/openldap-demo -- \\
      ldapsearch -x -H ldap://localhost \\
      -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PASSWORD" \\
      -b "ou=CostMgmt,ou=groups,$LDAP_BASE_DN" \\
      "(objectClass=groupOfNames)" cn member

  Resync from LDAP:
    # Users
    curl -sk -X POST "${KEYCLOAK_URL}/admin/realms/${REALM}/user-storage/${LDAP_COMPONENT_ID}/sync?action=triggerFullSync" \\
      -H "Authorization: Bearer \$TOKEN"
    # Groups (get mapper ID first)
    curl -sk -X POST "${KEYCLOAK_URL}/admin/realms/${REALM}/user-storage/${LDAP_COMPONENT_ID}/mappers/\$MAPPER_ID/sync?direction=fedToKeycloak" \\
      -H "Authorization: Bearer \$TOKEN"

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
  create_cost_mgmt_group_mapper
  sync_users
  sync_groups
  verify_configuration
  display_summary
}

main "$@"

