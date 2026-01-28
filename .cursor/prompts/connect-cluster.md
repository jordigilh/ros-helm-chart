# Connect to OpenShift Cluster

Set up cluster access for running tests and troubleshooting.

## Required Information

To connect to a cluster, you need:
1. **Cluster API URL**: e.g., `api.ocp-edge94.qe.lab.redhat.com:6443`
2. **Username**: e.g., `kubeadmin`
3. **Password**: The cluster admin password

## Login Command

```bash
oc login -s <CLUSTER_API_URL> -u <USERNAME> --password <PASSWORD>
```

Example:
```bash
oc login -s api.ocp-edge94.qe.lab.redhat.com:6443 -u kubeadmin --password gVFn9-cNwkg-AqWNR-knHGp
```

## Verify Connection

```bash
# Check logged in user
oc whoami

# Check cluster info
oc cluster-info

# List namespaces
oc get namespaces | grep -E "cost-onprem|keycloak"
```

## Environment Setup

After logging in, set these environment variables:

```bash
export NAMESPACE="cost-onprem"           # Or your deployment namespace
export KEYCLOAK_NAMESPACE="keycloak"     # Keycloak namespace
export HELM_RELEASE_NAME="cost-onprem"   # Helm release name
```

## Check Deployment Status

```bash
# All pods in namespace
kubectl get pods -n ${NAMESPACE}

# Helm release status
helm list -n ${NAMESPACE}

# Routes (for ingress URL)
oc get routes -n ${NAMESPACE}
```

## Common Issues

### "error: You must be logged in to the server"
Re-run the `oc login` command with valid credentials.

### "Unable to connect to the server"
- Check VPN connection if required
- Verify the cluster API URL is correct
- Ensure the cluster is running

### "Unauthorized" or "Forbidden"
- Password may have expired
- User may not have required permissions
- Try logging in again with fresh credentials
