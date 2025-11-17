"""
Phase 8: IQE Test Suite
========================

Run IQE tests to validate application functionality.
"""

import subprocess
import os
from typing import Dict, Optional


class IQETestPhase:
    """Phase 8: Run IQE test suite"""

    def __init__(self, iqe_dir: str, namespace: str = "cost-mgmt"):
        """Initialize IQE test phase

        Args:
            iqe_dir: Path to IQE plugin directory
            namespace: Kubernetes namespace
        """
        self.iqe_dir = iqe_dir
        self.namespace = namespace
        self.port_forward_proc = None

    def setup_port_forward(self) -> bool:
        """Set up port forward to Koku API"""
        print("\n🔌 Setting up port-forward to Koku API...")

        try:
            self.port_forward_proc = subprocess.Popen(
                ['kubectl', 'port-forward', '-n', self.namespace,
                 'svc/koku-koku-api', '8000:8000'],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE
            )

            # Wait for port forward to be ready
            import time
            for i in range(30):
                try:
                    import requests
                    response = requests.get('http://localhost:8000/api/cost-management/v1/status/', timeout=1)
                    if response.status_code == 200:
                        print("  ✅ Port-forward established")
                        return True
                except Exception:
                    time.sleep(1)

            print("  ⚠️  Port-forward timeout (API not accessible)")
            return False

        except Exception as e:
            print(f"  ❌ Port-forward failed: {e}")
            return False

    def cleanup_port_forward(self):
        """Clean up port forward process"""
        if self.port_forward_proc:
            self.port_forward_proc.terminate()
            try:
                self.port_forward_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.port_forward_proc.kill()

    def run_iqe_tests(self) -> Dict:
        """Run IQE test suite"""
        print("\n🧪 Running IQE test suite...")
        print("  (This may take 5-10 minutes)\n")

        env = os.environ.copy()
        env['ENV_FOR_DYNACONF'] = 'onprem'
        env['DYNACONF_IQE_VAULT_LOADER_ENABLED'] = 'false'
        env['PYTEST_PLUGINS'] = 'iqe_cost_management.conftest_onprem'

        # Use python3 from current venv (should be IQE venv if wrapper script is used)
        python_cmd = 'python3'

        try:
            result = subprocess.run(
                [
                    python_cmd, '-m', 'pytest',
                    'iqe_cost_management/tests/rest_api/v1/',
                    '-v', '--tb=short', '--maxfail=10',
                    '-k', 'not wait_for_ingest'
                ],
                cwd=self.iqe_dir,
                env=env,
                capture_output=True,
                text=True,
                timeout=600  # 10 minute timeout
            )

            # Parse results
            output = result.stdout + result.stderr

            passed = 0
            failed = 0
            skipped = 0

            for line in output.split('\n'):
                if ' passed' in line:
                    try:
                        passed = int(line.split()[0])
                    except (ValueError, IndexError):
                        pass
                if ' failed' in line:
                    try:
                        failed = int(line.split()[0])
                    except (ValueError, IndexError):
                        pass
                if ' skipped' in line:
                    try:
                        skipped = int(line.split()[0])
                    except (ValueError, IndexError):
                        pass

            total = passed + failed

            print(f"\n  📊 Results:")
            print(f"    Passed:  {passed}")
            print(f"    Failed:  {failed}")
            print(f"    Skipped: {skipped}")
            print(f"    Total:   {total}")

            success = failed == 0 and total > 0

            if success:
                print(f"\n  ✅ All tests passed!")
            elif total == 0:
                print(f"\n  ⚠️  No tests executed")
            else:
                print(f"\n  ⚠️  {failed} tests failed")

            return {
                'success': success,
                'passed': passed,
                'failed': failed,
                'skipped': skipped,
                'total': total,
                'output': output
            }

        except subprocess.TimeoutExpired:
            print("\n  ⏱️  Test timeout (10 minutes)")
            return {
                'success': False,
                'error': 'Timeout',
                'passed': 0,
                'failed': 0,
                'total': 0
            }
        except Exception as e:
            print(f"\n  ❌ Test execution failed: {e}")
            return {
                'success': False,
                'error': str(e),
                'passed': 0,
                'failed': 0,
                'total': 0
            }

    def run(self, skip: bool = False) -> Dict:
        """Run IQE test phase

        Args:
            skip: Skip tests if True

        Returns:
            Results dict
        """
        print("\n" + "="*70)
        print("Phase 8: IQE Test Suite")
        print("="*70)

        if skip:
            print("\n⏭️  Skipped (--skip-tests)")
            return {'passed': False, 'skipped': True}

        if not os.path.isdir(self.iqe_dir):
            print(f"\n⚠️  IQE directory not found: {self.iqe_dir}")
            print("  Skipping IQE tests")
            return {'passed': False, 'skipped': True, 'reason': 'IQE dir not found'}

        # Setup port forward
        if not self.setup_port_forward():
            return {
                'passed': False,
                'error': 'Port-forward setup failed'
            }

        try:
            # Run tests
            test_results = self.run_iqe_tests()

            return {
                'passed': test_results['success'],
                'results': test_results
            }

        finally:
            # Always cleanup
            self.cleanup_port_forward()

