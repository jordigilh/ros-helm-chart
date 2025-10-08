# Authorino Operator Prerequisites

## Overview

The ROS Helm chart with JWT authentication requires the **Authorino Operator** to be installed before deployment. This operator manages Authorino instances that provide JWT validation for the ROS ingress.

> **Why separate from Helm?** Helm has timing issues when creating both Operator subscriptions and Custom Resources in the same deployment. The operator needs time to install and register its CRDs before Authorino instances can be created.

## Installation Methods

### Method 1: OpenShift Console (Recommended)

1. **Access OperatorHub**:
   - Go to **Operators** → **OperatorHub**
   - Search for "Authorino"

2. **Install Authorino Operator**:
   - Click on **"Authorino Operator"** by Red Hat
   - Click **"Install"**
   - Keep default settings:
     - **Installation Mode**: All namespaces
     - **Installed Namespace**: openshift-operators
     - **Update Channel**: stable
     - **Approval Strategy**: Automatic

3. **Verify Installation**:
   - Go to **Operators** → **Installed Operators**
   - Confirm "Authorino Operator" shows "Succeeded" status

### Method 2: CLI Installation

Create and apply the following Subscription:

\`\`\`yaml
# authorino-operator-subscription.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: authorino-operator
  namespace: openshift-operators
spec:
  channel: stable
  name: authorino-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
\`\`\`

Apply with:
\`\`\`bash
oc apply -f authorino-operator-subscription.yaml
\`\`\`

### Method 3: Ansible/Automation

For automated deployments, use this Ansible task:

\`\`\`yaml
- name: Install Authorino Operator
  kubernetes.core.k8s:
    definition:
      apiVersion: operators.coreos.com/v1alpha1
      kind: Subscription
      metadata:
        name: authorino-operator
        namespace: openshift-operators
      spec:
        channel: stable
        name: authorino-operator
        source: redhat-operators
        sourceNamespace: openshift-marketplace
        installPlanApproval: Automatic
\`\`\`

## Verification

### Check Operator Status

\`\`\`bash
# Check if operator is installed
oc get subscription authorino-operator -n openshift-operators

# Check operator pods
oc get pods -n openshift-operators | grep authorino

# Verify CRDs are created
oc get crd | grep authorino
\`\`\`

Expected output:
\`\`\`
NAME                                        CREATED AT
authorinos.operator.authorino.kuadrant.io   2024-01-01T12:00:00Z
authconfigs.authorino.kuadrant.io           2024-01-01T12:00:00Z
\`\`\`

### Test Authorino Instance Creation

Create a test Authorino instance:

\`\`\`yaml
# test-authorino.yaml
apiVersion: operator.authorino.kuadrant.io/v1beta1
kind: Authorino
metadata:
  name: test-authorino
  namespace: default
spec:
  image: registry.redhat.io/rhosak/authorino-rhel8:1.0.0
  listener:
    tls:
      enabled: false
  log:
    level: info
\`\`\`

\`\`\`bash
# Apply test instance
oc apply -f test-authorino.yaml

# Check if it creates resources
oc get authorino test-authorino -o yaml

# Clean up test
oc delete -f test-authorino.yaml
\`\`\`

## Troubleshooting

### Common Issues

1. **"no matches for kind Authorino"**
   - The operator is not installed or CRDs are not ready
   - Wait a few minutes and try again
   - Check operator logs: `oc logs -n openshift-operators deployment/authorino-operator`

2. **Operator pod not starting**
   - Check events: `oc get events -n openshift-operators`
   - Verify cluster has sufficient resources
   - Check operator subscription status

3. **InstallPlan stuck**
   - If using Manual approval, approve the InstallPlan:
   - `oc get installplan -n openshift-operators`
   - `oc patch installplan <name> -n openshift-operators --type merge --patch '{"spec":{"approved":true}}'`

### Support Information

- **Operator**: Authorino Operator by Red Hat
- **Channel**: stable
- **Source**: redhat-operators
- **Documentation**: [Authorino Documentation](https://docs.kuadrant.io/authorino/)
- **Support**: Red Hat Customer Support (for enterprise customers)

## Next Steps

Once the Authorino Operator is installed:

1. **Deploy ROS with JWT Auth**:
   \`\`\`bash
   helm install ros-ocp . --set jwt_auth.enabled=true
   \`\`\`

2. **The Helm chart will**:
   - Create an Authorino instance using the operator
   - Configure JWT validation for Keycloak
   - Set up Envoy proxy for external authorization
   - Create all necessary AuthConfig resources

3. **No additional manual steps required** - the operator handles everything else!
