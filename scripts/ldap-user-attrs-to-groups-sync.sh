#!/bin/bash
#
# LDAP User Attributes to Groups Sync Script
# ═══════════════════════════════════════════════════════════════════════════
#
# Purpose: Reads user attributes (costCenter, division) from enterprise LDAP
#          and creates/updates shadow groups that Keycloak can import.
#
# Use Case: Enterprises with existing LDAP user attributes who are using RHBK
#           (Red Hat Build of Keycloak) where script mappers require JAR packaging.
#
# How it works:
#   1. Queries LDAP for all unique values of specified attributes (e.g., costCenter)
#   2. For each unique value, creates/updates an LDAP group (e.g., CN=org-1001)
#   3. Adds all users with that attribute value as members of the group
#   4. Keycloak's standard LDAP Group Mapper imports these groups
#   5. Groups flow to OpenShift → TokenReview → Authorino parses them
#
# Prerequisites:
#   - LDAP service account with write permissions to group OU
#   - ldap-utils package installed (ldapsearch, ldapadd, ldapmodify)
#   - Network connectivity to LDAP server
#
# Deployment:
#   - Run as Kubernetes CronJob (daily schedule recommended)
#   - Store credentials in Kubernetes Secret
#   - Monitor logs for failures
#
# Configuration:
#   Set via environment variables or edit defaults below
#
# Author: Cost Management Team
# Version: 1.0
#

set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════

# LDAP Connection Settings
LDAP_HOST="${LDAP_HOST:-ldap://ldap.company.com:389}"
LDAP_BIND_DN="${LDAP_BIND_DN:-CN=svc-keycloak-sync,OU=ServiceAccounts,DC=company,DC=com}"
LDAP_BIND_PASSWORD="${LDAP_BIND_PASSWORD:-}"
LDAP_BASE_DN="${LDAP_BASE_DN:-DC=company,DC=com}"

# LDAP Structure
LDAP_USER_BASE="${LDAP_USER_BASE:-OU=Users,${LDAP_BASE_DN}}"
LDAP_GROUP_BASE="${LDAP_GROUP_BASE:-OU=CostMgmt,OU=Groups,${LDAP_BASE_DN}}"

# User Attributes to Sync
# These should match the attributes in your enterprise LDAP that contain org_id and account_number
ORG_ID_ATTR="${ORG_ID_ATTR:-costCenter}"      # Maps to org_id
ACCOUNT_ATTR="${ACCOUNT_ATTR:-division}"       # Maps to account_number

# Group Naming (with namespace prefix to avoid collisions)
ORG_GROUP_PREFIX="${ORG_GROUP_PREFIX:-cost-mgmt-org-}"
ACCOUNT_GROUP_PREFIX="${ACCOUNT_GROUP_PREFIX:-cost-mgmt-account-}"

# Logging
LOG_LEVEL="${LOG_LEVEL:-INFO}"  # DEBUG, INFO, WARN, ERROR

# ═══════════════════════════════════════════════════════════════════════════
# FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

log() {
  local level="$1"
  shift
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
}

log_info() { [ "$LOG_LEVEL" != "ERROR" ] && [ "$LOG_LEVEL" != "WARN" ] && log "INFO" "$@" || true; }
log_warn() { [ "$LOG_LEVEL" != "ERROR" ] && log "WARN" "$@" || true; }
log_error() { log "ERROR" "$@"; }
log_debug() { [ "$LOG_LEVEL" = "DEBUG" ] && log "DEBUG" "$@" || true; }

check_prerequisites() {
  log_info "Checking prerequisites..."

  # Check required commands
  for cmd in ldapsearch ldapadd ldapmodify; do
    if ! command -v "$cmd" &>/dev/null; then
      log_error "Required command '$cmd' not found. Please install ldap-utils package."
      exit 1
    fi
  done

  # Check required environment variables
  if [ -z "$LDAP_BIND_PASSWORD" ]; then
    log_error "LDAP_BIND_PASSWORD environment variable is required"
    exit 1
  fi

  # Test LDAP connection
  if ! ldapsearch -x -H "$LDAP_HOST" -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PASSWORD" \
       -b "$LDAP_BASE_DN" -s base "(objectClass=*)" dn &>/dev/null; then
    log_error "Failed to connect to LDAP server at $LDAP_HOST"
    exit 1
  fi

  log_info "✓ Prerequisites check passed"
}

ensure_group_ou() {
  log_info "Ensuring group OU exists: $LDAP_GROUP_BASE"

  # Check if OU exists
  if ldapsearch -x -H "$LDAP_HOST" -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PASSWORD" \
     -b "$LDAP_GROUP_BASE" -s base "(objectClass=*)" dn &>/dev/null; then
    log_debug "Group OU already exists"
    return 0
  fi

  # Create OU
  local ou_rdn
  ou_rdn=$(echo "$LDAP_GROUP_BASE" | cut -d',' -f1 | cut -d'=' -f2)

  ldapadd -x -H "$LDAP_HOST" -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PASSWORD" <<EOF 2>/dev/null || {
    log_warn "Could not create group OU (may already exist)"
  }
dn: $LDAP_GROUP_BASE
objectClass: organizationalUnit
ou: $ou_rdn
description: Auto-generated groups for Cost Management (synced from user attributes)
EOF

  log_info "✓ Group OU ready"
}

sync_attribute_to_groups() {
  local attr_name="$1"
  local group_prefix="$2"
  local path_prefix="$3"  # e.g., "/organizations/" or "/accounts/"
  
  # Determine type marker based on path prefix
  local type_marker
  if [[ "$path_prefix" == "/organizations/" ]]; then
    type_marker="organization"
  elif [[ "$path_prefix" == "/accounts/" ]]; then
    type_marker="account"
  else
    log_error "Unknown path prefix: $path_prefix"
    return 1
  fi
  
  log_info "Syncing ${attr_name} → ${group_prefix}* groups (type: ${type_marker})..."

  # Get all unique attribute values
  local values
  values=$(ldapsearch -x -H "$LDAP_HOST" -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PASSWORD" \
    -b "$LDAP_USER_BASE" "(${attr_name}=*)" "$attr_name" 2>/dev/null | \
    grep "^${attr_name}:" | cut -d: -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sort -u)

  if [ -z "$values" ]; then
    log_warn "No users found with ${attr_name} attribute"
    return 0
  fi

  local value_count
  value_count=$(echo "$values" | wc -l | tr -d ' ')
  log_info "Found $value_count unique ${attr_name} values"

  local synced=0
  local failed=0

  while IFS= read -r value; do
    [ -z "$value" ] && continue

    local group_name="${group_prefix}${value}"
    local group_dn="CN=${group_name},${LDAP_GROUP_BASE}"

    log_debug "Processing: $attr_name=$value → $group_name"

    # Get all users with this attribute value
    local users
    users=$(ldapsearch -x -H "$LDAP_HOST" -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PASSWORD" \
      -b "$LDAP_USER_BASE" "(${attr_name}=${value})" dn 2>/dev/null | \
      grep "^dn:" | cut -d: -f2- | sed 's/^[[:space:]]*//')

    if [ -z "$users" ]; then
      log_warn "No users found for $attr_name=$value, skipping"
      continue
    fi

    local user_count
    user_count=$(echo "$users" | wc -l | tr -d ' ')

    # Check if group exists AND verify it's ours via type marker
    local existing_type
    existing_type=$(ldapsearch -x -H "$LDAP_HOST" -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PASSWORD" \
      -b "$group_dn" -s base "(objectClass=*)" costManagementType 2>/dev/null | \
      grep "^costManagementType:" | cut -d: -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    if [ -n "$existing_type" ]; then
      # Group exists - verify it's the correct type
      if [ "$existing_type" != "$type_marker" ]; then
        log_warn "  SKIP: Group $group_dn exists but type=$existing_type (expected: $type_marker)"
        log_warn "  This group may be managed by a different system or process"
        ((failed++))
        continue
      fi
      
      # Safe to update - it's ours and correct type
      log_debug "  Updating managed group: $group_dn ($user_count members, type: $existing_type)"
      
      # Clear existing members
      ldapmodify -x -H "$LDAP_HOST" -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PASSWORD" &>/dev/null <<EOF || true
dn: $group_dn
changetype: modify
delete: member
EOF
      
      # Add current members
      while IFS= read -r user_dn; do
        [ -z "$user_dn" ] && continue
        ldapmodify -x -H "$LDAP_HOST" -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PASSWORD" &>/dev/null <<EOF || {
          log_warn "  Failed to add member: $user_dn"
        }
dn: $group_dn
changetype: modify
add: member
member: $user_dn
EOF
      done <<< "$users"
    else
      # Create new group with type marker
      log_debug "  Creating new managed group: $group_dn ($user_count members, type: $type_marker)"
      
      # Need at least one member to create group (groupOfNames/costManagementGroup requirement)
      local first_user
      first_user=$(echo "$users" | head -1)
      
      if ! ldapadd -x -H "$LDAP_HOST" -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PASSWORD" &>/dev/null <<EOF; then
dn: $group_dn
objectClass: costManagementGroup
cn: $group_name
costManagementType: $type_marker
description: Auto-generated: Users with ${attr_name}=${value} (managed by Cost Management sync)
member: $first_user
EOF
        log_error "  Failed to create group: $group_dn"
        ((failed++))
        continue
      fi

      # Add remaining members
      echo "$users" | tail -n +2 | while IFS= read -r user_dn; do
        [ -z "$user_dn" ] && continue
        ldapmodify -x -H "$LDAP_HOST" -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PASSWORD" &>/dev/null <<EOF || {
          log_warn "  Failed to add member: $user_dn"
        }
dn: $group_dn
changetype: modify
add: member
member: $user_dn
EOF
      done
    fi

    log_info "  ✓ ${group_name}: $user_count members"
    ((synced++))
  done <<< "$values"

  log_info "✓ Synced $synced ${attr_name} groups ($failed failed)"
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════

main() {
  log_info "═══════════════════════════════════════════════════════════"
  log_info "LDAP User Attributes to Groups Sync"
  log_info "═══════════════════════════════════════════════════════════"
  log_info "LDAP Host: $LDAP_HOST"
  log_info "User Base: $LDAP_USER_BASE"
  log_info "Group Base: $LDAP_GROUP_BASE"
  log_info "Org ID Attribute: $ORG_ID_ATTR → ${ORG_GROUP_PREFIX}*"
  log_info "Account Attribute: $ACCOUNT_ATTR → ${ACCOUNT_GROUP_PREFIX}*"
  log_info "═══════════════════════════════════════════════════════════"

  check_prerequisites
  ensure_group_ou

  # Sync organization IDs (costCenter → /organizations/X)
  sync_attribute_to_groups "$ORG_ID_ATTR" "$ORG_GROUP_PREFIX" "/organizations/"

  # Sync account numbers (division → /accounts/X)
  sync_attribute_to_groups "$ACCOUNT_ATTR" "$ACCOUNT_GROUP_PREFIX" "/accounts/"

  log_info "═══════════════════════════════════════════════════════════"
  log_info "Sync completed successfully"
  log_info "═══════════════════════════════════════════════════════════"
}

# Handle signals
trap 'log_error "Sync interrupted"; exit 130' INT TERM

# Run main function
main "$@"

