# Troubleshooting

## Common Issues

### No Resource Optimization Data Being Collected

**Problem**: Cost Management Metrics Operator is not collecting data from your namespace, no ROS files are being generated, or Kruize is not receiving metrics.

**Cause**: Missing required namespace label.

**Solution**:
```bash
# Check if the label exists
kubectl get namespace ros-ocp --show-labels | grep cost_management

# Apply the required label
kubectl label namespace ros-ocp cost_management_optimizations=true --overwrite

# Verify the label was applied
kubectl get namespace ros-ocp -o jsonpath='{.metadata.labels.cost_management_optimizations}'
# Should output: true
```

**Note**: The `scripts/install-helm-chart.sh` script automatically applies this label during deployment. If you deployed manually or the label was removed, you need to apply it manually.

**To remove the label (if testing):**
```bash
kubectl label namespace ros-ocp cost_management_optimizations-
```

**Legacy Label**: For backward compatibility, you can also use `insights_cost_management_optimizations=true` (the old label from koku-metrics-operator v4.0.x), but `cost_management_optimizations` is recommended for new deployments.

---

### Pods Getting OOMKilled (Out of Memory)

**Problem**: Pods crashing with OOMKilled status.
```bash
# Check pod status for OOMKilled
kubectl get pods -n ros-ocp

# If you see OOMKilled status, increase memory limits
# Create custom values file
cat > low-resource-values.yaml << EOF
resources:
  kruize:
    requests:
      memory: "512Mi"
      cpu: "250m"
    limits:
      memory: "1Gi"
      cpu: "500m"

  database:
    requests:
      memory: "128Mi"
      cpu: "100m"
    limits:
      memory: "256Mi"
      cpu: "250m"

  application:
    requests:
      memory: "128Mi"
      cpu: "100m"
    limits:
      memory: "256Mi"
      cpu: "200m"
EOF

# Upgrade with reduced resources
VALUES_FILE=low-resource-values.yaml ./install-helm-chart.sh
```

**Kruize listExperiments API error:**

The Kruize `/listExperiments` endpoint may show errors related to missing `KruizeLMExperimentEntry` entity. This is a known issue with the current Kruize image version, but experiments are still being created and processed correctly in the database.

```bash
# Workaround: Check experiments directly in database
kubectl exec -n ros-ocp ros-ocp-db-kruize-0 -- \
  psql -U postgres -d postgres -c "SELECT experiment_name, status FROM kruize_experiments;"
```

**Kafka connectivity issues (Connection refused errors):**

This is a common issue affecting multiple services (processor, recommendation-poller, housekeeper).

```bash
# Step 1: Check current Kafka status
kubectl get pods -n ros-ocp -l app.kubernetes.io/name=kafka
kubectl logs -n ros-ocp -l app.kubernetes.io/name=kafka --tail=20

# Step 2: Apply Kafka networking fix and restart
./install-helm-chart.sh
kubectl rollout restart statefulset/ros-ocp-kafka -n ros-ocp

# Step 3: Wait for Kafka to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=kafka -n ros-ocp --timeout=300s

# Step 4: Restart all dependent services
kubectl rollout restart deployment/ros-ocp-rosocp-processor -n ros-ocp
kubectl rollout restart deployment/ros-ocp-rosocp-recommendation-poller -n ros-ocp
kubectl rollout restart deployment/ros-ocp-rosocp-housekeeper -n ros-ocp
kubectl rollout restart deployment/ros-ocp-ingress -n ros-ocp

# Step 5: Verify connectivity
kubectl logs -n ros-ocp -l app.kubernetes.io/name=rosocp-processor --tail=10
kubectl exec -n ros-ocp deployment/ros-ocp-rosocp-processor -- nc -zv ros-ocp-kafka 29092
```

**Alternative: Complete redeployment if issues persist:**
```bash
# Delete and redeploy if Kafka issues persist
./install-helm-chart.sh cleanup --complete
./deploy-kind.sh
./install-helm-chart.sh
```

**Pods not starting:**
```bash
# Check pod status and events
kubectl get pods -n ros-ocp
kubectl describe pod -n ros-ocp <pod-name>

# Check logs
kubectl logs -n ros-ocp <pod-name>
```

**Services not accessible:**
```bash
# Check if services are created
kubectl get svc -n ros-ocp

# Test port forwarding as alternative
kubectl port-forward -n ros-ocp svc/ros-ocp-ingress 3000:3000
kubectl port-forward -n ros-ocp svc/ros-ocp-rosocp-api 8001:8000
```

**Storage issues:**
```bash
# Check persistent volume claims
kubectl get pvc -n ros-ocp

# Check storage class
kubectl get storageclass
```

### Debug Commands

```bash
# Get all resources in namespace
kubectl get all -n ros-ocp

# Check Helm release status
helm status ros-ocp -n ros-ocp

# View Helm values
helm get values ros-ocp -n ros-ocp

# Check cluster info
kubectl cluster-info
```