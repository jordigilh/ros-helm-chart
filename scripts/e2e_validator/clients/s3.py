"""
S3 Client Wrapper
==================

Wrapper around boto3 for cleaner S3 API interactions.
"""

import boto3
from typing import List, Dict, Optional, TYPE_CHECKING

if TYPE_CHECKING:
    from .kubernetes import KubernetesClient


class S3Client:
    """Wrapper around boto3 for cleaner API"""

    def __init__(self, endpoint_url: str, access_key: str, secret_key: str,
                 region: str = 'us-east-1', verify: bool = False, k8s_client: Optional['KubernetesClient'] = None):
        """Initialize S3 client

        Args:
            endpoint_url: S3 endpoint URL
            access_key: AWS access key ID
            secret_key: AWS secret access key
            region: AWS region (default: us-east-1)
            verify: Verify SSL certificates (default: False for self-signed)
            k8s_client: Optional Kubernetes client for generating internal presigned URLs
        """
        self.endpoint = endpoint_url
        self.k8s = k8s_client
        self.s3 = boto3.client(
            's3',
            endpoint_url=endpoint_url,
            aws_access_key_id=access_key,
            aws_secret_access_key=secret_key,
            region_name=region,
            verify=verify
        )

    def create_bucket(self, bucket: str):
        """Create S3 bucket

        Args:
            bucket: Bucket name
        """
        try:
            self.s3.create_bucket(Bucket=bucket)
        except self.s3.exceptions.BucketAlreadyOwnedByYou:
            pass  # Bucket already exists, that's fine
        except self.s3.exceptions.BucketAlreadyExists:
            pass  # Bucket exists, that's fine

    def bucket_exists(self, bucket: str) -> bool:
        """Check if bucket exists

        Args:
            bucket: Bucket name

        Returns:
            True if bucket exists
        """
        try:
            self.s3.head_bucket(Bucket=bucket)
            return True
        except:
            return False

    def upload_file(self, local_path: str, bucket: str, key: str):
        """Upload file to S3

        Args:
            local_path: Local file path
            bucket: Bucket name
            key: S3 object key
        """
        with open(local_path, 'rb') as f:
            self.s3.put_object(Bucket=bucket, Key=key, Body=f.read())

    def upload_bytes(self, data: bytes, bucket: str, key: str):
        """Upload bytes to S3

        Args:
            data: Bytes to upload
            bucket: Bucket name
            key: S3 object key
        """
        self.s3.put_object(Bucket=bucket, Key=key, Body=data)

    def list_objects(self, bucket: str, prefix: str = '') -> List[Dict]:
        """List objects in bucket

        Args:
            bucket: Bucket name
            prefix: Key prefix filter

        Returns:
            List of object metadata dicts
        """
        response = self.s3.list_objects_v2(Bucket=bucket, Prefix=prefix)
        return response.get('Contents', [])

    def object_exists(self, bucket: str, key: str) -> bool:
        """Check if object exists

        Args:
            bucket: Bucket name
            key: S3 object key

        Returns:
            True if object exists
        """
        try:
            self.s3.head_object(Bucket=bucket, Key=key)
            return True
        except:
            return False

    def get_object(self, bucket: str, key: str) -> bytes:
        """Get object from S3

        Args:
            bucket: Bucket name
            key: S3 object key

        Returns:
            Object data as bytes
        """
        response = self.s3.get_object(Bucket=bucket, Key=key)
        return response['Body'].read()

    def delete_object(self, bucket: str, key: str):
        """Delete object from S3

        Args:
            bucket: Bucket name
            key: S3 object key
        """
        self.s3.delete_object(Bucket=bucket, Key=key)

    def delete_objects(self, bucket: str, keys: List[str]):
        """Delete multiple objects from S3

        Args:
            bucket: Bucket name
            keys: List of S3 object keys
        """
        if not keys:
            return

        objects = [{'Key': key} for key in keys]
        self.s3.delete_objects(
            Bucket=bucket,
            Delete={'Objects': objects}
        )

    def generate_presigned_url_via_pod(self, bucket: str, key: str, expires_in: int = 3600) -> Optional[str]:
        """Generate presigned URL using internal S3 endpoint by exec'ing into a pod
        
        This method generates a presigned URL from inside the cluster using a pod that has:
        - boto3 installed
        - AWS credentials configured (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)
        - Internal S3_ENDPOINT environment variable set
        
        This allows presigned URLs to use the internal .svc endpoint instead of external routes,
        enabling pods with `automountServiceAccountToken: false` to download from S3 without
        needing the cluster root CA from the service account mount.
        
        Args:
            bucket: S3 bucket name
            key: S3 object key
            expires_in: URL expiration in seconds (default: 3600)
            
        Returns:
            Presigned URL using internal S3 endpoint, or None if pod exec fails
        """
        if not self.k8s:
            raise ValueError("Kubernetes client required for generate_presigned_url_via_pod()")
        
        # Get MASU pod (has boto3 + AWS credentials + S3_ENDPOINT configured)
        masu_pod = self.k8s.get_pod_by_component('masu')
        if not masu_pod:
            print("  ⚠️  MASU pod not found, falling back to external presigned URL")
            return None
        
        # Python code to execute inside the pod
        python_code = f"""
import boto3
import os
import sys

try:
    endpoint = os.getenv('S3_ENDPOINT')
    access_key = os.getenv('AWS_ACCESS_KEY_ID')
    secret_key = os.getenv('AWS_SECRET_ACCESS_KEY')
    
    if not all([endpoint, access_key, secret_key]):
        print('ERROR: Missing S3 configuration', file=sys.stderr)
        sys.exit(1)
    
    s3_client = boto3.client(
        's3',
        endpoint_url=endpoint,
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
        region_name='us-east-1'
    )
    
    presigned_url = s3_client.generate_presigned_url(
        'get_object',
        Params={{'Bucket': '{bucket}', 'Key': '{key}'}},
        ExpiresIn={expires_in}
    )
    
    print(presigned_url)
except Exception as e:
    print(f'ERROR: {{e}}', file=sys.stderr)
    sys.exit(1)
"""
        
        try:
            output = self.k8s.python_exec(masu_pod, python_code)
            presigned_url = output.strip()
            
            # Verify the URL uses internal endpoint
            if '.svc' in presigned_url:
                return presigned_url
            else:
                print(f"  ⚠️  Generated URL doesn't use internal endpoint: {presigned_url[:80]}...")
                return None
        except Exception as e:
            print(f"  ⚠️  Failed to generate presigned URL via pod: {e}")
            return None

