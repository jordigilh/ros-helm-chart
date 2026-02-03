"""
E2E Validator CLI
=================

Main command-line interface for E2E validation.
"""

import click
import time
import os
import sys
from datetime import datetime, timedelta

# Suppress urllib3 SSL warnings (expected in local/test environments with self-signed certs)
import urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

from .clients.kubernetes import KubernetesClient
from .clients.kubectl_database import KubectlDatabaseClient
from .clients.nise import NiseClient
from .clients.kafka_producer import KafkaProducerClient
from .clients.sources_api import SourcesAPIClient
from .phases.preflight import PreflightPhase
from .phases.provider import ProviderPhase
from .phases.data_upload import DataUploadPhase
from .phases.processing import ProcessingPhase
from .phases.smoke_validation import SmokeValidationPhase
from .phases.deployment_validation import DeploymentValidationPhase
from .phases.kafka_validation import KafkaValidationPhase
from .logging import log_debug, log_info, log_success, log_warning, log_error


def fetch_org_id_from_keycloak(keycloak_namespace: str = "keycloak", username: str = "test") -> str:
    """Fetch org_id from Keycloak test user attributes.

    This ensures test data uses the same org_id as the UI user for proper multi-tenancy.

    Args:
        keycloak_namespace: Kubernetes namespace where Keycloak is deployed
        username: Test username to look up

    Returns:
        org_id from Keycloak user attributes, or None if not found
    """
    import subprocess
    import base64
    import json
    import requests

    try:
        # Step 1: Get Keycloak admin credentials from secret
        result = subprocess.run(
            ["kubectl", "get", "secret", "-n", keycloak_namespace, "keycloak-initial-admin",
             "-o", "jsonpath={.data.password}"],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode != 0:
            log_warning(f"  ⚠️  Could not get Keycloak admin credentials: {result.stderr}")
            return None

        admin_password = base64.b64decode(result.stdout.strip()).decode('utf-8')

        # Step 2: Get Keycloak route
        result = subprocess.run(
            ["kubectl", "get", "route", "-n", keycloak_namespace, "keycloak",
             "-o", "jsonpath={.spec.host}"],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode != 0:
            log_warning(f"  ⚠️  Could not get Keycloak route: {result.stderr}")
            return None

        keycloak_host = result.stdout.strip()
        keycloak_url = f"https://{keycloak_host}"

        # Step 3: Get admin token from master realm
        token_url = f"{keycloak_url}/realms/master/protocol/openid-connect/token"
        token_response = requests.post(
            token_url,
            data={
                "client_id": "admin-cli",
                "grant_type": "password",
                "username": "admin",
                "password": admin_password
            },
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            verify=False,
            timeout=30
        )

        if token_response.status_code != 200:
            log_warning(f"  ⚠️  Could not get admin token: {token_response.status_code}")
            return None

        admin_token = token_response.json().get("access_token")

        # Step 4: Get test user attributes from kubernetes realm
        users_url = f"{keycloak_url}/admin/realms/kubernetes/users"
        users_response = requests.get(
            users_url,
            params={"username": username, "exact": "true"},
            headers={
                "Authorization": f"Bearer {admin_token}",
                "Content-Type": "application/json"
            },
            verify=False,
            timeout=30
        )

        if users_response.status_code != 200:
            log_warning(f"  ⚠️  Could not get users: {users_response.status_code}")
            return None

        users = users_response.json()
        if not users:
            log_warning(f"  ⚠️  User '{username}' not found in Keycloak")
            return None

        # Extract org_id from user attributes
        user = users[0]
        org_id = user.get("attributes", {}).get("org_id", [None])[0]

        if org_id:
            log_success(f"  ✓ Fetched org_id from Keycloak user '{username}': {org_id}")
            return org_id
        else:
            log_warning(f"  ⚠️  User '{username}' has no org_id attribute")
            return None

    except subprocess.TimeoutExpired:
        log_warning("  ⚠️  Timeout fetching org_id from Keycloak")
        return None
    except Exception as e:
        log_warning(f"  ⚠️  Error fetching org_id from Keycloak: {e}")
        return None


def discover_sources_api_info(namespace: str) -> tuple:
    """Auto-discover Sources API service info.

    With the centralized gateway architecture, Sources API is accessed
    internally via the Kubernetes service, not via an external route.

    Args:
        namespace: Kubernetes namespace

    Returns:
        Tuple of (route_url, service_ip, route_hostname) or (None, None, None)
        Note: route_url and route_hostname may be None if no external route exists
    """
    try:
        from kubernetes import client

        # Get service ClusterIP - this is what we actually use for internal access
        v1 = client.CoreV1Api()
        service = v1.read_namespaced_service(
            name="cost-onprem-sources-api",
            namespace=namespace
        )
        service_ip = service.spec.cluster_ip

        log_success(f"  ✓ Auto-discovered Sources API:")
        log_info(f"    Service IP: {service_ip}")
        log_info(f"    Internal URL: http://cost-onprem-sources-api:8000")

        # Route is optional - with centralized gateway, external access goes through gateway
        route_url = None
        route_host = None
        try:
            custom_api = client.CustomObjectsApi()
            route = custom_api.get_namespaced_custom_object(
                group="route.openshift.io",
                version="v1",
                namespace=namespace,
                plural="routes",
                name="sources-api"
            )
            route_host = route['spec']['host']
            tls = route['spec'].get('tls')
            scheme = 'https' if tls else 'http'
            route_url = f"{scheme}://{route_host}"
            log_info(f"    External Route: {route_url}")
        except Exception:
            # No external route - this is expected with centralized gateway
            log_info(f"    External Route: N/A (uses centralized gateway)")

        return (route_url, service_ip, route_host)
    except Exception as e:
        log_info(f"  ℹ️  Sources API service not found: {e}")
        return (None, None, None)


@click.command(context_settings={"help_option_names": ["-h", "--help"]})
@click.option('--namespace', default='cost-onprem', help='Kubernetes namespace')
@click.option('--org-id', default=None, help='Organization ID (auto-fetched from Keycloak if not provided)')
@click.option('--keycloak-namespace', default='keycloak', help='Keycloak namespace for auto-fetching org_id')
@click.option('--provider-type', type=click.Choice(['aws', 'azure', 'gcp', 'ocp'], case_sensitive=False), default='aws', help='Cloud provider type to test')
@click.option('--skip-migrations', is_flag=True, help='Skip database migrations')
@click.option('--skip-provider', is_flag=True, help='Skip provider setup')
@click.option('--infrastructure-only', is_flag=True, help='Infrastructure testing only (skip data upload/processing/validation) - WARNING: incomplete E2E test')
@click.option('--skip-tests', is_flag=True, help='Skip IQE tests (only allowed in smoke-test mode)')
@click.option('--diagnose', is_flag=True, help='Run infrastructure diagnostics (auto-runs on failure)')
@click.option('--quick', is_flag=True, help='Quick mode (skip all setup)')
@click.option('--smoke-test', is_flag=True, help='Smoke test mode: fast validation with minimal data')
@click.option('--force', is_flag=True, help='Force data regeneration even if data exists')
@click.option('--timeout', default=300, help='Processing timeout (seconds)')
@click.option('--scenarios', default='all', help='Comma-separated scenario list or "all"')
@click.pass_context
def main(ctx, namespace, org_id, keycloak_namespace, provider_type, skip_migrations, skip_provider, infrastructure_only,
         skip_tests, diagnose, quick, smoke_test, force, timeout, scenarios):
    """
    E2E Validation Suite for Cost Management

    Database-agnostic testing with standalone validation
    """

    # Track exit code
    exit_code = 0

    # Auto-fetch org_id from Keycloak if not provided
    if org_id is None:
        log_info("\n🔑 Auto-fetching org_id from Keycloak...")
        org_id = fetch_org_id_from_keycloak(keycloak_namespace=keycloak_namespace)
        if org_id is None:
            log_warning("  ⚠️  Could not auto-fetch org_id, using default 'org1234567'")
            org_id = 'org1234567'

    # Generate unique cluster ID for this test run to ensure data isolation
    # This prevents conflicts from previous test runs and mimics production behavior
    import time
    cluster_id = f"test-cluster-{int(time.time())}"
    log_success(f"  ✓ Generated unique cluster ID: {cluster_id}")

    # Quick mode skips slow operations but RUNS critical setup and data upload
    if quick:
        skip_migrations = True
        # NOTE: We don't skip provider because billing source must be configured
        # for MASU to process data. Provider setup is fast (~2 seconds).

    # Smoke test optimizations: skip expensive operations but KEEP validation
    if smoke_test:
        timeout = 180  # Use 180s for smoke test (processing + summarization)
        log_info("\n🚀 Smoke test mode enabled:")
        log_info("   - Running standalone validation (YAML-driven)")
        log_info("   - Processing timeout: 180s")
        log_info("   - Minimal data (1 pod, 1 node, 1 cluster)")
        log_info("   - Estimated completion: ~90 seconds")
        log_info("")

    # Infrastructure-only mode warning
    if infrastructure_only:
        log_warning("\n⚠️  WARNING: Infrastructure-only mode enabled")
        log_info("   - Data upload, processing, and validation will be SKIPPED")
        log_info("   - This is NOT a complete E2E test")
        log_info("   - Use only for quick infrastructure checks (preflight, Kafka, Sources API)")
        log_info("")

    # Normalize provider type to uppercase for internal use
    provider_type = provider_type.upper()

    # Parse scenarios
    if scenarios == 'all':
        scenario_list = list(NiseClient.SCENARIOS.keys())
    else:
        scenario_list = [s.strip() for s in scenarios.split(',')]

    # Print header
    log_info("\n" + "="*70)
    log_info("  Cost Management E2E Validation Suite")
    log_info("  Database-Agnostic Testing (Nise + IQE)")
    log_info("="*70)
    log_info(f"\nConfiguration:")
    log_info(f"  Namespace:  {namespace}")
    log_info(f"  Org ID:     {org_id}")
    log_info(f"  Provider:   {provider_type}")
    log_info(f"  Mode:       {'SMOKE TEST (fast 4-row CSV)' if smoke_test else 'FULL VALIDATION (nise)'}")
    log_info(f"  Scenarios:  {len(scenario_list)}")
    log_info(f"  Timeout:    {timeout}s")
    log_info()

    start_time = time.time()
    results = {}

    try:
        # Initialize clients
        log_info("🔧 Initializing clients...")
        k8s = KubernetesClient(namespace=namespace)
        log_success("  ✓ Kubernetes client")

        # Dynamically discover PostgreSQL pod by label
        log_info("  🔍 Discovering PostgreSQL pod...")
        postgres_pod = k8s.discover_postgresql_pod()
        if not postgres_pod:
            log_error("  ❌ Failed to discover PostgreSQL pod with label app.kubernetes.io/component=database")
            ctx.exit(1)

        log_success(f"  ✓ Discovered PostgreSQL pod: {postgres_pod}")

        # Dynamically discover database secret from postgres pod
        log_info("  🔍 Discovering database secret...")
        db_secret_info = k8s.discover_database_secret(pod_name=postgres_pod)
        if not db_secret_info:
            log_error(f"  ❌ Failed to discover database secret from {postgres_pod} pod")
            ctx.exit(1)

        log_success(f"  ✓ Discovered secret: {db_secret_info['secret_name']}")

        # Get DB credentials from discovered secret
        # Try multiple key names for compatibility with different chart versions
        password_keys = ['koku-password', 'admin-password', 'ros-password']
        db_password = None
        for key in password_keys:
            db_password = k8s.get_secret(db_secret_info['secret_name'], key)
            if db_password:
                log_success(f"  ✓ Using password from key: {key}")
                break
        if not db_password:
            log_error(f"  ❌ Failed to get password from secret {db_secret_info['secret_name']} (tried: {', '.join(password_keys)})")
            ctx.exit(1)

        # Get database user from secret
        user_keys = ['koku-user', 'admin-user', 'ros-user']
        db_user = None
        for key in user_keys:
            db_user = k8s.get_secret(db_secret_info['secret_name'], key)
            if db_user:
                log_success(f"  ✓ Using username from key: {key}")
                break
        if not db_user:
            log_error(f"  ❌ Failed to get username from secret {db_secret_info['secret_name']} (tried: {', '.join(user_keys)})")
            ctx.exit(1)

        # Use kubectl exec for database queries - no port-forward needed!
        # This is more resilient to network issues than direct TCP connections
        db = KubectlDatabaseClient(
            k8s=k8s,
            pod_name=postgres_pod,
            database='costonprem_koku',
            user=db_user
        )
        log_success("  ✓ Database client (kubectl exec - no port-forward needed)")

        nise = NiseClient()
        log_success("  ✓ Nise client")

        # Initialize Sources API client (production flow)
        log_info("\n📡 Discovering Sources API...")
        route_url, service_ip, route_hostname = discover_sources_api_info(namespace)
        sources_api = None

        if service_ip:
            try:
                # Use internal service URL (curl will be executed from within the cluster)
                service_url = f"http://cost-onprem-sources-api:8000"
                log_info(f"    Using internal service: {service_url}")
                log_info(f"    Requests will be executed from within the cluster")

                sources_api = SourcesAPIClient(
                    base_url=service_url,
                    org_id=org_id,
                    k8s_client=k8s,
                    namespace=namespace
                )
                # Test connection
                source_types = sources_api.get_source_types()
                if source_types:
                    log_success(f"  ✓ Sources API client initialized")
                    log_info(f"  ℹ️  Available source types: {len(source_types)}")
                    log_info(f"  🎯 Will use Production Flow (HTTP → Kafka → Listener)")
                else:
                    log_warning(f"  ⚠️  Sources API responded but returned no source types")
                    sources_api = None
            except Exception as e:
                log_warning(f"  ⚠️  Sources API connection failed: {e}")
                import traceback
                traceback.print_exc()
                sources_api = None
        else:
            log_info(f"  ℹ️  Sources API not available")
            log_info(f"  Will use Development Flow (kubectl exec)")

        # Database queries will be done via kubectl exec (no port-forward needed!)
        log_success("\n✓ Database queries will use kubectl exec from within cluster")

        # Get S3 configuration for preflight checks
        # Try external route first for local execution
        s3_endpoint = None
        try:
            route_output = k8s.exec_in_pod('', ['oc', 'get', 'route', '-n', 'openshift-storage', 's3', '-o', 'jsonpath={.spec.host}'])
            if route_output and route_output.strip():
                s3_endpoint = f"https://{route_output.strip()}"
        except:
            # Fallback to internal endpoint
            s3_endpoint = "https://s3.openshift-storage.svc:443"

        bucket = "koku-bucket"

        # Fail-fast: skip remaining phases if a critical phase fails
        should_skip_remaining = False
        failed_phase = None

        # Phase 1: Preflight
        preflight = PreflightPhase(db, namespace, s3_endpoint, bucket, k8s_client=k8s, postgres_pod=postgres_pod)
        results['preflight'] = preflight.run()
        if not results['preflight']['passed'] and not results['preflight'].get('skipped'):
            log_error("\n❌ Pre-flight checks failed - skipping remaining phases")
            should_skip_remaining = True
            failed_phase = 'preflight'

        # Phase 2: Migrations
        from .phases.migrations import MigrationsPhase

        if should_skip_remaining:
            results['migrations'] = {'passed': False, 'skipped': True, 'reason': f'{failed_phase} failed'}
        else:
            migrations = MigrationsPhase(k8s, db)
            results['migrations'] = migrations.run(skip=skip_migrations)
            if not results['migrations']['passed'] and not results['migrations'].get('skipped'):
                log_error("\n❌ Migrations failed - skipping remaining phases")
                should_skip_remaining = True
                failed_phase = 'migrations'

        # Phase 2.5: Kafka Validation (Event-Driven Processing)
        if should_skip_remaining:
            results['kafka_validation'] = {'passed': False, 'skipped': True, 'reason': f'{failed_phase} failed'}
        else:
            kafka_validation = KafkaValidationPhase(k8s, namespace=namespace)
            kafka_results = kafka_validation.run()
            results['kafka_validation'] = {
                'passed': kafka_results.get('overall_success', False),
                'skipped': False,
                **kafka_results
            }
            # Kafka validation is informational - don't fail the pipeline if it fails
            # (This allows graceful degradation if Kafka listener isn't deployed yet)
            if not results['kafka_validation']['passed']:
                log_warning("\n⚠️  Kafka validation failed - continuing with remaining phases")
                log_info("   (Kafka listener is optional - orchestrator will use chords as fallback)")

        # Phase 3: Provider (with k8s client for Django ORM operations)
        if should_skip_remaining:
            results['provider'] = {'passed': False, 'skipped': True, 'reason': f'{failed_phase} failed'}
            provider_uuid = None
        else:
            provider_phase = ProviderPhase(
                db,
                org_id=org_id,
                k8s_client=k8s,
                sources_api_client=sources_api,
                postgres_pod=postgres_pod
            )
            results['provider'] = provider_phase.run(skip=skip_provider, provider_type=provider_type, cluster_id=cluster_id)
            if not results['provider']['passed'] and not results['provider'].get('skipped'):
                log_error("\n❌ Provider setup failed - skipping remaining phases")
                should_skip_remaining = True
                failed_phase = 'provider'
            provider_uuid = results['provider'].get('provider_uuid')

        # Phase 4: Data Upload
        if should_skip_remaining:
            results['data_upload'] = {'passed': False, 'skipped': True, 'reason': f'{failed_phase} failed'}
        elif infrastructure_only:
            results['data_upload'] = {'passed': False, 'skipped': True, 'reason': '--infrastructure-only'}
        else:
            from .clients.s3 import S3Client

            # Get S3 credentials - try multiple secret name patterns
            # The helm chart uses 'cost-onprem-storage-credentials' (release name prefix)
            # but the namespace might be different from the helm release name
            storage_secret_patterns = [
                'cost-onprem-storage-credentials',  # Default helm release name
                f'{namespace}-storage-credentials',  # Namespace-based
                'koku-storage-credentials',  # Legacy name
                'cost-onprem-odf-credentials',  # ODF credentials
            ]
            
            s3_access_key = None
            s3_secret_key = None
            
            for secret_name in storage_secret_patterns:
                s3_access_key = k8s.get_secret(secret_name, 'access-key')
                s3_secret_key = k8s.get_secret(secret_name, 'secret-key')
                if s3_access_key and s3_secret_key:
                    log_success(f"  ✓ Found S3 credentials in secret: {secret_name}")
                    break

            if not s3_access_key or not s3_secret_key:
                log_error("\n❌ Failed to get S3 credentials")
                should_skip_remaining = True
                failed_phase = 'data_upload'
                results['data_upload'] = {'passed': False, 'error': 'Missing S3 credentials'}
                s3_endpoint = None  # Set to None to skip the rest of data upload logic

            # Get S3 endpoint - try external route first for local execution
            # Check for external S3 route (OpenShift)
            try:
                route_output = k8s.exec_in_pod('', ['oc', 'get', 'route', '-n', 'openshift-storage', 's3', '-o', 'jsonpath={.spec.host}'])
                if route_output and route_output.strip():
                    s3_endpoint = f"https://{route_output.strip()}"
                    log_info(f"  ℹ️  Using external S3 route: {s3_endpoint}")
                else:
                    raise Exception("No route found")
            except:
                # Fallback: Get from MASU pod (internal endpoint - may not work locally)
                masu_pod = k8s.get_pod_by_component('masu')
                if not masu_pod:
                    log_error("\n❌ MASU pod not found")
                    ctx.exit(1)

                s3_endpoint_output = k8s.exec_in_pod(masu_pod, ['env'])
                s3_endpoint = None
                for line in s3_endpoint_output.split('\n'):
                    if line.startswith('S3_ENDPOINT='):
                        s3_endpoint = line.split('=', 1)[1].strip()
                        break

                if not s3_endpoint:
                    # Try common ODF S3 endpoint
                    s3_endpoint = "https://s3.openshift-storage.svc:443"
                    log_warning(f"  ⚠️  S3_ENDPOINT not in env, using default: {s3_endpoint}")

                # Convert internal endpoints to external for local execution
                if '.svc' in s3_endpoint:
                    log_warning(f"  ⚠️  Internal endpoint detected: {s3_endpoint}")
                    log_warning(f"  ⚠️  Attempting to find external route...")
                    # Try to get the OpenShift cluster domain using kubectl
                    try:
                        import subprocess
                        # Use kubectl config view to get the current cluster server
                        result = subprocess.run(
                            ['kubectl', 'config', 'view', '--minify', '-o', 'jsonpath={.clusters[0].cluster.server}'],
                            capture_output=True, text=True
                        )
                        if result.returncode == 0 and result.stdout.strip():
                            # Extract domain from API server URL (e.g., https://api.stress.parodos.dev:6443 -> apps.stress.parodos.dev)
                            server = result.stdout.strip()
                            # Remove protocol and port
                            host = server.replace('https://', '').replace('http://', '').split(':')[0]
                            # Convert api.X to apps.X
                            domain = host.replace('api.', 'apps.')
                            s3_endpoint = f"https://s3-openshift-storage.{domain}"
                            log_success(f"  ✓ Using external route: {s3_endpoint}")
                        else:
                            log_error(f"  ❌ Could not get cluster server from kubectl config")
                    except Exception as e:
                        log_error(f"  ❌ Could not determine external route: {e}")

            # Create S3 client using wrapper (pass k8s_client for internal presigned URLs)
            s3_client = S3Client(
                endpoint_url=s3_endpoint,
                access_key=s3_access_key,
                secret_key=s3_secret_key,
                verify=False,
                k8s_client=k8s
            )

            # Create Kafka client for OCP report announcements (OCP uses push-based processing)
            kafka_client = None
            if provider_type == 'OCP':
                try:
                    kafka_client = KafkaProducerClient()
                    log_success(f"  ✓ Kafka producer client initialized for OCP processing")
                except Exception as e:
                    log_warning(f"  ⚠️  Kafka client initialization failed: {e}")
                    log_info(f"     OCP processing may not be automatically triggered")

            # DataUploadPhase with S3 client (direct upload via HTTPS)
            data_upload = DataUploadPhase(
                s3_client,  # Pass the whole S3Client wrapper (not just .s3) for internal presigned URLs
                nise,
                k8s_client=k8s,
                db_client=db,
                provider_uuid=provider_uuid,
                kafka_client=kafka_client,
                org_id=org_id,
                s3_endpoint=s3_endpoint
            )

            # Use direct AWS CUR format upload (no need for in-pod execution)
            # Use monthly boundaries that MASU expects (first day of month to first day of next month)
            now = datetime.now()
            # Current month start
            start_date = datetime(now.year, now.month, 1)
            # Next month start (end date)
            if now.month == 12:
                end_date = datetime(now.year + 1, 1, 1)
            else:
                end_date = datetime(now.year, now.month + 1, 1)

            log_info(f"  ℹ️  Using monthly period: {start_date.strftime('%Y-%m-%d')} to {end_date.strftime('%Y-%m-%d')}")

            results['data_upload'] = data_upload.upload_provider_data(
                provider_type=provider_type,
                start_date=start_date,
                end_date=end_date,
                force=force,
                smoke_test=smoke_test,
                cluster_id=cluster_id
            )

            # Check for S3 errors
            if 'data_upload' in results:
                if not results['data_upload'].get('success', True) and 'error' in results['data_upload']:
                    log_error("\n❌ Data upload failed - S3 error")
                    should_skip_remaining = True
                    failed_phase = 'data_upload'

                # Check if upload was skipped due to invalid data
                elif results['data_upload'].get('skipped'):
                    reason = results['data_upload'].get('reason', 'unknown')
                    valid = results['data_upload'].get('valid', False)

                    if reason == 'invalid_data' or not valid:
                        log_error("\n❌ Data upload skipped - INVALID DATA IN S3")
                        log_info("   Found files but no valid manifest")
                        log_info("   Run with --force to regenerate")
                        should_skip_remaining = True
                        failed_phase = 'data_upload'
                    elif reason == 'valid_data_exists':
                        log_success("\n✅ Using existing valid data")
                        # Continue with processing

        # Phase 5-6: Processing (with provider UUID for targeted download)
        if should_skip_remaining:
            results['processing'] = {'passed': False, 'skipped': True, 'reason': f'{failed_phase} failed'}
        else:
            # Extract manifest_uuid from data_upload result for targeted monitoring
            manifest_uuid = results.get('data_upload', {}).get('manifest_uuid')
            if manifest_uuid:
                log_info(f"  ℹ️  Monitoring specific manifest: {manifest_uuid} (faster)")

            processing = ProcessingPhase(
                k8s,
                db,
                timeout=timeout,
                provider_uuid=provider_uuid,
                org_id=org_id,
                manifest_uuid=manifest_uuid,
                provider_type=provider_type,
                cluster_id=cluster_id
            )
            results['processing'] = processing.run()
            if not results['processing']['passed'] and not results['processing'].get('skipped'):
                log_error("\n❌ Processing failed - skipping remaining phases")
                should_skip_remaining = True
                failed_phase = 'processing'

        # Look up actual schema_name from Customer table (Koku prefixes 'org' to org_id)
        # This is needed for the Validation phase
        tenant_schema = db.get_schema_name_for_org(org_id)
        log_info(f"  ℹ️  Using tenant schema: {tenant_schema}")

        # Phase 7: Validation (PostgreSQL-based)
        if should_skip_remaining:
            results['validation'] = {'passed': False, 'skipped': True, 'reason': f'{failed_phase} failed'}
        elif skip_tests:
            # Tests explicitly skipped
            results['validation'] = {'passed': True, 'skipped': True, 'reason': '--skip-tests flag'}
        else:
            # Run standalone validation (uses dynamic dates matching data generation)
            log_info("\n📋 Running data validation...")
            # Calculate validation dates (same as data generation)
            now = datetime.now()
            val_start_date = datetime(now.year, now.month, 1)
            # For smoke tests, we generate only 1 day of data
            val_end_date = val_start_date + timedelta(days=1) if smoke_test else (
                datetime(now.year + 1, 1, 1) if now.month == 12 else datetime(now.year, now.month + 1, 1)
            )
            validation = SmokeValidationPhase(
                db_client=db,
                namespace=namespace,
                org_id=tenant_schema,  # Use actual schema name (e.g., orgorg1234567)
                cluster_id=cluster_id,
                start_date=val_start_date,
                end_date=val_end_date
            )
            results['validation'] = validation.run()
            if not results['validation']['passed']:
                log_error("\n❌ Validation failed")
                should_skip_remaining = True
                failed_phase = 'validation'

        # Final Summary
        log_info("\n" + "="*70)
        log_info("FINAL SUMMARY")
        log_info("="*70)

        elapsed = time.time() - start_time
        log_info(f"\nTotal Time: {elapsed:.1f}s ({elapsed/60:.1f} minutes)")

        # Define critical phases that MUST pass (never be skipped or failed)
        critical_phases = ['preflight', 'provider', 'data_upload', 'processing']

        log_info(f"    DEBUG: smoke_test={smoke_test}")

        # Validation is critical in smoke test mode (validates costs match nise YAML)
        if smoke_test:
            critical_phases.append('validation')
            log_info(f"    DEBUG: Added 'validation' to critical_phases")

        # IQE tests are critical in full validation mode only
        if not smoke_test:
            critical_phases.append('iqe_tests')

        log_info(f"    DEBUG: final critical_phases={critical_phases}")

        # Check critical phase status
        critical_failures = []
        critical_skipped = []
        critical_passed = []

        for phase in critical_phases:
            result = results.get(phase, {'passed': False, 'skipped': False})
            # Debug: Print phase status
            log_info(f"    DEBUG: {phase} -> passed={result.get('passed')}, skipped={result.get('skipped')}")
            if result.get('skipped', False):
                critical_skipped.append(phase)
            elif not result.get('passed', False):
                critical_failures.append(phase)
            else:
                critical_passed.append(phase)

        # Debug: Print critical phase lists
        log_info(f"    DEBUG: critical_passed={critical_passed}")
        log_info(f"    DEBUG: critical_skipped={critical_skipped}")
        log_info(f"    DEBUG: critical_failures={critical_failures}")
        log_info(f"    DEBUG: bool(critical_failures)={bool(critical_failures)}")
        log_info(f"    DEBUG: bool(critical_skipped)={bool(critical_skipped)}")
        log_info(f"    DEBUG: (critical_failures or critical_skipped)={(critical_failures or critical_skipped)}")

        # Count all phases for summary
        phases_passed = sum(1 for r in results.values() if r.get('passed', False) and not r.get('skipped', False))
        phases_skipped = sum(1 for r in results.values() if r.get('skipped', False))
        phases_failed = sum(1 for r in results.values() if not r.get('passed', False) and not r.get('skipped', False))
        phases_total = len(results) - phases_skipped

        log_info(f"\nPhases: {phases_passed}/{phases_total} passed", end="")
        if phases_skipped > 0:
            log_info(f" ({phases_skipped} skipped)")
        else:
            log_info()

        for phase_name, phase_result in results.items():
            if phase_result.get('skipped'):
                status = "⏭️ "
            elif phase_result.get('passed'):
                status = "✅"
            else:
                status = "❌"
            log_info(f"  {status} {phase_name}")

        # Overall result - ALL critical phases must pass
        validation_mode = "SMOKE TEST" if smoke_test else "FULL VALIDATION"
        test_failed = bool(critical_failures or critical_skipped)

        if test_failed:
            log_error(f"\n❌ E2E {validation_mode} FAILED")
            if critical_failures:
                log_info(f"\nCritical phases failed: {', '.join(critical_failures)}")
            if critical_skipped:
                log_info(f"Critical phases skipped: {', '.join(critical_skipped)}")
            log_warning("\n⚠️  Validation cannot pass with critical phase failures/skips")
            exit_code = 1
        else:
            log_success(f"\n✅ E2E {validation_mode} PASSED")
            log_info(f"\nAll {len(critical_passed)} critical phases completed successfully!")
            log_info(f"Critical phases: {', '.join(critical_passed)}")
            if provider_type == 'OCP':
                log_info("OCP provider validated (architecture-agnostic)")
            else:
                log_info("Database layer validated (architecture-agnostic)")
            exit_code = 0

        # Run diagnostics: automatically on failure OR when --diagnose flag is passed
        if test_failed or diagnose:
            log_info("\n" + "="*70)
            if test_failed:
                log_info("🔍 RUNNING DIAGNOSTICS (auto-triggered by failure)")
            else:
                log_info("🔍 RUNNING DIAGNOSTICS (--diagnose flag)")
            log_info("="*70)
            log_info("\nCollecting infrastructure health information...\n")

            try:
                diagnostic = DeploymentValidationPhase(k8s, db)
                diagnostic_results = diagnostic.run_all_validations()

                # Show diagnostic summary
                if diagnostic_results.get('summary'):
                    summary = diagnostic_results['summary']
                    score = summary.get('score', 0)
                    if score >= 95:
                        log_success("\n✅ Infrastructure appears healthy - issue likely in application logic")
                    elif score >= 70:
                        log_warning("\n⚠️  Some infrastructure issues detected - review above for details")
                    else:
                        log_error("\n❌ Significant infrastructure issues - likely root cause of failure")
            except Exception as diag_error:
                log_warning(f"\n⚠️  Diagnostic collection failed: {diag_error}")
                log_info("   (This doesn't affect the test result)")

    except KeyboardInterrupt:
        log_warning("\n\n⚠️  Interrupted by user")
        exit_code = 130
    except (click.exceptions.Exit, SystemExit):
        # Let Click handle exit codes properly
        raise
    except Exception as e:
        log_error(f"\n\n❌ Unexpected error: {e}")
        import traceback
        traceback.print_exc()
        exit_code = 1
    finally:
        # Cleanup
        if 'db' in locals():
            db.close()

    # Exit with proper code using Click's context
    ctx.exit(exit_code)


if __name__ == '__main__':
    main()

