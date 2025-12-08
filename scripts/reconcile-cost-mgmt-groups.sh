#!/bin/bash
#
# Reconcile Cost Management Groups
# ═══════════════════════════════════════════════════════════════════════════
#
# This script ensures OpenShift groups match the authoritative source (Keycloak).
# It removes stale group memberships when user attributes change in LDAP.
#
# Run as: CronJob in keycloak namespace (has credentials)
# Frequency: Every 15 minutes recommended
#

set -euo pipefail

# Configuration
KEYCLOAK_URL="${KEYCLOAK_URL:-https://keycloak-keycloak.apps.stress.parodos.dev}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-kubernetes}"
ORG_ATTR="${COST_MGMT_ORG_ATTR:-employeeNumber}"
ACCOUNT_ATTR="${COST_MGMT_ACCOUNT_ATTR:-employeeType}"
DRY_RUN="${DRY_RUN:-false}"

echo "═══════════════════════════════════════════════════════════"
echo "  Cost Management Group Reconciliation"
echo "═══════════════════════════════════════════════════════════"
echo "Keycloak URL: $KEYCLOAK_URL"
echo "Realm: $KEYCLOAK_REALM"
echo "Org Attribute: $ORG_ATTR"
echo "Account Attribute: $ACCOUNT_ATTR"
echo "Dry Run: $DRY_RUN"
echo ""

# Get Keycloak admin token
get_admin_token() {
  local password
  password=$(cat /var/run/secrets/keycloak/password 2>/dev/null || \
             oc get secret keycloak-initial-admin -n keycloak -o jsonpath='{.data.password}' | base64 -d)

  curl -sk -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=admin" \
    -d "password=$password" \
    -d "grant_type=password" \
    -d "client_id=admin-cli" | jq -r '.access_token'
}

TOKEN=$(get_admin_token)
if [ -z "$TOKEN" ] || [ "$TOKEN" == "null" ]; then
  echo "ERROR: Failed to get Keycloak admin token"
  exit 1
fi
echo "✓ Got Keycloak admin token"

# Get all users from Keycloak with their attributes
echo ""
echo "Fetching users from Keycloak..."
USERS=$(curl -sk "$KEYCLOAK_URL/admin/realms/$KEYCLOAK_REALM/users?max=10000" \
  -H "Authorization: Bearer $TOKEN")

USER_COUNT=$(echo "$USERS" | jq 'length')
echo "✓ Found $USER_COUNT users in Keycloak"

# Build expected group memberships
declare -A EXPECTED_ORG_GROUPS
declare -A EXPECTED_ACCOUNT_GROUPS

echo ""
echo "Building expected group memberships..."
for row in $(echo "$USERS" | jq -r '.[] | @base64'); do
  _jq() {
    echo "$row" | base64 -d | jq -r "$1"
  }

  username=$(_jq '.username')
  org_id=$(_jq ".attributes.${ORG_ATTR}[0] // empty")
  account_num=$(_jq ".attributes.${ACCOUNT_ATTR}[0] // empty")

  if [ -n "$org_id" ]; then
    group_name="cost-mgmt-org-${org_id}"
    EXPECTED_ORG_GROUPS["$group_name"]+="$username "
  fi

  if [ -n "$account_num" ]; then
    group_name="cost-mgmt-account-${account_num}"
    EXPECTED_ACCOUNT_GROUPS["$group_name"]+="$username "
  fi
done

echo "✓ Built expected memberships for ${#EXPECTED_ORG_GROUPS[@]} org groups and ${#EXPECTED_ACCOUNT_GROUPS[@]} account groups"

# Get all cost-mgmt groups from OpenShift
echo ""
echo "Fetching OpenShift groups..."
OCP_GROUPS=$(oc get groups -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name | startswith("cost-mgmt-"))')

# Reconcile each OpenShift group
echo ""
echo "Reconciling groups..."

reconcile_group() {
  local group_name="$1"
  local expected_users="$2"

  # Get current members
  current_users=$(oc get group "$group_name" -o jsonpath='{.users[*]}' 2>/dev/null || echo "")

  # Find users to remove (in OpenShift but not expected)
  for user in $current_users; do
    if [[ ! " $expected_users " =~ " $user " ]]; then
      echo "  STALE: User '$user' should not be in group '$group_name'"
      if [ "$DRY_RUN" != "true" ]; then
        oc adm groups remove-users "$group_name" "$user"
        echo "    → Removed"
      else
        echo "    → Would remove (dry run)"
      fi
    fi
  done
}

# Process org groups
for group_name in $(oc get groups -o name 2>/dev/null | grep "cost-mgmt-org-" | cut -d'/' -f2); do
  expected="${EXPECTED_ORG_GROUPS[$group_name]:-}"
  reconcile_group "$group_name" "$expected"
done

# Process account groups
for group_name in $(oc get groups -o name 2>/dev/null | grep "cost-mgmt-account-" | cut -d'/' -f2); do
  expected="${EXPECTED_ACCOUNT_GROUPS[$group_name]:-}"
  reconcile_group "$group_name" "$expected"
done

# Delete empty groups
echo ""
echo "Cleaning up empty groups..."
for group_name in $(oc get groups -o name 2>/dev/null | grep "cost-mgmt-" | cut -d'/' -f2); do
  members=$(oc get group "$group_name" -o jsonpath='{.users[*]}' 2>/dev/null || echo "")
  if [ -z "$members" ]; then
    echo "  EMPTY: Group '$group_name' has no members"
    if [ "$DRY_RUN" != "true" ]; then
      oc delete group "$group_name"
      echo "    → Deleted"
    else
      echo "    → Would delete (dry run)"
    fi
  fi
done

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Reconciliation complete"
echo "═══════════════════════════════════════════════════════════"


