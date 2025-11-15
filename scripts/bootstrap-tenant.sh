#!/bin/bash
# Manual tenant bootstrap script
# Run this after Helm chart deployment to provision default tenant

set -e

NAMESPACE="${1:-cost-mgmt}"
ORG_ID="${2:-org1234567}"

echo "Bootstrapping tenant: $ORG_ID in namespace: $NAMESPACE"

# Get MASU pod
MASU_POD=$(kubectl get pods -n $NAMESPACE -l app.kubernetes.io/component=masu -o jsonpath='{.items[0].metadata.name}')

if [ -z "$MASU_POD" ]; then
  echo "ERROR: MASU pod not found"
  exit 1
fi

echo "Using MASU pod: $MASU_POD"

# Run tenant bootstrap
kubectl exec -n $NAMESPACE $MASU_POD -- python /opt/koku/koku/manage.py shell <<EOPYTH
from api.models import Customer, Tenant
from api.iam.models import Domain
from django.db import connection
from django.core.management import call_command
import uuid

ORG_ID = "$ORG_ID"
DOMAIN = f"{ORG_ID}.local"

print(f"Provisioning tenant {ORG_ID}")

# Step 1 - Create Tenant entry
tenant, tenant_created = Tenant.objects.get_or_create(schema_name=ORG_ID)
print(f"  Tenant created={tenant_created}")

# Step 2 - Create Domain entry
domain, domain_created = Domain.objects.get_or_create(domain=DOMAIN, defaults={"is_primary": True, "tenant": tenant})
print(f"  Domain created={domain_created}")

# Step 3 - Create schema
with connection.cursor() as cursor:
    cursor.execute(f"CREATE SCHEMA IF NOT EXISTS {ORG_ID}")
    cursor.execute(f"GRANT ALL ON SCHEMA {ORG_ID} TO {connection.settings_dict['USER']}")
print(f"  Schema ensured")

# Step 4 - Run migrations
print(f"  Running tenant migrations...")
call_command('migrate_schemas', schema_name=ORG_ID, verbosity=0)
print(f"  Migrations complete")

# Step 5 - Create Customer
customer, customer_created = Customer.objects.get_or_create(schema_name=ORG_ID, defaults={"uuid": str(uuid.uuid4())})
print(f"  Customer created={customer_created}")

print(f"Tenant '{ORG_ID}' provisioned successfully")
EOPYTH

echo ""
echo "✅ Tenant bootstrap complete!"
echo ""
echo "Next steps:"
echo "  1. Run E2E validator: ./e2e-validate.sh --namespace $NAMESPACE"
echo "  2. Or add providers via Sources API"

