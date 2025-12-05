#!/usr/bin/env bash
#
# Deploy OpenLDAP Demo Server with Cost Management Organization Structure
# ═══════════════════════════════════════════════════════════════════════════
#
# This script deploys a test LDAP server with the organization structure
# required for demonstrating the LDAP → Keycloak → OpenShift → Authorino
# integration for Cost Management org_id extraction.
#
# Usage:
#   ./deploy-ldap-demo.sh [namespace]
#
# Default namespace: keycloak
#

set -euo pipefail

# Configuration
NAMESPACE="${1:-keycloak}"
LDAP_ADMIN_PASSWORD="admin123"
LDAP_DOMAIN="cost-mgmt.local"
LDAP_BASE_DN="dc=cost-mgmt,dc=local"

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
    echo_error "oc CLI not found. Please install OpenShift CLI."
    exit 1
  fi
  echo_info "oc CLI found"

  if ! oc whoami &> /dev/null; then
    echo_error "Not logged into OpenShift. Please run 'oc login' first."
    exit 1
  fi
  echo_info "Logged into OpenShift as $(oc whoami)"
}

function create_namespace() {
  echo_header "Creating Namespace: $NAMESPACE"

  if oc get namespace "$NAMESPACE" &> /dev/null; then
    echo_warn "Namespace $NAMESPACE already exists"
  else
    oc create namespace "$NAMESPACE"
    echo_info "Created namespace: $NAMESPACE"
  fi
}

function deploy_ldap() {
  echo_header "Deploying OpenLDAP Server"

  cat <<EOF | oc apply -f -
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: ldap-init-data
  namespace: $NAMESPACE
  labels:
    app: openldap-demo
    component: ldap
data:
  # Bootstrap LDIF - Initial directory structure and data
  01-base.ldif: |
    # Root domain entry
    dn: ${LDAP_BASE_DN}
    objectClass: top
    objectClass: domain
    dc: cost-mgmt

    # Organizational Units
    dn: ou=users,${LDAP_BASE_DN}
    objectClass: organizationalUnit
    ou: users
    description: User accounts for Cost Management

    dn: ou=groups,${LDAP_BASE_DN}
    objectClass: organizationalUnit
    ou: groups
    description: Groups for Cost Management

    # Separate OUs for organizations and accounts
    dn: ou=organizations,ou=groups,${LDAP_BASE_DN}
    objectClass: organizationalUnit
    ou: organizations
    description: Organization groups (org_id)

    dn: ou=accounts,ou=groups,${LDAP_BASE_DN}
    objectClass: organizationalUnit
    ou: accounts
    description: Account groups (account_number)

  02-users.ldif: |
    # Test User 1
    # Enterprise pattern: costCenter and accountNumber are USER attributes
    # These will be synced to groups by ldap-user-attrs-to-groups-sync.sh
    dn: uid=test,ou=users,${LDAP_BASE_DN}
    objectClass: inetOrgPerson
    objectClass: posixAccount
    objectClass: shadowAccount
    objectClass: costManagementUser
    uid: test
    cn: cost mgmt test
    sn: test
    givenName: cost mgmt
    displayName: cost mgmt test
    mail: cost@mgmt.net
    userPassword: test
    uidNumber: 10001
    gidNumber: 10001
    homeDirectory: /home/test
    loginShell: /bin/bash
    description: Test user for Cost Management demo
    costCenter: 1234567
    accountNumber: 9876543

    # Test User 2 (different organization and account)
    dn: uid=admin,ou=users,${LDAP_BASE_DN}
    objectClass: inetOrgPerson
    objectClass: posixAccount
    objectClass: shadowAccount
    objectClass: costManagementUser
    uid: admin
    cn: Admin User
    sn: User
    givenName: Admin
    displayName: Admin User
    mail: admin@mgmt.net
    userPassword: admin
    uidNumber: 10002
    gidNumber: 10002
    homeDirectory: /home/admin
    loginShell: /bin/bash
    description: Admin user for Cost Management demo
    costCenter: 7890123
    accountNumber: 5555555

  03-custom-schema.ldif: |
    # Custom schema for Cost Management
    # Enterprise pattern: costCenter and accountNumber are USER attributes
    # These match standard enterprise LDAP schemas (similar to employeeNumber, department)
    dn: cn=cost-management-schema,cn=schema,cn=config
    objectClass: olcSchemaConfig
    cn: cost-management-schema
    olcAttributeTypes: ( 1.3.6.1.4.1.99999.1.1
      NAME 'costCenter'
      DESC 'Cost center / Organization ID - typically from HR system'
      EQUALITY caseIgnoreMatch
      SUBSTR caseIgnoreSubstringsMatch
      SYNTAX 1.3.6.1.4.1.1466.115.121.1.15
      SINGLE-VALUE )
    olcAttributeTypes: ( 1.3.6.1.4.1.99999.1.2
      NAME 'accountNumber'
      DESC 'Account number / Division - typically from HR system'
      EQUALITY caseIgnoreMatch
      SUBSTR caseIgnoreSubstringsMatch
      SYNTAX 1.3.6.1.4.1.1466.115.121.1.15
      SINGLE-VALUE )
    olcObjectClasses: ( 1.3.6.1.4.1.99999.2.1
      NAME 'costManagementUser'
      DESC 'User with cost management attributes (costCenter, accountNumber)'
      SUP top
      AUXILIARY
      MAY ( costCenter $ accountNumber ) )

  04-organizations.ldif: |
    # NOTE: This OU structure is kept for organization, but groups will be
    # AUTO-GENERATED by ldap-user-attrs-to-groups-sync.sh script
    # The sync script reads user.costCenter and creates CN=org-{value} groups
    #
    # You can optionally create manual organizational groups here if needed
    # for other purposes (e.g., department-based access control)
    # But for Cost Management, the sync script will handle org_id/account_number mapping

  05-accounts.ldif: |
    # NOTE: Account groups are AUTO-GENERATED by ldap-user-attrs-to-groups-sync.sh
    # The sync script reads user.accountNumber and creates CN=account-{value} groups
    # under OU=CostMgmt,OU=Groups
    #
    # No manual account groups needed here

---
apiVersion: v1
kind: Secret
metadata:
  name: ldap-admin-password
  namespace: $NAMESPACE
  labels:
    app: openldap-demo
    component: ldap
type: Opaque
stringData:
  LDAP_ADMIN_PASSWORD: "${LDAP_ADMIN_PASSWORD}"

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openldap-demo
  namespace: $NAMESPACE
  labels:
    app: openldap-demo
    component: ldap
spec:
  replicas: 1
  selector:
    matchLabels:
      app: openldap-demo
      component: ldap
  template:
    metadata:
      labels:
        app: openldap-demo
        component: ldap
    spec:
      containers:
      - name: openldap
        image: docker.io/bitnami/openldap:2.6
        ports:
        - name: ldap
          containerPort: 1389
          protocol: TCP
        env:
        - name: LDAP_ROOT
          value: "${LDAP_BASE_DN}"
        - name: LDAP_ADMIN_USERNAME
          value: "admin"
        - name: LDAP_ADMIN_PASSWORD
          valueFrom:
            secretKeyRef:
              name: ldap-admin-password
              key: LDAP_ADMIN_PASSWORD
        - name: LDAP_USERS
          value: "test,admin"
        - name: LDAP_PASSWORDS
          value: "test,admin"
        - name: LDAP_PORT_NUMBER
          value: "1389"
        - name: LDAP_LOGLEVEL
          value: "256"
        - name: LDAP_ENABLE_TLS
          value: "no"
        volumeMounts:
        - name: ldap-init-data
          mountPath: /ldifs
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        livenessProbe:
          tcpSocket:
            port: ldap
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
        readinessProbe:
          tcpSocket:
            port: ldap
          initialDelaySeconds: 10
          periodSeconds: 5
          timeoutSeconds: 3
      volumes:
      - name: ldap-init-data
        configMap:
          name: ldap-init-data

---
apiVersion: v1
kind: Service
metadata:
  name: openldap-demo
  namespace: $NAMESPACE
  labels:
    app: openldap-demo
    component: ldap
spec:
  type: ClusterIP
  ports:
  - name: ldap
    port: 1389
    targetPort: ldap
    protocol: TCP
  selector:
    app: openldap-demo
    component: ldap
EOF

  echo_info "OpenLDAP resources deployed"
}

function wait_for_ldap() {
  echo_header "Waiting for OpenLDAP to be Ready"

  oc wait --for=condition=available --timeout=300s \
    deployment/openldap-demo -n "$NAMESPACE"

  echo_info "OpenLDAP is ready"

  # Wait a bit more for LDAP to fully initialize
  echo_info "Waiting 30s for LDAP initialization..."
  sleep 30
}

function import_ldif_data() {
  echo_header "Importing LDAP Data"

  local pod_name
  pod_name=$(oc get pod -n "$NAMESPACE" -l app=openldap-demo -o jsonpath='{.items[0].metadata.name}')

  if [ -z "$pod_name" ]; then
    echo_error "OpenLDAP pod not found"
    return 1
  fi

  echo_info "Using pod: $pod_name"

  # Import custom schema first (using ldapmodify for cn=config)
  echo_info "Importing custom schema (03-custom-schema.ldif)..."
  oc exec -n "$NAMESPACE" "$pod_name" -- \
    ldapadd -Y EXTERNAL -H ldapi:/// \
    -f "/ldifs/03-custom-schema.ldif" || {
      echo_warn "Warning: Schema may already exist (continuing)"
    }

  # Import data LDIF files
  for ldif in 01-base.ldif 02-users.ldif 04-organizations.ldif 05-accounts.ldif; do
    echo_info "Importing $ldif..."
    oc exec -n "$NAMESPACE" "$pod_name" -- \
      ldapadd -x -H ldap://localhost:1389 \
      -D "cn=admin,${LDAP_BASE_DN}" \
      -w "${LDAP_ADMIN_PASSWORD}" \
      -f "/ldifs/$ldif" || {
        echo_warn "Warning: Some entries in $ldif may already exist (continuing)"
      }
  done

  echo_info "LDAP data imported successfully"
}

function verify_ldap() {
  echo_header "Verifying LDAP Setup"

  local pod_name
  pod_name=$(oc get pod -n "$NAMESPACE" -l app=openldap-demo -o jsonpath='{.items[0].metadata.name}')

  echo_info "Testing LDAP search..."
  oc exec -n "$NAMESPACE" "$pod_name" -- \
    ldapsearch -x -H ldap://localhost:1389 \
    -D "cn=admin,${LDAP_BASE_DN}" \
    -w "${LDAP_ADMIN_PASSWORD}" \
    -b "${LDAP_BASE_DN}" \
    "(objectClass=*)" dn | grep -E "^dn:" | head -20

  echo ""
  echo_info "Verifying test user..."
  oc exec -n "$NAMESPACE" "$pod_name" -- \
    ldapsearch -x -H ldap://localhost:1389 \
    -D "cn=admin,${LDAP_BASE_DN}" \
    -w "${LDAP_ADMIN_PASSWORD}" \
    -b "ou=users,${LDAP_BASE_DN}" \
    "(uid=test)" dn cn mail

  echo ""
  echo_info "Verifying organization groups with custom attributes..."
  oc exec -n "$NAMESPACE" "$pod_name" -- \
    ldapsearch -x -H ldap://localhost:1389 \
    -D "cn=admin,${LDAP_BASE_DN}" \
    -w "${LDAP_ADMIN_PASSWORD}" \
    -b "ou=organizations,ou=groups,${LDAP_BASE_DN}" \
    "(objectClass=costManagementGroup)" dn cn organizationId member

  echo ""
  echo_info "Verifying account groups with custom attributes..."
  oc exec -n "$NAMESPACE" "$pod_name" -- \
    ldapsearch -x -H ldap://localhost:1389 \
    -D "cn=admin,${LDAP_BASE_DN}" \
    -w "${LDAP_ADMIN_PASSWORD}" \
    -b "ou=accounts,ou=groups,${LDAP_BASE_DN}" \
    "(objectClass=costManagementGroup)" dn cn accountNumber member
}

function display_summary() {
  echo_header "OpenLDAP Demo Deployment Summary"

  cat <<EOF

${GREEN}✓ OpenLDAP Demo Server Deployed Successfully${NC}

LDAP Server Details:
─────────────────────────────────────────────────────────
  Namespace:        $NAMESPACE
  Service:          openldap-demo.${NAMESPACE}.svc.cluster.local
  Port:             1389
  Base DN:          ${LDAP_BASE_DN}
  Admin DN:         cn=admin,${LDAP_BASE_DN}
  Admin Password:   ${LDAP_ADMIN_PASSWORD}

Directory Structure:
─────────────────────────────────────────────────────────
  ${LDAP_BASE_DN}
  ├── ou=users
  │   ├── uid=test         (password: test)
  │   └── uid=admin        (password: admin)
  └── ou=groups
      ├── ou=organizations  (Organization IDs)
      │   ├── cn=engineering (costManagementGroup)
      │   │   ├── cn: engineering           ← human-readable
      │   │   └── organizationId: 1234567   ← clean numeric value
      │   └── cn=finance (costManagementGroup)
      │       ├── cn: finance
      │       └── organizationId: 7890123
      └── ou=accounts (Account Numbers)
          ├── cn=account-9876543 (costManagementGroup)
          │   ├── cn: account-9876543        ← human-readable
          │   └── accountNumber: 9876543     ← clean numeric value
          └── cn=account-5555555
              ├── cn: account-5555555
              └── accountNumber: 5555555

Simple LDAP Management:
─────────────────────────────────────────────────────────
  Just 2 extra fields per group (clean numeric values):
    - organizationId: "1234567"  ← No prefix, just the number
    - accountNumber:  "9876543"  ← No prefix, just the number

  No special management needed - LDAP admins just set these fields.

  Keycloak does the mapping:
    - Reads organizationId field → Creates group "/organizations/1234567"
    - Reads accountNumber field  → Creates group "/accounts/9876543"

  Path distinction happens in Keycloak (not in LDAP values)

Test Users:
─────────────────────────────────────────────────────────
  User: test
    Username: test
    Password: test
    Email:    cost@mgmt.net
    Full Name: cost mgmt test
    LDAP Groups:
      - cn=1234567,ou=organizations (numeric org ID)
      - cn=9876543,ou=accounts      (numeric account number)
    Expected Keycloak Groups:
      - "/organizations/1234567" (group path)
      - "/accounts/9876543"      (group path)
    Expected Authorino Extraction:
      org_id: 1234567         (from /organizations/ path)
      account_number: 9876543 (from /accounts/ path)

  User: admin
    Username: admin
    Password: admin
    Email:    admin@mgmt.net
    Full Name: Admin User
    LDAP Groups:
      - cn=7890123,ou=organizations
      - cn=5555555,ou=accounts
    Expected Keycloak Groups:
      - "/organizations/7890123"
      - "/accounts/5555555"
    Expected Authorino Extraction:
      org_id: 7890123
      account_number: 5555555

Next Steps:
─────────────────────────────────────────────────────────
  1. Configure Keycloak LDAP Federation:
     ./configure-keycloak-ldap.sh

  2. Verify integration:
     - Check sync job created groups:
       ldapsearch -x -H ldap://localhost:${LDAP_PORT} \
         -D "cn=admin,${LDAP_BASE_DN}" -w "${LDAP_ADMIN_PASSWORD}" \
         -b "ou=CostMgmt,ou=groups,${LDAP_BASE_DN}" "(cn=org-*)"

     - Expected groups:
       * CN=org-1234567 (from test user's costCenter)
       * CN=org-7890123 (from admin user's costCenter)
       * CN=account-9876543 (from test user's accountNumber)
       * CN=account-5555555 (from admin user's accountNumber)

     How it works (Enterprise Pattern):
       User Attributes in LDAP:
         test: costCenter="1234567", accountNumber="9876543"
       ↓
       Sync Script (CronJob every 5 min):
         Creates groups: CN=org-1234567, CN=account-9876543
         Adds test user as member
       ↓
       Keycloak LDAP Group Mapper:
         Imports groups with prefixes: /organizations/1234567, /accounts/9876543
       ↓
       OpenShift OAuth:
         User object has groups array
       ↓
       Authorino:
         Parses groups to extract org_id and account_number

  3. After Keycloak configuration (run configure-keycloak-ldap.sh):
     - Login to OpenShift Console as "test" user
     - Check: oc get user test -o yaml
     - Expected groups: ["/organizations/1234567", "/accounts/9876543"]

  4. Test end-to-end flow:
     - Make API request with test user token
     - Verify X-Rh-Identity header contains:
       org_id: "1234567"
       account_number: "9876543"

Documentation:
─────────────────────────────────────────────────────────
  - ADR: docs/adr/0001-ldap-organization-id-mapping.md
  - Integration Guide: docs/authorino-ldap-integration.md

EOF
}

# Deploy LDAP Sync CronJob
deploy_sync_cronjob() {
  echo_header "Deploying LDAP User Attributes to Groups Sync"

  # Update the sync cronjob YAML with correct values
  local sync_yaml="/tmp/ldap-sync-cronjob-configured.yaml"

  cat > "$sync_yaml" <<'SYNCEOF'
---
# Secret for LDAP Service Account Credentials
apiVersion: v1
kind: Secret
metadata:
  name: ldap-sync-credentials
  namespace: keycloak
  labels:
    app: ldap-sync
    component: credentials
type: Opaque
stringData:
  LDAP_HOST: "ldap://openldap-demo.keycloak.svc.cluster.local:1389"
  LDAP_BIND_DN: "cn=admin,dc=cost-mgmt,dc=local"
  LDAP_BIND_PASSWORD: "admin123"
  LDAP_BASE_DN: "dc=cost-mgmt,dc=local"
  LDAP_USER_BASE: "ou=users,dc=cost-mgmt,dc=local"
  LDAP_GROUP_BASE: "ou=CostMgmt,ou=groups,dc=cost-mgmt,dc=local"
  ORG_ID_ATTR: "costCenter"
  ACCOUNT_ATTR: "accountNumber"
  ORG_GROUP_PREFIX: "cost-mgmt-org-"
  ACCOUNT_GROUP_PREFIX: "cost-mgmt-account-"
  LOG_LEVEL: "INFO"
---
# ConfigMap with embedded sync script
apiVersion: v1
kind: ConfigMap
metadata:
  name: ldap-sync-script
  namespace: keycloak
  labels:
    app: ldap-sync
    component: script
data:
  sync.sh: |
    #!/bin/bash
    # Embedded version of ldap-user-attrs-to-groups-sync.sh
    # Production version: scripts/ldap-user-attrs-to-groups-sync.sh

    set -euo pipefail

    log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] ${@:2}"; }
    log_info() { log "INFO" "$@"; }
    log_error() { log "ERROR" "$@"; }

    log_info "═══════════════════════════════════════════════════════════"
    log_info "LDAP User Attributes to Groups Sync (Demo)"
    log_info "═══════════════════════════════════════════════════════════"

    # Ensure group OU exists
    ldapadd -x -H "$LDAP_HOST" -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PASSWORD" 2>/dev/null <<EOF || log_info "Group OU exists"
    dn: ${LDAP_GROUP_BASE}
    objectClass: organizationalUnit
    ou: CostMgmt
    description: Auto-generated groups for Cost Management
    EOF

    # Sync costCenter -> org-* groups
    log_info "Syncing costCenter → org-* groups..."
    ORGS=$(ldapsearch -x -H "$LDAP_HOST" -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PASSWORD" \
      -b "$LDAP_USER_BASE" "(costCenter=*)" costCenter 2>/dev/null | \
      grep "^costCenter:" | cut -d: -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sort -u)

    for ORG_ID in $ORGS; do
      [ -z "$ORG_ID" ] && continue
      GROUP_DN="CN=${ORG_GROUP_PREFIX}${ORG_ID},${LDAP_GROUP_BASE}"

      USERS=$(ldapsearch -x -H "$LDAP_HOST" -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PASSWORD" \
        -b "$LDAP_USER_BASE" "(costCenter=${ORG_ID})" dn 2>/dev/null | \
        grep "^dn:" | cut -d: -f2- | sed 's/^[[:space:]]*//')

      FIRST_USER=$(echo "$USERS" | head -1)

      if ! ldapsearch -x -H "$LDAP_HOST" -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PASSWORD" \
         -b "$GROUP_DN" -s base "(objectClass=*)" dn &>/dev/null; then
        ldapadd -x -H "$LDAP_HOST" -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PASSWORD" &>/dev/null <<EOF
    dn: $GROUP_DN
    objectClass: groupOfNames
    cn: ${ORG_GROUP_PREFIX}${ORG_ID}
    description: Auto-generated: Users with costCenter=${ORG_ID}
    member: $FIRST_USER
    EOF
        log_info "  Created: ${ORG_GROUP_PREFIX}${ORG_ID}"
      fi
    done

    # Sync accountNumber -> account-* groups
    log_info "Syncing accountNumber → account-* groups..."
    ACCOUNTS=$(ldapsearch -x -H "$LDAP_HOST" -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PASSWORD" \
      -b "$LDAP_USER_BASE" "(accountNumber=*)" accountNumber 2>/dev/null | \
      grep "^accountNumber:" | cut -d: -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sort -u)

    for ACCOUNT in $ACCOUNTS; do
      [ -z "$ACCOUNT" ] && continue
      GROUP_DN="CN=${ACCOUNT_GROUP_PREFIX}${ACCOUNT},${LDAP_GROUP_BASE}"

      USERS=$(ldapsearch -x -H "$LDAP_HOST" -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PASSWORD" \
        -b "$LDAP_USER_BASE" "(accountNumber=${ACCOUNT})" dn 2>/dev/null | \
        grep "^dn:" | cut -d: -f2- | sed 's/^[[:space:]]*//')

      FIRST_USER=$(echo "$USERS" | head -1)

      if ! ldapsearch -x -H "$LDAP_HOST" -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PASSWORD" \
         -b "$GROUP_DN" -s base "(objectClass=*)" dn &>/dev/null; then
        ldapadd -x -H "$LDAP_HOST" -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PASSWORD" &>/dev/null <<EOF
    dn: $GROUP_DN
    objectClass: groupOfNames
    cn: ${ACCOUNT_GROUP_PREFIX}${ACCOUNT}
    description: Auto-generated: Users with accountNumber=${ACCOUNT}
    member: $FIRST_USER
    EOF
        log_info "  Created: ${ACCOUNT_GROUP_PREFIX}${ACCOUNT}"
      fi
    done

    log_info "═══════════════════════════════════════════════════════════"
    log_info "Sync completed successfully"
    log_info "═══════════════════════════════════════════════════════════"
---
# CronJob (manual trigger for demo, or set schedule)
apiVersion: batch/v1
kind: CronJob
metadata:
  name: ldap-user-attrs-sync
  namespace: keycloak
  labels:
    app: ldap-sync
    component: cronjob
spec:
  schedule: "*/5 * * * *"  # Every 5 minutes for demo (change to daily in prod)
  suspend: false
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      backoffLimit: 1
      activeDeadlineSeconds: 300
      template:
        spec:
          restartPolicy: OnFailure
          serviceAccountName: default
          containers:
          - name: ldap-sync
            image: alpine:3.18
            command:
            - /bin/sh
            - -c
            - |
              apk add --no-cache openldap-clients bash
              chmod +x /scripts/sync.sh
              /scripts/sync.sh
            envFrom:
            - secretRef:
                name: ldap-sync-credentials
            volumeMounts:
            - name: script
              mountPath: /scripts
              readOnly: true
            resources:
              requests:
                cpu: 50m
                memory: 64Mi
              limits:
                cpu: 200m
                memory: 128Mi
            securityContext:
              allowPrivilegeEscalation: false
              runAsNonRoot: true
              runAsUser: 1000
              capabilities:
                drop:
                - ALL
          volumes:
          - name: script
            configMap:
              name: ldap-sync-script
              defaultMode: 0755
SYNCEOF

  echo_info "Deploying LDAP sync CronJob..."
  oc apply -f "$sync_yaml"

  echo_info "✓ LDAP sync CronJob deployed"
  echo_info ""
  echo_info "The sync job will run every 5 minutes (demo frequency)"
  echo_info "To trigger manually:"
  echo_info "  oc create job --from=cronjob/ldap-user-attrs-sync manual-sync-1 -n keycloak"
  echo_info ""
  echo_info "To view logs:"
  echo_info "  oc logs -n keycloak -l app=ldap-sync --tail=50"
  echo_info ""

  # Trigger initial sync
  echo_info "Triggering initial sync..."
  oc create job --from=cronjob/ldap-user-attrs-sync initial-sync -n keycloak 2>/dev/null || echo_warn "Initial sync job already exists"

  # Wait a bit and show results
  sleep 5
  echo_info "Checking for created groups in LDAP..."
  ldapsearch -x -H "ldap://localhost:$LDAP_PORT" \
    -D "cn=admin,$LDAP_BASE_DN" -w "$LDAP_ADMIN_PASSWORD" \
    -b "ou=CostMgmt,ou=groups,$LDAP_BASE_DN" "(objectClass=*)" cn 2>/dev/null | \
    grep "^cn:" | cut -d: -f2 | sed 's/^ /  - /' || echo_warn "No groups found yet (sync may still be running)"
}

# Main execution
main() {
  echo_header "OpenLDAP Demo Deployment Script"
  echo "Deploying to namespace: $NAMESPACE"
  echo ""

  check_prerequisites
  create_namespace
  deploy_ldap
  wait_for_ldap
  import_ldif_data
  verify_ldap
  deploy_sync_cronjob
  display_summary
}

main "$@"

