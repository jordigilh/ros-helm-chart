# Check Component Logs

View logs for cost-onprem components to diagnose issues.

## Prerequisites

1. **Cluster access**: `oc whoami` returns your username
2. **Namespace**: Know which namespace the deployment is in

## Quick Log Commands

### Koku Listener (processes uploads)
```bash
kubectl logs -n ${NAMESPACE:-cost-onprem} -l app.kubernetes.io/component=listener --tail=100
```

### ROS Processor (sends to Kruize)
```bash
kubectl logs -n ${NAMESPACE:-cost-onprem} -l app.kubernetes.io/component=ros-processor --tail=100
```

### Kruize (generates recommendations)
```bash
kubectl logs -n ${NAMESPACE:-cost-onprem} -l app.kubernetes.io/component=ros-optimization --tail=100
```

### MASU (cost processor)
```bash
kubectl logs -n ${NAMESPACE:-cost-onprem} -l app.kubernetes.io/component=cost-processor --tail=100
```

### Celery Workers
```bash
kubectl logs -n ${NAMESPACE:-cost-onprem} -l app.kubernetes.io/component=cost-worker --tail=100
```

### Ingress
```bash
kubectl logs -n ${NAMESPACE:-cost-onprem} -l app.kubernetes.io/component=ingress --tail=100
```

### Database
```bash
kubectl logs -n ${NAMESPACE:-cost-onprem} -l app.kubernetes.io/component=database --tail=100
```

### Sources API
```bash
kubectl logs -n ${NAMESPACE:-cost-onprem} -l app.kubernetes.io/component=sources-api --tail=100
```

## Follow Logs (Live)

Add `-f` to follow logs in real-time:
```bash
kubectl logs -n ${NAMESPACE:-cost-onprem} -l app.kubernetes.io/component=listener -f
```

## Search for Errors

```bash
# All errors in listener
kubectl logs -n ${NAMESPACE:-cost-onprem} -l app.kubernetes.io/component=listener | grep -i error

# TLS/certificate issues in ROS processor
kubectl logs -n ${NAMESPACE:-cost-onprem} -l app.kubernetes.io/component=ros-processor | grep -i "x509\|certificate\|tls"

# S3 signature issues
kubectl logs -n ${NAMESPACE:-cost-onprem} -l app.kubernetes.io/component=ros-processor | grep -i "signature\|s3\|bucket"
```

## All Pods Status

```bash
kubectl get pods -n ${NAMESPACE:-cost-onprem} -l app.kubernetes.io/instance=cost-onprem
```

## Recent Events

```bash
kubectl get events -n ${NAMESPACE:-cost-onprem} --sort-by='.lastTimestamp' | tail -20
```
