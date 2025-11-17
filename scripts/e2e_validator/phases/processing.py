"""
Phase 5-6: Data Processing
===========================

Trigger and monitor MASU data processing.
"""

import time
from typing import Dict


class ProcessingPhase:
    """Phase 5-6: Trigger and monitor data processing"""

    def __init__(self, k8s_client, db_client, timeout: int = 300, provider_uuid: str = None):
        """Initialize processing phase

        Args:
            k8s_client: KubernetesClient instance
            db_client: DatabaseClient instance
            timeout: Processing timeout in seconds (default 300s = 5 minutes)
            provider_uuid: Provider UUID to process (if None, scans all providers)
        """
        self.k8s = k8s_client
        self.db = db_client
        self.timeout = timeout
        self.provider_uuid = provider_uuid

    def trigger_processing(self) -> Dict:
        """Trigger MASU processing via Celery task
        
        Uses provider-specific download task if provider_uuid is set,
        otherwise uses generic check_report_updates.
        """
        # Reset provider timestamps to enable immediate processing
        # This is critical for E2E testing - without this, the provider
        # may be skipped due to polling_timestamp > data_updated_timestamp
        if self.db and self.provider_uuid:
            print(f"\n🔄 Resetting provider timestamps to enable processing...")
            try:
                self.db.execute_query("""
                    UPDATE api_provider 
                    SET data_updated_timestamp = NOW(),
                        polling_timestamp = NOW() - INTERVAL '10 minutes'
                    WHERE uuid = %s
                """, (self.provider_uuid,))
                print(f"  ✅ Provider {self.provider_uuid} ready for polling")
            except Exception as e:
                print(f"  ⚠️  Failed to reset timestamps: {e}")
                print(f"  ℹ️  Processing may be delayed until next natural polling cycle")
        
        masu_pod = self.k8s.get_pod_by_component('masu')
        if not masu_pod:
            return {'success': False, 'error': 'MASU pod not found'}

        try:
            # Use check_report_updates which scans all active providers
            # This is the proven approach from the bash script
            python_code = """
import os, sys, django
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'koku.settings')
sys.path.append('/opt/koku/koku')
django.setup()
from masu.celery.tasks import check_report_updates
try:
    result = check_report_updates.delay()
    print(f'TASK_ID={result.id}')
    print(f'TASK_NAME=check_report_updates')
except Exception as e:
    import traceback
    print(f'ERROR={e}')
    print(f'TRACEBACK={traceback.format_exc()}')
"""

            output = self.k8s.python_exec(masu_pod, python_code)

            if 'TASK_ID=' in output:
                task_id = output.split('TASK_ID=')[1].split('\n')[0].strip()
                task_name = 'unknown'
                if 'TASK_NAME=' in output:
                    task_name = output.split('TASK_NAME=')[1].split('\n')[0].strip()
                
                result = {'success': True, 'task_id': task_id, 'task_name': task_name}
                
                # Include provider info if available
                if 'PROVIDER_TYPE=' in output:
                    result['provider_type'] = output.split('PROVIDER_TYPE=')[1].split('\n')[0].strip()
                if 'PROVIDER_NAME=' in output:
                    result['provider_name'] = output.split('PROVIDER_NAME=')[1].split('\n')[0].strip()
                if 'ORG_ID=' in output:
                    result['org_id'] = output.split('ORG_ID=')[1].split('\n')[0].strip()
                
                return result
            elif 'ERROR=' in output:
                error = output.split('ERROR=')[1].split('\n')[0].strip()
                return {'success': False, 'error': error, 'output': output}
            else:
                return {'success': False, 'error': 'No task ID returned', 'output': output}

        except Exception as e:
            return {'success': False, 'error': str(e)}

    def check_processing_status(self) -> int:
        """Check manifest count in database"""
        try:
            return self.db.get_manifest_count()
        except Exception:
            return 0

    def monitor_processing(self) -> Dict:
        """Monitor data processing until complete or timeout"""
        print(f"\n⏳ Monitoring processing (timeout: {self.timeout}s)...")

        start_count = self.check_processing_status()
        start_time = time.time()
        interval = 10

        while True:
            elapsed = int(time.time() - start_time)

            if elapsed >= self.timeout:
                print(f"\n  ⏱️  Timeout reached ({self.timeout}s)")
                current_count = self.check_processing_status()
                if current_count > start_count:
                    print(f"  ✅ Processing started ({current_count} manifests)")
                    return {
                        'success': True,
                        'timeout': True,
                        'manifest_count': current_count,
                        'elapsed': elapsed
                    }
                else:
                    print("  ⚠️  No manifests processed")
                    return {
                        'success': False,
                        'timeout': True,
                        'manifest_count': current_count,
                        'elapsed': elapsed
                    }

            time.sleep(interval)
            current_count = self.check_processing_status()

            if current_count > start_count:
                print(f"\n  ✅ Manifest processed (elapsed: {elapsed}s)")
                return {
                    'success': True,
                    'timeout': False,
                    'manifest_count': current_count,
                    'elapsed': elapsed
                }

            print(".", end="", flush=True)

    def run(self) -> Dict:
        """Run processing phase

        Returns:
            Results dict
        """
        print("\n" + "="*70)
        print("Phase 5-6: Data Processing")
        print("="*70 + "\n")

        # Trigger processing
        print("🚀 Triggering MASU data processing...")
        print(f"  Timeout: {self.timeout}s")
        if self.provider_uuid:
            print(f"  Provider UUID: {self.provider_uuid}")
        
        trigger_result = self.trigger_processing()

        if not trigger_result['success']:
            print(f"  ❌ Failed to trigger processing: {trigger_result.get('error')}")
            if 'output' in trigger_result:
                print(f"\n  Debug output:")
                for line in trigger_result['output'].split('\n')[:10]:
                    if line.strip():
                        print(f"    {line}")
            return {'passed': False, 'trigger': trigger_result}

        print(f"  ✅ Task triggered: {trigger_result['task_id']}")
        print(f"     Task name: {trigger_result.get('task_name', 'unknown')}")
        
        if 'provider_type' in trigger_result:
            print(f"     Provider: {trigger_result['provider_name']} ({trigger_result['provider_type']})")
            print(f"     Org ID: {trigger_result['org_id']}")

        # Monitor processing
        monitor_result = self.monitor_processing()

        if monitor_result['success']:
            print(f"\n  ✅ Processing complete")
            print(f"  ℹ️  Manifests: {monitor_result['manifest_count']}")
            print(f"  ℹ️  Time: {monitor_result['elapsed']}s")
        else:
            print(f"\n  ⚠️  Processing timeout or incomplete")
            print(f"  ℹ️  Manifests: {monitor_result['manifest_count']}")
            print(f"  ℹ️  Elapsed: {monitor_result['elapsed']}s")

        return {
            'passed': monitor_result['success'],
            'trigger': trigger_result,
            'monitor': monitor_result
        }

