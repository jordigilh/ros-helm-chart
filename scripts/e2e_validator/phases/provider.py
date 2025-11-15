"""
Phase 3: Provider Setup
========================

Create or verify cost provider configuration using Sources API (preferred)
or direct database access (fallback for testing).
"""

from typing import Dict, Optional
import uuid


class ProviderPhase:
    """Phase 3: Provider setup"""

    def __init__(self, db_client, org_id: str = "org1234567",
                 k8s_client=None, sources_api_client=None):
        """Initialize provider phase

        Args:
            db_client: DatabaseClient instance
            org_id: Organization ID
            k8s_client: KubernetesClient for executing Django ORM operations
            sources_api_client: SourcesAPIClient for proper Day 2 operations
        """
        self.db = db_client
        self.org_id = org_id
        self.k8s = k8s_client
        self.sources_api = sources_api_client

    def get_existing_provider(self) -> Optional[Dict]:
        """Check for existing provider"""
        return self.db.get_provider()

    def create_provider_via_django_orm(self,
                                       name: str = "AWS Test Provider E2E",
                                       bucket: str = "cost-data",
                                       report_name: str = "test-report") -> str:
        """Create provider using Django ORM AND provision tenant

        This does TWO things:
        1. Provisions tenant (schema + migrations + tables)
        2. Creates provider (customer + provider + auth + billing source)

        Args:
            name: Provider name
            bucket: S3 bucket name
            report_name: Report name

        Returns:
            Provider UUID
        """
        if not self.k8s:
            raise ValueError("KubernetesClient required for Django ORM operations")

        masu_pod = self.k8s.get_pod_by_component('masu')
        if not masu_pod:
            raise RuntimeError("MASU pod not found")

        # Python code to run in MASU pod - provisions tenant AND creates provider
        django_code = f'''
import os, sys, django
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "koku.settings")
sys.path.append("/opt/koku/koku")
django.setup()
from api.models import Customer, Provider
from api.provider.models import ProviderAuthentication, ProviderBillingSource
from django.db import connection
from django.core.management import call_command
import uuid

org_id = "{self.org_id}"

try:
    # STEP 1: Provision tenant schema
    print(f"TENANT_PROVISIONING_START")

    # Create PostgreSQL schema
    with connection.cursor() as cursor:
        cursor.execute(f"CREATE SCHEMA IF NOT EXISTS {{org_id}}")
        cursor.execute(f"GRANT ALL ON SCHEMA {{org_id}} TO {{connection.settings_dict['USER']}}")
    print(f"TENANT_SCHEMA_CREATED")

    # Run tenant migrations (creates 217 reporting tables)
    call_command('migrate_schemas', schema_name=org_id, verbosity=0)
    print(f"TENANT_MIGRATIONS_COMPLETE")

    # STEP 2: Create provider
    customer, _ = Customer.objects.get_or_create(
        schema_name=org_id,
        defaults={{"uuid": str(uuid.uuid4()), "org_id": org_id}}
    )
    provider, created = Provider.objects.get_or_create(
        name="{name}",
        defaults={{
            "uuid": str(uuid.uuid4()),
            "type": Provider.PROVIDER_AWS,
            "setup_complete": False,
            "active": True,
            "paused": False,
            "customer": customer
        }}
    )

    if created:
        # Create authentication with UUID
        auth, _ = ProviderAuthentication.objects.get_or_create(
            uuid=str(uuid.uuid4()),
            defaults={{"credentials": {{}}}}
        )

        # Create billing source with UUID
        billing, _ = ProviderBillingSource.objects.get_or_create(
            uuid=str(uuid.uuid4()),
            defaults={{
                "data_source": {{
                    "bucket": "{bucket}",
                    "report_name": "{report_name}",
                    "report_prefix": ""
                }}
            }}
        )

        # Link to provider
        provider.authentication = auth
        provider.billing_source = billing
        provider.setup_complete = True
        provider.save()

    print(f"PROVIDER_UUID={{provider.uuid}}")
    print(f"PROVIDER_NAME={{provider.name}}")
except Exception as e:
    import traceback
    print(f"ERROR={{e}}")
    print(f"TRACEBACK={{traceback.format_exc()}}")
'''

        # Execute in MASU pod
        output = self.k8s.python_exec(masu_pod, django_code)

        # Parse output
        provider_uuid = None
        error_msg = None
        traceback_msg = None

        for line in output.split('\n'):
            if line.startswith('PROVIDER_UUID='):
                provider_uuid = line.split('=', 1)[1].strip()
            elif line.startswith('ERROR='):
                error_msg = line.split('=', 1)[1].strip()
            elif line.startswith('TRACEBACK='):
                traceback_msg = line.split('=', 1)[1].strip()

        if error_msg:
            error_detail = f"{error_msg}"
            if traceback_msg:
                error_detail += f"\n{traceback_msg}"
            raise RuntimeError(f"Provider creation failed: {error_detail}")

        if not provider_uuid:
            raise RuntimeError(f"Failed to parse provider UUID from output: {output}")

        return provider_uuid

    def create_provider_via_sources_api(self,
                                        name: str = "AWS Test Provider E2E",
                                        bucket: str = "cost-data",
                                        report_name: str = "test-report",
                                        report_prefix: str = "") -> str:
        """Create provider via Sources API (Red Hat recommended method)

        This is the proper Day 2 operations approach that:
        1. Creates a source in Sources API
        2. Creates authentication
        3. Links to Cost Management application with S3 config

        Args:
            name: Provider name
            bucket: S3 bucket name
            report_name: Cost and Usage Report name
            report_prefix: Report prefix in bucket

        Returns:
            Source ID (used as provider UUID in Koku)
        """
        if not self.sources_api:
            raise ValueError("SourcesAPIClient required for Sources API operations")

        result = self.sources_api.create_aws_source_full(
            name=name,
            bucket=bucket,
            report_name=report_name,
            report_prefix=report_prefix
        )

        return result['source_id']

    def create_provider(self,
                       name: str = "AWS Test Provider E2E",
                       bucket: str = "cost-data",
                       report_name: str = "test-report") -> str:
        """Create provider using best available method

        Priority:
        1. Sources API (preferred, Red Hat recommended)
        2. Django ORM (requires k8s_client, properly provisions tenant)
        3. Direct SQL (fallback, may not provision tenant properly)

        Args:
            name: Provider name
            bucket: S3 bucket name
            report_name: Report name

        Returns:
            Provider UUID
        """
        # Prefer Sources API if available
        if self.sources_api:
            return self.create_provider_via_sources_api(name, bucket, report_name)

        # Use Django ORM approach if k8s client available
        if self.k8s:
            return self.create_provider_via_django_orm(name, bucket, report_name)

        # Fallback to direct SQL (won't provision tenant properly!)
        return self.db.create_provider(
            name=name,
            org_id=self.org_id,
            bucket=bucket,
            report_name=report_name
        )

    def run(self, skip: bool = False) -> Dict:
        """Run provider setup phase

        Args:
            skip: Skip provider creation if True

        Returns:
            Results dict
        """
        print("\n" + "="*70)
        print("Phase 3: Provider Setup")
        print("="*70 + "\n")

        if skip:
            print("⏭️  Skipped (--skip-provider)")
            existing = self.get_existing_provider()
            if existing:
                print(f"  ℹ️  Existing provider: {existing['name']}")
                print(f"  ℹ️  UUID: {existing['uuid']}")
                return {
                    'passed': True,
                    'skipped': True,
                    'provider_uuid': existing['uuid'],
                    'provider_name': existing['name']
                }
            else:
                print("  ⚠️  No existing provider found")
                return {
                    'passed': False,
                    'skipped': True,
                    'error': 'No provider found and creation skipped'
                }

        # Check for existing provider
        print("🔍 Checking for existing provider...")
        existing = self.get_existing_provider()

        if existing:
            print(f"  ✅ Provider exists: {existing['name']}")
            print(f"  ℹ️  UUID: {existing['uuid']}")
            print(f"  ℹ️  Active: {existing['active']}")

            # Check if billing source is configured
            has_billing_source = self.db.execute_query("""
                SELECT bs.id, bs.data_source
                FROM api_provider p
                LEFT JOIN api_providerbillingsource bs ON p.billing_source_id = bs.id
                WHERE p.uuid = %s
            """, (existing['uuid'],))

            if has_billing_source and has_billing_source[0] and has_billing_source[0][0] is not None:
                # Check if authentication is also configured
                has_authentication = self.db.execute_query("""
                    SELECT pa.id, pa.credentials
                    FROM api_provider p
                    LEFT JOIN api_providerauthentication pa ON p.authentication_id = pa.id
                    WHERE p.uuid = %s
                """, (existing['uuid'],))

                if has_authentication and has_authentication[0] and has_authentication[0][0] is not None:
                    print(f"  ✅ Billing source configured")
                    print(f"  ✅ Authentication configured")
                    return {
                        'passed': True,
                        'created': False,
                        'provider_uuid': existing['uuid'],
                        'provider_name': existing['name']
                    }
                else:
                    print(f"  ✅ Billing source configured")
                    print(f"  ⚠️  Authentication missing, creating...")
                    # Create authentication for existing provider
                    try:
                        import uuid as uuid_lib
                        auth_uuid = str(uuid_lib.uuid4())

                        # Step 1: Insert authentication
                        self.db.execute_query("""
                            INSERT INTO api_providerauthentication (uuid, credentials)
                            VALUES (%s::uuid, %s::jsonb)
                            RETURNING uuid
                        """, (
                            auth_uuid,
                            '{}'
                        ))

                        # Step 2: Get the internal ID of the authentication
                        authentication = self.db.execute_query("""
                            SELECT id FROM api_providerauthentication WHERE uuid = %s
                        """, (auth_uuid,))

                        if not authentication or not authentication[0]:
                            raise Exception("Failed to retrieve authentication ID")

                        authentication_id = authentication[0][0]

                        # Step 3: Update provider to link authentication
                        self.db.execute_query("""
                            UPDATE api_provider
                            SET authentication_id = %s
                            WHERE uuid = %s
                            RETURNING uuid
                        """, (authentication_id, existing['uuid']))

                        print(f"  ✅ Authentication created and linked")
                        return {
                            'passed': True,
                            'created': False,
                            'authentication_created': True,
                            'provider_uuid': existing['uuid'],
                            'provider_name': existing['name']
                        }
                    except Exception as e:
                        print(f"  ❌ Failed to create authentication: {e}")
                        return {
                            'passed': False,
                            'error': f'Authentication creation failed: {e}'
                        }
            else:
                print(f"  ⚠️  Billing source missing, creating...")
                # Create billing source for existing provider
                try:
                    import uuid as uuid_lib
                    billing_source_uuid = str(uuid_lib.uuid4())

                    # Step 1: Insert billing source
                    self.db.execute_query("""
                        INSERT INTO api_providerbillingsource (uuid, data_source)
                        VALUES (%s::uuid, %s::jsonb)
                        RETURNING uuid
                    """, (
                        billing_source_uuid,
                        '{"bucket": "cost-data", "report_name": "test-report", "report_prefix": ""}'
                    ))

                    # Step 2: Get the internal ID of the billing source
                    billing_source = self.db.execute_query("""
                        SELECT id FROM api_providerbillingsource WHERE uuid = %s
                    """, (billing_source_uuid,))

                    if not billing_source or not billing_source[0]:
                        raise Exception("Failed to retrieve billing source ID")

                    billing_source_id = billing_source[0][0]

                    # Step 3: Update provider to link billing source
                    self.db.execute_query("""
                        UPDATE api_provider
                        SET billing_source_id = %s
                        WHERE uuid = %s
                        RETURNING uuid
                    """, (billing_source_id, existing['uuid']))

                    print(f"  ✅ Billing source created and linked")

                    # Now check and create authentication if missing
                    has_authentication = self.db.execute_query("""
                        SELECT pa.id, pa.credentials
                        FROM api_provider p
                        LEFT JOIN api_providerauthentication pa ON p.authentication_id = pa.id
                        WHERE p.uuid = %s
                    """, (existing['uuid'],))

                    if not has_authentication or not has_authentication[0] or has_authentication[0][0] is None:
                        print(f"  ⚠️  Authentication missing, creating...")
                        # Create authentication for existing provider
                        try:
                            import uuid as uuid_lib
                            auth_uuid = str(uuid_lib.uuid4())

                            # Step 1: Insert authentication
                            self.db.execute_query("""
                                INSERT INTO api_providerauthentication (uuid, credentials)
                                VALUES (%s::uuid, %s::jsonb)
                                RETURNING uuid
                            """, (
                                auth_uuid,
                                '{}'
                            ))

                            # Step 2: Get the internal ID of the authentication
                            authentication = self.db.execute_query("""
                                SELECT id FROM api_providerauthentication WHERE uuid = %s
                            """, (auth_uuid,))

                            if not authentication or not authentication[0]:
                                raise Exception("Failed to retrieve authentication ID")

                            authentication_id = authentication[0][0]

                            # Step 3: Update provider to link authentication
                            self.db.execute_query("""
                                UPDATE api_provider
                                SET authentication_id = %s
                                WHERE uuid = %s
                                RETURNING uuid
                            """, (authentication_id, existing['uuid']))

                            print(f"  ✅ Authentication created and linked")
                        except Exception as e:
                            print(f"  ❌ Failed to create authentication: {e}")
                            return {
                                'passed': False,
                                'error': f'Authentication creation failed: {e}'
                            }

                    return {
                        'passed': True,
                        'created': False,
                        'billing_source_created': True,
                        'provider_uuid': existing['uuid'],
                        'provider_name': existing['name']
                    }
                except Exception as e:
                    print(f"  ❌ Failed to create billing source: {e}")
                    return {
                        'passed': False,
                        'error': f'Billing source creation failed: {e}'
                    }

        # Create new provider
        print("\n📝 Creating new provider...")
        try:
            provider_uuid = self.create_provider()
            print(f"  ✅ Provider created")
            print(f"  ℹ️  UUID: {provider_uuid}")

            return {
                'passed': True,
                'created': True,
                'provider_uuid': provider_uuid,
                'provider_name': 'AWS Test Provider E2E'
            }
        except Exception as e:
            print(f"  ❌ Provider creation failed: {e}")
            return {
                'passed': False,
                'error': str(e)
            }

