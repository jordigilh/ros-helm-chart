"""
Phase 1: Pre-flight Checks
===========================

Validates environment is ready for E2E testing.
"""

from typing import Dict


class PreflightPhase:
    """Phase 1: Pre-flight validation"""

    def __init__(self, k8s_client, namespace: str = "cost-mgmt"):
        """Initialize preflight checker

        Args:
            k8s_client: KubernetesClient instance
            namespace: Kubernetes namespace
        """
        self.k8s = k8s_client
        self.namespace = namespace

    def check_namespace(self) -> Dict:
        """Verify namespace is accessible"""
        try:
            self.k8s.v1.read_namespace(self.namespace)
            return {'passed': True, 'namespace': self.namespace}
        except Exception as e:
            return {'passed': False, 'error': str(e)}

    def find_masu_pod(self) -> Dict:
        """Find MASU pod"""
        pod_name = self.k8s.get_pod_by_component('masu')
        if pod_name:
            return {'passed': True, 'pod_name': pod_name}
        else:
            return {'passed': False, 'error': 'MASU pod not found'}

    def check_pod_health(self) -> Dict:
        """Check overall pod health"""
        health = self.k8s.get_pod_health()
        passed = health['ready'] >= 20  # Expect at least 20 ready pods

        return {
            'passed': passed,
            'total': health['total'],
            'ready': health['ready'],
            'running': health['running']
        }

    def run(self) -> Dict:
        """Run all preflight checks

        Returns:
            Results dict with all checks
        """
        print("\n" + "="*70)
        print("Phase 1: Pre-flight Checks")
        print("="*70 + "\n")

        results = {}

        # Check namespace
        print("🔍 Checking namespace...")
        results['namespace'] = self.check_namespace()
        if results['namespace']['passed']:
            print(f"  ✅ Namespace '{self.namespace}' accessible")
        else:
            print(f"  ❌ Namespace check failed: {results['namespace']['error']}")
            return {'passed': False, 'results': results}

        # Find MASU pod
        print("\n🔍 Finding MASU pod...")
        results['masu_pod'] = self.find_masu_pod()
        if results['masu_pod']['passed']:
            print(f"  ✅ MASU pod found: {results['masu_pod']['pod_name']}")
        else:
            print(f"  ❌ MASU pod not found")
            return {'passed': False, 'results': results}

        # Check pod health
        print("\n🔍 Checking pod health...")
        results['pod_health'] = self.check_pod_health()
        if results['pod_health']['passed']:
            print(f"  ✅ Pod health: {results['pod_health']['ready']}/{results['pod_health']['total']} ready")
        else:
            print(f"  ⚠️  Pod health: {results['pod_health']['ready']}/{results['pod_health']['total']} ready (expected ≥20)")

        all_passed = all(r.get('passed', False) for r in results.values())

        if all_passed:
            print("\n✅ Pre-flight checks passed")
        else:
            print("\n⚠️  Some pre-flight checks failed")

        return {
            'passed': all_passed,
            'results': results
        }

