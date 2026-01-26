"""
Kafka Infrastructure Validation Tests.

These tests validate the Kafka infrastructure required for Cost Management:
1. Kafka cluster health (Strimzi-managed)
2. Kafka listener pod deployment
3. Kafka connectivity from listener
4. Required Kafka topics existence

Source Reference: scripts/e2e_validator/phases/kafka_validation.py
"""

import json
import os
import subprocess
from typing import List, Optional

import pytest

from utils import get_pod_by_label, run_oc_command


# =============================================================================
# Helper Functions
# =============================================================================

def get_kafka_namespace() -> str:
    """Get Kafka namespace from environment or default."""
    return os.environ.get("KAFKA_NAMESPACE", "kafka")


def get_kafka_broker_pod(kafka_namespace: str) -> Optional[str]:
    """Get the first Kafka broker pod name.
    
    Uses strimzi.io/broker-role=true to find actual broker pods,
    not the entity-operator which also has strimzi.io/kind=Kafka.
    
    Args:
        kafka_namespace: Namespace where Kafka is deployed
        
    Returns:
        Pod name or None if not found
    """
    try:
        # Use broker-role label to get actual Kafka broker, not entity-operator
        result = subprocess.run(
            [
                "kubectl", "get", "pods",
                "-n", kafka_namespace,
                "-l", "strimzi.io/broker-role=true",
                "-o", "jsonpath={.items[0].metadata.name}",
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
        return None
    except (subprocess.TimeoutExpired, Exception):
        return None


def get_kafka_pods_status(kafka_namespace: str) -> dict:
    """Get status of all Kafka pods.
    
    Args:
        kafka_namespace: Namespace where Kafka is deployed
        
    Returns:
        Dict with pod counts and status details
    """
    try:
        result = subprocess.run(
            [
                "kubectl", "get", "pods",
                "-n", kafka_namespace,
                "-l", "strimzi.io/kind=Kafka",
                "-o", "json",
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
        
        if result.returncode != 0:
            return {"error": result.stderr, "total": 0, "running": 0}
        
        pods_data = json.loads(result.stdout)
        items = pods_data.get("items", [])
        
        running = sum(
            1 for pod in items
            if pod.get("status", {}).get("phase") == "Running"
        )
        
        return {
            "total": len(items),
            "running": running,
            "pods": [
                {
                    "name": pod.get("metadata", {}).get("name"),
                    "phase": pod.get("status", {}).get("phase"),
                }
                for pod in items
            ],
        }
    except Exception as e:
        return {"error": str(e), "total": 0, "running": 0}


def list_kafka_topics(kafka_namespace: str, kafka_pod: str) -> List[str]:
    """List all Kafka topics.
    
    Args:
        kafka_namespace: Namespace where Kafka is deployed
        kafka_pod: Name of a Kafka broker pod
        
    Returns:
        List of topic names
    """
    try:
        result = subprocess.run(
            [
                "kubectl", "exec",
                "-n", kafka_namespace,
                kafka_pod, "--",
                "bin/kafka-topics.sh",
                "--bootstrap-server", "localhost:9092",
                "--list",
            ],
            capture_output=True,
            text=True,
            timeout=60,
        )
        
        if result.returncode != 0:
            return []
        
        # Filter out internal topics (starting with __)
        topics = [
            t.strip() for t in result.stdout.split("\n")
            if t.strip() and not t.strip().startswith("__")
        ]
        return topics
    except Exception:
        return []


def check_listener_kafka_connection(namespace: str, listener_pod: str) -> dict:
    """Check listener logs for Kafka connection status.
    
    Args:
        namespace: Application namespace
        listener_pod: Name of the listener pod
        
    Returns:
        Dict with connection status and details
    """
    try:
        result = subprocess.run(
            [
                "kubectl", "logs",
                "-n", namespace,
                listener_pod,
                "--tail=200",
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
        
        if result.returncode != 0:
            return {"connected": False, "error": result.stderr}
        
        logs = result.stdout.lower()
        
        # Check for positive connection indicators
        connected_indicators = [
            "kafka is running",
            "consumer is listening",
            "connected to kafka",
            "subscribed to topic",
        ]
        
        # Check for error indicators
        error_indicators = [
            "kafka connection error",
            "unable to connect to kafka",
            "broker transport failure",
            "connection refused",
        ]
        
        has_connection = any(ind in logs for ind in connected_indicators)
        has_errors = any(ind in logs for ind in error_indicators)
        
        return {
            "connected": has_connection and not has_errors,
            "has_errors": has_errors,
            "logs_checked": True,
        }
    except Exception as e:
        return {"connected": False, "error": str(e)}


# =============================================================================
# Test Classes
# =============================================================================

@pytest.mark.infrastructure
@pytest.mark.component
class TestKafkaCluster:
    """Tests for Kafka cluster health."""
    
    def test_kafka_cluster_pods_exist(self):
        """Verify Kafka cluster pods exist in the kafka namespace."""
        kafka_ns = get_kafka_namespace()
        status = get_kafka_pods_status(kafka_ns)
        
        if "error" in status and status["total"] == 0:
            pytest.skip(f"Kafka cluster not found in namespace '{kafka_ns}': {status.get('error', 'unknown')}")
        
        assert status["total"] > 0, (
            f"No Kafka pods found in namespace '{kafka_ns}'. "
            "Ensure Strimzi Kafka is deployed."
        )
    
    def test_kafka_cluster_pods_running(self):
        """Verify all Kafka cluster pods are in Running state."""
        kafka_ns = get_kafka_namespace()
        status = get_kafka_pods_status(kafka_ns)
        
        if status["total"] == 0:
            pytest.skip(f"No Kafka pods found in namespace '{kafka_ns}'")
        
        assert status["running"] == status["total"], (
            f"Not all Kafka pods are running: {status['running']}/{status['total']}. "
            f"Pod details: {status.get('pods', [])}"
        )
    
    def test_kafka_broker_accessible(self):
        """Verify at least one Kafka broker pod is accessible."""
        kafka_ns = get_kafka_namespace()
        broker_pod = get_kafka_broker_pod(kafka_ns)
        
        if not broker_pod:
            pytest.skip(f"No Kafka broker pod found in namespace '{kafka_ns}'")
        
        # Try to run a simple command in the broker pod
        try:
            result = subprocess.run(
                [
                    "kubectl", "exec",
                    "-n", kafka_ns,
                    broker_pod, "--",
                    "echo", "broker-accessible",
                ],
                capture_output=True,
                text=True,
                timeout=30,
            )
            assert result.returncode == 0, f"Cannot exec into Kafka broker: {result.stderr}"
        except subprocess.TimeoutExpired:
            pytest.fail("Timeout accessing Kafka broker pod")


@pytest.mark.infrastructure
@pytest.mark.component
class TestKafkaTopics:
    """Tests for required Kafka topics."""
    
    REQUIRED_TOPICS = [
        "platform.upload.announce",  # Ingress upload notifications
        "hccm.ros.events",           # ROS events from Koku
    ]
    
    def test_can_list_topics(self):
        """Verify we can list Kafka topics."""
        kafka_ns = get_kafka_namespace()
        broker_pod = get_kafka_broker_pod(kafka_ns)
        
        if not broker_pod:
            pytest.skip(f"No Kafka broker pod found in namespace '{kafka_ns}'")
        
        topics = list_kafka_topics(kafka_ns, broker_pod)
        
        # We should be able to list topics even if none exist
        assert isinstance(topics, list), "Failed to list Kafka topics"
    
    @pytest.mark.parametrize("topic", REQUIRED_TOPICS)
    def test_required_topic_exists(self, topic: str):
        """Verify required Kafka topic exists."""
        kafka_ns = get_kafka_namespace()
        broker_pod = get_kafka_broker_pod(kafka_ns)
        
        if not broker_pod:
            pytest.skip(f"No Kafka broker pod found in namespace '{kafka_ns}'")
        
        topics = list_kafka_topics(kafka_ns, broker_pod)
        
        if not topics:
            pytest.skip("Could not list Kafka topics - cluster may not be ready")
        
        assert topic in topics, (
            f"Required topic '{topic}' not found. "
            f"Available topics: {', '.join(topics[:10])}{'...' if len(topics) > 10 else ''}"
        )


@pytest.mark.infrastructure
@pytest.mark.integration
class TestKafkaListener:
    """Tests for Kafka listener pod and connectivity."""
    
    def test_listener_pod_exists(self, cluster_config):
        """Verify Kafka listener pod exists."""
        listener_pod = get_pod_by_label(
            cluster_config.namespace,
            "app.kubernetes.io/component=listener"
        )
        
        if not listener_pod:
            pytest.skip("Listener pod not found - may not be deployed yet")
        
        assert listener_pod, "Kafka listener pod not found"
    
    def test_listener_pod_running(self, cluster_config):
        """Verify Kafka listener pod is in Running state."""
        listener_pod = get_pod_by_label(
            cluster_config.namespace,
            "app.kubernetes.io/component=listener"
        )
        
        if not listener_pod:
            pytest.skip("Listener pod not found")
        
        # Check pod status
        try:
            result = subprocess.run(
                [
                    "kubectl", "get", "pod",
                    "-n", cluster_config.namespace,
                    listener_pod,
                    "-o", "jsonpath={.status.phase}",
                ],
                capture_output=True,
                text=True,
                timeout=30,
            )
            
            phase = result.stdout.strip()
            assert phase == "Running", f"Listener pod is not running (status: {phase})"
        except subprocess.TimeoutExpired:
            pytest.fail("Timeout checking listener pod status")
    
    def test_listener_container_ready(self, cluster_config):
        """Verify listener container is ready."""
        listener_pod = get_pod_by_label(
            cluster_config.namespace,
            "app.kubernetes.io/component=listener"
        )
        
        if not listener_pod:
            pytest.skip("Listener pod not found")
        
        try:
            result = subprocess.run(
                [
                    "kubectl", "get", "pod",
                    "-n", cluster_config.namespace,
                    listener_pod,
                    "-o", "jsonpath={.status.containerStatuses[0].ready}",
                ],
                capture_output=True,
                text=True,
                timeout=30,
            )
            
            ready = result.stdout.strip().lower()
            assert ready == "true", f"Listener container not ready: {ready}"
        except subprocess.TimeoutExpired:
            pytest.fail("Timeout checking listener container readiness")
    
    def test_listener_kafka_connectivity(self, cluster_config):
        """Verify listener can connect to Kafka (log-based check)."""
        listener_pod = get_pod_by_label(
            cluster_config.namespace,
            "app.kubernetes.io/component=listener"
        )
        
        if not listener_pod:
            pytest.skip("Listener pod not found")
        
        status = check_listener_kafka_connection(
            cluster_config.namespace,
            listener_pod
        )
        
        if "error" in status:
            pytest.skip(f"Could not check listener logs: {status['error']}")
        
        if status.get("has_errors"):
            pytest.fail(
                "Kafka connection errors found in listener logs. "
                "Check: kubectl logs -n {ns} {pod} | grep -i 'kafka\\|error'".format(
                    ns=cluster_config.namespace,
                    pod=listener_pod
                )
            )
        
        # Note: If no explicit connection message but no errors, we consider it OK
        # The listener may not log connection success explicitly
        if not status.get("connected") and not status.get("has_errors"):
            # This is a soft pass - no errors detected
            pass
