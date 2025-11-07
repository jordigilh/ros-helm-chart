# Management Command Job - Troubleshooting Guide

**Purpose**: Run arbitrary Django management commands for operational tasks
**Source**: Koku ClowdApp `management-command-cji` job
**Status**: Not implemented in Helm chart (manual execution available)

---

## Overview

The Koku SaaS deployment includes a `ClowdJobInvocation` for running arbitrary Django management commands:

```yaml
jobs:
  - name: management-command-cji-${MGMT_IMAGE_TAG}-${MGMT_INVOCATION}
    podSpec:
      command:
        - /bin/bash
        - -c
        - python koku/manage.py ${COMMAND}
```

This is used for:
- One-off data fixes
- Manual data cleanup
- Operational maintenance tasks
- Debugging

---

## Why Not in Helm Chart?

**Decision**: Not implemented as a standard Helm resource

**Rationale**:
1. **Ad-hoc nature**: These jobs are triggered manually for specific operational needs
2. **Command flexibility**: The specific command varies based on the task
3. **Safety**: Prevents accidental execution during deployment
4. **kubectl exec availability**: Can be run manually when needed

---

## How to Run Management Commands

### Method 1: Using kubectl exec (Recommended)

Execute commands directly in a running Koku API pod:

```bash
# List available management commands
oc exec -it deployment/cost-mgmt-cost-management-onprem-koku-api-reads -- \
  python koku/manage.py help

# Run a specific command
oc exec -it deployment/cost-mgmt-cost-management-onprem-koku-api-reads -- \
  python koku/manage.py <command> [args]
```

**Examples**:

```bash
# Show database schema
oc exec -it deployment/cost-mgmt-cost-management-onprem-koku-api-reads -- \
  python koku/manage.py showmigrations

# Create a superuser
oc exec -it deployment/cost-mgmt-cost-management-onprem-koku-api-reads -- \
  python koku/manage.py createsuperuser

# Run shell
oc exec -it deployment/cost-mgmt-cost-management-onprem-koku-api-reads -- \
  python koku/manage.py shell

# Custom Koku commands (check koku/management/commands/)
oc exec -it deployment/cost-mgmt-cost-management-onprem-koku-api-reads -- \
  python koku/manage.py <custom_command>
```

---

### Method 2: Create a One-Off Job (For Long-Running Tasks)

For commands that take a long time or should run independently:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: koku-mgmt-command-$(date +%s)
  namespace: cost-mgmt
spec:
  backoffLimit: 2
  template:
    metadata:
      labels:
        app: koku-mgmt-command
    spec:
      restartPolicy: OnFailure
      containers:
      - name: mgmt-command
        image: quay.io/cloudservices/koku:latest
        command:
          - /bin/bash
          - -c
          - |
            cd $APP_HOME
            python koku/manage.py <YOUR_COMMAND_HERE>
        env:
        # Copy env vars from API deployment
        - name: DATABASE_SERVICE_NAME
          value: "database"
        - name: DATABASE_ENGINE
          value: "postgresql"
        # ... (all other required env vars)
```

**Deploy**:
```bash
# Save to file and apply
kubectl apply -f koku-mgmt-job.yaml

# Monitor
kubectl logs -f job/koku-mgmt-command-<timestamp>
```

---

### Method 3: Using debug Pod

Create a debug pod with shell access:

```bash
# Create debug pod
oc debug deployment/cost-mgmt-cost-management-onprem-koku-api-reads

# Inside the debug pod
cd $APP_HOME
python koku/manage.py <command>
```

---

## Common Management Commands

### Database Operations

```bash
# Show migration status
python koku/manage.py showmigrations

# Migrate database (normally done by pre-upgrade hook)
python koku/manage.py migrate --noinput

# Roll back migration
python koku/manage.py migrate <app_name> <migration_name>

# Create migrations (dev only)
python koku/manage.py makemigrations
```

### Data Operations

```bash
# Django shell (interactive Python)
python koku/manage.py shell

# Database shell (PostgreSQL)
python koku/manage.py dbshell

# Flush database (⚠️ DESTRUCTIVE)
python koku/manage.py flush --noinput
```

### User Management

```bash
# Create superuser
python koku/manage.py createsuperuser

# Change password
python koku/manage.py changepassword <username>
```

### Koku-Specific Commands

Check `../koku/koku/koku/management/commands/` for available custom commands:

```bash
# List custom commands
ls -la ../koku/koku/koku/management/commands/

# Run custom command
python koku/manage.py <custom_command>
```

---

## Environment Variables Required

When running management commands, ensure these environment variables are set:

```bash
# Database connection
DATABASE_SERVICE_NAME=database
DATABASE_ENGINE=postgresql
DATABASE_SERVICE_HOST=<koku-db-host>
DATABASE_SERVICE_PORT=5432
DATABASE_NAME=koku
DATABASE_USER=koku
DATABASE_PASSWORD=<password>

# Django settings
DJANGO_SECRET_KEY=<secret-key>
CLOWDER_ENABLED=False
DEVELOPMENT=False

# Optional (depending on command)
REDIS_HOST=redis
REDIS_PORT=6379
INSIGHTS_KAFKA_HOST=kafka
INSIGHTS_KAFKA_PORT=9092
```

**Get from running pod**:
```bash
oc exec deployment/cost-mgmt-cost-management-onprem-koku-api-reads -- env | sort
```

---

## Safety Checklist

Before running a management command:

- [ ] **Backup database** if command modifies data
- [ ] **Test in dev environment** first
- [ ] **Read command help**: `python koku/manage.py <command> --help`
- [ ] **Check for dry-run option**: Many commands have `--dry-run`
- [ ] **Verify namespace**: Ensure you're in the correct namespace
- [ ] **Monitor logs**: Watch output for errors

---

## Troubleshooting

### Command Not Found

**Error**: `Unknown command: <command>`

**Solution**:
1. Check available commands: `python koku/manage.py help`
2. Verify Koku version includes the command
3. Check spelling and capitalization

### Permission Denied

**Error**: `django.db.utils.ProgrammingError: permission denied`

**Solution**:
1. Check database user permissions
2. Some operations require superuser privileges
3. Run as appropriate database user

### Module Import Errors

**Error**: `ModuleNotFoundError: No module named 'koku'`

**Solution**:
1. Ensure you're in `$APP_HOME` directory: `cd $APP_HOME`
2. Check `PYTHONPATH`: `echo $PYTHONPATH`
3. Verify Koku image is correct

---

## When to Create a Helm Resource

Consider adding a management command job to the Helm chart if:

1. **Repeated execution**: Command needs to run regularly
2. **Deployment dependency**: Command must run during deployment
3. **Automation**: Part of an automated workflow
4. **Critical operation**: Essential for cluster health

**Example**: Database migration is now a Helm pre-upgrade hook because it's required before every deployment.

---

## Reference

### SaaS Implementation (ClowdApp)

```yaml
jobs:
  - name: management-command-cji-${MGMT_IMAGE_TAG}-${MGMT_INVOCATION}
    podSpec:
      command:
        - /bin/bash
        - -c
        - python koku/manage.py ${COMMAND}
      env:
        # ... (all Koku environment variables)
```

### Available Commands Location

- **Django built-in**: `django/core/management/commands/`
- **Koku custom**: `../koku/koku/koku/management/commands/`

### Documentation

- Django management commands: https://docs.djangoproject.com/en/stable/ref/django-admin/
- Koku source code: `../koku/` repository

---

## Summary

- ✅ **Not needed in Helm chart**: Manual execution via `kubectl exec` is sufficient
- ✅ **Available when needed**: All management commands work via running pods
- ✅ **Safe approach**: Prevents accidental execution
- ✅ **Documented**: This guide provides all necessary information

**For most cases**: Use `kubectl exec` on a running API pod
**For long-running tasks**: Create a one-off Job manifest
**For debugging**: Use `oc debug` to get a shell

