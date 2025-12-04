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
    description: Groups for Cost Management (includes organization groups)

  02-users.ldif: |
    # Test User 1
    dn: uid=test,ou=users,${LDAP_BASE_DN}
    objectClass: inetOrgPerson
    objectClass: posixAccount
    objectClass: shadowAccount
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

    # Test User 2 (different organization)
    dn: uid=admin,ou=users,${LDAP_BASE_DN}
    objectClass: inetOrgPerson
    objectClass: posixAccount
    objectClass: shadowAccount
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

  03-organizations.ldif: |
    # Organization 1234567 (for test user)
    dn: cn=org-1234567,ou=groups,${LDAP_BASE_DN}
    objectClass: groupOfNames
    cn: org-1234567
    description: Organization 1234567
    member: uid=test,ou=users,${LDAP_BASE_DN}
    businessCategory: 1234567

    # Organization 7890123 (for admin user)
    dn: cn=org-7890123,ou=groups,${LDAP_BASE_DN}
    objectClass: groupOfNames
    cn: org-7890123
    description: Organization 7890123
    member: uid=admin,ou=users,${LDAP_BASE_DN}
    businessCategory: 7890123

  04-accounts.ldif: |
    # Account group for test user (different from org_id)
    dn: cn=account_9876543,ou=groups,${LDAP_BASE_DN}
    objectClass: groupOfNames
    cn: account_9876543
    description: Account 9876543
    member: uid=test,ou=users,${LDAP_BASE_DN}

    # Account group for admin user (same as org_id - fallback scenario)
    dn: cn=account_7890123,ou=groups,${LDAP_BASE_DN}
    objectClass: groupOfNames
    cn: account_7890123
    description: Account 7890123
    member: uid=admin,ou=users,${LDAP_BASE_DN}

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
  
  # Import each LDIF file
  for ldif in 01-base.ldif 02-users.ldif 03-organizations.ldif 04-accounts.ldif; do
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
  echo_info "Verifying organization groups..."
  oc exec -n "$NAMESPACE" "$pod_name" -- \
    ldapsearch -x -H ldap://localhost:1389 \
    -D "cn=admin,${LDAP_BASE_DN}" \
    -w "${LDAP_ADMIN_PASSWORD}" \
    -b "ou=groups,${LDAP_BASE_DN}" \
    "(cn=org-*)" dn businessCategory member
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
      ├── cn=org-1234567   (businessCategory: 1234567)
      ├── cn=org-7890123   (businessCategory: 7890123)
      ├── cn=account_9876543
      └── cn=account_7890123

Test Users:
─────────────────────────────────────────────────────────
  User: test
    Username: test
    Password: test
    Email:    cost@mgmt.net
    Full Name: cost mgmt test
    Groups:   org-1234567, account_9876543
    Expected Mapping:
      org_id: 1234567
      account_number: 9876543

  User: admin
    Username: admin
    Password: admin
    Email:    admin@mgmt.net
    Full Name: Admin User
    Groups:   org-7890123, account_7890123
    Expected Mapping:
      org_id: 7890123
      account_number: 7890123 (same as org_id)

Next Steps:
─────────────────────────────────────────────────────────
  1. Configure Keycloak LDAP Federation:
     ./configure-keycloak-ldap.sh

  2. Verify integration:
     - Login to OpenShift Console as "test" user
     - Check: oc get user test -o yaml
     - Expected groups: ["1234567", "account_9876543"]

  3. Test end-to-end flow:
     - Make API request with test user token
     - Verify X-Rh-Identity header contains:
       org_id: 1234567
       account_number: 9876543

Documentation:
─────────────────────────────────────────────────────────
  - ADR: docs/adr/0001-ldap-organization-id-mapping.md
  - Integration Guide: docs/authorino-ldap-integration.md

EOF
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
  display_summary
}

main "$@"

