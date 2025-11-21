"""
Kafka Producer Client for E2E Testing
======================================

Sends OCP report announcements to Kafka to trigger MASU processing.
"""

import json
import base64
import uuid
import subprocess
from typing import List, Dict


class KafkaProducerClient:
    """Kafka producer for sending OCP report announcements"""

    def __init__(self, kafka_bootstrap_servers: str = "kafka-cluster-kafka-bootstrap.kafka.svc:9092"):
        """Initialize Kafka producer

        Args:
            kafka_bootstrap_servers: Kafka bootstrap servers (default: in-cluster service)
        """
        self.kafka_bootstrap = kafka_bootstrap_servers
        self.topic = "platform.upload.announce"

    def send_ocp_report_message(self,
                                 provider_uuid: str,
                                 org_id: str,
                                 cluster_id: str,
                                 files: List[str],
                                 s3_endpoint: str,
                                 bucket: str = "cost-data",
                                 report_prefix: str = "reports/test-report") -> Dict:
        """Send OCP report announcement to Kafka

        This simulates the koku-metrics-operator announcing that OCP usage reports
        are available for processing.

        Args:
            provider_uuid: OCP provider UUID
            org_id: Organization ID (tenant schema name)
            cluster_id: OpenShift cluster identifier
            files: List of CSV filenames (e.g., ['pod_usage.csv', 'storage_usage.csv'])
            s3_endpoint: S3 endpoint URL
            bucket: S3 bucket name
            report_prefix: S3 path prefix to reports

        Returns:
            Dict with success status and message details
        """
        request_id = f"e2e-test-{uuid.uuid4()}"

        # Build x-rh-identity header
        identity = {
            "identity": {
                "account_number": "10001",
                "org_id": org_id,
                "type": "System",
                "internal": {
                    "org_id": org_id
                },
                "system": {
                    "cluster_id": cluster_id
                }
            },
            "entitlements": {
                "cost_management": {"is_entitled": True},
                "insights": {"is_entitled": True}
            }
        }

        b64_identity = base64.b64encode(json.dumps(identity).encode('utf-8')).decode('utf-8')

        # Build file list with report types
        file_objects = []
        for file in files:
            # Extract report type from filename (e.g., pod_usage.csv -> pod_usage)
            report_type = file.replace('.csv', '').replace('_usage', '_usage')

            file_obj = {
                "file": f"{s3_endpoint}/{bucket}/{report_prefix}/{file}",
                "split_files": [],
                "report_type": report_type
            }
            file_objects.append(file_obj)

        # Build Kafka message payload
        message = {
            "request_id": request_id,
            "account": "10001",
            "org_id": org_id,
            "b64_identity": b64_identity,
            "service": "hccm",  # Hybrid Cloud Cost Management
            "files": file_objects,
            "provider_uuid": provider_uuid,
            "provider_type": "OCP",
            "cluster_id": cluster_id,
            "schema_name": org_id,
            "manifest_id": None  # Will be created by MASU
        }

        message_json = json.dumps(message)

        print(f"\n📨 Sending Kafka message to trigger OCP processing...")
        print(f"  Topic: {self.topic}")
        print(f"  Request ID: {request_id}")
        print(f"  Provider UUID: {provider_uuid}")
        print(f"  Cluster ID: {cluster_id}")
        print(f"  Files: {len(files)}")

        try:
            # Use kubectl exec to send message from inside the cluster
            # This avoids needing to configure external Kafka access
            kafka_pod = self._get_kafka_pod()
            if not kafka_pod:
                return {
                    'success': False,
                    'error': 'No Kafka broker pods found'
                }

            # Use kafka-console-producer to send message
            cmd = [
                'kubectl', 'exec', '-n', 'kafka', kafka_pod, '--',
                'sh', '-c',
                f'echo \'{message_json}\' | /opt/kafka/bin/kafka-console-producer.sh '
                f'--bootstrap-server localhost:9092 '
                f'--topic {self.topic} '
                f'--property "parse.key=true" '
                f'--property "key.separator=:" '
                f'--request-required-acks 1'
            ]

            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=30
            )

            if result.returncode != 0:
                return {
                    'success': False,
                    'error': f'Failed to send Kafka message: {result.stderr}',
                    'request_id': request_id
                }

            print(f"  ✅ Kafka message sent successfully")

            return {
                'success': True,
                'request_id': request_id,
                'topic': self.topic,
                'files': files,
                'message': message
            }

        except subprocess.TimeoutExpired:
            return {
                'success': False,
                'error': 'Timeout sending Kafka message',
                'request_id': request_id
            }
        except Exception as e:
            return {
                'success': False,
                'error': f'Failed to send Kafka message: {str(e)}',
                'request_id': request_id
            }

    def _get_kafka_pod(self) -> str:
        """Get a Kafka broker pod name

        Returns:
            Pod name or None if not found
        """
        try:
            result = subprocess.run(
                ['kubectl', 'get', 'pods', '-n', 'kafka',
                 '-l', 'strimzi.io/name=kafka-cluster-kafka',
                 '-o', 'jsonpath={.items[0].metadata.name}'],
                capture_output=True,
                text=True,
                timeout=10
            )

            if result.returncode == 0 and result.stdout.strip():
                return result.stdout.strip()

            return None

        except Exception:
            return None

    def verify_kafka_connectivity(self) -> Dict:
        """Verify that we can connect to Kafka

        Returns:
            Dict with connectivity status
        """
        print("\n🔍 Verifying Kafka connectivity...")

        kafka_pod = self._get_kafka_pod()
        if not kafka_pod:
            return {
                'success': False,
                'error': 'No Kafka broker pods found'
            }

        try:
            # Test Kafka connectivity by listing topics
            result = subprocess.run(
                ['kubectl', 'exec', '-n', 'kafka', kafka_pod, '--',
                 '/opt/kafka/bin/kafka-topics.sh',
                 '--bootstrap-server', 'localhost:9092',
                 '--list'],
                capture_output=True,
                text=True,
                timeout=10
            )

            if result.returncode != 0:
                return {
                    'success': False,
                    'error': f'Failed to list Kafka topics: {result.stderr}'
                }

            topics = result.stdout.strip().split('\n')

            # Check if our required topic exists
            topic_exists = self.topic in topics

            print(f"  ✅ Kafka connectivity verified")
            print(f"  Topics: {len(topics)}")
            print(f"  Required topic '{self.topic}': {'✅ exists' if topic_exists else '⚠️  not found'}")

            return {
                'success': True,
                'topics': topics,
                'topic_exists': topic_exists,
                'kafka_pod': kafka_pod
            }

        except Exception as e:
            return {
                'success': False,
                'error': f'Failed to verify Kafka connectivity: {str(e)}'
            }

